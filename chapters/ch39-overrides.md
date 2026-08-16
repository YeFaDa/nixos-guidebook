# 第 39 章 override 与 overlay：定制一切

> **本章导读**：官方 nixpkgs 收录了十万多个包，但总有一天你会想「改一点点」——换一个版本、加一个补丁、去掉一个依赖、打开一个编译开关。传统发行版的答案往往是 fork 源码包自己维护；Nix 的答案是在**求值层（evaluation）**改写：不动 nixpkgs 仓库一行代码，用 override（覆盖）家族与 overlay（叠加层）机制得到你想要的包。本章把这套「定制一切」的工具链一次讲透，并给出四个可直接照抄的实战案例。

## 39.1 为什么需要定制：在求值层改写世界

先看几个真实到不能再真实的需求：

- 上游上周刚修了一个崩溃 bug，nixpkgs 里的版本还没跟进——你想给这个包**打一个补丁**。
- 某个工具的新版本引入了你不喜欢的交互改动——你想**降级到旧版本**。
- 服务器上跑的服务只需要 git 的极小子集——你想**关掉一批编译开关**，少编几千个依赖。
- 你自己写了一个包——想把它**注入 pkgs**，让系统里其他配置像引用官方包一样引用它。

在传统发行版里，这些需求分别对应：等官方仓库、找第三方源、手改 spec 文件重新 rpmbuild、自己维护一套 AUR/PPA。每一条路都意味着**脱离官方支持，独自承担一切**。

Nix 的思路完全不同。回顾第 4 章与第 32 章：nixpkgs 本质上是一个巨大的、惰性求值的函数与属性集（attribute set），每个包都是「包函数被求值一次」的结果——一份配方（参见第 34 章的 `mkDerivation`）产出一个派生（derivation，参见第 13 章）。既然包是**函数应用的结果**，那么改输出根本不需要改函数体：

- 换实参，就能改变函数的结果（override 的本质）；
- 在结果上再包一层函数，就能在不碰原定义的情况下叠加修改（overrideAttrs 的本质）；
- 对整个包集合施加一个「后处理函数」，就能批量、组合地改写（overlay 的本质）。

这套机制的全部产出仍然是普通的派生：改了什么，输出哈希就变（参见第 15 章）；去哪找构建结果，仍然走第 16 章的构建流程与第 20 章的二进制缓存（binary cache）。「定制」在 Nix 里不是旁门左道，而是一等公民的日常操作。

| 你的需求 | 传统发行版的做法 | Nix 的做法（本章） |
| --- | --- | --- |
| 换版本 | 找第三方仓库 / 源码自编 | `overrideAttrs` 换 `version` + `src` |
| 打补丁 | 重打源码包 | `overrideAttrs` 追加 `patches` |
| 开关功能 | 手改 spec 重编 | `override { enableXxx = true; }` |
| 换某个依赖 | 几乎不可能干净地做 | `override { openssl = myOpenssl; }` |
| 一批包统一改 | 自建仓库 | overlay：`final: prev: { ... }` |

一句话总结本章的世界观：**nixpkgs 不是一堆二进制包，而是一份可编程的、可无损改写的配方库。**

## 39.2 callPackage 的注入原理：override 的本质

第 32 章介绍过 nixpkgs 的骨架，第 34 章逐行看过 `mkDerivation`，这里把 `callPackage`（调用包）的核心逻辑再收紧一次，因为它是理解 override 的钥匙。

`callPackage` 做的事情，一句话：**自动从包集合里按参数名找实参，再去调用包函数**。示意实现（真实实现见 nixpkgs 的 `lib/customization.nix` 与 `pkgs/stdenv/booter.nix`，以源码为准）：

```nix
# 示意：callPackage 的核心逻辑
callPackage = f: extraArgs:
  let
    # ① 取出 f 声明的形参表。
    #    例如 hello 的 package.nix 第一行是 { lib, stdenv, fetchurl }:
    #    那么 functionArgs 就是 { lib = false; stdenv = false; fetchurl = false; }
    #    (false 表示「没有默认值,必须被提供」)
    fArgs = builtins.functionArgs f;

    # ② 形参名凡是 pkgs 里同名存在的,自动取来当实参——这就是「注入」
    auto = lib.filterAttrs
      (name: _: builtins.hasAttr name pkgs)
      fArgs;
  in
    # ③ 显式传入的 extraArgs 永远压过自动注入——这就是 override 的入口
    f (auto // extraArgs);
```

所以 `callPackage ../by-name/he/hello/package.nix { }` 之所以能工作，是因为 `lib`、`stdenv`、`fetchurl` 这些名字恰好都是 `pkgs` 的属性。想看一个包到底能注入哪些参数，直接打开它的配方即可：

```console
$ nix edit nixpkgs#hello
# 在 $EDITOR 中打开 hello 的 package.nix,第一行就是函数签名
```

接着是第二把钥匙：`callPackage` 在调用前，会先用 `lib.makeOverridable` 把包函数包一层。示意：

```nix
# 示意:lib.makeOverridable 的核心(真实实现见 lib/customization.nix)
makeOverridable = f: origArgs:
  let
    # 第一次调用:用原始参数求值,得到正常结果
    result = f origArgs;
  in
    result // {
      # override:拿「原参数 ++ 新参数」把 f 再调用一次
      # 结果同样可再 override,因此可以链式覆盖
      override = newArgs: makeOverridable f (origArgs // newArgs);
    };
```

现在可以给出本章最重要的一句话：

> **`pkg.override { ... }` 的本质，就是「用不同的实参重新调用这个包函数」。**

override 没有修改任何派生——派生是不可变的（参见第 13 章）——它只是求值出了**另一个**派生。原包和新包并存于 store 中，互不干扰。这也是 override 可以随意组合、随意回退的原因：每一次 override 都是一次纯粹的新求值（呼应第 4 章的纯函数式思想）。

## 39.3 override 家族逐个精讲

### 39.3.1 `pkg.override { ... }`：换函数实参

适用于「参数写在包函数签名里」的一切东西：依赖（`stdenv`、`openssl`……）和作者显式暴露的功能开关。三个可运行示例：

```nix
# 例一:打开 ripgrep 的 PCRE2 环视正则支持
# (ripgrep 的函数签名里有 withPCRE2 ? false —— 第 37 章打包过它)
pkgs.ripgrep.override { withPCRE2 = true; }

# 例二:给 git 加上 git send-email 子命令
# (git 的签名里有一堆 xxxSupport ? false 开关)
pkgs.git.override { sendEmailSupport = true; }

# 例三:换编译器——用 clang 版 stdenv 重新求值整个包
# (依赖注入不只限于开关,任何形参都能换)
pkgs.hello.override { stdenv = pkgs.clangStdenv; }
```

两个容易误解的点：

1. `override` 改的是**函数参数**。`pname`、`version`、`src`、`patches` 这些是交给 `mkDerivation` 的**属性集字段**（第 34 章），对绝大多数包而言不在函数签名里，`override` 碰不到它们。个别包作者会把 `version` 之类的字段提升为函数形参，那时才可以用 `override` 注入——但这属于包作者的约定，不是通用规则。
2. `override` 一次只影响**这一个包的这一次求值**。`pkgs.git.override { ... }` 得到的是一个新的 git 派生，系统里其他依赖 git 的包（比如 `tig`）依然用官方 git。想「全局生效」要用 overlay（39.5 节）。

### 39.3.2 `pkg.overrideAttrs (old: { ... })`：改配方属性集

`overrideAttrs`（覆盖属性）来自 `stdenv.mkDerivation`：它在结果上挂了一个函数，用「原属性集与新属性的合并」**重新调用一次 mkDerivation**。`old` 参数就是本次传给 `mkDerivation` 的那份属性集——也就是你在 package.nix 里写的全部内容（`pname`、`version`、`src`、`buildInputs`、各 phase 覆盖、`meta`……），外加少量 stdenv 规范化注入的字段。

```nix
# 给 hello 追加一个补丁
pkgs.hello.overrideAttrs (old: {
  # old.patches 可能不存在(原包没写补丁),必须用 or [] 兜底
  # 为什么:overrideAttrs 是合并语义,直接写 patches = [ ... ] 会「替换」,
  # 而我们想要「追加」,所以先取出旧的再拼接
  patches = (old.patches or [ ]) ++ [ ./fix-greeting-crash.patch ];

  # 构建期工具同理:在旧的之上加 pkg-config
  nativeBuildInputs = old.nativeBuildInputs ++ [ pkgs.pkg-config ];
})
```

`overrideAttrs` 可以链式调用，后一次的 `old` 能看到前一次的修改：

```nix
pkgs.hello
  .overrideAttrs (old: { patches = (old.patches or [ ]) ++ [ ./a.patch ]; })
  .overrideAttrs (old: { patches = (old.patches or [ ]) ++ [ ./b.patch ]; })
# 最终 patches = [ ./a.patch ./b.patch ] —— 合并语义的好处
```

小心一点：`old.passthru` 里经常有指回派生自身的引用（如 `finalPackage`），在 overrideAttrs 里碰它们可能触发无限递归报错，遇到时优先改用别的字段。

**为什么改 `version` 必须同步换 `src` 与 `hash`**？因为 `mkDerivation` 不会「跟随版本号自动重新取源码」——`src` 是独立字段，`version` 只是拼进派生名的一个字符串。如果你只改 `version`，得到的是一个「名字叫 2.43.0、内容还是 2.40.0 源码」的假货。正确姿势是三者联动：

```nix
final: prev: rec {
  git-old = prev.git.overrideAttrs (old: {
    version = "2.43.0";                  # ① 改版本号
    src = prev.fetchFromGitHub {         # ② 必须同步换源码
      owner = "git";
      repo = "git";
      rev = "v${version}";               #    tag 与版本号一一对应
      hash = "sha0000000000000000000000000000000000000000000000000000000000000000";
      #    ^ ③ 哈希必须同步换:固定输出派生靠哈希校验(第 15 章)
    };
    # 注意:rec 把 version 引入作用域,rev = "v${version}" 才能取到新版本
  });
}
```

其中 ③ 的哈希值不是手算的，标准做法是「先放假哈希，让 Nix 告诉你真哈希」：

```console
$ nix build .#gitOld
error: hash mismatch in fixed-output derivation '/nix/store/...-git-2.43.0.tar.gz.drv':
        specified: sha0000000000000000000000000000000000000000000000000000000000000000
        got:      sha256-BCvfkXjZ0M8yZ3FxnD0uVfTnCc0zqfDTtPqWk3iCNZ8=
# 把 got: 的值回填进 hash 字段,重新构建即可
```

也可以用 `nix-prefetch-git`、`nix store prefetch-file` 等工具提前获取，原理相同。

### 39.3.3 `overrideDerivation`：已弃用的老 API

`lib.overrideDerivation drv f` 是 overrideAttrs 出现之前的老接口，如今官方文档已将其标记为不推荐（deprecated）。它和 `overrideAttrs` 的区别值得讲清楚，因为老博客里到处是它：

```nix
# 老 API:在「最终派生」层面打补丁
# 这里的 old 是 mkDerivation 加工完的底层派生属性集(builder、args、env 系列……)
lib.overrideDerivation pkgs.hello (old: {
  # 改这里的字段不会重新走 mkDerivation 的加工逻辑,
  # 因此改 buildInputs 之类往往不生效——依赖早已被展开成 env 变量
  NIX_CFLAGS_COMPILE = "-O0";
})
```

| 想改的东西 | 应该用的 API | 原因 |
| --- | --- | --- |
| 函数实参（依赖、开关） | `.override { ... }` | 重新调用包函数，干净彻底 |
| 配方字段（version/src/patches/…） | `.overrideAttrs (old: ...)` | 重新走一遍 mkDerivation 加工 |
| 底层派生字段 | ~~`overrideDerivation`~~ | 已弃用，迁移到上面两者 |

一句话记住区别：`overrideAttrs` 改的是**配方**，`overrideDerivation` 改的是**做好的菜**。改做好的菜容易把调料咬碎（丢 meta、丢 env 加工），改配方则始终由 mkDerivation 兜底。具体弃用状态以 `lib/customization.nix` 的注释为准。

## 39.4 makeScope 与 overrideScope'：语言生态的作用域

`python3Packages`、`haskellPackages`、`nodePackages` 这些「语言包集合」不是简单的大属性集，而是**作用域（scope）**：作用域内的包互相依赖时，优先从作用域内解析依赖，而不是全局 `pkgs`——否则 Python 包会链接到系统级的 OpenSSL，而 C 扩展却可能拿到另一份。这些作用域由 `lib.makeScope` 制造：

```nix
# 示意:一个语言作用域如何被创造
lib.makeScope pkgs.newScope (self: {
  # self.callPackage:先查 self(本作用域),查不到再去外层 pkgs
  # 为什么:让 python 包优先用 python 世界里的依赖版本
  requests = self.callPackage ./requests.nix { };
  flask = self.callPackage ./flask.nix { };  # flask 依赖 requests 时拿到的是上面那份
})
```

想在作用域层面整体替换某个依赖，用 `overrideScope'`（作用域覆盖）：

```nix
# 把 Python 作用域里的 requests 换成打了补丁的版本
# self: 替换后的作用域(其他包引用 requests 时,自动拿到新版本)
# super: 原作用域(拿旧版本做基底)
pkgs.python3Packages.overrideScope' (self: super: {
  requests = super.requests.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./requests-proxy.patch ];
  });
})
```

注意上面得到的是一个**新的作用域对象**，直接 `python3Packages.overrideScope'` 并不会改变系统里已经在用的 `python3`。想让某个解释器及其全部使用者都生效，官方推荐的做法是覆盖**解释器**的 `packageOverrides` 参数：

```nix
# overlay:全局替换 Python 世界里的某个库(完整示例)
final: prev: {
  python3 = prev.python3.override {
    # packageOverrides 是 python 包函数的标准形参:
    # 传一个 self/super 函数,重写它内部包集合的构造
    packageOverrides = pythonSelf: pythonSuper: {
      cryptography = pythonSuper.cryptography.overrideAttrs (old: rec {
        version = "42.0.8";   # 目标版本(示例)
        src = prev.fetchurl {
          url = "https://files.pythonhosted.org/packages/source/c/cryptography/cryptography-${version}.tar.gz";
          hash = "sha256-0000000000000000000000000000000000000000000000000000";
          # 哈希以预取结果为准,不要照抄占位值
        };
        # cryptography 含 Rust 扩展,换 src 后必须同步换 cargo 依赖的哈希
        cargoDeps = prev.rustPlatform.fetchCargoTarball {
          inherit src;
          hash = "sha256-0000000000000000000000000000000000000000000000000000";
        };
      });
    };
  };
}
```

为什么不能直接覆盖 `python3Packages.requests`？因为 `python3Packages` 只是 `python3.pkgs` 的一份视图：别的包通过 `python3.withPackages (ps: [ ps.foo ])` 拿到的是**解释器自带**的包集合，你在视图上做的修改它们看不见。覆盖 `python3` 本体，才能让所有下游共享同一份修改。这是 nixpkgs 手册 Python 章节明确强调的坑。

Haskell 世界同理。`haskellPackages.overrideScope'` 换某个库的版本；`overrideCabal`（覆盖 Cabal 标志）微调单个包的打包行为：

```nix
# haskellPackages 绑定特定 GHC:haskell.packages.ghc9101 之类,版本号以 nixpkgs 为准
pkgs.haskellPackages.overrideScope' (self: super: {
  # 给 aeson 打开 jailbreak(放宽依赖上界,常用于绕过老版本的版本约束)
  aeson = pkgs.haskell.lib.overrideCabal super.aeson { jailbreak = true; };
})
```

## 39.5 overlays 深度：final、prev 与组合方式

单点修改用 override，成体系、可组合、可共享的修改用 **overlay（叠加层）**。一个 overlay 就是一个函数：

```nix
# overlays/default.nix —— 最简 overlay
final: prev: {
  # final: 全部叠加完成后的「最终」包集合(见下文)
  # prev: 本层叠加「之前」的包集合
  hello = prev.hello.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./hello-greeting.patch ];
  });
}
```

**两个参数的精确语义**，这是 overlay 全部复杂性的来源，值得逐字读：

- `prev`（有些文档叫 `super`）：本层执行前已经就位的包集合——基础 nixpkgs 加上排在它前面的所有 overlay 的结果。它是「旧世界」，适合作为改写的**基底**。
- `final`（有些文档叫 `self`）：所有 overlay 全部应用完毕后的最终包集合。由于惰性求值，无论你在哪一层、哪一次引用 `final.hello`，取到的都是「尘埃落定」后的那个 hello——包括你自己这一层和后面所有层的修改。它是「新世界」，适合作为依赖解析的**出口**。

由此得出五条决策规则（建议背下来）：

1. **改旧包** → `prev.hello.overrideAttrs (...)`：以旧版本为基底，叠加修改。
2. **造新包** → `final.callPackage ./myapp { }`：让新包的依赖来自最终集合——别的 overlay 替换过的依赖它也能享受到。
3. **引用可能已被替换的依赖** → `final.openssl`。
4. **需要叠加前的原始版做基底或对比** → `prev.openssl`。
5. **同一层里改写同名属性，一律走 `prev.x`**：写 `final.hello = final.hello.override ...` 是无限递归（final.hello 正是你在定义的东西），必报 `infinite recursion encountered`。

组合方式一：**NixOS 配置**。`nixpkgs.overlays`（叠加层列表）作用于本次求值出的整个 `pkgs`——`environment.systemPackages`、其他模块引用的包，全部经过叠加：

```nix
# configuration.nix
{ ... }:
{
  # 列表从左到右依次应用,后层覆盖先层的同名属性
  nixpkgs.overlays = [
    (import ./overlays/hello-patched.nix)   # 第一层:改 hello
    (import ./overlays/add-myapp.nix)       # 第二层:加 myapp(其中可引用 final.hello)
  ];
  nixpkgs.config.allowUnfree = true;        # config 与 overlays 是同级的两个入口

  environment.systemPackages = with pkgs; [
    hello    # <- 已经是打过补丁的版本
  ];
}
```

组合方式二：**直接实例化 nixpkgs**。`import <nixpkgs>` 接受的参数里，overlays 与 config 并列：

```nix
let
  pkgs = import <nixpkgs> {
    overlays = [ (import ./overlays/default.nix) ];
    config = {
      allowUnfree = true;          # 允许非自由许可的包(如部分固件、IDE)
      permittedInsecurePackages = [ "openssl-3.0.13" ];  # 明示放行的「已知不安全」包
    };
  };
in
pkgs.hello   # 已叠加
```

顺带一提渠道时代的全局约定：`~/.config/nixpkgs/overlays/*.nix` 下的文件会被 `import <nixpkgs>` 自动按文件名顺序加载，无需显式列举。

组合方式三：**flake 输出**。在你的 flake 里声明 `overlays` 输出（参见第 21 章）：

```nix
# flake.nix —— overlay 的生产方
{
  description = "我的 nixpkgs 叠加层";
  outputs = { self }: {
    overlays.default = final: prev: {
      myapp = final.callPackage ./pkgs/myapp { };
    };
    # 也可以按名暴露多个:
    overlays.add-myapp = final: prev: {
      myapp = final.callPackage ./pkgs/myapp { };
    };
  };
}
```

消费方在自己的 `nixosSystem` 模块里注入（flake 的输入体系本身不吃 overlays 参数，注入点在模块层）：

```nix
# 消费方 flake.nix(节选)
{
  inputs.my-overlay.url = "github:you/nix-overlays";
  outputs = { self, nixpkgs, my-overlay }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        {
          # 只影响这台机器求值出的 pkgs
          nixpkgs.overlays = [ my-overlay.overlays.default ];
        }
        ./configuration.nix
      ];
    };
  };
}
```

**多个 overlay 的叠加语义**再强调一遍：列表从左到右折叠，后层对同名属性的赋值胜出；每一层看到的 `prev` 不同（逐层递进），但所有层看到的 `final` 是同一个（惰性定稿值）。所以「后写的赢」与「final 全层一致」并不矛盾——前者说的是属性赋值顺序，后者说的是依赖解析出口。

## 39.6 实战四例

以下四例都是完整可用的代码，目录布局如下（本章工程示例，非 nixpkgs 仓库内）：

```
my-nix-config/
├── flake.nix
├── overlays/
│   ├── hello-patched.nix
│   ├── git-old.nix
│   ├── add-myapp.nix
│   └── openssl-custom.nix
├── patches/
│   └── hello-greeting.patch
└── pkgs/
    └── myapp/
        └── package.nix
```

### 实战一：给 hello 打补丁

补丁文件（标准 unified diff，改动默认问候语）：

```diff
--- a/src/hello.c
+++ b/src/hello.c
@@ -100,7 +100,7 @@
   /* Print greeting message and exit.  */
-  puts (_("Hello, world!"));
+  puts (_("Hello, Nix!"));
```

overlay：

```nix
# overlays/hello-patched.nix
final: prev: {
  hello = prev.hello.overrideAttrs (old: {
    # 追加而非替换,保持与未来版本改动的兼容性
    patches = (old.patches or [ ]) ++ [
      ./hello-greeting.patch   # 相对路径基于本文件所在目录
    ];
  });
}
```

单测一下（渠道语法与 flake 语法各一）：

```console
$ nix-build -E 'import <nixpkgs> { overlays = [ (import ./overlays/hello-patched.nix) ]; }' -A hello
$ nix build --impure --expr 'let pkgs = import <nixpkgs> { overlays = [ (import ./overlays/hello-patched.nix) ]; }; in pkgs.hello'
$ ./result/bin/hello
Hello, Nix!
```

### 实战二：把 git 降级到旧版本

39.3.2 节的完整落地。核心是「version → rev → hash」三联动，外加一个实战细节：新版 git 的 `doInstallCheck` 会校验版本一致性，降级后如果自检失败，可以临时关掉：

```nix
# overlays/git-old.nix
final: prev: rec {
  git-old = prev.git.overrideAttrs (old: rec {
    pname = "git";               # rec 让 version/rev/src 互相可见
    version = "2.43.0";

    src = prev.fetchFromGitHub {
      owner = "git";
      repo = "git";
      rev = "v${version}";       # 官方 release tag 与版本号严格对应
      hash = "sha256-0000000000000000000000000000000000000000000000000000";
      # 占位哈希:构建一次,把报错中的 got: 值回填(见 39.3.2)
    };

    # 降级后 installCheck 的版本断言可能失败,临时关闭
    # 为什么可以放心关:它只是「装完跑一下 --version」的自检,不影响功能
    doInstallCheck = false;
  });
}
```

```console
$ nix build --impure --expr 'let pkgs = import <nixpkgs> { overlays = [ (import ./overlays/git-old.nix) ]; }; in pkgs.git-old'
$ ./result/bin/git --version
git version 2.43.0
```

### 实战三：用 overlay 引入自己的包，并让系统包用它

先写包（遵循 RFC 140 的 by-name 目录约定，参见第 32 章；这里是自有 flake 中的包，路径可自定）：

```nix
# pkgs/myapp/package.nix —— 一个 Rust 写的小服务
{ lib, rustPlatform }:
rustPlatform.buildRustPackage {
  pname = "myapp";
  version = "0.1.0";

  src = ./.;    # 就在本目录,flake 源直接可用

  cargoHash = "sha256-0000000000000000000000000000000000000000000000000000";
  # cargo 依赖树的固定输出哈希,同样用「假哈希回填法」获取

  meta = {
    description = "示例 Web 应用";
    mainProgram = "myapp";
    platforms = lib.platforms.linux;
  };
}
```

再写 overlay，用 `final.callPackage` 注入——这就是 callPackage 自动注入原理（39.2 节）的实战回响：将来 package.nix 需要新依赖时，只要形参名能在 `final` 里找到，**两边的代码都不用改**：

```nix
# overlays/add-myapp.nix
final: prev: {
  # 用 final:依赖解析出口指向最终集合,自动享受其他 overlay 的替换
  myapp = final.callPackage ../pkgs/myapp { };
}
```

接入 NixOS：

```nix
# configuration.nix
{ ... }:
{
  nixpkgs.overlays = [ (import ./overlays/add-myapp.nix) ];
  environment.systemPackages = with pkgs; [ myapp ];
}
```

### 实战四：全局替换 openssl——能做，但要先算账

设想你需要一个开启了特定合规开关的 openssl，想让全系统都用它：

```nix
# overlays/openssl-custom.nix
final: prev: {
  openssl = prev.openssl.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./openssl-compliance.patch ];
  });
}
```

把它挂进 `nixpkgs.overlays` 后，得益于 overlay 的全局语义，所有通过 callPackage 依赖 openssl 的包（curl、python、nginx、git……）都会重新求值并**链接到你的 openssl**。这正是 overlay 的威力，也正是它的危险：

- **重建规模**：openssl 处在半个发行版的依赖闭包里（第 17 章）。全局替换意味着这些包在你的机器上全部缓存未命中、需要本地重编（详见 39.7 第一坑）——普通桌面机可能要编几千个包。
- **安全责任转移**：从此你不再跟随官方的安全更新节奏。官方升 openssl 补丁时，你的 overlay 补丁可能冲突或被悄悄绕过，风险与维护责任由你承担。
- **行为兼容**：合规开关可能改变 API 行为或 ABI，极端情况下导致依赖它的程序出现难以排查的运行时问题。

更克制的做法是**局部替换**——只给真正需要它的那个应用换：

```nix
# 只给 curl 换定制 openssl,系统其余部分不受影响
environment.systemPackages = [
  (pkgs.curl.override {
    openssl = pkgs.openssl.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [ ./openssl-compliance.patch ];
    });
  })
];
```

判断标准很简单：如果替换动机是「某个应用需要」，就局部做；只有「整套系统都需要」（如全系统 FIPS 合规）才动用全局 overlay，并确保自己有能力长期维护。

## 39.7 常见坑

**坑一：override 之后缓存未命中——这是特性，不是 bug。**

```console
$ nix build .#helloPatched
this derivation will be built:
  /nix/store/…-hello-2.12.1.drv
# 为什么没有从 cache.nixos.org 下载?
```

因为你改了输入（补丁），输出哈希随之改变（第 15 章），得到的是一条 Hydra 从未构建过的新派生。二进制缓存按哈希精确命中（第 20 章），它不可能「差不多就行」。所以动手前先掂量：小改动通常只需本地重编目标包本身；全局替换大依赖则是另一回事（39.6 实战四）。

**坑二：多个 overlay 的叠加语义。**

```nix
nixpkgs.overlays = [ overlayA overlayB ];
# overlayA 里: prev = 基础 nixpkgs
# overlayB 里: prev = A 应用后的集合;同名属性以 B 为准(后写的赢)
# 两个 overlay 里的 final 是同一个 —— 最终定稿值
```

一个容易栽跟头的场景：A 替换了 openssl，B 里新造的包想引用「替换后的 openssl」。写 `prev.openssl` 会拿到 A 替换前的版本（对 B 而言 prev 里其实已含 A……注意：对 B 来说 prev 已经包含 A 的修改，所以 prev.openssl 也是新的）。真正会出错的方向是：B 里的包用 `import <nixpkgs> {}` 另起炉灶，那才是拿回了旧世界（见坑四）。记住出口统一走 `final`，就不会错。

**坑三：循环引用自己。**

```nix
# 错误:final.hello 正是下面这个正在定义的 hello —— 无限递归
final: prev: {
  hello = final.hello.overrideAttrs (_: { });
}

# 正确:以「旧 hello」为基底
final: prev: {
  hello = prev.hello.overrideAttrs (_: { });
}
```

同族问题也出现在 overrideAttrs 里：对同一属性做依赖自身的运算（`x = old.x ++ [ x ]`），或翻动 `old.passthru` 上指回自身的引用，都会报 `infinite recursion encountered`。另注意 39.3.2 提过的「追加型」overrideAttrs 若被机械地重复套用，补丁会重复叠加。

**坑四：在 overlay 里另起 `import <nixpkgs>`——重算爆炸。**

```nix
# 反例:每个定义点都重新实例化 nixpkgs
final: prev: {
  # 错在:这是一次全新的求值,不带任何 overlay 与 config,
  # 与外层集合是两个平行世界
  myapp = (import <nixpkgs> { }).callPackage ../pkgs/myapp { };
}
```

后果：同一台机器上存在多个参数不同的 nixpkgs 实例，同一个包在不同实例里求值出不同的 store 路径——缓存命中崩塌、闭包膨胀、求值时间成倍上涨，这就是俗称的「重算爆炸」。规则只有一条：**overlay 内部只用 `final`/`prev`，永远不要 import nixpkgs；NixOS 模块内只用 `pkgs` 形参；整个系统只在顶层实例化一次。**

## 39.8 本章小结

- 定制 nixpkgs 的全部秘密在于：包是「包函数求值一次」的结果，改输出只需换实参或包一层，不必改仓库源码。
- `callPackage f args = f (自动注入的实参 // args)`；`override` 的本质是用不同实参重新调用包函数。
- `pkg.override { ... }` 改函数参数（依赖与功能开关）；`pkg.overrideAttrs (old: ...)` 改交给 `mkDerivation` 的配方字段，`old` 即原属性集。
- 在 `overrideAttrs` 里改 `version` 必须同步换 `src` 与 `hash`：版本、tag、哈希三者联动，假哈希回填法是标准取哈希姿势。
- `overrideDerivation` 已弃用：它改「最终派生」而非「配方」，迁移到 override / overrideAttrs。
- 语言生态是 `makeScope` 造的作用域；全局改 Python 包要覆盖解释器的 `packageOverrides`，直接改 `python3Packages` 视图不会传播；Haskell 用 `overrideScope'` 与 `overrideCabal`。
- overlay 是 `final: prev: { ... }`：改旧包用 `prev` 做基底，解析依赖出口用 `final`，同层改写写 `prev.x` 否则无限递归。
- 多 overlay 从左到右叠加，后层胜出，但所有层的 `final` 是同一个；在 NixOS 用 `nixpkgs.overlays`，flake 用 `overlays.default` 输出并在消费方模块注入。
- 全局替换基础库（如 openssl）威力大、代价也大：重建规模、安全责任、兼容风险三者都要先算账，能用局部 override 解决就别动全局。

## 延伸阅读

- nixpkgs 手册·自定义包（override 与 overrideAttrs）：https://nixos.org/manual/nixpkgs/unstable/#sec-customising-packages
- nixpkgs 手册·Overlays 一章：https://nixos.org/manual/nixpkgs/unstable/#chap-overlays
- nixpkgs 手册·Python 一节（packageOverrides 语义）：https://nixos.org/manual/nixpkgs/unstable/#sec-language-python
- nixpkgs 源码·override 家族实现：https://github.com/NixOS/nixpkgs/blob/master/lib/customization.nix
- NixOS Wiki·Overriding：https://wiki.nixos.org/wiki/Overriding
