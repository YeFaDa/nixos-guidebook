# 第 34 章 mkDerivation 逐行剖析

> **本章导读**：`stdenv.mkDerivation` 是 nixpkgs 里出现频率最高的函数——十万包中绝大多数从它出发。本章把它的参数表彻底讲透：每个常用参数的语义、`nativeBuildInputs` 与 `buildInputs` 的精确分界（附判定口诀）、`finalAttrs`/`env`/`__structuredAttrs` 等现代规范，以及它如何把第 33 章的 phases 体系参数化。读完本章，第 36-38 章的真实源码将再无生词。

## 34.1 它在分层中的位置

```
你的 package.nix
   │ 「我想构建 hello 2.12.3，源码在这，用这些依赖……」
   ▼
stdenv.mkDerivation (finalAttrs: { ... })     ← 本章：参数翻译层
   │ 参数 → 环境变量/hook/phase 覆盖
   ▼
derivation { ... }                            ← 第 13 章：原子施工单
   │ 沙箱里执行
   ▼
setup.sh 的 phases                            ← 第 33 章：构建框架
```

mkDerivation 本体在 `pkgs/stdenv/generic/make-derivation.nix`——一个把人类语言翻译成构建机器语言的编译器。它同时通过 `makeOverridable`（第 39 章）给每个产出物挂上 `.override`/`.overrideAttrs` 能力。

## 34.2 身份参数：name / pname / version

```nix
stdenv.mkDerivation (finalAttrs: {
  pname = "hello";            # ✅ 现代规范：名字与版本分开声明
  version = "2.12.3";
  # 最终 name 自动拼成 "hello-2.12.3" → 输出路径 /nix/store/<hash>-hello-2.12.3
})
```

- ⛔ 过时写法 `name = "hello-${version}";`（连同 `rec`）已被 pname/version 取代：后者让 `nix run`、版本检查、自动更新工具都能机器可读地取到版本。
- `pname` 与 `version` 都可被 `overrideAttrs` 修改（finalAttrs 引用自动跟随，第 7 章）。

## 34.3 输入参数：src / patches / 各类依赖

```nix
{
  # 源码：fetcher 产物（第 15 章）；多源用 srcs + sourceRoot
  src = fetchurl { url = "..."; hash = "sha256-..."; };

  # 补丁：patchPhase 依次以 -p1 应用；本地文件（同目录）或 fetchpatch 皆可
  patches = [ ./fix-build.patch ];

  # ===== 依赖两大类（34.4 详解）=====
  nativeBuildInputs = [ pkg-config installShellFiles ];
  buildInputs = [ glib gtk3 ];

  # 传递依赖：让「依赖我的人」也隐式获得（用于 .pc/头文件依赖，慎用）
  propagatedBuildInputs = [ ];

  # ===== 命令行参数 =====
  configureFlags = [ "--without-gui" ];
  makeFlags = [ "PREFIX=$(out)" ];        # $(out) 是 make 的变量展开，等价 ${placeholder "out"}? 
  # ↑ 准确写法：makeFlags = [ "PREFIX=${placeholder "out"}" ]（见 34.6）
  buildFlags = [ "-j$NIX_BUILD_CORES" ];   # 通常不必，buildPhase 已并行
}
```

## 34.4 nativeBuildInputs vs buildInputs：一锤定音的判定

第 33 章的机制表述：native→PATH（构建时**运行**的），build→-I/-L（构建时**链接**的）。判定口诀：

> **在构建过程中被执行的，是 native；被链接/包含进产物的，是 build。**

| 场景 | 放哪 |
|------|------|
| pkg-config、cmake、ninja、bison、flex、wayland-scanner | nativeBuildInputs |
| gcc、bash 等工具链 | （stdenv 自带，不用声明） |
| glibc 之外你链接的 C/C++ 库（glib、openssl） | buildInputs |
| 解释型语言的「库」（python 包之于 python 应用） | 视 builder 而定（各语言 builder 有约定，第 35 章） |
| python/pip 本身（构建脚本里跑 python） | nativeBuildInputs |
| 字体、图标、数据文件 | buildInputs（或干脆 runtime 依赖的别的方式） |

两个现代规范：

1. **`strictDeps = true`**（✅ 新包默认开启，存量包逐步迁移）：构建脚本只能「看见」nativeBuildInputs 与直接声明的 buildInputs，不再泄漏地看到 stdenv 的全部传递依赖——好处是依赖显式化、交叉编译正确性（第 40 章）与构建缓存命中率。
2. **语言生态 builder 里通常不直接写这两项**：buildRustPackage、buildPythonPackage 有自己的依赖参数（cargoDeps/dependencies 等），底层仍映射到这两类（第 35 章）。

## 34.5 行为定制：phases、脚本与开关

```nix
{
  # 追加/覆盖各 phase（第 33 章规则）
  postPatch = ''
    substituteInPlace Makefile --replace-fail "gcc" "${stdenv.cc.targetPrefix}gcc"
    # substituteInPlace：nixpkgs 标准的「安全 sed」，替换不存在时报错
  '';
  postInstall = ''
    installManPage doc/foo.1
  '';

  # 测试开关
  doCheck = true;             # 默认 false（nixpkgs 政策：显式开启）
  doInstallCheck = true;

  # 环境变量注入（进构建环境）
  env.CGO_ENABLED = 0;        # ✅ env.<VAR>：现代写法（此前直接 CGO_ENABLED = 0，
                              #   在 structuredAttrs 下不可靠，env 层是规范方案）
}
```

## 34.6 路径占位符：placeholder

构建脚本需要在**构建前**引用输出路径（比如把路径编进二进制），但输出路径在构建时由 `$out` 环境变量给出。当参数不经过环境变量（如 `configureFlags` 要嵌入路径）时用占位符：

```nix
configureFlags = [
  "--with-systemdsystemunitdir=${placeholder "out"}/lib/systemd/system"
  # placeholder "out" 求值为构建时才会被替换的占位串（形如 /1rz4g4znpzjwh1xymhjpm42vipw92pr73gl...）
];
```

同理 `makeFlags = [ "PREFIX=${placeholder "out"}" ];` 比 `$(out)` 更规范（不依赖 make 的展开时机）。

## 34.7 输出参数：outputs 与分拣

```nix
{
  outputs = [ "out" "dev" "man" ];
  # install 之后 fixup 自动分拣（第 33 章 33.5）：
  #   man 页 → $man；头文件/.pc → $dev；其余 → $out
  # 模块作者可用 moveToOutput 微调：
  postInstall = ''
    moveToOutput "lib/*.a" "$dev"    # 把静态库挪进 dev 输出
  '';
}
```

选择建议：简单 CLI 工具单 `out` 即可（nixpkgs 对无输出的包也常加 `man`）；库类包至少 `out`+`dev`；巨型文档才拆 `doc`。**闭包大小是评审硬指标**（第 17 章）。

## 34.8 元数据与扩展：meta / passthru

```nix
{
  # meta：给「包管理系统」看的信息（搜索、授权、平台、维护者）
  meta = {
    description = "A program that produces a familiar, friendly greeting";
    longDescription = ''...'';
    homepage = "https://www.gnu.org/software/hello/";
    license = lib.licenses.gpl3Plus;      # 从 lib.licenses 枚举取（不是字符串！）
    maintainers = with lib.maintainers; [ stv0g ];
    platforms = lib.platforms.all;         # 或 posix/darwin/unix/linux…
    mainProgram = "hello";                 # ✅ 现代：nix run 与补全的入口提示
    changelog = "https://.../NEWS";
  };

  # passthru：任意附加属性（不进构建，供外部/工具消费）
  passthru = {
    updateScript = ./update.sh;            # 自动更新机器人用
    tests.version = testers.testVersion { package = finalAttrs.finalPackage; };
  };
}
```

`meta` 缺 license/maintainers/platforms 的 PR 在 nixpkgs 会被检查项拦截；`mainProgram` 是近年的规范新增（解决 `nix run pkg` 该跑哪个二进制的歧义）。

## 34.9 现代参数三件套：finalAttrs / env / __structuredAttrs

第 7 章讲过 `finalAttrs`；这里补全它在 mkDerivation 语境的完整形态：

```nix
stdenv.mkDerivation (finalAttrs: {
  # finalAttrs：本派生「最终形态」的属性集（override 合并后）
  pname = "example";
  version = "1.0";
  src = fetchFromGitHub {
    owner = "o";
    repo = "example";
    tag = "v${finalAttrs.version}";       # ← 引用最终值，override 后自动一致
    hash = "sha256-...";
  };
  passthru.updateScript = ... finalAttrs.version ...;

  __structuredAttrs = true;    # ✅ 参数以 JSON 文件（.attrs.json）传入构建，
                               # 而非逐个导出为环境变量：支持嵌套结构/列表/大参数，
                               # 现代包的标配（第 36-38 章实例里反复出现）
})
```

三者的分工一句话：**finalAttrs 管「引用最终态」，env 管「给构建器的变量」，__structuredAttrs 管「参数怎么传」**。

## 34.10 一个完整的「教科书包」

把本章参数拼成一个中等复杂度的完整示例（虚构的 C 库 `libfoo`，注释齐全）：

```nix
{
  lib, stdenv, fetchFromGitHub,   # lib：工具库；stdenv：构建环境；fetchFromGitHub：取源
  pkg-config,                     # 构建 RUN 的工具 → native
  glib,                           # 链接的库 → build
  versionCheckHook, installShellFiles,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "libfoo";
  version = "1.4.2";

  __structuredAttrs = true;

  src = fetchFromGitHub {
    owner = "example";
    repo = "libfoo";
    tag = "v${finalAttrs.version}";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";  # 假哈希起步（第 42 章）
  };

  outputs = [ "out" "dev" ];       # 库包拆 dev，闭包友好

  strictDeps = true;              # 依赖精确化（现代默认）
  nativeBuildInputs = [ pkg-config versionCheckHook installShellFiles ];
  buildInputs = [ glib ];

  env.NO_SHARED = "0";            # 注入构建环境变量

  doCheck = true;
  doInstallCheck = true;          # versionCheckHook 将跑 foo --version 核对

  postInstall = ''
    installManPage doc/foo.1
  '';

  meta = {
    description = "An example library doing foo";
    homepage = "https://github.com/example/libfoo";
    license = lib.licenses.mit;
    maintainers = [ lib.maintainers.alice ];
    platforms = lib.platforms.unix;
    mainProgram = "foo";
  };
})
```

第 36-38 章将把同样的参数表放进真实世界的包里逐一印证。

## 34.11 本章小结

- mkDerivation 是「参数 → 环境变量/hook/phase」的翻译层，产出自动可 override（第 39 章）。
- 身份：pname+version（⛔ name 拼接已过时）；输入：src/patches/依赖两类/propagated*。
- 判定口诀：构建时**执行**的进 nativeBuildInputs，**链接/包含**的进 buildInputs；strictDeps 让声明精确化。
- 输出路径进脚本用 `placeholder "out"`；outputs 拆分影响闭包与评审。
- meta（含 mainProgram）与 passthru 是包的「对外接口」；finalAttrs/env/__structuredAttrs 构成现代三件套。

## 延伸阅读

- 手册 «Derivation> 函数参考（每个参数的权威说明）：https://nixos.org/manual/nixpkgs/unstable/#sec-using-stdenv
- 源码：pkgs/stdenv/generic/make-derivation.nix
- 下一章（第 35 章）把视野扩展到全部打包方式。
