# 第 7 章 函数：lambda、多参数与柯里化

> **本章导读**：函数是 Nix 语言里唯一的「行为单元」：参数如何声明、如何匹配属性集、如何组合，决定了你能否读懂 nixpkgs 里每一行代码。本章除了讲透柯里化与模式匹配参数，还专门用一节对照「✅ 现代 finalAttrs 写法」与「⛔ 过时的 rec 写法」——这是近年 nixpkgs 最重要的风格迁移，旧教程普遍还在教后者。

## 7.1 函数语法：一个冒号，两边都是表达式

Nix 函数的完整语法就是 `参数: 函数体`，读作「接收参数，返回函数体的值」：

```nix
x: x + 1              # 一个匿名函数（lambda）：接收 x，返回 x+1
name: "Hello, ${name}"
```

函数是值（一等公民）：可以放进列表、存进属性集、当作参数传递、从函数返回。事实上 Nix **只有**匿名函数——函数没有内建的命名语法，起名靠 `let`（第 8 章）或属性集：

```nix
let
  inc = x: x + 1;     # 「命名」只是把 lambda 绑定到一个名字
in
  inc 41              # 42
```

`:t` 会告诉你它的类型是 `"lambda"`。函数也是唯一带「元信息」的值：`builtins.functionArgs f` 能返回模式匹配参数的名字与是否有默认值（7.9 节），这是 `callPackage` 自动注入参数的底层依据（第 32 章）。

## 7.2 柯里化：多参数函数的真相

Nix 没有「多参数函数」这个语法。`a: b: ...` 的含义是：**返回函数的函数**：

```nix
add = a: b: a + b;       # 读作：a: (b: a + b)
add 2 3                  # 5 —— 解析为 ((add 2) 3)

addTwo = add 2;          # 部分应用（partial application）：先喂第一个参数
addTwo 40                # 42 —— 得到的仍是普通函数
```

这个过程叫柯里化（currying）。它不只是省写法：**部分应用是 Nix 世界组织代码的基本手法**——先固定「配置」，得到一个待填充「数据」的函数。你在 nixpkgs 里会大量见到：

```nix
# 生成器函数：先给参数，得到「待注入依赖的包模板」
mkDerivation = { ... }@args: ...;       # stdenv 的入口（第 34 章）
makeOverridable = f: args: ...;         # lib.trivial 中 override 机制的基石（第 39 章）
```

⚠️ 惯例提醒：柯里化链中，「越稳定的参数越靠前」。库作者把配置放前面、数据放后面，调用方就能优雅地部分应用。

## 7.3 模式匹配参数：nixpkgs 一切包定义的起点

比起裸柯里化，更常见的是**属性集模式（attrset pattern）参数**：参数不是一个名字，而是一个「解构声明」：

```nix
{ a, b }: a + b                  # 要求调用者传 { a = ...; b = ...; }
```

完整语法一次讲全，每个零件都有精确语义：

```nix
# ① 无默认值的必选参数
{ name, version }: ...

# ② 默认值：? 后跟表达式
{ name, prefix ? "" }: "prefix=${prefix}${name}"

# ③ 允许多余属性：调用者传了未声明的字段也不报错
{ name, ... }: "got ${name}"
# 没有省略号时，传多余字段会报「anonymous function called with unexpected argument」

# ④ @ 绑定：既解构、又保留整个参数集
args@{ lib, stdenv, ... }: lib.foo args
# 也写作 { lib, stdenv, ... }@args，两者完全等价，nixpkgs 两种都在用
```

现在你可以读懂 nixpkgs 中每一个包文件的开头了。以真实源码（master 分支 2026-08 快照，`pkgs/by-name/ri/ripgrep/package.nix`）为例逐行注释：

```nix
{
  lib,              # nixpkgs 标准库：取 license、maintainers、辅助函数
  stdenv,           # 标准构建环境：提供 mkDerivation（第 33 章）
  buildPackages,    # 「构建平台」的包集合：交叉编译时与 stdenv 区分（第 40 章）
  fetchFromGitHub,  # 源码获取器（第 15、37 章）
  rustPlatform,     # Rust 构建器家族（第 35 章）
  installShellFiles, # 构建期工具：安装 man/补全（构建完就不需要，所以是 native）
  pkg-config,
  withPCRE2 ? true, # 带默认值的开关参数：调用方可 .override { withPCRE2 = false; }
  pcre2,
  writableTmpDirAsHomeHook,
}:                  # ← 注意这个尾逗号：RFC 166 格式的标准样貌（Nix ≥ 2.4 支持）
```

这个参数集**不是**写死的清单——它就是一张「本包需要的依赖提货单」。`callPackage` 按名字自动从包集合里注入（第 32 章），`pkgs.ripgrep.override { withPCRE2 = false; }` 则按名字重新供货（第 39 章）。理解了「函数参数 = 依赖声明」，nixpkgs 的组织方式就透明了一半。

✅ 现行规范：参数按「先工具库（lib）、再构建设施、再依赖、最后开关参数（带默认值）」大致排列；多参数必用 7.3 的多行尾逗号格式（nixfmt-rfc-style）。⛔ 过时样貌：单行 `{ lib, stdenv, fetchurl }:` 仍合法，但 nixpkgs 新代码不再这样排版。

## 7.4 调用：空格即是括号

函数应用写作 `f x`，没有括号、没有逗号。优先级规则（第 6 章表格）的实用推论：

```nix
f x y           # ((f x) y)：左结合柯里化调用
f (x + 1)       # 想把 x+1 整体作为参数，必须括号
f x + 1         # 是 (f x) + 1，不是 f (x+1)！
map (x: x * 2)  # lambda 参数整体要括号
pkg.override { withPCRE2 = false; }   # 「属性集参数」的调用：跟在函数后面即可
```

最常用的复合调用形态：

```nix
stdenv.mkDerivation (finalAttrs: { ... })   # 函数参数是另一个函数（见 7.5）
builtins.foldl' (acc: x: acc + x) 0 list    # 高阶函数 + 柯里化
lib.optionalString withPCRE2 "已启用"        # 部分应用已经藏在调用顺序里
```

## 7.5 命名、递归与自引用：rec、fix 与 finalAttrs

函数体里想引用「正在定义的函数」需要名字；属性集内部的字段想互相引用需要 `rec`。两者都是**合法但需谨慎**的结构：

### 7.5.1 rec 属性集：能不用就不用

```nix
rec {
  version = "1.2.3";
  src = fetchurl {
    url = "mirror://gnu/example/example-${version}.tar.gz";  # 引用同集字段
    hash = "sha256-...";
  };
}
```

`rec` 让集合内字段可以互相引用。两个真实代价：

1. **被 override 破坏**：`pkg.overrideAttrs`（第 39 章）替换 `version` 后，`src` 里插值的还是**旧求值结果**吗？——不是，插值是惰性的、按最终字段值求值；但当你把 `src` 也一并 override 时，`rec` 里的交叉引用极易和 override 后的字段失去同步，出现「版本改了、URL 没改」的隐性 bug。
2. 静态分析困难：`statix` 等工具对 `rec` 内引用的追踪有限。

### 7.5.2 ✅ 现代：`finalAttrs` 模式（现行推荐）

这是近年 nixpkgs 最重要的风格迁移。把 `mkDerivation` 的参数写成「接收一个属性集的函数」，就得到一个**可被 override 后自动保持一致**的自引用结构：

```nix
# ⛔ 过时写法（2010 年代教材通用）：
stdenv.mkDerivation rec {
  pname = "example";
  version = "1.2.3";
  src = fetchurl {
    url = "mirror://gnu/example/example-${version}.tar.gz";
    # rec 的自引用在 overrideAttrs 后可能与新值脱节
  };
}

# ✅ 现行写法（nixpkgs 已完成整体迁移，2026 年新包一律如此）：
stdenv.mkDerivation (finalAttrs: {
  pname = "example";
  version = "1.2.3";
  src = fetchurl {
    url = "mirror://gnu/example/example-${finalAttrs.version}.tar.gz";
    # 引用 finalAttrs.version：任何 overrideAttrs 改了 version，
    # src 的求值都会基于改后的值重新计算，引用永不脱节
  };
  passthru = {
    # passthru 里也用 finalAttrs 引用，tests/update 脚本同理
    updateScript = ./update.sh finalAttrs;
  };
})
```

`finalAttrs` 这个名字是社区约定（不强制，但 nixpkgs 评审会要求它）：表示「**最终**形态的属性集」。它配合 `mkDerivation` 内部机制（`lib.fix` + `makeOverridable`）工作：override 发生时，传入函数的 `finalAttrs` 就是 override 合并后的完整属性集。

> 📌 **给从旧教程过来的读者**：你在网上看到的 `rec { ... }` 版包定义绝大多数写于 2023 年之前，仍然能构建，但（1）提交 nixpkgs 会被要求改；（2）失去 override 一致性保证。新代码一律 `finalAttrs`。真实范例参见第 36-38 章逐行精讲的 hello、fzf、ripgrep。

### 7.5.3 lib.fix：自引用的数学骨架（可选深潜）

`rec` 与 `finalAttrs` 的底层是**不动点（fixed point）**：

```nix
fix = f: let x = f x; in x;   # lib.fix 的语义：f 的不动点

# rec { a = 1; b = a + 1; } ≈ lib.fix (self: { a = 1; b = self.a + 1; })
#   lazy 求值让「先假装有 x，再算 x」合法（第 11 章）
```

nixpkgs 的整个 `pkgs` 集合就是 `lib.fix` 出来的自引用巨网（第 32 章），NixOS 模块系统同样如此（第 25 章）。此处只需建立直觉：**Nix 用惰性求值把「自引用」从缺陷变成了构造工具**。

## 7.6 高阶函数：builtins 与 lib 的主力阵容

接收函数或返回函数的函数。内建部分（`builtins.*`）：

```nix
builtins.map (x: x * 2) [ 1 2 3 ]              # [ 2 4 6 ]
builtins.filter (x: x > 1) [ 1 2 3 ]           # [ 2 3 ]
builtins.foldl' (acc: x: acc * x) 1 [ 1 2 3 4 ] # 24：严格左折叠
#   ⚠️ 撇号（'）= 强制求值版本：foldl 不带撇号是惰性的，长列表会撑爆内存
builtins.sort (a: b: a < b) [ 3 1 2 ]           # [ 1 2 3 ]：比较器是柯里化双参函数
builtins.genList (i: i * i) 5                   # [ 0 1 4 9 16 ]：按索引生成
builtins.any (x: x > 2) [ 1 2 3 ]               # true：存在即真
builtins.all (x: x > 2) [ 1 2 3 ]               # false：全部才真
builtins.concatMap (x: [ x x ]) [ 1 2 ]         # [ 1 1 2 2 ]
```

`lib`（`import <nixpkgs> { }` 或 flake 的 `nixpkgs.lib`）的补充，nixpkgs 代码里出现频率极高：

```nix
lib.lists.optional 条件 值       # 条件真 → [ 值 ]，否则 [ ]（注意与 lib.optional 的区分）
lib.lists.range 1 3              # [ 1 2 3 ]
lib.lists.unique [ 1 1 2 ]       # [ 1 2 ]
lib.lists.flatten [ 1 [ 2 [ 3 ] ] ]  # [ 1 2 3 ]
lib.lists.remove [ 2 ] [ 1 2 3 ] # [ 1 3 ]
```

> ⚠️ `lib.optional` vs `lib.optionals`：前者「条件 + 单值 → 列表」，后者「条件 + 列表 → 列表」。类型混用是新手高频报错点（第 12 章惯用法章会再强调）。

## 7.7 管道与组合：把「嵌套调用」翻平

嵌套调用 `f (g (h x))` 读起来由内向外、反直觉。✅ 现行推荐 `lib.pipe`：

```nix
lib.pipe input [
  (x: x * 2)                 # 第一步
  (x: x + 1)                 # 第二步
  builtins.toString          # 第三步
]
# 等价 toString (((input * 2) + 1))，但从上到下读
```

真实的 nixpkgs 风格示例——统计一个属性集里各键的字符长度：

```nix
lib.pipe cfg.services [
  builtins.attrNames                          # 取全部服务名 → [ ... ]
  (map (name: { inherit name; len = builtins.stringLength name; }))  # 变成记录列表
  (foldl' (acc: x: acc + x.len) 0)            # 求和
]
```

函数级组合还有 `lib.composeExtensions`、`lib.composeManyExtensions`（overlay 组合，第 39 章）；`lib.flip`、`lib.const`、`lib.id` 见第 12 章。

## 7.8 错误里的函数：throw / abort 是普通值参与的表达式

`throw "消息"` 与 `abort "消息"` 求值为一个**错误值**——由于惰性求值，它躺在没人强制求值的分支里就永远不发作（第 11 章）：

```nix
{ supported ? throw "必须指定 supported" , ... }: ...
```

两者区别：`throw` 可被 `builtins.tryEval` 捕获（表达「可预期的配置错误」），`abort` 不可捕获（表达「致命错误，立刻停止」）。✅ 推荐：写给自己模块的用户看的错误用 `throw`；只在绝不希望被吞掉时用 `abort`。更友好的做法是 `lib.throwIfNot` / `lib.warnIfNot`。

## 7.9 反射：functionArgs

```nix
builtins.functionArgs ({ a, b ? 1 }: a + b)
# { a = false; b = true; }  —— 键是形参名，值是「是否有默认值」
```

这是 Nix 有限的反射能力，也是 `callPackage` 的秘密：求值器并不「扫描」函数体，而是**直接向函数要形参表**（`functionArgs` 对 lambda 形式的函数返回 `{ }`）。`lib.function` 里还有 `setFunctionArgs`、`toFunction` 等围绕它的工具。

## 7.10 本章规范速查（函数部分）

| 写法 | 状态 |
|------|------|
| `stdenv.mkDerivation (finalAttrs: { ... })` | ✅ 现行推荐 |
| `stdenv.mkDerivation rec { ... }` | ⛔ 过时：nixpkgs 已迁移完毕，新代码禁用 |
| 多行参数集 + 尾逗号（`{ lib, stdenv, }:`） | ✅ nixfmt-rfc-style 标准 |
| 单行参数集 | ⚠️ 合法，仅短清单时可读 |
| 顶层 `with pkgs;` 注入再引用 | ⛔ nixpkgs 禁止（可读性与静态分析） |
| 柯里化 `a: b:` | ✅ 库函数标准 |
| `builtins.foldl'`（带撇号） | ✅；`foldl` ⚠️ 惰性版本仅玩具场景 |
| `lib.pipe` | ✅ 替代深层嵌套调用 |
| `builtins.functionArgs` | ✅ 元编程/工具链场景 |

## 7.11 本章小结

- 函数语法是 `参数: 体`，没有名字、只有值；柯里化让「部分应用」成为组织配置的标准手法。
- 模式匹配参数 `{ a, b ? 默认, ... }@args` 是依赖声明：nixpkgs 的 `callPackage` 注入与 `.override` 都以此为本。
- `finalAttrs` 是当前自引用的标准答案：override 后引用自动一致；`rec` 写法⛔过时，遇到旧教程要能认出并迁移。
- `lib.fix` + 惰性求值让自引用成为 nixpkgs/模块系统的数学骨架。
- 高阶函数主力：`map`/`filter`/`foldl'`/`sort`/`genList`；组合用 `lib.pipe`；错误值 `throw`（可捕获）与 `abort`。
- `functionArgs` 是唯一的函数反射能力，`callPackage` 的地基。

## 延伸阅读

- 官方手册函数章节：https://nixos.org/manual/nix/stable/language/constructs
- nix.dev «Functions» 教程：https://nix.dev/tutorials/nix-language
- finalAttrs 迁移讨论与指南：nixpkgs 文档及 `lib.trivial.fix` 源码注释（pkgs/stdenv/generic 或 lib/trivial.nix）
- 第 8 章（作用域与 inherit）、第 12 章（惯用法）承接本章。
