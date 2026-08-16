# 第 11 章 惰性求值：Nix 的执行模型

> **本章导读**：同样是「执行」一段程序，Nix 与 Python、C 的根本区别在于：Nix 只计算「被问到的问题」。本章把这个直觉补成知识体系：什么是惰性求值（lazy evaluation）、求值到什么程度为止（弱头部范式）、如何在 nix repl 里亲眼看到它，以及何时该用 seq / deepSeq / foldl' 收紧缰绳。最后讲惰性加递归如何变出 lib.fix 这样的魔法——nixpkgs 的自引用包集合与 NixOS 模块系统都建立在其上（参见第 25、32 章）。

## 11.1 什么是惰性：被需要时才计算

### 11.1.1 从一段对照开始

先看严格求值（strict evaluation）语言的行事方式：

```python
# Python：定义即执行，异常立刻发生
x = 1 / 0          # 这一行就崩——没人「用」x 也一样
```

再看 Nix：

```nix
# Nix：定义只是记账，谁需要 x 谁负责
let x = 1 / 0; in { msg = "hello"; }   # 不报错——x 从未被需要
```

在 Nix 表达式里，每个值在被「需要」之前，都以未求值的形式存在——可以想象成一枚贴着表达式、等待拆封的蛋，术语叫 thunk（暂缓计算的表达式）。一旦某个值被需要，求值器就把它拆开算出结果，并把结果原地记住：**同一个值在同一次求值中不会被算第二次**（求值共享，11.6 节）。

这个模型要抛弃的直觉是「代码是从上到下执行的」。Nix 代码没有「执行顺序」，只有「依赖关系」：结果依赖什么，求值器就去算什么；依赖链之外的一切，写得多夸张都无关紧要。

画成一张图（箭头表示「被需要」）：

```text
表达式：let y = x * 2; x = 41; in "答案：${toString y}"

    "答案：${…}"          ← 最终被打印，需要整体求值字符串
        │ 于是需要插值 toString y
        ▼
      toString y          ← 需要 y
        ▼
      y = x * 2           ← 需要 x
        ▼
      x = 41              ← 落地！不再依赖别人，结果逐层回填
```

注意方向：求值从**结果**出发倒着走，而不是从 `let` 的第一行顺着走。这与第 4 章的声明式思想一脉相承——你声明的是关系，不是步骤。

### 11.1.2 求值到什么程度：剥洋葱只剥第一层

「被需要」也有程度之分。Nix 把值求值到**弱头部范式**（weak head normal form，WHNF）就停手——不用管这个名字的出处，记比喻即可：**剥洋葱只剥最外层**。知道它是个洋葱了，就不再往下剥。

严格地说，WHNF 指表达式最外层的「构造」已经确定：

- 是一个**属性集** → 知道它是属性集、有哪些键即可，**值一概不碰**；
- 是一个**列表** → 知道它是列表即可，**元素不碰**；
- 是一个**字符串** → 字符串没有「部分求值」，一旦需要就整体求出（包括其中每个插值）；
- 是一个**函数** → 函数本身就是值，等应用到参数时再说。

用三个小实验验证边界（可以在 nix repl 里逐条跑）：

```nix
# 属性集：只有键集合被需要，值原封不动
builtins.attrNames { big = 超昂贵计算; bad = throw "还没炸"; }
# [ "bad" "big" ] —— 两个值都没被求值

# 列表：问长度只需要「脊」，不需要元素
builtins.length (map (x: throw "boom") [ 1 2 3 ])   # 3 —— 元素从不被求值

# 字符串：需要就整体求值，插值逐个兑现
"${toString (throw "boom")}"   # error: boom

# 函数：不应用就永远是「值」，函数体从不被进入
let f = x: builtins.trace "执行了" x; in builtins.isFunction f
# true —— trace 没有任何输出，说明 f 的函数体从未执行
```

第一条利用了第 10 章讲过的事实——键在集合成形时就已确定；第二条是列表版同理；第三条说明字符串没有「半成品」：要么不算，要么算完整。

## 11.2 实验演示：眼见为实

### 11.2.1 throw 的炸弹只有踩上才响

```console
$ nix repl
nix-repl> :l <nixpkgs>              # 载入 nixpkgs，获得 lib 与 pkgs
Added … variables.
nix-repl> bad = throw "boom"        # 定义：只是记账，不响
nix-repl> s = { a = 1; b = bad; }   # 构造集合：仍然不响
nix-repl> s.a
1                                   # 只强制 s.a，b 的炸弹不炸
nix-repl> s.b
error: boom                         # 这一刻才强制求值
```

命令行同理：

```console
$ nix eval --expr 'let x = throw "boom"; in { a = 1; }'
{ a = <code>; }
$ nix eval --expr 'let x = throw "boom"; in x'
error: boom
```

第一条命令成功返回——注意结果里的 `<code>` 占位符：`nix eval` 默认**浅打印**，值没有被完全求出，属性 `a` 只显示一枚待拆的蛋。

### 11.2.2 nix repl 中赋值与 :p 的区别

repl 里直接敲 `s` 与敲 `:p s` 是两回事：前者浅打印（到 WHNF 为止），后者 `:p`（print）会**深度求值**后再打印：

```console
nix-repl> s = { a = 1; b = throw "boom"; }
nix-repl> s
{ a = 1; b = <code>; }
nix-repl> :p s
error: boom                        # :p 深度强制，藏着的炸弹被引爆
```

列表同理——浅打印能直接看到「几枚蛋」的结构：

```console
nix-repl> xs = map (x: throw "boom") [ 1 2 3 ]
nix-repl> xs
[ <code> <code> <code> ]           # 三个元素都是未拆封的蛋
nix-repl> builtins.elemAt xs 0
error: boom                        # 摸第一个元素，第一枚蛋被拆开
```

调试时善用这一对差异：先浅看结构、确认哪一层可疑，再 `:p` 全量引爆定位。配套的 `:t` 只看类型（set、list、string、lambda……），比浅打印更快。顺带一提：`:p` 与 `nix eval --json`（第 10 章）的强制深度同级，都把整棵子树剥完——「先浅看、再深爆」两步走，是排查大型属性集的标准动作。

### 11.2.3 排错含义：错误出现在「被强制」的地方

惰性求值下，「错误的定义位置」与「错误的爆发位置」可能相距甚远——一个 throw 可以定义在 A 模块，很久之后在 B 模块的某次选择中引爆。排错思路因此与传统语言不同：看到 error，先问「**谁逼它求值**」，再顺藤摸瓜回到定义处。`--show-trace` 与 repl 的调试模式就是回答这个问题的工具（11.7 节）。

与之相关的还有一个反直觉现象：同一段配置，`nix build` 可能成功而 `nix flake check` 失败（或相反）——不是代码「时好时坏」，而是两条命令强制求值的范围不同。比较两次求值的差异，往往就是定位线索本身。

## 11.3 惰性与声明式模型：十万个包，秒级求值

nixpkgs 是人类最大的软件仓库之一，描述着十万量级的包（第 32 章）。可 `nix build nixpkgs#hello` 的求值阶段通常只要几秒——为什么？

因为求值器从 `hello` 出发，只强制「从结果往回追溯」的那条链：`hello` 的 derivation → 它的 `src`、`buildInputs` → 每个依赖包的同款追溯……仓库里其余的包依然是未拆封的蛋。**整个 nixpkgs 不是一份排队执行的程序，而是一张按需展开的图**：你问到哪，它展开到哪。

以 `nix build nixpkgs#hello` 为例，求值器走过的路径大致是：

1. 导入 nixpkgs、得到 `pkgs` 集合——此时只是骨架，几乎没有求任何包；
2. 选择 `hello` 属性——强制求值 hello 的包表达式（第 32 章会讲它躺在哪个文件里）；
3. 求它的 derivation 属性：`src`（触发 fetchurl 的求值，第 13 章）、依赖列表（逐个强制依赖包的同款展开）；
4. 求值完成的 derivation 被写成 `.drv` 文件（第 13 章），交给构建调度。

整条路径没有触碰 `pkgs.vim`、`pkgs.emacs`，或任何一个与 hello 无关的包。反事实推论也值得想一遍：若没有惰性，任何一次构建都得先把十万量级的包全部求值成 derivation，按分钟起步计算——`nix search`、`nix-env` 之外的几乎所有日常工作流都会变得不可用。

这与声明式模型（第 4 章）互为表里：声明只描述「是什么」，而「是什么」只有在被观察（求值）时才需要具体化。也正因为如此，给 nixpkgs 叠加 overlay（第 39 章）、给 NixOS 增加一个模块（第 25 章），基本不会拖慢未触及部分的求值——它们只是往图上挂了新的、可能永远不被展开的节点。

反过来，这也能拆解一个常见误区：**「求值」不等于「构建」**。求值只是把图展开到你需要的那个 derivation——一份构建说明书；真正的编译安装发生在构建阶段（第 16 章）。惰性省下的，是「展开整张说明书」的钱；构建成本由二进制缓存与闭包复用另算（第 17、20 章）。

## 11.4 控制严格性：seq、deepSeq、foldl'……

惰性是默认，但有时你要反过来「强制」。工具箱如下：

```nix
# builtins.seq e1 e2：把 e1 求到 WHNF（剥第一层），然后求值并返回 e2
builtins.seq config.services.nginx.enable "ok"
# 用途：确保关心的字段「确实存在且能求值」，错误提前暴露

# builtins.deepSeq e1 e2：把 e1 深度求值（整颗洋葱剥完），返回 e2
builtins.deepSeq config "ok"
# 用途：把藏在整个配置深处的 throw 提前引爆——
# nix eval --json 的行为本质上就是这类深度强制（第 10 章）

# lib.foldl' —— 注意撇号（prime）：每一步都把累加器强求到 WHNF
lib.foldl' (acc: n: acc + n) 0 (lib.range 1 1000000)
# 若用不带撇号的 builtins.foldl，会先长出一条百万层深的
# 「((0+1)+2)+3…」待求值链，最后一次性求值——内存与栈都可能撑爆
```

两个小工具也在此一并交代，它们常与惰性配合出现：

```nix
lib.id = x: x;          # 恒等：常作「默认变换函数」的占位
lib.const = x: y: x;    # 恒返回第一个参数：常用于构造「忽略输入」的分支
```

什么时候需要主动严格化？三个典型场景：

1. **提前暴露错误**（fail fast）：构建开始前把配置 deepSeq 一遍，让错误死在求值阶段，而不是构建或部署中途。
2. **斩断长 thunk 链**：foldl' 的撇号就是为此——共享虽好，链条太长时内存先倒下。
3. **控制序列化时机**：toJSON、`--json` 本质上就是深度强制（第 10 章）。

第 1 个场景有个惯用形值得记——「门口验证」：让值穿过 deepSeq 之后再出门。

```nix
# 模块返回 config 前，先把整份配置剥完一遍：
# 表面看是「返回原值」，实际先把 rawConfig 整颗强制求值——
# 藏在深处的 throw 在这里引爆，而不是在三天后的部署现场
config = builtins.deepSeq rawConfig rawConfig;
```

原则：**默认保持惰性，有明确理由才加强制**。随手 deepSeq 会把「秒级求值单个包」的优势还给严格语言；正确姿势是只对真正想验证的子树强制，例如 `builtins.seq cfg.server.port …` 而不是 `builtins.deepSeq 整个 pkgs …`。

## 11.5 惰性 + 递归 = 魔法：lib.fix 详解

### 11.5.1 fix 的定义：先假装拿到结果

```nix
# 数学表述：fix f = f (fix f) —— 求 f 的不动点（fixed point）
# nixpkgs 的实现（lib/fixed-points.nix）用 let 让两处引用共享同一个 thunk：
fix = f: let fixpoint = f fixpoint; in fixpoint;
```

`lib.fix` 接受函数 `f`，返回 `f` 的不动点：一个「先假装存在、再由 f 构造出来」的值。动手试一次胜过看十遍定义：

```console
nix-repl> lib.fix (self: { a = 1; b = self.a + 10; })
{ a = 1; b = 11; }
```

发生了什么？`self` 代表「这个集合的最终结果」。定义 `b` 时引用了此刻尚不存在的 `self.a`——但没关系：真正需要 `b` 时，惰性求值允许先立字据后兑现，而那时 `self`（同一张字据网络）早已算出 `a`。**直觉：先假装拿到结果，再真正构造它。**

### 11.5.2 rec { } 就是 fix 的语法糖

```nix
# 两种写法等价：
rec { a = 1; b = a + 10; }
lib.fix (self: { a = 1; b = self.a + 10; })
```

`rec`（递归属性集，recursive attribute set）允许集合内部互相引用，本质就是把集合交给 fix。理解这层等价后，第 12 章反模式清单里「rec 与 override 不合」的坑也顺理成章：override 修改的是 fix **之外**的结果，rec 内部字据引用的仍是旧值——这正是包表达式改用 finalAttrs 的动机（第 12 章）。

递归属性集也能与 mapAttrs（第 10 章）组合出更实用的形态——「每个字段的最终值由加工函数给出，加工过程可以引用同层其他字段的最终值」：

```nix
# 字段 b 的最终值 = 原始值 10 + 同层 a 的最终值
lib.fix (self: lib.mapAttrs (name: initial:
  if name == "b" then self.a + initial else initial
) { a = 1; b = 10; })
# 结果：{ a = 1; b = 11; }
```

读法：mapAttrs 把「原始集合」加工成「最终集合」，self 就代表最终集合；b 加工时引用了 self.a，惰性保证这条「先立字据、后兑现」的引用成立。nixpkgs 里围绕 fix 的 `lib.extends`、`makeScope` 等设施都是这一模式的生产级变体（第 32 章）。

fix 还有一个结构性优点：既然集合是「函数 f 的不动点」，那么想改集合，只需**把 f 包一层再求新的不动点**——不用改动、也不用复制原来的 f。overlay（叠加层）正是这样一层包装：它站在 f 与最终集合之间，按需增删改字段（第 39 章）。惰性保证了这一切的组合成本依旧只发生在被触及的字段上。

### 11.5.3 为什么不会死循环

惰性不是免死金牌。递归必须「有底」：

```nix
lib.fix (self: { x = self.x; })
# error: infinite recursion encountered
```

`x` 的定义依赖 `x` 自己，没有任何一条路能先落地一个不依赖 self 的值——求值器发现字据循环，报 infinite recursion（无限递归）错误。良性递归的共同点：至少有一条路先算出**不依赖 self** 的值（上例的 `a = 1`），其余字段再挂上去。

「有底」不限于单字段，互相引用也行，只要环上有一处随调用收敛：

```nix
lib.fix (self: {
  even = n: n == 0 || self.odd (n - 1);    # 偶数：0 是底
  odd = n: n != 0 && self.even (n - 1);    # 奇数：一路减到 0
})
# self.even 4 → true：两个字段互相引用，但 n 每轮减 1，
# 环最终落在 n == 0 这个不依赖 self 的判断上
```

### 11.5.4 一句话预告

nixpkgs 的 `pkgs` 就是用 lib.fix 构造的自引用包集合——包 A 能引用「整个 pkgs」里的包 B，B 又能引用 pkgs（第 32 章）；NixOS 模块系统同样靠惰性打破「config 依赖 options、options 依赖 config」的循环（第 25 章）。fix 是这两座大厦共同的地基。

## 11.6 性能陷阱

### 11.6.1 共享与它的边界

求值器是按需调用（call-by-need）：同一个 thunk 在一次求值中至多算一次，之后所有引用共享结果。因此「同一个大表达式在多处被使用」在同一次求值里并不额外昂贵——mapAttrs 包一层、`//` 合一层，都不会让值被重复求值。但共享有边界，两处例外要心里有数：

- **跨进程不共享**：每条 nix 命令（nix build、nix eval、nix flake check……）都是一次全新求值，上次的成果不带走。Flakes 提供按提交缓存的求值缓存（evaluation cache），能显著缩短重复求值，细节以官方文档为准。
- **跨 derivation 的重复是真实的**：若一个昂贵求值的结果被塞进一百个 derivation 的环境变量，求值层面只算一次，但产物层面存在一百份拷贝——省不掉的存储与传输成本。

### 11.6.2 全量强制：--json、--raw 与 flake check

```console
$ nix eval --raw nixpkgs#hello.name   # 只强求一个字符串（无尾换行输出）
$ nix eval --json nixpkgs#hello.meta  # 深度强求整个 meta，再序列化
```

`--raw` 只接受单个字符串并强求它；`--json` 把结果递归序列化，等价于一次 deepSeq。`nix flake check` 要检查所有输出，求值覆盖面大，在大型仓库上耗时可观（第 44 章）。调试利器与性能陷阱，常常是同一个东西的两种叫法。

用时间感受一下量级差异（示意，具体秒数因机器与缓存而异）：

```console
$ nix eval --raw nixpkgs#hello.version   # 秒级：只强制 hello 这一条链
$ nix flake check github:NixOS/nixpkgs   # 分钟级：几乎展开整张图
```

### 11.6.3 内存与「顺手 deepSeq」

求值过程中的 thunk 与已共享的结果都住在内存里，大型配置的全量强制可能把内存推高；求值器自带垃圾回收，通常无需操心，但两种写法会人为放大占用：对巨型集合无差别 deepSeq；以及不带撇号的 foldl 累积超长链条（11.4 节）。如果 `nix-instantiate`/`nix eval` 在大仓库上内存吃紧，先检查这两处再怀疑语言本身。

### 11.6.4 nixpkgs 求值性能治理的现状

nixpkgs 的求值性能是被持续治理的指标：CI 基础设施（如 ofborg 与 Hydra）会对整个 pkgs 做全量求值——每个包的 derivation 与 meta 都要算出来——求值变慢会拖慢全仓库的评审与合并。因此社区对「让默认求值变贵」的改动非常敏感，常见守则包括：避免在顶层无谓地 attrValues / listToAttrs、把昂贵计算推迟到真正被需要的字段、警惕会让大量属性意外强求的「顺手 deepSeq」。

你在自己的代码里遵循同样的守则，就能同时服务两类读者：今天交互式使用它的自己，与未来某天全量强制它的 CI 或同事。治理工具与指标随时间演进，以 nixpkgs 官方资料为准。

## 11.7 调试工具箱

### 11.7.1 nix repl 常用命令

```console
$ nix repl
nix-repl> :?                     # 帮助——先把这张表看一遍
nix-repl> :l <nixpkgs>           # 载入：之后可直接用 pkgs.hello、lib 等
nix-repl> pkgs.hello             # 浅打印：能看到结构与 <code> 占位
nix-repl> :p pkgs.hello.meta     # 深度求值并打印
nix-repl> :t pkgs.hello          # 只看类型（set）
nix-repl> :e                     # 把刚输入的表达式送进 $EDITOR，
                                  # 保存后重新求值——适合试验多行草稿
nix-repl> :b pkgs.hello          # 直接在 repl 里构建这个 derivation
nix-repl> :s pkgs.hello          # 只构建其依赖（调试构建链时省时间）
nix-repl> :d                     # 切换调试模式：出错时进入交互式栈帧，
                                  # 可逐层查看「谁在求值谁」（Nix 2.18+）
```

（`:e` 与 `:d` 的具体交互细节以当前版本的官方手册为准；`:d` 的核心价值在于把 11.2.3 的「谁逼它求值」变成可交互追问的问题。）

### 11.7.2 builtins.trace：打印并返回原值

```nix
builtins.trace "走到这里了" (1 + 1)
# stderr 打印：trace: 走到这里了
# 表达式的值仍是 2 —— trace 不改变任何语义，纯粹偷看

# 更实用：把值本身打进标签——求值流到哪，值就带路到哪
version = builtins.trace "openssl 版本：${openssl.version}" openssl.version;
```

因为 trace 返回原值，它可以插入任何表达式中间而不断链；又因为惰性，trace 只在被强制时才打印——它本身就是一个「求值到没到过这里」的探针。lib 在此之上封装了 `lib.traceVal`（打印并返回值本身）、`lib.traceSeq`（强制一层再打印）等变体，按 lib 文档取用。

### 11.7.3 --show-trace：读堆栈的姿势

默认错误只给一行结论；`--show-trace` 展开完整求值栈：

```console
$ nix eval --show-trace --file myconfig.nix
error: …
… while evaluating the attribute 'server.port'
     at …/myconfig.nix:12:5:
… while calling anonymous lambda
     at …/nginx.nix:40:9:
…
```

从上往下读就是「谁在求值谁」的链条：最顶端是引爆点，往下逐层是被连带强制的属性与函数调用，最底下是源头定义。配合 11.2.3 的方法论：先定位「谁逼它求值」，再回到定义处修根因——而不是在爆发点贴 tryEval 创可贴（第 12 章讲 tryEval 的正确用法与边界）。

### 11.7.4 实战：把一个错误追到底

准备一份带病的配置：

```nix
# broken.nix —— 埋雷：配置里没有 server.port，
# 兜底逻辑用 throw 明确拒绝「随便给个默认值」
let
  portOf = cfg: cfg.server.port or (throw "配置里没有 server.port");
  cfg = { server = { }; };   # 只有 server，没有 port
in
"listen ${toString (portOf cfg)};"
```

第一步，裸跑，只拿到一行结论：

```console
$ nix eval --file broken.nix
error: 配置里没有 server.port
```

第二步，加 `--show-trace`，看「谁逼它求值」（具体行文随 Nix 版本略有差异，读法不变）：

```console
$ nix eval --show-trace --file broken.nix
error: 配置里没有 server.port
… while calling the 'throw' builtin
… while evaluating …
… while evaluating the attribute 'server.port'
… (直至源头定义)
```

第三步，按链条反推：结论在 portOf 里，但真正的问题在于「这段配置为什么没有 port」——修复点在 cfg 的来源（比如 NixOS 的 configuration.nix），而不是在 portOf 里把 throw 换成 80。这就是 11.2.3 的方法论落地：**错误爆发在强制点，根因在定义处，链条靠 trace**。

若错误发生在 nix repl 的探索过程中，先 `:d` 打开调试模式再复现，出错时求值器会停在栈帧上，可以逐层检查每一层的绑定——相当于把 `--show-trace` 从「事后尸检」升级成「现场勘查」。

## 11.8 本章小结

- 惰性 = 被需要才计算，且只计算到被需要的程度；未求值的值以 thunk 存在，结果在同一次求值中被共享。
- WHNF =「剥洋葱只剥第一层」：属性集只到键集合、列表只到「是列表」、字符串一需要就整体求出。
- repl 浅打印与 `:p` 深打印对应两种求值深度；错误只在强制处爆发，排错先问「谁逼它求值」。
- nixpkgs 秒级求值单一包的原因：整个仓库是一张按需展开的图，未触及的包仍是未拆封的蛋；求值不等于构建。
- builtins.seq / deepSeq、lib.foldl' 的撇号用于收紧严格性：提前暴露错误、斩断长 thunk 链；无理由不要全量强制。
- lib.fix = f (fix f)；rec { } 是它的语法糖；递归必须有「不依赖 self 的底」，否则无限递归。
- nixpkgs 的 pkgs 与 NixOS 模块系统的自引用结构都建立在 fix 与惰性之上（第 25、32 章）。
- `--json` / `--raw` 是全量强求；repl 的 `:p` / `:t` / `:d`、builtins.trace、`--show-trace` 是惰性世界的四件调试利器。

## 延伸阅读

- Nix 手册 · 语言结构（let、rec、inherit）：https://nix.dev/manual/nix/stable/language/constructs
- Nix 手册 · 内建函数（seq、deepSeq、trace、tryEval）：https://nix.dev/manual/nix/stable/language/builtins
- nixpkgs 手册 · lib.fixed-points（fix 家族）：https://nixos.org/manual/nixpkgs/stable/#sec-functions-library-fixed-points
- nix.dev · Nix 语言教程：https://nix.dev/tutorials/nix-language
