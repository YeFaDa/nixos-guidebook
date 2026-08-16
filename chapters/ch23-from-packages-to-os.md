# 第 23 章 从包到操作系统：NixOS 的构建哲学

> **本章导读**：NixOS 最迷人的一句话是「整台机器是一个派生」。本章把这句话拆开验证：系统闭包 `config.system.build.toplevel` 里装了什么；`/run/current-system`、`/etc`、用户环境如何从 store 生成；一次 `nixos-rebuild switch` 从回车到新系统生效的完整时间线。读懂本章，NixOS 对你不再是黑魔法，而是一台可以拆开看的机器。

## 23.1 整机即派生：toplevel

第 25 章会讲模块系统如何把几百个模块的声明求值成一份 `config`；本章直接看求值的最终产物——**系统闭包的入口派生**：

```nix
# 求值结果（概念）：
config.system.build.toplevel
# = /nix/store/xxxxxx-nixos-system-26.05.xxxx.xxxx
```

这个 store 路径的内部结构（逐项注释）：

```
/nix/store/...-nixos-system-26.05/
├── kernel                  → /nix/store/...-linux-6.12.x/kernel      （内核镜像）
├── initrd                  → /nix/store/...-initrd-linux/...          （初始内存盘，第 28 章）
├── init                    → /nix/store/...-stage-2-init/...          （系统初始化脚本）
├── initrd-entry?           （bootloader 条目所需的一切入口）
├── etc                     → /nix/store/...-etc/etc                   （整个 /etc 的模板，第 26 章）
├── systemd                 → /nix/store/...-systemd-257.x             （PID 1 本体）
├── units/                  （本机生成的全部 systemd 单元，第 29 章）
├── activate                （激活脚本：闭包 → 真实系统，第 26 章）
├── switch-to-configuration （系统切换脚本，第 27 章）
├── system-path             （environment.systemPackages 组成的用户环境）
└── kernel-modules          （本内核的模块树）
```

三条等价引用指向它：

```
/run/current-system      → /nix/store/...-system-...（当前运行系统；激活时切换）
/nix/var/nix/profiles/system-<N>-link → 同一路径（第 N 代系统；GC root）
/boot/.../nixos-generation-<N>.conf   → bootloader 条目引用它（第 28 章）
```

**「回滚」的全部秘密**：旧代的 profile 链接从未删除（受 GC root 保护），开机菜单按链接生成条目（第 27、28 章）。系统切换 = 切符号链接 + 激活，仅此而已。

## 23.2 系统闭包里有什么：一次实地观察

```console
# 我这台机器的系统闭包（-r 递归）：
$ nix path-info -r /run/current-system | wc -l
812
# 812 个 store 对象：内核、glibc、systemd、全部启用的服务及其依赖……
# 它们构成「让这台机器跑到当前状态」的全部所需（第 17 章闭包概念）

$ nix path-info -rS /run/current-system | sort -k2 -n | tail -3
# 闭包中最大的三个对象（-S 显示闭包大小贡献）
```

把这 812 个对象复制到一台裸机（`nix copy --to ssh://newhost`），再装上 bootloader 条目——那就是一台一模一样的系统。NixOS 的部署、镜像构建、测试框架（第 31、41 章）全部建立在这个事实上。

## 23.3 /etc：声明的投影

NixOS 的 `/etc` 是「投影」而非「本体」——本体在 store 里，由所有模块的 `environment.etc.*` 声明合并生成（机制细节在 26 章）：

```nix
# 模块里写：
environment.etc."nginx/nginx.conf".source = ...;   # → /etc/nginx/nginx.conf 是符号链
environment.etc."myapp.env".text = ''
  KEY=value
'';                                                 # → 文本直接生成的文件
```

```console
$ ls -l /etc/hostname /etc/nginx/nginx.conf
lrwxrwxrwx ... /etc/hostname -> /nix/store/2x1...-hostname
lrwxrwxrwx ... /etc/nginx/nginx.conf -> /nix/store/8kk...-nginx.conf
```

推论（NixOS 的「宪法条款」）：

- **手改 /etc 下的受管文件是无意义的**——下次激活被覆盖；正确做法是改配置声明（第 30 章讲如何与非声明式的软件共处）；
- `/etc` 里少数文件是「本地状态」（如 `/etc/machine-id`、`/etc/NIXOS` 标记），由激活脚本维护。

## 23.4 system-path：全局命令从哪来

`environment.systemPackages = [ ... ]` 的产物是 `toplevel/system-path`——一个 `buildEnv`（第 35 章）聚合的用户环境，把所有包的 `bin/`、`share/` 等按优先级合并成一棵树，再通过 `/run/current-system/sw` 进入所有人的 `PATH`：

```
$PATH 里的 /run/current-system/sw/bin/git
   → /run/current-system/sw/bin（合并视图）
   → 实际来自 /nix/store/...-git-2.47/bin/git
```

这个设计同时解释了：为什么 `environment.systemPackages` 里的程序「所有人都能用」（它在系统 PATH）；为什么 `nix-env` 装的包只有当前用户能见（用户 profile 优先级在 system-path 之前，第 18 章）；以及为什么 NixOS 上不该往 `/usr/local` 手装东西（系统闭包不含它，心智模型会碎）。

## 23.5 用户与组：也是声明

`users.users.<name>` 声明被「激活脚本」翻译成 `/etc/passwd`、`/etc/group` 与家目录（细节第 26、30 章）。默认 `users.mutableUsers = true`（可用 `passwd` 命令，改动落在本地状态文件）；置 `false` 后用户体系完全声明式（密码哈希也进配置）。这是「无状态哲学」的第一现场。

## 23.6 一次 rebuild 的完整时间线

把已学的机制串成一条时间线（命令细节第 24 章，这里看流程）：

```
$ nixos-rebuild switch --flake .#myhost
│
├─ ① 定位与求值（秒级）
│    读 flake.nix → 求 nixosConfigurations.myhost
│    → lib.nixosSystem：组装 ~1500 个模块（第 25 章）→ config
│    → config.system.build.toplevel = 一棵 .drv 树
│
├─ ② 构建/下载（取决于改动量）
│    逐个 .drv：先查 substituter 缓存（第 20 章）→ 命中则下载
│    未命中则本地沙箱构建（第 16 章）
│    NixOS 上通常绝大多数命中 cache.nixos.org（改的只是配置）
│
├─ ③ 激活（秒级，系统正在运行中）
│    新 toplevel/activate（第 26 章）：
│      - 挂载/同步 /etc、生成用户、tmpfiles……
│    新 toplevel/switch-to-configuration switch（第 27 章）：
│      - 切 /run/current-system 符号链接
│      - diff 新旧 systemd 单元 → reload/restart 变更的服务
│
├─ ④ 注册新代（瞬间）
│    /nix/var/nix/profiles/system-118-link → 新 toplevel
│    （旧代 system-117-link 原样保留 = 免费回滚点）
│
└─ ⑤ 写入 bootloader 菜单（瞬间）
     新条目 "NixOS - Generation 118"（下次开机可直接选 117 回滚）
```

五步全部原子可回滚：②③④ 任何一步失败，旧代的链接与菜单都没动过。

## 23.7 与传统发行版的机制对照

| 传统世界 | NixOS 世界 | 本体所在 |
|----------|-----------|---------|
| `apt install` 装的命令 | system-path / 用户 profile 里的包 | store 对象 |
| 手编辑的 /etc/nginx/... | 模块声明的投影 | store 对象 |
| `/lib/systemd/system/*.service` | 模块生成的单元 | store 对象 |
| `update-grub` + 内核包 | bootloader 条目 = 各代 profile | store 对象 |
| `useradd` 的结果 | users.users 声明 | 激活产物 |
| live CD + 脚本复装机 | 同一 flake 再求值一遍 | git 仓库 |

一列看下来：**NixOS 把「系统的一切」都变成了 store 对象或 store 对象的投影**。这就是「Nix 构建成 OS」的全部哲学——不是把包管理器塞进 Linux，而是把 Linux 装进纯函数模型。

## 23.8 本章小结

- 整机入口是 `config.system.build.toplevel`：内核、initrd、init、/etc 模板、单元、激活与切换脚本、system-path 全在一个闭包里。
- `/run/current-system` 指向当前系统；profile 链 = generation = 回滚单位；bootloader 菜单由代生成。
- /etc 与系统命令都是「store 的投影」，手改无效是设计而非缺陷。
- rebuild 时间线：求值 → 构建或下载 → 激活 → 注册新代 → 更新菜单；全程可回滚。
- NixOS 与传统的差别一句话：系统的一切要么是 store 对象，要么是 store 对象的投影。

## 延伸阅读

- NixOS 手册 «Changing Configuration»（rebuild 的官方叙述）：https://nixos.org/manual/nixos/stable/#sec-changing-config
- 源码导览：nixos/modules/system/activation/（activate 脚本）、nixos/lib/make-system-toplevel.nix
- 第 25 章（模块系统如何求值出 config）、第 26/27 章（激活与切换）是本章的微观续集。
