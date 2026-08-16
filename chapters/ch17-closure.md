# 第 17 章 闭包：依赖的完整图谱

> **本章导读**：第 14 章介绍存储模型时提到，每个 store 对象都登记着自己的引用（references），即它依赖哪些其他 store 路径。沿这份清单一路追到底，得到的完整路径集合就是闭包（closure）——一个程序运行所需的全部家当。闭包是 Nix「部署即复制」哲学的技术底座。本章带你亲手枚举、搬运、测量闭包，并拆解它背后的动态链接机制。

## 17.1 什么是闭包

### 17.1.1 从引用关系到传递闭包

先复习第 14 章的结论：`/nix/store` 中的每个对象在 Nix 数据库里都记录着一份引用（references）清单，等价于一条条指向其他 store 路径的有向边。例如 hello 的输出引用了 glibc；而 glibc 位于依赖图的最底层，不再引用任何别的 store 路径。

于是「运行 hello 需要哪些东西」这个问题，答案就是：在有向引用图上，从 hello 出发、沿着边不断走下去，所有可达结点的集合。这个集合在图论里有个标准名称——传递闭包（transitive closure）。Nix 旧命令 `nix-store -q --requisites` 中的 requisites（必需品），指的就是它。

为了体会这个定义的分量，对照一下传统 Linux 二进制的做法。ELF 文件的动态段（`DT_NEEDED`）里写的是 `libc.so.6` 这样的 soname（共享对象名）：不带路径、不带哈希、不带版本号，装载器靠「系统约定 + 全局缓存」去猜它指向哪个文件。也就是说，`DT_NEEDED` 是一份**愿望清单**——它声明了想要什么，却不保证东西在哪、是不是对的那个。而 Nix 的 references 是精确到哈希的完整边表：路径里的哈希保证了「引用的那个 glibc」就是构建时用到的那个 glibc，不多、不少、不会换。愿望与事实的差别，正是「依赖地狱」与「依赖闭包」的差别。

把 hello 的引用图画出来（箭头表示「引用」这条边）：

```text
hello-2.12.1 ──引用──▶ glibc-2.42-12 ──▶ （无）
```

图很小，但值得盯着看三秒：**闭包就是从起点出发、沿箭头可达的全部结点**。hello 的闭包是 {hello, glibc}；glibc 自己的闭包只有 {glibc}。任何程序、任何依赖组合都遵守同一条规则——没有特例，也没有藏在系统角落里的隐式依赖。

闭包作为一个集合，有三条值得记住的性质：

- **可枚举**：它是一条命令就能完整打印的列表，而不是散落在文件系统各处、靠约定维系的事实上的依赖；
- **可传递**：闭包的闭包还是闭包——把 hello 的闭包整体搬到目标机后，它在那台机器上依然自洽，不需要二次补齐；
- **内容寻址一致**：闭包里每个路径的身份由内容决定（第 15 章），因此「同一个闭包」在任何机器上都是同一批路径，可以逐项比对、签名与共享（第 20 章）。

### 17.1.2 运行闭包与构建闭包

闭包其实有两层含义，日常说「闭包」时几乎都指前者：

- **运行闭包（runtime closure）**：程序**运行时**需要的全部 store 路径——可执行文件本身、它链接的动态库、库需要的数据文件、字体、翻译文件等。这是从「输出」出发沿引用关系得到的闭包。
- **构建闭包（build closure）**：**构建**这个软件需要的全部内容——编译器 gcc、shell 工具 coreutils、补丁文件、各种构建脚本，以及它们各自的依赖。它是从派生文件（`.drv`，参见第 13 章）出发的传递闭包，规模大得多：hello 的运行闭包只有两个路径，构建闭包则有数百个（其中相当一部分来自 stdenv 的自举链，参见第 33 章）。

| 维度 | 运行闭包 | 构建闭包 |
| --- | --- | --- |
| 起点 | 派生的输出 | 派生文件（`.drv`） |
| 典型内容 | 二进制、动态库、数据文件 | 编译器、构建脚本、整套构建工具链 |
| hello 的规模 | 2 个路径 | 数百个路径 |
| 谁关心它 | 部署、打镜像（第 35 章） | 开发 shell、CI 构建（第 16、41 章） |

区分两者非常实用：

- **部署**只需要运行闭包。把服务器、容器镜像、LiveUSB 里塞进 gcc 是纯浪费——第 35 章会看到 `dockerTools` 打镜像时拷贝的正是运行闭包。
- **开发**关心构建闭包。`nix-shell` 拉起的开发环境、`nix build` 触发的构建，都在构建闭包的世界里活动（参见第 16 章）。
- **垃圾回收**的两个选项 `keep-outputs` / `keep-derivations` 恰好对应「输出」与「构建配方」两条边，参见第 19 章。

## 17.2 动手观察一个闭包

概念讲完了，动手看。以下三组命令都能列出闭包，习惯哪组用哪组：

```console
$ nix path-info -r nixpkgs#hello
/nix/store/q5r7d3v2m9xk4nj6zh0a1b8c5wse6fyl-hello-2.12.1
/nix/store/8s0wfrq2n6dp1t9cz3a5h7yj4bgxelru-glibc-2.42-12
```

`-r`（`--recursive`）表示沿引用关系递归展开，也就是列出闭包。输出只有两行：hello 本体，加上 glibc。hello 是个再简单不过的 C 程序，动态链接的 C 库是它唯一的运行时依赖，所以闭包到此为止。（哈希与次版本号取决于你渠道里的 nixpkgs 快照，这里以 26.05 渠道某个快照为例；若提示需要实验特性，参见第 21 章关于 `experimental-features` 的说明。）

单看一层依赖、或反过来问「谁依赖它」，用另外两个查询：

```console
$ nix-store -q --references /nix/store/q5r7...-hello-2.12.1
/nix/store/8s0w...-glibc-2.42-12
$ nix-store -q --referrers /nix/store/8s0w...-glibc-2.42-12
/nix/store/q5r7...-hello-2.12.1
/nix/store/c4t1...-curl-8.16.0
…
```

`--references` 回答「它直接依赖谁」（只看一层）；`--referrers` 回答反方向的「谁直接依赖它」。三个查询各司其职：

| 查询 | 方向 | 深度 | 回答的问题 |
| --- | --- | --- | --- |
| `--references` | 正向 | 一层 | 它直接依赖谁 |
| `--referrers` | 反向 | 一层 | 谁直接依赖它 |
| `--requisites`（`-r`） | 正向 | 传递 | 它运行需要的一切（闭包） |

排错时三者常常连用：程序起不来，先 `--references` 看它想加载哪些库；怀疑某个路径被误解引用，`--referrers` 列出引用它的「嫌疑人」；评估部署成本，`--requisites` 数一数要搬多少东西。

顺带学会读路径本身：`/nix/store/<32 位哈希>-<名字>-<版本>`。哈希来自全部输入（第 15 章），名字与版本来自派生。看到两个 `glibc-2.42-12` 的哈希不同，说明它们是不同输入（比如不同补丁集）的产物——闭包里出现「同版本」的两个包不是错误，而是两条并存的依赖线，各自指向各自的 glibc。

在 NixOS 上，对已安装的程序可以用旧命令观察：

```console
$ nix-store -q --requisites $(which hello)
/nix/store/q5r7...-hello-2.12.1
/nix/store/8s0w...-glibc-2.42-12
```

`which hello` 在 NixOS 上得到 `/run/current-system/sw/bin/hello` 或 `~/.nix-profile/bin/hello`——它们都是指向 store 路径的符号链，`nix-store -qR`（`-qR` 是 `--query --requisites` 的缩写）会顺着符号链找到 store 对象再展开闭包。在其他发行版上装了 Nix 的话，`which hello` 可能是发行版自己的 `/usr/bin/hello`，那就不归 Nix 管了；请先 `nix-env -iA nixpkgs.hello` 或直接给出 store 路径。

两个条目的闭包太平凡，换一个更有代表性的例子——curl（以下输出有删节，去掉了哈希前缀）：

```console
$ nix path-info -r nixpkgs#curl
/nix/store/…-brotli-1.1.0
/nix/store/…-curl-8.16.0
/nix/store/…-glibc-2.42-12
/nix/store/…-libidn2-2.3.7
/nix/store/…-libpsl-0.21.1
/nix/store/…-libssh2-1.11.0
/nix/store/…-libunistring-1.2
/nix/store/…-nghttp2-1.64.0
/nix/store/…-openssl-3.5.1
/nix/store/…-zlib-1.3.1
```

每一行为什么会在闭包里？逐个解释：

- **glibc**：C 标准库与动态装载器，任何动态链接的 ELF 程序都绕不开它。几乎所有闭包的公共祖先。
- **openssl**：TLS 支持。没有它，`curl https://...` 直接不可用。
- **zlib / brotli**：HTTP 响应压缩（gzip 与 brotli）。curl 默认启用这两类解码支持。
- **nghttp2**：HTTP/2 协议库。
- **libssh2**：让 curl 支持 `sftp://`、`scp://`。
- **libidn2**：国际化域名（IDNA）支持，负责把 `例子.中国` 这类域名转换为 Punycode。
- **libunistring**：libidn2 自己的依赖——Unicode 字符串处理库。注意它**不是** curl 直接引用的，而是经 libidn2 传递进来的。这条「隔代引用」正说明为什么要叫传递闭包：只看直接依赖会漏掉它。
- **libpsl**：公共后缀列表（Public Suffix List）库，用于 cookie 域判断。

如果某个库你觉得「不该在这」，比如 curl 为什么需要 brotli——这正说明 nixpkgs 打包时默认开启了一大堆可选特性；想裁剪，用 `override`（参见第 39 章）。

再看看**构建闭包**。先用 `-qd`（`--query --deriver`）找到派生 hello 的 `.drv` 文件，再对它求传递闭包：

```console
$ nix-store -qd $(which hello)
/nix/store/…-hello-2.12.1.drv
$ nix-store -qR $(nix-store -qd $(which hello)) | wc -l
573
```

看一眼这份清单的开头（示意）：

```console
$ nix-store -qR $(nix-store -qd $(which hello)) | head -5
/nix/store/…-hello-2.12.1.drv        # hello 自己的配方
/nix/store/…-gcc-wrapper-14.2.0.drv  # 编译器（stdenv 以 wrapper 形式封装）
/nix/store/…-coreutils-9.6.drv       # 构建脚本里的 cp、mkdir 等工具
/nix/store/…-bash-5.2-patched.drv    # 解释构建脚本的 shell
…
```

从两个路径暴涨到几百个路径：gcc、binutils、coreutils、bash、各种补丁工具、以及 stdenv 自举链上的每一环（参见第 33 章）全部在内。这就是「构建 hello」与「运行 hello」的成本差异——也是 Nix 能在任何空机器上从源码重建整个世界的原因（前提是这些构建依赖本身能被引导出来）。

## 17.3 闭包即部署：完整性的一次性解决

### 17.3.1 传统方案各自怎么保证完整性

「程序运行需要的一切都在这」——这个看似朴素的要求，是传统部署方式的长期痛点。逐一对照：

**`make install` 到 `/usr/local`**：安装器把文件撒到 `bin/`、`lib/`、`share/` 各处，依赖则默认「系统里已经有」。所谓完整性，靠的是约定与运气：两台机器都装了 libfoo 就能跑，版本不一致就出现「在我机器上是好的」。卸载更是灾难——没有清单，删不干净。apt/dnf 用包数据库与依赖声明改善了很多，但依赖是「名称 + 版本区间」而非精确哈希：同一个 `libssl-dev (>= 3.0)` 约束，今天装和明年装得到的世界不同，`apt upgrade` 之后任何一个未经测试的组合都可能出问题。

**`pip install` 到 venv**：虚拟环境隔离了 Python 层的依赖，比系统级安装进步。但 C 扩展模块链接的系统库（numpy 背后的 BLAS、cryptography 背后的 OpenSSL）仍在 venv 之外；把 venv 目录整个拷到另一台 OpenSSL 版本不同的机器上，import 时就会报 `undefined symbol`。而且 pip 的依赖解析基于名称与版本约束，解析器策略本身也在演化——同一份 requirements.txt 在不同年份可能解析出不同结果。

**Docker 镜像**：把完整 rootfs 打包，确实完整，但完整性靠「全都要」：每一层是不透明的 tar diff，你不知道里面有什么、哪些文件其实永远用不到；在层里删掉文件并不减小镜像体积（只是在上层打了个「墓碑」）；同一份 openssl 在十个镜像里存了十遍。而且镜像里塞进了 apt 元数据、包管理器、init 脚本——对一个只跑单个二进制的容器而言都是死重。

三种方案的共同短板：完整性要么靠外部环境兜底（make/pip），要么靠过度打包（Docker）。

### 17.3.2 Nix 的答案：把闭包整体搬走

Nix 的回答干净利落：**闭包本身就是可部署单元**。既然闭包精确枚举了运行所需的每个路径，而每个路径在 `/nix/store` 下自包含、位置由内容决定（参见第 15 章），那么把闭包里所有路径原样复制到目标机器，程序立刻就能运行——不需要目标机器装任何「前置依赖」。

把这个想法变成命令的，是两条搬运工具。

老牌的 `nix-copy-closure`，通过 SSH 传输闭包：

```console
$ nix-copy-closure --to alice@server $(which hello)
```

它会在本地计算闭包，比对远端已有的路径（只传缺的），把每个 store 对象序列化后经 SSH 导入远端 store。新一些的 `nix copy` 更通用，支持多种目标：

```console
$ nix copy --to ssh://alice@server nixpkgs#hello
```

`ssh://` 目标同样走 SSH 协议；`--to` 还可以是 `file://` 目录、二进制缓存 URL 等（参见第 20 章）——`nix copy` 实际上就是第 20 章二进制缓存生态的搬运基础。

传完之后在远端直接运行即可，无需任何安装步骤：

```console
$ ssh alice@server '/nix/store/q5r7...-hello-2.12.1/bin/hello'
Hello, world!
```

为什么敢直接执行？因为 hello 二进制里写死了 glibc 的确切 store 路径（机制见 17.5 节），装载器会到 `/nix/store/8s0w...-glibc-2.42-12/lib` 找库——路径在两台机器上一致，因为这个 glibc 内容完全一致（第 15 章的内容寻址保证）。

作为反面教材，试试传统方式搬运：

```console
$ scp /usr/bin/curl alice@server:
$ ssh alice@server ./curl https://example.com
./curl: error while loading shared libraries: libcurl.so.4: cannot open shared object file
```

`scp` 只搬了一个文件，而它需要的世界没有跟着走。这就是「一个文件」与「一个闭包」的差距。

把四种部署方式放进同一张表里对比：

| 维度 | make install | pip + venv | Docker 镜像 | Nix 闭包 |
| --- | --- | --- | --- | --- |
| 完整性依据 | 环境约定 | 只覆盖 Python 层 | 打包「全都要」 | 引用图证明 |
| 依赖标识 | 名称 | 名称 + 版本号 | 层摘要 | 精确哈希 |
| 增量传输 | 无从谈起 | 需重建环境 | 分层可复用 | 按 store 路径精确去重 |
| 回滚 | 无 | 难 | 换镜像标签 | 换 generation（第 18 章） |
| 内容可审计 | 不透明 | 较透明 | 层内不透明 | `nix path-info` 一目了然 |

表中最能体现「闭包思维」的是最后一行：一个闭包是**可枚举、可打印、可逐项审查**的集合。传统方案里「这个程序到底带了哪些文件」通常说不清，而 Nix 的答案就是一条命令的输出——审计、安全扫描、体积分析都因此有了精确的输入。

两个细节值得说明：其一，两台机器**不需要**运行相同的 NixOS 版本——闭包是自洽的，远端哪怕是完全没装 NixOS 的发行版，只要装了 Nix（multi-user 安装即可），路径照样成立。其二，闭包传输是增量的：远端已有同哈希的 glibc 就会跳过，这与 apt 逐包下载、层不可共享的 Docker 镜像形成对照。

### 17.3.3 离线搬运：export 与 import

没有 SSH 的场景（离线装机、往隔离网段的机器搬运），老工具 `nix-store --export` / `--import` 依然好用——它把整个闭包序列化成字节流，怎么传随你：

```console
$ nix-store --export $(nix path-info -r nixpkgs#hello) > hello.closure
```

导出文件是闭包内全部对象的归档，U 盘、scp、内网中转皆可承载。在目标机导入：

```console
$ nix-store --import < hello.closure
```

导入按第 15 章的规则校验内容哈希，落盘后的路径与导出方完全一致。离线部署一台 NixOS 的思路也在于此：目标盘挂载后，把引导器（第 28 章）与系统闭包一并导入即可，目标机全程不需要联网。

### 17.3.4 更新一台远端服务的完整循环

把上面的知识串成一次真实部署。假设目标服务器上有个 systemd 服务引用了工具的确切 store 路径（服务单元片段，示意）：

```bash
# /etc/systemd/system/mytool.service —— 引用确切路径，而非 /usr/bin
[Service]
ExecStart=/nix/store/…-mytool-0.3/bin/mytool serve
```

本地构建新版本、推送闭包、切换服务：

```console
$ nix build .#mytool
$ nix copy --to ssh://deploy@server $(readlink ./result)
$ ssh deploy@server 'sudo systemctl start mytool-0.4 && sudo systemctl stop mytool-0.3'
```

注意其中妙处：推送完成、切换服务**之前**，新旧两个版本在服务器上并存——新路径已就位，旧路径仍在运行；回退只是重新 start 旧单元，不存在「先删旧版再装新版」的危险窗口。NixOS 的 `switch-to-configuration`（第 27 章）把这个模式自动化到了整个操作系统层面，而它的原理，此刻已经完整地在你手里。

## 17.4 闭包大小：观测与优化

闭包是部署单元，因此「闭包多大」直接决定磁盘占用、传输量、镜像体积。Nix 对此有一等公民级别的观测工具。

`nix path-info` 加 `-S` 显示闭包大小（closure size），`-h` 人类可读：

```console
$ nix path-info -Sh nixpkgs#firefox
/nix/store/…-firefox-147.0    812.6 MiB
```

firefox 自己只有三百多 MB，闭包超过 800 MiB——多出来的部分是它传递依赖的所有库、字体配置、媒体编解码库等。想看清闭包里谁是体积大户，按第二列排序取前几名：

```console
$ nix path-info -rSh nixpkgs#firefox | sort -k2 -h | tail -6
/nix/store/…-libxcb-1.17.0        5.1 MiB
/nix/store/…-glibc-2.42-12        28.6 MiB
/nix/store/…-mesa-25.0.4          102.9 MiB
/nix/store/…-ffmpeg-7.1.1         118.7 MiB
...
```

两个尺寸概念要分清：`-s`（self size）是路径自身的磁盘占用，`-S`（closure size）是它整个闭包的总占用——后者才是「部署这个程序」的真实成本。一个共享库可能自身只有几百 KB、闭包却拖着几十 MB 的运行时依赖；一个 Go 编写的工具则往往自身多大、闭包就多大。判断「这个包重不重」，永远看闭包大小。

还要注意共享带来的记账差异：firefox 与 thunderbird 的闭包各算各的 glibc、mesa，但真装在同一台机器上，同哈希路径只落盘一份（第 14 章的 store 模型保证）。所以「把各软件闭包大小加起来」会高估实际磁盘占用——闭包大小衡量的是**单独部署的完整成本**，而不是增量成本。

闭包大小在 nixpkgs 社区是一个**正式的评审指标**：给核心软件改包，PR 的自动评审机器人会报告闭包大小的变化；「让闭包增长 200 MiB」的改动通常需要给出充分理由。原因很简单：闭包大小会向所有依赖者传播——firefox 闭包涨 200 MiB，等于每个装了 firefox 的系统、每张用它打的镜像都涨 200 MiB。

理解了观测，优化的套路也就清晰了。nixpkgs 里三件常用的武器：

**输出分离（multiple outputs）**。一个包拆成 `out`、`dev`、`doc`、`man` 等多个输出（参见第 34 章）：`dev` 里放头文件与 `.so` 符号链接、`doc` 里放文档。关键规则是：**运行时引用只指向 `out`**——二进制链接库时引用 `libfoo` 的 `out`，头文件只在编译时被 `dev` 引用。于是安装一个库供别的程序运行，头文件和文档根本不会进闭包。对照传统发行版：装 `libfoo` 通常连着 `libfoo-dev` 是否安装都要单独决策，而依赖关系上没有这种硬边界。

**裁剪符号（strip）**。编译产物里的调试符号动辄占体积一半以上，stdenv 默认对运行产物执行 strip、只把调试信息留在 `debug` 输出（`dontStrip` 可以关闭）。这与 Docker 领域「构建层带调试工具、运行层重新 COPY --from」的多阶段构建异曲同工，但在 Nix 里是包层面的默认行为，而非每个项目各自手搓 Dockerfile。

**语言链接模型**。Go 程序默认静态链接、Rust 常配 musl 静态链接（`pkgsStatic`，参见第 40 章），它们的闭包常常就是二进制自己——一个 hello 闭包不到 2 MiB。C/C++ 程序则必然拖着 glibc（动态装载器本身就是 ld-linux，来自 glibc）。选型时值得记住：闭包大小差距的主因往往不是代码量，而是链接模型。

三件武器的作用面归纳：

| 手段 | 砍掉的是什么 | 详见 |
| --- | --- | --- |
| 输出分离（dev/doc/man） | 头文件、文档——运行闭包不含它们 | 第 34 章 |
| strip | 调试符号 | 第 33 章 |
| 静态链接 / musl（pkgsMusl、pkgsStatic） | glibc 与全部动态库 | 第 40 章 |

顺带一提，`dockerTools` 生成的镜像之所以常常比手工 Dockerfile 小一截，就是因为镜像内容 = 运行闭包，天然排除了构建工具与文档（第 35 章）。

## 17.5 动态链接与 RPATH：自描述的二进制

前几节反复说「二进制里写死了依赖的确切路径」，现在拆开看这个机制。

传统 Linux 上，动态装载器 `ld.so` 按如下顺序解析 `DT_NEEDED` 里的每个 soname（细节以 `man ld.so` 为准）：

1. `DT_RPATH`（旧字段，现已少用）；
2. 环境变量 `LD_LIBRARY_PATH`；
3. `DT_RUNPATH`（现代字段，嵌入在 ELF 的动态段里）；
4. `/etc/ld.so.cache`——由 `ldconfig` 根据 `/etc/ld.so.conf` 扫描生成的全局缓存；
5. 兜底目录 `/lib`、`/usr/lib`。

主流路径是第 4 条：全系统维护一个「soname → 文件路径」的全局缓存。这个设计把**解析依赖的责任交给了环境**：二进制自己不知道库在哪，由所在机器统一裁决。它的脆弱性众所周知——升级 libfoo 后忘了 `ldconfig`、两个包争抢同一个 soname、不同程序需要同一库的不兼容版本，都是经典事故来源。

NixOS 反其道而行：**让每个二进制自己携带答案**。stdenv 构建每个包时（具体动作在第 33 章），会用 `patchelf` 把依赖的确切 store 路径写进 ELF 的 `DT_RUNPATH` 字段。亲手验证一下：

```console
$ nix-shell -p patchelf binutils --run \
  'readelf -d $(realpath $(which hello)) | grep -E "RPATH|RUNPATH"'
  [RUNPATH]        /nix/store/8s0w...-glibc-2.42-12/lib
```

`readelf -d` 打印 ELF 动态段，可以看到 `RUNPATH` 指向 glibc 的 store 路径——精确到哈希，不会有第二种解释。用 `patchelf --print-rpath` 也能看到同样内容。再看装载器实际解析的结果：

```console
$ ldd $(realpath $(which hello))
        linux-vdso.so.1 (0x00007fff...)
        /nix/store/8s0w...-glibc-2.42-12/lib/libc.so.6 (0x00007f...)
        /nix/store/8s0w...-glibc-2.42-12/lib/ld-linux-x86-64.so.2 (0x00007f...)
```

每行都是 store 路径。这样的二进制被称为**自描述（self-contained）的二进制**：把它放进任何一台装了 Nix 的机器，只要闭包在，它就能跑——17.3 节的「搬运闭包即可部署」正是建立在这个机制上。

于是在 NixOS 上，`/etc/ld.so.cache` 的世界里没有 `/nix/store` 的踪影：store 中的库**不注册**进全局缓存，装载器解析 store 程序的依赖时根本不查它。全局缓存的消失带来一个结构性的好处——**不存在「升级某个库影响全系统」这回事**。升级 glibc 只是让新路径出现、旧路径依旧；所有指向旧 glibc 的二进制继续指向旧 glibc，直到它们自己被重新构建。对照传统发行版一次 glibc 升级弄得起不来整个桌面环境的惨案，这不是运气，而是「共享的可变状态」被从设计里移除了。

把两个世界的规则并排放在一起，差异一目了然：

| 维度 | ldconfig 世界 | NixOS（RUNPATH）世界 |
| --- | --- | --- |
| 库的身份 | soname（如 `libfoo.so.1`） | `/nix/store` 哈希路径 |
| 解析依据 | 全局缓存 + 约定目录 | 二进制内嵌的确切路径 |
| 升级一个库 | 全局替换，波及所有引用者 | 新路径并存，旧引用者不动 |
| 同库多版本并存 | 靠 soname 版本号，易冲突 | 天然支持，路径即身份 |
| 排查工具 | `ldconfig -p`、`ldd` | `ldd`、`readelf -d`、`patchelf` |

代价也有：从网上下载的闭源二进制（它们的 RUNPATH 指向 `/usr/lib` 这类不存在于 NixOS 的路径）无法直接运行，社区为此提供了 `nix-ld` 兼载器与各类 `buildFHSEnv` 包装方案，属于进阶话题，可自行查阅 wiki。

顺带认识一下反向操作——给一个现成的二进制改 RPATH。打包第三方闭源软件、或修复一个「外来」二进制时常用：

```console
$ patchelf --print-rpath ./vendored-tool
/lib:/usr/lib
$ patchelf --set-rpath \
    $(nix-build '<nixpkgs>' -A openssl --no-out-link)/lib \
    ./vendored-tool
```

第一行显示这个二进制还带着传统世界的假设（`/lib`、`/usr/lib`，NixOS 上不存在或为空）；第二行把 openssl 的确切 store 路径写进它的 RUNPATH——这正是 stdenv 构建每个包时自动做的事情（第 33 章）的手工版。理解了这一层，那句社区经验之谈的分量就出来了：**在 NixOS 上，「给程序装依赖」往往就是「改它的 RPATH」**——不存在一个全局位置可以往里「装」东西。

最后一个常见疑问：`LD_LIBRARY_PATH` 还管用吗？管用——查找顺序里它优先于 `DT_RUNPATH`，所以应急时可以强制指定库路径。但在 NixOS 上几乎从不需要它，因为每个二进制已经有了正确答案；滥用它反而会破坏「自描述」的确定性，属于应当避免的反模式。真要应急，它长这样：

```console
$ LD_LIBRARY_PATH=/nix/store/…-openssl-3.5.1/lib ./vendored-tool
```

能跑起来，但这个变量**不该**进任何配置或脚本——它绕过了确定性，只配当一次性救急。

## 17.6 闭包思想的影响

闭包不止是 Nix 的内部机制，它重塑了「打包」这个问题本身。三个方向的影响：

**与 Docker 镜像的对照**。两者都在回答「怎么把程序连同环境一起搬走」，抽象却不同：镜像是「分层的 rootfs 快照」，闭包是「可计算的路径集合」。落到实处的差异：镜像层只能整体继承、删文件不减体积；闭包元素是内容寻址的独立对象，跨程序天然去重（所有包共享同一个 glibc 路径，磁盘与传输都只算一份）；镜像依赖 registry 的账号与令牌，闭包可以从任何 substituter、甚至 `ssh://` 直传（第 20 章）。`dockerTools` 把两者接通：按闭包生成镜像层，得到「镜像体积 ≈ 运行闭包体积」的容器（第 35 章）。提前剧睹一眼第 35 章的写法，感受「镜像 = 闭包」的画风：

```nix
# 用闭包直接生成 docker 镜像（示意，完整讲解见第 35 章）
pkgs.dockerTools.buildImage {
  name = "hello";
  config.Cmd = [ "${pkgs.hello}/bin/hello" ];
  # 镜像内容就是 hello 的运行闭包：
  # 没有 apt、没有包管理器、没有多余的层
}
```

**嵌入式与最小系统**。既然闭包完整且可枚举，「固件里应该放哪些文件」就成了一个可计算的问题：取目标程序的闭包，加上内核与 initramfs，即是系统全部内容。思路的延伸包括用 musl libc 替换 glibc 以缩小并简化闭包（`pkgsMusl`，第 40 章），以及把闭包写入定制的 rootfs 镜像。相比手工裁剪 BusyBox 的传统做法，这里「最小系统」有了可复现的依据。

**对其他构建系统的影响**。Bazel 的 runfiles 树、Guix 的 graft、各种「自包含应用目录」方案，都在不同程度上采用了「显式枚举运行时依赖集合」的思路；差别在于 Nix 给集合中每个元素赋予了全局唯一、内容寻址的身份，从而使集合本身可以被哈希、被签名、被任何人重放。第 20 章将看到这个身份体系如何支撑起全球共享的二进制缓存。

值得一提的是，Guix 作为同源的后继项目，把闭包思想推进到了用户级的完整系统；而回到传统世界，闭包也是理解容器、Flatpak、AppImage 这些「自带依赖的打包格式」的最佳参照系——它们都在用各自的方式逼近 Nix 从第一天起就精确拥有的东西：一个可计算、可搬运、可审计的运行时依赖全集。

## 17.7 本章小结

- 闭包（closure）是引用图的传递闭包：从一个 store 对象出发、沿引用关系可达的全部 store 路径，即程序运行所需的完整集合。
- 区分运行闭包与构建闭包：部署只需要前者；后者包含 gcc 等构建工具，规模大得多，`nix-store -qd` 加 `-qR` 可以观察到。
- `nix path-info -r` 与 `nix-store -qR` 是枚举闭包的日常工具；输出里的每个路径都应当能回答「它为什么在这」。
- 闭包是 Nix 的部署单元：`nix-copy-closure` 与 `nix copy --to ssh://` 把闭包整体搬到远端即可运行，无需远端预装任何依赖。
- 对照传统方案：make install 依赖环境兜底、venv 只隔离 Python 层、Docker 靠过度打包换完整性，闭包则做到「恰好完整」。
- 闭包大小是可观测（`nix path-info -Sh`）、可优化的：输出分离、strip、静态链接（musl）是三大常规手段。
- 自描述二进制是闭包可搬运的机制基础：`DT_RUNPATH` 写死依赖的确切 store 路径，NixOS 上没有针对 store 的全局 ldconfig 缓存。
- 闭包思想影响了容器打包（dockerTools）、嵌入式最小系统与各类自包含分发方案。

## 延伸阅读

- 闭包概念详解（nix.dev）：<https://nix.dev/concepts/closures>
- `nix path-info` 手册（nixos.org/manual）：<https://nixos.org/manual/nix/stable/command-ref/nix-path-info>
- `nix copy` 手册：<https://nixos.org/manual/nix/stable/command-ref/nix-copy>
- `nix-copy-closure` 手册：<https://nixos.org/manual/nix/stable/command-ref/nix-copy-closure>
- patchelf 与 RUNPATH（NixOS Wiki）：<https://wiki.nixos.org/wiki/Patchelf>
