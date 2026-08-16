# 第 19 章 垃圾回收：gcroots 与安全删除

> **本章导读**：/nix/store 是只增不减的：每次升级、每次构建、每个开发 shell 都会写入新路径，旧路径却因「回滚可能用得上」而无人敢删。谁来裁决哪些路径可以删？答案是垃圾回收器（garbage collector，GC）与它的根集合（GC roots）。本章讲清「正在使用」的精确定义、回收操作的正确姿势、与 NixOS 系统代的联动，以及磁盘治理与排错的实战经验。

## 19.1 为什么需要 GC：只增不减的 store

回顾前几章，`/nix/store` 里的内容有进无出，原因有三：

- **升级即新增**。`nix-env -u` 或 `nixos-rebuild switch` 不会覆盖旧版本——store 对象不可变（第 14 章），升级只是让 profile 或系统代指向新路径，旧路径原样留存，以备回滚（第 18 章）。
- **构建即新增**。每次 `nix build`、`nix-shell -p` 都可能产生新的派生输出，哪怕构建内容与从前完全一致，相关的 `.drv` 与中间产物也会占位。
- **输入即新增**。channel 快照、flake 输入的源码 tarball（fixed-output 派生，第 15 章）都缓存在 store 里。

量化一下增长有多快——在一台日常使用的 NixOS 上：

```console
$ du -sh /nix/store
41G     /nix/store
$ sudo nixos-rebuild switch --upgrade
building Nix...
$ du -sh /nix/store
43G     /nix/store
```

一次系统升级吃掉约 2 GB 并不夸张：新的内核、新的 glibc、几百个包的新版本全部以新路径落盘，旧的一律保留。三个月滚动之后，对着 du 的数字喊「Nix 太占空间」之前，先想清楚这些空间买到了什么：任何一次升级都可以整体撤销，任何时刻的系统状态都有完整快照。

长期滚动的机器上，/nix 占用几十上百 GB 是常态。但反过来，「删点什么腾地方」在 Nix 里是个危险操作：你随手 `rm` 掉的一个路径，可能是某个 profile、甚至当前系统闭包（第 17 章）的一环——删掉之后，下次开机就起不来了。

于是核心问题变成：**如何精确界定「正在使用」**？文件系统本身给不出答案（它不知道 `/nix/store/…-glibc` 被谁需要），Nix 的回答与编程语言的垃圾回收器（如 JVM、Go 的 GC）同构：

- 维护一个**根集合（GC roots）**：一组明确声明「我需要它」的入口；
- 依赖关系构成图：闭包（第 17 章）就是从根出发的可达集合；
- **从根不可达的路径 = 垃圾**，可以安全删除。

与语言运行时的 GC 逐项对照，同构性一目了然：

| 语言运行时 GC | Nix 的 GC |
| --- | --- |
| 根：线程栈、全局变量 | 根：profiles、间接根、临时根 |
| 可达对象：从根沿引用可达 | 可达路径：从根沿 references 可达 |
| 不可达对象被回收 | 不可达路径被删除 |
| 回收由运行时自动触发 | 回收由用户或定时器显式触发 |

最大的差别在最后一行：Nix 的 GC 从不「自作主张」——不删根（第 18 章的 generation 永远是你自己删），也从不自动运行（除非你配置了定时器）。回收时机的决定权完全在用户手里，这是把「可回滚」放在「省磁盘」之上的设计取舍。

两个经典误区提前澄清。其一，「GC 会删掉我正在运行的程序」——不会：正在使用的环境要么被根保护，要么已加载进内存，Unix 的文件语义保证已打开的文件不受删除影响（19.5 节展开）。其二，「store 这么大一定是泄漏了」——大多数时候它只是在诚实地保存你要求它保存的历史（19.6 节展开）。带着这两个共识往下读，会顺畅很多。

删除的安全性由可达性证明保证，而不是靠运气——这是 Nix 的 GC 与「清理 /usr/lib 里没人用的库」（没人能证明安全）的本质区别。

## 19.2 GC roots 全景

根都登记在哪里？一张目录地图（示意，省略部分条目）：

```text
/nix/var/nix/
├── gcroots/                        # 显式根的登记处
│   ├── auto/                       # Nix 自动登记的符号链接，多指向用户创建的 root
│   └── jd8k… -> /home/yz/proj/result   # 间接根：指向 store 之外的符号链接
├── profiles/                       # profile 们本身也是根
│   ├── system -> system-312-link   # NixOS 当前系统（第 24 章）
│   ├── system-311-link             # 历史 system 代（也是根！）
│   ├── per-user/
│   │   ├── root/channels -> …      # channel 也是 profile（第 18 章）
│   │   └── yz/profile -> profile-7-link
└── temporary-gcroots/              # 正在运行的 nix 命令的临时根
```

三种根值得分清：

**profile 根**。`/nix/var/nix/profiles` 下的每一个 `*-link`（包括所有历史代）都是 GC root。这就是旧代「赖着不走」的原因：profile-7-link 还在，它指向的 user-environment 及其整个闭包就可达。想真正释放空间，必须先删掉旧代（19.4 节），GC 才有机会跟进。

**间接根（indirect roots）**。你构建过东西的话一定见过项目目录里的 `result` 符号链接。当你执行 `nix build --out-link ./result ...`（或老命令 `nix-build --add-root ./result ...`）时，Nix 会把 `/nix/var/nix/gcroots/` 下登记一条指向 `./result` 的链接，并在 GC 时先解析这条链：只要 `./result` 还存在且指向某个 store 路径，该路径及其闭包就被保留。

亲手注册一个根试试：

```console
$ nix build nixpkgs#hello --out-link ./demo-root
$ nix store gc --print-roots | grep demo-root
/home/yz/demo-root: /nix/store/…-hello-2.12.1
$ rm ./demo-root
```

注册、可查、随符号链接一起消失——三行命令看完一个间接根的一生。这个设计很聪明——root 的生命周期跟着你工作目录里的符号链接走：你删掉 `result`（或删掉整个项目目录），下次 GC 时保护自动失效，不需要任何注销操作。

你可能注意到间接根登记在 `gcroots/auto/` 下、文件名是一串看似乱码的哈希——那是登记链接自己的名字，内容指向你磁盘上的 `result` 链接。GC 运行时会遍历 `auto/` 里的每条登记、解析到最终目标：解析成功就保护那个 store 路径；解析失败（`result` 已被删）就跳过。**没有登记表需要维护，目录本身就是协议。**

**临时根**。正在运行的 `nix build`、`nix-daemon` 会在 `/nix/var/nix/temporary-gcroots/` 下登记临时根。这保证了并发安全：一边构建一边 GC，构建者需要的路径不会被收走。

临时根可以亲眼看一看（开一个终端跑 `nix build`，同时在另一个终端执行）：

```console
$ ls /nix/var/nix/temporary-gcroots/
124553-0    124553-2
```

文件名形如「进程号-序号」，进程退出即消失。它的存在解释了一个常见困惑：你明明觉得某个路径「没人用了」，GC 却始终不敢删——看一眼这个目录和 `--print-roots` 的输出，往往真相大白。

三类根的速查表：

| 根的类型 | 谁创建 | 保护范围 | 如何解除 |
| --- | --- | --- | --- |
| profile 及其历史代 | nix-env / nixos-rebuild | 该代环境的整个闭包 | 删除 generation |
| 间接根（result 等） | nix build --out-link / nix-build | 链接目标的闭包 | 删掉那个符号链接 |
| 临时根 | 运行中的 nix 命令 | 正在处理的路径 | 进程退出，自动消失 |

观察当前机器的全部根：

```console
$ nix-store --gc --print-roots
/nix/var/nix/profiles/system-312-link
/nix/var/nix/profiles/per-user/yz/profile-7-link
/nix/var/nix/gcroots/auto/jd8k…: /home/yz/proj/result
/home/yz/proj/result: /nix/store/…-mytool-0.3
…
```

新 CLI 等价命令为 `nix store gc --print-roots`（输出示意；字段格式以官方手册为准）。逐行读过去，你会看到系统的全部「活着的理由」：系统代、用户环境、channel、你项目里的 result 链接。排错时这个列表往往是第一现场——某个「删不掉」的路径，通常都能在根列表里找到它的靠山。

## 19.3 回收操作：两条命令与两组配置

### 19.3.1 `nix store gc` 与 `nix-collect-garbage -d`

```console
$ nix store gc
```

标准回收：删掉所有从根不可达的路径。它**不会**动任何 generation——旧代是根，全部安然无恙。适合「我知道旧代还有用，只想清掉真正的孤儿」。

跑一次感受输出（数字示意）：

```console
$ nix store gc
1327 store paths deleted, 892.3 MiB freed
```

```console
$ nix-collect-garbage -d
```

先删除**所有 profile 的旧 generation**（包括 root 的系统历史代），然后做全量回收。`-d` 是 delete old generations 的意思。它是「彻底清理」的标准姿势，但要想清楚代价：所有用户环境与系统的回滚历史一并消失——执行前确认当前代工作正常。

| 命令 | 删旧 generation | 删不可达路径 | 适用场景 |
| --- | --- | --- | --- |
| `nix store gc` | 否 | 是 | 日常清理孤儿 |
| `nix-collect-garbage -d` | 是（全部 profile） | 是 | 定期深度清理 |

记忆口诀：`gc` 管现在够不够干净，`-d` 管历史要不要留。

### 19.3.2 NixOS 上的自动回收

```nix
{
  nix.gc = {
    automatic = true;                      # 启用 systemd 定时器自动回收
    dates = "weekly";                      # 每周执行（systemd OnCalendar 语法）
    options = [ "--delete-older-than 14d" ]; # 附给 nix-collect-garbage 的参数：
                                             # 只删 14 天前的旧代，最近的回滚窗口保留
  };
}
```

这会生成 `nix-gc.timer` 与 `nix-gc.service` 两个 systemd 单元（第 29 章），可用 `systemctl list-timers nix-gc.timer` 查看下次执行时间。`--delete-older-than` 的思路是在「保留足够回滚窗口」与「控制磁盘」之间取折中——比无脑 `-d` 稳妥得多，是生产机的推荐配置。

不在 NixOS 上（或不想开定时器）的机器，手动执行同样的清理：

```console
$ nix-collect-garbage --delete-older-than 14d
```

一条命令删掉所有 profile 中 14 天前的旧代并回收，效果与上面的定时器一致，适合「想清一次但不想常开自动 GC」的场景。

### 19.3.3 keep-derivations 与 keep-outputs

两个容易混淆的选项，恰好对应第 17 章讲的两条边：

```nix
{
  nix.settings = {
    keep-derivations = true;   # 默认 true：输出还活着时，保留派生它的 .drv 文件
                               # 好处：nix-build / nix-shell 知道「它从哪来」，
                               # 增量求值与溯源不断链；代价极小（.drv 是几 KB 的文本）
    keep-outputs = false;      # 默认 false：.drv 活着时是否连带保留其构建输出
                               # 开成 true 能避免「开发 shell 的依赖莫名被 GC」，
                               # 代价是 store 明显增大——按需取舍
  };
}
```

直觉记法：`keep-derivations` 保「配方」，`keep-outputs` 保「成品」。默认组合（保配方、不保成品）对多数人是合理的：配方便宜且常用，成品可能巨大。

一个真实的取舍场景：CI 机器每天用固定提交的 nixpkgs 反复进入开发 shell，每次 GC 跑完后，当天第一次进 shell 总要重新构建一批东西。给这台机器开 `keep-outputs = true` 后，只要 `.drv`（配方）可达——它们很小，通常都可达——对应的构建产物就一并保留，shell 恢复秒进。代价是 store 不再轻易缩小，需要配合更短的旧代窗口使用。

## 19.4 与 NixOS generation 的联动

NixOS 的每次 `nixos-rebuild switch` 都生成一个新的 system generation（第 24 章）：`/nix/var/nix/profiles/system-312-link`。两重身份必须同时意识到：

- 它是 **boot 菜单项**——GRUB / systemd-boot 的启动列表里每一项对应一个旧代，出问题时选旧代启动（第 28 章）；
- 它是 **GC root**——只要旧代还在，其系统闭包的全部路径都被保护。

所以「磁盘被历史系统代吃掉」是 NixOS 用户的必经之路：每次 rebuild 至少几十 MB 进账，半年下来旧代累积可观。正确的清理顺序是**先删代、再回收**：

```console
# nixos-rebuild list-generations
311   2026-07-28 08:11:03
312   2026-08-15 09:40:47   (current)
# nixos-rebuild delete-generations old
# nix-collect-garbage -d
```

`delete-generations old` 删除除当前代外的所有系统代（新版本还支持按代号或时间删除，语法以 `nixos-rebuild --help` 为准）；随后的全量回收把失去靠山的路径一扫而空。别忘了普通用户的 profile 旧代是独立的：`nix-env --delete-generations old` 只处理当前用户（`-p` 可指定其他 profile），多用户机器上需各自执行——`nix-collect-garbage -d` 之所以省事，正因为它一次遍历所有 profile。`nix-collect-garbage -d` 一条命令其实同时完成这两步（它删的是所有 profile 的旧代，包含系统代），分步执行的好处只是可控。

也可以限制 boot 菜单里保留多少项：

```nix
{
  boot.loader.systemd-boot.configurationLimit = 10;  # /boot 里最多保留 10 个启动项
  boot.loader.grub.configurationLimit = 10;          # GRUB 同理
}
```

注意理解它的边界：`configurationLimit` 控制的是 `/boot` 分区里的**菜单项数量**，在 `nixos-rebuild switch` 时裁剪；被裁掉的旧代不再作为 boot 项，但其 store 路径是否释放，仍取决于它是否还是 GC root（删代 + GC 才真正释放）。两件事互相配合，不能互相替代。

眼见为实，看看 boot 菜单项都躺在哪（以 systemd-boot 为例）：

```console
$ ls /boot/loader/entries
nixos-generation-311.conf
nixos-generation-312.conf
```

每个 `nixos-generation-N.conf` 指向第 N 代系统的内核与 initrd——启动时选旧代，就是选择引导当时的完整闭包（第 28 章）。删除某代后，对应的菜单项在下次 `nixos-rebuild switch` 时一并清理。

为什么旧代默认全部保留？因为 NixOS 无法预知哪一代是你的「救生艇」。磁盘告急时的正确动作从来不是抱怨默认值，而是按上面的流程**有意识地收窄历史窗口**——把「保留多少回滚余地」变成一个明确的运维决策，而不是一次隐式的惊喜。

## 19.5 安全性分析：GC 会删到正在运行的程序吗

一个合理担忧：GC 跑的时候，我的 firefox 正开着呢，它的文件会被删吗？

先给结论：**会删，但不会崩**——前提是它真的不可达。分两层看：

**Unix 的 unlink 语义**。进程对文件的持有靠打开的文件描述符与内存映射。GC 删除 store 路径只是 unlink：运行中的进程已经打开的库（glibc 早被映射进地址空间）、正在执行的二进制 inode 都继续有效，进程毫无感知地跑下去。这与传统发行版上「apt upgrade 替换了 /usr/lib 的库，正在运行的程序仍用旧版直到重启」是同一套内核语义。

用一个两分钟的实验验证它（任何 Linux 上都成立）：

```bash
# 写一个长睡眠脚本并启动，然后删掉脚本文件
$ cat > /tmp/sleeper.sh <<'EOF'
#!/bin/sh
sleep 300
EOF
$ chmod +x /tmp/sleeper.sh && /tmp/sleeper.sh &
$ rm /tmp/sleeper.sh
$ jobs
[1]+  Running                 /tmp/sleeper.sh &
```

文件已经从目录里消失，进程却安然无恙——GC 对 store 路径的删除，遵循的正是同一套语义。

**真正的风险在「之后」**。如果被删路径属于当前系统代（一般是可达的，GC 不会碰它），无事发生；但如果你刚删了旧代、又恰好在旧代的环境里开着程序（比如一个基于旧 nixpkgs 的 nix-shell），那么 shell 本身还活着，可它接下来想 fork/exec 的任何程序——编译器、python、测试脚本——可能已经不在磁盘上了，报 `No such file or directory`。实践建议：清旧代之前，退出不再需要的长会话 shell。

一个具体场景：你在昨天创建的 `nix-shell` 里跑着一个长任务，此时另一个终端执行了 `nix-collect-garbage -d`，恰好清掉了支撑这个 shell 的旧代。正在运行的长任务继续跑——二进制早已加载进内存；但任务结束后想再执行 `make test`，`make` 的路径已从磁盘消失，报 `No such file or directory`。这类「半死不活」的环境没有优雅的自愈手段，退出重建即可，代价通常只是从缓存重新下载（第 20 章）。

**为什么绝不手动 `rm /nix/store` 下的东西**，三个理由：

1. **绕过了可达性判断**。你删的路径可能正被某个根引用着——profile、系统代、或另一个 store 对象的闭包。GC 深谙此道，rm 不懂。
2. **破坏数据库一致性**。Nix 在 `/nix/var/nix/db` 里维护路径、引用、签名者的登记。手动 rm 让数据库指向不存在的路径，之后 `nix build` 会报 `path ... is not valid` 一类错误，甚至 daemon 拒绝工作。
3. **删除不完整等于埋雷**。一个 store 对象是完整目录树，rm 到一半失败（权限、断电）会留下残缺路径，后续一切引用它的操作行为未定义。

万一已经手滑了（或者磁盘损坏、断电）怎么办？修复思路是「让 Nix 自己重拿」：

```console
$ nix store verify --repair
```

`verify` 会校验登记的路径并尝试修复，内容损坏时从 substituter（第 20 章）重新下载——因为 store 路径由内容决定（第 15 章），重下载的东西与丢失的一模一样，这是 Nix 世界观带来的独特自愈能力。具体参数以 `nix store verify --help` 为准；个别顽固的坏路径也可用 `nix store delete` 显式移出登记后再重建。

## 19.6 磁盘治理实践

**观测先行**。动手清理之前先看清现状：

```console
$ du -sh /nix/store
41G     /nix/store
$ ncdu /nix/store
```

`ncdu` 的交互式视图适合按目录下钻（需要 root 权限看全貌），但切记**只读**——ncdu 支持按键删除文件，对 store 使用等于 19.5 节警告过的手动 rm，把它当望远镜用就好。更「Nix 原生」的视角是按闭包归属查：

```console
$ nix path-info -rSh /run/current-system | sort -k2 -h | tail -6
```

列出当前系统闭包里最大的路径——注意它们的总和远小于 store 总占用是正常的，差值就是「历史与世界」：旧代、旧 channel、你做过的实验。还有一个常被忽略的视角：当前系统整体的闭包多大？

```console
$ nix path-info -Sh /run/current-system
/nix/store/…-nixos-system-26.05…    2.4 GiB
```

这个数字是「重装或迁移这套系统至少要传输多少」的下界（第 17 章的闭包即部署）。它与 store 总占用的差值，就是历史的重量——差得越多，19.4 节的清理越值得做。

**去重：auto-optimise-store**。

```nix
{
  nix.settings.auto-optimise-store = true;  # 内容相同的文件自动硬链接去重
}
```

原理：store 是内容寻址的（第 15 章），两个不同路径下的同名文件若内容与权限完全一致，就可以安全地共享同一个 inode（硬链接）——因为它们本来就该一字不差。多 channel 并存、多代并存的机器上收益显著，代价是写入时多做一次哈希查重（较慢，所以不是默认值）。已有存量也可手动跑一次 `nix store optimise`。

一个高频疑问：删了几十 GB 的旧代，`df` 却只多出几个 GB？多半是**硬链接去重在起作用**——旧代与新代本是不同路径，但内容相同的文件共享 inode；删除旧代只是减引用计数，inode 要等最后一个引用者也删掉才真正释放。这不是 bug，恰恰是去重生效的证据：这些空间本就不该重复计费。

**空间大户清单**，按常见度排序：多个 nixpkgs 版本（channel + flake 输入 + 各种锁定版本并存）；历史 generation；开发 shell 与构建中间产物；从二进制缓存下载的超大闭包（如多个版本的 firefox）；被遗忘的 `result` 链接保护的实验产物。清理顺序建议：先 `nix store gc --print-roots` 审一遍根（删掉不再需要的 result、退订不用的 channel），再删旧代，最后全量回收。

大户之首「多个 nixpkgs 版本」可以这样数出来：

```console
$ ls -d /nix/store/*-source 2>/dev/null | wc -l
14
```

flake 输入的 nixpkgs 源码快照在 store 里的名字就叫 `source`——14 意味着这台机器上并存着 14 份不同提交的 nixpkgs 表达式树。它们大多被各个项目的 `flake.lock` 保护着（第 21 章），哪份该删取决于你还想不想构建那些项目：删掉项目的 result 根、让其失去保护，比手动判断安全得多。

**按需自动触发**。除了按时间表（`nix.gc`），还可以按磁盘水位：

```nix
{
  nix.settings = {
    min-free = 10 * 1024 * 1024 * 1024;  # 空闲低于 10 GiB 时，构建前自动删可回收路径
    max-free = 20 * 1024 * 1024 * 1024;  # 删到空闲 20 GiB 为止
  };
}
```

**心态**。最后是认知问题：`/nix/store` 很大不等于泄漏。几十 GB 的占用换来的是「任何时刻回滚到任何历史状态」与「所有项目环境并存互不干扰」——用 du 的数字对照换来的能力，多数情况是划算的。真正要警惕的是无意识增长：定期看看根列表，知道空间在保护谁。一个健康的节奏是「定期小扫除，偶尔大扫除」：每周让 `nix store gc` 清清孤儿，每季度审一次根、清一次旧代——把清理变成例行动作，而不是磁盘爆满之后的应激反应。

**一次完整的清理演练**，把本章的操作串起来：

```console
$ nix store gc --print-roots > /tmp/roots.txt
$ nix-shell -p ncdu --run 'ncdu /nix/store'
# nixos-rebuild list-generations
# nixos-rebuild delete-generations old
$ nix-env --delete-generations old
$ nix-collect-garbage
$ df -h /nix
```

各步的用意：先盘点根，确认没有「想保住却没登记」的东西；用 ncdu 直观感受分布（只看，不要用它删）；删掉系统旧代；再删当前用户 profile 的旧代（其他用户各自执行）；最后全量回收——注意此时**不必加 `-d`**，旧代已在前两步删掉；`df` 验收效果。把「删代」与「回收」拆开执行，每一步都可观察、可中止，比一条 `nix-collect-garbage -d` 更可控。

## 19.7 排错案例

**案例一：GC 之后 nix-shell 报缺失。**

```console
$ nix-shell -p python3
error: path '/nix/store/…-python3-3.13.x' disappeared
```

原因：上次的 GC（尤其是 `-d` 或带 `--delete-older-than` 的回收）移走了这个 shell 环境曾经依赖的路径，而某些引用了它的状态（比如缓存的求值结果、旧的 `.drv`）还在。修复通常很简单——重新执行同样的命令，让 Nix 按当前 channel 重新求值、从 substituter 重新拉取（第 20 章）。反复出现的话检查 `keep-outputs` 是否该开。

**案例二：flake 构建报输入路径缺失或哈希不符。**

```console
$ nix build
error: cannot fetch input 'github:NixOS/nixpkgs/…': … not valid
```

原因：flake 输入（如 nixpkgs 的源码 tarball）是 fixed-output 派生，缓存在 store 里；GC 删掉了它，而 `flake.lock` 依然指向同一个内容哈希。修复：直接重跑，Nix 会按 lock 里记录的哈希重新下载，结果与从前完全一致——这正是输入锁定的好处，删除不破坏可复现性。若报错的是输出路径缺失（而非输入），同样重跑即可，会从缓存或本地重建补齐。

**案例三：项目里的 result 链接变红（悬空）。**

现象：`ls` 里 `result` 颜色异常，`./result/bin/foo` 报 `No such file or directory`。原因：这个链接指向的路径失去了保护被 GC（比如有人删过 gcroots 登记，或你曾在别的机器上手动 rm 过）。修复：重新 `nix build`；由于二进制缓存命中（第 20 章），通常几秒内原路径满血复活。教训：想让某个产物长期不被回收，确认它的根确实登记在案（`nix store gc --print-roots` 里找得到），或者显式 `nix build --out-link ./stable-root`。

**案例四：清理之后 boot 菜单项变少了。**

「昨天还能选的第 311 代启动项去哪了」——`nix-collect-garbage -d` 删除旧系统代后，对应菜单项会在下次 `nixos-rebuild switch` 时移除。这是预期行为，不是损坏。如果想长期保留某个「已知良好」的代，清理前先用 `nixos-rebuild list-generations` 确认编号，并改用 `--delete-older-than` 带较长的时间窗口，让这位「功勋老将」活在窗口之内。

**案例五：清理之后，第一次 `nix-shell -p` 明显变慢。**

现象：GC 之前进入 shell 是秒开，现在每次都要「downloading」。原因：从前命中的路径恰好是某个旧代保护的构建产物，清旧代时一并释放了；现在它们改从二进制缓存下载（第 20 章）——首次几十秒，之后又恢复秒开（store 里重新有了）。这是正常代价而非故障；如果「重新变慢」的频率高到影响工作，回到 19.3 节，考虑 `keep-outputs = true`。

## 19.8 本章小结

- store 只增不减是设计使然（不可变 + 可回滚），GC 通过「根 + 可达性」精确定义垃圾，删除有证明、不靠猜。
- GC root 有三类：profile 及其所有历史代、间接根（`--out-link`/`--add-root` 登记的符号链接）、运行中命令的临时根；`nix store gc --print-roots` 列出全部靠山。
- `nix store gc` 只删不可达路径；`nix-collect-garbage -d` 先删所有旧代再回收，注意它会清掉回滚历史。
- NixOS 上用 `nix.gc.automatic` + `--delete-older-than` 在磁盘与回滚窗口之间取平衡。
- `keep-derivations`（默认开）保配方 `.drv`，`keep-outputs`（默认关）保构建成品，代价与收益按场景取舍。
- 系统旧代既是 boot 菜单项也是 GC root；清理顺序是先 `nixos-rebuild delete-generations` 再回收；`configurationLimit` 只管 /boot 菜单项，不能替代删代。
- 正在运行的进程靠 Unix unlink 语义不受 GC 影响，但旧环境里新起的进程可能失败；绝不手动 rm store，损坏后用 `nix store verify --repair` 或重下载自愈。
- `/nix` 大不等于泄漏；观测（ncdu、path-info）、去重（auto-optimise-store）、水位触发（min-free）构成治理三板斧。

## 延伸阅读

- `nix-collect-garbage` 手册：<https://nixos.org/manual/nix/stable/command-ref/nix-collect-garbage>
- `nix store gc` 手册（新 CLI）：<https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-store-gc>
- Nix 手册：垃圾回收器与根的官方说明：<https://nixos.org/manual/nix/stable/>
- NixOS 选项检索：nix.gc、keep-outputs 等：<https://search.nixos.org/options?query=nix.gc>
- NixOS Wiki：Storage optimization：<https://wiki.nixos.org/wiki/Storage_optimization>
