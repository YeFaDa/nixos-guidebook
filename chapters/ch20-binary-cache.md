# 第 20 章 二进制缓存与 substituter 生态

> **本章导读**：Nix 的构建是确定性的：输入完全相同，输出就完全相同。这带来一个惊人的推论——只要世界上任何一个人构建过某个路径，你就可以直接下载他的结果，而不必自己编译。承载这个承诺的基础设施是二进制缓存（binary cache）与它的服务端 substituter。本章讲清「下载替代构建」的原理与安全模型、缓存协议的内部结构、自建缓存的方法，以及「为什么我的包没命中缓存」这一高频问题。

## 20.1 为什么「别人构建过你就能下载」

第 13 章讲过，派生的哈希由全部输入决定（输入寻址，input addressing，参见第 15 章）：

**哈希相同 ⟺ 输入完全相同。**

再叠加第 16 章的结论：构建在沙箱中进行、工具链固定、结果可复现。于是：

**输入完全相同 ⟹ 输出可互换。**

如果我的机器上 `/nix/store/q5r7…-hello-2.12.1` 和构建农场上的是同一个派生哈希，那么农场构建出的那个 hello——连同它闭包里的每个路径（第 17 章）——拿来就能用：路径由内容决定（第 15 章），内容一致则路径一致，我的系统引用它毫无违和。「构建」与「下载」就此成为可互换的实现细节：Nix 先问你配置的 substituter「这个路径你有吗」，有就下载，没有才动手构建。这也是为什么 `nix-env -iA nixpkgs.firefox` 通常几十秒完成——你没有编译 firefox，全球共享的缓存替你编译过了。

两条路线的成本对照（firefox 量级的项目）：

| 路线 | 耗时 | 结果 |
| --- | --- | --- |
| 全量本地构建 | 以小时计（整套 C++/Rust 工具链与依赖） | `/nix/store/…-firefox-147.0` |
| 从缓存下载 | 一两分钟 | 同一个 `/nix/store/…-firefox-147.0` |

注意最后一行：两条路线殊途同归，产出**完全相同**的路径与哈希。「自己构建」与「直接下载」生产同一种商品——这是整个 substituter 机制成立的前提，也是它最反直觉的地方：传统直觉里「自己编译的」和「别人给的」是两种东西，在 Nix 里它们是同一种。

但这里有个必须严肃对待的问题：**凭什么敢用别人构建的二进制？** apt/yum 的世界里，你信任的是发行版仓库：Release 索引经 GPG 签名，包的完整性由仓库方背书——信任的对象是「这个源」。Nix 的信任模型颗粒更细，对象是**密钥**而非服务器：

- 每个 store 路径的元数据（narinfo，见 20.4 节）携带构建方的**签名**；
- 你在配置里声明信任哪些**公钥**（`trusted-public-keys`）；
- 下载前先验签：签名不来自可信密钥的内容，一概不用，无论它来自哪个服务器。

推论：服务器本身不需要被信任。你可以把 substituter 指向任何镜像、任何 CDN、同事随手起的 HTTP 服务——只要路径上的 narinfo 带着你的密钥认可的有效签名，内容就是安全的；恶意服务器最多让你「下载不到」（拒绝服务），无法让你「下载到坏东西」。这个「不信任基础设施、只信任签名」的模型，与 TLS 证书体系的思路一脉相承，但粒度细化到了单个 store 路径。

两点补充让这个模型更完整。其一，**为什么敢假设输出确定**：第 16 章的沙箱构建隔离了网络、时钟与构建脚本之外的一切，Hydra 还会对部分包做重复构建校验。但确定性是工程实践而非数学定理——极端情况下（如构建代码引入了随机性）两个「相同输入」可能产出不同字节，这正是签名（信任构建方）依然必要的原因。其二，**fixed-output 派生**（源码 tarball 的抓取，第 15 章）的输出哈希事先声明，任何人下载后都能本地重算验证，因此这类路径对 substituter 的信任要求最低。

术语就此澄清：substituter（替换器）指「替代本地构建的二进制来源」——它可以是专门的缓存服务（binary cache），也可以是一台开着 store 服务的普通机器（20.5.2 节）。日常语境两者常混称「缓存」，准确的理解是：substituter 是角色，binary cache 是它的主流实现。

## 20.2 cache.nixos.org：全球公共缓存

NixOS 官方运营的 `https://cache.nixos.org` 是默认 substituter，背后是 Hydra 构建农场（第 41 章）：nixpkgs 的每一次提交都会被 Hydra 按平台批量构建，成功产物自动推送进缓存。对使用者完全透明：不需要账号、不需要登录，匿名 HTTP 即可——权限控制发生在「谁能为缓存签名」那一侧（20.3 节），而不是「谁能下载」这一侧。凡是 Hydra 构建过的东西——稳定通道、unstable、绝大多数 nixpkgs 里的包——你都能从这里命中。

它命中率为什么高？关键在于第 18 章讲过的机制：**channel 是全社区共享的快照**。当 `nixos-26.05` 通道前进到某个提交时，全球所有订阅者拿到的都是同一个提交、同一批派生哈希。你 `nix-env -iA` 时要求的路径，与昨天几万名用户要求的路径一字不差——人人为彼此预热了缓存。对照传统发行版：Ubuntu 的镜像同样高效，但它的二进制依赖「版本号 + 架构」这样的粗粒度标识；Nix 的命中单位是精确到补丁级别的派生哈希，连「我给 hello 打了个自己的补丁」这种路径级差异都会诚实地变成缓存未命中（见 20.6 节）。

从服务器视角看还有一层优雅：缓存不需要理解「包」的概念，它只是一张从哈希到字节的大表。同一个 glibc 路径被 firefox、hello、你的项目各自引用，在缓存里只存一份；不同架构、不同渠道的路径天然按哈希区分。**全局去重不需要任何人规划，它是内容寻址的自然结果**——对照 Docker 生态近年才补课的镜像层去重，以及 apt/yum 各镜像站各自承担的完整同步负担。

基础设施层面，cache.nixos.org 前端是 CDN、后端是对象存储——narinfo 与 NAR 都是纯静态文件（20.4 节会解释为什么可以这么简单），因此服务的扩展成本极低，全球开发者的并发下载才成为可能。对网络条件欠佳的地区，社区镜像站（如国内高校镜像站提供的 cache.nixos.org 镜像）可以显著加速——把 substituters 指过去即可，镜像无法作恶，这正是「信任密钥而非服务器」模型送的红利。

两个边界要有预期：其一，缓存覆盖的是 Hydra **构建过**的内容——某个包在某个平台上被标记 `broken`、或最近才改过还没构建完，就不会命中；其二，缓存里的内容同样有保留策略，极旧或无引用的路径可能被清理（罕见，遇到了按 20.6 节的思路本地构建即可）。

覆盖面的另一面是**平台矩阵**：x86_64-linux 与 aarch64-linux 的 nixpkgs 全量任务（以及相当一部分 aarch64-darwin）都会推入缓存；冷门平台或非默认 jobset 的包则未必。判断一个包「应不应该命中」，最直接的办法是看它在 <https://hydra.nixos.org> 上的构建状态（第 41 章）——被标记为失败或从未构建的，本地编译是唯一出路。这也澄清了一个常见误会：「NixOS 的软件比别的发行版少」——多数时候不是没有包，而是那条具体的构建路径此刻不可用，换个通道快照往往就恢复了。

## 20.3 配置：substituters 与信任密钥

### 20.3.1 nix.conf 基本写法

```bash
# /etc/nix/nix.conf —— 守护进程级配置（多用户安装的权威配置位）
# substituters：按顺序查询的二进制缓存列表
substituters = https://cache.nixos.org https://nix-community.cachix.org
# trusted-public-keys：声明信任的签名公钥（name:base64 形式）
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= nix-community.cachix.org-1:mB9FShbq+HWdKNkH6Bm/y05FEG5wtSBBMOXQtrzzhTw=
```

（示例中 nix-community 的公钥以官方发布为准。）查询顺序即 `substituters` 的书写顺序：对每个需要的路径，Nix 依次向各缓存询问 narinfo，先答者先用——把最快、最可能命中的放前面，官方缓存兜底放后面。

一个实用习惯：**任何 substituters 列表都以 cache.nixos.org 结尾**。它承担兜底职责——团队缓存里没有的依赖自动回落到官方缓存，而不是触发一次本不必要的本地编译。反过来，把一个命中率为零的缓存放在第一位，每次构建都会先向它白问一轮 narinfo，平添几十毫秒乘以路径数量的延迟；列表顺序是性能项，不只是权限项。

### 20.3.2 NixOS 上的 nix.settings 与 trusted-users

NixOS 上不要手改 nix.conf，用声明式选项：

```nix
{
  nix.settings = {
    substituters = [
      "https://cache.nixos.org"              # 官方缓存永远兜底
      "https://nix-community.cachix.org"     # 社区缓存在前：更可能命中的放前面
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FShbq+HWdKNkH6Bm/y05FEG5wtSBBMOXQtrzzhTw="
    ];
    trusted-users = [ "root" "alice" ];      # 关键：哪些用户有权引入新的可信缓存
  };
}
```

`trusted-users` 为什么必须存在？想一想威胁模型：`substituters` 与 `trusted-public-keys` 决定了「哪些二进制会以 root 身份被安装运行」。如果任何普通用户都能给自己加一个缓存和配套公钥，恶意用户就能让 daemon 拉取并运行他签名的任意构建产物。因此规则是：**普通用户可以往自己的 `extra-substituters` 里加缓存，但只有当路径同时带有受信任密钥的签名时才会被采用**；想让某个第三方缓存的自有密钥生效，要么 root 把密钥加进全局 `trusted-public-keys`，要么把该用户列入 `trusted-users` 让他自己声明。顺带一提：root 默认在 trusted-users 名单里——这是「root 拥有这台机器」的又一种表述；名单越长，能以 root 身份引入二进制的账户越多，多用户主机上应保持名单最小。

顺带理清配置的落点与优先级：命令行 `--option` 最高，其后是环境变量、用户级 `~/.config/nix/nix.conf`、系统级 `/etc/nix/nix.conf`（多用户安装下守护进程读的权威配置）。层级的意义在于：`trusted-*` 类选项只认系统级配置——普通用户在自己文件里写 `trusted-public-keys` 是无效的，这正是上述安全模型在配置机制上的落实。NixOS 用户务必只走 `nix.settings` 声明式配置，手改 `/etc/nix/nix.conf` 会在下次激活（第 26 章）时被覆盖。

### 20.3.3 flake 里声明缓存：nixConfig

项目作者可以把「本项目该用哪个缓存」写进 flake，克隆者开箱即命中：

```nix
{
  description = "示例项目";

  # nixConfig 只在用户信任此 flake 时生效（见下）
  nixConfig = {
    substituters = [ "https://myproject.cachix.org" ];   # 本项目的私有缓存
    trusted-public-keys = [ "myproject.cachix.org-1:AAAA…" ];
  };

  outputs = { self, nixpkgs }: { … };
}
```

信任门槛是必须的——否则克隆一个恶意仓库就等于自动信任它的缓存与密钥，前面的安全模型就漏了。默认行为是忽略并给出警告；显式放行的方式是给命令加 `--accept-flake-config`，或把密钥、用户按 20.3.2 的方式加入信任配置。CI 环境通常对固定仓库开启前者（第 41 章）。团队内部的常见折衷：把 `--accept-flake-config` 写进 CI 的 Nix 配置（信任的是自家仓库与 CI 的组合），个人机器默认拒绝、遇到可信项目再手动放行——信任决策始终留在人的手里。

## 20.4 缓存协议内部：NAR 与 narinfo

### 20.4.1 NAR：store 对象的规范归档

要在 HTTP 上分发 store 对象，需要一个归档格式，而且这个格式必须**规范化（canonical）**：同一个 store 对象无论在谁的机器上、什么时候打包，字节序列必须完全一致——否则第 15 章的 NAR 哈希就无从谈起。Nix 归档格式 NAR（Nix ARchive）为此而生：它规定了目录、普通文件、可执行文件、符号链接四种结点的唯一序列化方式（不打包 mtime 等不稳定元数据，可执行位则保留）。给一个 store 路径打包成 NAR、取 SHA-256，就是 narinfo 里的 NarHash——下载后重算对比即可证明「拿到的与登记的是同一个对象」。NAR 的结点树概念上长这样：

```text
directory "…-hello-2.12.1"
├── directory "bin"
│   └── executable "hello"      # 记录内容与可执行位，没有 mtime
└── directory "share" …
```

每个结点的编码方式唯一确定，同一对象永远得出同一字节流。

与 tar 相比，NAR 牺牲了通用性换来**唯一性**：tar 在路径排序、元数据、格式上有无数自由度，同一个目录能打出十种不同的字节序列；NAR 对每种结点只允许一种写法，因此「NAR 哈希相同」是内容相同的强证明。这让它得以充当通用货币——两个 store 对象只要 NAR 哈希一致，就可以互相替代、互相校验，无论出自谁的构建（20.7 节的内容寻址派生把这一点用到了极致）。

### 20.4.2 narinfo：逐字段解读

缓存对外的「索引单元」是 narinfo 文件：每个 store 路径对应一个 `<哈希>.narinfo`，内容是纯文本（示意为 hello 的条目，字段值有删节）：

```text
StorePath: /nix/store/q5r7…-hello-2.12.1       # 这个条目对应的 store 路径
URL: nar/8s0w….nar.xz                          # NAR 归档的实际下载地址（相对路径）
Compression: xz                                # 归档压缩算法（xz 为主流，新缓存可用 zstd）
FileHash: sha256:3xK9…                         # 压缩包自身的哈希，防传输损坏
FileSize: 202960                               # 压缩包字节数
NarHash: sha256:1aBc…                          # 解压后 NAR 的哈希——与第 15 章的路径哈希呼应
NarSize: 1105920                               # 解压后 NAR 的字节数
References: 8s0w…-glibc-2.42-12                # 引用（闭包边表，第 17 章），空格分隔，
                                                # 写的是 /nix/store/ 后的「尾巴」以省空间
Deriver: mk3p…-hello-2.12.1.drv                # 派生它的 .drv 路径（信息性字段）
System: x86_64-linux                           # 构建平台
Sig: cache.nixos.org-1:6NCHdD59…               # 签名：对上述关键信息的指纹签名
```

几个字段值得多看一眼：`References` 让缓存具备**闭包感知**——Nix 拿到一个 narinfo 就知道还缺哪些路径，递归查询直到第 17 章的闭包补齐，再统一下载；`Sig` 是安全模型的落点，签名覆盖的是 StorePath、NarHash、References 等关键信息的规范化指纹，篡改任何一处都会让验签失败。

顺带解释 URL 里的「哈希」：narinfo 文件名是 store 路径的**哈希部分**——`/nix/store/<哈希>-<名字>` 中那 32 个字符（base32 小写、无填充，第 15 章）。服务器因此不需要任何索引数据库：把请求的哈希直接拼成文件名查磁盘即可，整棵缓存就是一堆静态文件，可以放在任何对象存储或 CDN 后面运行。自建缓存的实现因此都出奇地简单（见 20.5.4 节）。

完整的取回流程可以概括为五步：

1. 对需要的 store 路径，向 substituters 依次请求 `/<哈希>.narinfo`；
2. 拿到后先**验签**：Sig 必须出自某个 `trusted-public-keys` 里的密钥；
3. 按 References 递归获取闭包中全部路径的 narinfo（重复 1-2）；
4. 下载 NAR、校验 FileHash/NarHash、解包到 `/nix/store` 并登记数据库；
5. 仍缺（任何缓存都没有）的路径才进入本地构建（第 16 章）。

校验失败的行为值得强调：任何一步对不上——签名不可信、NarHash 不符、解包内容与登记不符——Nix 都会拒绝使用，转而询问下一个 substituter 或落入本地构建。失败是安全的：宁可慢，不可错。

用 curl 可以亲手摸一下线上缓存：

```console
$ curl -s https://cache.nixos.org/q5r7….narinfo | head -4
StorePath: /nix/store/q5r7…-hello-2.12.1
URL: nar/8s0w….nar.xz
Compression: xz
Sig: cache.nixos.org-1:6NCHdD59…
```

换一个依赖大户，看 References 字段的分量（输出示意、有删节）：

```console
$ curl -s https://cache.nixos.org/c4t1….narinfo | grep References
References: 8s0w…-glibc-2.42-12 k2m9…-libidn2-2.3.7 …
```

这是 curl 的条目，References 列出了它的全部直接依赖。Nix 拿着这份清单递归查询，拼出第 17 章的闭包再统一下载——一个 narinfo 就是一段闭包边表，缓存因此不需要理解「包」与「依赖」的语义，一切都被压平成了路径与哈希。

## 20.5 自建与私有缓存

只要会写文件、能起 HTTP 服务，就能当 substituter。按投入从低到高三档。

### 20.5.1 本地目录缓存：nix copy --to file://

```console
$ nix copy --to file:///tmp/my-cache nixpkgs#hello
```

`nix copy` 把闭包以缓存协议（narinfo + NAR 文件）写入目标；`file://` 目标就是一个目录，起个 `python -m http.server` 就能用。但要给别人用，**必须签名**——否则别人（包括未来的你，在另一台机器上）的 Nix 会拒绝这些无签名的条目。签名三步：

```console
$ nix key generate-secret-key --key-name mycache
```

在当前目录生成 `mycache.secret`（私钥，保管好，只放在推送方）。私钥一旦泄露，任何拿到它的人都能以你的名义签名；轮换密钥意味着换掉 `名字:` 前缀并重新推送全部内容，成本不低——所以从第一天起就把它当密码对待。

```console
$ nix key convert-secret-to-public < mycache.secret > mycache.pub
$ cat mycache.pub
mycache:6NCHdD59xxxx…
```

从私钥导出公钥，内容形如 `名字:base64`，把它填进使用方的 `trusted-public-keys`。

公私钥的分工值得记住：**私钥签内容，公钥进配置**——使用方只需要公钥，永远不接触秘密；推送方持有私钥。这与 TLS 证书、SSH 的 authorized_keys 是同一个形状。最后让推送方知道私钥在哪，此后 `nix copy` 会自动签名：

```bash
# 推送方的 nix.conf：声明私钥文件，nix copy 据此为每个路径生成 Sig
secret-key-files = /home/you/keys/mycache.secret
```

然后在任何一台机器上把它当 substituter 用：

```bash
# 使用方的 nix.conf（或 NixOS 的 nix.settings）
substituters = file:///tmp/my-cache https://cache.nixos.org
trusted-public-keys = mycache:6NCHdD59xxxx… cache.nixos.org-1:…
```

`file://` 前缀指向本地目录。这套「推送、签名、验签、命中」的流程不涉及任何网络，五分钟就能亲手跑通——之后你会明白，Cachix 与 Attic 本质上是同一套协议的规模化实现。

### 20.5.2 SSH 远端：小团队零运维方案

两三台机器的小团队，甚至不需要「缓存」这个概念——直接用远端 store 当 substituter：

```console
$ nix copy --to ssh://build@192.168.1.10 nixpkgs#hello
```

把闭包复制到构建机的 store（第 17 章）；然后在使用方配置 `substituters = ssh://build@192.168.1.10`，机器 A 上构建过的东西，机器 B 自动从 A 拉。注意 `ssh://` 作为 substituter 时走的是远端 store 协议而非 narinfo，因此没有缓存签名问题（信任由 SSH 账户承载）；代价是每个路径的询问都要经由 SSH，路径一多延迟就明显，这也是它只适合小团队的原因。免部署、免密钥体系（信任由 SSH 承担），代价是性能与并发能力有限。它还免费附赠一个调试便利：SSH 过去就是一台完整的 Nix 机器，`nix store ls`、`nix path-info` 可以直接查远端，「为什么 A 机器有、B 机器没有」这类问题当场可查。

反向操作同样有用——从远端把路径拉回本地：

```console
$ nix copy --from ssh://build@192.168.1.10 /nix/store/…-mytool-0.3
```

「构建机上有、我这里没有」的路径，一条命令补齐；配合闭包语义（第 17 章），需要连带哪些依赖，它自己知道。

### 20.5.3 Cachix：托管方案

Cachix（SaaS）把「缓存服务器 + 签名 + 权限」打包成服务，是目前最省心的主流选择：

```console
$ nix-shell -p cachix --run 'cachix use mycache'
```

`cachix use` 一条命令完成「写入 substituters、登记公钥」（个人机器直接生效；NixOS 上它会给出 nix.settings 片段让你声明式接入）。无论哪种方式，本质都只是写两行配置——一个 substituters 条目、一个公钥。理解了 20.3 节，Cachix 就没有任何魔法可言。

```console
$ nix build .#mytool | cachix push mycache
```

推送方把构建日志喂给 `cachix push`，它解析出本次产出的路径，签名并上传。CI 场景（GitHub Actions 有现成 action，第 41 章）的标准流水线是：CI 构建并 push 到 Cachix，开发者与后续 CI 全部命中，全团队没人再本地编译。

大仓库的全量推送可以改用监视模式，构建的同时实时上传：

```console
$ cachix watch-exec mycache -- nix build .#release
```

`watch-exec` 监视其子进程产生的所有 store 路径并增量推送，适合 CI 里「构建与推送一体化」的场景，不必等构建全部结束。

### 20.5.4 自托管：Attic、Harmonia 与 nix-serve

想在自有服务器上运维缓存，开源选择按复杂度排序：

- **nix-serve**：最老牌的单进程实现，兼容缓存协议，够小够用；
- **Harmonia**：Rust 实现的现代替代品，单二进制部署，nix-community 维护；
- **Attic**：带客户端与服务端的完整方案，支持多仓库存取权限、惰性拉取（按需回源）与垃圾回收策略，适合组织级使用。

选择的经验法则：单人用 `file://` 或 `ssh://` 足矣；小团队交给 Cachix 省心；组织级、多项目、需要权限与回收策略时，上 Attic。

以 Harmonia 为例，NixOS 上自托管一个缓存完全是声明式的：

```nix
{
  services.harmonia = {
    enable = true;                 # 起一个兼容缓存协议的 HTTP 服务
    signKeyPath = "/var/lib/secrets/harmonia-secret";
                                   # 签名私钥，只放这一台机器，妥善保管
  };
}
```

其他机器把 `https://harmonia.example.org` 加入 substituters、把对应公钥加入 trusted-public-keys，即可共享这台机器上构建过的一切（Harmonia 直接对外签名）。Attic 的思路更进一步：客户端推送、服务端按需从对象存储取回并做垃圾回收，适合多项目、大体量的组织。

企业内网的典型格局：CI（GitLab CI、Jenkins）持有签名私钥，每次构建把产物推进自建缓存；全部开发机与部署机的 NixOS 配置统一声明这个 substituter 与对应公钥。效果是「构建一次，全组织命中」，且私钥永不离开 CI——20.3 节的信任模型在这里发挥到极致。

## 20.6 「为什么我的包没有命中缓存」

这是 Nix 新手最高频的困惑，答案却非常干净：**任何输入变了，哈希就变了，而缓存里只有旧哈希**。

最常见的触发方式，给自己心爱的包加一个补丁：

```nix
{
  # 给 hello 打上自定义补丁
  hello-patched = pkgs.hello.overrideAttrs (final: prev: {
    patches = (prev.patches or [ ]) ++ [ ./banner.patch ];
    # 补丁文件成为派生的输入之一（第 13 章），
    # 于是派生哈希改变、输出路径改变——全球任何缓存都没有这个新路径
  });
}
```

构建它必然本地编译：不是缓存坏了，而是你创造了世界上第一个这样的派生。同理，「升级 nixpkgs 到新提交」「改一个编译 flag」「换一个依赖版本」都会沿依赖图传播哈希变化：直接被改的包变了，依赖它的所有包也跟着变（它们的输入里包含前者），一路级联到顶层。这也解释了 **fork nixpkgs 的代价**：你的分支与上游一旦分叉，分叉点之后的整个依赖子树都是「没人构建过」的，首次全量重建可能要几小时到几天——所以认真的 fork 都会配一个自己的 Cachix。

级联效应画出来更直观（箭头表示「依赖」，`*` 表示路径因上游变化而改变）：

```text
上游 nixpkgs：gcc ──▶ glibc ──▶ openssl ──▶ curl ──▶ 你的服务
你的 fork：    gcc* ──▶ glibc* ──▶ openssl* ──▶ curl* ──▶ 你的服务*
               （只改了 gcc，但它之后的每一环都换了新哈希）
```

你只改了一个包，它的全部下游都变成了「世界上没人构建过」的新路径。上游缓存对此爱莫能助——这不是缓存故障，而是哈希体系在如实报告：这确实是不同的东西。

诊断「为什么没命中」的两板斧：

```console
$ nix build -v .#mytool
```

加 `-v` 能看到 Nix 依次询问了哪些 substituter、哪些路径被判为「需要构建」。对可疑路径，手动查缓存：

```console
$ curl -s -o /dev/null -w "%{http_code}\n" https://cache.nixos.org/<哈希>.narinfo
404
```

404 表示该缓存的确认构建过这个精确哈希；如果返回 200 却仍在本地构建，问题多半出在信任配置（签名不被接受，回看 20.3 节）。顺手把这两板斧变成习惯：新环境首次构建前先 `--dry-run` 预览，遇到「意外要本地构建」时 curl 查一下 narinfo——九成的缓存疑问能在两分钟内定位。

另一个趁手的工具是 `--dry-run`：不动手，只告诉你「会怎样」：

```console
$ nix build --dry-run nixpkgs.hello
these 1 derivations will be built:
  /nix/store/…-hello-custom.drv
these 1 paths will be fetched (0.05 MiB):
  /nix/store/…-hello-2.12.1
```

（输出示意。）「will be fetched」的部分直接从缓存来，「will be built」的部分才是要本地编译的。构建大项目之前先 dry-run 一遍，心里就有数了：多久能好，取决于 will be built 的清单有多长。

反向的问题——「怎么让别人命中我的缓存」——的答案是把 20.5 节的组合用起来：Cachix 或自建缓存承接产物，flake 的 `nixConfig`（20.3.3 节）或 README 里的 `cachix use` 指引把入口交给用户。缓存命中是社区协作的一种形式：你的 CI 多构建一次，全世界用你项目的人少等一分钟。

把缓存入口交给用户，常见的三种形态按体验排序：

```bash
# 形态一：flake 里声明（20.3.3 节），用户构建时加 --accept-flake-config 即可
# 形态二：README 里写一行「nix-shell -p cachix --run 'cachix use mycache'」
# 形态三：让用户手动把 substituters 与公钥抄进自己的配置
```

形态一对用户最透明，但要沟通信任门槛的存在；形态二最直白，是当前社区项目的主流做法；形态三只适合内部文档。无论哪种，原则一致：**缓存地址与公钥要随项目一起发布**，否则「别人构建过」的红利只属于你自己。

## 20.7 展望：内容寻址派生

本章的安全模型有一个隐含假设：「输入相同则输出相同」靠构建的确定性保证，而确定性无法被证明——你终究要**信任**某个密钥背后的构建者没有撒谎（或者_outputs_被篡改却恰好签了名）。实验性的内容寻址派生（content-addressed derivations，CA 派生）尝试从根上改写这一点。

思路：不再用「输入哈希」给输出路径命名，而是构建完成后**按输出内容本身**计算哈希、命名路径。两个深远推论：

- **天然去重与互认**：不同的人、不同的机器、甚至不同的构建配方，只要产出内容一致，就得到同一个 store 路径。你从陌生人那里下载的产物，本地重算哈希即可自证清白——「信任但验证」变成「验证故无需信任」，第 20.1 节里对密钥的强依赖随之放松。
- **输入寻址的换算问题**成了核心工程挑战（如何让引用了旧命名方式的依赖图平稳迁移），这也是它长期处于实验阶段（`experimental-features = ca-derivations`）的原因。截至 Nix 2.35 它仍在演进，启用方式与限制以官方手册为准。

| 维度 | 输入寻址（现行） | 内容寻址（实验） |
| --- | --- | --- |
| 路径名来源 | 全部输入的哈希 | 输出内容本身的哈希 |
| 共享条件 | 输入完全一致 | 输出内容一致（更宽松） |
| 信任要求 | 必须信任签名方 | 本地验哈希即自证 |
| 主要难点 | 隐含假设确定性 | 与既有引用体系的换算与迁移 |

对普通使用者，此刻的行动项只有一个：给自己的项目配一个缓存（20.5 节），并把入口声明进 flake——协议层面的演进，交给生态去消化。

无论 CA 派生何时落地，方向是清晰的：Nix 生态把「复现」从道德承诺逐步变成数学事实，而二进制缓存生态——从 cache.nixos.org 到每一个 Cachix 实例——正是这份复现承诺兑现为下载速度的地方。

对本章的读者，最有用的心态或许是：把「缓存命中」看作一种**协作信号**——命中说明你的构建与整个生态同频，未命中说明你正在创造新的东西。前者享受全球共建的红利，后者用自建缓存把你的创造回馈给生态。

## 20.8 本章小结

- 「派生哈希相同 ⟺ 输入相同 ⟹ 输出可互换」是二进制缓存的全部前提；下载与构建是可互换的实现细节。
- 安全模型：信任密钥而非服务器——narinfo 必须带受信公钥的有效签名，恶意缓存最多拒绝服务、无法投毒。
- cache.nixos.org 由 Hydra 产出、全社区共享 channel 快照，这是它命中率高的结构性原因。
- 配置要点：`substituters` 按序查询、`trusted-public-keys` 声明信任、`trusted-users` 决定谁能引入新信任、flake 的 `nixConfig` 需显式放行。
- 缓存协议 = NAR（规范归档，哈希可复算）+ narinfo（含 References 的闭包索引与 Sig 签名），五步取回流程环环验签。
- 自建缓存从易到难：`file://` 本地目录、`ssh://` 直连远端 store、Cachix 托管、Attic/Harmonia/nix-serve 自托管；CI 持私钥推送、开发机命中是标准企业格局。
- 缓存未命中的唯一常见原因：任何输入变化（补丁、flag、依赖、nixpkgs 提交）导致新哈希；`-v` 与 curl 查 narinfo 是诊断两板斧。
- 内容寻址派生把「输出按内容命名」推向验证即信任的未来，目前仍为实验特性。

## 延伸阅读

- Nix 手册：`nix copy`：<https://nixos.org/manual/nix/stable/command-ref/nix-copy>
- Nix 手册：配置项（substituters、trusted-public-keys 等）：<https://nixos.org/manual/nix/stable/command-ref/conf-conf>
- NixOS Wiki：Binary Cache（含 narinfo 格式详解）：<https://wiki.nixos.org/wiki/Binary_Cache>
- Cachix 官方文档：<https://docs.cachix.org/>
- Nix 手册：`nix key`（缓存签名密钥）：<https://nixos.org/manual/nix/stable/command-ref/nix-key>
- nix.dev：闭包与缓存相关教程：<https://nix.dev/>
