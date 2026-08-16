# 第 12 章 惯用法：写出地道的 Nix 代码

> **本章导读**：语法都会之后，写出「像 nixpkgs 的代码」还需要一层风格共识：命名与包表达式的标准头部（finalAttrs）、lib 的常用组合拳、错误处理的正确工具，以及一份可对照检查的反模式清单。本章还介绍 nixfmt / deadnix / statix 组成的静态检查生态，最后用一次完整的重构实战把所有惯用法串起来——那段「祖传代码」的每一个毛病，你在自己的配置与包里大概率都见过。

## 12.1 「地道」的含义

Nix 没有官方风格警察，但 nixpkgs 一万多名贡献者、数万个 `.nix` 文件的长年协作，沉淀出了一套事实标准（de facto standard）。所谓「地道」（idiomatic），含义是具体的：

- **可评审**：评审者扫一眼就知道数据从哪来、哪些值会被求值、哪里可能被 override；
- **可检索**：命名统一后，全仓库搜索能直接找到同类做法，借鉴与复制都有据可依；
- **抗改动**：override、overlay、模块合并这些 Nix 特有的变换发生时，代码不会悄悄坏掉。

反过来说，不地道的代码不只是「被评审打回」的问题——它往往真的会在 override 或重构时坏掉。本章每条惯例都尽量给出坏例与好例的对照，而不是空谈风格；这些坏例并非虚构，它们在真实的_issue 与配置仓库里反复出现。

## 12.2 命名与结构

### 12.2.1 命名：camelCase 与常见角色名

标识符用 camelCase（驼峰式）：`mkDerivation`、`buildInputs`、`optionalString`。连字符或下划线只出现在「承载外部世界标识」的场合：包名（`hello-2.12.1`）、store 路径片段，以及跟随外部拼写的配置键。

更有效率的是记住社区约定俗成的**角色名**，它们是全社区的「黑话」，取名时直接复用：

| 名字 | 角色 |
|---|---|
| `pkgs` | 包集合（第 32 章） |
| `lib` | 函数库 |
| `cfg` | 模块内 config 的局部别名（第 25 章） |
| `config` / `options` | 模块系统两大主角（第 25 章） |
| `final` / `prev` | overlay 的两个参数（第 39 章） |
| `finalAttrs` | 包表达式里「自身最终属性集」（见下） |

### 12.2.2 包表达式标准头部：finalAttrs

一个现代包表达式的完整骨架：

```nix
# pkgs/by-name/he/hello/package.nix（示意，简化自 nixpkgs 真实写法）
{ lib, stdenv, fetchurl }:

# mkDerivation 的参数从「集合」升级为「函数」：
# 接收自身最终属性集，命名为 finalAttrs
stdenv.mkDerivation (finalAttrs: {
  pname = "hello";                 # 包名——进入 store 路径与 meta
  version = "2.12.1";

  src = fetchurl {
    # 引用 finalAttrs.version：读「最终」版本，而非定义时的旧值
    url = "mirror://gnu/hello/hello-${finalAttrs.version}.tar.gz";
    hash = "sha256-0000000000000000000000000000000000000000000000000000";
  };

  meta = {
    mainProgram = "hello";         # 告诉 lib.getExe 该找哪个二进制（12.3 节）
    platforms = lib.platforms.all;
  };
})
```

旧式写法用 `rec` 让集合内部互相引用（第 11 章讲过 rec 即 fix 的语法糖）：

```nix
# 旧式：仍大量存在于历史代码，新代码不推荐
{ lib, stdenv, fetchurl }:
stdenv.mkDerivation rec {
  pname = "hello";
  version = "2.12.1";
  src = fetchurl {
    url = "mirror://gnu/hello/hello-${version}.tar.gz";   # rec 引用
    hash = "sha256-0000000000000000000000000000000000000000000000000000";
  };
}
```

两者的差别在 override 时暴露（第 39 章）。假设想临时打一个 2.12.90 的测试包：

```nix
hello.overrideAttrs (old: { version = "2.12.90"; })
```

- 旧式：`src` 里的 `${version}` 绑定的是 rec 集合的**旧字据**——url 仍指向 2.12.1，哈希对不上，构建以离奇的方式失败；
- finalAttrs：整个属性集函数被重新应用到新值上，`finalAttrs.version` 读到 2.12.90，url 与所有自引用一致更新。

这就是 finalAttrs 的存在理由：**自引用指向 override 之后的最终结果**。第 11 章的 fix 知识在这里直接兑现。

### 12.2.3 目录约定：by-name

新包统一放在 `pkgs/by-name/<两位分片>/<包名>/package.nix`，分片取包名前两个字符：

```text
pkgs/by-name/he/hello/package.nix
pkgs/by-name/cu/curl/package.nix
```

这个布局让「包名 → 文件路径」可以机器推导，评审机器人、重构工具与统计脚本都依赖它；传统的 `pkgs/top-level/all-packages.nix` 手工登记不再是新包的必经之路。细节以 nixpkgs 手册与 by-name 目录下的 README 为准（第 32 章讲全景时再回到这里）。

## 12.3 常用组合拳

### 12.3.1 optional / optionals / optionalString：三分天下

```nix
lib.optional cond x          # 真 → [ x ]；假 → [ ]    —— 单元素版
lib.optionals cond xs        # 真 → xs；  假 → [ ]     —— 列表版（注意词尾的 s）
lib.optionalString cond s    # 真 → s；   假 → ""      —— 字符串版（第 9 章）
```

记法：单数装**一个**元素，复数装**整个列表**；字符串用第三个。三者把「条件」从 if 表达式降格成一个普通函数参数，于是可以内联进任何拼接处。phases（构建阶段，第 16、34 章）里的典型用法：

```nix
nativeBuildInputs = [
  # 调试构建才需要 gdb：列表条件追加
] ++ lib.optionals withDebug [ gdb ];

configureFlags = [
  "--enable-foo"
  # 单个开关条件追加：optional 产列表，直接拼进 flags
] ++ lib.optional withBar "--enable-bar";

installPhase = ''
  runHook preInstall
  # 脚本里的条件片段用 optionalString 拼接（第 9 章）
  ${lib.optionalString stdenv.isDarwin ''
    install_name_tool -id $out/lib/libfoo.dylib $out/lib/libfoo.dylib
  ''}
  runHook postInstall
'';
```

顺带认识 `lib.lists.singleton x`（等价 `[ x ]`）：在「接口统一收列表」的函数里，它是把单个元素抬升成列表的最短写法。

### 12.3.2 lib.getExe / getExe'：别再手写 /bin

```nix
lib.getExe pkgs.hello                      # "/nix/store/…-hello/bin/hello"
lib.getExe' pkgs.git "git-upload-pack"     # 指定 bin/ 下的确切文件名
```

`getExe` 读取 `meta.mainProgram`（缺省回退 pname），替你拼好 `/nix/store/…/bin/…`。手写 `"${pkgs.hello}/bin/hello"` 的问题不只是啰嗦：包改名、二进制改名时它不会跟着变，坏在运行时；而 getExe 在找不到 mainProgram 时会明确报错，逼你把信息写对——12.2 骨架里的 `mainProgram = "hello";` 正是为此。

### 12.3.3 lib.makeBinPath：拼一个 PATH

```nix
lib.makeBinPath [ pkgs.coreutils pkgs.jq ]
# "/nix/store/…-coreutils/bin:/nix/store/…-jq/bin"
```

生成包装脚本（wrapper）时用它构造 PATH：比手写 `${pkg}/bin:` 链条可读，而且经由每个包的 bin 输出取路径（多输出 derivation 参见第 13 章）。同族还有 `makeLibraryPath`、`makeSearchPath` 等。12.7 的重构实战会把 getExe 与 makeBinPath 一起用上。

## 12.4 错误处理

### 12.4.1 throw 与 abort：一字之差，天壤之别

```nix
throw "hello 不支持平台 ${stdenv.hostPlatform.system}"   # 用户可修的错误
abort "内部一致性被破坏：这不该发生，请上报 bug"          # 不可挽回的错误
```

两者都终止求值，区别在**可捕获性**：`throw` 是普通错误，`builtins.tryEval` 能接住；`abort` 不可捕获——按官方手册的表述，tryEval 只捕获 throw 与 assert 产生的错误，abort 与内建函数的类型错误都会穿透。选择标准：

- 错误**用户可修**（平台不符、参数冲突、版本太旧）→ `throw`，给上层降级的机会；
- 错误意味着**代码本身有 bug** → `abort`，防止它被 tryEval 静默吞掉、把问题拖到更深处。

### 12.4.2 assert：把契约写在求值里

```nix
# assert 是表达式而非语句，形式为「assert 布尔; 结果表达式」
{ lib, stdenv, openssl }:
assert lib.versionAtLeast openssl.version "3.0";     # 版本契约：太旧立即失败
stdenv.mkDerivation (finalAttrs: { /* … */ })
```

断言失败即终止（与 throw 同类，可被 tryEval 捕获），且求值器会指出断言所在行。nixpkgs 里的高频形态还有平台契约：

```nix
# 依赖的工具链必须能在目标平台运行——
# availableOn 检查对方 meta 的 platforms 与 badPlatform（第 32 章）
assert lib.meta.availableOn stdenv.hostPlatform stdenv.cc;
```

把契约写成 assert 的收益是「错就错在源头」：比起让不满足契约的构建跑到一半再莫名失败，一处断言省下的是整个排错过程。

### 12.4.3 builtins.tryEval：接住可接的

```console
nix-repl> builtins.tryEval (throw "可救")
{ value = false; success = false; }
nix-repl> builtins.tryEval (abort "不可救")
error: 不可救
```

成功时返回 `{ value = 结果; success = true; }`。两个必须记住的边界：

- **浅捕获**：tryEval 只保护到 WHNF（第 11 章）——结果集合里藏着的 throw 不会触发失败，除非你显式深度求值后再装进去；
- **接不住 abort**（如上）与内建函数的类型错误。

它的正当用途是「逐个试探、坏的跳过」：遍历巨大包集合时过滤掉当前平台不可用或本身有错的条目。如果发现自己在业务逻辑里用 tryEval 接自己刚 throw 的错误，多半是把本该 assert 的契约写错了地方。

### 12.4.4 lib.warn：不致命的问题

```nix
lib.warn "my-package：enableFoo 已废弃，请改用 enableBar" value
```

打印警告到 stderr 并原样返回 `value`——把「现在还能用、将来会移除」的过渡信息留给用户，比 throw 温和、比注释有效。它继承第 11 章的惰性：只有 value 被强制时警告才会打印。

## 12.5 反模式清单

以下七条按「出现频率 × 危害」排序，每条给坏例与好例。多数在前文已有铺垫，这里是集中对照。

### 反模式 1：顶层 with pkgs

```nix
# 坏：整份文件处于动态作用域之下
with import <nixpkgs> { };
stdenv.mkDerivation { /* … */ }
```

问题：任何绑定都可能被 pkgs 的上万个属性遮蔽——你后来定义的 `name`、`description` 若与 pkgs 撞名，错误信息极其迷惑；静态工具（deadnix、statix、语言服务器）对 with 下的名字几乎无法分析。好例就是 12.2 的标准头部：文件是函数，依赖写进参数，`callPackage` 负责注入（第 32 章）。

### 反模式 2：深层嵌套 with

```nix
# 坏：with 套 with——concatStringsSep 来自哪里？读者与工具一起迷路
with lib; with pkgs; {
  text = concatStringsSep "," (map (p: getExe p) [ curl jq ]);
}
```

```nix
# 好：显式引用，每个名字都有出处
{
  text = lib.concatStringsSep "," (map lib.getExe [ pkgs.curl pkgs.jq ]);
}
```

with 的语义与代价在第 8 章讲过：它让名字来源不可静态判定。一层、局部、无歧义时勉强可接受；嵌套即禁（第 8 章还讲了动态与词法作用域的差异，这是根因）。

### 反模式 3：rec 引用会被 override 破坏的字段

见 12.2.2 的对照实验：rec 的自引用在 overrideAttrs 后指向旧值。凡是会被 override 的包表达式，内部自引用一律走 finalAttrs。这也解释了为什么「还能跑」的老代码里 rec 遍地都是——不是 rec 正确，是还没被 override 过。

### 反模式 4：字符串拼 shell 不转义

```nix
# 坏：userInput 含分号或反引号时，就是命令注入
buildCommand = ''
  echo ${userInput} > $out/notice.txt
'';
```

```nix
# 好：先转义再插值；更好的做法见第 9 章——writeText、环境变量传值
buildCommand = ''
  printf '%s\n' ${lib.escapeShellArg userInput} > $out/notice.txt
'';
```

第 9 章 9.3 节有完整讨论：转义是底线，绕开 shell 才是上策。

### 反模式 5：重复手写 "/bin/xxx"

```nix
# 坏：五处手拼路径，包改名、换输出时全部悄悄失效
env.PATH = "${pkgs.curl}/bin:${pkgs.jq}/bin";
ExecStart = "${pkgs.hello}/bin/hello --run";
```

```nix
# 好：意图集中，路径由 lib 负责拼
env.PATH = lib.makeBinPath [ pkgs.curl pkgs.jq ];
ExecStart = "${lib.getExe pkgs.hello} --run";
```

配套习惯：给自己的包写 `meta.mainProgram`（12.2 骨架），getExe 才能工作。

### 反模式 6：把整个 pkgs 塞进构建

```nix
# 坏：为了「让脚本什么都能调用」，把整个包集合强转成文本塞进环境
preBuild = ''
  export ALL_PATHS=${toString (lib.attrValues pkgs)}
'';
```

后果有三层：求值层强制整个 pkgs（第 11 章的全量强求）；构建层把十万个 store 路径塞进环境变量；依赖层让这个包「依赖一切」，任何包变动都可能让它重建。正确姿势永远是：只声明真正用到的依赖（buildInputs / nativeBuildInputs），脚本内用绝对路径或 makeBinPath。

### 反模式 7：生成代码不留入口

nixpkgs 与大型配置里常有「机器生成的 `.nix`」——语言插件映射、镜像清单等。反模式不是「使用生成代码」，而是**生成后手改、且不留再生入口**：下次再生成，手改全部蒸发；评审者也无法判断哪行是机器的。好例是在文件头写明出处与再生成命令：

```nix
# 本文件由 ./generate.nix 生成（nix run .#generate），请勿手改；
# 需要改动请改源头 manifest.json
{ }
```

## 12.6 格式化与静态检查生态

| 工具 | 定位 | 备注 |
|---|---|---|
| nixfmt | 格式化器 | nixpkgs 官方采纳的统一风格（旧名 nixfmt-rfc-style，后并入 nixfmt） |
| alejandra | 格式化器 | 社区流行，快且风格强硬（opinionated） |
| deadnix | 静态检查 | 找出未使用的绑定（let 变量、函数参数），提示删除 |
| statix | 静态检查 | lint 常见反模式，规则含 unquoted_uri、empty_let_in、eta_reduction 等 |

上手只需 nix run：

```console
$ nix run nixpkgs#nixfmt -- .            # 原地格式化（gofmt 式）
$ nix run nixpkgs#nixfmt -- --check .    # 只检查不改，适合挂 CI
$ nix run nixpkgs#deadnix -- .           # 列出未使用的绑定
$ nix run nixpkgs#statix -- check .      # lint 反模式
```

格式化器的价值不在「哪种风格更好」，而在**风格退出讨论**：nixpkgs 采纳 nixfmt 后，评审不再争论空格与换行，diff 只剩实质改动。Flakes 里可以给仓库声明统一格式化器，`nix fmt` 一键执行、`nix flake check` 顺带校验——具体做法在第 44 章的 Flake 模板中给出：

```nix
# flake.nix 片段（第 44 章完整讲解）
{
  outputs = { self, nixpkgs }: {
    formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt;
  };
}
```

## 12.7 重构实战：60 行「祖传代码」的重生

先看病号——一段为教学拼接的典型样本，能跑，但每个角落都在埋雷。标号 ① 至 ⑧ 的问题将逐步处理：

```nix
# ops-tools.nix —— 【重构前】
with import <nixpkgs> { };                              # ① 顶层 with

stdenv.mkDerivation rec {                               # ② rec 自引用
  name = "ops-tools-" + version;                        # ③ 手拼 name
  version = "0.3";

  src = ./.;

  buildInputs = with pkgs; [ jq curl gnugrep ];         # ④ 二层 with＋依赖不分类

  # 部署令牌：来自上游清单（示意）
  deployToken = "build-secret-xyz";

  installPhase = ''
    mkdir -p $out/bin $out/share

    cat > $out/bin/fetch-logs <<'EOF'
    #!/bin/sh
    PATH=${jq}/bin:${curl}/bin:${gnugrep}/bin:$PATH     # ⑤ 手写 bin 链
    for h in log1.internal log2.internal; do
      curl -s "https://$h/logs?token=${deployToken}" | jq . > "$h.json"
    done
    EOF
    chmod +x $out/bin/fetch-logs

    cat > $out/bin/clean-logs <<'EOF'
    #!/bin/sh
    PATH=${jq}/bin:${curl}/bin:${gnugrep}/bin:$PATH     # ⑤ 又抄一遍
    find /var/log/app -name '*.json' -mtime +7 -delete
    EOF
    chmod +x $out/bin/clean-logs

    if [ -d ./extras ]; then                            # ⑦ 条件写死在 shell 里
      cp ./extras/* $out/share/
    fi

    # 「以防万一」把所有包路径记一份进产物
    echo "${toString (lib.attrValues pkgs)}" > $out/share/all-paths.txt  # ⑥
  '';
}                                                       # ⑧ 没有 meta
```

### 第 1 步：拆掉顶层 with，文件变成函数

动机：反模式 1。让依赖显式、让遮蔽不可能，也让这个文件可以被 callPackage 调用（第 32 章）：

```nix
{ lib, stdenv, jq, curl, gnugrep }:
stdenv.mkDerivation rec { /* … */ }
```

④ 里的二层 `with pkgs` 随之消失——包名已经在参数列表里。

### 第 2 步：rec 换 finalAttrs，name 换 pname + version

动机：12.2.2。`name = "ops-tools-" + version` 手拼出的名字丢掉了 pname 语义（nixpkgs 靠 pname+version 生成规范名与更新检测）：

```nix
stdenv.mkDerivation (finalAttrs: {
  pname = "ops-tools";
  version = "0.3";
  # …
})
```

### 第 3 步：heredoc 脚本改为 writeShellScriptBin 生成

动机：第 9 章。heredoc 拼脚本没有语法检查、没有标准 bin 布局；writeShellScriptBin 自动补 shebang、构建时做语法检查（shell -n），产物目录规范：

```nix
{ lib, stdenv, writeShellScriptBin, jq, curl, gnugrep }:
# … let 部分见最终版
```

脚本体先原样搬过去，路径问题留给第 4 步。

### 第 4 步：命令路径换 getExe / makeBinPath + wrapProgram

动机：反模式 5。两处重复的 `${jq}/bin:…` 链换成 wrapper 统一注入 PATH，改依赖清单只改一处：

```nix
wrapProgram $out/bin/fetch-logs \
  --prefix PATH : ${lib.makeBinPath [ curl jq gnugrep ]}
```

### 第 5 步：令牌与主机名移到运行期

动机：第 9 章的注入防护，外加一条安全常识——**secret 不进 store**。原代码把 deployToken 烤进构建脚本，它随产物进入 /nix/store，而 store 路径默认全局可读。重构后脚本只从环境变量读值，构建期零知情：

```nix
curl -sf "https://$h/logs" -H "Authorization: Bearer $TOKEN" | jq . > "$h.json"
```

### 第 6 步：shell 里的条件判断移回 Nix

动机：让「装不装 extras」成为求值期决定——可测试、可组合，产物布局也稳定（第 11 章：这份判断只发生在求值时）：

```nix
extras = if builtins.pathExists ./extras then ./extras else null;
# 安装处：
${lib.optionalString (extras != null) ''
  cp -r ${extras}/. $out/share/
''}
```

### 第 7 步：删掉对整个 pkgs 的插值

动机：反模式 6。那行「以防万一」的 all-paths.txt 让这个包依赖一切、求值全库；直接删除。真需要清单，做成单独的调试包。

### 第 8 步：补 meta

动机：getExe、平台过滤、nix search 的信息全部来自 meta（第 32 章）：

```nix
meta = {
  description = "内网日志抓取与清理小工具集";
  mainProgram = "fetch-logs";
  platforms = lib.platforms.unix;
  license = lib.licenses.mit;
};
```

### 重构后的完整版本

```nix
# ops-tools.nix —— 【重构后】
{ lib
, stdenv
, writeShellScriptBin
, makeWrapper
, jq
, curl
, gnugrep
, findutils
}:

let
  # 条件资产显式化：extras 是否存在，在求值期决定（第 6 步）
  extras = if builtins.pathExists ./extras then ./extras else null;

  # 脚本本体：writeShellScriptBin 自动 shebang ＋ 构建期语法检查（第 3 步）
  fetchLogs = writeShellScriptBin "fetch-logs" ''
    set -euo pipefail
    # SERVERS / TOKEN 从运行期环境读取（第 5 步）——构建期零知情
    for h in $SERVERS; do
      curl -sf "https://$h/logs" -H "Authorization: Bearer $TOKEN" \
        | jq . > "$h.json"
    done
  '';

  cleanLogs = writeShellScriptBin "clean-logs" ''
    set -euo pipefail
    find /var/log/app -name '*.json' -mtime +7 -delete
  '';
in
stdenv.mkDerivation (finalAttrs: {
  pname = "ops-tools";          # 规范命名（第 2 步）
  version = "0.3";
  src = ./.;

  buildInputs = [ jq curl gnugrep findutils ];   # 运行期依赖
  nativeBuildInputs = [ makeWrapper ];           # 构建期工具：只在构建时需要

  installPhase = ''
    runHook preInstall

    # 脚本来自 writeShellScriptBin 的产物；
    # 插值即声明依赖——字符串 context 保证了这一点（第 9 章）
    install -Dm555 ${lib.getExe fetchLogs} $out/bin/fetch-logs
    install -Dm555 ${lib.getExe cleanLogs} $out/bin/clean-logs

    # PATH 统一由 wrapper 注入：改依赖清单只改这一处（第 4 步）
    wrapProgram $out/bin/fetch-logs \
      --set-default SERVERS "log1.internal log2.internal" \
      --prefix PATH : ${lib.makeBinPath [ curl jq gnugrep ]}
    wrapProgram $out/bin/clean-logs \
      --prefix PATH : ${lib.makeBinPath [ findutils ]}

    # 条件安装：判断在 Nix 里，产物布局稳定（第 6 步）
    ${lib.optionalString (extras != null) ''
      cp -r ${extras}/. $out/share/
    ''}

    runHook postInstall
  '';

  meta = {                       # 元数据补全（第 8 步）
    description = "内网日志抓取与清理小工具集";
    mainProgram = "fetch-logs";
    platforms = lib.platforms.unix;
    license = lib.licenses.mit;
  };
})
```

对照两版的收获可以总结成一句话：**行为没变，但每一个决策都从 shell 字符串里搬回了 Nix 表达式**——于是它们可 override、可组合、可静态检查，secret 不再落盘，未来加第三个脚本只需再写一个 writeShellScriptBin。最后跑一遍 12.6 的工具收尾：

```console
$ nix run nixpkgs#nixfmt -- ops-tools.nix    # 统一格式
$ nix run nixpkgs#deadnix -- ops-tools.nix   # 应无输出：没有未用绑定
$ nix run nixpkgs#statix -- check .          # 应无 lint：反模式清零
```

## 12.8 本章小结

- 「地道」是协作基础设施：可评审、可检索、抗 override 改动；每条惯例都有坏例对照。
- 标识符 camelCase，角色名复用社区黑话（pkgs、lib、cfg、finalAttrs……）。
- 包表达式新标准头部是 `stdenv.mkDerivation (finalAttrs: { … })`：自引用在 override 后保持一致；`pname + version` 取代手拼 name。
- optional / optionals / optionalString 三分天下：单元素、列表、字符串；getExe 与 makeBinPath 取代手写 `/bin` 路径。
- throw 可被 tryEval 捕获、abort 不可；assert 把契约写在求值期；tryEval 是浅捕获；lib.warn 打印警告并返回原值。
- 七大反模式：顶层 with pkgs、嵌套 with、rec 抗 override、拼 shell 不转义、手写 /bin、塞整个 pkgs、生成代码不留入口。
- nixfmt（官方）、alejandra、deadnix、statix 构成格式化与静态检查流水线；Flakes 的 formatter 与 nix flake check 让它们一键化（第 44 章）。
- 重构实战的主线：把决策从 shell 字符串搬回 Nix 表达式——行为不变，可维护性质变。

## 延伸阅读

- nixpkgs 贡献指南：https://github.com/NixOS/nixpkgs/blob/master/CONTRIBUTING.md
- nixpkgs 手册 · 打包参考（标准头部与 meta）：https://nixos.org/manual/nixpkgs/stable/#part-stdenv
- nixfmt（官方格式化器）：https://github.com/NixOS/nixfmt
- deadnix：https://github.com/nix-community/deadnix
- statix：https://github.com/nerdypepper/statix
- alejandra：https://github.com/kamadorueda/alejandra
