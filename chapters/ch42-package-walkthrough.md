# 第 42 章 从零打包一个软件：完整实战

> **本章导读**：这是全书的压轴实战。我们选两个靶子——虚构但典型的 autotools C 项目「ghello」与 Go 语言 CLI「gcat」——从 fork nixpkgs、写第一版 package.nix 开始，经历假哈希、缺依赖、测试失败、安装路径错位等真实报错，一路打磨到 meta 完整、测试内建、可以提交 PR 的成品。请把它当作「陪练」：报错信息是本章的主角，你将来真正打包时遇到的八成问题，都会在本章的排错循环里出现过至少一次。

## 42.1 选靶：ghello 与 gcat

打包教学最大的尴尬是找一个体积合适、依赖典型、又不会过时的真实项目。本章用两个虚构项目代替，它们的形态刻意选得最「典型」：

- **ghello**：C 语言写的打招呼程序，用 GNU Autotools（autoconf/automake）构建，依赖 pkg-config 探测的 glib。它代表了海量「./configure && make && make install」式老牌 Unix 软件——nixpkgs 里最大的一类。
- **gcat**：Go 语言写的 cat 克隆，模块化依赖（go.mod + 一串间接依赖），版本号从 `--version` 输出。它代表现代语言生态，nixpkgs 为其提供了 buildGoModule 这样的专用构建函数（第 35 章讲过打包方式的分层）。

双案例是有意为之：前者教你 stdenv 的通用排错方法论（这方法论对任何语言都成立），后者教你「语言专用构建器 + 固定输出哈希」的现代套路。

**真实练习方式**：本章所有操作都在 nixpkgs 真实仓库里做，不新建任何东西。流程与真实贡献者完全一致：

```console
# ① 在 GitHub 上 fork NixOS/nixpkgs，然后克隆你的 fork
$ git clone --depth 1 git@github.com:yourname/nixpkgs.git
$ cd nixpkgs

# ② 拉齐官方仓库并建一个工作分支（避免直接在 master 上动土）
$ git remote add upstream https://github.com/NixOS/nixpkgs.git
$ git fetch upstream master
$ git checkout -b ghello-init upstream/master
```

之所以在真实 nixpkgs 里练，而不是在自己的 flake 里 `pkgs.callPackage ./foo.nix`：你会经历 `nixfmt` 格式检查、目录规范、meta 完整性这些「只有进了大仓库才会被强制」的约束，而正是这些约束让 nixpkgs 的十万个包保持可维护。规范本身在第 32 章有全景介绍，本章用到哪块讲哪块。

## 42.2 准备环境：目录规范与开发 shell

先回顾（参见第 32 章）：nixpkgs 的包定义集中在 `pkgs/` 下，传统入口是 `pkgs/top-level/all-packages.nix`。但 2024 年起，**新包一律走 `pkgs/by-name/`**（RFC 140），这是现在的硬性规范：

```
pkgs/by-name/
└── gh/                      # ← 双字母前缀：取包名前两个字符（ghello → gh）
    └── ghello/              # ← 目录名必须等于包名
        ├── package.nix      # ← 固定文件名；整个包的定义入口
        └── (补充文件)        # ← 可选：补丁、companion 模块、测试等，全部就近放置
```

by-name 的三条核心规则：

1. **双字母前缀**按包名前两个字符计算，避免单一目录下堆积数万条目（`pkgs/by-name/gh/ghello`、`pkgs/by-name/gc/gcat`）；
2. **目录自包含**：包的全部相关文件都住在自己的目录里，不允许把补丁丢到别处；
3. **自动暴露**：目录就位后 `pkgs.ghello` 自动可用，**不需要**（也不允许）再去 all-packages.nix 手工登记——旧式的 `hello = callPackage ../applications/misc/hello { };` 写法对新包已废弃。

接下来准备开发环境。nixpkgs 仓库根目录自带开发 shell：

```console
# ✅ 现代方式：flake 的 develop 环境（包含构建、校验所需工具）
$ nix develop

# ⛔ 经典方式：default.nix 的 nix-shell。仍然可用（老贡献者肌肉记忆），
#    但新工作流建议统一到 nix develop
$ nix-shell
```

进入后你拥有一个带完整 stdenv 工具链与 nixpkgs 校验脚本的环境。本实战主要在仓库根目录工作，构建和试错用下面三条命令（记住它们，本章会反复出现）：

```console
# 构建 ghello（. 由当前仓库 flake 解析，ghello 经 by-name 自动暴露）
$ nix build .#ghello

# 构建时直接把日志打到终端（排错必备，见 42.5）
$ nix build -L .#ghello

# 进入 ghello 的构建环境，手动复现各阶段（见 42.5）
$ nix-shell -A ghello        # 或：nix develop .#ghello
```

## 42.3 第一轮：骨架与假哈希循环

万事开头难，nixpkgs 社区把这个「开头」标准化成了著名的**假哈希约定（fake hash convention）**：你不可能凭空算出上游压缩包的哈希，所以第一版故意填一个众所周知的假哈希，让构建**必然**在下载校验处失败，再从报错里抄出真实哈希。

ghello 的第一版 `pkgs/by-name/gh/ghello/package.nix`：

```nix
# pkgs/by-name/gh/ghello/package.nix —— 第一版骨架
{
  lib,          # nixpkgs 的工具库：许可证列表、平台列表、维护者名单都在这
  stdenv,       # 标准构建环境：提供 CC、make 等与标准 phase（第 33 章）
  fetchurl,     # 经典下载器：下载 → 校验哈希 → 放入 store（第 15 章）
}:

stdenv.mkDerivation (finalAttrs: {
  # ✅ 现行写法：接收 finalAttrs 参数，包内引用自身属性不会因 rec 造成求值问题，
  #    也让 passthru/updateScript 等能引用「最终的这份派生」（第 34 章详述）
  # ⛔ 旧教程常见 { ... }: stdenv.mkDerivation rec { }，新代码不要再写 rec
  pname = "ghello";        # 包名，与 URL、meta、目录名保持一致
  version = "1.0.0";       # 上游版本号；name 会自动拼成 ghello-1.0.0

  src = fetchurl {
    # 发布 tarball 的地址；${finalAttrs.version} 引用上面，升版本只改一处
    url = "https://github.com/example/ghello/releases/download/v${finalAttrs.version}/ghello-${finalAttrs.version}.tar.gz";
    # 假哈希：lib.fakeHash 的值就是这串全 A 的 SRI 哈希。
    # 它「众所周知地错误」，构建必失败，失败信息里就有真哈希
    hash = lib.fakeHash;
  };

  # 依赖先不写——等报错告诉我们缺什么（42.4 的主线剧情）
  nativeBuildInputs = [ ];
  buildInputs = [ ];

  meta = {
    description = "A tiny greeting program with configurable salutations";
    homepage = "https://github.com/example/ghello";
    license = lib.licenses.gpl2Plus;        # 许可证只能从 lib.licenses 里取
    maintainers = [ ];                      # 42.6 再填上你自己
    mainProgram = "ghello";                 # 主程序名，供 nix run / getExe 使用
    platforms = lib.platforms.unix;         # 支持的平台集合
  };
})
```

然后跑第一次构建，迎接注定到来的失败：

```console
$ nix build -L .#ghello
...
error:
       … while evaluating the fixed-output derivation '/nix/store/p4z2…-ghello-1.0.0.tar.gz.drv'
       … in the hash mismatch on the output path '/nix/store/5qh8…-ghello-1.0.0.tar.gz'
         specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
         got:       sha256-11ZmSM3gqx1HOn1Kcjb9dNdVPSTnPP5x0c5MNcMPi98=
error: 1 dependencies of derivation '/nix/store/…-ghello-1.0.0.drv' failed to build
```

**把 `got:` 后面的 SRI 哈希原样抄回 package.nix**，第二次构建就会通过下载校验：

```nix
  src = fetchurl {
    url = "https://github.com/example/ghello/releases/download/v${finalAttrs.version}/ghello-${finalAttrs.version}.tar.gz";
    hash = "sha256-11ZmSM3gqx1HOn1Kcjb9dNdVPSTnPP5x0c5MNcMPi98=";  # 从报错抄回的真实哈希
  };
```

这就是官方推荐流程，它背后的道理值得想一层：**哈希只能来自真实下载，不能来自猜测**。SHA-256 是单向的，任何「算出来」「抄别的发行版」的捷径都是错的；而故意让构建失败一次，恰好是拿到真实哈希最短路径。这也解释了为什么别用 `nix store prefetch-file` 再 `--hash-type sha256` 之类绕路——两步并一步的假哈希法就是社区共识。

**fetchurl 与 fetchzip 的哈希语义差异**（呼应第 15 章）：两者的哈希都作用于固定输出派生（fixed-output derivation），但「固定」的对象不同：

- `fetchurl` 固定的是**压缩包字节**：哈希对着下载下来的 `.tar.gz` 文件本身算；
- `fetchzip` 固定的是**解压后的内容**：它下载、解压，再对解压出的目录算哈希。

因此同一个 URL，两种 fetcher 的哈希**不能互换**。经验法则：正规发布 tarball 用 fetchurl；上游只提供 GitHub 自动打包的 zip 源码包时用 fetchzip（自动包字节不稳定，但内容稳定）。另外，tarball 若来自 git tag 的自动打包（而非发布附件），字节可能随平台工具变化，此时更稳的选择是 `fetchFromGitHub`（按 commit rev 拉取，配 `hash` 字段）——42.7 的 Go 案例会用到。

## 42.4 迭代排错循环：四类经典报错

骨架通过后进入本章的主线：**改一版 → 构建 → 读报错 → 修 → 再构建**。下面四个剧本覆盖新手期绝大多数失败。每个剧本给完整报错样例与修复 diff。

### 剧本一：缺构建工具（nativeBuildInputs）

真实报错长这样（构建系统根本没生成 Makefile）：

```
error: builder for '/nix/store/m3yb…-ghello-1.0.0.drv' failed with exit code 2;
       last 10 log lines:
       > unpacking sources
       > unpacking source archive /nix/store/5qh8…-ghello-1.0.0.tar.gz
       > source root is ghello-1.0.0
       > patching sources
       > updateAutotoolsGnuConfigScriptsPhase
       > configuring
       > no configure script, doing nothing
       > building
       > make: *** No targets specified and no makefile found.  Stop.
```

根因：上游发布包里只有 `configure.ac` 与 `Makefile.am`，没带生成的 `configure` 脚本（有些项目就这样发版）。stdenv 的 configurePhase 找不到 `./configure`，一路空转到 buildPhase 崩溃。修复：

```nix
  # diff：新增一行
+ nativeBuildInputs = [ autoreconfHook ];
```

`autoreconfHook` 是个 setup hook（第 33 章）：往 nativeBuildInputs 一加，configurePhase 前会自动跑 `autoreconf -fi` 生成 configure 脚本。同类问题还有 `bison: command not found`、`yarn: command not found`——凡是「构建期间要在宿主侧运行的程序」缺失，都往 nativeBuildInputs 里补。

### 剧本二：configure 找不到依赖（buildInputs 与 pkg-config）

```
> checking for glib-2.0 >= 2.50... no
> configure: error: Package requirements (glib-2.0 >= 2.50) were not met:
>
> No package 'glib-2.0' found
>
> Consider adjusting the PKG_CONFIG_PATH environment variable if you
> installed software in a non-standard prefix.
```

根因：configure 脚本用 pkg-config 探测 glib，而构建环境里没有 glib 的 `.pc` 文件。要补**两样**东西：

```nix
  # diff：两行各就各位
- nativeBuildInputs = [ autoreconfHook ];
+ nativeBuildInputs = [ autoreconfHook pkg-config ];  # 探测工具在「构建时」运行 → native
+ buildInputs = [ glib ];                             # 库本体被链接进产物 → build
```

判定法（第 34 章有完整版，先记口诀）：**在构建过程中运行的工具放 nativeBuildInputs；编译链接时吃进产物的库和头文件放 buildInputs**。pkg-config 本身是工具（native），glib 是库（build）。stdenv 会自动把 buildInputs 的 `dev` 输出加进 `PKG_CONFIG_PATH`、`NIX_CFLAGS_COMPILE` 等环境变量——这正是 nixpkgs 无需 `/usr/include` 也能找到一切的秘密。

### 剧本三：测试失败或需要网络

```
> running tests
> PASS: test_greeting
> FAIL: test_remote
> ===================
> Connecting to example.com:80... failed: Network is unreachable
> FAIL 1 of 2 tests
error: builder for '/nix/store/…-ghello-1.0.0.drv' failed with exit code 2
```

根因：构建沙箱没有网络（第 16 章）。上游的某个测试想真的访问外网，这在 Nix 的模型里是非法需求。两种修法，优先细粒度：

```nix
  # ✅ 推荐：只关掉需要网络的那条测试（上游若提供了开关）
+ preCheck = ''
+   export GHELLO_SKIP_NETWORK_TESTS=1   # 假设上游认这个变量；没有开关见下
+ '';

  # ⚠️ 图省事：整个跳过测试。能用，但损失了其余测试的保障，
  #    PR 评审可能要求你说明理由
+ doCheck = false;
```

若上游没有开关，还可以在 postPatch 里把该测试从列表里删掉，或者（更好的长期主义）给上游提 issue/PR 加开关。**不要**为了联网测试去关沙箱——所有联网需求都必须改造成 fetchers 在固定输出派生里完成（第 16 章的原则，第 46 章问题「沙箱内无网络」还会复盘）。

### 剧本四：install 阶段路径问题

```
> installing
> make[1]: Entering directory '/build/ghello-1.0.0'
> install -D ghello /usr/bin/ghello
> install: cannot create regular file '/usr/bin/ghello': No such file or directory
error: builder for '/nix/store/…-ghello-1.0.0.drv' failed with exit code 2
```

根因：上游 Makefile 的安装前缀默认 `/usr`，而 Nix 的世界观里一切产物必须进 `$out`（第 33 章）。GNU 风格项目尊重 `--prefix`，stdenv 已自动传了；但这个项目用的是自制的 `PREFIX` 变量，没接住。修复：

```nix
  # diff：把 PREFIX 指到 $out（$(out) 在 make 里展开为 store 路径）
+ installFlags = [ "PREFIX=$(out)" ];
```

判定与选择：先看 `make install` 到底读哪个变量（读 Makefile 或 `./configure --help`）。标准变量是 `--prefix`（已自动）；`PREFIX=` 用 installFlags 或 makeFlags；`DESTDIR=` 则要小心——DESTDIR 是打包时的「暂存根」，路径会被原样写进产物，Nix 下通常应当用 prefix 而非 DESTDIR（store 路径要真实出现在二进制里，运行时才找得到动态库）。

四幕剧演完，`nix build -L .#ghello` 通过，`./result/bin/ghello` 能跑——最难的阶段过去了。

## 42.5 手动排错环境：把构建拿在手里

报错信息不够时，最好的办法是钻进构建环境手动复现。stdenv 把构建拆成了若干 phase（第 33 章），在交互 shell 里这些 phase 是**可以直接调用的函数**：

```console
# 进入 ghello 的构建环境（含源码已解压的副本机制由各 phase 自理）
$ nix-shell -A ghello
# 或 flake 风格：$ nix develop .#ghello

[nix-shell]$ cd "$(mktemp -d)"     # 到干净目录操作，别污染仓库
[nix-shell]$ unpackPhase           # 解压 src 到当前目录（$sourceRoot）
[nix-shell]$ cd ghello-1.0.0
[nix-shell]$ configurePhase        # 跑 ./configure，可手动加参数试验
[nix-shell]$ buildPhase            # make
[nix-shell]$ installPhase          # make install 到 $out
[nix-shell]$ echo $out             # 交互 shell 里 $out 指向一个临时 store 路径
```

这套流程的价值在于**变量与真实构建一字不差**：`PKG_CONFIG_PATH`、`NIX_CFLAGS_COMPILE`、`PATH` 里的工具链，全是 stdenv 组装好的原班人马。configure 报找不到依赖时，先在这里看 `echo $PKG_CONFIG_PATH`、`pkg-config --modversion glib-2.0` 手验证，比盲改 package.nix 快得多。

看日志的三个入口：

```console
# ① 构建时同步输出日志（最常用，失败现场直接可见）
$ nix build -L .#ghello

# ② 事后查看某个已构建（或构建失败）目标的日志
$ nix log .#ghello

# ③ 从上一次失败继续交互调试：KFS 环境 + 复用已完成的下载
$ nix-shell -A ghello --arg config '{ allowBroken = true; }'   # 按需传参
```

## 42.6 打磨：meta、测试与安装后校验

能构建只是及格线。一个「nixpkgs 品质」的包还需要三块打磨，风格与第 36-38 章的真实案例一致。

### 42.6.1 meta 全字段

```nix
  meta = {
    description = "A tiny greeting program with configurable salutations";
    # description 规范：小写开头、不以句号结尾、说「是什么」而不是「好厉害」

    longDescription = ''
      ghello prints a friendly greeting. It supports custom salutations,
      locale-aware punctuation and reads names from stdin.
    '';                                        # 可选：给需要更多上下文的人看

    homepage = "https://github.com/example/ghello";
    changelog = "https://github.com/example/ghello/blob/v${finalAttrs.version}/NEWS";

    license = lib.licenses.gpl2Plus;           # ✅ 必须从 lib.licenses 取，不许手写字符串
    # ⛔ license = "GPLv2+"; —— 旧代码里的裸字符串已弃用

    maintainers = [ lib.maintainers.yourname ];
    # 维护者契约：你会在该包出问题时被 ping、包需要大改动时被征求意见、
    # 上游失效时负责标记 broken。加入前先在 maintainers/maintainer-list.nix
    # 登记自己的 GitHub 账号与联系方式（PR 里一并提交）

    mainProgram = "ghello";                    # nix run nixpkgs#ghello 与 lib.getExe 的落点
    platforms = lib.platforms.unix;            # 有把握再写 all；不确定就先收窄
  };
```

### 42.6.2 安装后校验：doInstallCheck + versionCheckHook

nixpkgs 提供了一个 setup hook 专门校验「版本号没打错」：它在 installCheck 阶段运行 `ghello --version`，断言输出里含 `version` 字符串。版本号靠手工同步、错一位就静默装旧版的经典事故，由此被挡在门外：

```nix
{
  lib, stdenv, fetchurl,
  autoreconfHook, pkg-config, glib,
  versionCheckHook,           # 来自 nixpkgs 全局 setup hooks，直接可用
}:

stdenv.mkDerivation (finalAttrs: {
  # ……前略……

  # ✅ 现行推荐：开启安装后检查 + 版本校验钩子
  doInstallCheck = true;
  nativeBuildInputs = [ autoreconfHook pkg-config versionCheckHook ];
  # versionCheckHook 被加进 nativeBuildInputs 后，
  # 会在 installCheckPhase 自动运行 $out/bin/ghello --version 并匹配版本
})
```

### 42.6.3 passthru.tests：把冒烟测试挂进 CI

`passthru.tests` 里放的是「不阻塞本包构建、但会在 ofBorg/CI 里被求值与运行」的测试。最简单的冒烟测试用 runCommand（记得把它加进文件头部的函数参数列表）：

```nix
  passthru = {
    # runCommand：跑一段脚本，成功（touch $out）即测试通过
    tests.smoke = runCommand "ghello-smoke-test" { }
      ''
        # lib.getExe 直接给出可执行文件的 store 绝对路径，无需操作 PATH
        ${lib.getExe finalAttrs.finalPackage} --version | grep -q "${finalAttrs.version}"
        ${lib.getExe finalAttrs.finalPackage} World | grep -q "Hello, World"
        # runCommand 的惯例：成功则创建 $out
        touch $out
      '';
    # 有余力还可以加 updateScript（配合 nixpkgs-update 机器人自动升版本）
    # updateScript = nix-update-script { };
  };
```

至此 ghello 的 package.nix 已经是一份「能进主干」的成品。回头数一下：从骨架到成品，我们动了哈希一次、依赖两次、测试一次、安装一次——每一步都是被具体报错推着走的。这就是打包的常态。

## 42.7 Go 案例第二遍：buildGoModule

同样的方法论跑一遍 gcat，你会发现现代语言构建器的套路惊人地一致——**还是假哈希循环**，只是这次要填两个。

`pkgs/by-name/gc/gcat/package.nix` 第一版：

```nix
{
  lib,
  buildGoModule,          # Go 专用构建器：处理 GOPATH、vendor 目录、go build
  fetchFromGitHub,        # 按 commit 拉 git 仓库，比自动打包的 tarball 更稳定
}:

buildGoModule (finalAttrs: {
  pname = "gcat";
  version = "0.3.0";

  src = fetchFromGitHub {
    owner = "example";
    repo = "gcat";
    tag = "v${finalAttrs.version}";   # tag 也是引用方式之一，底层等价于锁定 rev
    hash = lib.fakeHash;              # 假哈希 ①：源码本身
  };

  vendorHash = lib.fakeHash;          # 假哈希 ②：依赖模块树（go.sum 对应物的哈希）

  # 注入版本号：Go 程序惯用 -X 链接参数把版本写进包级变量
  ldflags = [
    "-s" "-w"                               # 去符号表与 DWARF，减小体积（可选）
    "-X main.version=v${finalAttrs.version}"  # main.version 是上游约定的变量路径
  ];

  meta = {
    description = "A tiny cat(1) clone written in Go";
    homepage = "https://github.com/example/gcat";
    license = lib.licenses.mit;
    mainProgram = "gcat";
    platforms = lib.platforms.unix;
    maintainers = [ lib.maintainers.yourname ];
  };
})
```

第一次构建，先炸源码哈希（与 42.3 完全同款），抄回真值；第二次构建，轮到依赖树：

```
error: hash mismatch in fixed-output derivation '/nix/store/zq4k…-gcat-0.3.0-go-modules.drv':
         specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
         got:       sha256-eiTK6tGkjjDQzVDOSSK76iVXpPNlBAftgWtN3Z9FZXA=
```

把 `got:` 抄进 `vendorHash`，第三次构建通过。这就是 buildGoModule 的工作方式：它先把你的依赖抽出来放进一个**独立固定输出派生**（`-go-modules`），保证「拉取依赖」这步需要网络的操作被隔离在可复现的盒子里（呼应第 16 章），正式构建时完全离线。所以有两把哈希锁，也就有两轮假哈希。

多模块仓库的小抄：源码在子目录时加 `subPackages = [ "cmd/gcat" ];` 指定入口；`vendorHash = null` 用于上游已自带 vendor 目录的项目。装好后验证版本注入是否生效：

```console
$ nix build -L .#gcat && ./result/bin/gcat --version
gcat version v0.3.0
```

## 42.8 贡献回上游：从本地成品到 nixpkgs PR

本地绿了，接下来把包送进 nixpkgs 主干，流程本身就是一次小型协作演练。

**commit message 有硬约定**：格式为「包名: 动作 at 版本」。新包是 `init at`，升级是 `v1.0.0 -> v1.1.0`。一个包一个 commit，方便评审与日后 `git log -- pkgs/by-name/gh/ghello` 追溯：

```console
# 只提交本包目录，别把无关文件卷进来
$ git add pkgs/by-name/gh/ghello
$ git commit -m "ghello: init at 1.0.0"
$ git push -u origin ghello-init
```

提交 PR 后，**ofBorg** 机器人会自动出现（它在第 41 章的 CI 全景里出过场）：默认执行 hydra 求值检查，验证你的包在全部平台上能被求值；也可以在 PR 评论里显式点菜：

```text
@ofborg build ghello        # 让 ofBorg 实际构建这个包
@ofborg eval                # 只做全量求值检查
```

ofBorg 的回复会贴在 PR 里，构建成功是最有说服力的「自我介绍」。提交前自查一遍重建范围：如果 ofBorg 显示你的改动会引发**大量重建**（依赖你包的东西太多），按 nixpkgs 规则需要改走 **staging 分支**再合并，让 Hydra 慢慢消化，避免堵塞 master。配套工具 nixpkgs-review 可以本地预演「重建范围内还有哪些包会坏」：

```console
# 对一个已打开的 PR 做受影响包的构建评审
$ nix run github:Mic92/nixpkgs-review -- pr 123456
```

评审环节的常见反馈：meta 字段补全、测试禁用理由、license 与上游 LICENSE 文件不一致等。维护者（maintainers 列表里的人）会收到 ping。小包通常几天内合并；被要求修改时直接 push 到同一分支即可，PR 会自动更新。

## 42.9 收尾 checklist

提交 PR 前对照打勾，能挡掉九成评审意见：

- [ ] 目录正确：`pkgs/by-name/<双字母前缀>/<包名>/package.nix`，无多余文件；
- [ ] 哈希为 SRI 格式（`sha256-...=`），来自真实报错回填，无裸 64 位十六进制旧写法；
- [ ] `license` 取自 `lib.licenses`，与上游 LICENSE 文件一致；
- [ ] `description` 遵循规范（小写开头、无句号、描述性）；
- [ ] `mainProgram`、`platforms` 已填；`maintainers` 已登记自己；
- [ ] `doInstallCheck = true` + versionCheckHook（适用时）；`passthru.tests` 至少一个冒烟测试；
- [ ] 测试若被跳过，有注释说明理由（沙箱无网络等）；
- [ ] `nixfmt` 格式化：`nix shell nixpkgs#nixfmt -- nixfmt pkgs/by-name/gh/ghello/package.nix`；
- [ ] 本地 `nix build -L .#ghello` 通过，`nix flake check`（在仓库根）无新报错；
- [ ] commit message 符合 `pkg: init at x.y.z` 约定，PR 描述包含上游链接与测试记录。

## 42.10 本章小结

- 新包一律走 `pkgs/by-name/<双字母前缀>/<包名>/package.nix`（RFC 140）：目录自包含、自动暴露为 `pkgs.<pkg>`，不再手写 all-packages.nix。
- 假哈希约定是官方推荐起步法：`hash = lib.fakeHash` 让构建必失败，从报错的 `got:` 抄回真实 SRI 哈希——哈希只能来自真实下载。
- fetchurl 哈希对压缩包字节，fetchzip 哈希对解压后内容，两者不可互换；自动打包的源码包优先改用 fetchFromGitHub。
- 排错四剧本：缺构建工具补 nativeBuildInputs；configure 找不到依赖补 buildInputs 加 pkg-config；测试要网络优先细粒度跳过；安装路径用 installFlags/makeFlags 把前缀指到 $out。
- `nix-shell -A 包名`（或 `nix develop .#包名`）进入与真实构建完全同质的环境，phase 是可调用的函数，是最强的排错手段。
- 打磨三件套：完整 meta（license 从 lib.licenses 取、登记 maintainer、mainProgram）、doInstallCheck + versionCheckHook、passthru.tests 冒烟测试。
- buildGoModule 重复同一套循环：源码 hash 与 vendorHash 两个假哈希各炸一次；ldflags 的 `-X main.version=...` 注入版本号。
- 贡献约定：commit message `pkg: init at x.y.z`、ofBorg 自动求值/构建检查、大重建走 staging 分支、提交前过一遍收尾 checklist。

## 延伸阅读

- nixpkgs 贡献指南（CONTRIBUTING.md）—— https://github.com/NixOS/nixpkgs/blob/master/CONTRIBUTING.md
- nixpkgs 手册：向 Nixpkgs 添加软件包 —— https://nixos.org/manual/nixpkgs/unstable/#sec-contributing
- RFC 140：by-name 目录规范 —— https://github.com/NixOS/rfcs/blob/master/rfcs/0140-simple-package-paths.md
- `pkgs/by-name/README.md`（随仓库更新的权威细则）—— https://github.com/NixOS/nixpkgs/blob/master/pkgs/by-name/README.md
- Nix 手册：固定输出派生 —— https://nixos.org/manual/nix/stable/language/derivations.html
- nixpkgs-review —— https://github.com/Mic92/nixpkgs-review
