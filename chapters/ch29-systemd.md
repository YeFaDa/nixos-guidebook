# 第 29 章 systemd 集成

> **本章导读**：在第 24 章你已经无数次写下 `services.foo.enable = true`，本章拆开这台自动售货机：NixOS 如何把选项求值成真正的 systemd 单元文件，`systemd.services.<name>` 的每个字段对应单元文件的哪一行，以及如何把你自己的脚本封装成一个有沙箱、有日志、能回滚的服务。读完本章，`systemctl cat nginx` 输出里那一串 store 路径将不再神秘。

## 29.1 为什么 NixOS 选择 systemd

NixOS 与 systemd 的结合不是偶然，而是气质相投。

systemd 的单元文件（unit file）本身就是一个声明式的描述：你告诉它「这个服务用什么命令启动、依赖谁、崩了怎么办」，而不是像 SysV init 时代那样写一个自己 fork 自己、自己写 pid 文件、自己管日志的 shell 脚本。回看第 22 章的历史：SysV init 用 `S20apache2` 这样的文件名编号硬排顺序，启动顺序靠人脑推演，进程退出与否要靠 pid 文件猜测，孤儿进程更是无人认领。systemd 用 cgroup 精确追踪每个服务派生的进程、用依赖图表达顺序、用 journald 统一结构化日志——这些恰好补齐了「系统=纯函数输出」缺失的那一半：Nix 声明了「磁盘上应该有什么」，systemd 声明了「运行时应该跑什么」。

两者拼起来才是完整的 NixOS 故事：

- 配置求值 → 单元文件写进 `/nix/store` → `/etc/systemd/system` 链接过去 → systemd 依声明拉起服务；
- 因为单元文件在 store 里，它不可变、有哈希、可被 generation 引用——「切换系统版本」因此可以是原子的，「回滚」则连服务定义一起回滚。

对照传统发行版：Ubuntu 上手改 `/etc/systemd/system/foo.service` 是常规操作，改坏了只能靠备份或记忆恢复；NixOS 上单元文件的唯一权威来源是配置仓库，`git log` 就是单元的变更史。

## 29.2 systemd.services.<name> 选项全解

NixOS 没有让你直接写 unit 文件，而是提供了一层选项封装。先给总表，再逐项示例。

| 选项 | 生成的单元内容 | 一句话用途 |
|---|---|---|
| `enable` | 控制单元是否生成（默认 `true`；`false` 时链接到 `/dev/null`） | 条件化屏蔽单元；**注意它不是开机自启开关** |
| `description` | `Description=` | 人读的说明，status 与 journal 都会显示 |
| `after` / `before` | `After=` / `Before=` | 顺序约束（不产生依赖，只排先后） |
| `wants` / `requires` / `bindsTo` / `partOf` | `Wants=` / `Requires=` / `BindsTo=` / `PartOf=` | 依赖强度逐级上升 |
| `wantedBy` / `requiredBy` | 生成 `*.wants/` 符号链接 | **真正的开机自启开关** |
| `serviceConfig` | `[Service]` 段任意字段 | Type、User、Restart、加固选项全在这 |
| `script` | 包装成 `ExecStart` | 用 Nix 字符串写启动脚本 |
| `preStart` / `postStart` / `postStop` | `ExecStartPre=` / `ExecStartPost=` / `ExecStopPost=` | 前置准备与善后 |
| `reload` | `ExecReload=` | 不中断连接的重载 |
| `path` | 单元内 `PATH` | 给脚本注入可用命令 |
| `environment` | `Environment=` | 环境变量（Nix 友好的 attrset 写法） |
| `unitConfig` | `[Unit]` 段任意字段 | 启动限速等非依赖字段 |
| `startAt` | 自动生成同名 `.timer` | 「定时任务」的最短路径 |
| `restartIfChanged` / `reloadIfChanged` / `stopIfChanged` | （NixOS 侧元选项） | rebuild 时对变更单元的处置策略 |

下面逐块示例。一个服务要「开机自启」，最小集合是 `wantedBy` 加一个启动入口：

```nix
{
  systemd.services.myapp = {
    description = "我的示例服务";

    # 为什么常见 multi-user.target：它代表「多用户系统就绪」，
    # graphical.target 之前的最后一级，服务器与桌面通吃
    wantedBy = [ "multi-user.target" ];

    # 顺序 vs 依赖：after 只保证先后，不保证「它失败了也等我」
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];   # 想要网络「真正可用」通常两者都写

    serviceConfig = {
      Type = "simple";               # 默认值；含义见下方 Type 速查
      ExecStart = "${pkgs.myapp}/bin/myapp --port 8080";
      # 为什么写全路径：服务的 PATH 非常精简，裸命令名找不到；
      # ${pkgs.myapp} 插值保证路径精确到哈希，升级即换路径，永不错配
      User = "myapp";
      Group = "myapp";
      WorkingDirectory = "/var/lib/myapp";
      Restart = "on-failure";        # 异常退出 5 秒后拉起；正常退出不拉
      RestartSec = "5s";
    };
  };
}
```

`enable` 与 `wantedBy` 的区别值得用一整段讲清：`enable` 默认就是 `true`，把它设为 `false` 的效果是该单元被链接到 `/dev/null`（存在但被屏蔽）——适合配合 `lib.mkIf` 做条件禁用；而「这台机器开机要不要启动它」由 `wantedBy` 决定。写了 `enable = true` 却忘了 `wantedBy`，是新手服务「配了却不跑」的第一大原因。

### 29.2.1 依赖强度光谱

```nix
{
  systemd.services.myapp = {
    wants = [ "network-online.target" ];    # 弱依赖：你挂我也启，你挂了我照跑
    requires = [ "postgresql.service" ];    # 强依赖：pg 启动失败则我根本不启
    bindsTo = [ "postgresql.service" ];     # 绑定：pg 停止时把我也一起停掉
    partOf = [ "myapp-stack.target" ];      # 分组：随组重启（组内滚动重启的钥匙）
  };
}
```

经验：网络类服务写 `wants`/`after` + `network-online.target` 就够；真正「没有它我无法工作」的本地依赖才上 `requires`；容器栈、代理栈用自定义 target 加 `partOf` 实现整组控制。

### 29.2.2 Type 速查与 script 家族

| Type | 语义 | 适用 |
|---|---|---|
| `simple`（默认） | `ExecStart` 的进程即服务本体，启动即「已运行」 | 前台常驻程序 |
| `exec` | 同 simple，但等到 exec 完成才算启动 | 想捕获「二进制找不到」类失败 |
| `forking` | 进程会 fork 到后台，父进程退出才算启动完成 | 传统双 fork 守护进程 |
| `notify` | 程序主动调 `sd_notify` 报告「就绪」 | 精确的启动顺序（nginx、sshd 支持） |
| `oneshot` | 跑完就退出 | 备份脚本、初始化任务（常配 `RemainAfterExit = true`） |

`script` 系列是 NixOS 的糖：你写 Nix 字符串，它包装成 bash 脚本生成 `ExecStart`/`ExecStartPre`，且自动 `set -e`：

```nix
{
  systemd.services.myapp-init = {
    description = "一次性初始化";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;   # 为什么：退出后仍显示 active，便于依赖它的人判断
    };
    # preStart → ExecStartPre：主启动前的准备，失败则主命令不执行
    preStart = ''
      install -d -m 0750 -o myapp -g myapp /var/lib/myapp
    '';
    # script 与 serviceConfig.ExecStart 二选一（同时写会报断言错误）
    script = ''
      echo "开始初始化……"
      ${pkgs.sqlite}/bin/sqlite3 /var/lib/myapp/db.sqlite 'CREATE TABLE IF NOT EXISTS t(x);'
      # 坑：shell 的 ${VAR} 会被 Nix 当字符串插价！
      # 要输出字面 ${VAR} 需写成 ''${VAR}（两个单引号开头的转义）
      echo "home is $HOME"     # 裸 $HOME 不冲突，可放心使用
    '';
    # postStop → ExecStopPost：无论正常/异常停止都会执行，适合清理
    postStop = ''
      echo "服务已停止"
    '';
  };
}
```

### 29.2.3 目录、环境与 PATH

```nix
{
  systemd.services.myapp = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      # RuntimeDirectory：启动前自动创建 /run/myapp（tmpfs，重启即空），
      # 属主自动归 User/Group，停止后自动清理——别再手写 mkdir + chown
      RuntimeDirectory = "myapp";
      RuntimeDirectoryMode = "0750";
      # StateDirectory：同上，但指向 /var/lib/myapp（持久数据）
      StateDirectory = "myapp";
      # Environment：单个键值；列表可写多条
      Environment = [ "MYAPP_PORT=8080" ];
      # EnvironmentFile：从文件读环境变量；前缀 - 表示「文件可以不存在」
      EnvironmentFile = "-/run/secrets/myapp-env";
    };
    # environment：Environment= 的 attrset 写法，更顺手
    environment = {
      LANG = "C.UTF-8";
      RUST_LOG = "info";
    };
    # path：把这些包的 bin 目录拼进本单元的 PATH
    # 为什么需要：systemd 服务的 PATH 默认极小，脚本里裸调 curl 会失败
    path = with pkgs; [ curl coreutils jq ];
  };
}
```

`RuntimeDirectory`/`StateDirectory` 不只是省事：它们按 `User`/`Group` 自动设属主，避免「root 跑了一次留下 root 属主目录、切普通用户后写不进」的经典权限事故（29.7 还会回到这个坑）。

### 29.2.4 定时与重载

```nix
{
  systemd.services.report = {
    description = "每日报告";
    serviceConfig.Type = "oneshot";
    script = '' ${pkgs.curl}/bin/curl -s https://example.com/health > /dev/null ''; 
    # startAt：一行顶一个 timer + enable，语法是 systemd.time(7)
    startAt = "*-*-* 03:00:00";   # 每天 03:00
  };

  systemd.services.myapp = {
    # reload：生成 ExecReload，改配置「平滑重载」而非重启（连接不断）
    reload = '' ${pkgs.coreutils}/bin/kill -HUP $MAINPID '';
    # $MAINPID 由 systemd 注入，指主进程 pid
  };
}
```

### 29.2.5 沙箱加固（hardening）

`serviceConfig` 里最值得投资的一组字段是沙箱选项。原则：**默认全部拒绝，再按需开口子**：

```nix
{
  systemd.services.myapp = {
    serviceConfig = {
      NoNewPrivileges = true;          # 禁止 setuid 提权
      PrivateTmp = true;                # 独立 /tmp，看不到别的服务的临时文件
      ProtectSystem = "strict";         # 整个文件系统只读
      ReadWritePaths = [ "/var/lib/myapp" ];   # 只开这一个可写口子
      ProtectHome = true;               # 完全看不到 /home
      PrivateDevices = true;            # 看不到真实设备（除 /dev/null 等基本项）
      ProtectKernelTunables = true;     # 禁改 /proc/sys
      ProtectKernelModules = true;      # 禁加载内核模块
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
                                       # 只许这几种 socket：要 AF_NETLINK 的程序会失败
      CapabilityBoundingSet = "";       # 剥夺全部 capabilities
      SystemCallFilter = [ "@system-service" ];  # 白名单式系统调用过滤
      LockPersonality = true;           # 禁止切换执行域
      MemoryDenyWriteExecute = true;    # 禁 W+X 内存（无 JIT 的程序都适用）
    };
  };
}
```

这些选项任何发行版的 systemd 都支持，但只有 NixOS 让它们随配置一起进版本管理。想知道自己的服务还有多少暴露面，跑 `systemd-analyze security myapp.service`（29.5 实战演示）。

## 29.3 其他单元类型

### 29.3.1 systemd.timers：cron 的继任者

29.2.4 的 `startAt` 是最短路径；需要精细控制时直接声明 timer 单元：

```nix
{
  # 同名服务是 timer 的触发目标（db-dump.timer → db-dump.service）
  systemd.services.db-dump = {
    description = "数据库备份";
    serviceConfig.Type = "oneshot";
    script = '' ${pkgs.postgresql}/bin/pg_dumpall > /var/backup/db.sql '';
  };

  systemd.timers.db-dump = {
    wantedBy = [ "timers.target" ];   # timer 的「开机自启」开关
    timerConfig = {
      OnCalendar = "*-*-* 03:30:00";   # 每天 03:30（日期-时间全格式）
      Persistent = true;               # 为什么重要：关机错过的触发，开机后补跑
      RandomizedDelaySec = "10min";    # 错峰：多台机器不会同时打爆备份服务器
      AccuracySec = "1min";            # 默认 1h 的触发精度，按需收紧
    };
  };
}
```

`OnCalendar` 速览（完整语法见 `man systemd.time`，可用 `systemd-analyze calendar "..."` 离线验证）：

| 写法 | 含义 |
|---|---|
| `daily` / `hourly` / `weekly` / `monthly` | 常用别名 |
| `*-*-* 03:00:00` | 每天 03:00（年-月-日 时:分:秒） |
| `*:0/15` | 每小时的 0/15/30/45 分 |
| `Mon..Fri 09:00:00` | 工作日每天 09:00 |
| `Sun *-*-01..07 02:00:00` | 每月第一个周日 02:00 |

对照传统 crontab：timer 把「任务」与「计划」拆成两个单元，日志自动进 journal（`journalctl -u db-dump` 直接可查），`Persistent` 补跑是 cron 永远做不到的。

### 29.3.2 systemd.sockets：socket 激活

让监听端口与处理进程解耦：socket 常驻，服务按需拉起。

```nix
{
  systemd.sockets.myapp = {
    description = "myapp 监听 socket";
    wantedBy = [ "sockets.target" ];
    socketConfig = {
      ListenStream = "8080";   # 监听 TCP 8080；也可以是 /run/myapp.sock
      Accept = false;          # false：单实例接管；true：每连接一个实例
    };
  };

  systemd.services.myapp = {
    serviceConfig.Type = "simple";
    # Accept=false 时监听的 fd 固定传到 3 号描述符；
    # Accept=true 时连接从 stdin 进来（ inetd 风格）
    script = '' exec ${pkgs.myapp}/bin/myapp --fd 3 '';
    # 注意：这里刻意不写 wantedBy——服务由 socket 负责拉起，
    # 再写 multi-user.target 会变成「常驻 + 按需」两头启动
  };
}
```

收益：端口永远有人听（零秒上线观感）、空闲时不占内存、重启服务不丢排队连接。要求程序支持从既存 fd 监听（systemd 生态的库通常支持）。

### 29.3.3 mounts、paths、targets、tmpfiles

```nix
{
  # mounts：直接声明 mount 单元（本地磁盘通常用 fileSystems 选项，
  # 它底层同样生成 mount 单元；systemd.mounts 适合网络盘等特殊场景）
  systemd.mounts = [{
    what = "nas.local:/export/media";
    where = "/mnt/media";
    type = "nfs";
    options = "ro,x-systemd.automount";   # automount：首次访问才真正挂载
    wantedBy = [ "multi-user.target" ];
  }];

  # paths：监听文件系统变化触发同名服务（轮询任务的替代品）
  systemd.paths.myapp-inbox = {
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = "/var/lib/myapp/inbox";   # 变化即触发 myapp-inbox.service
    };
  };

  # targets：自定义分组，配合 partOf 实现「整组启停/重启」
  systemd.targets.myapp-stack = {
    wants = [ "myapp.service" "db-dump.timer" ];
    wantedBy = [ "multi-user.target" ];
  };

  # tmpfiles：声明式地「确保目录/文件/链接存在且权限正确」，
  # 激活时执行（第 26 章），语法同 systemd-tmpfiles(8)
  systemd.tmpfiles.rules = [
    "d /var/lib/myapp 0750 myapp myapp -"        # d=目录，不存在才建
    "z /var/lib/myapp 0750 myapp myapp -"        # z=已存在则修正权限
    "L+ /usr/local/bin/myapp - - - - ${pkgs.myapp}/bin/myapp"  # 强制符号链接
  ];
}
```

## 29.4 从 config 到单元文件：一条链路的真相

前面所有选项最终都变成一件事：求值出一个目录放 `/nix/store`，再链接进 `/etc/systemd/system`。亲手看一遍：

```console
# nginx 的单元文件是哪个？
$ systemctl cat nginx.service
# /etc/systemd/system/nginx.service
# (输出内容，路径指向 /etc/systemd/system/nginx.service)
...
```

关键事实：`/etc/systemd/system/nginx.service` 本身就是一个指向 store 的符号链接：

```console
$ readlink -f /etc/systemd/system/nginx.service
/nix/store/xxxxx-unit-systemd-nginx.service/nginx.service
$ grep ExecStart /nix/store/xxxxx-unit-systemd-nginx.service/nginx.service
ExecStart=/nix/store/yyyyy-nginx-1.27/bin/nginx -c ...   # 连二进制都精确到哈希
```

「开机自启」在文件系统层面就是一堆符号链接。`wantedBy = [ "multi-user.target" ]` 的产物：

```console
$ ls -l /etc/systemd/system/multi-user.target.wants/ | head
... nginx.service -> /nix/store/xxxxx-unit-.../nginx.service
... sshd.service -> /nix/store/...
```

这解释了两件事：其一，systemd 眼中的 `/etc/systemd/system` 与普通发行版无异，只是里面大部分条目是 store 链接；其二，rebuild 切换 generation 时，激活脚本重放这些链接（第 26 章），`switch-to-configuration` 再对变更单元下发 restart/reload 并 `daemon-reload`（第 27 章）。单元文件、二进制、配置文件三者共享同一个 store 哈希体系——这就是「系统=纯函数输出」在运行时的形态。

顺带一提：`systemctl status` 里看到的 `/run/current-system` 也是符号链接，指向本次激活的系统闭包；上一代系统在 `/nix/var/nix/profiles/system-<N>-link` 静静躺着，等待回滚（第 18 章）。

## 29.5 完整实战：把一个 Python 脚本做成服务

需求：一个返回机器状态 JSON 的小 HTTP 接口，跑在 127.0.0.1:8080，由 nginx 反代对外，仅此而已。

第一步，把脚本本身变成 store 里的产物。`pkgs.writers.writePython3` 会生成带正确 shebang 与 Python 依赖的脚本，并在构建期跑 flake8 检查（写错了构建就失败，而不是运行时才炸）：

```nix
# 放在 configuration.nix 顶部的 let 里，或独立 modules/status-api.nix
let
  statusApi = pkgs.writers.writePython3 "status-api" {
    libraries = [ pkgs.python3Packages.bottle ];  # 轻量 HTTP 微框架
    flakeIgnore = [ "E501" ];   # 示例代码忽略行宽检查
  } ''
    from bottle import route, run
    import platform

    # /status：给监控拉的 JSON 端点
    @route("/status")
    def status():
        return {"ok": True, "host": platform.node()}

    # 只监听回环地址：对外暴露交给 nginx 反代，
    # 为什么：攻击面最小化，服务本身不需要（也不应该）直接面对公网
    run(host="127.0.0.1", port=8080)
  '';
in { ... }
```

第二步，声明用户与带加固的服务：

```nix
{
  # 专用系统用户：不登录、无 home 权限需求
  users.users.statusapi = {
    isSystemUser = true;
    group = "statusapi";
  };
  users.groups.statusapi = { };

  systemd.services.status-api = {
    description = "状态页 API（示例）";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      ExecStart = "${statusApi}";     # writePython3 的产物就是可执行文件本体
      User = "statusapi";
      Group = "statusapi";
      Restart = "on-failure";
      RestartSec = "3s";

      # —— 沙箱：能不给的都不给 ——
      NoNewPrivileges = true;
      ProtectSystem = "strict";       # 全文件系统只读
      ProtectHome = true;             # 无 /home 可见
      PrivateTmp = true;              # 独立 /tmp
      PrivateDevices = true;          # 无设备
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      CapabilityBoundingSet = "";     # 无特权能力
      SystemCallFilter = [ "@system-service" ];
      MemoryDenyWriteExecute = true;  # CPython 无 JIT，可以安全启用
    };
  };
}
```

第三步，nginx 反代与验证：

```nix
{
  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    virtualHosts."status.example.com" = {
      # 仅内网演示可以不开证书；公网请加 forceSSL + enableACME（第 24.6.2）
      locations."/".proxyPass = "http://127.0.0.1:8080";
    };
  };
}
```

```console
# rebuild 前先静态验证单元文件（拼写、路径、字段合法性）
$ systemd-analyze verify /etc/systemd/system/status-api.service
# 沙箱暴露面评分：0.0～10，越小越收敛
$ systemd-analyze security status-api.service

$ sudo nixos-rebuild switch --flake .#myhost

# 运行状态与日志
$ systemctl status status-api
$ curl -s http://127.0.0.1:8080/status
{"ok": true, "host": "myhost"}
# 跟踪日志（-f 同 tail -f；journal 按 unit 归档，无需自己管日志轮转）
$ journalctl -u status-api -f
# 只看最近 10 分钟
$ journalctl -u status-api --since "10 min ago"
```

至此这个脚本获得了：开机自启、崩溃自愈、journald 日志、沙箱隔离、随配置版本化——总代码量不到 50 行声明。

## 29.6 声明式的纪律：为什么没有 systemctl enable/disable

在 Ubuntu 上 `systemctl enable --now foo` 是日常；在 NixOS 上这条命令仍然「能跑」，但意义变了。`systemctl enable` 会往 `/etc/systemd/system/*.wants/` 写符号链接——而 29.4 已经看到，这个目录归激活脚本管。下次 rebuild 时，链接会被按配置重放：你手工 enable 的消失，你手工 disable 的复活。它不是被禁止，而是**注定无效**。同理：

- `systemctl edit nginx`（生成 `/etc/systemd/system/nginx.service.d/override.conf`）——下次 rebuild 后 drop-in 依旧躺在那，但配置一变大家就忘了它的存在，成为幽灵补丁；
- `systemctl mask` 的结果也会被 rebuild 撤销。

正确的心智模型是：**运行态命令（start/stop/restart/reload/status/journalctl）随便用**——它们操作的是当下，reboot 后本来就归配置管；**持久态变更（enable/disable/edit/mask）一律回 nix 文件里改**。想临时关掉一个服务到下次重启，`systemctl stop` 就够了，不必也不该 disable。

这套纪律的回报在 rebuild 时兑现：`switch-to-configuration` 对比新旧两代系统中每个单元文件的内容（第 27 章详解其策略）：

- 文件变了的单元默认 **restart**；设了 `restartIfChanged = false` 的只 reload 或不动（比如改 sshd 配置时不断开当前连接就靠它）；
- 声明了 `reload`/`ExecReload` 且只有 `reloadTriggers` 指向的内容变化的，只 **reload** 不重启（nginx 换配置不断连接）；
- `stopIfChanged = false` 用于「重启前先停」会造成损伤的服务（典型如依赖 socket 的单元）。

于是「我改了配置，哪些服务会重启、会不会断连」这个问题，答案完全写在你的配置里、可被 `dry-activate` 预演——这是命令行时代无法想象的确定性。

## 29.7 调试工具箱与常见失败模式

### 29.7.1 日常三板斧

```console
# 状态总览：主 pid、内存、最近日志片段一屏可见
$ systemctl status status-api
# 查看单元最终生效的完整内容（含 drop-in 合并结果）
$ systemctl cat status-api
# 重启 / 重载
$ sudo systemctl restart status-api

# 日志：按单元、跟踪、时间窗
$ journalctl -u status-api -n 50 --no-pager   # 最近 50 行
$ journalctl -u status-api -f                 # 实时跟踪
$ journalctl -u status-api --since today
# 磁盘占用与清理
$ journalctl --disk-usage
$ sudo journalctl --vacuum-size=500M
```

journal 的持久化与限额也可声明：`services.journald.extraConfig = "SystemMaxUse=500M";`。

### 29.7.2 启动性能

```console
$ systemd-analyze                    # 总启动耗时
$ systemd-analyze blame | head -20   # 各单元耗时排行（看趋势，别迷信绝对值）
$ systemd-analyze critical-chain multi-user.target   # 到达目标的串行关键路径
```

`blame` 的常见误读：耗时长的单元可能只是「在等网络」，真正的元凶要看 `critical-chain`。NixOS 特有的一个项是 `nix-optimise`/`nix-gc` 等 timer，它们不该出现在关键路径上——若出现，检查 `Persistent = true` 是否在开机时集中补跑了任务。

### 29.7.3 常见失败模式对照表

| 症状 | 根因 | 修法 |
|---|---|---|
| 服务启动即退，日志显示进程 fork 后父进程退出，systemd 反复重启 | 传统守护进程被当成 `Type = "simple"` 跑 | 改 `Type = "forking"`，或加参数让程序前台运行（更佳） |
| `ExecStart` 报「No such file or directory」，但命令明明装了 | 用了裸命令名；服务 PATH 里没有它 | 写全路径，最好用 `${pkgs.foo}/bin/foo` 插值 |
| `Permission denied` 写 `/var/lib/foo`，ls 显示 root 属主 | 手工 mkdir 的目录没给运行用户 | 用 `StateDirectory = "foo"` 让 systemd 接管属主 |
| 脚本里 `${VAR}` 莫名变成空串或求值报错 | Nix 把 `${...}` 当插值处理 | 字面 `${` 写成 `''${` |
| oneshot 服务跑完显示 inactive (dead)，依赖它的单元忽启忽不启 | oneshot 结束即退，无「active」态可依赖 | 加 `RemainAfterExit = true` |
| `RestrictAddressFamilies` 后网络调用失败 | 程序需要未放行的地址族（如 AF_NETLINK） | 按报错补族，或先关该加固项定位 |
| 改了配置 rebuild，服务却没生效 | 单元内容没变只是重启策略不同，或忘写 `wantedBy` | `dry-activate` 预演 + `systemctl cat` 核对最终内容 |

调试顺序建议：`systemctl status`（状态与退出码）→ `journalctl -xeu foo`（上下文日志）→ `systemctl cat`（确认生效的单元真的是你以为的那份）→ 最后才怀疑 nix 配置本身。

## 29.8 本章小结

- NixOS 与 systemd 同为声明式：选项求值成单元文件入 store，`/etc/systemd/system` 以符号链接引用，回滚连服务定义一起回滚。
- `enable` 不是开机自启：`wantedBy` 才是；`enable = false` 是把单元链接到 `/dev/null` 的屏蔽手段。
- 依赖按强度选：`after` 只排顺序；`wants` 弱依赖；`requires` 强依赖；`bindsTo` 同生共死；`partOf` 随组重启。
- `Type` 对号入座：前台程序 simple、传统守护进程 forking、支持 sd_notify 的 notify、跑完即走的 oneshot（配 RemainAfterExit）。
- `RuntimeDirectory`/`StateDirectory` 替你管目录属主，是权限事故的头号预防针；沙箱选项从「默认拒绝」开始开口子。
- timer 优于 cron：`Persistent` 补跑、日志进 journal、`systemd-analyze calendar` 可离线验证表达式。
- 持久态变更（enable/disable/edit/mask）必须回 nix 改，运行态命令（start/stop/restart）随时可用；rebuild 对单元的 restart/reload 策略由 `restartIfChanged`/`reloadTriggers` 等声明决定（第 27 章）。
- 调试三板斧：`systemctl status` → `journalctl -xeu` → `systemctl cat`；上线前 `systemd-analyze verify` 与 `security` 各跑一遍。

## 延伸阅读

- systemd 官方手册：`systemd.service(5)`、`systemd.time(7)`、`systemd.exec(5)`：<https://www.freedesktop.org/software/systemd/man/latest/>
- NixOS 手册·systemd 选项：<https://nixos.org/manual/nixos/stable/#sec-systemd>
- NixOS 选项检索（搜 `systemd.services`）：<https://search.nixos.org/options>
- NixOS Wiki·systemd 与加固：<https://wiki.nixos.org/wiki/Systemd_Services>、<https://wiki.nixos.org/wiki/Hardening_NixOS_Services>
- systemd-analyze 安全评分：<https://www.freedesktop.org/software/systemd/man/latest/systemd-analyze.html>
