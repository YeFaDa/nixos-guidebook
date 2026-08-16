# 第 38 章 复杂包实例精讲（逐行注释）

> **本章导读**：简单与中等实例都是「一个包一个文件」；复杂度的新维度是：**语言运行时生态**（Python 的 requests——依赖解析与测试矩阵）、**操作系统级构建**（Linux 内核——构建器之王的参数面）、**聚合巨兽**（Firefox——数十个构建依赖的编排）。三个实例代表三条复杂度轴线，逐条拆解。

## 38.1 实例一：Python 的 requests——生态型包

Python 生态的复杂不在单个包，而在**依赖图与测试**：几十个传递依赖、可选依赖组（extras）、需要禁网络与平台相关的失败测试。文件：`pkgs/development/python-modules/requests/default.nix`（master 2026-08 快照完整逐字内容）。

### 38.1.1 完整源码（逐行注释）

```nix
{
  lib,
  stdenv,                  # 只为读 hostPlatform（平台相关测试禁用）
  buildPythonPackage,      # ★ Python 生态构建器（第 35.3 节）
  certifi,                # ↓ 本体的运行依赖（每个都是独立的 nix 化 Python 包）
  chardet,                 #   ——可选组 use_chardet_on_py3 用
  charset-normalizer,
  fetchFromGitHub,
  idna,
  pysocks,                 # 可选组 socks 用
  pytest-mock,
  pytest-xdist,            # ↓ 测试依赖（nativeCheckInputs）
  pytestCheckHook,
  setuptools,              # 构建系统（PEP 517 的 build backend）
  urllib3,
}:

buildPythonPackage (finalAttrs: {
  pname = "requests";
  version = "2.34.2";
  pyproject = true;        # ★ 声明走 PEP 517/517? ——准确：PEP 517/518（pyproject.toml
                           #   构建协议）：buildPythonPackage 用 pyproject 构建钩子
                           #   而非旧 setup.py 直跑（⛔ 旧时代 format="setuptools" 已过时）

  src = fetchFromGitHub {
    owner = "psf";
    repo = "requests";
    tag = "v${finalAttrs.version}";
    hash = "sha256-J2/sNpFUDHkNBeN7BfiMamv7YaWixZAZHxaqmPVEptc=";
  };

  build-system = [ setuptools ];
  # ✅ 现代写法（对位旧 buildInputs 放 setuptools）：PEP 517 的构建后端依赖
  # → 归入 native 依赖、构建完即弃（第 34.4 节判定口诀的 Python 版）

  dependencies = [
    certifi
    charset-normalizer
    idna
    urllib3
  ];
  # ✅ 现代写法（对位旧 propagatedBuildInputs）：Python 包的运行依赖
  #   「propagated」语义：下游 import requests 时这些也必须可见——
  #   buildPythonPackage 把它们展开为 PYTHONPATH 传递

  optional-dependencies = {
    security = [ ];
    socks = [ pysocks ];
    use_chardet_on_py3 = [ chardet ];
  };
  # 对应 setup.cfg/pyproject 的 extras：下游可用
  # python3Packages.requests.override { extras = [ "socks" ]; }? （以 pyproject.nix 时代的
  # 约定为准）——更重要的是：它们让 nixpkgs 能解析「带 extra 的依赖声明」

  nativeCheckInputs = [
    pytest-mock
    pytest-xdist
    pytestCheckHook       # 钩子化测试：把 pytest 接进 checkPhase（第 33 章 hook 思想）
  ]
  ++ finalAttrs.passthru.optional-dependencies.socks;
  # 测试依赖 + 「socks 组」也进测试集（引用 passthru 里的定义，单一事实源）

  disabledTests = [
    # Disable tests that require network access and use httpbin
    "requests.api.request"
    "requests.models.PreparedRequest"
    "requests.sessions.Session"
    "requests"
    "test_redirecting_to_bad_url"
    "test_requests_are_updated_each_time"
    "test_should_bypass_proxies_pass_only_hostname"
    "test_urllib3_pool_connection_closed"
    "test_urllib3_retries"
    "test_use_proxy_from_environment"
    "TestRequests"
    "TestTimeout"
  ]
  # 沙箱无网络（第 16 章）→ 需要真实网络的用例按名禁用：
  # 这是 Python 打包的核心日常工作——「测试与隔离的和平协议」
  ++ lib.optionals (stdenv.hostPlatform.isDarwin && stdenv.hostPlatform.isAarch64) [
    # Fatal Python error: Aborted
    "test_basic_response"
    "test_text_response"
  ];
  # 平台相关失败：Apple Silicon 的已知崩溃，按平台条件禁用（精确到用例级）

  disabledTestPaths = lib.optionals (stdenv.hostPlatform.isDarwin && stdenv.hostPlatform.isAarch64) [
    # Fatal Python error: Aborted
    "tests/test_lowlevel.py"
  ];
  # 整个文件级禁用（比逐用例粗一档的粒度）

  pythonImportsCheck = [ "requests" ];
  # installCheck 阶段自动执行 import requests——最小烟雾测试（能否导入）

  __darwinAllowLocalNetworking = true;
  # darwin 沙箱对本地回环网络限制的豁免开关（平台特定沙箱细节，第 16 章）

  meta = {
    description = "HTTP library for Python";
    homepage = "http://docs.python-requests.org/";
    changelog = "https://github.com/psf/requests/blob/${finalAttrs.src.tag}/HISTORY.md";
    license = lib.licenses.asl20;
    maintainers = [ lib.maintainers.fab ];
  };
})
```

### 38.1.2 requests 教给我们的

- **现代 Python 打包三柱**：`pyproject = true` + `build-system` + `dependencies`（三者都完成了对旧写法的替代）；
- **依赖的传播**：Python 的 import 图决定了 dependencies 必须是 propagated 语义——语言生态如何改写第 34 章的通用规则；
- **测试矩阵治理**：无网络 → disabledTests；平台崩溃 → 条件 disabled；导入检查 → pythonImportsCheck。三层治理让「在沙箱里测试不合作的软件」成为工程而非运气；
- **单一事实源**：optional-dependencies 在 passthru 里被测试引用，避免两处清单漂移。

## 38.2 实例二：Linux 内核——buildLinux 的参数面

内核是 nixpkgs 最重的构建对象之一：编译数小时、产物多个、配置体系庞杂。nixpkgs 的内核打包位于 `pkgs/os-specific/linux/kernel/`，由 `generic.nix`（buildLinux 工厂）+ 每版本一个小文件（如 `linux-6.12.nix`）组成。以下依 master 结构整理（节选注释）。

### 38.2.1 版本文件的样子（linux-6.12.nix 概念形）

```nix
{
  lib,
  fetchurl,
  buildLinux,
  ...
} @ args:

buildLinux (
  args
  // {
    version = "6.12.30";          # 具体 point release

    src = fetchurl {
      url = "mirror://kernel/linux/kernel/v6.x/linux-${version}.tar.xz";
      hash = "sha256-...";
    };

    kernelPatches = [
      # 内核补丁集：各补丁 { name, patch, extraConfig? } 结构
      # NixOS 对品牌内核（zen、liquorix）就是在这里换补丁组实现的
    ];

    structuredExtraConfig = [
      # 以 kernel config 片段形式注入配置（新式：结构化而非拼接字符串）
      # 例如强制开启某些安全选项
    ];
  }
)
```

### 38.2.2 buildLinux（generic.nix）的关键参数与行为（注释版概览）

```nix
# buildLinux 收到的典型参数（节选，完整以源码为准）：
{
  version, modDirVersion ? ...,   # 模块目录版本串（含 -zen 之类后缀）
  src,
  configfile,                     # .config 的来源：
                                  #   默认 = 按当前平台/需求从 allconfig 生成
                                  #   NixOS 模块层（boot.kernelPackages）
                                  #   再依你的 boot.initrd/文件系统选项动态改写
  kernelPatches, allowImportFromOffset? ...,
  features ? { },                 # 特性开关（ia32Emulation 等）
  enableParallelBuilding ? true,
  # ——构建行为：
  outputs = [ "out" "dev" ];      # $out/modules、$dev/headers
  # phases 特殊性：
  configurePhase = ''...''        # 不是 ./configure！而是把 configfile 精修后
                                  # 写入 .config（含 randomize 启闭、必要的 =y 追加），
                                  # 然后 make prepare
  buildFlags = [ "vmlinux" "modules" "bzImage" ];
  # 安装：modules_install、firmware 归位、生成 modprobe 索引
  # NixOS 集成：kernel + modules 打包成 linuxPackages.<name> scope，
  #   boot.kernelPackages = pkgs.linuxPackages_6_12; 一行换内核（第 24 章）
}
```

### 38.2.3 学到什么

- **「构建器」可以非常领域化**：buildLinux 里没有 ./configure，phases 被完全重写——第 33 章框架的「可替换性」在高难度场景的兑现；
- **配置也是依赖图**：内核 .config 由「平台基线 + NixOS 模块需求 + 用户覆盖」多层求值合成——第 25 章模块思想在内核层的复刻；
- **scope 组织**：`linuxPackages_<ver>` 聚集内核与其所有外置模块（nvidia、zfs...），保证模块与内核严格同版匹配——`makeScope` 的教科书应用（第 39 章）。

## 38.3 实例三：Firefox——聚合巨兽的编排

Firefox 的打包没有「一个文件读到底」的形态，而是一个**构建编排系统**（位于 `pkgs/applications/networking/browsers/firefox/`）。逐层导览（依 master 结构概述）：

```
firefox/
├── packages/firefox.nix      ← 入口：callPackage common.nix + 一组构建依赖
├── common.nix                ← 巨型工厂（千行）：源码 fetch → 构建 → 打包
├── update.nix                ← 自动更新脚本
└── vendor? （AGen? 源码树依赖锁定）
```

`common.nix` 的复杂度来自四面：

1. **构建工具链的异构性**：Rust（含 pinned 版本）+ clang + cbindgen + node + yasm + wine（部分平台跑配置脚本）……——nativeBuildInputs 长达数十项，每项 pin 到特定版本（浏览器上游对工具链版本敏感）；
2. **源码即依赖树**：Mozilla 的源码发行版自带 vendor 化依赖，nixpkgs 依 mozilla 的清单校验哈希（fetchzip 类 FOD）；
3. **补丁与配置体系**：数十个下游补丁（沙箱、系统库适配）+ mozconfig 的生成与改写（`postPatch` 的重量级应用）；
4. **多渠道多产品**：firefox、beta、devedition、esr 与 thunderbird 共用 common.nix，参数差异（版本、渠道开关）由入口文件注入——`finalAttrs` 模式在「一族产品」上的扩展。

它教给我们的是打包复杂度的第三轴：**当「一个软件」实际是一张巨网时，打包定义从「配方」演变为「编排系统」**——而 Nix 的表达力足以让这套编排保持可求值、可缓存、可复现（Firefox 的每次更新都是 mass-rebuild，走 staging 分支，第 41 章 CI 话题的呼应）。

## 38.4 三实例对照：复杂度的三个方向

| 方向 | requests | linux | firefox |
|------|----------|-------|---------|
| 复杂在哪 | 依赖解析+测试矩阵 | 构建规模+配置体系 | 工具链编排+多产品 |
| builder | buildPythonPackage | buildLinux | common.nix（自研工厂） |
| 关键技术 | extras/测试禁用/导入检查 | config 合成/补丁组/scope | 版本 pin/共享工厂 |
| 你该记住 | dependencies 传播语义 | phases 可整体重写 | 定义可以长成系统 |

## 38.5 本章小结

- Python：pyproject 三柱（pyproject/build-system/dependencies）+ 三层测试治理（disabledTests/平台条件/pythonImportsCheck）。
- 内核：buildLinux 重写 phases、配置由多层合成、linuxPackages scope 保证内核-模块同源。
- Firefox：打包定义演化为编排系统；版本 pin 的工具链与多产品共用工厂。
- 三条复杂度轴线合起来，就是 nixpkgs 十万包经验沉淀的全谱系——第 42 章你将从零走一遍自己的完整流程。

## 延伸阅读

- 源文件：pkgs/development/python-modules/requests/default.nix（完整真实）
- pkgs/os-specific/linux/kernel/（generic.nix 值得通读）、pkgs/applications/networking/browsers/firefox/
- 手册 «Python«、«Linux Kernel>：https://nixos.org/manual/nixpkgs/unstable/#sec-language-python
