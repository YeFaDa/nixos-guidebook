# 第 26 章 激活机制：activation scripts

> **本章导读**：第 23 章时间线里的第 ③ 步「激活」是 rebuil 与真实系统之间的桥梁：把刚构建出的系统闭包「落实」为机器上的可变状态——生成 /etc、创建用户、写 tmpfiles。本章拆解 `activate` 脚本的内部结构、`environment.etc` 的投影机制、setuid wrappers，以及如何安全地加入自定义激活逻辑。

## 26.1 激活要解决什么

store 里的东西是**不可变的**，而一台机器的运行状态必须有可变的部分：

- `/etc` 必须真的存在（符号链接指向 store）；
- 用户与组的数据库（`/etc/passwd` 等）是会变的状态；
- `/tmp`、`/run`、运行时目录需要按规则创建；
- 某些程序需要 setuid 位（不可变文件系统上无法直接 chmod）。

**激活（activation）= 以新系统闭包为输入，把机器的可变状态「收敛」到与之一致**。执行者是系统闭包里的 `activate` 脚本（`nixos/modules/system/activation/activation-script.nix` 生成），它由几十个具名的「激活脚本片段」按依赖顺序拼装而成。

## 26.2 activation script 的结构：片段、依赖、顺序

每个片段是一个名字 + 一段 bash + 它依赖的其他片段：

```nix
# NixOS 内部使用的描述形态（用户也可用同样接口添加，见 26.6）
system.activationScripts.etc = {
  # （内部表示：script 文本 + deps 列表）
};
```

激活总脚本 `activate` 的骨架（逐段注释，源自 nixos/modules/system/activation/activate.sh，节选意译）：

```bash
# stage 2 init 或 switch-to-configuration 会调用本脚本

systemConfig=$(readlink -f .)        # 本次激活的系统闭包路径

# ① 基础环境：PATH 指向新系统的工具
PATH=/nix/var/nix/profiles/system/base/bin ...

# ② 按依赖拓扑序执行全部片段，典型顺序（完整清单见 /run/current-system/activate 里）
#    - specialfs   ：挂载特殊文件系统（/proc /sys /dev /run 已由早期 init 保证）
#    - etc         ：同步 /etc（26.3 节核心）
#    - users       ：声明式用户与组 → /etc/passwd /etc/group、家目录
#    - groups      ：组同步
#    - tmpfiles    ：systemd-tmpfiles --create（按 systemd 规则建运行时目录）
#    - wrappers    ：setuid 包装器（26.5 节）
#    - ...其他（各模块注册的片段）

# ③ 标记激活完成
touch /run/nixos/activation-completed ...
```

观察自己机器的激活全貌（推荐实验）：

```console
$ less /run/current-system/activate        # 总脚本（可读的 bash）
$ grep -n "^# " /run/current-system/activate | head -30   # 各片段的注释分隔
```

## 26.3 /etc 的投影机制精讲

模块系统把所有 `environment.etc.*` 声明合并成 `config.environment.etc`——一个 `attrsOf` 类型的大属性集；激活时按每个条目的**模式**生成 `/etc` 下的实体：

```nix
environment.etc = {
  # 模式一：source（默认）—— 符号链接到 store 路径（不可变投影）
  "nginx/nginx.conf".source = "${nginxConf}";   # → /etc/nginx/nginx.conf -> /nix/store/...

  # 模式二：text —— 文本内容直接生成为 store 文件再链接
  "myapp.conf".text = ''
    log_level = debug
  '';

  # 模式三：copy —— 复制为普通文件（可被本地工具就地修改，下次激活覆盖）
  "myapp/local.conf".copyForBinary?  # 准确的参数是 mode/user/group/target 等，见下
};
```

精确的条目属性（`man configuration.nix` 的 environment.etc.<name>）：

| 属性 | 作用 | 默认 |
|------|------|------|
| `source` / `text` | 内容来源 | — |
| `mode` | 权限 | `"symlink"`；文本默认 0644 |
| `user` / `group` | 属主 | root |
| `target` | 实际路径（允许 etc."x".target 改名） | 名字本身 |

**同步策略**：激活时对比 `/etc` 现状与目标清单——该建的链接建上、该删的（上一代有、这一代没有的受管条目）移除；不受管的文件一律不动。这解释了两个日常现象：

1. 手改受管文件 → 下次 rebuild 被覆盖（本体在 store，链接重建即「还原」）；
2. `/etc` 下不属于任何声明的文件（如某些软件自建的）安然无恙。

## 26.4 用户与组：声明式化 /etc/passwd

`users.users.*` 声明在激活时被 `users` 片段翻译成账户数据库：

```nix
users.users.alice = {
  isNormalUser = true;          # uid 自动分配、建家目录、常用组
  extraGroups = [ "wheel" "networkmanager" ];
  shell = pkgs.fish;
  openssh.authorizedKeys.keys = [ "ssh-ed25519 AAAA..." ];
  hashedPassword = "$y$j9T$...";   # mkpasswd -m sha-512 生成（勿用明文！）
};
users.mutableUsers = false;     # 关：/etc/passwd 等完全由声明生成
```

`mutableUsers = true`（默认）时 `passwd`/`useradd` 可用（改动存活于本地文件，声明只做初建）；`false` 时激活脚本每次把账户库重写为声明形态——**忘写密码就重装**的喜剧由此可能发生（救援方法第 30、45 章）。

## 26.5 setuid wrappers：不可变世界的特权通道

`/nix/store` 只读，无法给二进制 chmod u+s；而 `sudo`、`ping`、`passwd` 等需要特权位。NixOS 的方案是 **wrapper**：编译出极小的 C 包装器（带 setuid 位，位于可写的 `/run/wrappers/bin/`），内部再 exec store 里的真实程序：

```
$ ls -l /run/wrappers/bin/sudo
-r-sr-xr-x 1 root root ... /run/wrappers/bin/sudo   ← 有 setuid 的包装器
$ file /run/wrappers/bin/sudo
ELF ... （execve 到 /nix/store/...-sudo/bin/sudo）
```

声明接口：`security.wrappers.<name> = { source = ...; owner = "root"; group = ...; setuid = true; };`。这是「不可变 + 特权」共存的教科书设计（对比：传统发行版直接 chmod store 外的文件）。

## 26.6 编写自己的激活脚本

接口与系统片段一致（`system.activationScripts.<名字>`），要点：**声明依赖、幂等、快**：

```nix
{ config, lib, pkgs, ... }:
{
  system.activationScripts.setupDataDir = {
    # deps：在本片段之后才运行的其他片段（保证 etc/users 先就绪）
    deps = [ "etc" "users" ];
    text = ''
      # 幂等：存在即跳过（激活可能反复发生）
      if [ ! -d /srv/mydata ]; then
        mkdir -p /srv/mydata
        chown myapp:myapp /srv/mydata
      fi
    '';
  };
}
```

三条纪律：

1. **必须幂等**——同一代系统可能被反复激活（重启、回滚、修复）；
2. **只做「机器状态」的事**——数据初始化属于服务自身（unit 的 ExecStartPre）而非系统激活（职责边界见第 30 章）；
3. **慢操作是大忌**——激活阻塞 rebuild 与开机（stage 2 里也执行），网络请求之类绝不要放进来。

⚠️ 一个常见误区：把「每次启动都要做」的事写进激活脚本。激活只在**切换到某一代时**跑一次，重启同一代不会重跑——开机级任务应该用 systemd unit（`serviceConfig.Type=oneshot` + `wantedBy = multi-user.target`，第 29 章）。

## 26.7 dry-activate：彩排模式

`nixos-rebuild dry-activate` 构建并求值一切，但激活阶段只打印「将会做什么」而不执行——适合在危险变更（大规模用户调整、防火墙规则）前预览。`nixos-rebuild test` 则激活但不注册新代/不更新开机菜单（重启后回到旧代），适合实验。

## 26.8 本章小结

- 激活 = 把不可变闭包收敛为机器可变状态；`activate` 由几十个按依赖拓扑排序的片段组成。
- /etc 是投影：source/text 链到 store，copy 模式可本地改写；不受管文件不受影响。
- 用户与组由激活生成；`mutableUsers=false` 走向完全声明式（注意锁死风险）。
- setuid 通过 /run/wrappers 的 C 包装器实现，接口是 security.wrappers。
- 自定义片段三纪律：幂等、快速、只管机器状态；开机任务交给 systemd unit 而非激活。

## 延伸阅读

- 源码：nixos/modules/system/activation/（activate.sh、activation-script.nix——短小精悍，强烈推荐通读）
- 手册 «Changing Configuration»：https://nixos.org/manual/nixos/stable/#sec-changing-config
- 第 27 章（switch-to-configuration）承接：激活之后如何切换系统代。
