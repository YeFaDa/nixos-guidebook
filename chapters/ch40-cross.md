# 第 40 章 交叉编译

> **本章导读**：在 x86 工作站上编出能跑在树莓派上的程序，在 Linux 上编出 Windows 的 exe，把一个静态链接的单文件二进制扔进最小容器——这些都是交叉编译（cross compilation）的领地。Nix 把「目标平台」做进了求值模型本身：同一份包配方，换一个入口就自动为别的平台求值。本章讲清 build/host/target 三元组、`pkgsCross` 全景、模拟执行、静态链接，以及如何让自己的包可交叉。

## 40.1 问题定义：build、host、target 三元组

交叉编译的第一步是把三个「平台」概念掰开。它们在 Nix 里的名字是 `stdenv.buildPlatform`、`stdenv.hostPlatform`、`stdenv.targetPlatform`：

- **build platform（构建平台）**：跑编译器的机器——就是你现在敲命令的这台工作站。
- **host platform（宿主平台）**：跑构建产物的机器——树莓派、ARM 服务器、Windows。
- **target platform（目标平台）**：构建产物**再产出代码**时面向的机器。它只对「产物本身是代码生成器」的东西有意义：编译器、汇编器、链接器。hello 这种普通程序没有 target 的概念。

三种典型场景对号入座：

| 场景 | build | host | target |
| --- | --- | --- | --- |
| 在 x86_64 工作站编译本机运行的 hello | x86_64-linux | x86_64-linux | （无意义） |
| 在 x86_64 工作站为树莓派 5 编译 hello | x86_64-linux | aarch64-linux | （无意义） |
| 在 x86_64 Linux 上构建「跑在 Windows 上、生成 aarch64 代码的 GCC」 | x86_64-linux | x86_64-windows | aarch64-linux |

每个平台在 nixpkgs 里都有一个 `config` 字符串（三元组风格），例如 `"x86_64-unknown-linux-gnu"`、`"aarch64-unknown-linux-musl"`、`"x86_64-w64-mingw32"`。判定当前是否本机构建的标准写法是：

```nix
stdenv.buildPlatform == stdenv.hostPlatform   # 本机构建;不等即交叉
```

在 repl 里亲手摸一下这三个属性，比读十遍定义都有效：

```console
$ nix repl -f '<nixpkgs>'
nix-repl> pkgs.stdenv.buildPlatform.config
"x86_64-unknown-linux-gnu"
nix-repl> pkgs.stdenv.hostPlatform.config
"x86_64-unknown-linux-gnu"        # build == host:本机构建
nix-repl> pkgsCross.mingwW64.stdenv.hostPlatform.config
"x86_64-w64-mingw32"              # 换个入口,host 变成 Windows
```

**为什么交叉编译在 Nix 里格外自然**？传统做法里，交叉意味着你手工安装一套 mingw 工具链、祈祷 `./configure --host=...` 能找到它、再祈祷 `PKG_CONFIG_PATH` 指向对的目录。而在 Nix 中，host platform 是**nixpkgs 实例化的一个参数**（呼应第 32 章）：换掉这个参数，整个包集合据此重新求值，第 34 章以来你读过的每一份包配方一个字都不用改——同一份配方，任意平台。这是「包集合是纯函数」的又一次兑现。

**为什么交叉时必须严格区分两类依赖**？这正是第 34 章埋下伏笔的地方。`nativeBuildInputs` 与 `buildInputs` 不只是「优先级不同」，而是**平台归属不同**：

- `nativeBuildInputs`（原生构建输入）：构建期在 build 平台上**运行**的工具——gcc、make、pkg-config、cmake。交叉时它们必须仍是本机程序。
- `buildInputs`（构建输入）：被链接进产物、将来在 host 平台上存在的东西——库、头文件、数据文件。交叉时它们必须是目标平台的版本。

装反了会怎样？给 aarch64 程序链接 x86 的 OpenSSL，会在链接期直接报「file format incompatible」之类的错误；把交叉 gcc 放进 buildInputs 则构建脚本会试图「运行」它。报错长这样（措辞随工具链浮动，关键词是 file format）：

```text
/usr/bin/ld: /nix/store/…-openssl-3.x.x-x86_64-linux/lib/libssl.so:
file format not recognized: file format not recognized
collect2: error: ld returned 1 exit status
```

第 34 章的定义之所以严格，就是为了在交叉时不出错。

nixpkgs 内部通过 **splicing（拼接）** 落实这套区分：包集合被切成四份，`mkDerivation` 在求值依赖时按「这个 input 将在哪个世界使用」自动取自正确的份：

| 拼接集合 | 内容运行于 | 服务于 | 对应的 inputs |
| --- | --- | --- | --- |
| `pkgsBuildBuild` | 构建机 | 构建机工具自身的构建 | 极少手写（工具链的工具链） |
| `pkgsBuildHost` | 构建机 | 目标机产物的**构建** | `nativeBuildInputs` |
| `pkgsHostTarget` | 目标机 | 目标机产物的**运行** | `buildInputs` |
| `pkgsTargetTarget` | （产物所面向的）目标机 | 编译器类产物的输出 | 仅 gcc/汇编器等 |

普通包作者只需要记住中间两行：**在构建机上跑的进 nativeBuildInputs，活在目标机里的进 buildInputs**，splicing 会办好剩下的一切。作为使用者你通常感知不到这套机制的存在——直到某个包归类错了，它才会以报错的方式现身。

## 40.2 nixpkgs 的交叉世界入口：pkgsCross 全景

第 32 章说过 `pkgs` 是「用一组参数实例化的 nixpkgs」。交叉的入口就是换掉其中一个参数（`crossSystem`），而 `pkgsCross`（交叉包集合）把这个操作封装成了属性：

```nix
# 下面两件事等价(示意;真实 crossSystem 结构更丰富,以 lib/systems 为准)
import <nixpkgs> {
  localSystem = { system = "x86_64-linux"; };
  crossSystem = { config = "aarch64-unknown-linux-gnu"; };
}
# == pkgsCross.aarch64-multiplatform
```

两个实用细节：其一，flake 里 `pkgsCross` 挂在 `legacyPackages` 输出之下，所以 `nixpkgs#pkgsCross.<name>.<pkg>` 这种写法开箱即用；其二，`pkgsCross.<name>` 本身是一套**完整的包集合**——不是「几个交叉包」，而是整个 nixpkgs 换了一双眼睛重新求值，你可以在里面继续写 `pkgsCross.aarch64-multiplatform.python3Packages.foo`。渠道用户同样从同一份 `import <nixpkgs>` 的结果上拿到它。

常用入口一览（完整清单见 nixpkgs 源码 `pkgs/top-level/cross-packages.nix` 与 `lib/systems/examples.nix`，以源码为准）：

| pkgsCross 名 | 目标平台 | 典型用途 |
| --- | --- | --- |
| `aarch64-multiplatform` | aarch64-linux（glibc） | 树莓派 4/5、ARM 服务器、Apple Silicon 虚机 |
| `aarch64-multiplatform-musl` | aarch64 musl | 极简镜像、静态友好场景 |
| `armv7l-hf-multiplatform` | armv7 硬浮点 | 32 位 ARM 板卡（不少工控板、旧手机方案） |
| `raspberryPi` | armv6 | 树莓派 1/Zero（较老，状态以源码为准） |
| `armhf-embedded` / `aarch64-embedded` | 裸机 ELF（无 OS） | 固件、bootloader、嵌入式工具链 |
| `gnu64` | x86_64-linux | 在 32 位环境编 64 位目标等场景 |
| `gnu32` | i686-linux | 32 位目标 |
| `musl64` / `musl32` | x86_64 / i686 musl | 进入 musl 世界（40.5 节） |
| `mingwW64` / `mingw32` | x86_64 / i686 Windows（PE） | 交叉产出 Windows 程序 |
| `avr` | AVR 裸机 | 单片机工具链（avr-gcc 等） |
| `riscv64` | riscv64-linux | RISC-V 设备（可用性随上游演进） |
| `ppc64` | powerpc64-linux | POWER 平台 |
| `wasm32-wasi` | WebAssembly (WASI) | 实验性，以源码为准 |

**交叉 stdenv 的自举**值得用一段话讲清，因为它是「为什么交叉这么慢但可靠」的答案。为 aarch64 构建任何东西之前，nixpkgs 要先凭空造出一整套交叉工具链，大致分四步：

| 阶段 | 用什么构建 | 产出 | 为什么必须分这一步 |
| --- | --- | --- | --- |
| ① | 本机 bootstrap 工具 | 交叉 binutils | 先有「能产出目标机目标文件的汇编器/链接器」 |
| ② | ①的产物 | 最小交叉 GCC | 此时还没有目标机 libc，只能编 freestanding 代码 |
| ③ | ②的产物 | 目标机 libc（glibc/musl） | 关键一步：从此目标机有了运行时 |
| ④ | ②③的产物 | 完整交叉 GCC + stdenv | 能编普通程序与 C++ 标准库，最终成型 |

每一步的产物都是 store 里的普通派生（第 13-16 章），可缓存、可复现、可单独复用。这也是交叉构建首次很慢、之后很爽的原因：工具链一旦编好（或从缓存拿到），后续每个包的构建与本机构建体验一致。而且整条链是「内容寻址」的（第 14 章）——GCC 升级或 libc 换版本，只会让链的后缀重算，前缀照样命中缓存。

想亲眼看这条自举链，查一下交叉 GCC 派生的输入：

```console
$ nix store -q --references \
    $(nix path-info --derivation nixpkgs#pkgsCross.aarch64-multiplatform.gcc)
# 输出里的 .drv 引用大致是:binutils → 最小 gcc → glibc → … 的链路
```

（不同版本阶段数略有出入，以 `pkgs/stdenv` 相关源码与官方手册为准。）

## 40.3 实操三例

### 例一：为树莓派/ARM 服务器构建 hello

```console
$ nix build nixpkgs#pkgsCross.aarch64-multiplatform.hello
$ file ./result/bin/hello
./result/bin/hello: ELF 64-bit LSB pie executable, ARM aarch64, version 1 (SYSV),
dynamically linked, interpreter /nix/store/…-glibc-aarch64-…/ld-linux-aarch64.so.1, …
```

`file` 命令确认了架构归属：`ARM aarch64`、解释器指向 aarch64 版 glibc——尽管它此刻躺在 x86 机器的 store 里。aarch64 是 Hydra 的官方构建架构之一，多数常用包能直接从 cache.nixos.org 命中（第 20 章）；冷门目标则可能触发包括工具链在内的本地构建，耗时以小时计。

产物怎么送到目标机？直接 `scp result/bin/hello` 是能跑的（前提是目标机 glibc 兼容），但 Nix 的正解是**搬闭包**（第 17 章）——把运行所需的整棵依赖树一起送达：

```console
# --print-out-paths 打印 store 路径;把闭包拷到目标机的 store
$ nix copy --to ssh://pi@raspberrypi \
    $(nix build --print-out-paths nixpkgs#pkgsCross.aarch64-multiplatform.hello)
# 目标机(装了 Nix 的)从此拥有完整依赖树,升级/回滚都是普通 Nix 操作
```

想在本机跑它？直接执行会得到 `Exec format error`。解决之道见 40.4 节的模拟执行。

### 例二：为 Windows 构建 mingwW64

```console
$ nix build nixpkgs#pkgsCross.mingwW64.hello
$ ls result/bin
hello.exe
$ file result/bin/hello.exe
result/bin/hello.exe: PE32+ executable (console) x86-64, for MS Windows
```

产出一个 Windows 控制台程序 `hello.exe`，可以拷给 Windows 同事直接运行（是否依赖 DLL 取决于具体包与链接方式）。没有 `file` 命令时用 `readelf`/`objdump` 也能验证架构，思路相同：

```console
$ nix shell nixpkgs#binutils -c readelf -h result/bin/hello.exe | grep Machine
  Machine:                           Advanced Micro Devices X86-64
```

对 mingw 目标要清醒的是：收录的包远少于 Linux 世界，复杂 GUI 栈、依赖内核特性（/proc、systemd、glibc 专有扩展）的软件大多不可用；能顺利交叉的多是 CLI 工具与自带依赖管理的现代语言产物（Rust、Go 生态对交叉默认友好）。分发时还要留意 Windows 侧的常客问题：路径分隔符、行尾、以及产物是否依赖 mingw 运行时 DLL——要么静态链接，要么把 DLL 一起打包。

### 例三：平台过滤——架构无关的检查

包的可用平台由 `meta`（元数据）控制，这是打包者的声明：

```nix
# package.nix(节选)
meta = {
  platforms = lib.platforms.linux ++ lib.platforms.darwin;  # 白名单:仅这些 host 平台可构建
  # badPlatform 是反向刀:从 platforms 里再剔除若干平台
  # badPlatform = lib.platforms.i686;  # 例如:32 位下编译不过,显式排除
};
```

判定函数是 `lib.availableOn`（是否可用）：判断「某包在给定 host 平台上是否可构建」。Hydra 用它过滤任务；你在自己的代码里也可以直接断言（`assert` 语义见第 12 章）：

```nix
# 求值期断言依赖可用,比构建期报错早得多
assert lib.availableOn stdenv.hostPlatform openssl;
```

在 nix repl 里观察两个世界的平台标识：

```console
$ nix repl -f '<nixpkgs>'
nix-repl> pkgsCross.aarch64-multiplatform.stdenv.hostPlatform.config
"aarch64-unknown-linux-gnu"
nix-repl> lib.availableOn pkgs.stdenv.hostPlatform pkgs.hello
true
```

构建一个 `meta.platforms` 不含当前平台的包，会在求值/选择期就被拦下，报错大意是「package … is not available on the requested hostPlatform」——比构建两小时后在链接期爆炸友好得多。这正是「把平台做成数据」的好处。

### 附：pkgsCross 与 packages.aarch64-linux 的区别

flake 用户很快会发现另一条路：`nixpkgs#packages.aarch64-linux.hello`。它同样产出 aarch64 二进制，但语义与 pkgsCross 完全不同：

```console
$ nix build nixpkgs#packages.aarch64-linux.hello          # aarch64 的「原生」树
$ nix build nixpkgs#pkgsCross.aarch64-multiplatform.hello # 交叉树
```

| | `packages.aarch64-linux` | `pkgsCross.aarch64-multiplatform` |
| --- | --- | --- |
| 语义 | 目标机的**原生**构建（build == host == aarch64） | **交叉**构建（build = 你的机器，host = aarch64） |
| 自举 | aarch64 自己的 bootstrap（构建期程序常靠 binfmt 模拟执行） | 你机器上的交叉工具链 |
| 构建脚本 | 会运行目标机二进制（configure 探测、测试） | 构建期全程本机程序，产物不能直接跑 |
| 典型场景 | 目标机就是部署平台：整系统镜像、installer | 在主力机上顺手产出目标机二进制 |

选择的经验法则：给目标机做**完整系统**（树莓派 SD 镜像、ARM 服务器的 installer）走原生树路线（配合 40.4 的 binfmt 让构建期的目标机程序可跑）；只是**产一个目标机二进制**，pkgsCross 更快更省心。

## 40.4 模拟执行：让交叉产物在 x86 主机上跑起来

交叉构建有个天然尴尬：产物没法直接运行，测试就成了问题。NixOS 的答案是 binfmt（二进制格式注册）：内核的 binfmt_misc 机制可以把「未知魔数的可执行文件」透明地交给用户态模拟器。NixOS 把它封装成了一个选项：

```nix
# configuration.nix
{ ... }: {
  # 注册 aarch64-linux 的用户态模拟(qemu-user + binfmt_misc)
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
}
```

`nixos-rebuild switch` 之后，aarch64 二进制可以「原生地」执行：

```console
$ nix build nixpkgs#pkgsCross.aarch64-multiplatform.hello
$ ./result/bin/hello          # 内核自动转交 qemu-aarch64 执行
Hello, world!
```

注册是否生效，可以在主机侧查证——binfmt_misc 本质是内核暴露的一张「魔数 → 解释器」注册表：

```console
$ ls /proc/sys/fs/binfmt_misc/
qemu-aarch64  register  status
$ cat /proc/sys/fs/binfmt_misc/qemu-aarch64
enabled
interpreter /nix/store/…-qemu-user-…/bin/qemu-aarch64
flags: OCF
# (flags 与 magic 字段随注册脚本而异,以实际输出为准)
```

代价与边界：qemu-user 是系统调用翻译，性能有损耗（通常可接受）；个别依赖古怪 ioctl 或特权的程序会行为异常；它模拟的是用户态，不是整机（整机模拟走 QEMU system 模式，NixOS VM 测试框架大量使用之，参见第 41 章）。

也可以绕过 binfmt 手动调模拟器——理解这套机制的最佳方式：

```console
$ nix shell nixpkgs#qemu
$ qemu-aarch64 ./result/bin/hello    # 显式把产物交给 qemu-user 执行
Hello, world!
```

binfmt 与下文的 `hostPlatform.emulator` 底层用的都是它：binfmt 只是把「文件魔数 → qemu」的映射注册进内核，让 shell 里的直接执行成为可能。

模拟执行还有一个高价值用途——**在 x86 主机上构建完整的树莓派系统**。为 aarch64 构建整套 NixOS 镜像时，构建期偶尔需要运行目标机程序（configure 探测、安装脚本），声明目标平台 + 注册 binfmt 后这些程序由 qemu 代跑：

```nix
# 树莓派镜像配置骨架(示意)
{ ... }: {
  # 声明这台机器是 aarch64 —— 整个 pkgs 求值成 aarch64 的原生树
  nixpkgs.hostPlatform.system = "aarch64-linux";
  # 配合构建主机上的 boot.binfmt.emulatedSystems = [ "aarch64-linux" ],
  # 少量构建期目标机程序即可透明运行(镜像细节以 NixOS 手册与
  # nixos-hardware 仓库为准)
}
```

这正是 40.3 附表中「原生树 + 模拟执行」路线的落地：慢于纯交叉，但求值语义与真机完全一致，整系统构建的事实标准。

**`stdenv.hostPlatform.emulator` 的机制**是这套思路在打包层的延伸：每个 host 平台都知道「如何运行自己的产物」——本机构建时它是一个**空字符串**，交叉时它是 qemu 或 wine 的调用前缀。于是同一份测试代码可以两栖：

```nix
# installCheck 的跨平台写法(示意)
installCheckPhase = ''
  runHook preInstallCheck
  # ${stdenv.hostPlatform.emulator}:
  #   本机构建时展开为空 —— 直接运行
  #   交叉 aarch64 时展开为 qemu-aarch64 —— 模拟运行
  #   交叉 mingw  时展开为 wine64    —— Wine 运行
  ${stdenv.hostPlatform.emulator} $out/bin/myapp --version > /dev/null
  runHook postInstallCheck
'';
```

第 37 章讲过的 ripgrep 用 Wine 跑 `installCheck` 的例子，本质上就是这个机制：mingw 目标的 `hostPlatform.emulator` 指向 Wine，`rg --version` 在构建期被透明地「在 Windows 语义下」执行了一遍。

## 40.5 静态链接：pkgsStatic 与 pkgsMusl

「完全静态链接」与「交叉」共享同一套平台模型——你可以把「静态世界」理解成一个特殊的交叉目标。nixpkgs 给了两个入口：

- `pkgsStatic`（静态包集合）：强制产物尽量完全静态链接。默认配合 glibc 静态库；glibc 对静态支持不佳时（见下文坑），musl 是更稳的基底。
- `pkgsMusl`（musl 包集合）：整个世界换用 musl libc——动态链接，但运行时极小。

```console
$ nix build nixpkgs#pkgsStatic.hello
$ file ./result/bin/hello
./result/bin/hello: ELF 64-bit LSB executable, x86-64, version 1 (SYSV), statically linked
$ ldd ./result/bin/hello
not a dynamic executable
$ nix store -q --requisites ./result | wc -l
1
```

最后一行是点睛之笔：完全静态二进制的闭包（第 17 章）**只剩它自己**。对比一下同一批入口的闭包规模（数量随版本浮动，量级是稳定的）：

| 入口 | 链接方式 | hello 闭包规模 |
| --- | --- | --- |
| `nixpkgs#hello` | glibc 动态 | 约 10 个路径（glibc、locale 等） |
| `nixpkgs#pkgsMusl.hello` | musl 动态 | 约 2-3 个路径（二进制 + musl） |
| `nixpkgs#pkgsStatic.hello` | 静态 | 1 个路径 |

亲手验证这组数字（闭包查询是第 17 章的工具）：

```console
# 多个产物同时构建:out-link 依次编号为 result result-1 result-2
$ nix build nixpkgs#hello nixpkgs#pkgsMusl.hello nixpkgs#pkgsStatic.hello
$ ldd result-1/bin/hello           # musl 动态版:解释器是 musl 的加载器
        linux-vdso.so.1
        /nix/store/…-musl-…/lib/ld-musl-x86_64.so.1
$ nix store -q --requisites result   | wc -l    # glibc 动态闭包
9
$ nix store -q --requisites result-1 | wc -l    # musl 动态闭包
2
$ nix store -q --requisites result-2 | wc -l    # 完全静态闭包
1
```

（具体数字随版本浮动，量级关系是稳定的。）

**musl 静态的闭包优势**由此而来：往容器基础镜像、救援 initramfs、路由器固件里塞一个 `pkgsStatic` 的 busybox/工具集，不用拖任何运行时。配合 40.2 的 `aarch64-multiplatform-musl`，还能得到「静态 + ARM」的组合。

**常见坑**，静态链接并非免费午餐：

1. **glibc 静态的 dlopen 警告**：glibc 的 NSS（名字服务）设计为运行时 `dlopen` 加载模块。静态链接 glibc 程序调用 `getaddrinfo`、`getpwnam` 时会打印著名警告：
   ```
   warning: Using 'getaddrinfo' in statically linked applications requires at
   runtime the shared libraries from the glibc version used for linking
   ```
   警告背后是真实的行为退化：解析结果可能与你预期不符。musl 无此设计，静态场景优先 musl。
2. **一切显式 dlopen 的东西**：插件系统（vim/python 的动态模块、openssl 的 engine）在「宿主程序是静态、插件是动态」时会直接翻车——地址空间里没有动态链接器。这类包要么放弃静态，要么整树静态。
3. **gettext/iconv**：glibc 自带的 iconv 静态可用但边界条件多；有些包假设 GNU libiconv，交叉/静态组合下容易出现符号冲突或编码缺失，报错信息往往远离现场，排查时优先怀疑这里。
4. **闭包独立是双刃剑**：静态二进制不再共享系统的 libc——上游爆出 CVE 时，官方渠道修掉 glibc 就能让全机动态程序受保护，而你的静态产物必须**重新构建分发**才吃到修复。救援盘、CI 工具链这类「快进快出」的场景无所谓；长期在线的服务就要掂量了。

最后给一张**选型速查**，把本章入口放进决策清单：

- 日常程序、脚本、开发工具 → 默认 `pkgs`（glibc 动态，缓存命中率最高）；
- 要扔进 scratch 容器、任意基础镜像、或裸机分发的单文件 → `pkgsStatic`（优先 musl 基底，闭包为 1）；
- 极小动态运行时、镜像内多个程序共享一份 libc → `pkgsMusl`；
- 目标机是 ARM/其他架构 → `pkgsCross.<name>`（「指定架构 + musl + 静态」的组合以 pkgsCross 清单为准）；
- 给 Windows 同事一个免安装 exe → `pkgsCross.mingwW64`（留意运行时 DLL）；
- 给目标机构建**整系统**（镜像、installer）→ 原生树路线：声明 `nixpkgs.hostPlatform` + 构建主机 binfmt（40.4 节）；
- 拿不准时从默认 `pkgs` 起步——闭包小 8 个路径不值得为此吃静态链接的坑（第 17 章算过闭包账）。

## 40.6 打包者视角：如何让自己的包可交叉

交叉支持不是构建系统的恩赐，而是打包者遵守纪律的结果。纪律只有两条，都已经在 40.1 节预演过：

**第一条：严格区分两类 inputs。**

```nix
stdenv.mkDerivation {
  pname = "myapp";
  # ...
  nativeBuildInputs = [
    pkg-config   # 构建机上运行 → splicing 自动给本机版本
    cmake
  ];
  buildInputs = [
    openssl      # 链接进产物 → splicing 自动给目标机版本
  ];
  # 归类正确,交叉自动成立;归类错误,本机构建也能「碰巧成功」——这是最阴险的
}
```

阴险之处在于：本机构建时 build == host，两类 inputs 拿到的是同一份东西，错误归类毫无症状；一切换 `pkgsCross` 才爆炸。所以「能不能交叉」是检验打包质量的试金石。

好消息是，分类正确之后，剩下的大部分脏活由 stdenv 自动完成：cmake/meson 会拿到按 hostPlatform 生成的工具链文件，`PKG_CONFIG_PATH` 等环境变量会指向目标机的库目录，交叉编译器、sysroot 的传参都已就位——你在第 34 章看过的那些「魔法变量」，交叉时全部由 stdenv 按平台重算。构建系统层面几乎不用改脚本，前提仍然是那两个字：归类。

**第二条：不要在构建脚本里直接运行刚构建出的目标机二进制。**

```nix
stdenv.mkDerivation {
  # ...
  postInstall = lib.optionalString (stdenv.buildPlatform == stdenv.hostPlatform) ''
    # 只有本机构建才直接执行产物做冒烟测试
    $out/bin/myapp --selftest
  '';
  # 交叉时想测,用模拟器前缀(40.4 节):
  #   ${stdenv.hostPlatform.emulator} $out/bin/myapp --selftest
  # 或者干脆留给 NixOS VM 测试(第 41 章)在目标环境里测
}
```

更精细的写法是 `canExecute` 谓词二分——「构建机能否直接运行目标机程序」由它判定，本机构建必为真，跨架构必为假：

```nix
postInstall =
  if stdenv.buildPlatform.canExecute stdenv.hostPlatform then
    # 能直接执行:本机构建等情形,零开销
    "$out/bin/myapp --selftest"
  else
    # 不能直接执行:跨架构,套模拟器前缀
    "${stdenv.hostPlatform.emulator} $out/bin/myapp --selftest";
```

判断「能不能直接跑」还有个更细的谓词：`stdenv.buildPlatform.canExecute stdenv.hostPlatform`——本机与目标同为 x86_64 时它为真（不需要模拟器），跨架构为假。精细的包可以据此三分支处理。

**第三条（配套声明）：写好 `meta.platforms`。**

```nix
meta = {
  description = "示例应用";
  mainProgram = "myapp";
  platforms = lib.platforms.linux;   # 声明支持范围;Hydra 与 lib.availableOn 据此过滤
};
```

`meta.platforms` 决定了 Hydra 在哪些目标上尝试构建、`lib.availableOn` 在求值期放行谁。声明不实（明明没测过却写全平台）会浪费构建农场的算力，也会误导下游用户——按实际验证过的范围写。

最后给一张失败模式速查表，交叉打包的报错九成落在这四格里：

| 症状 | 根因 | 修复 |
| --- | --- | --- |
| 链接期 `file format incompatible` | 库与工具的两类 inputs 归类颠倒 | 重查 nativeBuildInputs / buildInputs |
| 构建期 `Exec format error` | 构建脚本直接运行了目标机二进制 | `canExecute` 判断或套 `emulator` 前缀 |
| configure 找不到目标机的库 | 依赖没进 buildInputs（或 pkg-config 归类错） | 依赖交给 splicing：归类对即自动正确 |
| 交叉时 `doCheck` 失败 | 测试阶段直接跑目标机产物 | 交叉时跳过测试，或用 emulator 执行 |

## 40.7 加拿大交叉：一句话与展望

**加拿大交叉（canadian cross）**指 build、host、target 三者互不相同的构建——例如在 x86_64 Linux（build）上，编一个运行于 Windows（host）、产出 aarch64 Linux 代码（target）的 GCC。名字来自一段与「同时面向美墨的加拿大」有关的历史玩笑。它是交叉编译的完全体，也是 nixpkgs 中主要服务于「用 A 平台的机器引导 B 平台的工具链」这类自举场景的技术；普通应用开发者一生大概率不需要写它，但知道 `pkgsTargetTarget` 那一份拼接集合是为它准备的，能帮你把平台模型补完。展望：WASM、嵌入式目标与 LLVM 工具链的交叉支持仍在快速演进，Rust/Zig 生态「把交叉当默认能力」的设计也在反向推动传统工具链改进，细节以官方手册与 `lib/systems` 源码为准。

## 40.8 本章小结

- 三个平台各司其职：build 跑编译器、host 跑产物、target 只对「产物是代码生成器」的工具有意义。
- `nativeBuildInputs` 与 `buildInputs` 的严格定义在交叉时显出真意：前者来自构建平台集合（运行于构建机），后者来自宿主平台集合（存在于目标机）；splicing 机制按归类自动分发。
- 交叉入口是 `pkgsCross.<name>`，本质是用 `crossSystem` 重新实例化 nixpkgs；常用目标包括 aarch64-multiplatform、mingwW64、musl64、riscv64 等。
- 交叉 stdenv 需要多阶段自举：交叉 binutils → 最小 GCC → 目标 libc → 完整 GCC；工具链是普通派生，可缓存可复现。
- 用 `file` 验证产物架构；本机跑交叉产物靠 `boot.binfmt.emulatedSystems` 注册 qemu-user。
- `stdenv.hostPlatform.emulator` 是「运行前缀」：本机为空串、交叉为 qemu/wine，让同一份测试代码两栖。
- `pkgsStatic` 得到闭包为 1 的完全静态二进制，`pkgsMusl` 得到极小的 musl 动态世界；glibc 静态要警惕 NSS 的 dlopen 警告与插件翻车。
- 让自己的包可交叉：inputs 归类严格、构建脚本不直接运行目标机产物（用 emulator 包装或留给 VM 测试）、如实声明 `meta.platforms`，可用 `lib.availableOn` 在求值期断言。

## 延伸阅读

- nixpkgs 手册·交叉编译一章：https://nixos.org/manual/nixpkgs/unstable/#chap-cross
- nixpkgs 源码·平台系统定义：https://github.com/NixOS/nixpkgs/blob/master/lib/systems/default.nix
- NixOS 选项检索·binfmt 模拟执行：https://search.nixos.org/options?query=boot.binfmt.emulatedSystems
- nixpkgs 源码·pkgsCross 入口：https://github.com/NixOS/nixpkgs/blob/master/pkgs/top-level/cross-packages.nix
- musl libc 官网（静态链接设计背景）：https://musl.libc.org
