# 第 36 章 简单包实例精讲（逐行注释）

> **本章导读**：从本章起，我们进入 nixpkgs 真实源码。三个「简单包」实例覆盖三条最常见路线：GNU hello（autotools 教科书）、figlet（裸 Makefile 补丁流）、平凡构建器自制小包（不写一行 C 代码的打包）。每个实例的结构相同：**完整源码（逐行中文注释）→ 求值与构建过程复盘 → 该实例教给我们的通用经验**。源码取自 nixpkgs master 分支 2026-08 快照，个别平台分支略有精简（以仓库为准）。

## 36.1 实例一：GNU hello——nixpkgs 的「Hello World」

GNU hello 本体只是一个打印问候的程序，但它是 nixpkgs 的图腾：第一个被所有人用来验证工具链的包。位于 `pkgs/by-name/he/hello/package.nix`。

### 36.1.1 完整源码逐行注释

```nix
{                                     # ── 函数头：本包的「依赖提货单」（第 7.3 节）
  lib,                                # nixpkgs 标准库：licenses/maintainers/platforms、optionalString 等
  stdenv,                             # 标准构建环境：本包的构建器来源（mkDerivation）
  fetchurl,                           # 下载器（第 15 章）：GNU 镜像取源码
  versionCheckHook,                   # 测试钩子（第 33 章）：自动校验 --version 输出
  testers,                            # 测试设施（第 41 章）：passthru.tests 用
}:                                    # ← 注意尾逗号：nixfmt-rfc-style 的标准样貌（RFC 166）

stdenv.mkDerivation (finalAttrs: {    # ── finalAttrs 模式（第 7.5.2 节）：现代写法的标志
  pname = "hello";                    # 包名（与 version 分离：机器可读，override 友好）
  version = "2.12.3";                 # 版本；输出路径将为 ...-hello-2.12.3

  src = fetchurl {                    # 源码 = 固定输出派生：哈希声明 + 镜像速记
    url = "mirror://gnu/hello/hello-${finalAttrs.version}.tar.gz";
    #  ↑ mirror://gnu 自动在 GNU 镜像组里轮询（第 15.3.1 节）
    #  ↑ ${finalAttrs.version}：引用「最终态」的版本——overrideAttrs 改版本时
    #    URL 自动跟随（finalAttrs 的核心价值，第 7 章）
    hash = "sha256-jZkUKv2SV28wsM18tCqNxoCZmLxdYH2Idh9RLibH2yA=";
    #  ↑ SRI 格式（第 15.4 节）：✅ 现行规范（旧式 base32 的 sha256= 已淘汰）
  };

  __structuredAttrs = true;           # ✅ 现代：参数以 JSON 传给构建器而非环境变量
                                      #   （第 34.9 节三件套之一；新包标配）

  strictDeps = true;                  # ✅ 现代：依赖显式化，交叉编译正确（第 34.4 节）

  # ── 平台差异（原文件含更多分支，此处保留主干语义）：
  #   Cygwin 平台需打 gnulib 的 memcpy 声明补丁（patches 列表按平台条件附加）
  #   Darwin 平台因 configure 探测到 libiconv 却未链接 → NIX_LDFLAGS = [ "-liconv" ]
  #   FreeBSD 平台把 gettext 加进 buildInputs
  #   （写法均为 lib.optionalString / lib.optionals 的标准组合，第 12 章）

  doCheck = true;                     # 开启 make check（nixpkgs 默认关，需显式开）
  doInstallCheck = true;              # 开启安装后自检（下一行的钩子就在这时跑）

  nativeInstallCheckInputs = [ versionCheckHook ];
  #  ↑ 安装期自检的 native 依赖：hook 在 installCheckPhase 校验
  #    `hello --version` 输出 == finalAttrs.version（防止「装好了但版本不对」）

  passthru.tests = {                  # passthru：不参与构建的附加属性（第 34.8 节）
    version = testers.testVersion {   # Hydra 会构建这些测试（第 41 章），提升包质量
      package = finalAttrs.finalPackage;   # 「最终形态的包自己」——override 后测试同步
    };
    run = ./test.nix;                 # 一个 NixOS VM 测试：真的把包装进系统跑一遍
  };

  meta = {                            # ── 元数据：搜索、授权、平台的对外接口
    description = "A program that produces a familiar, friendly greeting";
    longDescription = ''              # nix search / 网站上展示的详述
      GNU Hello is a program that prints Hello, world! ...
    '';
    homepage = "https://www.gnu.org/software/hello/manual/";
    changelog = "https://git.savannah.gnu.org/cgit/hello.git/plain/NEWS";
    license = lib.licenses.gpl3Plus;  # 从 lib.licenses 枚举取值（不是字符串！）
    maintainers = [ lib.maintainers.stv0g ];  # 维护者：坏了会被 ping 的人（第 42 章）
    platforms = lib.platforms.all;    # 所有平台（hello 无平台限制）
    mainProgram = "hello";            # ✅ 现代规范：nix run nixpkgs#hello 的入口
  };
})
```

### 36.1.2 构建过程复盘

求值期发生了什么：

1. `callPackage` 注入五个参数（第 32 章）；
2. `fetchurl {...}` 求值成固定输出派生（第 15 章）：哈希声明在案；
3. `mkDerivation` 翻译参数（第 34 章）→ 产出 `.drv`（第 13 章）。

构建期（沙箱内，第 33 章的 phases 逐一执行）：

```
unpackPhase    解压 hello-2.12.3.tar.gz（src 是 fetchurl 的输出）
patchPhase     无补丁（本平台分支），直接过
configurePhase ./configure --prefix=/nix/store/...-hello-2.12.3
               # autotools 标准 configure 由 stdenv 默认调用；
buildPhase     make -j$NIX_BUILD_CORES
checkPhase     make check（doCheck = true）
installPhase   make install → 程序落进 $out/bin/hello
installCheck   versionCheckHook：跑 $out/bin/hello --version，比对 2.12.3
fixupPhase     shebang/RPATH/strip（hello 是原生二进制，改动很小）
```

### 36.1.3 hello 教给我们的

- **函数头 = 依赖清单**：加依赖改头，`callPackage` 自动接线；
- **finalAttrs + SRI hash + structuredAttrs + strictDeps + mainProgram**：2026 年一个「规范新包」的全套要件——这五件套就是「最新推荐规范」在包定义层面的样子；
- **meta 不是注释而是接口**：license 缺失会被 ofBorg 挡，maintainers 决定谁被 ping；
- **测试内建**：doCheck/doInstallCheck/passthru.tests 三层测试从 hello 级别就该有。

## 36.2 实例二：figlet——裸 Makefile 与补丁流

figlet（把文字变成 ASCII 大字横幅）没有 configure，作者只提供 Makefile——展示「非 autotools 世界」与本地补丁的标准处理。位于 `pkgs/by-name/fi/figlet/package.nix`（依 master 快照整理）。

### 36.2.1 完整源码逐行注释

```nix
{
  lib,
  stdenv,
  fetchurl,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "figlet";
  version = "2.2.5";

  src = fetchurl {
    url = "ftp://ftp.figlet.org/pub/figlet/program/unix/figlet-${finalAttrs.version}.tar2.gz";
    # ↑ 作者只提供 ftp 源；无镜像组可用时的直接写法
    hash = "sha256-...";
  };

  patches = [
    # 补丁一：Alpine 移植的 musl 兼容修复——C++ 风格声明在纯 C 下报错
    # （nixpkgs 的常见做法：直接吸收其他发行版的成熟补丁，注明来源）
    ./musl-cpp-decl.patch
    # 补丁二：Darwin 需要 <unistd.h> 显式包含
    ./darwin-unistd.patch
  ];
  # ↑ patches 列表在 patchPhase 以 patch -p1 依次应用（第 33 章）
  #   ./xxx.patch 是相对本文件（by-name 目录内）的本地文件——by-name 要求自包含（RFC 140）

  # figlet 的 Makefile 不认 --prefix，用 make 变量注入安装位置：
  makeFlags = [
    "prefix=${placeholder "out"}"     # Makefile 里的 $(prefix) → $out（第 34.6 节占位符）
    "CC=${stdenv.cc.targetPrefix}cc"  # 用 stdenv 的编译器（写死 cc/gcc 会绕过工具链，
                                      # 交叉编译时 targetPrefix 是关键，第 40 章）
  ];

  # 上游 Makefile 没装「贡献字体」，安装后手工补齐：
  postInstall = ''
    mkdir -p $out/share/figlet
    cp contributed/*.flf $out/share/figlet/    # 字体文件与程序同装（运行期数据）
  '';

  doCheck = true;                     # 上游有自测目标，直接开启

  meta = {
    description = "Program for making large letters out of ordinary text";
    homepage = "http://www.figlet.org/";
    license = lib.licenses.afl21;      # 三选一时挑最贴近的上游许可证
    platforms = lib.platforms.unix;
    mainProgram = "figlet";
  };
})
```

### 36.2.2 构建复盘与经验

与 hello 的差异点全是「上游不规范时怎么办」的模板：

| 上游问题 | nixpkgs 解法 | 通用性 |
|----------|--------------|--------|
| 无 configure | configurePhase 自动空跑；安装位置靠 `makeFlags` 注入 | 所有裸 Makefile 包 |
| Makefile 写死 `CC` 或安装路径 | makeFlags 覆盖变量 | 同上 |
| 源码小 bug | 本地补丁（吸收 Alpine/Debian 的现成补丁是惯例） | 一切补丁流 |
| 漏装数据文件 | postInstall 手工 `install` | 数据文件/文档/补全通用 |

**补丁的写法纪律**（nixpkgs 贡献指南）：补丁须有来源（上游 PR 链接或其他发行版链接）与说明；`substituteInPlace` 用于小替换（替换失败会报错，比 sed 安全）；超过几十行的改动应推动上游而非长期携带。

## 36.3 实例三：平凡构建器自制包——不写一行 C

目标：给自己做一个「常用速查」命令 `cheatsheet`，内容来自若干 Markdown 文件；再做一个包装脚本 `p`（快速 ping 网关）。这类需求在 dotfiles 与内部工具里天天出现。

### 36.3.1 用 runCommand 与 write* 组合

```nix
# my-tools.nix —— 一个自制小工具集（flake/pkgs 里常见形态）
{
  lib,
  pkgs,
}:
let
  # ① writeText：字符串 → store 文件（第 35.2.2 节）
  bashCheats = pkgs.writeText "bash.md" ''
    # 常用命令速查
    - 查闭包大小：nix path-info -rSh $(which prog)
    - 看构建日志：nix log /nix/store/xxx.drv
    - 进环境：nix develop
  '';

  # ② runCommandLocal：快到不值得进缓存的拼装（第 35.2.1 节）
  cheatsheets = pkgs.runCommandLocal "cheatsheets" { } ''
    mkdir -p $out/share/cheats
    cp ${bashCheats} $out/share/cheats/bash.md
    # ↑ ${bashCheats} 插值：文件被复制进本派生的输入（依赖关系由此建立）
  '';

  # ③ writeShellScriptBin：脚本即「包」（bin/ 布局自动）
  cheatsheetCmd = pkgs.writeShellScriptBin "cheatsheet" ''
    cat ${cheatsheets}/share/cheats/bash.md
    # ↑ 闭包完整：脚本引用的所有文件都在依赖里（第 17 章语义）
  '';

  # ④ wrapProgram 思路（mkShell 场景外的 makeWrapper 演示）：
  pCmd = pkgs.writeShellScriptBin "p" ''
    exec ${lib.getExe pkgs.iputils} ping -c 3 "''${1:-192.168.1.1}"
    # ↑ lib.getExe：✅ 现代规范取可执行文件路径（⛔ "${pkgs.iputils}/bin/ping" 手拼已过时）
    # ↑ ''${1:-...}：shell 的默认参数语法，'' 转义出字面 ${（第 6.6.2 节）
  '';
in
pkgs.symlinkJoin {                    # ⑤ 聚合成一个「包」（第 35.2.3 节）
  name = "my-tools";
  paths = [ cheatsheetCmd pCmd ];
}
```

消费方式任选：`nix run`、进 `environment.systemPackages`、Home Manager 的 `home.packages`。

### 36.3.3 学到什么

- **「打包」不等于「编译」**：内容（字符串、配置、脚本）到产物的最短路径是平凡构建器；
- **依赖关系藏在插值里**：每个 `${...}` 都把目标拉进闭包——这就是第 9 章「字符串上下文」的实践意义；
- **组合优于单体**：小件（文件、脚本）+ symlinkJoin 聚合，各小件独立可测、可复用；
- `lib.getExe`、`lib.makeBinPath` 等小工具是「现代规范」的日常面孔（第 12 章）。

## 36.4 三实例对照小结

| 维度 | hello | figlet | 自制工具集 |
|------|-------|--------|-----------|
| 构建系统 | autotools | 裸 Makefile | 无（组装） |
| builder | stdenv.mkDerivation | stdenv.mkDerivation | runCommand/write*/symlinkJoin |
| 源码获取 | fetchurl+镜像 | fetchurl+ftp | 内容内联 |
| 补丁 | 无（平台条件分支） | 两个本地补丁 | 无 |
| 测试 | 三层测试 | doCheck | 无（内容简单） |
| 学习重点 | 规范新包五件套 | 上游不规范的应对 | 「文件即派生」心智 |

## 36.5 本章小结

- hello 展示 2026 年规范包的全套要件：finalAttrs、SRI、structuredAttrs、strictDeps、mainProgram、三层测试。
- figlet 展示裸 Makefile + makeFlags 注入 + 本地补丁的标准打法；吸收其他发行版补丁是惯例。
- 平凡构建器让「脚本/配置/聚合」也享受 Nix 的一切（可复现、原子、闭包完整）。
- 三个实例合起来覆盖日常打包需求的大半；下一章进入带语言工具链的中等复杂度。

## 延伸阅读

- 源文件：pkgs/by-name/he/hello/package.nix、pkgs/by-name/fi/figlet/package.nix
- nixpkgs «Submit changes> 贡献规范：https://github.com/NixOS/nixpkgs/blob/master/pkgs/README.md
- 第 37 章（中等实例：fzf 与 ripgrep）。
