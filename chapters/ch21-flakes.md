# 第 21 章 Flakes：新一代 Nix 工作流

> **本章导读**：channel 时代的 Nix 有一个尴尬的秘密——「我用的是 nixpkgs」这句话在不同机器上含义不同，而且没有任何文件记录你当时用的到底是哪一份。Flakes 用一份 `flake.nix` 加一份 `flake.lock` 把「依赖什么」与「锁定到哪」变成仓库里可审计的两个文件。本章覆盖 flake 的定义、URL 语法、`outputs` 协议、锁文件解剖、日常命令全集、与 NixOS 的集成，以及它长期「实验特性」身份背后的诚实现状与最佳实践。

## 21.1 痛点回顾：channel 时代的不确定性

第 18 章介绍过 channel（频道）机制：它把 nixpkgs 的一个滚动快照安装到本地，`<nixpkgs>` 这个尖括号路径经由 `NIX_PATH` 环境变量解析。这套机制工作得不错，但埋着三个雷。

**雷一：`<nixpkgs>` 指向哪里取决于环境**。`NIX_PATH` 是环境变量，root 的 channel 与你用户的 channel 可以不同，两台机器更可以不同：

```bash
# 两台机器上分别执行，输出可能完全不同：
nix-channel --list        # channel 名字都叫 nixpkgs
# 但 root 的 nixpkgs 与用户的 nixpkgs、A 机与 B 机的 nixpkgs，
# 分别是不同时间点的不同快照
```

旧世界也有自己的「验伤」办法——直接看尖括号解析到哪，但结果本身就依赖环境：

```console
$ nix-instantiate --eval -E '<nixpkgs>'
# 打印 <nixpkgs> 当下解析到的 store 路径；
# 换个用户、换台机器、channel 更新之后再跑，答案都可能不同
```

于是「同一份配置文件在两台机器装出不同的包」屡见不鲜，而 channel 更新（`nix-channel --update`）之后，旧的对应关系就永远消失了——**没有任何文件记录你当时用的究竟是哪一次提交**。

**雷二：没有锁文件**。对比现代语言生态：Cargo 有 `Cargo.lock`，npm 有 `package-lock.json`，它们把「依赖解析的结果」固化为可提交的文件。channel 世界的 Nix 没有对应物，「可复现」只能靠人人自律地固定 channel 版本号。

**雷三：git 仓库无法作为依赖源**。想在构建里用朋友的仓库？只能用 `builtins.fetchTarball` 之类的临时手段：

```nix
# 旧世界的典型写法：能跑，但既不锁定也不记录
import (builtins.fetchTarball
  "https://github.com/NixOS/nixpkgs/archive/master.tar.gz")
```

每次求值都可能拿到不同的 `master`，哈希也没进任何锁文件——你刚才还能构建的东西，下次求值就变了。

Flakes 对这三个雷各给出一击：**任意 git 仓库可直接作为依赖源**（URL 即依赖）、**`flake.lock` 锁定每个依赖的精确版本**、**求值是纯的**（不再读 `NIX_PATH` 与你的环境）。本章余下部分展开这套机制。

## 21.2 flake 是什么：定义、URL 与「协议」

一个 flake（雪花/碎片，官方对这个词没有更多解释，社区也常直接用英文）就是**一个含有 `flake.nix` 文件的目录**，通常是 git 仓库。`flake.nix` 声明依赖（inputs）与产出（outputs）；Nix 负责把依赖解析、锁定、复制进 store，然后求值 outputs 函数。

引用一个 flake 的语法是 flake URL（flake reference），常见形态：

- `github:NixOS/nixpkgs` —— GitHub 仓库，跟默认分支（可变引用）；
- `github:NixOS/nixpkgs/nixos-26.05` —— 附加 ref，分支或标签（可变引用）；
- `github:NixOS/nixpkgs/<40位提交号>` —— 精确提交（不变引用）；
- `git+file:///home/me/my-repo` —— 本地 git 仓库；开发自己的 flake 时更常用直接给路径；
- `path:./sibling-dir` —— 普通目录（不要求 git），整个目录会被复制进 store；不带 `narHash` 参数时是可变引用，锁文件会补上哈希使其确定；
- 裸 `nixpkgs` 或 `flake:nixpkgs` —— **flake 注册表（flake registry）别名**，展开为注册表里登记的 URL（全局注册表中 `nixpkgs` 指向 NixOS/nixpkgs 的 unstable 分支，以注册表实际内容为准）。

此外还可用查询参数附加信息，如 `?ref=`、`?rev=`、`?dir=`（flake.nix 不在仓库根目录时）、`?narHash=`（本地路径的锁定哈希）。

**「协议」**：`flake.nix` 的核心是 `outputs` 函数——它接收所有 inputs 的求值结果（外加表示自身的 `self`），返回一个**约定命名**的属性集。Nix 的各个子命令认领其中对应的属性：

- `packages.<system>.<name>`：`nix build .#name` 的目标；
- `apps.<system>.<name>`：`nix run .#name` 的目标（`program` 字段为可执行路径）；
- `devShells.<system>.<name>`：`nix develop` 进入的开发环境；
- `checks.<system>.<name>`：`nix flake check` 求值并构建的检查项（测试放这里）；
- `nixosConfigurations.<主机名>`：`nixos-rebuild --flake .#主机名` 的入口（21.6 节）；
- `overlays.default`：暴露给其他 flake 消费的覆盖层（参见第 32-41 章 nixpkgs 部分）；
- `nixosModules` / `homeConfigurations`：可复用的 NixOS 模块 / home-manager 的主机配置（后者是社区生态约定，非 Nix 内建）；
- `templates`：`nix flake init -t` 可用的模板；
- `legacyPackages`、`formatter`、`lib` 等：工具与生态约定的其他出口。

用 `nix flake show`（21.5 节）可以把一个 flake 的这些出口全部列出来——它是理解陌生 flake 的第一站。对 21.3 节的模板，输出大致是一棵这样的树（示意）：

```console
$ nix flake show
├───apps
│   ├───aarch64-darwin
│   │   └───hello: app
│   └───x86_64-linux
│       └───hello: app
├───checks
│   └───x86_64-linux
│       └───smoke: derivation 'smoke-test'
├───devShells
│   └───x86_64-linux
│       └───default: development environment
├───nixosConfigurations
│   └───myhost: NixOS configuration
└───packages
    └───x86_64-linux
        ├───default: package 'example'
        └───example: package 'example'
```

最后厘清一个概念层次：flake 改变的是**求值与依赖管理**这一层，不改变构建本身——outputs 最终产出的仍是第 13 章意义上的普通 derivation，构建过程照旧走第 16 章的沙箱与调度。你可以把 flakes 理解为「给求值过程也装上了锁」：依赖是锁定的、求值是纯的、结果是可以缓存的，而 store 以下的一切原封不动。

## 21.3 flake.nix 逐行精讲

下面是一个多用途的完整模板：包、开发环境、NixOS 配置、overlay 各占一席。每一行都配了中文注释，建议对照 21.2 节的协议逐行读一遍：

```nix
{
  # 纯文档：flake show 与部分 UI 会展示它，给人看，机器不消费
  description = "我的通用工作台：包、开发环境与 NixOS 配置";

  # inputs：本 flake 的全部外部依赖，每个条目最终都会被锁进 flake.lock
  inputs = {
    # github:owner/repo/ref 形态：ref 可以是分支或标签，
    # 锁定后记录的是解析到的精确提交（rev），分支名只是「更新时的意图」
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # home-manager：管理用户级配置的 flake（生态中最常见的搭配之一）
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      # follows：把 home-manager 自己的 nixpkgs 输入重定向到「我们的」nixpkgs，
      # 保证整棵依赖树只有一份 nixpkgs——求值更快、闭包更干净（参见第 17 章）
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # flake = false（注意是单数 flake）：该仓库不是 flake（没有 flake.nix），
    # 只把它当普通目录用；outputs 里拿到的将是它在 store 里的路径
    priv-secrets = {
      url = "git+ssh://git@github.com/me/priv-dotfiles.git";
      flake = false;
    };

    # 工具库：为「多系统输出」省掉手写 genAttrs 的样板
    flake-utils.url = "github:numtide/flake-utils";
  };

  # outputs：flake 协议的实现；参数是各 inputs 的求值结果，外加 self
  outputs = { self, nixpkgs, home-manager, flake-utils }:
    # eachDefaultSystem：为 x86_64-linux、aarch64-darwin 等每个常见平台
    # 展开一份「与系统相关」的输出（packages、devShells、apps、checks）
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          # 把 flake 版 nixpkgs 变成该平台的 pkgs：
          # system 必须显式传入——纯求值没有「当前系统」这个默认值
          pkgs = import nixpkgs {
            inherit system;             # 把外层循环变量传进去
            config.allowUnfree = true;  # 例：允许非自由许可证软件
          };
        in
        {
          # packages.<system>.<name>：nix build .#example 的目标
          packages.example = pkgs.callPackage ./pkgs/example.nix { };

          # default：省略名字时的默认目标（nix build、nix run 都会用到）
          packages.default = self.packages.${system}.example;

          # devShells：nix develop 进入的环境（不写名字即 default）
          devShells.default = pkgs.mkShell {
            packages = [ pkgs.cargo pkgs.rustc ];  # 环境内可用的工具
          };

          # apps：nix run 的目标；program 必须是可执行文件的路径
          apps.hello = {
            type = "app";
            program = "${pkgs.hello}/bin/hello";
          };

          # checks：nix flake check 会求值并构建它们，冒烟测试的好位置
          checks.smoke = pkgs.runCommand "smoke-test" { }
            ''
              # 构建能成功且行为正确才算过：跑一下 hello 并断言输出
              ${pkgs.hello}/bin/hello | grep -q Hello
              touch $out
            '';
        })
    // {
      # 与平台无关的输出放在 eachDefaultSystem 之外，用 // 合并两部分结果

      # nixosConfigurations.<主机名>：nixos-rebuild --flake 的入口
      nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./hosts/myhost/configuration.nix          # 常规系统模块
          ./hosts/myhost/hardware-configuration.nix # 硬件扫描产物（21.6 节）
          home-manager.nixosModules.home-manager    # 直接接入别的 flake 的模块
        ];
      };

      # overlays：暴露给其他 flake 消费的覆盖层（nixpkgs 部分见第 32-41 章）
      overlays.default = final: prev: {
        my-tool = final.callPackage ./pkgs/example.nix { };
      };

      # nixosModules：供他人 NixOS 配置 import 的可复用模块
      nixosModules.default = import ./modules/my-module.nix;
    };
}
```

三个容易忽略的细节。其一，`self` 指本 flake 自身，可用 `self.outPath`（本 flake 源码在 store 里的路径）引用仓库内的其他文件。其二，inputs 不是「版本号」而是**依赖图的边**：每个 input 本身也可以是个 flake，有自己的 inputs，`follows` 就是在这棵树上做重定向。其三，`//` 把「按系统展开的输出」与「全局输出」合并成一个属性集——这是手写多用途 flake 的标准姿势。

## 21.4 flake.lock：锁文件解剖

首次对某个 flake 求值时，Nix 会解析所有可变引用（分支、注册表别名……），把结果写进 `flake.lock`。一个精简后的真实结构如下（哈希与提交号做了截节处理）：

```json
{
  "nodes": {
    "root": {
      "inputs": {
        "home-manager": "home-manager",
        "nixpkgs": "nixpkgs"
      }
    },
    "home-manager": {
      "inputs": {
        "nixpkgs": [ "root", "nixpkgs" ]
      },
      "locked": {
        "lastModified": 1767225600,
        "owner": "nix-community",
        "repo": "home-manager",
        "rev": "0123456789abcdef0123456789abcdef01234567",
        "type": "github"
      },
      "original": {
        "owner": "nix-community",
        "ref": "release-26.05",
        "repo": "home-manager",
        "type": "github"
      }
    },
    "nixpkgs": {
      "locked": {
        "lastModified": 1767225600,
        "owner": "NixOS",
        "repo": "nixpkgs",
        "rev": "0123456789abcdef0123456789abcdef01234567",
        "type": "github"
      },
      "original": {
        "owner": "NixOS",
        "ref": "nixos-26.05",
        "repo": "nixpkgs",
        "type": "github"
      }
    }
  },
  "root": "root",
  "version": 7
}
```

逐项解释各字段的职责：

- `version`：锁文件格式版本（当前为 7）。格式演进时 Nix 会拒绝读取不认识的版本，而不是误解它。
- `nodes`：依赖图的全部节点。`root` 节点代表 flake 本身，它的 `inputs` 列出顶层依赖，值是其他节点的名字（重复的输入名会自动加 `_2` 之类的后缀）。
- `inputs`（节点内）：该 flake 声明的依赖。注意 `home-manager` 的 nixpkgs 是一个**数组路径** `["root", "nixpkgs"]`——这正是 `follows` 在锁文件里的表示：「跟随 root 节点的 nixpkgs」，不占独立节点。
- `locked`：**锁定后的事实**——实际解析到了哪个提交（`rev`）、仓库是谁（`owner`/`repo`）、类型（`type`，如 `github`、`git`、`path`）、最后修改时间（`lastModified`，给人判断新旧用）；`path` 类型的源还会带 `narHash`（源码内容哈希，与第 15 章的固定输出思想同源）。
- `original`：**原始意图**——你在 flake.nix 里写的引用（如 `ref: "nixos-26.05"`）。更新时 Nix 按 `original` 重新解析出新的 `rev` 再改写 `locked`。这两个字段的分工就是「锁定」与「更新」互不干扰的关键。

**为什么锁文件必须进 git？**三个理由。第一，它是团队与 CI 复现同一依赖图的唯一凭据，不提交就回到了 channel 时代。第二，Nix 求值 flake 时读取的是 **git 快照**——未跟踪的文件对求值不可见（21.8 节的头号陷阱），新版 Nix 遇到未跟踪的 `flake.lock` 通常会直接报错并提示 `git add`。第三，代码评审时锁文件的 diff 让「这次升级动了哪些依赖」一目了然。

更新的两个姿势：

```console
$ nix flake update            # 按 original 重新解析并更新全部输入
$ nix flake update nixpkgs    # 只更新名为 nixpkgs 的这一个输入
```

按输入更新的写法有过演变：旧版 Nix 是 `nix flake lock --update-input nixpkgs`，自 Nix 2.22 起改为上面的 `nix flake update nixpkgs`（旧选项已移除）。不同版本的可用写法以官方手册为准。日常推荐只按需更新单个输入——全量更新把几十个依赖一起推向新提交，出问题时难以定位是哪一个引起的。

再送一个工程小技巧：`flake.lock` 是机器生成的 JSON，两个人同时改依赖就会产生 git 冲突。**不要手工解冲突**——任选一边保留（或干脆接受任意一方），再跑一次 `nix flake update` 让 Nix 重新生成。锁文件始终以「重新解析的结果」为准，手改既痛苦又容易把图改出坏边。

## 21.5 日常命令全集

以下命令均属新 CLI（`nix-command`），并假定已启用 flakes（21.7 节）。每个命令配两个示例。

先统一语法：`nixpkgs#hello` 这类写法读作「flake 引用 `#` 属性路径」。`#` 之前是 flake 的 URL（`nixpkgs` 是注册表别名，`.` 是当前目录，也可以是完整的 `github:...`）；之后是在该 flake 的 outputs 里导航的属性路径（`packages.<system>.hello` 这类前缀可以省略，系统名由 Nix 代入当前平台）。

**nix build**：构建 outputs 里的某个目标，产出符号链接 `./result`（参见第 14、18 章）。

```console
$ nix build nixpkgs#hello                  # 从注册表别名取 nixpkgs，构建 hello
$ nix build github:NixOS/nixpkgs/nixos-26.05#cowsay   # 远程仓库直接构建，不必本地克隆
```

**nix run**：构建并立即运行（apps 优先，其次 packages 里碰巧是可执行的目标）。

```console
$ nix run nixpkgs#cool-retro-term          # 临时跑一个程序，不安装进 profile
$ nix run .#hello                          # 运行本 flake 的 apps.hello
```

**nix develop**：进入 devShells 里声明的开发环境。

```console
$ nix develop                              # 进入当前 flake 的默认 devShell
$ nix develop -c cargo test                # 进入后在同一命令行里执行 cargo test 再退出
```

**nix shell**：把若干包装进一个临时 shell（比 devShell 轻，不需要预先声明环境）。

```console
$ nix shell nixpkgs#ripgrep                # 临时拿到 rg，exit 后消失
$ nix shell nixpkgs#jq nixpkgs#fd -c ./scripts/report.sh   # 为脚本一次性配齐工具
```

**nix flake show**：列出 flake 的全部出口（理解陌生 flake 的第一站）。

```console
$ nix flake show                           # 当前目录 flake 的 outputs 树
$ nix flake show github:nix-community/home-manager   # 远程 flake 同样可看
```

**nix flake check**：求值并构建 checks，同时对其他 outputs 做一致性检查（如 apps 的 program 是否真的存在）。

```console
$ nix flake check                          # 全量检查（会构建 checks）
$ nix flake check --no-build               # 只做求值层面的检查，适合快速验证 NixOS 配置
```

**nix flake init / new**：从模板起步。init 在当前目录生成，new 在新目录生成。

```console
$ nix flake init                           # 当前目录生成一个最小 flake.nix 模板
$ nix flake new ~/proj/demo -t templates#python   # 用官方模板库的 python 模板建新项目
```

**nix flake metadata**：查看 flake 与锁定的输入信息（解析到了哪个 rev、何时提交）。

```console
$ nix flake metadata                       # 本 flake 各输入的锁定情况
$ nix flake metadata nixpkgs               # 注册表别名当前指向什么（不含本地锁）
```

**nix flake update / lock**：更新与维护锁文件。

```console
$ nix flake lock                           # 只为「新增」的输入补锁，不升级已有条目
$ nix flake lock --override-input nixpkgs github:NixOS/nixpkgs/nixos-unstable
                                           # 临时换用另一个 nixpkgs 做测试（写入 lock）
```

**nix flake archive**：把 flake 的全部源码（含锁定输入）复制进 store，并可顺道推到缓存——CI 或离线分发时常用。

```console
$ nix flake archive --json | jq -r .path   # 打包进 store 并打印其路径
$ nix flake archive --to file:///var/nix-cache .   # 同时把 flake 源推到本地缓存
```

**nix profile install**：从 flake 安装进用户 profile（参见第 18 章）。

```console
$ nix profile install .#example            # 安装本 flake 构建的目标
$ nix profile install nixpkgs#ripgrep      # 等价于旧世界的 nix-env -iA，但走 flake 语义
```

**nix flake clone**：把一个远程 flake 的源码克隆到本地（走 git，不做求值）。

```console
$ nix flake clone nixpkgs                 # 克隆注册表别名当前指向的仓库
$ nix flake clone github:nix-community/home-manager --dest ~/src/home-manager
```

**纯度提示**：以上一切命令对 flake 的求值都遵守纯求值（pure evaluation）规则——**不读你的环境**。具体表现：`builtins.getEnv` 不可用（或返回空）；不能读 flake 目录之外的文件；没有隐式的「当前系统」（system 必须显式传递）；`NIX_PATH` 被忽略，尖括号 `<nixpkgs>` 语法失效。21.1 节的三个雷，在这里被逐个拆掉。个别场景确需豁免时可用 `--impure`，其滥用警告见 21.8 节。

## 21.6 NixOS 上的 flakes

flake 化的 NixOS 配置，入口是 `nixos-rebuild` 的 `--flake` 参数：

```console
# 在 flake 仓库根目录执行；行首的 # 是 root 提示符，
# 而 .#myhost 里的 # 是 flake 语法（flake 引用与属性名之间的分隔符），别混淆
# nixos-rebuild switch --flake .#myhost
```

这条命令的解析过程值得逐步看清：

1. **定位 flake**：`.` 表示当前目录的 `flake.nix`（若省略 `#myhost`，则用当前主机名匹配 `nixosConfigurations`）；
2. **读取/生成锁**：读 `flake.lock`，缺失的输入会当场解析并写入；
3. **求值**：计算 `nixosConfigurations.myhost.config.system.build.toplevel`——这正是 21.3 节模板里 `nixpkgs.lib.nixosSystem` 造出来的那个属性；
4. **构建**：与其他构建一样先问二进制缓存，未命中才本地构建（参见第 16、20 章）；
5. **激活**：切换系统并注册新的 generation（参见第 18 章）。

不想直接切换系统时，可以先「只构建」或「构建并试激活」：

```console
$ nix build .#nixosConfigurations.myhost.config.system.build.toplevel
# 上述解析链的第 1-4 步：只构建 toplevel，不切换；
# 适合验证配置能否求值、构建是否能过
$ nixos-rebuild test --flake .#myhost
# 激活新配置但不设为默认启动项（generation 语义参见第 18 章）
```

**hardware-configuration 的配合**。安装时 `nixos-generate-config` 扫描硬件生成 `hardware-configuration.nix`（文件系统、内核模块、导入的硬件模块）。flake 化的常见做法是把它拷进仓库（如 `hosts/myhost/hardware-configuration.nix`），作为模块放进 `nixosSystem` 的 `modules` 列表（21.3 节模板正是如此）。它是「每台机器各不相同」的部分，与放之四海皆准的公共模块分开存放；迁移到新机器时重新生成一份即可。注意它必须像其他文件一样被 git 跟踪，否则对求值不可见。

**旧 channel 与 flake 并存期的常见混乱**。flake 化不会自动清除 channel 世界，两套机制在过渡期共存，典型事故是：系统明明锁定了 nixos-26.05，某个包却来自 unstable。原因往往是某个模块或教程代码里残留了 `import <nixpkgs>`——`NIX_PATH` 在 NixOS 上默认仍存在，尖括号会解析到 channel 版的 nixpkgs，绕开你的锁文件。一个常用的兼容技巧：

```nix
# 让 <nixpkgs> 解析到注册表里的 nixpkgs flake
# 注意：这解析到的是「注册表的 nixpkgs」，并不自动等于你锁定的那个输入；
# 精确的做法是把 input 显式接进模块（如通过 extraArgs/specialArgs 传 pkgs）
nix.nixPath = [ "nixpkgs=flake:nixpkgs" ];
```

另一个方向的心智负担：`nix-channel --update` 与 `nixos-rebuild --upgrade` 只影响 channel 轨道，对 flake 化的重建**毫无作用**——flake 轨道的更新只有 `nix flake update`（或 git pull 你自己的仓库）。两条轨道并行时，先想清楚自己此刻站在哪条上。

## 21.7 实验状态的诚实说明

必须诚实面对的事实：flakes 自 Nix 2.4（2021 年）引入起，至今（Nix 2.35、2026 年中）仍标记为**实验特性（experimental feature）**。「实验」的准确含义是：语法、命令行为与锁文件格式**不承诺稳定**，理论上可能在后续版本调整，且默认不启用。

启用需要同时打开两个实验开关（它们是两个独立特性）：`nix-command`（新命令行界面，即本章用到的 `nix build` 等命令）与 `flakes`（flake 相关语法与内建函数）。常用的三处开关位置：

```nix
# 位置一（推荐，NixOS）：系统级声明式配置，进入 configuration.nix
nix.settings.experimental-features = [ "nix-command" "flakes" ];
```

```bash
# 位置二（多用户安装）：写入 /etc/nix/nix.conf，对守护进程与所有用户生效
# 单用户个人偏好则用 ~/.config/nix/nix.conf
experimental-features = nix-command flakes
```

```console
# 位置三（临时/CI）：命令行即时附加，或用环境变量 NIX_CONFIG 携带同样内容
$ nix --extra-experimental-features "nix-command flakes" flake show
```

配置之后可以随时确认开关状态：

```console
$ nix show-config | grep experimental-features
# experimental-features = flakes nix-command   ← 生效即如此
```

CI 环境的惯用法是不落任何文件、用环境变量注入同一份配置：

```console
$ export NIX_CONFIG='experimental-features = nix-command flakes'
```

那为什么一个「实验特性」成了事实标准？因为生态用脚投票：nixpkgs 的文档与搜索服务、home-manager 等主流项目、几乎全部近年教程与新公司实践都围绕 flakes 展开；channel 路径虽仍可用，但已是「遗留模式」的待遇。这种「官方实验、民间标准」的张力正是社区关于 flakes 争论不休的根源。官方的稳定化（stabilization）工作一直在推进（拆分为若干更小的设计议题逐步收敛），但截至本书写作没有给出落地时间表——**当前状态请以官方公告为准**，本章描述的具体命令行为在细节上也可能随版本微调，以官方手册为准。

## 21.8 最佳实践与陷阱

**陷阱一：git 树里未 add 的新文件对 flake 不可见（最常见！）**。flake 的求值对象是 git 快照，未跟踪（untracked）的文件等于不存在：

```console
$ nix build .#example
error: … '/nix/store/…-source/pkgs/example.nix' … No such file or directory
```

明明文件就在仓库里，为什么报「不存在」？因为 Nix 读的是 git 眼中的仓库，而 git 还不认识它。修复：

```console
$ git add pkgs/example.nix   # 让 git 看见它
# 开发期的偷懒变体：git add -N（intent-to-add），内容仍可随时改动
```

这个陷阱还会以更隐蔽的形式出现：改了文件但行为不变（改的是未跟踪文件）、`hardware-configuration.nix` 拷进来忘了 add、CI 上构建失败本地却正常（本地有未跟踪文件参与求值的情况相反——本地**多**了 git 快照里没有的东西）。

**陷阱二：不要 import 未锁定的东西**。flake 的保证只覆盖 `inputs` 声明的依赖。任何绕开 inputs 的获取都是漏洞：

```nix
# 反例：在 flake 里用 fetchTarball 引入「另一个 nixpkgs」
# 它不进 flake.lock，每次求值都可能解析到不同内容，锁文件形同虚设
# let pkgs = import (builtins.fetchTarball
#   "https://github.com/NixOS/nixpkgs/archive/master.tar.gz") {};
```

正确做法永远是声明为 input（需要固定时再 `flake = false` + narHash）。同理，谨慎对待别人 flake 里出现的这类写法——它意味着该 flake 的「可复现」承诺有例外。

**陷阱三：多系统输出要写对**。`packages` 等输出按 `system` 分层，漏了你的平台就会出现「明明有这个包却 `nix build` 报找不到」的怪象。手写法与工具法：

```nix
# 手写：为列出的每个平台生成一份输出
let
  systems = [ "x86_64-linux" "aarch64-darwin" ];
  forAllSystems = nixpkgs.lib.genAttrs systems;
in
{
  packages = forAllSystems (system: {
    hello = import nixpkgs { inherit system; } .hello;  # 仅为示意的取包写法
  });
}
```

实践中更常见的是 21.3 节用的 `flake-utils.lib.eachDefaultSystem`，或 `flake-parts`（把 flake 输出组织成模块的社区框架），任选其一，避免手写样板。

**陷阱四：`--impure` 的滥用警告**。`nix build --impure`、`nix develop --impure` 会放开纯求值的限制（读环境变量、读 flake 外的文件……）。它偶尔是正当的（一次性脚本、需要读宿主信息的开发环境），但把 `--impure` 固化进日常工作流，等于亲手拆掉 21.1 节痛陈的三项保证：你的构建只在你的机器上成立，CI 与同事无法复现。遇到「必须 impure」的需求时，正确的方向通常是：把数据做成 flake 内的文件、声明成 input、或用 overlay 处理——让信息进入依赖图，而不是从依赖图外偷渡。

**小结性的最佳实践**：锁文件必进 git 且勤于评审其 diff；升级输入按个更新（`nix flake update <input>`）而非全量；`nix flake check` 纳入 CI；仓库里的每个文件都要么被 git 跟踪、要么明确不参与求值——把这四条变成习惯，flakes 的「可复现」承诺才真正属于你。

## 21.9 本章小结

- channel 时代的三宗罪：`<nixpkgs>` 解析依赖环境、没有锁文件、git 仓库无法直接作依赖源；flakes 用「源即依赖 + 锁文件 + 纯求值」逐一对症下药。
- flake 是含 `flake.nix` 的目录（通常是 git 仓库）；URL 形态包括 `github:owner/repo[/ref]`、`git+file:`、`path:` 与注册表别名（如裸 `nixpkgs`）；它只改变求值与依赖管理层，产出的仍是普通 derivation。
- outputs 是一份协议：函数接收 inputs 与 `self`，返回约定命名的属性——`packages`、`apps`、`devShells`、`checks`、`nixosConfigurations`、`overlays`、`nixosModules` 等，各命令各认各的出口。
- `flake.lock` 用 `nodes`/`locked`/`original`/`root`/`version` 把「锁定的事实」与「更新的意图」分开记录；`follows` 在锁里表现为跨节点路径数组；冲突不要手解，重新生成为准。
- 锁文件必须进 git：它是团队与 CI 复现的凭据，且 Nix 从 git 快照求值，未跟踪文件（包括锁本身）对求值不可见。
- 更新用 `nix flake update [input]`（旧版 `--update-input` 已淘汰）；推荐按输入增量更新而非全量。
- 日常命令：build/run/develop/shell 五件套加 `nix flake show/check/init/new/metadata/update/lock/archive/clone` 与 `nix profile install .#pkg`；flake 求值是纯的：不读环境、不读外部文件、忽略 `NIX_PATH`。
- NixOS 集成的解析链：找 flake→读锁→求值 `nixosConfigurations.<主机名>`→构建 toplevel→激活；过渡期警惕 `<nixpkgs>` 经 `NIX_PATH` 把 channel 版 nixpkgs 偷渡进来；flakes 自 2.4 起长期实验状态（三处开关启用 `nix-command` 与 `flakes`），稳定化以官方公告为准；两大高频陷阱是未 `git add` 的文件对 flake 不可见、import 未锁定的来源击穿锁保证，`--impure` 是逃生门而非日常门。

## 延伸阅读

- Nix 官方手册：Flakes 章节（flake 引用语法、协议与命令细节）：<https://nixos.org/manual/nix/stable/flakes>
- Nix 官方手册：`nix flake` 命令参考：<https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-flake>
- nixos.org Wiki：Flakes <https://wiki.nixos.org/wiki/Flakes>
- nix.dev 概念页：Flakes <https://nix.dev/concepts/flakes>
- Zero to Nix（Determinate Systems 的入门教程）：<https://zero-to-nix.com>
- 官方 flake 模板库：<https://github.com/NixOS/templates>
