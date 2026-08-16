# 第 31 章 部署工具生态

> **本章导读**：当你的 NixOS 配置从一台机器长成一群机器，「部署」就从一次 rebuild 变成了一门工程。本章先把部署拆解为构建、传输、激活三个不可再分的原子动作，再逐一考察 nixos-rebuild、nixos-anywhere、deploy-rs、colmena 等工具对这三步的不同包装方式，最后给出按规模选型的建议与「配置仓库 + CI + 缓存 + 部署工具」的完整拓扑。读完你应当能回答两个问题：我的场景该用哪个工具，以及它为什么被设计成这样。

## 31.1 部署的本质：构建、传输、激活

在第 23 章我们看到，一份 NixOS 配置求值后会得到一个特殊的派生（derivation），其构建产物是 `/nix/store/xxxx-nixos-system-26.05.yyyy/` 这样的「系统顶层路径」（toplevel）。第 17 章讲过，这个路径背后挂着整个系统闭包（closure）：内核、initrd、所有软件、所有 systemd 单元文件，一个不多一个不少。而第 27 章讲过，「激活」一个新系统就是执行该路径下的 `bin/switch-to-configuration`：切换 `/nix/var/nix/profiles/system` 软链接、写入引导项、重启变化过的服务。

由此可以给出部署的严格定义——所谓部署一台 NixOS 机器，就是完成三个原子动作：

1. **构建（build）**：把配置（configuration.nix 或 flake）求值成派生并 realize，得到系统闭包。构建可以在你的笔记本、CI 服务器或目标机本体上进行，产物字节级相同（参见第 16 章）。
2. **传输（copy）**：把闭包中目标机尚不存在的路径复制过去。Nix 按路径哈希做差量传输，两台机器共用的依赖（比如同一份 nixpkgs 构建出的 glibc）一个字节都不会重传。
3. **激活（activate）**：在目标机上调用 `switch-to-configuration switch`，让新闭包成为「当前系统」。

手工完成这三步并不神秘，一条命令一条命令写出来就是这样：

```console
# ① 构建本机求值 .#myhost 的系统闭包，得到 ./result 软链接
$ nix build .#nixosConfigurations.myhost.config.system.build.toplevel

# ② 经 ssh 把闭包差量复制到目标机（目标机需开启 ssh，Nix 会走 ssh 协议写入 store）
$ nix copy --to ssh://root@203.0.113.10 ./result

# ③ 在目标机上激活：解引用 result 拿到真实 store 路径，远程执行其中的激活脚本
$ ssh root@203.0.113.10 \
    "$(readlink -f ./result)/bin/switch-to-configuration switch"
```

这三行命令就是本章所有工具的「最小公分母」。理解了这个参照系，再看任何部署工具，都只需要问三个问题：构建放在哪台机器？传输走 ssh 还是走二进制缓存？激活是裸调 `switch-to-configuration`，还是包上了回滚、验证等额外逻辑？

| 工具 | 构建位置 | 传输通道 | 激活方式 | 附加能力 |
| --- | --- | --- | --- | --- |
| nixos-rebuild | 本机 / 目标机 / CI | `nix copy` over ssh | switch-to-configuration | 零依赖、开箱即用 |
| nixos-anywhere | 管理机 | `nix copy` | nixos-install（全新安装） | disko 分区、kexec |
| deploy-rs | 管理机 / CI | `nix copy` | 自带 activator（带回滚） | magic rollback |
| colmena | 管理机 / CI | `nix copy` | switch-to-configuration | 并行、tags、密钥分发 |

还有一个贯穿全章的洞察值得先说破：因为激活在机制上只是「换一个软链接指向，再按差异重启服务」（第 27 章），它天然接近原子操作，失败即可整体回滚。后面所有工具的花哨特性——自动回滚、部署确认、并行推五十台机器——全都建立在这个朴素的地基上。这也是 NixOS 部署与第 31.8 节将要对比的 Ansible 式「逐步收敛」的根本差异所在。

## 31.2 内置工具：nixos-rebuild 的远程模式

nixos-rebuild 本身就内置了远程部署能力，通过两个参数控制：

```console
# 模式一：构建与激活都发生在目标机上
# 适合：目标机性能尚可、且它自己能（经 substituted 缓存）快速拿到依赖时，
#       好处是无需跨机传输构建上下文，命令最短
$ nixos-rebuild switch --flake .#myhost \
    --target-host root@203.0.113.10 \
    --build-host root@203.0.113.10

# 模式二：在管理机上构建，只把成品推给目标机激活
# 适合：目标是树莓派、路由器、小内存 VLM 等弱机，或目标机无法访问 nixpkgs 源时
$ nixos-rebuild switch --flake .#myhost \
    --target-host root@203.0.113.10 \
    --build-host you@your-laptop
```

两点实务提醒：

- **显式写出两个 host 最稳妥**。只给 `--target-host` 而省略 `--build-host` 时构建到底落在哪一侧，随 nixos-rebuild 版本与配置会有差异，部署脚本里把两个参数都写死，行为才是可预期的（细节以官方手册为准）。
- **ssh 与 root 权限**。激活要写 `/nix/var/nix/profiles/`、`/etc`、`/run`，因此远程侧必须是 root，或者用普通用户加 sudo。非交互场景（CI、脚本）推荐 23.11 后引入的 `--use-remote-sudo`，但注意它要求该用户的 sudo 免密（NOPASSWD），否则会卡在密码提示上：

```console
# 用普通用户 + 免密 sudo 部署（比直接 root 登录更符合最小权限原则）
$ nixos-rebuild switch --flake .#myhost \
    --target-host deploy@203.0.113.10 \
    --build-host localhost \
    --use-remote-sudo
```

初次连接还有两个小坑：目标机的 host key 不在 known_hosts 时命令会失败，先 `ssh-keyscan` 或手动登录一次；flake 模式下 nixos-rebuild 需要把你的配置仓库拷到构建侧，所以配置仓库必须是干净的 git 仓库（参见第 45 章问题「git tree is dirty」）。

**密钥分发问题**在这里第一次露头。配置里迟早会出现不能见人的东西：WireGuard 私钥、数据库口令、TLS 证书。而第 14 章讲过，`/nix/store` 全局可读——把明文密钥写进配置或 derivation 等于把钥匙挂在门上。于是「部署」除了三步之外，实际还有隐藏的第四步：**把密钥以安全方式送到目标机**。本章后续工具各有解法：colmena 有内建的 `deployment.keys`，nixos-anywhere 支持 `--disk-encryption-keys`，而更通用的方案是 sops-nix 与 agenix（用公钥加密后存仓库，在目标机上解密到 `/run/secrets`，不进 store）。此处先记住问题，后面看到工具时对号入座。

## 31.3 nixos-anywhere + disko：从裸机到系统

`nixos-rebuild` 只适用于「目标机上已经装了 NixOS」的情况。给一台全新机器（办公室新到的裸机、云厂商刚开出来的 VPS、PVE 里的空虚拟机）装 NixOS，2026 年的现代标准答案是 **nixos-anywhere** 配合 **disko**。

先看整体流程，它把「人肉装系统」的每一步都自动化并声明式化了：

```
裸机 / 云 VM
   │ ① 引导进任意 Linux 救援系统
   │    （云厂商 rescue 镜像、iPXE、刻好的 Live USB 均可）
   ▼
救援系统（唯一要求：能 ssh 登录）
   │ ② 在管理机上运行 nixos-anywhere，经 ssh 连入
   │    必要时用 kexec 引导进一个临时 NixOS 安装环境，
   │    确保目标侧拥有 nix、disko 等全套工具
   ▼
③ disko 读取你 Nix 文件里的磁盘声明
   │    → 分区 → 格式化 → 挂载到 /mnt
   ▼
④ nixos-install --flake .#myhost
   │    构建系统闭包 → 复制进 /mnt → 安装 bootloader
   ▼
⑤ reboot，得到一台与你 git 仓库声明完全一致的 NixOS
```

关于第 ② 步补充一句：目标救援系统不是 NixOS 安装镜像时，nixos-anywhere 会视情况用 kexec 切换到一个临时 Nix 环境；kexec 行为与镜像选择可以用参数控制（`--kexec`、`--no-kexec`），具体默认值以官方 README 为准。这解决了一个经典麻烦：很多云厂商的救援系统是没有 nix 的 Debian/Alpine。

### 31.3.1 disko 配置：GPT + EFI + ext4 单盘

disko 的核心思想是：磁盘布局也是配置。下面是一份可以直接放进 NixOS 模块的完整声明，逐行注释：

```nix
# modules/disko.nix —— 最简单的单盘布局：GPT 分区表 + ESP + ext4 根分区
{ config, ... }:
{
  disko.devices = {
    disk.main = {                  # 磁盘的逻辑名，随意取，会在分区标签中体现
      type = "disk";               # 声明这是一块物理盘（disko 也支持 zfs/bcache 等别的顶层类型）
      device = "/dev/vda";         # 要抹掉的设备路径；⚠️ 跑一次即全盘数据清空，务必核对
      content = {
        type = "gpt";              # 使用 GPT 分区表（现代 x86/ARM 机器的标准选择）
        partitions = {
          ESP = {                  # EFI 系统分区（EFI System Partition）
            priority = 1;          # 序号靠前，确保分区位置稳定、可预测
            size = "512M";         # 512 MiB 足够放下多个 generation 的内核与 initrd
            type = "EF00";         # GPT 分区类型码：EFI System
            content = {
              type = "filesystem";
              format = "vfat";     # ESP 必须是 FAT 系列文件系统，UEFI 固件才认
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];  # 权限收紧：只允许 root 读引导文件
            };
          };
          root = {
            size = "100%";         # 占满剩余空间
            content = {
              type = "filesystem";
              format = "ext4";     # 朴素可靠的选择；需要快照可换 btrfs，读者可自行扩展
              mountpoint = "/";
              mountOptions = [ "noatime" ];  # 不记录访问时间，减少无谓写入
            };
          };
        };
      };
    };
  };
}
```

把 disko 作为 NixOS 模块导入后，`mountpoint` 会被自动翻译成 `fileSystems` 配置——你不需要再手写一份 `fileSystems."/"`，单一事实来源（single source of truth）。要在 flake 里使用，把 disko 加进 inputs 并导入其模块：

```nix
# flake.nix 节选
inputs.disko = {
  url = "github:nix-community/disko";
  inputs.nixpkgs.follows = "nixpkgs";  # ✅ 复用同一个 nixpkgs，避免两套 stdenv 混用
};

# nixosSystem 的 modules 中：
#   inputs.disko.nixosModules.disko
```

### 31.3.2 disko 配置：带 LUKS 全盘加密

笔记本等容易丢的设备建议全盘加密。第二份示例在根分区外套了一层 LUKS（Linux Unified Key Setup）：

```nix
# modules/disko-luks.nix —— GPT + ESP + LUKS + ext4
{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/nvme0n1";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";              # ESP 不加密（UEFI 没法解 LUKS）
            mountOptions = [ "umask=0077" ];
          };
        };
        luks = {
          size = "100%";
          content = {
            type = "luks";                      # 分区内容是 LUKS 加密卷
            name = "crypted";                   # 解锁后映射为 /dev/mapper/crypted
            settings.allowDiscards = true;      # SSD TRIM 穿透加密层，维持回收效率
            content = {
              type = "filesystem";              # 加密卷内部再放真正的文件系统
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
      };
    };
  };

  # disko 只负责「格盘」这一侧；开机解锁还需要 initrd 配置。
  # 用稳定的 by-partlabel 引用，避免设备名漂移
  boot.initrd.luks.devices."crypted".device =
    "/dev/disk/by-partlabel/disk-main-luks";
}
```

LUS 的口令有两种给法：交互式（安装与每次开机都在控制台输入口令），或由 nixos-anywhere 在安装期注入一个密钥文件。后者用于非交互安装：

```console
# 安装期注入 LUKS 密钥文件：左侧是目标机上的路径，右侧是本机文件
$ nix run github:numtide/nixos-anywhere -- \
    --flake .#myhost \
    --disk-encryption-keys /tmp/secret.key ./secret.key \
    root@203.0.113.10
```

### 31.3.3 执行安装与常用参数

万事俱备后，一条命令完成安装：

```console
# ✅ 标准用法：从 flake 取配置，装到 root@目标机
$ nix run github:numtide/nixos-anywhere -- \
    --flake .#myhost root@203.0.113.10

# 救援系统只给了 root 密码没有公钥时，用 sshpass 传密码（装好后请立即换成公钥）
$ SSHPASS='rescue-password' nix run github:numtide/nixos-anywhere -- \
    --flake .#myhost root@203.0.113.10 -- --env-file <(echo "SSHPASS=$SSHPASS")

# 想在装完后留在机器里检查（比如手动看一眼挂载），先不重启
$ nix run github:numtide/nixos-anywhere -- --no-reboot --flake .#myhost root@203.0.113.10
```

安装结束后建议做的第一件事：确认 ssh host key 是否符合预期（全新机器首次信任）、把临时密码通道关掉、把真正的密钥配置（sops-nix/agenix）部署上去。与传统「人肉 nixos-install」相比，nixos-anywhere 的价值不在省一次敲回车，而在于**装机过程本身进了版本库**：换一块盘、重装一台同型号机器，得到的是位元级相同的起点。

## 31.4 deploy-rs：带回滚确认的部署

deploy-rs 是一款基于 flake 的部署工具，出自 Serokell。它的两个设计点直击远程部署的痛点：flake 原生集成（部署配置与系统配置写在同一个文件里），以及大名鼎鼎的 **magic rollback（魔法回滚）**。

flake 中的部署声明长这样，注意结构 `deploy.nodes.<节点名>.profiles.<profile名>`：

```nix
# flake.nix 节选：deploy-rs 部署声明
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    deploy-rs.url = "github:serokell/deploy-rs";
  };

  outputs = { self, nixpkgs, deploy-rs }@inputs: {
    # 系统本身照常定义，部署工具只是引用它
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ ./hosts/myhost/configuration.nix ];
    };

    deploy = {
      autoRollback = true;    # 激活脚本失败 → 自动回滚到上一个 profile（默认开启）
      magicRollback = true;   # 激活后的连通性确认机制（默认开启，见下文）
      nodes = {
        myhost = {
          hostname = "203.0.113.10";        # 部署目标地址（缺省用节点名解析）
          profiles = {
            system = {                       # NixOS 整机对应名为 system 的 profile
              # 把 nixosConfigurations 包装成 deploy-rs 的激活目标，
              # activate.nixos 会生成带确认逻辑的 activator
              path = deploy-rs.lib.x86_64-linux.activate.nixos
                self.nixosConfigurations.myhost;
              user = "root";                 # 激活动作在目标机上以哪个用户执行
              sshUser = "deploy";            # ssh 登录用的用户（可与 user 不同）
              sshOpts = [
                "-p" "22"
                "-o" "StrictHostKeyChecking=accept-new"  # 首次部署新机时自动记录 host key
              ];
            };
          };
        };
      };
    };
  };
}
```

日常使用就一条命令：

```console
# ✅ 部署单个节点（ flakes 为事实标准后无需安装，nix run 即可）
$ nix run github:serokell/deploy-rs -- .#myhost

# 先看看会改什么，不真正激活（与 nixos-rebuild dry-activate 异曲同工）
$ nix run github:serokell/deploy-rs -- .#myhost --dry-activate
```

**magic rollback 的机制**值得讲透，它是 deploy-rs 的灵魂。普通工具激活完就收工，如果新配置把 sshd 或防火墙搞坏了，你将失去对机器的控制——只能去机房接显示器。deploy-rs 的激活脚本在切换到新 generation 之后并不立即宣告成功，而是进入一个「确认窗口」：

1. 激活脚本设置好新 profile，然后等待一个确认信号，超时时间默认约 30 秒；
2. deploy-rs 在你的管理机一侧，激活完成后立刻通过 ssh **重新连回目标机**并写入确认；
3. 若确认按时到达，部署成功收尾；
4. 若无法回连——典型原因正是新配置弄坏了 sshd、改错了防火墙、路由没了网——超时后激活脚本自动执行回滚，机器退回上一个 generation，你的连接随之恢复。

而 `autoRollback` 处理的是另一类失败：激活脚本本身返回非零（比如 activation 阶段报错），此时同样自动回退。两者合起来，把「一次失手的部署变成砖」这类事故的概率压到极低。也正因如此，**不要轻易关掉这两个开关**；确实要在虚拟机里部署没有网络弹性可言的环境时，才用 `--magic-rollback false` 显式关闭。

如果一次部署真的失败了且未自动回滚（例如超时设置过短），手工补救：

```console
# 在目标机本地（或经带外控制台）回滚到上一个 generation
$ sudo nixos-rebuild switch --rollback

# 或直接切换系统 profile 指向（等价于上面做法的底层形式）
$ sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch
```

deploy-rs 的定位是「把一台台 NixOS 安全地推到远端」，它不提供配置分发、密钥管理、批量编排这些更上层的概念。机器多了、需要按标签分组与并行时，往下看 colmena。

## 31.5 colmena：类 Ansible 的多机部署

colmena（西班牙语「蜂房」）把 NixOS 集群看作一个蜂巢：所有节点在同一个 flake 里声明，统一求值、并行构建、逐台上传激活，外加一套运维小工具。它的心智模型最接近 Ansible，但执行的是 NixOS 语义。

colmena 在 flake 中使用 `colmena` 输出声明节点（新版也可直接复用 `nixosConfigurations`，两种形式以官方手册为准）：

```nix
# flake.nix 节选：colmena 节点声明
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs }: {
    colmena = {
      meta = {
        # 集群默认使用的 nixpkgs 实例（按目标架构各取所需）
        nixpkgs = import nixpkgs { system = "x86_64-linux"; };
        # 透传给所有节点模块的额外参数，比如让模块里能用 self
        specialArgs = { inherit self; };
      };

      # 所有节点共享的公共配置（类似 Ansible 的 group_vars/all）
      defaults = { pkgs, ... }: {
        services.openssh.enable = true;   # 没有 ssh 就没有部署，先保住命脉
      };

      # —— 每个属性就是一个节点 ——
      web-01 = { name, nodes, pkgs, ... }: {
        deployment = {
          targetHost = "203.0.113.21";     # ssh 目标；缺省直接用节点名
          targetUser = "root";             # 缺省 root
          tags = [ "web" "prod" ];         # 用于 --on 选择分组
          allowLocalDeployment = true;     # 允许在节点本机运行 colmena apply-local
        };
        # 以下就是普通 NixOS 模块语法，与手写 configuration.nix 无异
        networking.hostName = "web-01";
        services.nginx.enable = true;
      };

      db-01 = { ... }: {
        deployment = {
          targetHost = "203.0.113.22";
          tags = [ "db" "prod" ];
        };
        services.postgresql.enable = true;
      };
    };
  };
}
```

节点模块可以拿到 `name`（自身节点名）与 `nodes`（全集群求值结果），因此能写出「应用服务器自动发现数据库地址」这类跨节点引用——这是纯 nixos-rebuild 做不到的。

**apply 流程**：`colmena apply` 会先在本机完成全部节点的求值与构建（默认并行），然后对每台目标机上传闭包并激活；也可以用 `--evaluator streaming` 应对超大规模集群的求值内存压力：

```console
# ✅ 部署整个集群（构建并行、推送并行、激活默认逐台确认）
$ colmena apply

# 只部署带 prod 标签的节点
$ colmena apply --on prod

# 目标机自己构建（弱机集群或管理机不便时的选项）
$ colmena apply --build-on-target

# 在节点本机执行（对应 allowLocalDeployment = true，适合笔记本这类「自己管自己」的机器）
$ colmena apply-local --sudo

# 只构建不上线：在 CI 里验证「全部节点至少能构建成功」非常有用
$ colmena build

# 部署后需要重启才能生效的变更，顺手安排重启
$ colmena apply --reboot
```

**密钥分发**是 colmena 相对 deploy-rs 的一个实打实的加分项。`deployment.keys` 让你在节点声明里直接描述密钥：构建侧不落盘明文，部署时经 ssh 写入目标机内存文件系统 `/run/keys`（重启即消失，随下次部署再注入）：

```nix
deployment.keys."wg-private" = {
  keyFile = ./secrets/wg-private.age;   # 从文件读取（也可用 text/command 提供）
  destDir = "/run/keys";                # 缺省即 /run/keys，权限默认 0600
  permissions = "0600";
};
# 服务里引用路径 "/run/keys/wg-private"，并声明 after 依赖确保注入完成再启动
```

**运维查询**则靠 `colmena eval` 与 `colmena exec`，两者组合能顶掉不少手写脚本：

```console
# 求值查询：列出每个节点的目标地址（表达式签名随版本可能微调，以手册为准）
$ colmena eval -E '{ nodes, ... }: builtins.mapAttrs (n: c: c.config.deployment.targetHost) nodes'

# 在一批机器上并行执行任意命令（Ansible 的 raw/shell 即视感）
$ colmena exec --on web -- uptime
```

## 31.6 其他方案速览

**NixOps** 在生态史上的地位值得单独一页（参见第 3 章）。它是最早的声明式云部署器：2013 年前后出现，能在 AWS/OpenStack 上「从零造机 + 部署 NixOS + 管理整套机器状态」，思路领先时代近十年，「基础设施也是 Nix 表达式」的很多理念由它首创。但 NixOps 2 的 flakes 化重写迟迟没有正式发布，社区把它拆成了 nixops-aws 等一系列插件仓库后维护节奏依然缓慢。⛔ 今天新项目不建议再选它，但阅读其论文与文档对理解「为什么 NixOS 适合声明式部署」极有营养。

**morph** 是较早的社区多机部署工具（读 flake/nix 表达式、ssh 推送激活）。⚠️ 功能上已被 colmena/deploy-rs 全面覆盖且更新不活跃，只在接手存量集群时可能遇到。

**朴素方案**不该被瞧不起。如果你只有两三台机器、部署频率不高，一个 20 行的 shell 脚本完全够用：

```bash
#!/usr/bin/env bash
# deploy.sh —— 朴素但可靠的「穷人的部署工具」
set -euo pipefail
for host in web-01 web-02 db-01; do
  # 先构建（本机），再推送到目标机激活；任何一步失败立即停
  nixos-rebuild switch --flake ".#$host" \
    --target-host "root@$host.corp.example" \
    --build-host localhost \
    || { echo "部署 $host 失败"; exit 1; }
done
```

什么时候该升级工具？当你开始需要：并行部署省时间、失败自动回滚、按标签分组、密钥分发、跨节点引用——任何两条命中，就值得引入 deploy-rs 或 colmena。

## 31.7 选型指南与完整拓扑

按规模和团队形态选型：

| 场景 | 推荐组合 | 理由 |
| --- | --- | --- |
| 个人 1 台（笔记本/工作站） | nixos-rebuild + flake | 无远程环节，工具越少越好 |
| 家里 3-5 台（homelab） | nixos-anywhere 装机 + nixos-rebuild --target-host 或 deploy-rs | 一台管理机推全家；magic rollback 对物理机尤其珍贵 |
| 团队 10-100 台 | colmena（或 deploy-rs）+ CI + cachix | 需要 tags、并行、审计；部署权限收敛到 CI |
| 云上大规模 | Terraform/OpenTofu 造机 + nixos-anywhere 初始化 + colmena 日常运维 | 造机归 IaC 工具，系统归 Nix；两者经 userdata/启动脚本交接 |
| 全新裸机/云 VM 初始化 | nixos-anywhere + disko | 任何规模下的标准答案 |

当规模超过「一台笔记本」时，推荐把部署升级成一条流水线，完整拓扑如下：

```
        ┌────────────────────────────────────────────────────┐
        │        配置仓库（flake.nix + flake.lock + hosts/）    │
        │        评审（PR）通过后才允许进入主干                  │
        └───────────────────────┬────────────────────────────┘
                                │ git push（人工或合并按钮）
                                ▼
        ┌────────────────────────────────────────────────────┐
        │                  CI（GitHub Actions）                │
        │   nix flake check（求值+测试） → nix build（构建）     │
        │   → cachix push（把产物推到团队二进制缓存）             │
        └──────────┬──────────────────────────┬───────────────┘
                   │                          │
                   ▼                          ▼
        ┌──────────────────┐        ┌──────────────────────┐
        │  二进制缓存 cachix │        │  运维机 / 发起人本机    │
        │  （存闭包，按需取） │        │  colmena apply / deploy│
        └─────────┬────────┘        └──────────┬───────────┘
                  │ 缓存命中则免构建               │ ssh 上传差量闭包
                  ▼                             ▼
        ┌────────────────────────────────────────────────────┐
        │           目标机器群（1..N 台 NixOS 节点）             │
        │   /nix/store ← 闭包就位；system profile 指向新代      │
        └────────────────────────────────────────────────────┘
```

这套拓扑的关键分工：**CI 负责构建与缓存，部署工具只负责传输与激活**。这样即使目标机与管理机都很弱，部署也只是「从 cachix 拉产物 + 换软链接」，秒级完成；而任何人在任何机器上重新构建，得到的都是同一份闭包（第 16 章的构建可复现性在部署侧的兑现）。

## 31.8 与 Ansible/Puppet 的对比

Ansible 与 Puppet 也解决「把机器变成期望状态」的问题，为什么 NixOS 圈子还要造自己的轮子？差别在「期望状态」的定义深度。

Ansible/Puppet 的模型是**收敛循环（convergence loop）**：你描述期望状态（「nginx 已安装、配置文件内容为 X、服务在运行」），工具逐步执行操作，然后检查现实与期望的差距，反复迭代直到一致。这个模型有三个固有摩擦：

- **状态漂移检测靠运行时**。模块作者必须为每种资源实现「检查是否已一致」的逻辑，实现不完美就会出现「每次运行都显示 changed」的假变更；
- **修改是过程式的**。改配置 = 推新文件 + reload 服务，中间态可能半新半旧；失败后回滚需要你额外写 playbook；
- **宿主系统是黑盒**。工具没法知道系统里还有什么，`apt` 装过的包、上次手改的 `/etc/nginx/nginx.conf`，都在模型之外。

NixOS 把「期望状态」推进到了**全系统闭包**：求值配置的那一瞬间，整个系统的内容就完全确定了——每一个文件的字节、每一个服务的单元、内核与 glibc 的确切版本。由此：

- **幂等性来自构造而非收敛循环**。不存在「检查是否一致」这一步，因为激活动作本身就是把系统整体切换到一个数学上确定的值；已在新闭包里的东西不会再动（第 27 章的 diff 激活）；
- **回滚是免费的**。旧 generation 的闭包还在 store 里，指回去就完成回滚（第 18、27 章）；
- **没有隐藏状态**。系统里所有内容都出自求值结果，`/etc` 里的文件是激活脚本从 store 链接/生成的，不存在「上一次手动改过什么」。

那 Ansible 还有用吗？当然。当你管理的机器大多**不是** NixOS（存量 CentOS、网络设备、云资源），或者需要编排 Nix 之外的动作（数据库迁移、工单审批流），Ansible 依然是好工具。一个务实的混合架构很常见：Ansible 管「非 Nix 资产与流程」，colmena 管 NixOS 机群。甚至有人用 Ansible 触发 `colmena apply`——毕竟对 Ansible 来说，跑一条命令是它最擅长的事。

## 31.9 本章小结

- 部署 NixOS = 三个原子动作：**构建**系统闭包、**传输**闭包差量、**激活**（switch-to-configuration）；一切部署工具都是这三步的不同包装。
- nixos-rebuild 内置 `--target-host` / `--build-host` 远程部署；建议显式写出两个 host，非 root 用户配合 `--use-remote-sudo`。
- 密钥分发是部署的隐藏第四步：store 全局可读，明文密钥不能进配置；解法有 colmena 的 deployment.keys、nixos-anywhere 的 --disk-encryption-keys、以及 sops-nix/agenix。
- nixos-anywhere + disko 是全新机器（裸机/云 VM）的标准安装流程：救援系统 + ssh → kexec 临时环境 → 声明式分区 → nixos-install --flake，装机过程本身进入版本库。
- deploy-rs 的 magic rollback 在激活后要求工具回连确认，超时自动回滚，专治「新配置弄坏 sshd 变砖」类事故。
- colmena 提供 tags、并行、deployment.keys、eval/exec 运维查询，是多机规模下最接近 Ansible 体验的选择。
- NixOps 是声明式云部署的开山之作但已维护缓慢；两三台机器时，nixos-rebuild 加 shell 脚本的朴素方案完全够用。
- 成规模的正确拓扑是「配置仓库 + CI 构建 + cachix 缓存推送 + 部署工具只管传输激活」；与 Ansible 的本质区别在于 NixOS 把期望状态推进到全系统闭包，幂等性来自构造而非收敛循环。

## 延伸阅读

- NixOS 手册：使用 nixos-rebuild 部署到其他机器 —— https://nixos.org/manual/nixos/stable/#sec-changing-config
- nixos-anywhere（官方仓库与文档）—— https://github.com/nix-community/nixos-anywhere
- disko（声明式磁盘管理）—— https://github.com/nix-community/disko
- deploy-rs —— https://github.com/serokell/deploy-rs
- colmena 手册 —— https://colmena.cli.rs/unstable/
- NixOps（历史项目）—— https://github.com/NixOS/nixops
- NixOS Wiki：部署工具综述 —— https://wiki.nixos.org/wiki/Deployment
