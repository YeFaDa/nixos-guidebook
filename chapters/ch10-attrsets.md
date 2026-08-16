# 第 10 章 属性集：Nix 世界的中心数据结构

> **本章导读**：Nix 没有类、没有结构体，也没有独立的「记录」类型——从 derivation 到 NixOS 配置，一切结构化数据都由属性集（attribute set，attrset）承载。本章完整覆盖属性集的语法、取值语义（尤其是 `or` 默认值的精确边界）、builtins 与 lib.attrsets 工具箱、`//` 浅合并与 `recursiveUpdate` 深合并的分野，以及与 JSON 的互转和惰性账单。属性集的层叠合并最终演化为 NixOS 模块系统的 config 合并（参见第 25 章），本章是通向那里的必经之路。

## 10.1 语法全解

### 10.1.1 字面量：分号不可省

```nix
# 属性集字面量：键 = 值; —— 每条以分号结尾，不能省略
{ }

{ greeting = "hello"; count = 2; }
```

三个必须记牢的语法事实：

1. **属性名的本质是字符串**。`greeting` 只是 `"greeting"` 的标识符写法，两者完全等价：`{ greeting = 1; }.greeting` 与 `{ "greeting" = 1; }."greeting"` 是同一个集合。
2. **同一字面量内重复定义属性是错误**。`{ a = 1; a = 2; }` 直接拒绝求值，报形如 attribute 'a' already defined 的错误，不会静默取后者——想合并请用 `//` 运算符（10.5 节）。
3. **值可以是任何表达式**：函数、列表、另一个属性集、derivation，都可以。属性集因此能同时充当「对象」「字典」「命名空间」三种角色。

初学者最常犯的错是漏分号——把 `;` 写成 `,` 或干脆不写。Nix 的错误信息通常能指向出错位置，但养成「每个键值对以分号收尾」的手感，比学会读错误更快。

### 10.1.2 嵌套写法是语法糖

```nix
# 下面两行完全等价：
{ a.b.c = 1; }
{ a = { b = { c = 1; }; }; }
```

点号嵌套只是「少打几层括号」的糖，没有创造任何特殊结构；混写也合法，Nix 会自动归并到同一棵树上：

```nix
{ a.b = 1; a.c = 2; }   # 即 { a = { b = 1; c = 2; }; }
```

但重复定义约束依然生效：`{ a.b = 1; a = 2; }` 中 `a` 被定义了两次，报错。写 NixOS 配置时 `{ services.nginx.enable = true; services.nginx.port = 80; }` 这种「同一路径多行展开」正是靠这条糖规则合流的——如果嵌套写法会互相覆盖，配置文件就没法按主题分块书写了。

### 10.1.3 动态属性名

```nix
let
  name = "port";
in
{
  ${name} = 8080;                                  # 键取变量 name 的值："port"
  "app-${name}" = 1;                               # 字符串键也可以是插值表达式
  ${if name != "" then name else "default"} = 2;   # 任意可求值为字符串的表达式
}
```

`${...}` 里必须是**能求值为字符串**的表达式，否则报错——属性名的类型只有字符串一种。动态名常与 `listToAttrs`、`mapAttrs'` 配合，把列表数据「折叠」成属性集（10.4 节）；读取端与之镜像的写法是 `set.${name}`（10.2 节）。

### 10.1.4 inherit 简写回顾

```nix
let
  a = 1;
  src = { x = 1; y = 2; };
in
{
  inherit a;            # 等价于 a = a; —— 从外层作用域「抄」进属性集
  inherit (src) x y;    # 等价于 x = src.x; y = src.y;
}
```

`inherit`（继承）是第 8 章讲过的语法糖：消除 `x = src.x;` 这类左右同名的重复，让 diff 干净——新增一个字段时，`inherit (src) x y z` 只在行尾加一个词。它在包表达式与模块里出现频率极高，第 12 章的惯用法还会回到它。

## 10.2 取值：点号、or 默认值与函数应用

### 10.2.1 点号选择与动态选择

```nix
cfg.server.port          # 逐层选择
cfg."weird key"          # 键不是合法标识符时，用字符串形式
cfg.${someName}          # 键来自变量——与动态属性名互为镜像
```

选择不存在时默认直接报错，错误信息还会贴心地给出拼写相近的候选（attribute 'prot' missing, did you mean 'port'?）——但更优雅的处理方式是下面这个。

### 10.2.2 or 默认值：精确语义

```nix
cfg.server.port or 80    # 整条路径缺任何一环时，取 80
```

`or` 的语义比「属性缺失时给默认」更宽也更精确，值得逐条记：

- **默认值覆盖整条路径**：`a.b.c or d` 里无论缺的是 `c`、`b`，还是 `a`，甚至中间某一层根本不是属性集（比如是整数），都返回 `d`。
- **只救「缺失」，不救「错误」**：若 `a.b` 存在但它的值是 `throw "boom"`，求值照样失败——`or` 捕获的是「属性不存在 / 不是集合」，不是求值异常（第 11 章会解释为什么两者必须区分）。
- **默认值惰性求值**：默认表达式只在缺失真正发生时才被求值，写昂贵计算也不心疼。
- **`or` 是选择表达式的语法成分，不是函数**——不能写 `or(x.y, 80)`。

一个实践要点：把带 `or` 的选择传给函数时要加括号，`f (x.y or d)`；不加括号的 `f x.y or d` 不是合法语法，因为 `or` 必须紧贴属性路径。

与之配套的问号运算符只判断存在性、不取值：

```nix
cfg ? server            # cfg 是否有 server 属性
cfg ? server.port       # 整条路径都存在才为 true
```

### 10.2.3 `a.f x` 的解析规则

选择（`.`）比函数应用（空格）**结合得更紧**：

```nix
pkg.lib.concatStringsSep "," xs
# 解析为 (pkg.lib.concatStringsSep) "," xs —— 先选属性，再应用
```

应用本身左结合：`f x y` 是 `(f x) y`，这正是柯里化的语法根源（参见第 7 章）。两条规则叠加的推论：`set.fn arg` 永远表示「取出 set.fn 这个函数，应用于 arg」。属性集因此天然可以当**命名空间**用——你天天写的 `lib.xxx`、`pkgs.xxx`，本质是从两个巨大的属性集里选函数与包；第 9 章用过的 `lib.strings` 系列，则是命名空间里的又一层。

## 10.3 builtins 家族

操作属性集的内建函数（builtins）一览：

| 函数 | 作用 | 备注 |
|---|---|---|
| `attrNames` | 所有属性名 | **按字典序排序**返回 |
| `attrValues` | 所有属性值 | 顺序与 attrNames 一一对应 |
| `hasAttr` | 判断属性是否存在 | 与 `?` 运算符等价 |
| `getAttr` | 按名取值 | 与点号等价，但名字可以是变量 |
| `removeAttrs` | 删除若干属性 | 返回新集合，原集不变 |
| `listToAttrs` | 列表转属性集 | 元素形如 `{ name, value }`；重名时后者覆盖前者 |
| `mapAttrs` | 同时变换键与值 | 惰性（10.7 节） |
| `catAttrs` | 跨列表收集同名属性 | 冷门但无可替代 |
| `groupBy` | 按键把列表分组 | lib 有同名封装 |

（过滤属性集没有对应的 builtins——`builtins.filter` 只作用于列表；属性集过滤的惯用方案是 `lib.filterAttrs`，见下一节。另外 `genList` 属于列表家族，别在属性集里找它。）

逐个上手：

```nix
let
  example = { hello = 1; curl = 2; bash = 3; };
in
[
  (builtins.attrNames example)            # [ "bash" "curl" "hello" ] —— 注意排了序
  (builtins.attrValues example)           # [ 3 2 1 ] —— 与上面的顺序一一对应
  (builtins.removeAttrs example [ "curl" ])   # { hello = 1; bash = 3; }
  (builtins.getAttr "bash" example)       # 3 —— 键在变量里时的点号替代品
]
```

`attrNames` 按字典序排序这件事值得单独记：它保证了 `mapAttrsToList` 产出的顺序稳定——第 9 章生成 nginx 配置时各段顺序不随机，根源就在这里。

```nix
# listToAttrs：把「键值对列表」折叠成属性集
# 元素不是 { name, value } 形状会直接报错——宁缺毋滥
builtins.listToAttrs [
  { name = "a"; value = 1; }
  { name = "b"; value = 2; }
]
# { a = 1; b = 2; }
```

```nix
# mapAttrs：函数同时拿到「键」与「值」——比先 attrNames 再取值干净得多
builtins.mapAttrs (n: v: v * 10) { a = 1; b = 2; }   # { a = 10; b = 20; }

# catAttrs：从「属性集的列表」里收集某个属性，没有该属性的元素被跳过
builtins.catAttrs "a" [ { a = 1; } { b = 2; } { a = 3; } ]   # [ 1 3 ]

# groupBy：按键分组——一列杂项瞬间变成按类归档的字典
builtins.groupBy (n: if n < 0 then "neg" else "pos") [ -1 2 -3 4 ]
# { neg = [ -1 -3 ]; pos = [ 2 4 ]; }
```

## 10.4 lib.attrsets 常用函数精讲

nixpkgs 的 lib 在 builtins 之上补齐了工程实践需要的操作。以下每个都值得形成肌肉记忆（完整签名以 nixpkgs 手册为准）。

### mapAttrs'：改名 + 改值

`mapAttrs` 不能改键名。要「顺便改名」，用 `mapAttrs'`（注意撇号）搭配 `nameValuePair`：

```nix
# 给每个条目起一个带后缀的新名字
lib.mapAttrs'
  (name: value: lib.nameValuePair "${name}-pkg" value)
  { hello = pkgs.hello; }
# 结果：{ "hello-pkg" = <hello 的 derivation>; }
```

`lib.nameValuePair name value` 构造 `{ name = …; value = …; }`——正是 `listToAttrs` 需要的元素形态。两者接力，就实现了「属性集 → 处理 → 属性集」的改名流水线。

### mapAttrsToList：属性集 → 列表

```nix
lib.mapAttrsToList (name: value: "${name}=${toString value}") { a = 1; b = 2; }
# [ "a=1" "b=2" ]
```

第 9 章的「属性集 → 文本」管道，前半段就是它。

### filterAttrs：按键值对过滤

```nix
lib.filterAttrs (n: v: v > 1) { a = 1; b = 2; c = 3; }   # { b = 2; c = 3; }
```

函数同时拿到键与值，按任意一边过滤都行（例如只保留以 `enable` 结尾的键）。

### attrVals：按键列表批量取值

```nix
lib.attrVals [ "b" "a" ] { a = 1; b = 2; }   # [ 2 1 ] —— 顺序跟键列表走
```

与「先把键排好、再统一取值」的场景天然契合，比如按既定顺序生成配置段。

### optionalAttrs：条件添加属性

```nix
lib.optionalAttrs pkgs.stdenv.isLinux {
  iptables = pkgs.iptables;    # 条件为真 → 返回这个集合
}                               # 条件为假 → 返回 { }，之后合并等于没写
```

它把「这段数据要不要存在」变成一个普通表达式。模块系统里的 `mkIf` 与之思想同源（第 25 章），10.8 节有完整实战。

### zipAttrsWith：把同名值收集成列表（简提）

```nix
lib.zipAttrsWith (name: values: values) [ { a = 1; } { a = 2; b = 3; } ]
# { a = [ 1 2 ]; b = [ 3 ]; } —— 多个集合里同名的值被聚合到一起
```

适合「多份来源各有部分字段、想按字段对齐」的场景；对聚合方式有要求时，换掉那个函数即可。

### recursiveUpdate 与 //：深浅合并的分野

先看 `//`（update 运算符）有多「浅」：

```nix
{ a = { x = 1; y = 2; }; } // { a = { z = 3; }; }
# 结果：{ a = { z = 3; }; } —— a 被整个换掉，x、y 消失了！
```

`//` 只看顶层：右侧出现的顶层属性直接顶掉左侧，**不做嵌套合并**。要嵌套合并，用 `recursiveUpdate`：

```nix
lib.recursiveUpdate { a = { x = 1; y = 2; }; } { a = { z = 3; }; }
# 结果：{ a = { x = 1; y = 2; z = 3; }; } —— 深处合并，各自保留
```

`recursiveUpdate` 的递归只发生在「两侧同位置的值都是属性集」时；否则同样右优先。两个附加警告：其一，它没有类型与冲突仲裁——两边都给 `enable` 一个布尔值时直接取右边，不提示、不报错；其二，对**自引用**集合（第 11 章 lib.fix 构造的那种）做深合并可能引发无限递归，因为深合并会试图钻进每一个属性。

### mergeAttrsList：多路浅合并的便捷形式

```nix
lib.mergeAttrsList [ { a = 1; } { b = 2; } { a = 3; } ]
# { a = 3; b = 2; } —— 从左往右 //，右者胜
```

来源多于两个时，它比 `a // b // c // …` 更能表达「这是一摞要合并的东西」，少打一层括号，也少一层心智负担。

### 路径三件套：attrByPath / getAttrFromPath / setAttrByPath

```nix
lib.attrByPath [ "a" "b" ] "缺省" { a = { b = 1; }; }   # 1；路径缺失则取 "缺省"
lib.getAttrFromPath [ "a" "b" ] { a = { b = 1; }; }     # 1；缺失则抛出带路径信息的错误
lib.setAttrByPath [ "a" "b" ] 42                         # { a = { b = 42; }; } —— 凭空造出嵌套
```

它们与 `or` 选择符可以互换；`getAttrFromPath` 的错误信息带完整路径，适合「缺了就该报错，而且要说清缺在哪」的场景；`setAttrByPath` 则常用于构造发往模块系统的嵌套 config。

### foldAttrs：跨集合归并同名的值

```nix
lib.foldAttrs (n: acc: n + acc) 0 [ { a = 1; } { a = 10; } { b = 5; } ]
# { a = 11; b = 5; } —— 把多个集合中同名属性的值折叠到一起
```

当多份清单各有部分字段、需要按字段聚合时，它比手写递归省心得多。

## 10.5 合并语义：从 // 到模块系统

### 10.5.1 浅合并 //：右优先、只看顶层

把 `//` 的行为总结成三条：**右侧优先**；**只合并顶层**，嵌套集合被整体替换；**惰性**——合并本身只重组结构，不求值未触及的值（第 11 章）。它是「默认值 + 用户配置」这一最常见叠加模式的惯用形：

```nix
# 模块内的经典写法：默认配置打底，用户覆盖在上（第 25 章的雏形）
{ config ? { } }:
{ port = 80; root = "/srv"; } // config
```

### 10.5.2 recursiveUpdate：深合并，但规则朴素

`recursiveUpdate` 解决「嵌套字段被整体顶掉」的问题，代价是规则朴素：能递归就递归，不能递归就右优先，没有冲突处理。对「两边结构由同一套代码约定」的场景（比如同一模块的默认值与覆盖值）它很好用；对「两份独立来源的配置」它太容易静默压掉别人的字段——这正是模块系统要解决的问题。

### 10.5.3 列表与字符串：两种合并都不救

一个常被忽略的事实：`//` 与 `recursiveUpdate` 对列表和字符串都是**整体替换**：

```nix
{ ports = [ 80 ]; } // { ports = [ 443 ]; }
# { ports = [ 443 ]; } —— 不是 [ 80 443 ]！列表不会被拼接
```

「把两边的端口列表连起来」「把两段配置文本拼起来」这类合并方式，纯属性集运算给不了——它们需要每个字段知道自己「该怎么合并」。记住这个缺口，下一小节的结论就有了着落。

### 10.5.4 层叠合并的终点：NixOS 模块系统

想象真实系统：发行版默认配置、硬件配置、管理员配置、各服务模块，层层叠加。用 `//` 串起来有三个死结：嵌套字段被顶层替换碾碎（10.5.1）；列表、字符串无法按语义合并（10.5.3）；两个模块给同一字段赋值时无规则可依。

NixOS 的答案是把「合并」升级为一等公民：**模块系统**（module system）让每个配置字段声明类型（`types.bool`、`types.lines`、`types.listOf`），由类型决定合并方式——布尔按优先级取舍、`lines` 把多段文本用换行拼接、列表做连接；再加上优先级（`mkOverride` / `mkDefault`）与条件（`mkIf`）两种调节阀。第 25 章会展开全貌；本章只需带走一个直觉：

**模块系统的 config 合并 ≈ 带类型与优先级的 recursiveUpdate。**

## 10.6 属性集与 JSON

### 10.6.1 toJSON / fromJSON / toFile

```nix
builtins.toJSON { name = "nix"; tags = [ "fun" ]; }
# "{\"name\":\"nix\",\"tags\":[\"fun\"]}"

builtins.fromJSON ''{ "name": "nix", "stars": 42 }''
# { name = "nix"; stars = 42; } —— JSON 对象直接变属性集
```

Nix 属性集与 JSON 对象结构相近，互转是把配置交给外部世界（或从外部读入）的最短路径：`toJSON` 的产物可以塞进 `pkgs.writeText` 生成配置文件（第 9 章），`fromJSON` 则常与 `lib.importJSON` 一起读取预生成清单。

```nix
# builtins.toFile：把字符串写成 store 里的内容寻址文件并返回路径
builtins.toFile "note.md" "# 笔记\n"
# "/nix/store/…-note.md"；内容寻址意味着同文本必得同路径（第 15 章）
```

`toFile` 有一条与第 9 章呼应的限制——`text` 若携带 derivation 上下文会被直接拒绝，防止依赖被悄悄丢弃；需要依赖追踪时请改用 `pkgs.writeText`。

### 10.6.2 nix eval --json：现代调试利器

```console
$ nix eval --json nixpkgs#hello.meta.platforms
["aarch64-linux","x86_64-linux",…]
$ nix eval --json --file select-packages.nix --apply 'builtins.attrNames'
["curl","git","iptables","strace"]
```

第二条命令对 10.8 节的示例文件求值，`--apply` 把结果喂给 `builtins.attrNames`，再以 JSON 输出。要点：`--json` 会把整个结果**深度求值**（第 11 章）——属性集里任何一个藏着 throw 的值都会在这一刻引爆。这让它既是「一次性看全结构」的利器，也是全量强求的性能陷阱；日常查看属性集形状时，nix repl 的浅打印（`nix-repl> s`）与深度打印（`:p s`）分工更细。

## 10.7 性能与求值：属性集的惰性账单

属性集是惰性的（第 11 章完整展开），账单规则先用三句话概括：

1. **构造便宜**：`{ a = 昂贵计算; }` 本身几乎零成本——昂贵计算被存成待求值的「蛋」（thunk），没人问就不算。
2. **遍历值就要求值**：`attrValues`、`mapAttrsToList`、`toJSON` 会把所有值强制求出来——任何一颗藏着的 throw 都在这里引爆。
3. **重排结构不动值**：`mapAttrs`、`removeAttrs`、`//`、`optionalAttrs` 只重组键与骨架，不碰未触及的值。

用一条命令感受规则 1 与 2 的差距：

```console
$ nix eval --expr 'let
    big = builtins.listToAttrs (builtins.genList (i: { name = toString i; value = i; }) 100000);
  in builtins.length (builtins.attrNames big)'
100000
# attrNames 只看键：十万个条目瞬间清点完毕；
# 若换成 attrValues 逐个强制求值，成本立刻上一个台阶（本例的值是廉价整数，故差距小；
# 真实 nixpkgs 里每个值可能是一整条依赖链的求值）
```

NixOS 配置本身就是一个巨大的属性集，`nixos-rebuild` 之所以能以秒级完成求值，正因为其中绝大多数属性从未被需要——「为什么可以只算一小块」是第 11 章的主题。

## 10.8 综合示例：按平台选包

目标：基础包清单人人都有；Linux 追加网络与调试工具；macOS（Darwin）追加窗口管理工具。逐行注释：

```nix
# select-packages.nix —— optionalAttrs + // 组合出按平台的包集合
let
  pkgs = import <nixpkgs> { };
  inherit (pkgs) lib;      # 从 pkgs 里抄出 lib，后面少打几个字（inherit 糖）

  # 三份纯数据：共同基础、Linux 专属、Darwin 专属
  base = {
    curl = pkgs.curl;      # 下载工具，哪个平台都要
    git = pkgs.git;        # 版本控制
  };

  # 条件为真 → 返回字面集合本身；为假 → 返回 { }，之后合并等于没写过
  linuxOnly = lib.optionalAttrs pkgs.stdenv.isLinux {
    iptables = pkgs.iptables;   # Linux 防火墙管理工具
    strace = pkgs.strace;       # 系统调用追踪，Linux 专属
  };

  darwinOnly = lib.optionalAttrs pkgs.stdenv.isDarwin {
    skhd = pkgs.skhd;           # macOS 热键守护进程，Darwin 专属
  };
in
  # // 右优先浅合并：三份清单叠成一份。
  # 平台互斥，实际不会发生覆盖——需要覆盖语义时右者胜
  base // linuxOnly // darwinOnly
```

验证与推论：

```console
$ nix eval --json --file select-packages.nix --apply 'builtins.attrNames'
["curl","git","iptables","strace"]
```

四个值得展开的观察：

- 这条求值只强制了属性名，三个 derivation 本身仍是未拆封的蛋（10.7 节规则 3 的现场演示）。
- 想把结果当包列表用：`builtins.attrValues` 展开即可——但注意那一刻才真正求值每个包（规则 2）。
- 在 NixOS 模块里，同样的代码不需要 `import <nixpkgs>`，`lib` 与 `pkgs` 由模块系统作为参数传入（第 24 章）；再把 `optionalAttrs` 换成 `mkIf`，它就成了随开关启停的一整段配置（第 25 章）。
- 来源更多时，用 `mergeAttrsList [ base linuxOnly darwinOnly ]` 表意更直白；如果字段存在嵌套且需要保留两侧，才轮到 recursiveUpdate 登场。

## 10.9 本章小结

- 属性集字面量每条以分号结尾；同一字面量内重复定义属性是错误；`a.b.c = 1` 是嵌套的语法糖，可混写合流。
- 动态属性名 `{ ${name} = v; }` 的键必须求值为字符串；`inherit (src) a b` 是消除重复的高频糖。
- `or` 默认值覆盖整条路径的缺失（含中间层不是集合），但不捕获求值错误；`?` 只判断存在性。
- 选择比应用结合紧：`a.f x` 恒为 `(a.f) x`，属性集因此可当命名空间用。
- `attrNames` / `attrValues` 按字典序稳定输出；属性集过滤用 `lib.filterAttrs`，分组用 `groupBy`。
- `mapAttrs'` 配 `nameValuePair` 改名；`mapAttrsToList` 是「属性集 → 文本」管道的前半段；`optionalAttrs` 让一段数据有条件地存在。
- `//` 浅合并右优先、嵌套与列表整体顶掉；`recursiveUpdate` 深合并但无类型无仲裁；两者的缺口正是模块系统类型的用武之地。
- 模块系统 ≈ 带类型与优先级的深度合并（第 25 章）；`nix eval --json` 深度强求，是调试利器也是性能陷阱。

## 延伸阅读

- Nix 手册 · 运算符（选择、or、?、//）：https://nix.dev/manual/nix/stable/language/operators
- Nix 手册 · 内建函数（attrNames、mapAttrs 等）：https://nix.dev/manual/nix/stable/language/builtins
- nixpkgs 手册 · lib.attrsets：https://nixos.org/manual/nixpkgs/stable/#sec-functions-library-attrsets
- nix.dev · Nix 语言教程：https://nix.dev/tutorials/nix-language
