# 第 16 章 构建过程：沙箱、钩子与复现

> **本章导读**：第 13 章把派生（derivation）称作「构建的原子」，本章钻进原子内部：一份 `.drv` 文件交给 Nix 之后，究竟经历了什么才变成 `/nix/store` 里的产出？我们将依次考察守护进程的调度与锁、Linux 沙箱的隔离手段、构建脚本真实可见的环境、固定输出派生这个「例外中的例外」，最后展开两个由此衍生的大问题——逐位复现（bitwise reproducibility）与供应链安全。

## 16.1 从 .drv 到产出：守护进程、替代与锁

在第 13 章我们看到，求值（evaluation）的终点是一份存储在 `/nix/store` 里的 `.drv` 文件——它是一份自包含的配方：builder 程序、参数、环境变量，以及对其他 `.drv` 的依赖。把这份配方变成产出（output），是多用户安装（参见第 14 章）中 `nix-daemon` 的工作。客户端（比如你敲的 `nix build`）只是把目标 `.drv` 递给守护进程，真正持有关键权限、能写入 store 的始终是它。

守护进程拿到一个「构建目标」后，决策顺序大致是：

1. **本地查存在**：目标输出路径是否已经在 `/nix/store`？在则直接结束——这就是 Nix 幂等性的第一道门。
2. **询问替代者（substituter）**：也就是二进制缓存（binary cache），如 `cache.nixos.org`。若缓存里有该路径且签名可信，就下载替代本地构建（参见第 20 章）。
3. **排队本地构建**：缓存未命中才真正动手。构建任务受 `max-jobs` 限制，超出的任务进入队列等待。
4. **执行构建**：进入沙箱（16.2 节），运行 builder，等待退出码。
5. **登记产出**：扫描输出中的 store 路径引用，写入 Nix 数据库，产出对世界可见（引用扫描正是闭包的来源，参见第 17 章）。

用一条命令同时观察「替代」与「构建」两种结局：

```console
$ nix build nixpkgs#cowsay
# 缓存命中时：显示 this path will be fetched，然后从 cache.nixos.org 复制
# 缓存未命中时：显示 this derivation will be built，转入本地（或远程）构建
```

顺带一句新旧对照：老教程里的 `nix-build`（旧 CLI）做的是同一件事——查缓存、必要时构建、生成 `result` 符号链接；本章统一使用能力更完整的新 CLI（`nix build`），两者在本书版本基准下都可用。

与 `make` 对照一下：`make` 对「目标是否已经是新的」的判断基于文件时间戳，且两个并发的 `make` 互不知情，可能同时写同一个目标文件。Nix 的做法是给**输出路径加锁**：如果两个终端同时请求构建同一个 derivation，守护进程保证只有一个真正执行，另一个阻塞等待，醒来后直接复用刚产生的结果：

```console
# 终端 1：开始一个耗时构建
$ nix build .#slow-pkg
# 终端 2：请求同一个 derivation，会等待锁与空闲构建槽位，而不是重复构建
$ nix build -v .#slow-pkg
```

这个「同一 derivation 全局只构建一次」的语义，是多用户共享一台构建机的基石——想一想 Debian 的 `sbuild` 需要管理员精心配置锁与工作目录，而 Nix 把它做成了默认行为。

构建并发的两个旋钮：

```nix
# NixOS configuration.nix 片段：本地构建的并发控制
{
  nix.settings = {
    # 同时进行的构建任务数；0 表示禁止本地构建（全部依赖缓存或远程机器）
    max-jobs = 4;
    # 传给每个构建的 NIX_BUILD_CORES；0 表示「把所有核心分给当前任务」
    # 它会成为构建内的环境变量，供 make -j 之类的工具读取
    cores = 0;
  };
}
```

顺带一提：把构建任务分发给远程机器（`builders = ssh://...`）是这套调度机制的自然延伸，本章不展开，以官方手册的分布式构建章节为准。

## 16.2 沙箱机制：Linux 的实现

「构建」听起来人畜无害，本质却是**在你的机器上以 root 委托的身份执行任意脚本**。若不设防，一个恶意或笨拙的构建脚本可以读走你的 `~/.ssh`、往 `~/.bashrc` 里塞东西、或者偷偷从网上拉代码——`curl | bash` 式的 Makefile 在传统世界毫不稀奇。Nix 的回答是：**默认把每个构建关进沙箱（sandbox）**。

在 Linux 上，沙箱由内核的命名空间（namespace）组合实现：

- **mount namespace + chroot/pivot_root**：构建进程看到一棵全新的文件系统树。`/nix/store` 被一个临时挂载覆盖，**只有本 derivation 声明的输入路径**会被挂进去——构建脚本看不到 store 里的其他任何东西。
- **network namespace**：一个空的网络栈，连 DNS 都没有。构建期间**禁网**（下文详述原因）。
- **PID / IPC / UTS namespace**：进程视角被隔离，看不到宿主进程，也不能用信号与共享内存骚扰它们。
- **最小化的 `/proc`、`/dev`、`/sys`**：`/proc` 是新挂的、只含沙箱内进程；`/dev` 只保留 `null`、`zero`、`urandom` 等极少数设备节点；`/sys` 大多被遮蔽或只读。
- **构建目录**：沙箱内固定为 `/build`（`PWD` 与 `TMPDIR` 都指向它）；沙箱外的落点是 `/tmp/nix-build-<名字>-<序号>.drv-0` 这类路径，在 16.8 节调试时你会再见到它。

**身份与环境**：构建脚本不以你的用户身份运行。守护进程从 `nixbld` 组里挑一个当前空闲的构建用户（build user，如 `nixbld3`；NixOS 默认创建 32 个）来执行；`HOME` 被设为字面量 `/homeless-shelter`——一个不存在的路径，名字本身就是提醒：构建无家可归，不许依赖任何用户文件。`USER` 则设为 `nixbld`。

为什么要专门的一组构建用户？因为隔离不能只靠「看不见」：构建进程毕竟要以某个 uid 运行，如果它就是你自己的用户，理论上就能写你的家目录。用一组专用用户运行构建，加上文件系统层面「构建目录与输出路径之外无可写之处」，两道闸一起落下，恶意脚本才真正无落脚点。用一组（而非一个）用户还有个微妙的好处：并发的多个构建分到不同 uid，即使某个构建试图通过共享的可写位置（比如沙箱外的临时目录）给后来的构建「留条子」，权限也对不上号。

空口无凭，我们写一个探测 derivation，让构建自己把沙箱内部报告出来：

```nix
# sandbox-probe.nix —— 用一次 stdenv 构建打印沙箱内部情况
{ pkgs ? import <nixpkgs> { } }:
pkgs.runCommand "sandbox-probe" { } ''
  echo "== 我是谁 =="
  id                      # uid/gid：应为 nixbld 组里的某个构建用户
  echo "== 家与用户 =="
  echo "HOME=$HOME"       # 预期 /homeless-shelter
  echo "USER=$USER"
  echo "== 我能看到的 store =="
  ls /nix/store | wc -l   # 只有本构建声明的输入，而不是整个仓库
  echo "== 我能上网吗 =="
  # 沙箱内没有路由与 DNS；用 bash 内建的 /dev/tcp 做最朴素的探测
  if timeout 3 bash -c "echo > /dev/tcp/1.1.1.1/443" 2>/dev/null; then
    echo "网络可达（这不该发生！）"
  else
    echo "网络不可达（符合预期）"
  fi
  touch $out              # runCommand 要求最终产出 $out 这个文件
''
```

```console
$ nix-build sandbox-probe.nix && cat result
```

输出里你会看到 `nixbld`、`/homeless-shelter`，以及一个极小的 store 视图——这就是「最小权限」的具体形状。

**为什么禁网？**两个理由，一个温和一个严酷。温和的理由是**确定性**：若构建能联网，它今天和明天拉到的代码可能不同，产出就不可预测，整个 store 模型的根基（参见第 14、15 章）随之动摇。严酷的理由是**安全**：禁网切断了构建脚本窃取数据（把环境变量发往外部）与引入未声明代码（现场下载后门）两条最顺手的路。对比 Debian：要接近这种隔离，打包者得用 `pbuilder`/`sbuild` 配置 chroot，且那是打包基础设施的一部分而非每个构建的默认；Nix 把它做成了「不做任何事时的默认」。

沙箱开关与状态可以这样确认：

```console
$ nix show-config | grep -i sandbox
# sandbox = true 表示默认对所有构建启用（NixOS 上即默认）
# sandbox = relaxed 的含义见 16.4 节
```

**macOS 的差异**：Linux 的 mount namespace 在 macOS 上不存在对应物。Nix 在 macOS 上长期依赖 `sandbox-exec`（Seatbelt）加载一份生成的描述文件（profile），限制文件写入与网络。差异要点：文件系统隔离是「按规则拒绝写」而非「给你一棵新树」，因此构建**能看见整个 `/nix/store` 与更多宿主文件**，隔离强度弱一档；另外 Apple 已将 `sandbox-exec` 标记为废弃，macOS 沙箱的长期走向以官方手册与 Nix 仓库的 issue 跟踪为准。

沙箱策略本身也是可配置的。`sandbox` 有三个取值：`true`（默认，全部沙箱化）、`false`（完全不沙箱，仅调试时使用）、`relaxed`（固定输出派生不沙箱，其余照常，见 16.4 节）。个别构建确需访问沙箱外的设备或文件时，不必整体关掉沙箱，用白名单追加：

```nix
# NixOS configuration.nix 片段：按需给沙箱「开小灶」
{
  nix.settings = {
    # 例：把 KVM 设备放进沙箱，虚拟机类测试（如 nixosTests）能借此大幅加速
    extra-sandbox-paths = [ "/dev/kvm" ];
  };
}
```

原则是「能不开就不开」：每多开一条通道，就多一分与 16.6 节复现性目标相悖的不确定。

## 16.3 允许的不纯通道

「纯构建」说起来干净，但构建脚本毕竟活在操作系统里，有几个不纯的通道是 Nix **有意保留**的，理解它们才能理解构建的确定性与不确定性各来自哪里。

**环境变量白名单**。沙箱里的环境不是你 shell 的环境。求值阶段，derivation 的属性表决定了绝大部分环境变量（`name`、`out`、`buildInputs`……都成了环境变量）；除此之外，Nix 只额外注入少数几个变量：`HOME`、`USER`、`NIX_BUILD_CORES`（可用核心数）、`NIX_BUILD_TOP`（构建临时目录）、`NIX_STORE`、`TMPDIR` 等，完整清单以官方手册的构建环境章节为准。你在终端里 `export FOO=bar` 再构建，`FOO` 进不去；`http_proxy`、`PATH`、`LANG` 同样进不去。这是刻意设计：**不同的机器、不同的用户、不同的 shell 配置，构建环境却完全一致**——传统打包里「我这能编过你那编不过」的经典场景在源头就被消灭了。

可以做个十秒钟的实验，证明「白名单」不是修辞：

```nix
# env-heritage.nix —— 证明父进程环境进不了构建
{ pkgs ? import <nixpkgs> { } }:
pkgs.runCommand "env-heritage" { } ''
  # FOO 是我们即将在 shell 里 export 的变量
  echo "FOO=[$FO]" > $out
''
```

```console
$ FOO=bar nix-build env-heritage.nix && cat result
FOO=[]
```

对照：把同一行 `echo $FOO` 写进 Makefile，`make` 会原样继承你 shell 里的 `FOO`——这就是「环境即陷阱」与「环境即白名单」的差别。

**时钟与随机性**。沙箱冻结了文件系统视图与网络，却**没有冻结时钟**——`date` 可用、文件 mtime 正常流逝；`/dev/urandom` 也开放（编译器、脚本运行时普遍需要它）。这意味着产出中可能嵌入时间戳与随机种子，它们是「同一份配方、不同机器、字节不同」的头号来源，16.6 节专门讨论。

**`__structuredAttrs`：用 JSON 文件代替环境变量**。环境变量传参有两个天生缺陷：值必须是字符串（复杂数据要手工序列化），且受内核参数区大小限制（`ARG_MAX`，输入多的大型 derivation 真的会撞上）。现代的解法是结构化属性：

```nix
# structured-demo 的关键片段：属性直接以 Nix 值传递，构建内读 JSON
pkgs.stdenv.mkDerivation {
  name = "structured-demo";
  # 开关：本 derivation 的属性不再逐个变成环境变量，
  # 而是整体序列化成一个 JSON 文件，路径通过环境变量告诉构建脚本
  __structuredAttrs = true;
  # 直接就是 attrset，不需要 builtins.toJSON 手工打包
  config = { debug = true; opt = 2; };
  nativeBuildInputs = [ pkgs.jq ];   # 为了在构建内解析 JSON
  buildCommand = ''
    # NIX_ATTRS_JSON_FILE 指向 .attrs.json；bash 用户也可以
    # source $NIX_ATTRS_SH_FILE 拿到扁平化后的变量
    debug=$(jq -r '.config.debug' "$NIX_ATTRS_JSON_FILE")
    echo "debug=$debug opt=$(jq -r '.config.opt' "$NIX_ATTRS_JSON_FILE")" > $out
  '';
}
```

这样一来，列表、嵌套属性、布尔值都能原样传给构建，且不占用环境变量空间。nixpkgs 中越来越多的重载包（输入极多的那种）已经改用这一机制。

## 16.4 fixed-output derivation：例外中的例外

16.2 节说「构建期间禁网」，但有个显而易见的矛盾：源码 tarball 本身就是从网上下载的——下载源码的那一步怎么活下来的？

答案是**固定输出派生（fixed-output derivation，FOD）**：如果一份 derivation 在声明时就**写死了输出的哈希值**，Nix 便允许它在构建时联网。原理参见第 15 章，这里看它的实际形状——一个手工版的 `fetchurl`：

```nix
# fetchurl 的极简原理演示（nixpkgs 里真正的 fetchurl 更完善）
let
  pkgs = import <nixpkgs> { };
in
derivation {
  name = "hello-2.12.1.tar.gz";
  # 固定输出派生是唯一「合法联网」的构建：这里用 curl 下载
  builder = "${pkgs.bash}/bin/bash";
  args = [ "-c" "${pkgs.curl}/bin/curl -fL -o $out https://ftp.gnu.org/gnu/hello/hello-2.12.1.tar.gz" ];
  # 声明哈希算法与期望值：产出必须精确匹配
  outputHashAlgo = "sha256";
  outputHash = "sha256-JXikjqrFbKNB3wqWkdKPdZCn2hTsdkg2ZTu5CTaozXE=";
  # flat：对文件本身算哈希；recursive：对整个目录树（fetchzip/fetchgit 用）
  outputHashMode = "flat";
  system = "x86_64-linux";
}
```

**为什么敢放行？**信任逻辑非常干净：输出哈希已经由你（或 nixpkgs 维护者）事先声明，构建脚本无论怎么做恶，结果要么与声明一致（无害），要么哈希不匹配（构建失败，并报出实际哈希）。作恶无法通过哈希这道闸。`fetchFromGitHub`、`fetchgit`、`fetchzip` 都是同一原理的封装（参见第 15 章）。

两点补充。其一，沙箱策略上，FOD 通常仍套用文件系统隔离但**解除断网**；若配置为 `sandbox = relaxed`，则 FOD 完全脱离沙箱运行。其二，FOD 信任的是「哈希」而非「来源」：URL 指向的服务器若在某天开始返回恶意内容，只要哈希对不上就会构建失败，所以安全；但第一次给某 URL 记录哈希时的「首次即信任」（trust on first use）仍需谨慎——对高价值目标，哈希应当来自上游的官方发布渠道而非现场下载。

为一个新的 URL 取得「正确的哈希」，正规途径不是手算，而是让 Nix 自己下载并计算：

```console
$ nix store prefetch-file --hash-algo sha256 \
    https://ftp.gnu.org/gnu/hello/hello-2.12.1.tar.gz
# 输出 NAR 哈希与期望的 SRI 值，把它填进 outputHash 即可
# （注意 flat 模式与 recursive 模式的哈希口径不同，以该命令输出与手册说明为准）
```

把算出的哈希回填到 `outputHash`，一次「锁定源码」的工作就完成了——这正是 nixpkgs 维护者给新包取哈希的日常动作。

## 16.5 构建脚本内部视角：builder、args 与 stdenv

把镜头切换到构建脚本本身。`.drv` 里与执行直接相关的字段是 `builder` 与 `args`：守护进程 fork 之后，在构建目录里以 `builder + args + 声明的环境变量` 启动进程，仅凭退出码判断成败——**退出 0 且 `$out` 存在即成功**，没有别的魔法。我们用 16.4 节式的方式裸写一个最小构建来验证：

```nix
# minimal.nix —— 完全不借助 stdenv 的「裸」构建
let
  # 为什么要 import 一个 nixpkgs：只是取一个真实存在于 store 的 bash，
  # 它的绝对路径会在求值期被插入到 .drv 里，成为唯一的解释器
  bash = (import <nixpkgs> { }).bashInteractive;
in
derivation {
  # 名字：决定输出 store 路径的 basename（哈希前缀另算，见第 14 章）
  name = "hello-minimal";
  # builder：必须是绝对路径的可执行文件；注意它是字符串插值的结果，
  # 求值完成后就是一个写死的 store 路径——这就是「配方自包含」的含义
  builder = "${bash}/bin/bash";
  # args：交给 builder 的参数。-c 保证脚本一出错立即退出，
  # 因为我们只靠退出码向 Nix 汇报成败
  args = [ "-c" "echo hello > $out" ];
  # system：平台三元组；与当前系统不符时不会本地构建（会寻找远程机器）
  system = "x86_64-linux";
}
```

```console
$ nix-build minimal.nix
/nix/store/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx-hello-minimal
$ cat ./result
hello
```

`$out` 从哪来？它是 Nix 注入的环境变量，值为「预期的输出路径」；构建脚本的合同只有一条：**在退出前把产出放到 `$out`**。再看看这份 `.drv` 的真容：

```console
$ nix derivation show /nix/store/*-hello-minimal.drv
```

```json
{
  "/nix/store/…-hello-minimal.drv": {
    "args": [ "-c", "echo hello > $out" ],
    "builder": "/nix/store/…-bash-5.3.x/bin/bash",
    "env": {
      "builder": "/nix/store/…-bash-5.3.x/bin/bash",
      "name": "hello-minimal",
      "out": "/nix/store/…-hello-minimal",
      "system": "x86_64-linux"
    },
    "inputDrvs": {
      "/nix/store/…-bash-5.3.x.drv": [ "out" ]
    },
    "inputSrcs": [ ],
    "outputs": {
      "out": { "path": "/nix/store/…-hello-minimal" }
    },
    "system": "x86_64-linux"
  }
}
```

（路径以 `…` 截节，实际是完整哈希。）注意 `env` 里没有任何神秘内容：derivation 的属性就是环境变量，加上 Nix 注入的 `out`。各字段速查：

- `args` 与 `builder`：守护进程启动构建时的完整命令行；
- `env`：构建进程的整个环境变量表（属性即变量）；
- `inputDrvs`：依赖的其他 `.drv`，以及各自要用的输出名（多输出包见第 13 章）；
- `inputSrcs`：不经构建、直接作为源的 store 路径；
- `outputs`：本配方的产出路径表。

那 nixpkgs 里成千上万的包，`builder` 都是自己写的 bash 脚本吗？不是。绝大多数包共用**同一个 builder**——bash 加上 stdenv 的 `setup` 脚本（参见第 33 章）。链条是这样的：这些 derivation 的 `builder` 仍是 bash，`args` 里多了一个 `default-builder.sh`；该脚本只做两件事——`source $stdenv/setup`（引入整套装舱工具函数与 PATH 构造），然后执行 `genericBuild`。`genericBuild` 的本体是**按 `phases` 数组依次调用各阶段函数**：解包（unpackPhase）、打补丁（patchPhase）、配置（configurePhase）、编译（buildPhase）、测试（checkPhase）、安装（installPhase）、修正（fixupPhase）……每个阶段前后还挂着 `pre*Hooks`/`post*Hooks` 钩子供包覆写。你在 nixpkgs 包定义里写的 `installPhase = ''…''`，最终就是替换掉 phases 里的某个函数。细节留给第 33 章，此处只需记住：**`derivation` 是机器接口，`stdenv` 是给人用的脚手架**。

最后补一块拼图：构建结束后，Nix 如何知道产出依赖谁？答案朴素得惊人——**在产出文件的内容里搜索 store 路径模式**。演示：

```nix
# refs-demo.nix —— 产出中的 store 路径字符串会被扫描成依赖
{ pkgs ? import <nixpkgs> { } }:
let
  # 第一步：产出一个小文本文件
  text = pkgs.runCommand "my-text" { } ''
    echo "由 refs-demo 生成" > $out
  '';
in
# 第二步：把上一步产出的路径以字符串形式写进新产出
pkgs.runCommand "refs-demo" { } ''
  echo "请阅读 ${text} 的内容" > $out
''
```

```console
$ nix-build refs-demo.nix && cat result
请阅读 /nix/store/…-my-text 的内容
$ nix path-info --references ./result
/nix/store/…-my-text
```

`${text}` 在求值期被展开成真实路径，构建后的扫描器据此登记依赖边——闭包（参见第 17 章）的边就是这样一条条连起来的。而沙箱恰好保证了这件事的可信：构建脚本在沙箱里**看不见**任何未声明的 store 路径，所以扫到的引用必然来自声明的输入；「可见性」与「登记」互相印证，谁也漏不了谁的账。

## 16.6 确定性：输入寻址不等于逐位复现

初学者最容易在这里产生误解：既然 store 路径是哈希算出来的，Nix 不是天然可复现（reproducible）吗？**不。**第 15 章讲过，常规 derivation 的路径来自**全部输入**的哈希（输入寻址，input-addressed）——配方相同则路径相同；但**产出的字节**是什么，哈希管不着。同一份 `.drv` 在两台机器上构建，路径完全一致，字节却可能不同：

- **时间戳**：16.3 节说过，沙箱里的时钟照常走。`gzip` 默认在头部嵌入 mtime，`tar` 嵌入 mtime 与 uid，许多构建系统把构建日期编进版本串。
- **随机种子**：`/dev/urandom` 开放，某些生成器、编译器的随机化（如符号顺序）每次不同。
- **并行度**：`make -j8` 与 `make -j16` 的任务交错不同，个别构建系统会把交错顺序固化进产物（如归档内文件顺序）。

这引出一个结构性的事实：**「路径相同、字节不同」在输入寻址模型里是合法状态**。两台机器各自构建同一份 `.drv`，得到同一个 store 路径、内容却互有出入——模型对此不报警，因为路径本来就只承诺「输入相同」，不承诺「输出相同」。哪个机器上的字节「算数」，取决于谁先占了坑（本机构建）或你从哪个缓存下载。要消除这种松弛，要么靠 16.6 节后半的复现性治理，要么走向第 15 章末尾介绍的内容寻址（content addressing）——让路径直接由内容决定，字节不同则路径必不同。

既然如此，「可复现」要靠什么？答案是**约定与治理**，Nix 只是让验证变得极其便宜：

```nix
# 若你的构建确实会嵌入时间戳，用一个固定纪元代替真实时钟
stdenv.mkDerivation {
  # ……
  postPatch = ''
    # SOURCE_DATE_EPOCH 是 reproducible-builds.org 定义的跨项目约定：
    # 一切「需要时间」的工具（gcc、tar、zip…）都应改读这个变量
    # 315532800 = 1980-01-01 UTC，ZIP 格式允许的最早时间，常被用作默认
    export SOURCE_DATE_EPOCH=315532800
  '';
}
```

nixpkgs 的 stdenv 已经统一导出 `SOURCE_DATE_EPOCH`，多数包无需自己动手；`tar --mtime=@0 --sort=name`、`gzip -n` 这类「去随机化」开关也广泛用于打包脚本。验证逐位复现性的命令是 `--check`——忽略已有产出、强制重建一份，再逐字节比对：

```console
$ nix build nixpkgs#hello --check
# 一致：安静通过；不一致：报错指出 derivation 不可复现，
# 配合 --keep-failed 可保留两份产出，交给 diffoscope 对比
```

`--check` 失败后的排查路径通常是这样：

```console
$ nix build nixpkgs#somelib --check --keep-failed
# 失败信息会给出两次构建各自的目录位置（以实际输出为准）
$ diffoscope /tmp/nix-build-somelib-0.drv-0 /tmp/nix-build-somelib-1.drv-0
```

`diffoscope`（reproducible-builds.org 的明星工具）会递归解包两侧产物，精确指出第一个字节差异出现在哪个归档成员、哪个字段——十有八九，你会看到某个时间戳赫然在列。

两个值得认识的名字：**reproducible-builds.org** 是跨发行版的可复现构建总纲（源自 Debian 的 Reproducible Builds 项目，规范了 `SOURCE_DATE_EPOCH`，提供了 `diffoscope`、`reprotest` 等工具）；**r13y**（r13y.com，由 Determinate Systems 维护）则持续跟踪「nixpkgs 全量重建中有多少比例逐位一致」，是观察 nixpkgs 复现性债务的仪表盘。Nix 在这场运动中的位置很特殊：store 模型让「同路径不同字节」可以直接对质（路径一样、内容却分叉，一眼可见），**发现问题便宜**；但修复仍要靠上游与打包者逐包治理。

最后是最扎心的一点：**「缓存优先」掩盖了不可复现问题**。只要二进制缓存（参见第 20 章）可用，就几乎没人真正重构建——大家下载的都是缓存里那一份字节，于是不可复现的包岁月静好。一旦缓存丢失、或某个新平台没有缓存、或有人较真用 `--check` 重建，复现性债务才集中爆发。可以说，Nix 生态的日常体验是「复现性由缓存代持」的，而 r13y 这样的项目负责提醒大家账本上的真实数字。

## 16.7 构建之后的钩子：post-build-hook

16.5 节的 `phases` 钩子是**构建内部**的扩展点；Nix 还提供了一个**构建之外**的钩子：`post-build-hook`（注意名称准确如此，不是 build_hook）。每次有 derivation 被本机成功构建后，守护进程会以 root 身份运行你配置的程序，并通过环境变量传递 `OUT_PATHS`（本次新建的 store 路径，空格分隔）与 `DRV_PATH`。它最常见的用途是**把本机构建出来的东西顺手推上自己的缓存**，让团队其他人（以及 CI）直接命中：

```bash
#!/usr/bin/env bash
# /etc/nix/post-build-hook.sh —— 构建成功后自动推送本机产出
set -euo pipefail
# OUT_PATHS 为空说明没有新产出（例如全部来自缓存），直接返回，
# 避免每次都跑一遍无谓的 nix copy
if [ -z "${OUT_PATHS:-}" ]; then
  exit 0
fi
# 推送到本机自建的文件型缓存；签名与密钥配置参见第 20 章
exec nix copy --to file:///var/nix-cache $OUT_PATHS
```

```bash
# /etc/nix/nix.conf：注册钩子（也可用 NixOS 模块，见下）
post-build-hook = /etc/nix/post-build-hook.sh
```

```nix
# NixOS 上等价的声明式配置
{
  nix.settings = {
    # 每次本机构建成功后以守护进程身份执行该脚本
    post-build-hook = "/etc/nix/post-build-hook.sh";
  };
}
```

```console
# 脚本必须有可执行权限，否则钩子会静默失败
# chmod +x /etc/nix/post-build-hook.sh
```

两点工程提醒：钩子失败会让对应的构建被标记为失败（推缓存失败等于构建失败，这个语义是刻意的——避免缓存悄悄缺货）；钩子每次构建触发一次而非每个路径一次，脚本内部要自己考虑批量处理。

顺带一提，如果你的构建流量大到「逐次触发钩子」太频繁，生态里还有常驻进程式的方案（如 `cachix watch-store` 这类「盯着 store 推送」的工具），思路从「每次构建后推」变成「有新东西就推」，适合大型 CI 场景，具体以各工具文档为准。

## 16.8 观测与调试工具箱

构建出问题时，Nix 提供的观测手段远比 `make` 的「盯屏幕」体面。

**看日志**。常规 `nix build` 只在失败时吐出尾部日志；`-L`（`--print-build-logs`）让所有构建实时输出日志，调试自己写的 derivation 时应当是肌肉记忆。事后查询用 `nix log`，它连缓存构建的日志都能取到（缓存可以存日志，这也是 Nix 生态的便利之一）：

```console
$ nix build -L .#my-pkg          # 实时打印全部构建日志
$ nix log nixpkgs#hello          # 查询某个包的构建日志（哪怕不是本机构建的）
$ nix log /nix/store/*-my-pkg.drv # 也可直接对 .drv 查询
```

**保留现场**。`--keep-failed`（`-K`）在失败时不清理构建目录，并把路径打印出来，你可以进到沙箱外的落点直接翻检：

```console
$ nix build --keep-failed .#broken
# 失败提示中会给出：note: keeping build directory '/tmp/nix-build-broken-0.drv-0'
$ ls /tmp/nix-build-broken-0.drv-0   # 进入「案发现场」调查
```

**回退到本地构建**。`--fallback` 的语义：当替代下载（缓存）失败时不要放弃，回退为本地从源码构建。缓存偶发故障、或缓存里的东西不可信时很有用：

```console
$ nix build --fallback .#my-pkg
```

**先看后动**。`--dry-run` 不构建、不下载，只列出「将构建哪些、将取回哪些」，评估一次操作的影响面时非常顺手：

```console
$ nix build --dry-run .#my-pkg
# 会分别列出 these derivations will be built 与 these paths will be fetched，
# 据此判断这次变更牵动多大（闭包概念参见第 17 章）
```

想看得更深一层，`-v` 会把守护进程的决策过程也打印出来——查询了哪些 substituter、在等待哪个锁——排查「为什么它在下载而不是构建」这类问题时，最先用的就是它。

**进入构建环境重试**。比看日志更进一步的是「人肉进沙箱」：`nix develop` 可以直接以某份 derivation 的构建环境（依赖、PATH、环境变量）开一个交互 shell。对 stdenv 系 derivation，进去后还能手动调用各阶段函数，逐条复现失败点——这在改 nixpkgs 包时是日常操作：

```console
$ nix develop /nix/store/xxxxxx-broken-1.0.drv
# 进入后：环境与该构建完全一致，可以手动执行
#   unpackPhase、patchPhase、configurePhase、buildPhase……逐段定位
# 注意：nix develop 本身不带沙箱（它是给人用的，不是给构建用的）
```

一个诚实的提醒：`nix develop` 的环境**模拟**了构建环境，但少了沙箱的文件系统隔离与断网，个别问题（恰好依赖沙箱行为）无法在其中复现，此时回到 `--keep-failed` 的现场更可靠。

## 16.9 安全模型总结：三层信任链

把本章与第 14、15、20 章的线索收拢，Nix 的构建安全模型可以概括为**三层信任链**，每层挡住不同的攻击面：

1. **缓存签名层**：从替代者（二进制缓存）来的一切必须带有你信任的公钥对应的签名，验签失败拒收（`trusted-public-keys`、`substituters` 的配置，参见第 20 章）。这挡住了**传输与缓存端的篡改**——缓存服务器被攻破也无法向你投毒。
2. **store 完整性层**：进入 store 的路径与内容由 Nix 数据库登记，可随时校验：
   ```console
   # 校验整个 store 的登记一致性与内容哈希（FOD 与内容寻址路径尤其严格）
   # nix store verify --all
   ```
   这层保证**本地存量**没有被悄悄改动。
3. **构建隔离层**：即使签名的配置引导你构建一份恶意 derivation（比如你引入了坏人的 overlay），沙箱也限制了它能造成的直接伤害——禁网断外传，最小文件系统断读取，专用构建用户断越权。本章 16.2 节的全部内容都属于这一层。

在三层之外还有个「入口」问题：**谁有资格把构建任务递给守护进程**。多用户安装下，普通用户默认只能请求构建与查询；被列入 `trusted-users` 的用户才被允许改写全局配置类选项（如临时指定 substituter）。最小化信任名单，是这三层之外的第一道朴素防线（选项语义参见官方手册与第 20 章）。

第一层的配置长这样（详细机制参见第 20 章）：

```nix
# NixOS：声明信任哪些缓存、验哪些公钥
nix.settings = {
  substituters = [
    "https://cache.nixos.org"      # 官方缓存
    "https://my-cache.example.org" # 自建缓存（配合 16.7 节的钩子）
  ];
  trusted-public-keys = [
    "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    "my-cache.example.org-1:…"     # 自建缓存的公钥
  ];
}
```

当代供应链安全的语境下（想想 2024 年的 xz 后门、更早的 SolarWinds 事件），这套模型的价值与**边界**都值得诚实标注。价值：Nix 把「你审计过的那次构建」与「你部署的那份字节」之间的对应关系变得可验证——签名负责传递不失真，复现性负责任何人可以重走构建并得到相同字节。边界：**Nix 判断不了源码本身的善恶**。上游维护者在源码里埋逻辑（xz 式攻击），沙箱、签名、哈希全部无感放行——那一步的防线只能是代码审计与信任的分发（谁的 flake 输入、谁的 overlay、谁的缓存公钥）。换言之，Nix 把「信任」从模糊的「信这个包」收敛为清晰的「信这些人与这些字节」，这让信任变得可管理，但没有让信任消失。

## 16.10 本章小结

- 构建由 `nix-daemon` 调度：先查本地 store，再问二进制缓存（替代下载），最后才本地构建；输出路径加锁保证同一 derivation 并发只构建一次。
- 沙箱：Linux 用命名空间组合（最小 `/nix/store` 视图、禁网、最小 `/proc` `/dev`、`HOME=/homeless-shelter`、`nixbld` 构建用户）；macOS 用 `sandbox-exec` 描述文件，隔离弱一档且该机制已被 Apple 标记废弃；禁网同时服务确定性与安全。
- 不纯通道是白名单式的：只有 `NIX_BUILD_CORES` 等少数环境变量进入构建；时钟与随机性仍开放，是字节级差异的主要来源；`__structuredAttrs` 用 JSON 文件传参，突破环境变量的大小与类型限制。
- 固定输出派生（FOD）是唯一合法联网的构建：输出哈希已事先声明，作恶必然导致哈希不匹配而失败；`fetchurl`/`fetchFromGitHub` 皆基于此（参见第 15 章）。
- `.drv` 的 `builder`+`args` 是机器接口，退出码与 `$out` 是全部合同；stdenv 的 `setup`/`genericBuild`/`phases` 是给人用的脚手架（参见第 33 章）；产出依赖来自对文件内容的 store 路径扫描，闭包的边由此而来（参见第 17 章）。
- 输入寻址只保证「同配方同路径」，不保证同字节；复现性靠 `SOURCE_DATE_EPOCH` 等约定治理，`nix build --check` 可验证，`diffoscope` 可定位差异，「缓存优先」让不可复现问题长期被掩盖。
- 观测与调试：`-L` 看日志、`nix log` 查历史日志、`--keep-failed` 保留现场、`--fallback` 回退本地构建、`--dry-run` 先看后动、`nix develop` 进入构建环境；`post-build-hook` 可在构建成功后自动推送缓存。
- 安全模型是三层信任链：缓存签名挡传输篡改，store 完整性挡本地篡改，沙箱限制恶意构建的伤害，入口处还有 `trusted-users` 把关；但源码本身的善恶不在 Nix 的能力边界内。

## 延伸阅读

- Nix 官方手册：构建环境与高级属性（`__structuredAttrs`、输出哈希）：<https://nixos.org/manual/nix/stable/language/advanced-attributes>
- Nix 官方手册：`nix.conf` 配置项（`sandbox`、`post-build-hook`、`max-jobs` 等）：<https://nixos.org/manual/nix/stable/command-ref/conf-file>
- Nix 官方手册：`nix build`（`-L`、`--check`、`--fallback`、`--keep-failed`）：<https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-build>
- Nix 官方手册：术语表（store derivation、沙箱等条目）：<https://nixos.org/manual/nix/stable/glossary>
- nixos.org Wiki：Nix 沙箱 <https://wiki.nixos.org/wiki/Nix_sandbox>
- 可复现构建总纲（`SOURCE_DATE_EPOCH`、diffoscope 等规范的出处）：<https://reproducible-builds.org>
- r13y：nixpkgs 复现性看板 <https://r13y.com>
- nix.dev 教程站（打包与调试实践）：<https://nix.dev>
