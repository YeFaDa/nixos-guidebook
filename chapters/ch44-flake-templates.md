# 第 44 章 Flake 应用开发模板

> **本章导读**：学完第 21 章的 flakes 机制与第 39 章的 override/overlay 之后，缺的是一个「把它们组装起来」的完整骨架。本章给出一份可直接抄走的工程模板：从仓库目录结构、flake.nix 逐行骨架，到 devShells、自有软件打包、overlay 暴露、NixOS 与 home-manager 集成、formatter/checks 质量内建，最后落到 GitHub Actions CI 与常用命令速查。无论你管理的是 dotfiles、团队项目还是自己的软件发布，这份模板都能作为起点。

## 44.1 模板总览：推荐的仓库结构

先看全貌。以下结构同时适合「个人配置仓库」（dotfiles）与「项目仓库」，多余的部分按需删减：

```
my-config/
├── flake.nix                  # 唯一入口：inputs 与全部 outputs
├── flake.lock                 # 输入的精确锁定（提交进 git！）
├── .envrc                     # direnv 配置：一行 use flake，进目录即得开发环境
├── README.md
├── hosts/                     # 每台机器一份 NixOS 配置
│   ├── myhost/
│   │   ├── configuration.nix  # 该机的 configuration.nix（第 24 章）
│   │   └── hardware-configuration.nix
│   └── nas/                   # 第二台机器，同一仓库统一管理
├── modules/                   # 可复用的 NixOS 模块（第 25、43 章）
│   └── shared/default.nix     # 全机器共享的公共配置
├── home/                      # home-manager 用户配置（44.7）
│   └── alice.nix
├── packages/                  # 自己打包的软件（44.5）
│   └── foo.nix
└── overlays/                  # 需要全局覆盖 pkgs 时放这里（44.6）
    └── default.nix
```

三条组织原则：

1. **flake.nix 只做「接线」**。它声明输入、把各目录的模块/包连到 outputs 上；具体内容全部下放到 `modules/`、`hosts/`、`packages/`，保持入口文件薄——这样几百台机器的仓库，flake.nix 依然只有百来行。
2. **按「谁在变化」分目录**。机器相关的进 `hosts/`，跨机器复用的进 `modules/`，与操作系统无关的进 `packages/` 与 devShells。
3. **flake.lock 必须提交**。它是可复现性的锚点（第 21 章）；「lock 文件要不要进版本库」在社区有过争论，对配置仓库与应用仓库，现行共识是**提交**，更新则是显式动作（44.10）。

## 44.2 flake.nix 骨架：逐行注释

```nix
# flake.nix —— 本模板的完整骨架
{
  # description 会显示在 nix flake metadata 与搜索结果里，认真写一句
  description = "我的 NixOS 配置与项目工具链";

  inputs = {
    # nixpkgs 输入：github: 前缀的 flake ref（第 21 章），
    # ref 锁定到 NixOS 26.05 稳定分支；不写 ref 则默认追 master（unstable）
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # 追踪滚动分支的第二个输入：两者并存，按机器选用
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    home-manager = {
      # home-manager 必须用与 nixpkgs 大版本匹配的 release 分支
      url = "github:nix-community/home-manager/release-26.05";

      # ✅ 关键一行：让 home-manager 内部使用「我们上面那个 nixpkgs」。
      # 若不 follows，home-manager 会带来自己独立的 nixpkgs 副本，
      # 结果：同一份配置里出现两套不同版本的包环境，闭包翻倍、
      # 版本漂移、依赖冲突。所有工具型 input 都应这样对齐
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  # outputs 接收所有 input：
  # { self, nixpkgs, ... } 是显式解构；@inputs 把整个输入集合也捕获一份，
  # 便于原样透传给 nixosSystem 的 specialArgs（见 44.7）
  outputs = { self, nixpkgs, nixpkgs-unstable, home-manager }@inputs:
    { /* 以下各节逐步填充 */ };
}
```

关于 `github:` URL 与 ref 再补两句：`github:owner/repo/ref` 中 ref 可以是分支名（如 `nixos-26.05`）、tag 或 commit 哈希；写分支名时 lock 文件负责把「今天的 26.05」钉死成具体 commit——所以 ref 的粒度决定你追新的频率。裸 URI（如 `git+https://...` 不带 rev）在旧教程里常见，⛔ 已不推荐：不可锁定的输入破坏复现性，一律走带 ref 的 flake ref 写法。

## 44.3 perSystem 与多平台输出

flake 的 `packages`、`devShells`、`apps`、`checks`、`formatter` 五类输出都必须按系统（system）分层：`packages.x86_64-linux.foo`。手写每个系统一遍既冗长又易漏，标准做法是用一个帮助函数批量展开。两种流派：

```nix
outputs = { self, nixpkgs, ... }@inputs:
  let
    # ✅ 流派 A：手写系统列表（零额外依赖，nixpkgs.lib 自带 genAttrs）
    systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
    forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    # 每个系统取出该平台的 pkgs 实例，后面反复使用
    pkgsFor = forAllSystems (system: import nixpkgs {
      inherit system;
      # 在此应用自己的 overlay（44.6），保证 devShell/包与系统口径一致
      overlays = [ self.overlays.default ];
    });
  in
  { /* 用 forAllSystems 展开 outputs */ };

  # ✅ 流派 B：flake-utils 库
  # inputs.flake-utils.url = "github:numtide/flake-utils";
  # outputs = { self, nixpkgs, flake-utils }: flake-utils.lib.eachDefaultSystem
  #   (system: { packages.hello = ...; })
  # 优点：默认覆盖常见平台、带 eachSystem 等糖；缺点：多一个 input。
  # 两个流派等价，团队按口味二选一即可（另有 hercules-ci/flake-parts
  # 提供更结构化的模块化写法，仓库变大后可再考虑）
```

五类输出的分工，一张表说清：

| 输出 | 地址 | `nix` 命令 | 用途 |
| --- | --- | --- | --- |
| packages | `packages.<system>.<name>` | `nix build .#name` | 打包产物（每个都应是 derivation） |
| devShells | `devShells.<system>.<name>` | `nix develop .#name` | 开发环境（44.4） |
| apps | `apps.<system>.<name>` | `nix run .#name` | 可执行入口，program 指向可运行文件 |
| checks | `checks.<system>.<name>` | `nix flake check` | 质量检查：构建即测试（44.8） |
| formatter | `formatter.<system>` | `nix fmt` | 格式化器（44.8） |

**legacyPackages 与 packages 的选择**：`packages` 要求每个属性都是扁平的单个 derivation，会被 `nix flake check` 严格校验——自己的包放这里。`legacyPackages` 允许任意嵌套（包括直接放整棵 `pkgs` 树），nixpkgs 官方仓库就是用它暴露全部软件。规则很简单：⚠️ 自己的仓库尽量只用 `packages`；只有当某个输出天生是「一棵树」（比如应用 overlay 后的完整 pkgs 实例，见 44.6）时才用 `legacyPackages`，且它不会参与 flake check 的严格校验。

## 44.4 devShells：可复制的开发环境

devShell 的本质是「一个只为环境而生的 derivation」（mkShell），进入它就得到一组固定的工具与环境变量——团队成员之间、CI 与本地之间，由此共享同一个工具链版本：

```nix
devShells = forAllSystems (system:
  let pkgs = pkgsFor.${system}; in {
    # default 是 nix develop 不带参数时的落点
    default = pkgs.mkShell {
      # packages：进入 shell 后 PATH 里多出的工具
      packages = [
        pkgs.go          # Go 工具链本体
        pkgs.gopls       # 语言服务器
        pkgs.delve       # 调试器
        pkgs.golangci-lint
      ];
      # ⚠️ 旧教程爱写 with pkgs; [ go gopls ]——作用域遮蔽问题多，
      #    现代规范建议显式 pkgs. 前缀（可读、可 grep、少惊喜）

      # env：以更严格的方式设置环境变量（mkDerivation 的 env 参数，
      # 会被视为字面量而非依赖引用）
      env = {
        GOLANGCI_LINT_CACHE = "${toString ./.}/.golangci-cache";
      };

      # shellHook：进入 shell 时执行的一次性脚本，做变量设置与提示
      shellHook = ''
        echo "进入 gcat 开发环境（Go $(go version | cut -d' ' -f3)）"
        # 关联 44.8 的 pre-commit 检查，进入 shell 即自动挂上钩子
        ${self.checks.${system}.pre-commit-check.shellHook}
      '';
    };

    # 多 shell：给不同场景不同的环境，nix develop .#ci 进入
    ci = pkgs.mkShell {
      packages = [ pkgs.nil pkgs.nixfmt ];   # CI 只需要 Nix 相关工具
    };
    lint = pkgs.mkShell {
      packages = [ pkgs.golangci-lint ];
    };
  });
```

日常使用：

```console
# 进入 default shell
$ nix develop

# 直接在 devShell 里跑一条命令（不进入交互，CI 与脚本友好）
$ nix develop -c go test ./...

# ⛔ 旧时代的 nix-shell -p go：仍可用，但与 flake 世界两套口径；
#    新项目统一 nix develop（第 45 章有两者冲突的排错条目）
```

**direnv + nix-direnv** 让「进入环境」这个动作彻底消失：在仓库根放一个 `.envrc`，内容一行 `use flake`，cd 进目录自动加载 devShell、离开自动卸载：

```bash
# .envrc —— 就这一行（需要先安装 direnv 与 nix-direnv 两个插件）
use flake
```

```console
# 首次允许该目录的 direnv（安全机制，防止恶意 .envrc）
$ direnv allow

# 之后就无感了：cd 进去工具就位，cd 出去环境消失
$ cd my-config && which go
/nix/store/…-go-1.24/bin/go
```

务必配合 nix-direnv 使用（它负责缓存 devShell 的求值结果），否则每次 cd 都要付出一次完整求值的代价。NixOS 上两者都可经 `programs.direnv.enable = true;` 与 `programs.direnv.nix-direnv.enable = true;` 声明式安装。

## 44.5 打包自己的软件

仓库里自有软件（或暂不想进 nixpkgs 的第三方软件）放 `packages/` 目录，用 `pkgs.callPackage` 接入（第 39 章详述了它的机制，这里只看接线）：

```nix
# packages/foo.nix —— 一个普通的包定义（第 34、42 章的写法原样适用）
{ lib, stdenv, fetchFromGitHub }:

stdenv.mkDerivation (finalAttrs: {
  pname = "foo";
  version = "1.2.3";
  src = fetchFromGitHub {
    owner = "example";
    repo = "foo";
    tag = "v${finalAttrs.version}";
    hash = "sha256-…";     # 照样走假哈希循环，见第 42 章
  };
  meta.mainProgram = "foo";
})
```

在 outputs 里接线：

```nix
packages = forAllSystems (system:
  let pkgs = pkgsFor.${system}; in {
    # ✅ callPackage 的两个收益（第 39 章）：
    # 1) 自动注入：foo.nix 声明的参数按名从 pkgs 取值，无需手写传参
    # 2) 可覆盖性：使用者可随时 (pkgs.foo.override { … }) 换掉任一依赖
    foo = pkgs.callPackage ./packages/foo.nix { };
  });
```

**apps 与 nix run**：`packages.foo` 装好之后其实已经可以 `nix run .#foo`（前提是 meta.mainProgram 指明了入口），apps 输出的价值在于**另起一个名字**、或让入口指向包装脚本：

```nix
apps = forAllSystems (system:
  let pkgs = pkgsFor.${system}; in {
    # apps.default：nix run（不带参数）时的落点
    default = {
      type = "app";                                  # 目前唯一类型
      program = pkgs.lib.getExe pkgs.hello;          # ✅ getExe：从包取可执行文件
    };                                               #    的标准姿势，自动读
    serve = {                                        #    meta.mainProgram
      type = "app";
      # 也可以直接指自家包：pkgs.lib.getExe self.packages.${system}.foo
      program = pkgs.lib.getExe self.packages.${system}.foo;
    };
  });
```

```console
$ nix run .#           # 跑 apps.default
$ nix run .#serve      # 跑指定的 app
```

## 44.6 overlays：暴露与消费

当你需要**修改** nixpkgs 里的包（升版本、换依赖、打补丁）时，写一个 overlay（第 39 章）。仓库内自用、同时对外暴露给别的 flake 复用，是现代项目的标准姿势：

```nix
# flake.nix 的 outputs 里
overlays = {
  # final/prev 双参数是 overlay 的固定签名（第 39 章）：
  # final 是「应用全部 overlay 之后」的 pkgs（互相引用用它），
  # prev 是「上一层」的 pkgs（引用原版用它）
  default = final: prev: {
    # 例子：给整个仓库提供一个换过依赖的 foo
    foo = final.callPackage ./packages/foo.nix { };
    # 例子：覆盖 nixpkgs 已有包的版本
    # hello = prev.hello.overrideAttrs (oldAttrs: rec { … });
  };
};
```

消费这个 overlay 的三种途径：

```nix
// 途径一：别的 flake 把你的仓库当 input，再挂到自己的 nixpkgs 上
// inputs.my-config.url = "github:you/my-config";
// nixpkgs.overlays = [ inputs.my-config.overlays.default ];
```

```nix
# 途径二：本仓库的 pkgsFor 统一应用（44.3 已写），保证 devShell、
# packages 与系统三处看到的 pkgs 口径一致
pkgsFor = forAllSystems (system: import nixpkgs {
  inherit system;
  overlays = [ self.overlays.default ];
});
```

```nix
# 途径三：导出一棵「应用了 overlay 的完整 pkgs 树」。
# 这就是 legacyPackages 的合法用武之地（44.3 的规则）
legacyPackages = forAllSystems (system: pkgsFor.${system});
```

注意途径三与 `packages` 的区别：`legacyPackages.x86_64-linux` 是整棵树（含你覆盖后的所有 nixpkgs 包），适合「让消费者随意取用」；`packages` 则是你**有意发布**的、经过 flake check 校验的清单。对外发布用后者，内部传递用前者。

## 44.7 系统集成：nixosConfigurations 与 homeConfigurations

配置仓库的最终产出是「可部署的系统」。flake 里用 `nixpkgs.lib.nixosSystem` 定义每台机器（与第 24 章的 configuration.nix 无缝衔接）：

```nix
nixosConfigurations = {
  myhost = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    # specialArgs：向所有模块注入额外参数——
    # 把 inputs 整包传入，模块里就能用 inputs.home-manager 等引用
    specialArgs = { inherit inputs; };
    modules = [
      ./hosts/myhost/configuration.nix     # 机器本体
      ./hosts/myhost/hardware-configuration.nix
      ./modules/shared                     # 公共配置（目录带 default.nix）
      # home-manager 以 NixOS 模块方式接入（下文模式对比）
      home-manager.nixosModules.home-manager
      {
        home-manager.useGlobalPkgs = true;     # 复用系统 nixpkgs，不另开一套
        home-manager.useUserPackages = true;   # 装进用户 profile，而非系统全局
        home-manager.extraSpecialArgs = { inherit inputs; };
        # 用户 alice 的 home 配置直接挂进来
        home-manager.users.alice = import ./home/alice.nix;
      }
    ];
  };
};
```

定义好之后，`nixos-rebuild switch --flake .#myhost` 即可部署（远程部署见第 31 章）。

**home-manager 的两种使用模式**要分清，按场景选择：

| | standalone（独立模式） | as-NixOS-module（模块模式） |
| --- | --- | --- |
| 挂载方式 | 独立的 homeConfigurations 输出 | 塞进 nixosSystem 的 modules |
| 更新命令 | `home-manager switch --flake .#alice` | 跟随 `nixos-rebuild switch` |
| 适用场景 | 非NixOS 的 Linux/macOS、服务器上无 root 的场景 | 全套 NixOS 的个人机器 |
| 原子性 | 用户层单独一个 profile | 系统+用户一次性原子切换 |

standalone 模式的最小示例：

```nix
homeConfigurations."alice" = home-manager.lib.homeManagerConfiguration {
  # 注意：homeManagerConfiguration 的参数形状随版本有过调整，
  # 以 home-manager 手册当前版本为准
  pkgs = nixpkgs.legacyPackages.x86_64-linux;   # 指定平台的 pkgs
  modules = [ ./home/alice.nix ];
};
```

```console
$ nix run home-manager -- switch --flake .#alice
```

`home/alice.nix` 内部就是普通的 home-manager 模块：`home.packages`、`programs.git.enable` 之类，两种模式下写法完全相同——差异只在「谁负责激活它」。

## 44.8 质量内建：formatter 与 checks

「质量内建」指让 `nix flake check` 一条命令就能替你把关整个仓库。两块拼图：

**formatter 输出**接住 `nix fmt` 命令，把格式化也钉死在 flake 里，团队不再争论装哪个格式化器：

```nix
# ✅ nixfmt：现行官方推荐格式化器（nixpkgs 已采纳其 RFC 166 风格）
formatter = forAllSystems (system: pkgsFor.${system}.nixfmt);
```

```console
$ nix fmt        # 格式化整个仓库（含 flake.nix 与所有 .nix）
```

**checks 输出**里放任何「构建成功即测试通过」的 derivation。社区流行的 pre-commit-hooks.nix 把 statix（反模式静态检查）、deadnix（死代码）、nixfmt（格式）变成一个 check：

```nix
# inputs 增加（别忘了 follows 对齐 nixpkgs）：
# pre-commit-hooks = {
#   url = "github:cachix/pre-commit-hooks.nix";
#   inputs.nixpkgs.follows = "nixpkgs";
# };

checks = forAllSystems (system:
  let pkgs = pkgsFor.${system}; in {
    # pre-commit-hooks 提供的 run 函数：把钩子检查打包成单个 derivation
    pre-commit-check = inputs.pre-commit-hooks.lib.${system}.run {
      src = ./.;                          # 检查整个仓库
      hooks = {
        nixfmt.enable = true;             # Nix 代码格式
        statix.enable = true;             # 常见反模式（如多余的 let）
        deadnix.enable = true;            # 未使用的绑定
      };
    };
  });
```

把 44.4 里 shellHook 那行接上后，git commit 前钩子也会自动执行同样的检查——本地提交与 CI 校验用的是同一份定义，不存在「两套标准」。验收：

```console
$ nix flake check
```

它会对当前平台的所有 checks 逐一构建，并对 packages 做求值校验；CI（下一节）直接复用这条命令。

## 44.9 CI：GitHub Actions 最小配置

把上节的质量内建搬进 CI，再接上 cachix 缓存推送，就得到一份「15 行起步」的流水线（以 2026 年主流的 action 版本为例，具体版本以官方仓库最新为准）：

```yaml
# .github/workflows/ci.yml
name: CI
on:
  push:
    branches: [ main ]      # 主干变更才推送缓存
  pull_request:             # PR 只做检查与读缓存

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4      # 检出仓库（flake 依赖 git 树，见第 45 章）

      - uses: cachix/install-nix-action@v31
        with:
          # 提高 GitHub API 限额，拉取 github: 输入时不易被限流
          extra_nix_config: |
            access-tokens = github.com=${{ secrets.GITHUB_TOKEN }}

      - uses: cachix/cachix-action@v16
        with:
          name: your-cache-name         # 你在 cachix.org 建的缓存名
          # 缓存命中策略：只有主干推送才写缓存，PR 只读——
          # 避免每个 PR 都往缓存里塞重复产物
          push: ${{ github.ref == 'refs/heads/main' }}
          authToken: ${{ secrets.CACHIX_AUTH_TOKEN }}

      - name: Flake check
        run: nix flake check

      - name: Build packages
        run: nix build .#foo
```

**缓存命中策略**是这套流水线的灵魂，原则有三：

1. **主干推送，PR 拉取**。main 分支的构建结果进缓存后，后续 PR 与所有人的本地构建都能直接命中，把「CI 构建 40 分钟」变成「CI 下载 40 秒」；
2. **CI 与本地共用一个缓存**。团队成员在 NixOS 的 `nix.settings.substituters` 里加上自己的 cachix 地址（配 `trusted-public-keys`），本地 `nix build` 同样命中——第 20 章的缓存机制在此落地；
3. **先 check 后 build**。`nix flake check` 覆盖求值与测试，`nix build` 覆盖构建，两者顺序执行，前者失败即止，反馈更快。

## 44.10 常用命令速查表

日常操作一表汇总（均在 flake 仓库根目录执行）：

| 目的 | 命令 | 备注 |
| --- | --- | --- |
| 构建自有包 | `nix build .#foo` | 产物软链在 `./result` |
| 构建系统闭包 | `nix build .#nixosConfigurations.myhost.config.system.build.toplevel` | 不激活，仅验证 |
| 运行 app/包 | `nix run .#serve` | 无参数时用 apps.default |
| 进入开发环境 | `nix develop` | 等价 `.#default`，配 direnv 后无感 |
| 在环境中执行命令 | `nix develop -c make test` | 不进入交互 |
| 检查整个 flake | `nix flake check` | checks + 求值校验 |
| 格式化 | `nix fmt` | 用 formatter 输出 |
| 查看输出清单 | `nix flake show` | 排查 outputs 结构错误 |
| 装进用户 profile | `nix profile install .#foo` | ⛔ 旧世界是 nix-env -iA，已不推荐 |
| 卸载 | `nix profile remove foo` | 对应上一条 |

输入更新的新旧写法务必注意（Nix 2.22 起命令语义重排）：

```console
# ✅ 现行写法（Nix 2.22+，含 2.35）
$ nix flake update                # 更新全部输入，重写 flake.lock
$ nix flake update nixpkgs        # 只更新名为 nixpkgs 的这一个输入

# ⛔ 旧写法：仍被兼容但已弃用，新脚本不要再写
$ nix flake lock --update-input nixpkgs

# 临时用另一个版本做实验（不改 lock，适合测试 PR 分支的 nixpkgs）
$ nix build .#foo --override-input nixpkgs github:NixOS/nixpkgs/pull/12345/head
```

更新后记得 `git diff flake.lock` 检查变化范围、提交 lock；`nix flake metadata` 可随时查看各输入当前锁定的 commit。

## 44.11 本章小结

- 推荐结构：flake.nix 只做接线，内容按 hosts/（机器）、modules/（复用模块）、packages/（自有包）、home/（用户环境）分目录；flake.lock 必须提交。
- inputs 的 `inputs.nixpkgs.follows = "nixpkgs"` 是健康配置的标志：所有工具型输入对齐同一个 nixpkgs，避免双份闭包与版本漂移。
- 用 genAttrs 展开系统列表或 flake-utils 的 eachDefaultSystem 处理多平台；packages 只放扁平 derivation，整棵 pkgs 树才用 legacyPackages。
- devShells 用 mkShell 组装工具与 env，多 shell 按场景分（default/ci/lint）；配 direnv 的 `use flake` 实现「进目录即环境」。
- 自有软件经 `pkgs.callPackage ./packages/foo.nix { }` 接入：自动注入参数、天然可 override；apps.default 配 lib.getExe 定义 nix run 入口。
- overlay 用 final/prev 双参数书写，既在本仓库 pkgsFor 中统一应用，也经 overlays.default 输出给下游消费。
- nixosSystem 的 modules/specialArgs 组装整机，homeConfigurations 承载 standalone 用户环境；home-manager 两种模式按「是否 NixOS 全家桶」选择。
- 质量内建 + CI 的组合拳：formatter 用 nixfmt，checks 挂 pre-commit-hooks（statix/deadnix/nixfmt），CI 复用 nix flake check 并以「主干推送、PR 拉取」的策略经营 cachix 缓存。

## 延伸阅读

- Nix 手册：flake 命令参考 —— https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-flake.html
- NixOS Wiki：Flakes —— https://wiki.nixos.org/wiki/Flakes
- home-manager 手册 —— https://nix-community.github.io/home-manager/
- nix-direnv —— https://github.com/nix-community/nix-direnv
- pre-commit-hooks.nix —— https://github.com/cachix/pre-commit-hooks.nix
- cachix 使用文档 —— https://docs.cachix.org/
