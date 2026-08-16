# 第 28 章 启动流程：从 bootloader 到登录提示符

> **本章导读**：NixOS 把「整机」变成 store 里的一个闭包，但 CPU 不懂 store——它只会从固件开始执行。本章跟随一次完整的加电过程：UEFI/BIOS → 引导加载程序 → initrd（stage 1）→ 系统初始化（stage 2）→ systemd → 登录提示符，看清每一环如何被 Nix 化、generation 菜单如何生成、以及启动出问题时的救援手段。

## 28.1 全景：五幕剧

```
第一幕  固件（UEFI/BIOS）
        │ 找到启动项（NVRAM 里的 systemd-boot 或磁盘 MBR 的 GRUB）
        ▼
第二幕  引导加载程序（systemd-boot / GRUB）
        │ 读 /boot/loader/entries/nixos-generation-*.conf
        │ 菜单 = 全部保留的 generation（第 27 章注册的）
        ▼
第三幕  initrd（初始内存盘，stage 1）
        │ 加载内核 + 挂载真正的根文件系统（含 /nix/store）
        ▼
第四幕  stage 2：系统初始化
        │ 切根 → 准备 /run /etc → 运行激活（第 26 章）→ exec systemd
        ▼
第五幕  systemd（PID 1）
        │ 按 target 依赖拉起服务 → getty/显示管理器 → 登录
```

每一幕的「Nix 特色」：第二幕的菜单内容由 profile 链生成；第三幕的 initrd 是一个派生输出；第四幕执行的是系统闭包里的脚本；第五幕的单元文件全部来自模块系统求值。

## 28.2 第一、二幕：固件与引导加载程序

### 28.2.1 systemd-boot（UEFI 推荐）

```nix
boot.loader.systemd-boot.enable = true;
boot.loader.efi.canTouchEfiVariables = true;   # 允许写 NVRAM（注册启动项）
boot.loader.systemd-boot.configurationLimit = 10;   # 菜单保留 10 代
```

NixOS 在每次注册新代时（第 27 章）向 `/boot/loader/entries/` 写入条目文件：

```ini
# /boot/loader/entries/nixos-generation-118.conf —— 生成物，逐行注释
title   NixOS - Generation 118            # 菜单显示名
version generation-118                    # 代号
linux   /efi/.../bzImage-6.12.x           # 内核（从 store 复制或 stub）
initrd  /efi/.../initrd-6.12.x            # initrd
options init=/nix/store/xxxx-system-118/init systemConfig=/nix/store/xxxx-system-118
        #  ↑ 告诉内核：PID 1 之前先跑这个 init；systemConfig 指明本代闭包
```

回滚菜单（`Generation 117`、`116`……）就是这些条目的罗列——**回滚的全部基础设施只是一堆文本文件加符号链接**。

### 28.2.2 GRUB（BIOS / 复杂需求）

```nix
boot.loader.grub.enable = true;
boot.loader.grub.device = "/dev/sda";           # MBR 安装（BIOS）
# UEFI 下用 efifsInstall? 准确：boot.loader.grub.efiSupport + efiInstallAsRemovable
boot.loader.grub.useOSProber = true;            # 多系统菜单（可选）
```

GRUB 路线的 `grub.cfg` 同样由 Nix 生成，generation 以 menuentry 形式出现。选型经验：UEFI 机器默认 systemd-boot（简单、快）；需要 btrfs 快照引导、多系统精细控制时用 GRUB。

## 28.3 第三幕：initrd（stage 1）

### 28.3.1 initrd 是什么、里面有什么

initrd（initial RAM disk）是压缩的迷你根文件系统，内核先把它的内容当作根挂载，用它去找到真正的根设备。NixOS 的 initrd 是一个派生输出，内容随配置生成：

```
initrd 内部（概念）：
├── init                          # stage 1 主脚本（或 systemd，见 28.3.3）
├── kernel-modules/               # 挂根所需的最小模块集（文件系统、加密、存储驱动）
│     # 由 boot.initrd.availableKernelModules 控制
├── 密钥材料（initrd-secrets）     # boot.initrd.secrets 注入的解锁密钥等
└── busybox 等基础工具
```

### 28.3.2 stage 1 脚本干了什么（传统路径）

`boot.initrd.systemd.enable = false`（传统默认路径）时，init 是一段 bash 脚本（逐段注释其主线）：

```bash
# ① 解析内核命令行（从 bootloader 传来的 options）
#    拿到 root=/dev/... 或 LABEL=/UUID=...、systemConfig=...
# ② 加载内核模块（存储控制器、文件系统、LUKS……）
# ③ 处理键盘布局（早期输入需要，如 LUKS 密码）
# ④ 逐层解锁与挂载：
#      LUKS 分区 → cryptsetup open
#      LVM/RAID/btrfs 子卷 → 相应工具
#      挂载真实根到 /mnt-root? （内核参数 root= 指向的设备）
# ⑤ 把 /run 挂为 tmpfs（early 的 /run）
# ⑥ 切根：mount --move + switch_root 到真实根
#    执行 init=/nix/store/...-system-118/init（进入 stage 2）
# 任何一步失败 → 掉进救援 shell（U troubleshoot 见 28.6）
```

配置入口速览：

```nix
boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "ahci" ];
boot.initrd.kernelModules = [ "dm-snapshot" ];
boot.initrd.luks.devices."root".device = "/dev/disk/by-uuid/....";
boot.initrd.secrets = { "/crypto_keyfile.bin" = ./secret.bin; };  # ⚠️ 明文进 initrd！
```

### 28.3.3 systemd in initrd（现代路径）

`boot.initrd.systemd.enable = true` 把 stage 1 也交给 systemd 管理（近年已趋可用）：init 换成 systemd，各步骤变成 `.target`/`.service`（`initrd-nixos-...`），优点是依赖管理正规化、日志进 journal、与 `systemd-cryptsetup` 等现代组件统一。新旧路径并存，配置项大多两用；新装机在支持的硬件上可以尝试（以当前版本文档为准）。

## 28.4 第四幕：stage 2 —— 系统初始化

`systemConfig/init` 脚本（概念上仍是 bash，逐段注释主线）：

```bash
# ① 早期环境：PATH 指向本代闭包的工具
# ② 挂载特殊文件系统：/proc /sys /dev（若 initrd 未完成）
#    以及关键一步：确认 /nix 可用（stage 1 已挂载真实根，
#    /nix/store 在根分区上——这就是 NixOS 分区布局的硬要求）
# ③ 挂 /run（tmpfs）、/tmp（按 boot.tmp.useTmpfs 配置）
# ④ 准备 /etc：把 systemConfig/etc 的内容激活（调用第 26 章的 activate：
#    符号链接、用户、wrappers、tmpfiles 全在这里落地）
# ⑤ 写 /run/current-system → systemConfig
# ⑥ exec systemConfig/systemd（或其 init）—— systemd 成为 PID 1
```

注意与运行期 rebuild 的差异：**开机时的激活是「同代重放」**（第 26 章幂等性要求的原因之一）；而运行期 rebuild 是「新代激活 + 单元 diff」（第 27 章）。

## 28.5 第五幕：systemd 与登录

systemd 作为 PID 1 后：

```
default.target（通常 graphical.target 或 multi-user.target）
├── 基础：local-fs.target、swap.target、network.target ...
├── 用户会话：getty@tty1（多用户）或 display-manager（图形）
│     # 服务型机器：sshd 被 multi-user.target 拉起（第 29 章）
├── 全部 NixOS 声明的服务（按第 25 章求值出的单元图）
└── 用户级：systemd --user 实例（Home Manager 的工作层）
```

观察启动全景的命令：

```console
$ systemd-analyze           # 各阶段耗时
$ systemd-analyze blame     # 每个服务耗时（排序）
$ systemd-analyze critical-chain   # 关键路径
$ journalctl -b             # 本次启动的全部日志
$ journalctl -b -p err      # 只看错误级
```

## 28.6 排错：进不去系统怎么办

**救援 shell（stage 1 失败）**：`boot.shell_on_fail`（内核参数或配置项）让 initrd 失败时给一个 busybox shell——修复后 `exec stage2` 继续? （以文档为准）；紧急时也可在 bootloader 菜单按 `e` 给内核行临时加参数。

**开机菜单回滚**：菜单里选旧代（第 27 章）——90% 的「昨晚 update 挂了」由此秒解。

**从 live USB 修**（chroot 大法，完整命令）：

```console
# live 环境中：
$ sudo mkdir -p /mnt
$ sudo mount /dev/nvme0n1p2 /mnt            # 根分区
$ sudo mount /dev/nvme0n1p1 /mnt/boot       # EFI 分区
$ sudo nixos-enter                           # NixOS live 自带：直接进入旧系统环境
# （或在任意 Linux 上手动：mount --bind /dev /proc /sys 后 chroot）
# 进入后可以：改配置重新 rebuild、--rollback、检查日志
```

**激活失败循环**：开机进的是坏代时，菜单选前一代；修好配置再 switch 新代覆盖。

## 28.7 本章小结

- 启动五幕：固件 → bootloader → initrd（stage 1）→ 系统初始化（stage 2）→ systemd。
- 引导菜单条目由 generation 生成，`init=` 与 `systemConfig` 内核参数指定本代闭包；回滚基础设施 = 条目文件 + 符号链接。
- initrd 负责解锁并挂载真根；传统脚本路径与 systemd-in-initrd 并存。
- stage 2 挂特殊文件系统、重放激活（幂等）、切 /run/current-system、exec systemd。
- 排错三板斧：shell_on_fail、菜单回滚、live USB + nixos-enter。

## 延伸阅读

- 手册 «Boot» 章节：https://nixos.org/manual/nixos/stable/#sec-boot
- 源码导览：nixos/modules/system/boot/stage-1-init.sh、stage-2-init.sh（短小，值得通读）
- 第 29 章（systemd 之后的世界）承接本章第五幕。
