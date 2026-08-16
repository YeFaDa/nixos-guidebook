# 第 18 章 Profile、channel 与 generation

> **本章导读**：前面几章讲的 store 对象都是「死的」——构建完就躺在 /nix/store 里。而 `nix-env -i` 装的软件、`nix-channel --update` 更新的包集，状态记录在哪？答案是本章的三件套：profile（用户环境）描述「装了什么」，generation（代）保留「装过什么」，channel（通道）回答「从哪里装」。它们构成了命令式 Nix 的状态管理，也是理解 flakes 所要取代之物的必经之路。

## 18.1 用户环境（profile）是什么

第 17 章的命令式操作 `nix-env -iA nixpkgs.hello` 执行完后，`which hello` 指向 `~/.nix-profile/bin/hello`。`~/.nix-profile` 是什么？层层解剖：

```console
$ readlink ~/.nix-profile
/nix/var/nix/profiles/per-user/yz/profile
$ readlink /nix/var/nix/profiles/per-user/yz/profile
profile-7-link
$ readlink /nix/var/nix/profiles/per-user/yz/profile-7-link
/nix/store/…-user-environment
```

三层符号链，每层各司其职：

- `~/.nix-profile` 是给用户的「把手」，PATH 里加入的是 `~/.nix-profile/bin`；
- `/nix/var/nix/profiles/per-user/yz/profile` 是 Nix 管理的 profile（用户环境）本体所在，root 用户的 profile 在 `/nix/var/nix/profiles/profile`，普通用户在 `per-user/$USER/` 子目录（目录结构与生成时机以官方手册为准，首次使用 nix-env 时会自动建立）；
- `profile-7-link` 中的数字 7 是 generation 编号（见 18.2 节），它最终指向 store 里的一个 `user-environment` 派生。

把整条链画成图（普通用户 yz 的例子）：

```text
/home/yz/.nix-profile ──▶ /nix/var/nix/profiles/per-user/yz/profile
                                   │
                                   ▼
                         profile-7-link ──▶ /nix/store/…-user-environment   （当前）
                         profile-6-link ──▶ /nix/store/…-user-environment   （上一代，保留）
                         profile-5-link ──▶ /nix/store/…-user-environment   （上上代，保留）
```

左端是「把手」，右端是不可变的 store 对象，中间的 `profile-N-link` 序列就是 generation 历史。所谓回滚，就是把链条的第一层重新指向某个旧的 N。

关键认知：**profile 本身就是一个 store 派生**。每次你安装、卸载、升级软件，Nix 并不是去修改某个目录——store 里的对象不可变（第 14 章）——而是构建出一个**新的** `user-environment`，把 profile 符号链指向它。这个派生由 `buildEnv`（依赖合并工具）生成，把所有已装包的 `bin/`、`lib/`、`share/`、`etc/` 以符号链方式合并进一个目录：

```console
$ ls ~/.nix-profile
bin  etc  lib  manifest.nix  share
```

其中 `manifest.nix` 是这个环境的内容清单，记录着装了哪些包、各自的版本与元数据（下面的输出有删节）：

```bash
# ~/.nix-profile/manifest.nix —— 由 nix-env 生成的内容清单（示意）
[
  {
    name = "hello-2.12.1";         # 包名与版本，来自派生的 name
    system = "x86_64-linux";       # 平台，防止跨平台误用
    outputs = [ "out" ];           # 该包有几个输出（第 34 章）
    meta = { … };                  # 描述、主页、许可证等元数据
  }
  # …每个已安装的包一项
]
```

`manifest.nix` 与合并目录还解释了「两个包都提供 `bin/foo`」时会发生什么：buildEnv 会因为文件冲突而构建失败，逼你在装入环境前解决冲突——传统发行版把这种冲突留到安装瞬间才暴露（apt 的 file conflict 报错），Nix 把它前置到了「环境」这个派生的构建时。

「profile 是派生」带来两个直接推论。其一，profile 可回滚——因为旧版本没有消失，只是不再被指向（18.2 节）。其二，profile 是 GC root——只要 profile 指向某个 user-environment，它引用的所有包就不会被垃圾回收（第 19 章）。NixOS 的系统本身也遵循同样机制：`/nix/var/nix/profiles/system` 就是「操作系统级 profile」，由 `nixos-rebuild` 更新（第 24、27 章）。你 PATH 里的这个 profile，则是通过 `/etc/profile.d/nix.sh`（或登录 shell 初始化）注入的。

### 18.1.1 多 profile：一个用户也可以有多套环境

profile 不止一个。用 `-p` 指定任意路径，就能开辟一套独立环境——比如把「工作工具链」与「日常软件」分开：

```console
$ nix-env -p ~/.nix-profiles/work -iA nixpkgs.go
```

`-p` 指定 profile 的存储位置，此后对这个 profile 的所有操作（安装、升级、generation、回滚）都作用于它，机制与默认 profile 一模一样。配套的还有切换命令：

```console
$ nix-env --switch-profile ~/.nix-profiles/work
```

常见的分法：`work` 放项目工具链、`tmp` 放随手实验（坏了整目录删掉重来）、默认 profile 放长期使用的软件。好处是隔离——`tmp` 里的胡乱尝试不会污染日常环境的 generation 历史，垃圾回收（第 19 章）时也可以按 profile 分别取舍。旧习惯在新 CLI 的对应物是 `nix profile --profile <路径>` 参数，但两套体系管理的清单格式不同，依然不要混用（见下节末尾）。

## 18.2 generation：可回滚的历史

上节看到 `profile-7-link`。每次对 profile 的操作（安装、卸载、升级、回滚）都会生成一个**新的 generation（代）**：编号加一、构建新的 user-environment、把 `profile` 链指向新的 `profile-N-link`。旧的 `profile-N-link` 原地保留——这就是 Nix「安装操作皆可撤销」的实现。

三组常用命令：

```console
$ nix-env --list-generations
  18   2026-08-01 09:12:33
  19   2026-08-09 21:40:02
  20   2026-08-15 10:05:47   (current)
```

```console
$ nix-env --rollback
switching from generation 20 to 19
```

```console
$ nix-env --switch-generation 18
switching from generation 19 to 18
```

NixOS 系统代的查看方式略有不同（它存放在 `/nix/var/nix/profiles/system`）：

```console
# nixos-rebuild list-generations
311   2026-07-28 08:11:03
312   2026-08-15 09:40:47   (current)
```

系统代的回滚用 `nixos-rebuild --rollback` 或 `--switch-generation N`，机制与用户 profile 完全一致——毕竟整个 NixOS 就是一个更大的 profile（第 24 章）。两套 generation 还会在第 19 章的垃圾回收里再次同框：它们都是 GC root，都在悄悄占着磁盘。

回滚的代价近乎为零：只是把一条符号链指回旧的 store 路径，不重新下载、不重新构建。代价转移到磁盘上——旧代是 GC root，占着空间（第 19 章讲怎么清）。

一个新手常见现象：`nix-env -iA` 装完包，`which` 却说找不到。原因是当前 shell 的命令缓存里还没有新装的程序——执行 `hash -r`（bash）或 `rehash`（zsh）刷新一下即可，重开终端也行。这不是 Nix 的毛病：所有 shell 都会缓存命令的查找位置，只是 NixOS 上 PATH 干净、目录集中，问题更容易被注意到。

这与 apt/yum 形成鲜明对照：`apt install` 后悔了只能 `apt remove`，而 remove 未必还原到安装前的状态（配置文件、被自动连带升级的依赖都回不去）；Nix 的每一代 profile 都是一个完整快照，`--rollback` 一步回到当时的确切世界。

新 CLI（`nix profile`，需 `nix-command` 特性，参见第 21 章）提供等价能力，且多了历史对比：

| 任务 | 旧 CLI（nix-env） | 新 CLI（nix profile） |
| --- | --- | --- |
| 查看已安装 | `nix-env -q` | `nix profile list` |
| 查看变更历史 | 无直接等价 | `nix profile history` |
| 回滚 | `nix-env --rollback` | `nix profile rollback` |
| 删除旧版本 | `nix-env --delete-generations old` | `nix profile garbage-collect` |

`nix profile history` 会列出每代之间安装项的版本变化（输出示意）：

```console
$ nix profile history
Version 7 (2026-08-12) -> 8 (2026-08-15):
  flake:nixpkgs#hello: 2.12.0 -> 2.12.1
```

它回答的是「这一代与上一代之间，谁变了」——升级后想确认「刚才那次操作到底动了什么」，看它比对着 `list` 的长清单肉眼比对高效得多。

一个容易踩的坑：新旧 CLI 的 profile 互不兼容。`nix profile` 使用的 profile 位于 `~/.local/state/nix/profiles/`（XDG 状态目录），数据格式与 `nix-env` 的 `manifest.nix` 不同。请选定一种工作流坚持使用，不要对同一个 profile 混用两套命令。

## 18.3 nix-env 全用法学

`nix-env` 是命令式安装的主力，常用动作一表看清（示例均以 channel 名 `nixpkgs` 为准；NixOS 上根用户的 channel 名为 `nixos`，下同）：

```console
$ nix-env -iA nixpkgs.hello
```

按**属性名（attribute）**精确安装。`-A` 后面是 nixpkgs 属性树里的路径，与你 在 search.nixos.org 上看到的包名一致。

```console
$ nix-env -i hello
```

按**包名**模糊安装。不推荐，原因见下。

```console
$ nix-env -e hello
```

卸载（e = erase），随后生成新一代 profile。

```console
$ nix-env -u
```

升级 profile 中所有已装包（u = upgrade），在**当前 channel 快照**里找同名包的新版本。加 `--upgrade` 全称等价；只想升级某个包用 `nix-env -u hello`。

升级的坑在于「跳得太远」：`-u` 会升到 channel 里同名包的最新版本，**包括大版本**。如果你的脚本依赖 Python 3.12 的行为，而 channel 已推进到 3.13，一次 `nix-env -u` 之后解释器就悄无声息地换了一代。升级前先预览变化：

```console
$ nix-env -q --compare-versions | grep -v ' = '
hello-2.12.0  <  2.12.1
```

输出里 `<` 表示本地落后于 channel 里的版本（`grep -v ' = '` 过滤掉已同步的行）。对大版本敏感的机器，逐包升级比无差别的 `nix-env -u` 稳妥得多。

```console
$ nix-env -q
```

查询已安装的包；`nix-env -qa`（`--query --available`）则列出当前 channel 里**所有可安装**的包。两个查询各来一次，感受差别：

```console
$ nix-env -q
hello-2.12.1
ripgrep-14.1.0
$ nix-env -qa | wc -l
128000+
```

`-q` 只读 manifest，瞬间返回；`-qa` 要把整个 nixpkgs 求值一遍，条目以十万计（数字随快照浮动），需要几十秒。日常找包的更好入口是 <https://search.nixos.org>——它标出每个包的属性路径，正是 `-iA` 要用的那个键。

```console
$ nix-env --set nixpkgs.hello
```

把 profile **整个替换**为这一个包（清掉其他安装项），适合「这个 profile 只干一件事」的场景。

### 为什么 `-iA` 优于 `-i`

`-i`（按名安装）匹配的是派生的 name 字段（形如 `hello-2.12.1`，名称与版本连写），匹配到多个时 nix-env 会自作主张挑版本号最高的那个。这套语义埋着两类坑：

**坑一：名字对不上。** 属性名叫 `python3`，而多个 Python 相关派生的 name 是 `python3-3.13.x`、`python3-minimal-…`；你想装的 `python3Packages.requests` 在属性树的子目录里，根本不存在一个叫这个名字的派生 name。`nix-env -i requests` 找不到任何东西，`nix-env -iA nixpkgs.python3Packages.requests` 一步到位：

```console
$ nix-env -i requests
error: selector 'requests' matched no derivations
$ nix-env -iA nixpkgs.python3Packages.requests
(replacing 'requests-2.32.3')
installing 'requests-2.32.3'
```

**坑二：撞名歧义。** nixpkgs 里常有名称相近、或 name 相同但语义不同的包（不同打包方式、不同变体共用一个 name）。按名安装时 nix-env 静默选择「版本最高」的那个，选错了我行我素；按属性名安装时，属性路径是唯一键，装的就是属性树上那个确切的位置。

一句话总结：属性名是 nixpkgs 这门「语言」里的标识符，包名只是展示用的字符串——编程时当然用标识符。另一个细节：`-iA` 后面的第一段是 channel 名，不必非叫 `nixpkgs`——`nix-env -iA nixos.hello` 在 NixOS 上同样成立（系统通道名叫 nixos）；订阅了多个通道时，按名字各取所需。

## 18.4 channel 机制

### 18.4.1 channel 是什么

channel（通道）回答「`nixpkgs` 从哪来」。它本质上是一个 URL，指向某个 nixpkgs 仓库的**快照**：Nix 官方在 channels.nixos.org 上为每个通道维护一个「最新已验证快照」，`nix-channel --update` 时下载该快照的表达式 tar 包，解压为本地副本。此后 `<nixpkgs>` 求值用的就是这个副本，直到下次 update。

update 的落点可以亲眼看一下（普通用户，布局示意）：

```text
~/.nix/defexpr/
└── channels/            # 符号链，指向 Nix 管理的 channel profile
    └── nixpkgs/         # 你订阅的通道快照住在这里
        ├── default.nix
        ├── pkgs/        # 一份完整的 nixpkgs 表达式树
        ├── lib/
        └── …
```

它本质上就是 nixpkgs 某个 git 提交的快照——这再次印证 18.5 节要说的事：channel 给你的是「跟着官方指针走的版本」，不是「你自己选定的版本」。第 19 章还会遇到这个目录的另一个身份：channel 是 profile，自然也是 GC root。

日常操作四件套：

```console
$ nix-channel --list
nixpkgs https://channels.nixos.org/nixpkgs-unstable
```

列出已订阅通道（名字 URL 成对）。

```console
$ nix-channel --add https://channels.nixos.org/nixos-26.05 nixpkgs
```

订阅新通道。名字最好用 `nixpkgs`，这样 `<nixpkgs>` 解析直接命中；NixOS 上系统级通道由 `nixos-rebuild --upgrade` 维护，名字叫 `nixos`。

```console
$ nix-channel --update
unpacking channels...
```

拉取各通道的最新快照。注意：这一步之后 `nix-env -iA` 装到的就是**新世界**，但已安装的包不会自动升级——升级是 `nix-env -u` 的事。两步分离，意味着「包集更新」与「系统变更」可以独立决策。实践中推荐的节奏：先 update、观察几天（或在别的机器先试），再升级 profile——而 channel 自己的 `--rollback`（见下）为这段观察期提供了退路。

```console
$ nix-channel --rollback
```

很少人知道：channel 本身也是 profile，也有 generation。刚 update 完发现新版有坑，一条命令退回上一个快照——这是滚动升级的安全网。

### 18.4.2 NIX_PATH 与 `<nixpkgs>` 的查找规则

`nix-env -iA nixpkgs.hello` 里的 `nixpkgs`、代码里写的 `<nixpkgs>`，靠 NIX_PATH 环境变量解析。NIX_PATH 是一组冒号分隔的 `名字=路径` 映射：

```console
$ echo $NIX_PATH
nixpkgs=/nix/var/nix/profiles/per-user/root/channels/nixos:/nix/var/nix/profiles/per-user/root/channels
```

（输出示意；NixOS 上默认值由 `nix.nixPath` 选项生成，具体条目以 NixOS 手册为准。）

`<nixpkgs>` 的查找顺序可概括为三步：

1. NIX_PATH 中名为 `nixpkgs` 的显式条目（第一个命中生效）；
2. 用户目录 `~/.nix/defexpr/` 下的 channels 聚合表达式——普通用户 `nix-channel --update` 的产物登记在这里；
3. 命令行 `-I nixpkgs=/some/path` 的临时覆盖（优先级最高，常用于临时锁定某个 checkout）。

验证解析结果：

```console
$ nix-instantiate --eval -E '<nixpkgs>'
/nix/var/nix/profiles/per-user/root/channels/nixos
```

`-I` 的临时覆盖值得单独一提——这是前 flake 时代「钉住某个 nixpkgs 版本」的主流手段：

```console
$ nix-build -I nixpkgs=/home/yz/nixpkgs '<nixpkgs>' -A hello
```

把 nixpkgs 克隆到本地、checkout 到已知提交，此后所有带 `-I` 的构建都基于这份代码。缺点也明显：锁定状态存在于命令行而不是代码里，换台机器、换个终端就丢了；团队成员之间靠口头约定「大家都 checkout 到某提交」，毫无强制力（第 21 章的 flake.lock 正是为此而生）。

这套「环境变量全局状态」正是 flakes 要消灭的东西之一：同一台机器上不同 shell 的 NIX_PATH 可能不同，`<nixpkgs>` 指向哪里无法写进代码（第 21 章）。在 flakes 仍与旧机制并存的今天，理解 NIX_PATH 依然是排错的基本功。

## 18.5 通道家族：rolling 还是锁定

官方通道是一个家族，各有来历（命名与提升流程的权威描述参见第 41 章与 NixOS 手册）：

| 通道 | 内容 | 适合谁 |
| --- | --- | --- |
| `nixos-26.05` | 当前稳定版（release-26.05 分支 + 回移的修复） | 生产机、求稳的桌面 |
| `nixos-26.05-small` | 同上，但构建与测试任务更少、推进更快 | 接受略少测试换取更快更新的服务器 |
| `nixos-unstable` | master 分支通过 NixOS 测试集后的快照 | 追新桌面、开发机 |
| `nixos-unstable-small` | unstable 的高速版 | 同上 |
| `nixpkgs-unstable` | master 分支快照，不含 NixOS 集成测试 | 非 NixOS 系统上的 Nix 用户（Linux/macOS） |

这些通道都由 Hydra 构建农场（第 41 章）产出：`release-26.05` 分支上的每次提交都经过整套构建与测试，全绿之后通道指针才前进。`-small` 后缀的含义是「等待的构建/测试任务更少」——同样的源代码，更快到达，代价是部分平台与测试未跑完就发布。因此 small 与非 small 的内容同源，差异只在「新鲜度」与「验证完成度」的权衡；忘了自己用哪个，`nix-channel --list` 一看便知。半年一次的发布节奏（25.11 → 26.05 → 26.11）意味着 `nixos-26.05` 会持续收到安全更新直到生命周期结束，之后需要手动换到新通道。

**rolling 还是锁定**，是一个工程决策：

- channel 是**滚动的**：`nix-channel --update` 之后，`nix-env -u` 装到的是「今天的最新」，明天再执行可能就不一样。这对探索很友好，对可复现是灾难——你的 CI 上周三还是好的，今天同一命令装出了不同版本。
- 解决办法是**锁定**：要么不用 channel、改用 flake 的 `flake.lock`（第 21 章），要么用 `-I nixpkgs=...` 钉住某个本地 checkout / tarball。社区共识：任何要长期维护的东西（项目环境、CI、团队配置）都应当锁定；channel 适合「个人沙盒快速尝鲜」。

| 选择 | 典型场景 | 优点 | 风险 |
| --- | --- | --- | --- |
| rolling（unstable） | 个人桌面、尝鲜 | 及时用上新版本 | 每次更新都是一次冒险 |
| stable（nixos-26.05） | 服务器、日常主力 | 半年打磨 + 安全回移 | 软件略旧 |
| 锁定（flake.lock 等） | 项目、CI、团队 | 完全可复现 | 升级需要显式动作 |

三个选项并不互斥：常见组合是「系统走 stable、项目走 lock、沙盒走 unstable」，同一台机器上三套世界并存、互不干扰——这正是 store 模型（第 14 章）给的自由。

顺带回答一个常见疑问：「我到底站在哪个通道上？」两条命令说清：

```console
$ nix-channel --list
nixos https://channels.nixos.org/nixos-26.05
$ nixos-version
26.05.1234.abcdef (Yarara)
```

`nixos-version` 的输出由小版本号与 nixpkgs 的 git 提交拼成——也就是说，「26.05」只是大版本标签，同一通道内的两次 `--update` 依然是两个不同的世界。channel 给的是「版本区间的承诺」，不是「精确版本的承诺」，这句话值得在心里放一整章。

## 18.6 Flakes 如何取代这一切

本章的三件套各有各的问题：profile 是命令式的（装了什么查 manifest，不在代码里）；channel 是漂移的（update 之后世界就变了）；NIX_PATH 是全局的（代码不知道自己用的是哪个 nixpkgs）。flakes（第 21 章）对三者给出统一答案——**声明式输入 + 哈希锁定**。

flake 的输入写在 `flake.nix` 里，例如 `nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05"`；第一次求值时，Nix 把这个输入的确切修订（commit 哈希）、tarball 哈希写进 `flake.lock`：

```bash
# flake.lock（节选）——每个输入的精确坐标都被锁定
{
  "nodes": {
    "nixpkgs": {
      "locked": {
        "lastModified": 1769000000,      # 快照时间戳
        "rev": "a1b2c3d4e5f6…",          # 精确到 nixpkgs 的 git 提交
        "type": "github"
      }
    }
  }
}
```

从此构建只认 lock 文件：同一份 `flake.nix` + `flake.lock`，今天构建、明年构建、同事机器上构建，得到的 nixpkgs 完全相同——channel 的漂移问题被结构性消灭。想升级，显式执行 `nix flake update` 并把 lock 的变化提交进版本库，升级这件事第一次变得**可审计**：diff 一下 lock 文件，就能看到 nixpkgs 从哪个提交挪到了哪个提交。

三代工作流对照：

| 维度 | channel + nix-env | nix profile | flake（声明式） |
| --- | --- | --- | --- |
| 安装 | `nix-env -iA nixpkgs.hello` | `nix profile install nixpkgs#hello` | 写进 flake / 配置后一次构建 |
| nixpkgs 来源 | NIX_PATH 全局解析 | 安装时经 registry 解析并锁定为路径 | `flake.lock` 精确锁定 |
| 可复现 | 否（随 update 漂移） | 装完那一刻锁定，升级时漂移 | 是 |
| 依赖说明 | 散落各处 | profile manifest | 代码即文档 |
| 回滚 | generation | generation | generation + git revert |

值得强调：`nix profile install nixpkgs#hello` 里 nixpkgs 经**全局 flake registry** 解析——安装的那一刻它确实锁定了具体 store 路径，但 `nix profile upgrade` 时会重新解析到最新，仍属「命令式 + 半锁定」，介于两个时代之间。真正声明式的终点是：把需要的包写进 NixOS 配置（第 24 章）或 home-manager，让「装了什么」成为代码的输出而非操作的历史。

从 channel 工作流迁移到 flakes 时，值得逐项自检：

- `nix-env -iA` 装过的东西，逐个转为配置声明（NixOS 的 `environment.systemPackages`，或 home-manager 的 `home.packages`），否则迁移后会「莫名消失」；
- shell 里裸写的 `<nixpkgs>` 与对 `$NIX_PATH` 的依赖，改为显式的 flake 输入；
- 依赖 `nix-channel --rollback` 的应急习惯，换成「把 flake.lock 的变化提交进 git，出事就 revert」——回滚单位从「上次 update」细化到「每次提交」；
- 团队共享的 nixpkgs 坐标，从「大家都订阅同一个通道」变成「大家都用仓库里那份 lock 文件」，对齐第一次有了强制力。

新项目是否用 flakes？2026 年的答案是：用。锁定、无全局状态、输入可组合这三点收益，对任何要长期维护的环境都是硬需求；代价是学习一套新概念，第 21 章将完整展开。

最后留一句关于 NIX_PATH 的话：官方已明确它是被 flakes 取代的遗留机制，新代码不要再依赖 `<nixpkgs>` 与 `$NIX_PATH`。但正如本章所见，`nix-env`、channel、profile 这套旧世界的机器仍在大量机器上运转，理解它们的原理，是读懂存量配置与排查「为什么这里求值出的 nixpkgs 和我想的不一样」的基本功。

## 18.7 本章小结

- profile（用户环境）本身是 store 里的派生：`~/.nix-profile` 经多层符号链指向某个 `user-environment`，其中 `manifest.nix` 记录内容清单。
- 每次 nix-env 操作生成新的 generation；旧代保留为 `profile-N-link`，回滚只是改符号链，近乎零成本。
- 新旧 CLI 各有 profile 体系（`~/.local/state/nix/profiles` 与 `/nix/var/nix/profiles`），不要混用同一 profile。
- `nix-env` 的核心动作：`-iA`（按属性装，首选）、`-e`（卸载）、`-u`（升级）、`-q`/`-qa`（查询）、`--set`（整体替换）。
- 按名安装（`-i`）匹配派生 name、撞名时静默选最高版本，歧义与失配是常态；属性名才是唯一键。
- channel 是 nixpkgs 快照的订阅机制，本身也是可回滚的 profile；`<nixpkgs>` 经 NIX_PATH 解析。
- 通道家族覆盖稳定（nixos-26.05）到滚动（nixos-unstable），生产求稳、开发追新、项目一律锁定。
- flakes 用 `flake.lock` 把输入钉到精确提交，消除漂移与全局状态，是新旧工作的分水岭（第 21 章）。

## 延伸阅读

- `nix-env` 手册：<https://nixos.org/manual/nix/stable/command-ref/nix-env>
- `nix-channel` 手册：<https://nixos.org/manual/nix/stable/command-ref/nix-channel>
- `nix profile` 手册（新 CLI）：<https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-profile>
- NixOS Wiki：Nix channels：<https://wiki.nixos.org/wiki/Nix_channels>
- nix.dev：Flakes 概念：<https://nix.dev/concepts/flakes>
- Nix 手册：环境变量（NIX_PATH 等）：<https://nixos.org/manual/nix/stable/command-ref/env-vars>
