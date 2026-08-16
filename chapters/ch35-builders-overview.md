# 第 35 章 打包方式总览：全部 builder 分类详解

> **本章导读**：nixpkgs 的 `pkgs` 集合里住着不止「编译型软件」：有从字符串直接生成的脚本、从依赖拼装的环境、各语言生态的专用构建器、容器与 AppImage、甚至 Linux 内核与编辑器插件。本章建立完整的分类学：四大类打包方式、每类的代表 builder、各自适用场景与「Hello World 级」示例。它是第 36-38 章实例精讲前的「地图页」，也是日后翻查的工具页。

## 35.1 分类框架

```
nixpkgs 打包方式
├── 一、基础构建层
│   ├── stdenv.mkDerivation        ← 第 33/34 章（C/C++/Make/Autotools/CMake/Meson...）
│   └── 原语 derivation            ← 第 13 章（仅在造轮子时直接用）
├── 二、平凡构建器（trivial builders）：不编译，只「组装」
│   ├── runCommand / runCommandLocal
│   ├── writeText / writeTextFile / writeShellScript(Bin) / writeScript(Bin)
│   │   / writePythonScript? （writers 家族：pkgs.writers）
│   ├── symlinkJoin / linkFarm / buildEnv（聚合）
│   └── makeWrapper 语义（wrapProgram：打包界最常用的「胶布」）
├── 三、语言生态构建器（每门语言一套约定）
│   ├── buildGoModule / buildGoPackage(⚠️旧)
│   ├── rustPlatform.buildRustPackage
│   ├── buildPythonPackage / python3.pkgs.callPackage
│   ├── buildNpmPackage / buildYarnPackage(⚠️渐退) / mkYarnPackage(⚠️旧)
│   ├── haskellPackages.callHackage / haskell.lib.compose
│   ├── buildPerlPackage / buildRubyGem / buildMix / buildRebar3
│   ├── buildDunePackage (OCaml) / buildOpamPackage?
│   ├── buildDotnetModule / buildMaven / buildGradle
│   ├── lua? lua5_*.withPackages / buildLuaPackage
│   ├── vimPlugins / emacsPackages（第 35.5 框架级）
│   └── zig/crystal/swift/gnat 等：多经由 stdenv 直接构建
└── 四、特殊目标构建器
    ├── mkShell（开发环境，非包）
    ├── dockerTools（buildImage / streamLayeredImage / buildLayeredImage / buildEnv 集成）
    ├── buildFHSEnv / appimageTools / steam-run（兼容层）
    ├── buildLinux（内核） / buildVM? vmTools（虚拟机构建）
    ├── testers.* / validatePkgConfig 等（测试设施）
    └── pkgsCross / pkgsStatic / pkgsMusl（平台变体，第 40 章）
```

下面逐类展开，每类给可运行的最小示例。

## 35.2 平凡构建器：不编译的打包

### 35.2.1 runCommand：一段 shell 即一「包」

```nix
# 最简单：名字、构建输入、命令。命令结束时 $out 必须存在
pkgs.runCommand "my-config" { } ''
  mkdir -p $out/etc
  echo "hello from runCommand" > $out/etc/my.conf
''
```

`runCommandLocal` 变体提示「很快、不值得进缓存」。凡「拿几个输入拼一个文件/目录」的需求，先想 runCommand。

### 35.2.2 write* 家族：字符串直接进 store

```nix
pkgs.writeText "note.txt" "你好，Nix"              # 生成 /nix/store/...-note.txt
pkgs.writeShellScriptBin "say-hi" ''
  echo "hi from ${pkgs.hello}"
''   # 产出带 bin/say-hi 的「包」（可直接进 systemPackages 或 PATH）
pkgs.writers.writePython3Bin "py-echo" { libraries = [ pkgs.python3Packages.requests ]; } ''
  print("written in python")
''   # writers 家族：任意解释器语言的脚本一键成包（带依赖与检查）
```

第 26/29 章的自定义服务脚本、第 43 章的模块里都会用到它们——**「文件即派生」**。

### 35.2.3 聚合器：symlinkJoin 与 buildEnv

```nix
# symlinkJoin：把多个包的目录树符号链接合并为一个包
pkgs.symlinkJoin {
  name = "my-tools";
  paths = [ pkgs.ripgrep pkgs.fzf ];
}
# → 一个包含两者 bin/share 的「联合包」

# buildEnv：更强（可裁剪/过滤/打 postBuild 钩子）——system-path 就是它造的（第 23 章）
pkgs.buildEnv {
  name = "my-env";
  paths = [ pkgs.hello ];
  pathsToLink = [ "/bin" ];       # 只取 bin，闭包与体积友好
  postBuild = ''
    ln -s ${pkgs.hello}/bin/hello $out/bin/salut   # 聚合后加工
  '';
}
```

### 35.2.4 makeWrapper： omnipresent 的胶布

严格说这是 `makeWrapper` hook 提供的命令（常见于 postInstall/postFixup）：

```nix
postFixup = ''
  wrapProgram $out/bin/myapp \
    --prefix PATH : ${lib.makeBinPath [ pkgs.git pkgs.ripgrep ]} \
    --set MYAPP_CONFIG ${./default.toml}
  # 为可执行文件生成「包装脚本」：预置 PATH 与环境变量
  # ——解决「程序运行时找 git/找配置」的经典问题（闭包完整性由此保证）
'';
```

## 35.3 语言生态构建器：约定高于配置

每门语言一个（组）builder，共同模式：**拉取语言依赖 → 语言自己的构建工具跑起来 → 产物归位到 Nix 布局**。详见第 37-38 章的逐行实例（fzf/ripgrep/requests），此处速览：

| Builder | 语言 | 关键参数 | 依赖锁定 |
|---------|------|----------|----------|
| `buildGoModule` | Go | `vendorHash` | go.mod → vendor 树（FOD） |
| `rustPlatform.buildRustPackage` | Rust | `cargoHash` | Cargo.lock → crates 缓存（FOD） |
| `buildPythonPackage` | Python | `pyproject`、`build-system`、`dependencies` | pypi 依赖各为独立 nix 包 |
| `buildNpmPackage` | JS/TS | `npmDepsHash` | package-lock（FOD） |
| `haskellPackages.callHackage "pkg" ver {}` | Haskell | 各包独立 | stackage/hackage 快照集 |
| `buildPerlPackage` / `buildRubyGem` / `buildMix` / `buildRebar3` | Perl/Ruby/Elixir/Erlang | — | 各自生态 |
| `buildDunePackage` | OCaml | `duneBuildPhase` 约定 | opam-repository 快照 |
| `buildDotnetModule` | C# | `nuDeps` | nuget.lock（FOD） |
| `buildMaven`/`buildGradle` | JVM | — | pom/gradle 锁 |

三条共性规律（记住它们就掌握了 80%）：

1. **依赖图由语言自己的 lock 文件驱动**，锁内容以固定输出派生（第 15 章）取回（vendorHash/npmDepsHash/cargoHash 的假哈希循环都一样，第 42 章）；
2. builder 本质是 stdenv 的预配置（设置了各 phase、hook、依赖变量）——第 33 章的一切照样生效；
3. 语言「包集合」多经 scope 组织（`python3Packages`、`haskellPackages`、`rubyPackages...`），可用 `callPackage`/`.overrideScope'` 整体定制（第 39 章）。

## 35.4 特殊目标构建器

### 35.4.1 mkShell：不是包，是环境

```nix
pkgs.mkShell {
  packages = [ pkgs.gcc pkgs.cmake pkgs.sqlite ];
  shellHook = ''echo "welcome to dev shell"'';
}
```

`nix develop`/`nix-shell` 进入（第 42 章实战）。mkShell 产出的是「环境派生」，不安装任何东西到系统。

### 35.4.2 dockerTools：容器即闭包

```nix
pkgs.dockerTools.buildImage {
  name = "myapp";
  tag = "latest";
  config = {
    Env = [ "PATH=/bin" ];
    Cmd = [ "${pkgs.hello}/bin/hello" ];
  };
  copyToRoot = pkgs.buildEnv {           # 进镜像的文件集（现代参数，替代旧 copyToRoot?）
    name = "root";
    paths = [ pkgs.bash pkgs.coreutils ];
    pathsToLink = [ "/bin" ];
  };
}
# streamLayeredImage：流式产出（不占磁盘聚合）；buildLayeredImage：分层缓存友好
# 镜像「每层都是 Nix 闭包」——真正可复现的容器
```

### 35.4.3 FHS 兼容层：buildFHSEnv / appimageTools / steam-run

```nix
# 给「假设 /usr 存在」的软件（很多闭源工具）一个假 FHS：
pkgs.buildFHSEnv {
  name = "closed-app";
  targetPkgs = pkgs: [ pkgs.glib pkgs.gtk3 ];
  runScript = "${closed-app}/bin/closed-app";
}
# 产物是一个包装命令：进入 FHS 沙箱再运行目标程序
pkgs.steam-run           # 预配置好的通用 FHS（跑任意二进制/steam 游戏的万能胶）

pkgs.appimageTools.wrapType2 {   # AppImage 的标准处理
  name = "some-app";
  src = fetchurl { url = "..."; hash = "..."; };
}
```

### 35.4.4 内核与 VM：buildLinux / vmTools

`pkgs.linux` 系列经 `callPackage ../os-specific/linux/kernel/generic.nix`（`buildLinux`）构建（第 38 章复杂实例）；`vmTools.runInLinuxVM` 允许「在 VM 里构建」（打包需要真内核特性的软件时用）。`linuxPackages` scope 汇集内核外置模块（nvidia 驱动等）。

### 35.4.5 编辑器插件：vimPlugins / emacsPackages

Vim 插件（`vimPlugins.nvim-treesitter`）与 Emacs 包（`emacsPackages.melpaPackages.xxx`）各自有生成器把上游插件仓库转成包集合，配合 `(neovim.override { configure = ... })` 或 Emacs 的 `withPackages` 消费。

## 35.5 选型决策树

```
要打包什么？
├─ 一个文件/脚本由内容决定 → write* 家族
├─ 几个现有输入拼装/加工 → runCommand / symlinkJoin / buildEnv
├─ C/C++/Rust/Go/... 源码编译
│    ├─ 走语言生态有 builder？→ 用之（vendorHash 之类锁依赖）
│    └─ 否 → stdenv.mkDerivation（构建系统由 hook 自动识别）
├─ 解释型语言的库/应用 → 对应语言的 buildXxxPackage
├─ 预编译二进制（闭源/官方发行包）
│    ├─ 是 AppImage → appimageTools.wrapType2
│    ├─ 假设 FHS → buildFHSEnv
│    └─ 只是 tar 包 → stdenv + autoPatchelfHook（自动补 RPATH/依赖）
├─ 容器镜像 → dockerTools
├─ 开发环境（不是包）→ mkShell
└─ 内核/驱动 → buildLinux / linuxPackages
```

## 35.6 本章小结

- 四大类：基础构建（stdenv）、平凡构建器（runCommand/write*/聚合器）、语言生态 builder、特殊目标（docker/FHS/内核/插件）。
- 平凡构建器实现「文件即派生、环境即派生」；makeWrapper 是保证运行期闭包完整的头号工具。
- 语言生态 builder 的共性：lock 文件驱动依赖、FOD 取回、stdenv 预配置。
- 特殊目标各有专器：容器=闭包分层的 dockerTools、FHS 兼容、buildLinux。
- 决策树是日常打包的快速索引；实例见第 36-38 章。

## 延伸阅读

- 手册 «Build Helpers»（每类 helper 的权威文档）：https://nixos.org/manual/nixpkgs/unstable/#sec-build-helpers
- 源码地图：pkgs/build-support/（本表全部实现的所在地，浏览目录收获巨大）
- 第 36 章起进入真实源码逐行精讲。
