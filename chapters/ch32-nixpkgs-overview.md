# 第 32 章 nixpkgs 仓库全景与组织思想

> **本章导读**：nixpkgs 是地球上最大的软件仓库之一——一个 git 仓库描述着十万级软件包与整个 NixOS，没有一名专职员工。本章回答：它的目录如何组织；`pkgs.hello` 这个属性是怎么「求值」出来的（callPackage 与自举）；分支如何变成你机器上的 channel/flake 输入。第 33-38 章将深入它的构建设施与真实包源码。

## 32.1 一个仓库统治一切

传统发行版里「包仓库」「发行版配置」「构建农场配置」分属多处；nixpkgs 的哲学是**单一仓库（monorepo）**：

- 全部软件包定义（`pkgs/`）；
- 全部 NixOS 模块与发行版机制（`nixos/`）；
- 标准库 `lib/`；
- 文档、测试、CI 配置。

收益：原子性（升级一个库与重建它的十万下游在同一次提交里被求值）、一致性（任何一台 Hydra 构建的全量结果可复用为 channel）、以及「fork 一个仓库 = fork 整个世界」的定制能力（第 39 章 overlays 与 fork 工作流）。代价：仓库巨大（clone 全历史数 GB；✅ 现代做法是浅克隆 `--depth 1` 或用 GitHub 的 tarball）。

## 32.2 仓库结构地图

```
nixpkgs/
├── pkgs/                       ★ 全部软件包
│   ├── by-name/                ✅ 新式：一个包一个目录（RFC 140）
│   │   ├── he/hello/package.nix
│   │   ├── ri/ripgrep/package.nix
│   │   └── fz/fzf/package.nix
│   ├── applications/           ⚠️ 传统目录：按类别（旧包的存量，逐步迁移中）
│   ├── development/libraries/  # C/C++ 库等
│   ├── development/compilers/  # gcc、llvm、rust ...
│   ├── development/python-modules/  # Python 库（不同于 by-name 的存量布局）
│   ├── servers/  os-specific/  tools/  test/ ...
│   ├── build-support/          ★ 构建器与 fetcher 家族（第 15、35 章）
│   │   ├── fetchurl/  fetchFromGitHub 在 lib? （fetchers 集中地）
│   │   ├── buildenv/  docker/  appimage/  buildFHSEnv/  trivial-builders/
│   │   └── rust/  go/  python? （语言生态 builder 的实现地）
│   ├── stdenv/                 ★ 标准构建环境（第 33 章）
│   ├── top-level/              ★ 装配层：pkgs 集合的诞生地
│   │   ├── all-packages.nix    # 「总目录」：传统包在这里注册
│   │   ├── splice.nix          # 交叉编译的拼接机制（第 40 章）
│   │   └── stage*.nix          # stdenv 自举的各阶段
│   └── os-specific/linux/kernel/ # 内核打包（第 38 章）
├── nixos/                      ★ 发行版
│   ├── modules/                # 全部 NixOS 模块（第 25 章）
│   │   └── module-list.nix     # 模块注册表
│   ├── tests/                  # NixOS VM 测试（第 41 章）
│   └── lib/eval-config.nix     # nixosSystem 入口
├── lib/                        ★ Nix 标准库（第 7、10、12 章）
│   ├── default.nix  attrsets.nix  lists.nix  strings.nix  trivial.nix ...
├── doc/  maintainainers? → maintainers/scripts  pkgs/maintainers? # 文档与维护者
│   （维护者名单：pkgs/maintainers/scripts? 实际位于 maintainers/ 目录）
├── flake.nix                   # 作为 flake 输入时的入口（legacyPackages/...）
├── default.nix                 # channel 时代入口（import <nixpkgs>）
└── .github/  ci  ofborg 配置    # CI 与机器人（第 41 章）
```

## 32.3 by-name：RFC 140 与包注册的新旧世界

**旧世界（存量）**：包放进类别目录（`pkgs/applications/misc/hello/default.nix`），并要在 `pkgs/top-level/all-packages.nix` 手工加一行 `hello = callPackage ../applications/misc/hello { };`。类别归属靠人猜，「改两个文件」是提包的固定成本。

**新世界（✅ 2023 年 RFC 140 起，所有新包必须）**：

```
pkgs/by-name/<名前两字母>/<包名>/package.nix
```

- 文件名固定 `package.nix`，目录名即包名（属性名自动等于目录名，**无需改 all-packages.nix**）；
- 目录必须**自包含**（不得引用目录外的文件——补丁、脚本都放本目录）；
- 机器人（ofBorg）自动校验结构与命名。

两种方式最终都汇入同一个 `pkgs` 集合；`pkgs.hello` 无论哪种注册方式，得到的是同一个对象。本书第 36-38 章的实例全部选自 by-name 世界。

## 32.4 `pkgs` 是怎么求值出来的：callPackage 与自举

这是理解 nixpkgs 机制的核心一节。

### 32.4.1 callPackage：依赖的自动注入

第 7 章埋的伏笔在此兑现。每个包是一个「按名索求依赖的函数」：

```nix
# pkgs/by-name/he/hello/package.nix（骨架）
{
  lib,
  stdenv,
  fetchurl,
}:
stdenv.mkDerivation (finalAttrs: { ... })
```

`callPackage f` 的定义（概念）：

```nix
callPackage = f: args:
  f (builtins.intersectAttrs (builtins.functionArgs f) pkgs // args);
#   ↑ 只取「f 声明了的形参」对应的包属性，注入给 f
#     多余的 pkgs 属性不会传（这就是 ... 省略号不报错的原因）
```

于是：**加依赖 = 在函数头加一个形参**；**换依赖 = `.override` 按名重供**（第 39 章）。依赖图的「接线」完全声明化——没有 apt 那样的「包名解析+版本求解」运行期过程，一切在求值期静态展开。

### 32.4.2 自引用的包集合：lib.fix 的现实应用

`pkgs` 里的包互相依赖（gcc 需要的 glibc 也由本集合提供）。装配层（all-packages.nix）的结构（概念化，真实代码是分层 stage 的）：

```nix
pkgs = lib.fix (self:
  let
    callPackage = self.callPackage;   # stdenv 提供的机制，随自举阶段增强
  in
  {
    # 旧世界注册样例（真实文件里有上万个条目）
    glibc = callPackage ... ;
    gcc = callPackage ... ;
    # by-name 目录会被自动扫描合并进来（RFC 140 的机制）
  })
# lib.fix：包集合可以引用自己（pkgs.gcc 的构建依赖里可以写 pkgs.glibc），
# 惰性求值保证按需展开、无环可用（第 7、11、25 章）
```

### 32.4.3 自举链（bootstrap）：鸡生蛋问题

`stdenv`（编译器与核心工具）自己是怎么被构建的？答案是一条多阶段链（`pkgs/top-level/stage*.nix`，概览即可，细节在 stdenv 源码）：

```
stage 0：发行版自带/预编译的 bootstrap 工具（如 glibc+gcc 的静态二进制）
stage 1：用 stage 0 构建 glibc、新的 gcc
stage 2：用 stage 1 重建 glibc、gcc（消除对 bootstrap 二进制的依赖）
……最终 stage N：干净、自洽的 stdenv，开始构建世界
```

这就是 nixpkgs 极高可复现性的根源：**连工具链本身都是仓库定义构建的**（配合 binary cache 不用真的从零编译，第 20 章）。

## 32.5 分支、通道与你的机器

```
master（每日千次合并）
  ├── staging（大量重建的缓冲区，定期晋升回 master）
  ├── staging-next（staging 的验证层）
  └── release-26.05（稳定分支：只收 bugfix/安全修复）
        │ Hydra 全量构建 release-26.05
        ▼ 通过率达标（第 41 章闸门）
      channel：nixos-26.05（tarball+缓存快照）
        │ 你的机器 nix-channel --update / flake.lock 更新
        ▼
      本机 nixpkgs 副本 → 求值出你的系统
```

三个用户可见的「版本流」：

1. **stable**（`nixos-26.05` / flake 里 `github:NixOS/nixpkgs/nixos-26.05`）：保守，适合生产与求稳；
2. **unstable**（`nixos-unstable` / `github:NixOS/nixpkgs/nixos-unstable`）：滚动，适合桌面与开发机（本书多数示例的隐含环境）；
3. **锁定提交**（flake 里 pin 到具体 rev）：可复现的终极形态，生产 flake 的标准做法。

## 32.6 贡献流程鸟瞰

第 41、42 章有全流程实战；此处给心理地图：fork → 分支改动 → `nixfmt` 格式化 → PR → ofBorg 自动求值/构建检查 → 维护者评审（包的 `meta.maintainers` 会被 ping）→ merge（maintainer 有自行 merge 权限的通道）→ Hydra 构建 → 进入 unstable → backport 到 release 分支 → 顺流进入下一个 stable。

## 32.7 版本与兼容策略

- **unstable 里没有版本承诺**：包版本随上游滚动；breaking change 常态存在。
- **stable 只进修复**：安全补丁与重要 bugfix 从 unstable backport。
- **alias 机制**：改名的包保留 `meta.unknown? alias`（`lib.alias`? 实际机制为 `pkgs` 上的 alias 属性 + 警告），给下游迁移期；最终会被清理。
- **mass-rebuild 语义**：改动 glibc/gcc/python 这类基础包会触发全仓库重建 → 必须走 staging 分支（第 42 章规则）。

## 32.8 本章小结

- nixpkgs = 包 + 发行版 + 标准库的 monorepo；新包一律 by-name（RFC 140），旧类别目录是存量。
- `callPackage` 按 `functionArgs` 自动注入依赖：包定义的函数头就是依赖提货单；`pkgs` 是 lib.fix 出的自引用集合。
- stdenv 经多阶段自举，工具链本身由仓库定义。
- 分支河流：master/staging → release-YY.MM → Hydra → channel/flake 锁定 → 你的机器。
- 用户三选择：stable（稳）、unstable（新）、锁定 rev（可复现）。

## 延伸阅读

- nixpkgs 手册（贡献与结构的一手文档）：https://nixos.org/manual/nixpkgs/unstable/
- RFC 140（by-name）：https://github.com/NixOS/rfcs/blob/master/rfcs/0140-simple-package-paths.md
- 第 33 章（stdenv）与第 34 章（mkDerivation）进入构建设施内部。
