# 第 27 章 switch-to-configuration：系统切换的内部

> **本章导读**：第 23 章时间线的第 ③ 步后半：激活脚本把闭包「落实」为机器状态之后，还需要有人来回答三个问题——正在运行的服务怎么办？`/run/current-system` 何时切？新系统代何时注册？这个「 jemand」就是系统闭包里的 `switch-to-configuration` 脚本。理解它，就理解了「为什么改了配置大部分服务不用重启机器」以及「为什么有些改动提示你必须重启」。

## 27.1 它是谁、谁在调用它

每个系统闭包的 toplevel 里都有一个可执行文件：

```
/run/current-system/switch-to-configuration   # 旧代里同样存在
```

`nixos-rebuild` 的四种动作最终都以不同参数调用**新代**的这个脚本：

```console
$ nixos-rebuild switch   # → switch-to-configuration switch   激活+切换+注册新代
$ nixos-rebuild boot     # → 只构建+注册新代+更新引导菜单（不动当前系统）
$ nixos-rebuild test     # → switch-to-configuration test      激活但不注册（重启回旧代）
$ nixos-rebuild dry-activate  # → 激活彩排（打印将做的事，不执行）
```

它本身是 bash 脚本（nixos/modules/system/activation/switch-to-configuration.pl——历史上曾是 Perl 实现，现代版本已迁移为 bash/nix 生成，具体以源码为准），干三件事：

1. **对比新旧系统的 systemd 单元**，决定哪些要 reload/restart/stop/start；
2. **切换 `/run/current-system` 符号链接**到新代；
3. **注册新代**（profile-N-link）并调用 bootloader 更新菜单。

## 27.2 核心：systemd 单元的 diff 策略

系统正在运行，而新旧两代的 `/etc/systemd/system`（单元文件）与「期望状态」发生了差异。脚本的决策表（简化但语义准确）：

| 差异情况 | 动作 | 说明 |
|----------|------|------|
| 新代新增单元且 `wantedBy` 生效 | `systemctl start` | 新服务直接拉起 |
| 新代删除了单元 | `systemctl stop` + 禁用 | 旧服务停止 |
| 单元文件内容变化 | 默认 **restart**（stop+start） | 保证运行态=声明 |
| 单元声明了 `X-Reload-Changes`? / 服务支持 reload 且只有 `ExecReload` 相关变化 | `systemctl reload` | 无缝重载（nginx 重读配置） |
| 仅 target/挂载等非服务单元变化 | 按类型处理 | |
| 内核/initrd 变化 | 无法热切换 | 输出警告：需要重启（`boot` 动作已备好新代） |

**reload 还是 restart 的精确机制**：脚本比较新旧单元文件，若变化仅涉及「可重载」的部分且单元配置了 reload 能力（`ExecReload` 存在且单元未被声明为需要重启），用 reload；其余变化 restart。模块作者可以通过服务的 `reload` 选项与 unit 的 `restartTriggers` 精细影响这一决策：

```nix
# 模块作者视角：配置文件变了应该 reload 而不是 restart
systemd.services.nginx = {
  reload = ''
    ${lib.getBin pkgs.nginx}/bin/nginx -s reload
  '';
  # restartTriggers：这些值变化时强制 restart（比如 ssl 证书内容）
  restartTriggers = [ config.environment.etc."nginx/nginx.conf".source ];
};
```

`switch-to-configuration` 在 diff 时把 `restartTriggers` 编码进单元文件的环境里——值变则「单元文件变了」，触发对应动作。这是模块作者表达「这种变化需要何种响应」的标准通道。

## 27.3 一次 switch 的实操观察

```console
# 先跑一次彩排，看看会发生什么
$ nixos-rebuild dry-activate
...
activating the configuration...
reloading user units for alice...
setting up /etc...
reloading the following units: home-manager-alice.service
the following new units were started: backup.timer
# ↑ dry 模式下只打印；真实 switch 才执行

$ nixos-rebuild switch
building Nix...
building the system configuration...
activating the configuration...
setting up /etc...
restarting the following units: nginx.service
the following new units were started: myapp.service myapp.timer
```

输出里的每一行都来自 27.2 的决策表。**注意它从不自动重启整个机器**——涉及内核的变更只提示：

```
warning: the following NixOS configuration changes are incompatible
and require a reboot to take effect:
  - new kernel
```

## 27.4 系统代与回滚的完整闭环

switch 成功后：

```
/nix/var/nix/profiles/system-118-link → /nix/store/NEW-toplevel   ← 新注册
/nix/var/nix/profiles/system-117-link → /nix/store/OLD-toplevel   ← 原样保留
                                    ↑ GC root 保护（第 19 章）
/run/current-system → NEW-toplevel                                 ← 已切换
/boot/loader/entries/nixos-generation-118.conf                     ← 菜单已加
```

回滚的三种姿势：

```console
# ① 热回滚（马上生效，回到 117 的运行状态）
$ nixos-rebuild switch --rollback

# ② 冷回滚（机器已重启，在开机菜单手动选 Generation 117）

# ③ 列出与清理（控制保留多少代）
$ nix-env -p /nix/var/nix/profiles/system --list-generations
$ sudo nixos-rebuild list-generations          # 现代入口（以手册为准）
$ sudo nix-collect-garbage -d                  # 删旧代并 GC（第 19 章）
```

bootloader 的 `configurationLimit`（systemd-boot/grub 通用选项）控制菜单里保留多少代，防止 /boot 膨胀。

## 27.5 特化（specialisations）：一代系统里的备胎

NixOS 允许在**同一代**里预置变体（例如同一系统带/不带调试配置）：

```nix
specialisation.debug.configuration = {
  environment.systemPackages = [ pkgs.strace ];
  nix.settings = { ... };   # 调试用差异
};
```

开机菜单里会出现 `NixOS - Generation 118 - debug-configuration` 条目——选它即以该变体启动；`/run/current-system/specialisation` 目录在运行期也可切换。适合准备「带排障工具的同一系统」这类场景（内核参数调优的变体也常见）。

## 27.6 远程切换与失败恢复

`nixos-rebuild --target-host`（第 31 章）本质是把构建产物 push 到远端再远程调用 `switch-to-configuration switch`。两个安全注意：

1. **不要在失联风险下盲切**——若新代的 sshd 配置错误，switch 后你就上不去机器了。生产惯例：用 `boot` 动作 + 计划重启，或用 systemd 的 `runtime-max-self`? 更可靠的官方机制是 systemd 的「启动失败自动回滚」思路：NixOS 24.05+ 提供 `system.autoUpgrade.allowReboot` 与引导失败回退（boot counting，`systemd-boot` 的 EFI 启动计数）组合，以及 deploy-rs 的 magic rollback（第 31 章）做激活后健康检查。
2. **本地也一样**：改 sshd/防火墙前先 `dry-activate`，或在 tmux 里保留旧会话应急。

## 27.7 本章小结

- `switch-to-configuration` 负责单元 diff、切换 /run/current-system、注册新代、更新引导菜单。
- diff 决策表：新增→start，移除→stop，变化→默认 restart、可 reload 则 reload；`restartTriggers` 是模块作者影响决策的通道。
- 内核/initrd 变化不能热切，需重启；switch 从不自动重启机器。
- 回滚三姿势：--rollback 热回滚、开机菜单冷回滚、generation 清理与 configurationLimit。
- specialisations 在同一代内预置变体；远程切换要防「切完锁死」，可用 boot+重启或部署工具的自动回滚。

## 延伸阅读

- 源码：nixos/modules/system/activation/switch-to-configuration.pl（diff 决策的一手实现）
- 手册 «Changing Configuration»：https://nixos.org/manual/nixos/stable/#sec-changing-config
- 第 31 章（部署工具如何包装 switch）、第 28 章（新代如何被引导加载）。
