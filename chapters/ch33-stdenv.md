# 第 33 章 stdenv：标准构建环境

> **本章导读**：第 13 章的裸 `derivation` 等于「给你一个 bash 和一个空目录」；真实的包需要的是：解压、打补丁、configure、make、安装、修复引用……stdenv 就是把这套 Unix 构建通用流程**框架化**的构建环境。本章讲清它的构成（工具链 + setup.sh + phases + hooks）、每个 phase 的默认行为、以及环境变量如何把依赖注入构建。第 34 章的 mkDerivation 只是它的一层友好封装。

## 33.1 stdenv 是什么

`stdenv`（standard environment）是 nixpkgs 中所有「编译型」包的公共地基，一个属性集，包含：

1. **工具链**：gcc/g++（或 clang）、binutils、coreutils、gnused、gnumake、bash、patch、patchelf……——构建一个 autotools/cmake 包所需的全套 Unix 工具；
2. **构建框架**：`setup.sh`——一个被当作 builder 执行的 shell 框架，实现了「分阶段构建」；
3. **工厂函数**：`stdenv.mkDerivation`（第 34 章）；
4. **元信息**：`stdenv.cc`、`stdenv.hostPlatform` 等（交叉编译与诊断用，第 40 章）。

自举链（第 32 章）保证 stdenv 的每个组件本身也是 nixpkgs 构建的——不存在「从系统借来的 gcc」。

## 33.2 setup.sh：phases 体系

当 mkDerivation 生成的派生开始构建时，实际执行的命令大致是：

```
bash -e /nix/store/...-stdenv/setup <派生名>
```

setup.sh 做三件事：准备环境（PATH、编译器旗标、依赖变量）→ 按顺序执行各 **phase** → 每个阶段前后调用注册的 **hook**。

### 33.2.1 phases 全景（顺序即执行序）

| Phase | 默认行为 | 常用覆盖点 |
|-------|----------|-----------|
| `unpackPhase` | 解压 `$src` 到当前目录（支持 tar/zip/git 快照） | `postUnpack`、`sourceRoot`、`setSourceRoot` |
| `patchPhase` | 应用 `patches` 列表（patch -p1） | `postPatch`（sed/替代脚本的主场） |
| `configurePhase` | 跑 `./configure --prefix=$out`（或 cmake/meson 由 hook 自动接管） | `configureFlags`、`preConfigure` |
| `buildPhase` | `make -j$NIX_BUILD_CORES` | `buildFlags`、`preBuild`、`dontBuild` |
| `checkPhase` | `make check`（默认跳过，除非 `doCheck`） | `checkFlags`、`disabledTests`（语言生态 builder 有各自的约定） |
| `installPhase` | `make install` | `installFlags`、`postInstall` |
| `installCheckPhase` | 安装后自检（默认跳过，`doInstallCheck` 开启） | `installCheckPhase`、versionCheckHook |
| `fixupPhase` | **Nix 特有的修复阶段**（见 33.4） | `postFixup` |
| `distPhase` | 打源码分发包（罕用） | |

覆盖的两种方式（✅ 都常用）：

```nix
# ① 追加式（最常见）：phase 结束后追加自己的命令
postInstall = ''
  install -Dm644 README.md $out/share/doc/README.md
'';

# ② 整体替换（少用，慎用）：替换整个 phase
installPhase = ''
  runHook preInstall        # 惯例：保留 hook 调用
  mkdir -p $out/bin
  cp mybin $out/bin/
  runHook postInstall
'';
```

⚠️ 覆盖整个 phase 时保留 `runHook preXxx/postXxx` 调用——hook 体系（33.3）依赖它们。

### 33.2.2 一个包的构建旅程示例

以第 36 章将精讲的 figlet 为例，构建日志（`nix build -L` 可见）依次是：

```
unpacking sources
patching sources
configuring
no configure script, doing nothing        # figlet 是纯 Makefile 包
building
build flags: -j16 ...
running tests
installing
post-installation fixup
shrinking RPATHs of ELF executables and libraries in /nix/store/...-figlet-2.2.5
checking for references to /build/ in /nix/store/...   # 防泄漏检查
```

每一行对应一个 phase 或 fixup 步骤——从此你读构建日志不再是对着黑盒。

## 33.3 hooks：无侵入的扩展点

Hook 是「满足条件就自动生效」的 shell 函数/脚本。nixpkgs 用 hook 实现「加一个 nativeBuildInputs 就改变行为」的魔法：

| 你加进 nativeBuildInputs 的 | 自动发生什么 |
|------------------------------|--------------|
| `cmake` / `ninja` | configurePhase 改跑 `cmake`，build 用 ninja |
| `meson` + `ninja` | 同上（mesonSetupHook/mesonCheckHook） |
| `pkg-config` | configure 能解析 `.pc`，`PKG_CONFIG_PATH` 按依赖展开 |
| `autoconf`/`automake` 等 autoreconfHook | configure 前自动 `autoreconf -fi` |
| `installShellFiles` | 提供 `installShellCompletion`/`installManPage` 命令 |
| `versionCheckHook` | installCheck 自动验证 `--version` 与 `version` 一致 |
| `writableTmpDirAsHomeHook` | 交叉场景设 HOME（第 37 章 ripgrep 用到 wine 时） |
| 各语言的 `*SetupHook` | 展开该语言的依赖变量（如 Python 的 NIX_PYTHONPATH） |

机制：每个 hook 包在被解包到构建环境后，向 `preXxxHooks`/`postXxxHooks` 注册函数；phase 执行时 `runHook` 依序调用。**这就是「声明依赖=改变构建行为」的实现层**——你永远不用改构建脚本本身。

## 33.4 fixupPhase：Nix 特色的收尾

构建脚本来自「假设 FHS 世界」的传统软件，产物常带着不符合 Nix 模型的杂质。fixupPhase 自动清理：

1. **shebang 修复**：`#!/bin/bash` → `#!/nix/store/...-bash/bin/bash`；`#!/usr/bin/env python` → 指向 store 里的确切 python（这就是 NixOS 上脚本「自带解释器」的原理）；
2. **RPATH 修补**：给 ELF 可执行文件/库设置指向依赖的 store 路径（`patchelf --set-rpath`）——运行期定位库靠它而非 `/etc/ld.so.conf`（第 17 章伏笔回收）；
3. **strip**：删除调试符号（`dontStrip = false` 默认；闭包瘦身）；
4. **`/build` 引用检查**：产物里若残留构建目录路径（污染与泄漏）→ 报错拦截；
5. **move-docs / move-systemd-units** 等按 outputs 分拣（33.5）。

观察一个真实二进制：

```console
$ head -1 $(nix build nixpkgs#figlet --print-out-paths)/bin/figlet
#!/nix/store/...-bash/bin/bash          # ← fixup 修过的 shebang（figlet 是脚本包装? 以实际为准）
$ patchelf --print-rpath $(nix build nixpkgs#ripgrep --print-out-paths)/bin/rg
/nix/store/...-pcre2-10.x/lib           # ← fixup 写入的 RPATH
```

## 33.5 多输出的分拣

outputs 声明的各输出（第 13、34 章）在 install 之后由 fixup 阶段的 `moveToOutput` 系列分拣：

- `moveToShare`/`moveToDev`：man/info → `man`/`doc`，头文件与 `.pc` → `dev`；
- `propagatedBuildInputs` 的 dev 部分自动记入 `dev` 输出的引用（保证链接时能找到，但不进运行闭包——第 17 章「闭包瘦身」的实现细节）。

## 33.6 环境变量：依赖如何注入构建

stdenv 把依赖「展开」为构建环境变量（这就是第 13 章「多余属性变环境变量」框架化后的样子）：

```bash
# 构建脚本内可见（示例）：
$out                       # 本包输出路径
$srcs / $src               # 源（fetcher 产物路径）
PATH=/nix/store/...-gcc/bin:/nix/store/...-binutils/bin:...   # 工具链+native 依赖的 bin
NIX_CFLAGS_COMPILE         # gcc 注入旗标（-I 来自 buildInputs 的 include）
NIX_LDFLAGS                # 链接旗标（-L 来自 buildInputs 的 lib）
PKG_CONFIG_PATH            # 由 pkg-config hook 展开（.pc 目录）
CMAKE_PREFIX_PATH          # 由 cmake hook 展开
configureFlags             # mkDerivation 参数原样落地
```

理解要点：**nativeBuildInputs 与 buildInputs 的本质区别就是「进入哪个变量」**——前者进 PATH（构建时执行的程序），后者进 -I/-L（链接的目标）。这个区分在交叉编译时变成硬规则（第 40 章），第 34 章有判定口诀。

## 33.7 自定义与调试旋钮（速查）

```nix
# 行为开关（dont* 家族）
dontBuild = true;          # 纯安装型包跳过 make
dontConfigure = true;
dontStrip = true;          # 保留符号（调试场景）
doCheck = true;            # 开测试（默认关！）
doInstallCheck = true;     # 开安装后自检

# 调试
strictDeps = true;         # ✅ 推荐：依赖声明必须精确（见第 34 章）
__structuredAttrs = true;  # ✅ 现代：参数以 JSON 传递，突破环境变量限制
NIX_DEBUG = 6;             # setup.sh 打印每个变量与决策（写在 env 里）
```

命令行侧：`nix build -L`（实时日志）、`--keep-failed`（保留构建目录现场，进 `/tmp/nix-build-*`）、`nix develop`（进同一个环境手工重放，第 42 章实战演示）。

## 33.8 本章小结

- stdenv = 工具链 + setup.sh 框架 + mkDerivation 工厂；全部组件自举自 nixpkgs。
- phases 顺序：unpack → patch → configure → build → check → install → installCheck → **fixup** → dist；追加用 postXxx，整体替换要保留 runHook。
- hooks 实现「加依赖即改行为」：cmake/meson/pkg-config/versionCheck 等各就各位。
- fixupPhase 是 Nix 特色收尾：shebang 重写、RPATH 修补、strip、/build 泄漏检查、outputs 分拣。
- 依赖以环境变量注入：nativeBuildInputs→PATH，buildInputs→-I/-L；strictDeps 与 __structuredAttrs 是现代规范。

## 延伸阅读

- nixpkgs 手册 «stdenv» 章节（phase 与变量的权威文档）：https://nixos.org/manual/nixpkgs/unstable/#part-stdenv
- 源码：pkgs/stdenv/generic/setup.sh（千行 bash，通读一遍胜过十篇教程）
- 第 34 章把视角换成 mkDerivation 的参数表。
