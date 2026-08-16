# 第 15 章 哈希、固定输出与内容寻址

> **本章导读**：哈希是 Nix 的货币。第 13 章末尾给出了三种哈希模型的总览，本章把中间那种——**固定输出派生（fixed-output derivation）**——讲透，因为它承担着整个体系里最微妙的工作：把「从互联网下载源码」这个先天不纯的动作，安全地纳入纯函数世界。你还将学会所有 fetcher 的用法、哈希格式的转换、以及那个所有打包者的必经仪式：用假哈希换真哈希。

## 15.1 为什么「下载」是个难题

一切构建都始于获取源码，而下载是不纯的：

- 同一 URL 的内容可能变化（上游重发 tarball）；
- 下载依赖网络与时间（今天能下，明天 404）；
- 服务器可能被劫持返回恶意内容。

若放任构建脚本随意联网下载（传统 `Makefile` 的做法），第 4 章的纯函数模型就被撕开一个口子：输入哈希无法覆盖「从网络拿回来的东西」。Nix 的解法优雅而彻底——**预先声明你要拿到的东西的哈希，然后允许你去拿，最后强制校验**。拿回来的东西不符声明，构建失败；符合声明，它就有了确定的身份。

## 15.2 fixed-output derivation 的机制

在第 13 章的 `derivation` 原语层面，固定输出只需两个额外参数：

```nix
derivation {
  name = "hello-2.12.3.tar.gz";
  builder = "${curl}/bin/curl";     # 举例：用 curl 下载
  args = [ "-o" "$out" "-L" "https://ftp.gnu.org/gnu/hello/hello-2.12.3.tar.gz" ];
  outputHashAlgo = "sha256";        # 声明哈希算法
  outputHash = "sha256-...";        # 声明期望的输出哈希（SRI 格式）
  outputHashMode = "flat";          # flat=文件本身；recursive=解包后的 NAR
  # ↑ 固定输出派生的标志：这三件套
}
```

运行时与普通派生的两点不同：

1. **沙箱放开网络**——这是全 Nix 体系中唯一被允许联网的构建类型；
2. **构建结束强制校验**输出哈希，不匹配则整个构建作废（报 «hash mismatch»）。

输出路径由 `(名字, 声明的哈希)` 决定，与「用什么工具下载」无关——于是**不同 fetcher 下载同一文件得到同一 store 路径**，缓存与共享照常成立。

## 15.3 fetchers 家族：nixpkgs 的源码获取层

日常从不手写上面的裸派生，而是用 nixpkgs 封装好的 fetcher 家族（`pkgs/top-level/all-packages.nix` 顶层可直接取）。逐个讲（✅ 标注为现代推荐用法）：

### 15.3.1 fetchurl：下载单个文件

```nix
src = pkgs.fetchurl {
  url = "https://ftp.gnu.org/gnu/hello/hello-2.12.3.tar.gz";
  hash = "sha256-jZkUKv2SV28wsM18tCqNxoCZmLxdYH2Idh9RLibH2yA=";
};
# ✅ 现代：hash = SRI 格式（sha256-<base64>）
# ⚠️ 旧式：sha256 = "1lp...";（base32，32 字符）—— 仍合法，nixpkgs 已整体迁移到 SRI
```

`mirror://gnu/...` 是 nixpkgs 内建的镜像速记（`pkgs/build-support/fetchurl/mirrors.nix` 定义了 GNU、SourceForge、kernel.org 等数十组镜像），✅ 推荐使用以提高可用性：`url = "mirror://gnu/hello/hello-2.12.3.tar.gz";`。

### 15.3.2 fetchzip：下载并解压

```nix
src = pkgs.fetchzip {
  url = "https://example.com/foo-1.0.zip";
  hash = "sha256-...";
};
# 产物是解压后的目录树；哈希作用于「解压后的内容」（NAR 哈希，非压缩包字节）
# 因此上游重新打包（压缩参数变了但内容没变）不会破坏你的哈希 ✅
```

### 15.3.3 fetchFromGitHub：nixpkgs 的绝对主力

```nix
src = pkgs.fetchFromGitHub {
  owner = "BurntSushi";
  repo = "ripgrep";
  tag = "15.2.0";                 # ✅ 用 tag/rev 固定；不用 branch（会漂移）
  hash = "sha256-BsSIbZwB6s8i3dDTRYJ1EdVbJmiO0oxcLu6qiYlPkOI=";
};
```

要点逐条：

- `tag` 与 `rev` 二选一（tag 会被翻译成 rev）；内部走 GitHub 的 **codeload tarball**；
- 产物是解压后的源码树（等价 fetchzip 语义）；
- 可选参数：`deepClone = true`（完整克隆，保留 git 历史，⚠️ 哈希不同、体积大，仅特殊需要）；`leaveDotGit = true`（保留 .git 目录，供版本号生成用）；`fetchSubmodules = true`；
- 同族还有 `fetchFromGitLab`、`fetchFromGitea`、`fetchFromBitbucket`、`fetchFromSavannah` 等，接口一致。

### 15.3.4 fetchgit 与 fetchTarball

```nix
# fetchgit：需要完整 git 仓库时
src = pkgs.fetchgit {
  url = "https://git.example.com/foo";
  rev = "a1b2c3d4...";
  hash = "sha256-...";
};

# ⚠️ fetchTarball（nixpkgs 版）：下载并解压 tarball
src = pkgs.fetchTarball { url = "..."; hash = "sha256-..."; };

# ⛔ builtins.fetchTarball / builtins.fetchurl（内建 impure 版）：
#    无哈希声明、无缓存安全；仅适合一次性实验。nixpkgs 代码禁用。
```

### 15.3.5 其他常用

`fetchpatch`（打补丁用的源码补丁）、`fetchDebianPatch`、`fetchPypi`（PyPI 定位）、`fetchCrate`（Rust crate）、`fetchnpm`? （npm 场景走 buildNpmPackage 内部）、`fetchhg`/`fetchsamba`? 不常见不列——完整清单见 `pkgs/build-support/`（第 32 章仓库地图）。

## 15.4 哈希格式：四种编码与互转

同一个 SHA-256 有四种文本编码（值相同、写法不同）：

| 格式 | 样例 | 使用场景 |
|------|------|---------|
| base16（hex） | `8d7...`（64 字符） | `nix hash file` 默认输出 |
| base32 | `1lp3...`（32 字符，Nix 字母表） | ⚠️ 旧式 `sha256 = ...` 写法 |
| SRI | `sha256-jZkU...` | ✅ 现行推荐（`hash = ...`） |
| base64 | `jZkU...`（44 字符） | SRI 中的裸部分 |

转换工具（✅ 新 CLI）：

```console
$ nix hash convert --to sri 8d7f...
$ nix hash convert --to base32 sha256-jZkU...
$ nix hash file --base16 ./pkg.tar.gz      # 计算文件哈希
$ nix hash path ./src                      # 目录（NAR）哈希
```

**SRI 是现行规范**：nixpkgs 已全量迁移到 `hash = "sha256-..."` 写法；旧教程的 `sha256 = "base32..."` 仍被接受（⛔ 新代码不要再写）。SRI 的好处：自带算法名（未来换 sha512 不用改字段）、与 W3C 标准对齐。

## 15.5 假哈希换真哈希：打包者的成人礼

你无法在下载前知道哈希（鸡生蛋问题），官方流程因此是「两步走」：

```nix
# 第一步：故意填假哈希（✅ 标准做法：lib.fakeHash）
{
  lib,
  fetchFromGitHub,
}:
src = fetchFromGitHub {
  owner = "example";
  repo = "foo";
  tag = "v1.0";
  hash = lib.fakeHash;      # 即 "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
};
```

```console
# 第二步：构建，Nix 下载后在报错里「告诉」你真实哈希
$ nix build
error: hash mismatch in fixed-output derivation '/nix/store/...-source':
  specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
  got:       sha256-BsSIbZwB6s8i3dDTRYJ1EdVbJmiO0oxcLu6qiYlPkOI=
```

把 `got:` 的值抄回 `hash = ...`，完成。这个流程之所以是「特性而非缺陷」：它强制每个新包的哈希都来自**真实下载**，杜绝手抄错哈希的可能。第 42 章实战章会完整走一遍，包括 vendorHash（Go/Rust 依赖包哈希）的同款循环。

⚠️ 两个高频坑：

- 报错显示的 got 哈希对 **fetchurl（flat 模式）** 是「压缩包字节」的哈希，对 **fetchzip/fetchFromGitHub（recursive 模式）** 是「解压后内容」的哈希——两者不可混用（15.3.1 与 15.3.2 的语义差别）；
- 多次改 `hash` 后如果还 mismatch，检查是否 tag 指向变了（上游移动了 tag——⛔ 这正是要 pin rev 的原因）。

## 15.6 哈希何时会变：不变量与攻击面

一个心智模型：**哈希锚定的「身份」变了 ⟺ 输入集合变了**。常见触发：

- 上游源码变化（重发 tarball、force-push、tag 移动）；
- 你改了 fetcher 参数（`deepClone`、`leaveDotGit`、解压模式）；
- fetcher 本身的行为变化（历史上 fetchFromGitHub 曾因 GitHub tarball 生成方式改变而全仓库重算哈希）。

安全维度（呼应第 4 章边界）：固定输出校验保护你「拿到的东西与声明一致」，但不保证「上游本身没被投毒」——依赖审查、lockfile 审计（`nix flake lock` 的 diff）是补充手段。

## 15.7 内容寻址（CA derivations）：正在成形的未来

第 13 章提到的第三种模型——输出路径由**实际内容**决定——处于实验阶段（`ca-derivations` 特性）。它解决输入寻址的一个深层痛点：**两台机器独立构建同一输入，字节相同却各存一份**（因为路径由输入而非内容决定，缓存未命中时各自构建）。CA 化之后：

- 任何人构建出相同内容 → 相同路径 → 全局去重；
- 「相信构建结果」与「相信构建者」解耦，缓存生态的信任模型简化；
- 与 flakes 的锁文件配合，逼近「数学上可复现的软件供应链」。

截至 2026 年它仍未默认启用，但设计已稳定多年，是理解 Nix 演进方向的重要坐标。

## 15.8 本章小结

- 固定输出派生是「纯函数世界接入互联网」的唯一通道：声明哈希 → 允许联网 → 强制校验。
- fetcher 家族各有语义：fetchurl（flat 文件）、fetchzip/fetchFromGitHub（解压树）、fetchgit（完整仓库）；✅ 一律用 tag/rev 固定 + SRI 哈希。
- 四种哈希编码；`nix hash convert` 互转；SRI 是现行规范。
- 假哈希（lib.fakeHash）→ 报错回填真哈希，是唯一正确的获取哈希流程。
- 内容寻址是演进方向：从「相信输入」走向「相信内容」。

## 延伸阅读

- nixpkgs 手册 «Fetchers» 章节：https://nixos.org/manual/nixpkgs/unstable/#chap-pkgs-fetchers
- Nix 手册 «Advanced Attributes»（outputHash 三件套）：https://nixos.org/manual/nix/stable/language/advanced-attributes
- 第 36-38 章所有真实包例子的 `src` 都用本章 fetcher；第 42 章实战完整演练假哈希循环。
