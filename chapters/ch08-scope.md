# 第 8 章 let、with 与作用域规则

> **本章导读**：作用域决定了「一个名字到底指什么」。Nix 只有两种引入名字的机制——函数参数与 `let`/`with`——但它们与惰性求值的组合能产生精妙（也易错）的行为。本章讲清 `let`、`inherit`、`rec`、`with` 的精确规则，并给出与 nixpkgs 现行规范一致的取舍建议：哪些写法 ✅ 常用，哪些 ⛔ 已被社区明确弃用。

## 8.1 词法作用域：名字由「写在哪」决定

Nix 是**词法作用域**（lexical scoping）：一个名字指向什么，由它书写的位置静态决定，与调用者、求值顺序无关。全部绑定机制只有两类：

1. **函数参数**（第 7 章）：模式匹配 `let { a, b }: ...` 中 `a`、`b` 在函数体内可见；
2. **`let ... in`** 与 **`with`**：本章主角。

没有全局变量、没有动态作用域、没有赋值——一个名字一旦绑定，在它的作用域内不可变。这带来一个安心的事实：**读懂一段 Nix 代码不需要执行它**，只需要向上看绑定。

## 8.2 let ... in：受控的局部命名

```nix
let
  version = "2.12.3";                     # 前面的绑定
  url = "mirror://gnu/hello/hello-${version}.tar.gz";   # 可以引用它
  checksum = builtins.hashString "sha256" url;
in
  "打包 ${version}，来源 ${url}"
```

精确规则：

1. `let` 区里可以定义任意多个绑定，每条以分号结尾；
2. **后面的绑定可以引用前面的**（`url` 引用 `version`）；
3. `let` 的绑定**不能引用自身或后面**的绑定——需要自引用时用 `rec` 或 `lib.fix`（第 7 章）；
4. `in` 后的表达式是整个 `let` 表达式的值，绑定在其中可见；
5. `let` 可以嵌套，内层同名绑定**遮蔽**（shadow）外层：
   ```nix
   let x = 1; in let x = 2; in x   # 2 —— 内层赢
   ```

✅ 格式规范（nixfmt-rfc-style）：`let` 与 `in` 各占一行，绑定体缩进，`in` 后的表达式另起一行缩进（见第 6 章 6.12 的示例）。⚠️ 单行 `let x = 1; in x` 合法，仅用于极短场景。

`let` 在真实代码中最常见的三种出场：

```nix
# ① 在属性集前做「预计算」，避免重复表达式
let
  canRun = stdenv.hostPlatform.emulatorAvailable buildPackages;
in
  { postFixup = lib.optionalString canRun "..."; }

# ② 在派生参数内部整理中间逻辑（第 36-38 章实例里大量出现）
# ③ 在函数体里给模式参数「换个短名」或「派生值」
{ cfg }: let inherit (cfg) port host; in "${host}:${toString port}"
```

## 8.3 inherit：三种形态一次讲透

`inherit` 是属性集里的「抄近道」语法，三种形态：

```nix
# ① 从外层作用域取值，名字同键：
let version = "1.0"; in
{ inherit version; }                    # 等价 { version = "1.0"; }

# ② 从某个属性集里取若干字段（最常见！）：
{ inherit (pkgs) hello ripgrep fzf; }   # 等价 { hello = pkgs.hello; ripgrep = pkgs.ripgrep; fzf = pkgs.fzf; }

# ③ 在 let 中使用（极少但合法）：
let inherit (src) owner repo; in "${owner}/${repo}"
```

`inherit (x) a b;` 的本质是 `a = x.a; b = x.b;`。它在 nixpkgs 无处不在的原因：

- 少打字且不重复名字（改名时只改一处）；
- 让「这个字段来自哪个集合」一目了然——正是 `with` 想解决的可读性问题，但**静态可见**。

⚠️ 唯一的坑：`inherit` 抄的是**值**（按惰性求值），不是「引用」——对属性集/派生这类值无所谓（它们本身不可变），但要有「抄即快照」的意识。

对照真实源码（`pkgs/by-name/fz/fzf/package.nix`，2026-08 快照）：

```nix
{
  lib,
  buildGoModule,
  fetchFromGitHub,
  runtimeShell,
  installShellFiles,
  bc,
  ncurses,
  versionCheckHook,
}:              # ← 模式参数本身也是一种「inherit」：从 callPackage 注入的集合里解构
```

## 8.4 rec：带自引用的属性集（回顾与告诫）

第 7 章已从 override 一致性角度批评过 `rec`；从作用域角度看，`rec` 是第三种命名机制——「集合内互相可见」：

```nix
rec {
  a = 1;
  b = a + 1;      # rec 内可以前向、后向引用
  c = b + a;
}
```

⚠️ `rec` 的字段查找发生在**整个集合**上，等于给每个字段都开了一个微型 `with`。代价：

1. 名字冲突静默遮蔽：`rec { x = 1; y = x; }` 里拼错成 `z` 不会报「未定义」，而是去找外层或报错位置诡异；
2. 循环引用错误信息晦涩（`infinite recursion encountered`，定位见第 45 章）；
3. 配合 override 的脱节问题（第 7 章）。

✅ 取舍建议：`rec` 只用于「纯字面量的自引用小集合」（比如一组常量）；涉及派生的自引用一律 `finalAttrs`（第 7 章）；涉及包集合的自引用交给 `lib.fix` / `makeScope`（第 32、39 章）。⛔ nixpkgs 评审对新的 `mkDerivation rec` 写法会直接要求迁移。

## 8.5 with：把属性集注入作用域（能看懂，慎用）

`with 集合; 表达式` 把集合的**所有键**注入表达式的作用域：

```nix
with pkgs; [
  hello           # 即 pkgs.hello
  ripgrep         # 即 pkgs.ripgrep
]

with (import <nixpkgs> { }); stdenv.mkDerivation { ... }   # 老教程开场白
```

### 8.5.1 优先级的精确规则

名字查找的优先顺序（从高到低）：

1. **函数参数**（模式匹配形参）；
2. **更近的 `let` / 内层 `with`**（按嵌套深度）；
3. `with` 注入的名字（多个 `with` 时，**内层**的赢）；
4. 外层作用域。

一句话：**显式绑定永远赢过 `with`；同级看嵌套深度**。

```nix
let hello = "我自己定义的"; in
with pkgs; [ hello ]          # [ "我自己定义的" ] —— let 赢

with { a = 1; }; with { a = 2; }; a    # 2 —— 内层 with 赢
```

### 8.5.2 ⛔ 为什么 nixpkgs 禁用顶层 with

社区明确不推荐（nixpkgs 贡献指南 + `statix` 检查项），理由：

1. **可读性**：`with pkgs;` 之后，读者对任何名字都要猜「是 pkgs 的属性还是别处定义」；
2. **静默语义漂移**：nixpkgs 新增一个与你的局部变量同名的属性时，你的代码含义可能悄然改变；
3. **工具链失明**：静态检查、LSP 对 `with` 的解析既慢又不可靠；
4. **求值成本**：`with` 会强制构建整个注入集合的键集合（对 `pkgs` 这种巨型集合不便宜）。

✅ 现行替代方案对照：

```nix
# ⛔ 过时风格（旧教程常见）：
with pkgs; stdenv.mkDerivation {
  buildInputs = [ glib gtk3 ];
  nativeBuildInputs = [ pkg-config ];
}

# ✅ 现行风格：显式引用（配合 inherit 省字）：
{ lib, stdenv, glib, gtk3, pkg-config }:
stdenv.mkDerivation {
  buildInputs = [ glib gtk3 ];
  nativeBuildInputs = [ pkg-config ];
}
```

⚠️ `with` 并未被语言弃用——在「作用域明确、集合小、临时性」的场景（如示例代码、repl 试算、`lib.genAttrs (attrNames x) (n: with x.${n}; ...)` 这类刻意注入）依然合理。判据：**读者能否不假思索地说出每个名字来自哪里**。

## 8.6 内建函数里的小作用域工具

与名字查找相关的实用内建：

```nix
builtins.getAttr "b" { a = 1; b = 2; }   # 2 —— 「运行时」点号，键可以是变量
builtins.hasAttr "b" { a = 1; b = 2; }   # true —— 即 ? 运算符的函数版
x ? b                                    # true —— 属性存在测试（第 6 章优先级表第 4 级）
builtins.removeAttrs { a = 1; b = 2; } [ "a" ]   # { b = 2; } —— 「反绑定」
builtins.intersectAttrs { a = 1; b = 2; } { b = 3; c = 4; }  # { b = 3; } —— 按键取交集
```

`?` 与 `or` 的组合是防御式访问的标准姿势（第 10 章展开）：

```nix
cfg ? port                 # 配置里有没有 port
cfg.port or 8080           # 没有就给默认
```

## 8.7 综合实战：一段代码的三种作用域写法

需求：给定 `pkgs` 与配置 `cfg`，产出「按需带调试工具」的环境包清单。三种写法对比：

```nix
# ❌ 写法一（旧教程风）：with + 深层嵌套，名字来源不明
let env = with pkgs; [ hello ripgrep ] ++ (if cfg.debug then [ strace ltrace ] else [ ]);
in env

# ⚠️ 写法二：能用的继承，但分支结构笨重
let
  base = [ pkgs.hello pkgs.ripgrep ];
  debug = with pkgs; [ strace ltrace ];     # 小集合、局部作用 → with 尚可
in
  if cfg.debug then base ++ debug else base

# ✅ 写法三（现行 nixpkgs 风格）：lib 工具 + optional，无 with、无 if 链
let
  inherit (pkgs) hello ripgrep strace ltrace;
in
  [ hello ripgrep ] ++ lib.optional cfg.debug strace ++ lib.optional cfg.debug ltrace
  # 更简洁： ++ lib.optionals cfg.debug [ strace ltrace ]
```

三个版本求值结果相同，可维护性依次上升。这段改写浓缩了本章与第 12 章的全部主张：**显式优于隐式、小工具优于分支、来源可见优于省字**。

## 8.8 本章规范速查（作用域部分）

| 写法 | 状态 |
|------|------|
| `let ... in` + `inherit (x) a b;` | ✅ 标准手法 |
| `lib.fix (self: { ... })` 替代大型 `rec` | ✅（第 32 章） |
| `mkDerivation (finalAttrs: { ... })` 自引用 | ✅（第 7 章） |
| `rec` 小型常量集合 | ⚠️ 可接受 |
| `rec` 用于派生定义 | ⛔ 已被 nixpkgs 整体迁移淘汰 |
| 顶层 `with pkgs;` | ⛔ nixpkgs 禁用 |
| 局部、小集合的 `with` | ⚠️ 慎用（判据：名字来源可脱口而出） |
| `attrs ? key` / `attrs.key or 默认` | ✅ 防御式访问标准 |

## 8.9 本章小结

- Nix 只有函数参数与 `let`/`with` 两种绑定机制；词法作用域，读代码向上看绑定即可。
- `let` 后向引用、不可自引用；`inherit (x) a b;` 是「显式的 with」，nixpkgs 的标准省字法。
- `rec` 是集合级自引用：小型常量集合 ⚠️ 可用，派生定义 ⛔ 过时（用 `finalAttrs`）。
- `with` 的查找优先级最低（函数参数 > let > 内层 with > 外层）；顶层 `with pkgs;` 因可读性、静默漂移与工具链成本被社区禁用。
- `?` 与 `or` 组合做防御式访问；`removeAttrs`/`intersectAttrs` 是「反绑定」工具。

## 延伸阅读

- 官方手册 «Constructs / Let / With»：https://nixos.org/manual/nix/stable/language/constructs
- nixpkgs 贡献者指南（风格与禁项）：https://github.com/NixOS/nixpkgs/blob/master/CONTRIBUTING.md
- 第 10 章（属性集深讲）、第 12 章（惯用法总汇）承接本章。
