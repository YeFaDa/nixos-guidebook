# 第 13 章 派生（Derivation）：构建的原子

> **本章导读**：第 4 章说「构建被建模为纯函数」，本章揭示这个函数的实体形态：**派生（derivation）**。你会看到：一个包定义如何求值成一份 `.drv` 文件；`.drv` 里的每个字段意味着什么；如何不用任何构建系统、徒手写一个最小可构建的派生；以及「多输出」与「三种哈希模型」这两个决定 nixpkgs 形态的设计。本章的每个概念都会在第 33-38 章的打包实战中反复出现。

## 13.1 求值的终点：一份「施工单」

第 6 章强调过语言与执行器的分离：Nix 语言负责求值（evaluation），Nix 包管理器负责构建（build）。连接两个世界的枢纽就是一个内建函数 `derivation`——**当求值器碰到它，就把参数记录成一份施工单，交给 Nix 守护进程**。

一个完整的最小例子（逐行注释）：

```nix
# hello-min.nix —— 不依赖任何 nixpkgs 设施的「裸」派生
derivation {
  # ① 名字：进入输出路径的一部分（/nix/store/<哈希>-hello-min）
  name = "hello-min";

  # ② 构建器：构建过程要执行的程序。
  #    这里直接用 bash（通过路径引用，本身也是 store 路径）
  builder = "${bash}/bin/bash";

  # ③ 传给构建器的参数：以 "-c" + 脚本 的方式执行
  args = [
    "-c"
    ''
      echo "Hello, Nix!" > $out     # ④ $out：本次构建的输出路径（环境变量注入）
      echo "built at $(date)" >> $out
    ''
  ];

  # ⑤ bash 从哪来？这里省略——完整可运行版见 13.4 节
}
```

求值这个表达式时，Nix 做三件事：

1. 计算全部输入的哈希（builder 的路径、args、环境、name……）；
2. 在 store 里生成 `/nix/store/<哈希>-hello-min.drv`——一份 ATerm 格式的施工单；
3. 返回一个「以输出路径为主角的属性集」（13.3 节展开）。

**构建**发生在之后：`nix build` / `nix-build` 读取 `.drv`，起沙箱（第 16 章）、执行 builder，验收产物落在 `$out` 指向的路径。

## 13.2 `builtins.derivation` 参数逐行精讲

`derivation` 是 `builtins.derivation` 的裸名别名。核心参数（现代工程里 99% 由 `mkDerivation` 代劳，但你必须知道底层）：

```nix
derivation {
  name = "example-1.0";        # 输出路径名；约定「名字-版本」
  system = "x86_64-linux";     # 目标三元组：决定能否在本机构建
                              # （交叉/远程构建的判断依据，第 40 章）
  builder = ./build.sh;       # 构建器：任意可执行文件（脚本要可执行+shebang）
  args = [ "参数1" "参数2" ];   # 传给 builder 的命令行参数

  # 其余所有属性 → 全部变成构建器的「环境变量」。
  # 这是关键设计：输入清单与构建环境是同一份东西。
  src = ./.;                  # 环境变量 $src = 复制进 store 后的路径
  CFLAGS = "-O2";             # 环境变量 $CFLAGS
}
```

三条精确规则：

1. **路径与派生值在传入时被「实体化」**：`src = ./.` 会让 Nix 把整个目录复制进 store，环境变量 `$src` 的值是复制后的路径；属性值若包含其他派生的输出，其 store 路径成为本派生的依赖。
2. **其他一切类型按字符串化**：整数、布尔会变成字符串。⛔ 大属性集会展开成巨型环境变量——这正是 `__structuredAttrs`（第 16、34 章）诞生的原因：改传一个 JSON 文件。
3. **`system` 与 `builder` 不匹配时**：构建会失败（“a x86_64-linux is required to build …, but I am a x86_64-darwin”），这是远程构建/交叉编译触发的信号。

## 13.3 `.drv` 文件：施工单的解剖

每个派生在 store 里是一个 `.drv` 文件。现代观察方式（✅ 推荐 JSON 视图，⚠️ 旧的 `nix show-derivation`、`nix-instantiate --xml` 已过时）：

```console
$ nix derivation show nixpkgs#hello
```

输出（节选，中文注释为后加）：

```json
{
  "/nix/store/4wk...-hello-2.12.3.drv": {
    "args": ["-e", "/nix/store/...-default-builder.sh"],
    // ↑ stdenv 的默认 builder（第 33 章）：用 bash -e 执行 setup.sh
    "builder": "/nix/store/...-bash-5.2/bin/bash",
    "env": {
      "name": "hello-2.12.3",
      "out": "/nix/store/p7d...-hello-2.12.3",
      "src": "/nix/store/1xa...-hello-2.12.3.tar.gz",
      "system": "x86_64-linux"
      // ↑ env 就是 13.2 节的「其余属性」：构建时全部注入为环境变量
    },
    "inputDrvs": {
      "/nix/store/...-bash-5.2.drv": { "outputs": ["out"] },
      // ↑ 依赖的其他 .drv：bash 的 out 输出
      "/nix/store/...-glibc-2.40.drv": { "outputs": ["out"] }
    },
    "inputSrcs": [ "/nix/store/...-default-builder.sh" ],
    // ↑ 直接引用的「源」型 store 路径（不经构建产生）
    "outputs": { "out": { "path": "/nix/store/p7d...-hello-2.12.3" } },
    // ↑ 输出清单：本例单输出 out（多输出见 13.5）
    "system": "x86_64-linux"
  }
}
```

`.drv` 的磁盘格式是 ATerm（一种紧凑的前缀记法），日常无需直读，但要知道：**`.drv` 路径的哈希 = 对这份施工单内容的哈希**。也就是说，改任何一个字符的输入（版本号、一个环境变量、一个依赖的 .drv 哈希），`.drv` 路径就变，输出路径也跟着变——「雪崩式」的输入哈希传导正是 Nix 一切复用与缓存（第 20 章）的根基。

对求值器而言，`derivation { ... }` 调用的**返回值**是一个形如这样的属性集：

```nix
{
  outPath = "/nix/store/p7d...-hello-2.12.3";  # out 输出的路径
  drvPath = "/nix/store/4wk...-hello-2.12.3.drv";
  type = "derivation";
  # 以及每个输出的属性（多输出时）与全部 env 字段的浅拷贝
}
```

所以 Nix 代码里 `"${hello}"` 插值得到的就是 `outPath`——「把一个包变成字符串 = 它的输出路径」，这是第 9 章字符串上下文的来源。

## 13.4 徒手构建一次：完整可复现实验

不看任何构建系统，从零走一遍「求值 → 施工单 → 构建」。新建目录，写入两个文件：

```nix
# ~/nix-lab/bare/default.nix —— 求值入口
let
  # nixpkgs 只用来「借」一个 bash 与一个 coreutils（它们本身是派生）
  pkgs = import (fetchTarball "channel:nixos-26.05") { };
in
derivation {
  name = "bare-hello";
  system = "x86_64-linux";
  builder = "${pkgs.bash}/bin/bash";   # builder 必须是绝对路径的 store 程序
  args = [
    "-c"
    ''
      # === 以下是「构建脚本」，逐行注释 ===
      set -eu                            # 出错即停：构建脚本的标准开头
      echo "bare hello"                  # 构建期输出会进构建日志（nix log）
      echo "Hello from a bare derivation!" > $out
      # $out 由 Nix 注入：构建成功的标志就是该路径存在且非空
    ''
  ];
}
```

```console
# 求值 + 构建（一步完成）
$ cd ~/nix-lab/bare
$ nix-build
/nix/store/6f2...-bare-hello

# 看看产物
$ cat /nix/store/6f2...-bare-hello
Hello from a bare derivation!

# 看施工单
$ nix derivation show /nix/store/6f2...-bare-hello.drv | head
```

再做一个实验，体会「输入变 → 路径变」：

```console
# 把 name 改成 bare-hello2，再构建
$ nix-build
/nix/store/9ab...-bare-hello2        # ← 哈希变了：名字也是输入
```

你刚刚徒手完成了：写包定义（求值层）→ 生成 .drv → 沙箱构建 → 产出 store 对象。第 16 章会把镜头拉近到沙箱内部；第 33 章将展示 stdenv 如何把「裸 bash 脚本」升级成「分阶段的构建框架」。

## 13.5 多输出：一次构建，多个产物

大型软件的构建产物天然分几类：程序、头文件与静态库（开发用）、文档、调试符号。Nix 允许一个派生声明多个输出（multiple outputs）：

```nix
derivation {
  name = "libfoo-1.0";
  outputs = [ "out" "dev" "man" ];
  # 构建器必须把产物分别写进 $out、$dev、$man 三个路径
  ...
}
```

三个工程收益：

1. **闭包瘦身**：链接期只需要 `dev`（头文件 + .so 符号链接），运行期只需要 `out`——依赖 libfoo 的程序闭包里不必出现文档与头文件（第 17 章的「运行闭包」由此成立）；
2. **安装粒度**：`hello.man` 可以单独安装；
3. **依赖去环**：两个包互需对方不同输出时（编译器与库的经典死结），拆输出可破环。

`out` 是特殊输出：属性集插值（`"${pkg}"`）默认取它。nixpkgs 惯例：`out`=程序与运行时、`dev`=开发文件、`doc`、`man`、`lib`（大库的运行时拆分）、`bin`（仅命令）、`info`。详见第 34 章的 outputs 参数。

## 13.6 三种哈希模型：派生如何被「锚定」

这是理解第 15 章的前置框架。一个派生的输出路径如何确定？Nix 有三种模型（前两种是现行主力）：

**1. 输入寻址（input-addressing，默认）**。输出路径 = f(全部输入的哈希)。构建前就能算出路径；同输入构建两次必然同路径。缺点：**不保证两次构建字节相同**（第 16 章的可复现性讨论）。

**2. 固定输出（fixed-output）**。预先声明输出哈希（`outputHash`），输出路径 = f(名字, 输出哈希)。构建器**被允许联网**（fetchers 全靠它，第 15 章）；构建后校验哈希，不符即失败。它把「网络这个不纯源」关进了哈希的笼子。

**3. 内容寻址（content-addressing，实验特性）**。输出路径 = f(名字, 实际输出的哈希)。不同机器构建同一输入若字节一致，产物天然去重共享；这是「全生态可复现」的技术路线图（第 20 章 outlook）。

## 13.7 引用关系：产物如何记住自己依赖谁

构建完成后，Nix 会**扫描输出内容里的 store 路径字符串**，自动登记「本产物引用了哪些路径」（references，记入 store 数据库，第 14 章）。引用关系不必手工声明——它来自字符串的真实出现（二进制里的 RPATH、脚本里的 shebang、文本里的路径）。这个设计的高明之处：

- 依赖图是**事后验证的事实**，不是「希望如此的声明」；
- 漏依赖（构建期悄悄用了某个路径）会被发现并进入闭包，防止「构建机能跑、部署机缺库」；
- 闭包（第 17 章）= 从任一产物出发沿 references 走到头的集合。

配套工具：`nix-store -q --references <路径>` 查看直接引用；`--requisites` 查看闭包。

## 13.8 与上层设施的关系

本章的 `derivation` 是「机器码」级别的原语。真实 nixpkgs 的分层：

```
你的 package.nix
    └── stdenv.mkDerivation (finalAttrs: { ... })   ← 第 34 章：参数化工厂
            └── stdenv 的 setup.sh + phases 框架     ← 第 33 章：构建框架
                    └── derivation { ... }            ← 本章：原子施工单
```

每一层只做一件事：`mkDerivation` 把人类友好的参数（pname、nativeBuildInputs…）翻译成环境变量与脚本；stdenv 在构建期执行分阶段流程；`derivation` 保证输入哈希与隔离。读打包代码时心里有这张图，就不会迷路。

## 13.9 本章小结

- `derivation` 是连接求值与构建的原语：参数即输入清单，多余属性全部注入为构建环境变量。
- `.drv` 是施工单（ATerm 格式），其路径哈希锚定全部输入；`nix derivation show` 是现代观察方式。
- 构建成功的契约：产物出现在 `$out`（及各输出）路径。
- 多输出拆分闭包、提供安装粒度；`out` 是默认输出。
- 三种哈希模型：输入寻址（默认）、固定输出（可联网的 fetchers）、内容寻址（实验）。
- 引用关系由构建后扫描自动登记，闭包因此是数学事实。

## 延伸阅读

- Nix Pills 第 2-5 章（徒手玩 derivation 的经典教材）：https://nixos.org/guides/nix-pills/
- `nix derivation show` 手册：https://nixos.org/manual/nix/stable/command/new-cli/nix3-derivation-show
- 下一章（第 14 章）深入 `.drv` 产物的家：/nix/store。
