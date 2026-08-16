# 第 41 章 测试与持续集成

> **本章导读**：nixpkgs 能同时维护十万多个包而不塌方，靠的是一条高度自动化的质量流水线：PR 机器人求值检查、维护者评审、机器人受权合并、Hydra 构建农场批量构建、渠道逐级晋升、缓存全网分发。本章先全景走一遍这条流水线，再分别站到「包作者」「NixOS 测试编写者」「普通用户」三个视角讲测试工具，最后给出自己项目的 GitHub Actions 持续集成（CI）模板。

## 41.1 nixpkgs 的质量流水线全景

把一个包从「我想改一行」到「全世界用户用上」的完整旅程画成图：

```
┌────────────┐   ┌─────────────┐   ┌──────────────┐   ┌─────────────┐
│  GitHub PR │──▶│   ofBorg    │──▶│ 维护者评审    │──▶│ merge 入库  │
│ (任何人提交)│   │ 求值检查/    │   │ (人工,按     │   │ master 或   │
│            │   │ 试构建/重建 │   │  CODEOWNERS  │   │ staging 分支│
│            │   │ 规模报告    │   │  与维护者名单)│   │             │
└────────────┘   └─────────────┘   └──────────────┘   └──────┬──────┘
                                                           │
                    ┌──────────────────────────────────────▼──────┐
                    │                Hydra 构建农场                │
                    │  · 对新 commit 求值出全部派生                 │
                    │  · 批量构建(多架构),成功者推送 cache.nixos.org │
                    │  · 跑 NixOS 测试套件与「tested」门槛任务        │
                    └──────────────────────┬───────────────────────┘
                                           │ 全部关键任务绿 + 缓存一致
                    ┌──────────────────────▼───────────────────────┐
                    │              渠道晋升(channel promotion)      │
                    │  nixos-unstable ──(半年一次切线)──▶ nixos-YY.MM │
                    │  通道指针只指向「构建完整、缓存就绪」的 commit      │
                    └──────────────────────────────────────────────┘
```

每个环节都有明确的自动化者：ofBorg（PR 机器人）管求值与试构建；nixpkgs-merge-bot（合并机器人）管「维护者授权后的合并」；Hydra（构建农场）管批量构建与缓存；渠道晋升由脚本依据 Hydra 的绿灯自动执行。人类维护者的工作集中在「评审」这一格——机器负责可机械判定的部分，人负责值得人看的部分。

大规模重建的 PR（如 bump 一个基础库）不会直接进 master，而是先入 **staging** 分支，等 Hydra 在 staging 上验证通过后再批量合并回 master——避免 master 长时间大面积变红。

每个环节的职责与执行者一表收拢：

| 环节 | 自动化者 | 人类做什么 |
| --- | --- | --- |
| 求值检查 | ofBorg | 无（红了自己改） |
| 试构建与重建规模报告 | ofBorg 构建机 | 判断走 master 还是 staging |
| 代码评审 | （无——刻意保留给人） | 看实现、看文档、看测试 |
| 合并执行 | nixpkgs-merge-bot | 维护者评论授权 |
| 批量构建与缓存 | Hydra + cache.nixos.org | 无 |
| 渠道晋升 | 晋升脚本（依据 Hydra 绿灯） | 处理 blocker、放行安全更新 |

## 41.2 ofBorg 与合并机器人

**ofBorg**（PR 机器人）在每个 PR 上自动出现，典型检查包括：

- **求值检查（eval）**：PR 的修改是否让 nixpkgs 在 x86_64-linux、aarch64-linux、x86_64-darwin 等平台上仍然能完整求值。改坏一个包名、写错一个类型，这里立刻红。
- **试构建（build）**：对受影响的包发起构建（ofBorg 自有构建机），结果贴回 PR。
- **重建规模报告（path counts）**：估算这个 PR 会触发多少个派生重编——评审者据此判断该走 master 还是 staging。报告贴在 PR 里，形如（示意）：

  ```text
  x86_64-linux: 12 packages built, 34 paths changed
  aarch64-linux: 12 packages built, 34 paths changed
  ```

ofBorg 接受评论指令，常用的有：

```text
@ofborg eval     # 强制重新求值
@ofborg build <pkg>   # 请求构建指定包,如 @ofborg build ripgrep
@ofborg rebase   # 把 PR 变基到目标分支最新
```

指令集合随版本演进，以 ofBorg 官方仓库及其 wiki 为准：https://github.com/NixOS/ofborg

**nixpkgs-merge-bot**（合并机器人）解决的是「维护者授权合并」：当 PR 触及的每个包的 `meta.maintainers` 里都有你时，你无需仓库写权限，只需在 PR 下评论：

```text
@NixOS/nixpkgs-merge-bot merge
```

机器人会核验你的维护者身份与包的关联关系，通过后代替官方成员执行合并。这在人员众多的开源项目里，把「授权」与「执行」干净地分开了。以仓库 README 为准：https://github.com/NixOS/nixpkgs-merge-bot

## 41.3 Hydra：官方构建农场与渠道晋升

**Hydra**（nixpkgs 官方构建农场，https://hydra.nixos.org）是 Nix 生态的「老黄牛」：对 nixpkgs 的每个推进 commit 求值出**全部**派生（「everything」顶层任务集），在 x86_64-linux、aarch64-linux、x86_64-darwin 等架构上批量构建，构建产物即时推送 cache.nixos.org（第 20 章）。围绕它有几个关键概念：

- **任务集（jobset）**：如 `nixos/unstable`（追踪 master 的组合任务）、`nixpkgs/release-26.05`（稳定分支）、各 PR 之外的大规模验证集。Hydra 页面上每个包的每个架构是一个任务（job）。
- **门槛任务（channel blockers）**：如 `tested`——要求给定 commit 的全部关键任务（安装测试、VM 测试套件、各架构核心包）全部成功，渠道才允许指向它。
- **一致性（consistency）**：晋升前检查「该 commit 求值出的所有派生是否都已在缓存中」。没构建完就晋升，用户更新时就会大面积触发本地编译——所以宁可慢，不可缺。
- **可复现性（r13y，reproducibility）**：对同一派生多次构建比对输出是否逐字节一致。社区看板 r13y.com（https://r13y.com）长期追踪 nixos-unstable 最小闭包的可复现率，是质量风向标。

**渠道为什么不即时**？因为「master 最新 commit」与「可以放心让百万用户更新的 commit」之间隔着：全部关键任务构建成功、缓存完整填充、无已知 blocker（某个核心包坏了、安全隐患待修、或晋升脚本还没跑到点）。unstable 渠道通常以小时级节奏晋升；半年一版的稳定渠道（nixos-26.05）更是只在一切绿灯后前进。你不是在等「打包」，你是在等「整棵依赖树的构建完整」。节奏与规则以 hydra.nixos.org 与 NixOS wiki 的 Channels 页面为准。

## 41.4 包作者侧的测试：passthru.tests、testers、doInstallCheck

作为包作者（第 36-38 章的延续），测试挂在包的 `passthru`（传递属性）上是标准姿势。Hydra 与 nixpkgs-review 都会自动发现并构建 `passthru.tests`：

```nix
# package.nix(节选)
{ lib, stdenv, fetchFromGitHub, nixosTests, testers, ... }:
stdenv.mkDerivation (finalAttrs: {
  pname = "myapp";
  version = "1.2.3";
  # ...

  passthru.tests = {
    # ① 挂现成的 NixOS VM 测试(41.5 节)——包与其系统级集成一起验证
    vmtest = nixosTests.myapp;

    # ② 版本自检:装完跑 --version,断言输出含 version
    version = testers.testVersion {
      package = finalAttrs.finalPackage;
      # command 默认取 pname;version 默认取 finalAttrs.version
    };

    # ③ pkg-config 模块自检:验证安装的 .pc 文件与名称匹配
    pkgConfig = testers.hasPkgConfigModules {
      package = finalAttrs.finalPackage;
    };
  };

  meta = {
    maintainers = with lib.maintainers; [ someone ];
    platforms = lib.platforms.linux;
  };
})
```

`testers`（测试帮手库，位于 `pkgs/lib/testers.nix`）常用成员：

| 帮手 | 断言什么 |
| --- | --- |
| `testers.testVersion` | 产物二进制的 `--version` 输出包含期望版本 |
| `testers.hasPkgConfigModules` | 产物提供了声明的 pkg-config 模块 |
| `testers.testEqualDerivation` | 两个表达式求值出完全相同的派生（防止无谓重建） |
| `testers.testEqualContents` | 两个路径内容逐字节一致 |
| `testers.testBuildFailure` | 断言「构建按预期失败」（测错误处理路径） |

另有对 shell 脚本批量跑 shellcheck 的 `testers.shellcheck` 等，完整清单以 `lib/testers.nix` 源码为准。它的用法示意：

```nix
# 对包内安装的 shell 脚本自动跑 shellcheck(参数以 lib/testers.nix 为准)
passthru.tests.shellcheck = testers.shellcheck {
  name = "myapp-scripts";
  scripts = [ finalAttrs.finalPackage ];   # 扫描产物中的 .sh / 入口脚本
};
```

这些测试帮手的价值在于**把「我以为能跑」变成派生级的凭据**：Hydra 每次构建都重新验证，回归在进入渠道之前就被拦住，而不是等用户在生产环境发现。

**doInstallCheck**（安装期自检）在第 36-38 章多次出场，这里收个尾：

```nix
stdenv.mkDerivation (finalAttrs: {
  # ...
  doInstallCheck = true;    # 打开 installCheck 阶段(默认在 check 之后、装完之后跑)
  installCheckPhase = ''
    runHook preInstallCheck
    # 冒烟测试:产物是否至少能启动。交叉时记得套 emulator 前缀(第 40 章)
    $out/bin/myapp --version > /dev/null
    runHook postInstallCheck
  '';
})
```

它与 passthru.tests 的分工：`doInstallCheck` 在**每次构建该包时**都跑（构建期质量），`passthru.tests` 是**独立的下游派生**（可以挂 VM 测试、跨包集成，且失败不会连带这个包本身构建失败）。两者互补，不是二选一。

## 41.5 NixOS VM 测试框架

NixOS 的杀手锏级测试设施：用 QEMU 起若干台虚拟机，机器的配置就是普通 NixOS 模块，测试脚本用 Python 驱动。测试本身是一个派生——「构建它」就是「跑它」，于是测试天然进了 Hydra 与缓存体系。

结构上，一个测试 = `nixos/tests/` 下的一个文件，导入 `make-test-python.nix`（Python 驱动版）：

```nix
# nixos/tests/myapp.nix 的骨架
import ./make-test-python.nix ({ lib, ... }: {
  name = "myapp";                    # 测试名,出现在构建日志与结果路径中
  meta.maintainers = [ lib.maintainers.someone ];

  nodes = {
    # 每个属性 = 一台虚拟机;机器名即测试脚本里的变量名
    machine = { config, pkgs, ... }: {
      services.myapp = {
        enable = true;               # 被测配置:普通 NixOS 模块(第 43 章会写这个模块)
        port = 8080;
      };
      environment.systemPackages = [ pkgs.curl ];  # 测试机里默认没有 curl,显式装上
    };
    # 需要多台(如 client/server)就继续加属性
  };

  testScript = /* python */ ''
    # 下面是 Python 代码;machine 即 nodes.machine
  '';
})
```

驱动脚本（driver）的常用 API，按使用频率排：

- `start_all()`：启动全部虚拟机（不调用则机器不会自动开机）。
- `machine.succeed("cmd")`：在 `machine` 内以 root 执行命令，返回 stdout；退出码非零则整个测试失败——「断言命令成功」。
- `machine.fail("cmd")`：反向断言——命令必须失败。
- `machine.wait_for_unit("nginx")`：等到 systemd 单元进入 active 状态（第 29 章）。
- `machine.wait_for_open_port(80)`：等到端口可建立 TCP 连接。
- `machine.wait_for_file("/path")`、`machine.wait_until_succeeds("cmd")`：轮询等待。
- `machine.execute("cmd")`：执行但不抛异常，返回状态，用于不构成断言的探查。
- `machine.copy_from_vm("/var/log/x.log")`：把 VM 内文件拷出，便于排错。
- `machine.screenshot("name")`：截屏（图形控制台下）。

完整示例：**测试 nginx 虚拟主机返回 200**，逐行注释：

```nix
import ./make-test-python.nix ({ lib, ... }: {
  name = "nginx";

  nodes.machine = { pkgs, ... }: {
    services.nginx = {
      enable = true;                          # 被测对象:nginx 服务
      virtualHosts."example.test" = {
        # 用派生造一个只有 index.html 的静态站点根目录
        # 为什么用派生:站点内容也进入测试的哈希,测试可复现
        root = pkgs.runCommand "test-root" { } ''
          mkdir -p $out
          echo "hello from nginx" > $out/index.html
        '';
      };
    };
    environment.systemPackages = [ pkgs.curl ];  # VM 里默认没有 curl
    networking.firewall.allowedTCPPorts = [ 80 ];# 放行 80,顺便测防火墙配置
  };

  testScript = /* python */ ''
    start_all()                                 # 开机(VM 启动到登录提示约需数十秒)
    machine.wait_for_unit("nginx")              # 等 nginx 单元 active——服务真的起来了
    machine.wait_for_open_port(80)              # 等 80 可连——监听真的就绪了
    # 断言 HTTP 状态码:
    # succeed 返回 stdout;curl -w '%{http_code}' 把状态码打到 stdout
    code = machine.succeed(
        "curl -s -o /dev/null -w '%{http_code}' http://localhost/"
    ).strip()
    assert code == "200", f"期望 200,实际 {code}"
    # 断言响应正文:
    body = machine.succeed("curl -s http://localhost/")
    assert "hello from nginx" in body
    # 顺手断言失败路径:访问不存在的路径应是 404
    code404 = machine.succeed(
        "curl -s -o /dev/null -w '%{http_code}' http://localhost/missing"
    ).strip()
    assert code404 == "404", f"期望 404,实际 {code404}"
  '';
})
```

在本地跑它：

```console
# 渠道方式:直接构建测试文件——VM 测试的「构建过程」就是执行测试
$ nix-build '<nixpkgs/nixos/tests/nginx.nix>'
# flake 方式:nixosTests 是 nixpkgs flake 暴露的测试集合
$ nix build nixpkgs#nixosTests.nginx
# 构建日志(含 VM 控制台输出)用 -L 实时看,或事后取:
$ nix log /nix/store/…-nginx.drv
```

两个容易踩的细节。其一，**测试为什么「构建即运行」**：VM 测试的派生把「起虚拟机、跑脚本、断言、关机」整个编排做成了构建过程，于是它享受派生的一切属性——输入变了就重跑、跑过就进缓存、Hydra 能并行调度。其二，**testScript 里的转义**：testScript 是 Nix 字符串，`${...}` 会被 Nix 求值；要写 Bash 的 `${VAR}`，得用 `''${VAR}`（两个单引号转义）：

```nix
testScript = /* python */ ''
  # ''$HOME 传给 VM 内 shell 时是字面量 ${HOME}
  machine.succeed("echo ''$HOME")
'';
```

交互式排错用 `driverInteractive`：得到一个 Python REPL，可以手动开机器、敲命令、看串口，还能连 VNC 看屏幕：

```console
$ nix build nixpkgs#nixosTests.nginx.driverInteractive
$ ./result/bin/nixos-test-driver
(nixos-test-driver)> start_all()
(nixos-test-driver)> machine.succeed("systemctl status nginx | head -20")
```

更轻量的日常试验：社区工具 **nixos-shell**（把一份 configuration.nix 直接丢进一台临时 VM 交互）适合「进机器里看看」；**colmena** 等部署工具则在部署前做并行求值检查。按需取用，正式回归仍以上述 VM 测试为准。

## 41.6 用户侧工具：nixpkgs-review、nix-diff、flake check

**nixpkgs-review**（PR 审查器）：审查一个 PR 影响的全部包——检出 PR、求值受影响的派生、逐个本地构建、报告成败。审别人的 PR、或自查「我的改动会炸掉谁」都是它：

```console
$ nix shell nixpkgs#nixpkgs-review
$ nixpkgs-review pr 345678          # 审查 GitHub PR 345678
$ nixpkgs-review rev HEAD           # 审查某个本地提交
$ nixpkgs-review wip                # 审查工作区未提交的改动
# 构建完成后自动进入一个 shell,被构建的包都在 PATH 里,可手动把玩验证
```

报告输出形如（示意）：

```text
$ nixpkgs-review rev HEAD
=== 3 packages to build:
myapp-1.2.3 myapp-cli-1.2.3 myapp-tests-1.2.3
[3 built, 0 fetched, 0 failed (0 cached), 0 queued]
=== 3 packages were built:
/nix/store/…-myapp-1.2.3 …
```

`failed` 一栏非零就是你的改动炸了下游——在别人发现之前先发现它，这就是 nixpkgs-review 的全部意义。

**nix-diff**（派生差异器）：两个 `.drv` 到底差在哪——依赖、环境变量、构建脚本，逐字段列出。排「为什么我的包没命中缓存」的利器（第 20 章问题的第 41 章答案）：

```console
$ nix shell nixpkgs#nix-diff
$ nix-diff \
    $(nix path-info --derivation nixpkgs#hello) \
    $(nix path-info --derivation .#hello)
# 输出两份配方之间的精确差异:
#   • environment.src: /nix/store/…-hello-2.12.1.tar.gz → /nix/store/…-hello-2.12.1.tar.gz
#   • environment.patches: [] → ["/nix/store/…-greeting.patch"]
```

**nix flake check**（flake 检查）：对自己的项目执行全套静态与动态检查——求值所有输出（packages、devShells、nixosConfigurations……）、校验元数据（description、license 齐全）、构建并运行 `checks` 输出里的派生：

```nix
# flake.nix(节选):把测试做成 check,flake check 会构建并运行它
{
  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      packages.${system}.default = pkgs.hello;

      checks.${system}.hello-works = pkgs.runCommand "hello-works" { } ''
        # runCommand 的构建脚本:跑一遍被测程序,把标记写进 $out
        ${self.packages.${system}.default}/bin/hello > $out
      '';
    };
}
```

```console
$ nix flake check      # 也可在 CI 里跑(41.7 节)
```

## 41.7 自己项目的 CI 实践

把上述工具串成自己项目的持续集成。GitHub Actions 完整模板（`.github/workflows/ci.yml`）：

```yaml
# .github/workflows/ci.yml —— Nix 项目的 CI 流水线
name: CI

on:
  pull_request:          # 每个 PR 都跑
  push:
    branches: [ main ]   # 主干推送也跑(部署 job 只在此时触发)

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4        # 拉代码;flake 只需要文件,浅克隆即可

      - uses: cachix/install-nix-action@v27
        # 安装 Nix 本体;版本号以该 action 仓库最新为准
        with:
          extra_nix_config: |
            # 用只读方式挂 store,免得 runner 磁盘被撑爆(可选)
            auto-optimise-store = true

      - name: 格式检查
        run: nix fmt -- --check
        # 前提:flake 里定义了 formatter(如 nixfmt);
        # --check 让它只报告不修改,有未格式化文件则失败

      - name: 静态检查与构建测试
        run: nix flake check -L
        # -L 直接打印构建日志,失败时不用再翻

      - uses: cachix/cachix-action@v15
        # 登录自己的 cachix 二进制缓存
        with:
          name: my-cache                 # 你的 cachix 缓存名
          authToken: '${{ secrets.CACHIX_AUTH_TOKEN }}'
          pushFilter: '(-source$|\.drv$)'
          # 推送时过滤源码派生与 .drv,只推真正有价值的产物

      - name: 构建并推送主产物
        run: nix build .#default -L
        # cachix-action 会在 job 结束时把本次构建的所有 store 路径推上缓存
        # 于是 PR 与后续 CI 全部命中缓存,不再重复构建

  deploy:
    needs: check                         # 前一 job 全绿才继续
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v27
      - name: 注入部署密钥
        uses: webfactory/ssh-agent@v0.9.0
        with:
          ssh-private-key: '${{ secrets.DEPLOY_SSH_KEY }}'
      - name: 远程部署
        run: |
          # 从 CI 机器直接驱动远端切换(第 27 章讲过 switch-to-configuration)
          # --use-remote-sudo:远端需要 sudo 权限
          nix run nixpkgs#nixos-rebuild -- switch \
            --flake .#prod \
            --target-host deploy@prod.example.com \
            --use-remote-sudo
        # 产物已推上 cachix,远端机器几乎零本地构建
```

如果要覆盖多个系统，给 check job 加矩阵（matrix）即可——每个系统一个 runner，各自 `nix flake check` 时只构建本系统的 checks：

```yaml
  check-matrix:
    strategy:
      matrix:
        os: [ ubuntu-latest, ubuntu-24.04-arm ]   # x86_64 与原生 aarch64 runner
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v27
      - run: nix flake check -L
```

（runner 名称与可用性以 GitHub 官方文档为准。）

提交前的**本地把关**清单（让 PR 一次过）：

```console
$ nix fmt                          # 统一格式(nixfmt,nixpkgs 官方格式化器,RFC 166)
$ nix flake check -L               # 求值 + 测试一条龙
$ nix shell nixpkgs#statix -c statix check ./
# statix:反模式检查(如不必要的 with、可简化的继承)
$ nix shell nixpkgs#nixpkgs-hammering -c nixpkgs-hammer ./pkgs/myapp/package.nix
# nixpkgs-hammering:打包习惯检查(缺 meta、无谓重建等),建议逐条处理
$ nixpkgs-review wip               # 动真格:把受影响的包全部本地构建一遍
```

这套「本地把关 + CI 复验 + 缓存共享」就是 nixpkgs 流水线在个人项目尺度上的翻版——工具相同，规模不同而已。

## 41.8 本章小结

- nixpkgs 质量流水线：PR → ofBorg 求值/试构建 → 维护者评审 → merge（master 或 staging）→ Hydra 批量构建并推缓存 → 渠道晋升；机器做机械判定，人做判断。
- ofBorg 提供 eval、build、rebase 等评论指令（以其官方 wiki 为准）；nixpkgs-merge-bot 让维护者在授权范围内自助合并。
- Hydra 以任务集批量构建；渠道晋升受「tested」门槛任务、缓存一致性与可复现性（r13y）约束——慢是为了完整。
- 包作者三件套：`passthru.tests` 挂独立测试（含 VM 测试）、`testers.*` 断言帮手、`doInstallCheck` 构建期自检——前两者独立派生，后者每次构建都跑。
- NixOS VM 测试 = make-test-python.nix + nodes 配置 + Python 脚本；`succeed/fail/wait_for_unit/wait_for_open_port/copy_from_vm` 是核心 API；测试本身是派生，构建即运行。
- 本地跑测试用 `nix build nixpkgs#nixosTests.<name>`，排错用 `driverInteractive` 进交互驱动；nixos-shell 适合轻量试验。
- 用户工具：`nixpkgs-review` 审 PR 影响面、`nix-diff` 比派生差异、`nix flake check` 检查自己的 flake。
- 自己的 CI：install-nix → fmt 检查 → flake check → cachix 推送 → 主干绿后远程 nixos-rebuild 部署；提交前配 statix 与 nixpkgs-hammering。

## 延伸阅读

- Hydra 构建农场：https://hydra.nixos.org
- ofBorg（含指令 wiki）：https://github.com/NixOS/ofborg
- nixpkgs-merge-bot：https://github.com/NixOS/nixpkgs-merge-bot
- nixpkgs 手册·NixOS 测试：https://nixos.org/manual/nixpkgs/unstable/#sec-nixos-tests
- nixpkgs 手册·testers：https://nixos.org/manual/nixpkgs/unstable/#sec-testers
- nixpkgs-review：https://github.com/Mic92/nixpkgs-review
- nix-diff：https://github.com/oxij/nix-diff
- nix flake check 命令参考：https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-flake-check
- Cachix 文档：https://docs.cachix.org
- 可复现性看板：https://r13y.com
