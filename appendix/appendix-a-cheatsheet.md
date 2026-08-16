# 附录 A：Nix 语言速查表

> 依据 Nix 2.35 官方语言手册整理（2026-08）。用于快速查阅；概念详解见第 6-12 章。⛔ 标记为已弃用/不推荐，⚠️ 为受限或慎用，✅ 为现行推荐规范。

## A.1 类型与字面量

| 类型 | typeOf | 字面量 | 要点 |
|------|--------|--------|------|
| 整数 | `"int"` | `42` `-7` | 64 位；`5 / 2 = 2`（整除截断） |
| 浮点 | `"float"` | `3.14` `1e6` | 与整数可比较（`1 == 1.0` 为 true） |
| 布尔 | `"bool"` | `true` `false` | 仅小写 |
| null | `"null"` | `null` | 与 `false` 是不同值 |
| 字符串 | `"string"` | `"..."` `''...''` | 可携带上下文（第 9 章） |
| 路径 | `"path"` | `./a.txt` `/nix/...` `~/x` | 字面量须含 `/`；相对定义文件 |
| 列表 | `"list"` | `[ 1 2 3 ]` | 空白分隔、无逗号、惰性 |
| 属性集 | `"set"` | `{ a = 1; }` | 条目以分号结尾 |
| 函数 | `"lambda"` | `x: x` `{ a }: ...` | 无名；模式匹配见 A.3 |

## A.2 运算符优先级（高 → 低）

| 级 | 运算符 | 结合 | 示例 |
|----|--------|------|------|
| 1 | 函数应用 | 左 | `f x y` ≡ `(f x) y` |
| 2 | 属性选择 / `or` | 左 | `a.b.c or d` |
| 3 | 一元 `-` `!` | — | `-n` |
| 4 | `?` | 左 | `a ? b` |
| 5 | `*` `/` | 左 | 整数对整数为整除 |
| 6 | `+` `-` | 左 | 字符串/路径拼接同级 |
| 7 | `++` | 右 | 列表拼接 |
| 8 | `//` | 右 | 属性集浅合并（右优先） |
| 9 | `<` `>` `<=` `>=` | — | 仅同类型（数字/字符串/路径） |
| 10 | `==` `!=` | — | ⚠️ Nix ≥ 2.4 跨类型报错（旧版返回 false） |
| 11 | `&&` | 左 | 短路 |
| 12 | `||` | 左 | 短路 |
| 13 | `->` | 右 | 蕴含：`a -> b` ≡ `!a \|\| b` |

## A.3 语法速查

```nix
# let / in：局部绑定，后向引用，不可自引用（自引用用 rec / lib.fix / finalAttrs）
let a = 1; b = a + 1; in b        # 2

# rec：属性集内自引用（⚠️ 小常量集合可用；⛔ 派生定义已淘汰 → finalAttrs）
rec { x = 1; y = x + 1; }

# inherit 三态
{ inherit x; }                    # 等价 { x = x; }
{ inherit (src) owner repo; }     # 等价 { owner = src.owner; repo = src.repo; }
let inherit (cfg) port; in ...

# with：注入属性集（⛔ nixpkgs 禁止顶层 with pkgs）
with pkgs; [ hello ripgrep ]      # 查找优先级：函数参数 > let > 内层 with > 外层

# if：表达式，必须有 else，条件必须布尔
if x > 0 then "正" else "非正"

# 模式匹配参数（函数「依赖提货单」）
{ a, b ? 0, ... }@args: a + b     # 默认值 b=0；... 允许多余字段；args 绑定整个集合
{ lib, stdenv, fetchurl, }: ...   # ✅ RFC 166 格式：多行 + 尾逗号

# 动态属性名 / or 默认值
{ ${name} = value; }
attrs.port or 8080                # 属性缺失时取默认（仅「缺失」触发）

# 缩进字符串规则（''...''）
# ① 剥掉全部非空行的最长公共前导空白；② 纯空白行不参与计算；
# ③ 开头 '' 同行内容不剥离；④ 字面 ${ 写 ''${；字面 '' 写 ''''；
# ⑤ 反斜杠不构成转义（写正则/Windows 路径友好）
''
  ${greeting}
  ''${literalBraces}
''

# 断言与错误
assert builtins.isString x; ...   # 求值期断言
throw "..."                       # 可被 tryEval 捕获
abort "..."                       # 不可捕获，立即终止
```

## A.4 builtins 一览（Nix 2.35，按字母序）

签名风格：`名字 参数 → 结果说明`。★ = 高频。

| 内建函数 | 用途 |
|----------|------|
| `abort s` | 致命错误，立即终止求值（不可捕获） |
| `add e1 e2` / `sub` / `mul` / `div` | 算术的函数形式 |
| `addErrorContext ctx v` | 求值 v 出错时附加上下文信息 |
| `all pred list` ★ | 全部满足？（短路） |
| `any pred list` ★ | 存在满足？（短路） |
| `attrNames set` ★ | 属性名列表（字典序） |
| `attrValues set` ★ | 属性值列表（名字典序） |
| `baseNameOf x` | 最后一个路径分量 |
| `bitAnd` / `bitOr` / `bitXor` | 整数位运算 |
| `break v` | 调试模式下触发断点（第 11 章） |
| `catAttrs attr list` | 收集列表中各 set 的同名属性 |
| `ceil n` / `floor n` | 取整 |
| `compareVersions s1 s2` ★ | 版本比较 → -1/0/1 |
| `concatLists lists` | 拍平一层 |
| `concatMap f list` | map 后拍平 |
| `concatStringsSep sep list` ★ | 连接字符串 |
| `convertHash { hash; toHashFormat; }` | 哈希编码互转（配合 nix hash） |
| `currentSystem` ⚠️ | 当前系统三元组（纯求值不可用；可用性差，勿依赖） |
| `currentTime` ⚠️ | 求值时刻 Unix 时间（纯求值不可用；破坏复现，勿用） |
| `deepSeq e1 e2` | 深度求值 e1 返回 e2 |
| `derivation attrs` ★ | 原语：声明派生（第 13 章） |
| `dirOf s` | 目录部分 |
| `elem x list` ★ | 成员测试 |
| `elemAt list n` | 下标取元素 |
| `fetchClosure args` ⚠️实验 | 从缓存取闭包（fetch-closure 特性） |
| `fetchGit args` | 拉取 git 仓库（impure 变体 ⛔ 仅实验；nixpkgs 用 fetchgit） |
| `fetchTarball args` ⚠️ | 下载解压 tarball（无哈希约束；⛔ nixpkgs 用 pkgs.fetchTarball） |
| `fetchTree args` ⚠️实验 | 通用源树获取（fetch-tree 特性） |
| `fetchurl args` ⚠️ | 内建下载（⛔ nixpkgs 用 pkgs.fetchurl） |
| `filter pred list` ★ | 过滤 |
| `filterSource f src` | 复制进 store 时过滤文件（第 15 章；现代替代 builtins.path） |
| `findFile searchPath path` | `<...>` 查找的实现 |
| `flakeRefToString` ⚠️实验 | flake 引用 → URL |
| `foldl' op init list` ★ | 严格左折叠（撇号=防栈堆积） |
| `fromJSON e` ★ | 解析 JSON |
| `fromTOML e` | 解析 TOML |
| `functionArgs f` ★ | 形参表 {名:有无默认值}（callPackage 的地基） |
| `genericClosure attrset` | 传递闭包（依赖图遍历，第 32 章相关） |
| `getAttr s set` | 动态取属性（点号的函数版） |
| `getContext s` | 字符串上下文详情（第 9 章） |
| `getEnv s` ⚠️ | 读环境变量（破坏纯度，nixpkgs 禁） |
| `groupBy f list` | 按键分组 → attrsOf list |
| `hasAttr s set` | 属性存在（`?` 的函数版） |
| `hasContext s` | 是否带上下文 |
| `hashFile algo path` / `hashString algo s` | 计算 base16 哈希（✅ SRI 用 nix hash / lib.hashString? 以手册为准） |
| `head list` ★ | 首元素（空表抛错） |
| `import path` ★ | 载入并求值 .nix 文件 |
| `intersectAttrs a b` | 键交集（取 b 值） |
| `isAttrs` / `isBool` / `isFloat` / `isFunction` / `isInt` / `isList` / `isNull` / `isPath` / `isString` | 类型谓词 |
| `langVersion` / `nixVersion` / `storeDir` | 环境常量 |
| `length list` ★ | 长度 |
| `lessThan a b` | `<` 的函数版（sort 用） |
| `listToAttrs list` ★ | [{name;value}] → attrs（配 lib.nameValuePair） |
| `map f list` ★ | 映射 |
| `mapAttrs f set` ★ | 按属性映射（f name value） |
| `match regex str` ★ | 正则匹配 → 组列表或 null |
| `nixPath` ⚠️ | NIX_PATH 内容 |
| `outputOf` ⚠️实验 | 派生输出引用（dynamic-derivations 特性） |
| `parseDrvName s` | "name-version" → {name; version} |
| `parseFlakeRef` ⚠️实验 | 解析 flake 引用 |
| `partition pred list` | 分成 {right; wrong} |
| `path args` | ✅ 现代源复制（filter/name 配套；第 15 章） |
| `pathExists path` | 存在性（仅路径类型） |
| `placeholder output` ★ | 输出路径占位符（第 34.6 节） |
| `readDir path` | 目录清单（含文件类型） |
| `readFile path` ★ | 文件内容为字符串 |
| `readFileType p` | 节点类型字符串 |
| `removeAttrs set list` ★ | 剔除属性 |
| `replaceStrings from to s` ★ | 逐对替换 |
| `scopedImport scope path` ⚠️ | 带作用域 import（无缓存语义，罕用） |
| `seq e1 e2` | 求值 e1 返回 e2（浅严格） |
| `sort cmp list` ★ | 稳定排序 |
| `split regex str` ★ | 按正则切分（惰性交替结构） |
| `splitVersion s` | 版本拆段 |
| `storePath path` ⚠️ | 字符串→store 路径依赖（纯求值不可用；慎） |
| `stringLength e` | 字节长度（中文注意） |
| `substring start len s` | 字节截取 |
| `tail list` ★ | 去首元素 |
| `throw s` ★ | 可捕获错误 |
| `toFile name s` | 字符串写为 store 文件 |
| `toJSON e` ★ | 序列化 JSON |
| `toPath s` | ⛔ **DEPRECATED**：用 `/. + "/path"` 替代 |
| `toString e` ★ | 强转字符串（路径→路径文本） |
| `toXML e` | XML 表示（罕用） |
| `trace e1 e2` ★ | 打印 e1 返回 e2（printf 调试） |
| `traceVerbose e1 e2` | 仅 --trace-verbose 时打印 |
| `tryEval e` ★ | 捕获 throw（不捕 abort）→ { success; value; } |
| `typeOf e` ★ | 类型名字符串 |
| `unsafeDiscardOutputDependency s` ⚠️ | 削减派生级上下文 |
| `unsafeDiscardStringContext s` ⚠️ | 剥离上下文（名字即警告） |
| `unsafeGetAttrPos` | 属性位置（报错信息用） |
| `warn e1 e2` | 打印警告返回 e2（lib.warn 的地基） |
| `zipAttrsWith f sets` | 多集合按键归并 |

## A.5 lib 常用函数 50 选

```nix
# —— lib.trivial / 通用 ——
lib.id                # 恒等
lib.const             # 常函数
lib.fix               # 不动点（第 7/25/32 章）
lib.flip f a b        # 参数交换
lib.pipe x [f g]      # ★ 管道：x |> f |> g（第 7.7 节）
lib.composeExtensions # overlay 组合（第 39 章）
lib.getExe pkg        # ★ 取主程序路径（替代 "${pkg}/bin/x"）
lib.getExe' pkg name  # 指定名字
lib.getVersion / lib.getName
lib.optional cond x         # 条件→单元素列表
lib.optionals cond xs       # 条件→列表本身（注意复数）
lib.optionalString cond s   # 条件→字符串或空串
lib.fakeHash / lib.fakeSha256 / lib.fakeSha512   # ★ 假哈希起步（第 42 章）
lib.versionAtLeast / versionOlder / compareVersions
lib.warnIf cond msg / throwIfNot cond msg

# —— lib.strings ——
lib.concatStringsSep / concatMapStringsSep
lib.hasPrefix / hasSuffix / removePrefix / removeSuffix
lib.stringToCharacters / toLower / toUpper / trim
lib.escapeShellArg / escapeShellArgs      # ★ 注入防护（第 9 章）
lib.generators.toINI / toKeyValue / toJSON? # 配置生成器（第 43 章）

# —— lib.lists ——
lib.range a b; lib.repeat n x; lib.replicate? （以手册为准）
lib.unique; lib.flatten; lib.last; lib.take/drop? 常用项
lib.lists.findFirst / findSingle
lib.zipListsWith / zipLists
lib.lists.crossLists? 罕用不列

# —— lib.attrsets ——
lib.attrByPath [path] default set
lib.getAttrFromPath [path] set
lib.setAttrByPath [path] v
lib.mapAttrs' (k: v: { name = k'; value = v'; })   # ★ 改键改值
lib.mapAttrsToList / mapAttrsRecursive? 常用
lib.filterAttrs (k: v: cond) / filterAttrsRecursive
lib.optionalAttrs cond { ... }      # ★ 条件属性（模块系统常用）
lib.recursiveUpdate a b             # 深合并（// 是浅合并）
lib.mergeAttrsList [ ... ]          # 多集合合并
lib.attrVals names set / attrValues'
lib.genAttrs names (n: ...)         # 按名生成
lib.zipAttrsWith? 见 builtins 同名
lib.groupBy' / foldAttrs            # 聚合
```

## A.6 stdenv phases 与常用 hook

| Phase（执行序） | 默认行为 | 常用覆盖/参数 |
|---|---|---|
| unpack | 解压 $src | `postUnpack`、`sourceRoot` |
| patch | 应用 patches | `postPatch`、`substituteInPlace --replace-fail` |
| configure | ./configure --prefix=$out（hook 识别 cmake/meson） | `configureFlags`、`preConfigure` |
| build | make -jN | `buildFlags`、`dontBuild` |
| check | make check（默认关） | `doCheck`、`checkFlags` |
| install | make install | `installFlags`、`postInstall` |
| installCheck | 默认关 | `doInstallCheck`、`versionCheckHook` |
| fixup | shebang/RPATH/strip/分拣 | `postFixup`、`dontStrip` |
| dist | 打 tar 分发 | 罕用 |

常用 hook（进 nativeBuildInputs 即生效）：`cmake`、`ninja`、`meson`、`pkg-config`、`autoreconfHook`、`installShellFiles`、`versionCheckHook`、`makeWrapper`、`autoPatchelfHook`、`writableTmpDirAsHomeHook`。

## A.7 mkDerivation 常用参数

| 参数 | 语义 | 规范状态 |
|------|------|----------|
| `pname` / `version` | 名字与版本（分离声明） | ✅（⛔ `name = "x-${version}"` 过时） |
| `src` / `srcs` | 源（fetcher 产物） | ✅ |
| `patches` | 补丁列表 | ✅ |
| `nativeBuildInputs` | 构建时**执行**的依赖 | ✅（口诀见 34.4） |
| `buildInputs` | **链接/包含**进产物的依赖 | ✅ |
| `propagatedBuildInputs` | 传递依赖（.pc/头文件场景） | ⚠️ 慎用 |
| `outputs` | 多输出声明 | ✅ |
| `env.<VAR>` | 注入构建环境变量 | ✅（替代裸变量名） |
| `__structuredAttrs` | 参数走 JSON | ✅ 新包标配 |
| `strictDeps` | 依赖精确化 | ✅ 默认方向 |
| `doCheck` / `doInstallCheck` | 测试开关（默认关） | ✅ 显式开 |
| `postXxx` / `preXxx` | phase 前后追加 | ✅ |
| `meta` / `passthru` | 元数据/附加属性 | ✅（含 `mainProgram`） |
| `${placeholder "out"}` | 输出路径占位 | ✅（替代 $(out) 惯用） |
| `overrideAttrs`/`.override` | 定制（第 39 章） | ✅ |

## A.8 新旧对照总表

| 领域 | 旧（⚠️/⛔ 过时） | 新（✅ 现行） |
|------|------------------|---------------|
| 构建 | `nix-build '<nixpkgs>' -A hello` | `nix build nixpkgs#hello` |
| 环境 | `nix-shell -p ripgrep` | `nix shell nixpkgs#ripgrep`（临时）/ `nix develop`（项目） |
| 安装 | `nix-env -iA nixpkgs.hello` | `nix profile install nixpkgs#hello` |
| 更新源 | `nix-channel --update` | `nix flake update`（lock 进 git） |
| 求值 | `nix-instantiate --eval` | `nix eval` |
| 看 .drv | `nix show-derivation` | `nix derivation show` |
| 哈希 | `sha256 = "base32..."` | `hash = "sha256-..."`（SRI） |
| 自引用 | `mkDerivation rec {}` | `mkDerivation (finalAttrs: {})` |
| 取程序 | `"${pkg}/bin/foo"` | `lib.getExe pkg` |
| 顶层作用域 | `with pkgs; ...` | 函数参数显式注入 + `inherit` |
| 源路径 | `import <nixpkgs>` | flake input（锁定 rev） |
| `builtins.toPath` | ⛔ DEPRECATED | `/. + "/path"` |
| 跨类型 `==` | 旧版返回 false | Nix ≥ 2.4 报错（勿依赖旧行为） |
| 替换脚本 | `--replace` | `--replace-fail`（宁炸勿静默） |
| 格式化 | 手工/各写各的 | `nixfmt`（RFC 166 风格，nixpkgs 官方） |

## A.9 延伸阅读

- 官方语言手册（本表的权威来源）：https://nixos.org/manual/nix/stable/language/
- `nix repl` 里直接实验：`builtins.attrNames builtins` 可列出当前版本全部内建函数。
