# 第 30 章 用户、状态与「无状态」哲学

> **本章导读**：NixOS 把「磁盘上应该有什么」声明得明明白白，但一台真实机器上总有配置管不到的东西：数据库文件、docker 卷、你的 home 目录、还有那把解密的私钥。本章先盘点这台机器上所有「状态」——哪些可丢弃、哪些必须备份；再沿两条路线收编状态：把用户与密码完全声明化，以及用 impermanence 把「想要留下的一切」变成显式清单；最后处理最敏感的状态——机密（secrets），以及换机器时的完整迁移流程。

## 30.1 NixOS 的「状态」清单：什么该备份、什么不该

传统 Linux 的经验在 NixOS 上会失灵：那里 `/etc`、`/usr` 都是「改了就没了」的宝贵状态；这里恰好相反，大部分路径是可重建的产物。先建立全景：

| 位置 | 里面是什么 | 能否重建 | 该备份吗 |
|---|---|---|---|
| `/nix/store` | 全部软件、单元文件、生成的配置 | 能：rebuild 触发重新构建/从缓存下载（第 17、20 章） | 否（体积巨大且纯属产物） |
| `/nix/var/nix/db`、profiles、GC roots | store 数据库与各代注册信息 | 理论能、实践上重装更快 | 否 |
| `/etc` | 大部分是指向 store 的符号链接与生成文件；少数真实文件（见 30.2） | 能：由配置生成 | 否——备份配置仓库本身即可 |
| `/var` | 服务真实数据：PostgreSQL 数据、docker 卷、ACME 证书私钥、syncthing 索引 | **不能** | **是（按服务挑）** |
| `/home` | 用户数据与 dotfiles | 不能（dotfiles 另有管理之道，第 44 章） | **是** |
| `/boot` | 内核与各代启动项 | 能：rebuild 重新生成 | 否 |
| secrets 私钥（如 sops 的 age key） | 解密配置中机密的钥匙 | 不能（丢了就得全部重新加密） | **是（离线安全存放）** |
| channel / flake lock | 版本指针 | channel 重新 `nix-channel --update` 即可；flake lock 在 git 仓库里 | 否（lock 随仓库走） |

这张表反过来读就是 NixOS 的备份策略：**只备份 `/home`、精选的 `/var/lib/<service>` 与机密私钥，其余交给配置仓库**。对照 Ubuntu：那里你得琢磨 tar 整个 `/etc`、记 `dpkg --get-selections` 的包清单、还要祈祷 `/usr` 里的手工修改没丢——NixOS 把「系统」本身从备份清单里划掉了。

一条诚实的注脚：`/var` 里也有可重建的角落（如 `/var/log` 视合规需求、`/var/cache` 显然不用），而 docker 卷、数据库目录几乎必然要备份。「按服务挑」的前提是你知道自己装了哪些服务——配置仓库恰好就是这份清单。

盘点一台已运行机器的状态，比想象的简单——一切都摊在明处：

```console
# /var 下谁在占地方？按体积排序，逐个问自己「丢了心疼吗」
$ sudo du -sh /var/lib/* | sort -rh | head
5.2G    /var/lib/docker        # docker 镜像与卷：容器数据都在这
2.1G    /var/lib/postgresql    # 数据库：必备份
180M    /var/lib/acme          # TLS 证书私钥：丢了要重新签（可重建，但服务会抖）
...
# docker 用户再看一眼卷与镜像的分布
$ docker system df
# 哪些旧 generation 还躺在启动菜单里？（回滚余量，也是磁盘去向）
$ ls /nix/var/nix/profiles | tail -5
system-113-link  system-114-link  system-115-link  system-116-link  system-117-link
```

这张表加上这条命令的输出，就是你这台机器的「状态资产负债表」：左边是配置仓库（资产），右边是必须备份的数据（负债），其余都是可以随时丢弃的产物。

## 30.2 /etc 的生成机制回顾

第 24.5 节埋了伏笔，现在兑现：`/etc` 里那些文件是谁放的？

答案是激活脚本（activation script，第 26 章）。每次 rebuild 激活时，系统会把求值出的 `/etc` 内容物逐项落到磁盘：普通文件先写进 store（内容寻址、不可变），再在 `/etc` 下创建符号链接指向它。看一眼实况：

```console
# 大部分条目是链接：指向 /etc/static（一个指向 store 的中转链接场）或直接指向 store
$ ls -l /etc/hosts
lrwxrwxrwx ... /etc/hosts -> /etc/static/hosts
$ readlink -f /etc/static
/nix/store/xxxxx-etc/etc/static
$ readlink -f /etc/hosts
/nix/store/xxxxx-etc/etc/hosts

# 也有真实文件：典型的就是 mutableUsers = true 时的 passwd 三件套
$ ls -l /etc/passwd /etc/shadow /etc/group
-rw-r--r-- ... /etc/passwd      # 真实文件：由 useradd/passwd 维护
```

想在声明里往 `/etc` 放东西，正门是 `environment.etc`（详见选项检索）：

```nix
{
  # 生成 /etc/myapp/myapp.conf（符号链接进 store）
  environment.etc."myapp/myapp.conf".text = ''
    listen = 8080
  '';
  # 变体：source 直接引用现成文件；mode/user/group 控制权限
  environment.etc."myapp/key.pem" = {
    source = ./files/key.pem;   # 注意：文件内容会进 store——机密别走这条路（见 30.5）
    mode = "0640";
  };
}
```

三个例外值得点名，它们是 `/etc` 里真正的可变内容：

- `/etc/nixos`：一个真实目录，配置源码住在这里——它不是被生成的，而是生成一切的源头，必须进 git；
- `mutableUsers = true` 时的 `passwd`/`group`/`shadow`：用户数据库是真实文件（30.3 会把它也收编成 store 链接）；
- 少数服务通过 `environment.etc.<name>.mode` 等选项声明为「可写副本」的条目。

```console
$ ls -ld /etc/nixos
drwxr-xr-x ... /etc/nixos   # 真实目录：配置源码，git 仓库本体
```

由此得出本章最重要的纪律：**手改 `/etc` 注定被覆盖**。激活脚本每次都会把链接修回配置声明的样子——`vim /etc/hosts` 改完，下次 rebuild 一切如初。正确做法是找到对应的选项（`/etc/hosts` 对应 `networking.extraHosts`），或用 `environment.etc`。判断某个文件归谁管的最快办法：`readlink -f` 显示 store 路径 → 归配置管；是真实文件 → 要么是 mutableUsers 的用户数据库，要么是某服务的运行时状态（多在 `/var`）。

## 30.3 完全声明式用户

第 24.3 讲了字段的语法，这里补全「全面切换到声明式用户」的流程与救援。

开启 `users.mutableUsers = false` 之后：

```console
# passwd 直接失效——/etc/shadow 已是只读的 store 链接
$ passwd
passwd: Authentication token manipulation error
```

改密码的标准流程变成三步：生成哈希 → 改配置 → rebuild：

```console
# 1) 生成 sha-512 哈希（Ubuntu 上 mkpasswd 来自 whois 包）
$ nix shell nixpkgs#mkpasswd
$ mkpasswd -m sha-512
Password:
$6$rounds=5000$xxxxxxxx$yyyyyyyy...   # 整串复制
```

```nix
# 2) 写进配置（用户级或系统级仓库均可）
{
  users.mutableUsers = false;
  users.users.alice.hashedPassword = "$6$rounds=5000$xxxxxxxx$yyyyyyyy...";
  # 更优雅：hash 不进 git/store，走 secrets（30.5）
  # users.users.alice.hashedPasswordFile = "/run/secrets/alice-password";
}
```

```console
# 3) 应用——记得先留一个已登录的会话防翻车
$ sudo nixos-rebuild switch --flake .
$ git commit -am "chore: 轮换 alice 密码"
```

四个「密码相关」选项的生效时机极易混淆，列表辨析：

| 选项 | 生效时机 | 明文进配置? | 适用场景 |
|---|---|---|---|
| `initialPassword` | 仅创建用户那一次 | 是（明文密码） | 新装机过渡，最不安全 |
| `initialHashedPassword` | 仅创建用户那一次 | 否（哈希） | 同上，稍好 |
| `hashedPassword` | 每次激活强制同步（需 `mutableUsers = false`） | 否（哈希） | 完全声明式的正选 |
| `hashedPasswordFile` | 每次激活强制同步 | 否（内容在 secrets） | 与 sops-nix/agenix 组合的最佳实践 |

一个高频疑问：`initialHashedPassword` 写错了、用户已经创建了，再改配置为什么没生效？因为它只在「用户不存在」的那次激活里读——补救办法是把 `initialHashedPassword` 换成 `hashedPassword`（配合 mutableUsers = false 强制同步），或临时 `sudo passwd` 后再走正规流程。

与传统的 `vipw` 对照：`vipw` 改的是一份易失文件，改完即生效、无历史、无评审；声明式流程多敲两条命令，换来的是密码变更进 git 历史、三台机器改一次全同步、以及「忘了上次设了什么」的问题永远消失（看配置就行）。

**忘记密码的救援路径**（也适用于 `hashedPassword` 写错把自己锁在外面）：

```console
# ① 任意 NixOS live USB 启动，挂载原系统
$ sudo mount /dev/nvme0n1p2 /mnt       # 根分区
$ sudo mount /dev/nvme0n1p1 /mnt/boot  # EFI 分区（rebuild 要写启动项）

# ② 进入原系统环境（chroot 的 NixOS 增强版，PATH 等已就绪）
$ sudo nixos-enter

# ③ 修配置：把 mutableUsers 改回 true，或修正/重设 hashedPassword，
#    然后在 chroot 里直接 rebuild
[nix-shell:/]# vim /etc/nixos/configuration.nix
[nix-shell:/]# nixos-rebuild switch --flake /etc/nixos#myhost
```

与 Ubuntu 救援对照：那边是 live CD + `chroot /mnt passwd`；这里多一步 rebuild，因为锁住你的不是 `/etc/shadow` 这份文件，而是一份声明——所以解铃还须系铃人。

另外注意：`mutableUsers = false` 时 `/etc/shadow` 是只读的 store 链接，即便在救援环境里想用 `chpasswd` 应急修改也会失败——必须回到配置层面解决。这不是刁难，而是「配置即真相」的必然：磁盘上的任何绕道都会在下一次激活时被纠正。更多排错场景见第 42 章。

## 30.4 无状态化进阶：impermanence 与 opt-in state

`users.mutableUsers = false` 收编了用户状态；[impermanence](https://github.com/nix-community/impermanence) 项目把同样的思路推到整台机器：**根文件系统用 tmpfs，每次开机都是一个全新系统，你想保留的一切必须显式声明**。这套心智模型叫 opt-in state（选择加入的状态）：默认即弃，白名单留存。

```nix
{
  imports = [ inputs.impermanence.nixosModules.impermanence ];

  # ① 根文件系统 = tmpfs：内存盘，断电即空——这是「无状态」的物理保证
  fileSystems."/" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [ "mode=755" "size=8G" ];   # 为什么限大小：防异常日志把内存吃爆
  };
  # ② 持久卷：普通 ext4/btrfs 分区，挂在 /persistent
  fileSystems."/persistent" = {
    device = "/dev/disk/by-label/persist";
    fsType = "ext4";
    neededForBoot = true;   # 为什么：machine-id、ssh 主机密钥要在启动早期可用
  };

  # ③ 白名单：显式声明要「活过重启」的路径
  environment.persistence."/persistent" = {
    files = [
      "/etc/machine-id"     # 不留：日志关联与 DHCP 租约会混乱
    ];
    directories = [
      "/var/log"            # 日志要能回看（否则每次开机 journal 归零）
      "/var/lib/nixos"      # uid/gid 分配状态：不留会导致用户 uid 漂移
      "/var/lib/systemd"    # systemd 的 ticker 等状态
    ];
    # 按用户细粒度白名单——你会发现 home 里真正值得留下的少得惊人
    users.alice = {
      files = [ "/home/alice/.ssh/authorized_keys" ];
      directories = [ "/home/alice/.config" "/home/alice/.local/share" ];
    };
  };
}
```

一份「第一版白名单」参考，从社区实践中反复出现的条目归纳而来：

```nix
{
  environment.persistence."/persistent" = {
    files = [
      "/etc/machine-id"          # 不留：日志关联与 DHCP 租约会混乱
      # SSH 主机密钥：不留的话每次开机都是新身份，
      # 所有客户端都会报「HOST KEY HAS CHANGED」
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
    ];
    directories = [
      "/var/log"                 # 日志要能回看
      "/var/lib/nixos"           # uid/gid 分配状态
      "/var/lib/systemd"         # systemd 记账状态
      "/var/lib/bluetooth"       # 已配对的蓝牙设备
      "/var/lib/NetworkManager"  # 已保存的 Wi-Fi 密码
      # 按服务追加："/var/lib/docker"、"/var/lib/postgresql"……
    ];
  };
}
```

第一次配置时的体验是「迭代式发现」：开机发现 SSH 连不上，哦，主机密钥没进白名单；浏览器书签没了，哦，profile 目录漏了……两三个循环后白名单趋于稳定。此后每次开机都变成一场免费的灾难恢复演练：如果这机器此刻丢了，重启后缺什么，白名单立刻告诉你。

适合谁：追求极致可复现的极客、频繁做破坏性实验的机器、安全洁癖者。不适合谁：不想为每个新软件琢磨「它的状态在哪个目录」的日常桌面、跑着大量有状态服务又没空盘点的工作机。诚实的代价清单：调试成本上升（一切「莫名丢失」先怀疑白名单）、某些不守规矩的软件把状态写在奇怪路径、以及你必须持续维护这份清单。

## 30.5 机密（secrets）管理：为什么、怎么做

### 30.5.1 为什么不能把密码明文写进 nix 文件

第 14 章讲过 store 的内容寻址与不可变性，这里补上它的另一面：**store 是全局可读的**。

```console
# 任何本地用户都能列 store、读任何路径
$ ls -ld /nix/store
drwxrwxr-t ... /nix/store   # 世界可读
```

凡是被配置引用的字符串——`hashedPassword`、数据库密码、API token——都会成为 derivation 的一部分，随构建结果躺在 `/nix/store/xxxxx-system-units/` 之类的路径里，模式位 0444，机器上**任意用户**可读。`users.users.alice.hashedPassword` 用的是哈希尚可接受（与 `/etc/shedow` 同级风险），但 `environment.variables.DB_PASSWORD = "s3cret"` 这种写法等于把明文密码发给了所有本地账户。何况配置仓库通常还要推 GitHub。结论：机密必须走专门的通道，两条主流路线是 sops-nix 与 agenix，思想一致：

- **构建期加密**：机密以 age（或 GPG）公钥加密后的密文进入仓库，密文可以放心进 store；
- **激活期解密**：每台机器私有一把私钥（放在重装即丢、备份必捡的位置），激活脚本用它在系统启动/切换时解密；
- **运行时控制**：解密产物落在 `/run/secrets`（或 `/run/agenix`）——tmpfs，不落盘、重启即消（下次激活再生成），属主与权限可精确到「只有那个服务读得到」。

### 30.5.2 sops-nix 最小可用示例

三步走。第一步，生成 age 密钥对（私钥留在目标机，公钥进仓库）：

```console
# 在目标机上执行
$ nix shell nixpkgs#age
$ sudo age-keygen -o /var/lib/sops-nix/key.txt
Public key: age1qyqszq...   # 把这个公钥记下来，写进 .sops.yaml
```

第二步，在仓库根放 `.sops.yaml`，告诉 sops「哪些文件用哪些公钥加密」：

```yaml
# .sops.yaml —— sops 的路由配置
keys:
  - &myhost age1qyqszq...        # 目标机的 age 公钥
creation_rules:
  - path_regex: secrets/.*\.yaml$   # secrets/ 下的文件都按此规则加密
    key_groups:
      - age:
          - *myhost
```

然后创建并编辑密文文件：

```console
$ nix shell nixpkgs#sops
# 首次创建/此后编辑都用同一条命令；保存时自动用 .sops.yaml 的公钥加密
$ sops secrets/myhost.yaml
```

第三步，模块接入与使用：

```nix
{
  # flake 输入 inputs.sops-nix，然后引入其模块
  imports = [ inputs.sops-nix.nixosModules.sops ];

  sops.defaultSopsFile = ./secrets/myhost.yaml;   # 密文文件（可安全进 store）
  sops.age.keyFile = "/var/lib/sops-nix/key.txt"; # 私钥位置：绝不能进 store

  # 声明一个机密：激活时解密为 /run/secrets/alice-password
  sops.secrets.alice-password = {
    neededForUsers = true;   # 为什么：改用户密码要在 users 激活段之前就绪
  };
  # 与 30.3 衔接：声明式用户的 hash 从 secrets 来，git 里连哈希都没有
  users.users.alice.hashedPasswordFile = "/run/secrets/alice-password";

  # 服务机密的典型用法：按运行用户控制权限，注入为环境文件
  sops.secrets.myapp-env.owner = "myapp";   # 只有 myapp 用户可读
  systemd.services.myapp = {
    serviceConfig.EnvironmentFile = config.sops.secrets.myapp-env.path;
  };
}
```

rebuild 之后看一眼落地的产物，加深理解：

```console
# /run 是 tmpfs：机密只存在于内存中，重启即消（下次激活再解密）
$ mount | grep " /run "
tmpfs on /run type tmpfs (rw,nosuid,nodev,mode=755,...)
# 属主与权限按声明落位——其他用户读不到
$ ls -l /run/secrets/
-r-------- 1 myapp myapp 43 ... myapp-env
-r-------- 1 root  root  63 ... alice-password
# 密文在 store 里、明文永远不在：随便查一个系统闭包都只有密文
$ ls /nix/store/*-source/secrets/myhost.yaml   #（内容为密文，可放心）
```

[agenix](https://github.com/ryantm/agenix) 是同一思想的另一实现：每个机密一个 `.age` 文件，仓库里用 `secrets.nix` 声明「哪些公钥可以解哪些文件」，`agenix -e` 编辑、`agenix -r` 在人员变动时批量重加密；运行时解密到 `/run/agenix/<name>`，核心选项是 `age.secrets.<name>.file` 与 `age.identityPaths`。两者怎么选：重度使用 sops 生态（明文也可托管）或喜欢 YAML 分文件 → sops-nix；喜欢「一机一钥、命令行简洁」→ agenix。社区两者都很主流。

无论选哪个，都别忘了一条：**解密私钥本身是 30.1 表格里唯一必须人工保管的机密**——把它打印进保险柜或放进密码管理器，丢了的代价是重新加密所有机密。

## 30.6 备份与迁移

### 30.6.1 三件备份工具的声明式写法

restic（去重快照，现代首选；第 24.6.6 已给完整示例，换机器时记得仓库密码也在 secrets 里）：

```nix
{
  services.restic.backups."nas" = {
    paths = [ "/home" "/var/lib/postgresql" ];
    repository = "sftp:backup@nas.local:/backup/myhost";
    passwordFile = "/run/secrets/restic-pw";
    timerConfig = { OnCalendar = "daily"; Persistent = true; };
    pruneOpts = [ "--keep-daily" "7" "--keep-monthly" "6" ];
  };
}
```

borg（经典去重备份，加密成熟）：

```nix
{
  services.borgbackup.jobs.home = {
    paths = [ "/home" "/var/lib" ];
    repo = "backup@nas.local:/backup/myhost.borg";
    encryption = {
      mode = "repokey-blake2";
      passCommand = "cat /run/secrets/borg-pass";   # 密码走 secrets 通道
    };
    environment.BORG_RSH = "ssh -i /run/secrets/borg-key";
    compression = "zstd";
    startAt = "daily";
    prune.keep = { daily = 7; weekly = 4; monthly = 6; };   # 保留策略一并声明
  };
}
```

rsnapshot（rsync 硬链接快照，无加密，适合本地/可信网）：

```nix
{
  services.rsnapshot = {
    enable = true;
    # 间隔与 cron 表达式的映射；对应保留层级需在配置中声明 retain，
    # 具体选项（cronIntervals、extraConfig 等）以官方选项检索为准
    cronIntervals = { daily = "30 2 * * *"; };
  };
}
```

共同点值得点破：备份的**内容**（paths）、**节奏**（timer）、**保留策略**（prune）全部声明化——恢复演练时你要回答的「当时怎么备的」这个问题，答案就在 git 历史里。

### 30.6.2 换机器：从零到「完全一样」

配置仓库 + 数据备份 + 私钥 = 整台机器。新机器流程：

```console
# 前置：新机器配置（flake 里加好 nixosConfigurations.newhost 与磁盘声明）

# ① 磁盘分区与系统安装一条命令完成（disko 声明磁盘 + nixos-anywhere 远程安装）
#    原理与选项详见第 31 章部署生态
$ nix run github:numtide/nixos-anywhere -- --flake .#newhost root@192.168.1.50

# ② 恢复数据：把备份里的 /home 与挑选过的 /var/lib 拉回来
$ sudo rsync -aHAXv backup:/restore/home/ /home/
$ sudo rsync -aHAXv backup:/restore/var/lib/postgresql/ /var/lib/postgresql/

# ③ 恢复机密私钥（它不在任何仓库里！）
$ sudo scp old-machine:/var/lib/sops-nix/key.txt /var/lib/sops-nix/key.txt

# ④ 各服务通常需要一次重启来重新挂接数据
$ sudo systemctl restart postgresql
```

对照传统换机：Ubuntu 时代的「迁移」实际是「重装 + 大量手工补救」，两台机器永远差着无数细节；这里 ①④ 是机械操作，②③ 有备份清单可循，机器间的「漂移」被压缩到 rsync 的粒度。

### 30.6.3 演练建议

备份没验证过恢复，等于没有备份。NixOS 让灾难演练便宜到可以例行化：

- 季度演练：拿一台虚拟机（或 impermanence 机器的一次重启，见 30.4），只带「配置仓库 + 备份 + 私钥」从零重建，计时并记录卡壳点；
- 演练中发现的每个「咦这个服务怎么起不来」，都是白名单/备份清单的一条补录；
- 把演练日期记进仓库的提交信息——下次真出事时，你引用的是三个月前的实证，而不是乐观的想象。

## 30.7 「系统即代码」的收益盘点与诚实的代价

把本章与前章串起来，NixOS 的主张可以一句话说清：**机器的全部意图都在版本库里，磁盘上其余的要么是产物，要么是显式登记的数据**。收益盘点：

- **可审计**：`git log` 就是变更史。上一条 console 里那个「谁在三月改过防火墙」的问题，传统机器靠 `/var/log` 碰运气，NixOS 靠 `git blame`。

```console
$ git log --oneline --follow configuration.nix | head -5
a1b2c3d feat: 开放 22000 端口给 syncthing
e4f5a6b fix: 修正 alice 的密码哈希
...
```

- **可回滚**：generation 机制（第 18 章）让「撤销」是系统级原语——内核、服务单元、`/etc`、用户定义一起退回上个版本，一次重启完成。
- **可复制**：同一份配置在新机器上得到同一套系统（flake lock 锁定下甚至同一版 nixpkgs）。三台机器的 nginx 配置不再是「大概一样」。
- **可交接**：接手的人读仓库，而不是读你的记忆。

然后是诚实的代价，不列完这部分本章就不算诚实：

- **学习曲线陡峭**：你得同时理解 Nix 语言、模块系统、store 与激活机制——正是本书试图摊平的坡。
- **有状态软件不会消失**：NixOS 没有（也不能）把 PostgreSQL 的数据变成纯函数输出；docker 卷、数据库、上传文件依然是状态，备份依然是你的责任，本章因此存在。
- **部分软件假设可写的系统路径**：往 `/usr`、`/etc` 写文件的老软件在 NixOS 上会碰壁（只读或被覆盖），需要用包装、`environment.etc`、tmpfiles 等手段驯化，第 42—45 章的排错篇处理这类问题。
- **调试层级变多**：一个问题可能出在 nix 求值、store 构建、激活脚本、systemd 单元或应用本身——但每一层都有本章这样的工具可查，而且每一层的答案都可以固化回配置里，第二次就不再是问题。

「无状态」的准确含义由此清晰：不是机器没有状态，而是**状态从默认变成了例外**——每一条状态都必须被显式声明（用户、secrets）或显式登记（备份、白名单）。例外清单之外的整个系统，都是可以随时丢弃、随时重建的函数输出。

## 30.8 本章小结

- 状态清单是备份策略的地基：只备份 `/home`、精选 `/var/lib` 与机密私钥；store、`/boot`、生成的 `/etc` 全部交给配置仓库重建。
- `/etc` 大部分是激活脚本落下的 store 符号链接；手改被覆盖不是 bug 而是纪律，正门是 `environment.etc` 与对应模块选项（第 26 章）。
- 完全声明式用户 = `mutableUsers = false` + `hashedPassword`（或更优的 `hashedPasswordFile` 走 secrets）；改密码三步：mkpasswd → 改配置 → rebuild；锁死的救援路径是 live USB + `nixos-enter`。
- impermanence 把「保留什么」变成白名单：tmpfs 根 + `/persistent` 卷 + `environment.persistence`，opt-in state 心智模型；适合可复现极客与实验机，不适合怕折腾的日常桌面。
- 机密绝不能明文进 nix：store 全局可读且进 git。sops-nix/agenix 的共同思想是构建期公钥加密、激活期解密到 `/run/secrets`（tmpfs）、运行时按用户控权限。
- 备份三件套 restic/borg/rsnapshot 的路径、节奏、保留策略全部声明化；恢复没演练过等于没备份，季度虚拟机重建是低成本演练。
- 换机器 = nixos-anywhere 装系统（第 31 章）+ rsync 恢复 `/home` 与 `/var/lib` + 手工恢复机密私钥。
- 系统即代码的收益是可审计、可回滚、可复制、可交接；代价是学习曲线、有状态软件依旧存在、以及少数假设可写路径的软件需要驯化。

## 延伸阅读

- NixOS 手册·修改配置与回滚：<https://nixos.org/manual/nixos/stable/#sec-changing-config>
- NixOS 选项检索（`users.users`、`environment.etc`、`services.restic` 等）：<https://search.nixos.org/options>
- NixOS Wiki·Impermanence：<https://wiki.nixos.org/wiki/Impermanence>
- impermanence 项目：<https://github.com/nix-community/impermanence>
- sops-nix：<https://github.com/Mic92/sops-nix>；agenix：<https://github.com/ryantm/agenix>
- restic 文档：<https://restic.readthedocs.io/>；BorgBackup：<https://www.borgbackup.org/>
