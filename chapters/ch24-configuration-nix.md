# 第 24 章 configuration.nix 全面精讲

> **本章导读**：如果全书只允许你精读一章，那就是本章。它是你日常与 NixOS 对话的地方：装机后第一行配置、中文桌面、用户与密码、服务与防火墙、桌面环境、`nixos-rebuild` 的每个动作，全部发生在 `configuration.nix` 及其引入的文件里。本章既是教程，也是一本可以反复翻查的「中文配置百科」——每个小节都给出可直接粘贴、逐行注释的完整代码块。版本基准：NixOS 26.05（Yarara）、Nix 2.35；个别选项随版本迁移，凡不确定处以 <https://search.nixos.org/options> 为准。

## 24.1 最小可启动配置：逐行读懂

安装器（`nixos-install`，或图形安装器）做完两件事：分区、挂载，然后在 `/etc/nixos/` 下生成两个文件。你此后对整台机器的掌控，全部从这两个文件出发。

```nix
# /etc/nixos/configuration.nix —— 整台机器的「源头」
# 修改后执行 sudo nixos-rebuild switch 生效（见 24.9）
{ config, pkgs, ... }:

{
  # 引入硬件声明：fileSystems、swap、initrd 内核模块、平台
  # 该文件由安装器调用 nixos-generate-config 生成，一般不要手改
  imports = [ ./hardware-configuration.nix ];

  # 启动器：UEFI 机器首选 systemd-boot，零配置、自动列出所有旧代
  boot.loader.systemd-boot.enable = true;
  # 允许把 EFI 启动项写入固件变量；否则要手工进 BIOS 调整启动顺序
  boot.loader.efi.canTouchEfiVariables = true;

  # 主机名：决定提示符、ssh 目标名，也是 flake 中 .#hostname 的取值依据
  networking.hostName = "myhost";

  # Wi-Fi 用 wpa_supplicant（无桌面环境的服务器/最小系统常用）
  # 桌面机建议改用 24.2 的 NetworkManager 写法，两者互斥
  networking.wireless.enable = true;

  # 第一个用户：wheel 组成员才能用 sudo
  users.users.alice = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
  };

  # 系统级软件包，相当于「这台机器的 /usr/bin」
  environment.systemPackages = with pkgs; [ vim git curl ];

  # 开启 SSH 服务，否则远程没法管理
  services.openssh.enable = true;

  # 安装时的 NixOS 版本号：只增不减、永不修改
  # 它告诉迁移逻辑「当年按哪个版本的语义生成状态」，乱改可能导致升级脚本误判
  system.stateVersion = "26.05";
}
```

这段大约二十行的配置，就足以启动一台能远程登录的机器。注意两个细节：

- `imports` 引入的 `hardware-configuration.nix` 不是你写出来的，是安装器探测硬件后生成的「硬件事实清单」，典型内容如下：

```nix
# /etc/nixos/hardware-configuration.nix（安装器生成，示意）
{ config, lib, pkgs, modulesPath, ... }:

{
  # 为什么记内核模块：initrd 必须先能驱动磁盘控制器，否则根分区都挂不上
  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "ahci" "usb_storage" "sd_mod" ];
  fileSystems."/" = {
    # 用 by-uuid 而不是 /dev/sda1：设备名在 BIOS/多盘机器上会漂移，UUID 不会
    device = "/dev/disk/by-uuid/1234-5678...";
    fsType = "ext4";
  };
  swapDevices = [ ];
  # 平台声明：nixpkgs 据此选择 x86_64/aarch64 包集
  # 旧版安装器可能写的是 nixpkgs.system，含义相同
  nixpkgs.hostPlatform = "x86_64-linux";
}
```

- `system.stateVersion` 是初学者最常「手贱」改坏的地方：它不是「当前系统版本」，而是「这份配置诞生时的版本承诺」。升级系统时改它，等于撕毁了与迁移逻辑的契约。

与传统发行版对照：Ubuntu 装完后你的系统状态散落在 `/etc/fstab`、`/etc/network/`、`apt` 的包列表和 `/home` 的 dotfiles 里，重装一台「一模一样」的机器几乎不可能；而 NixOS 的这两份文件加上一个 flake 锁（参见第 13—21 章），就是机器的完整定义。

## 24.2 全局基础与「中文桌面一站式配置」

装完机后的第一波需求通常是：主机名、网络、时区、语言。在 Ubuntu 上这对应 `hostnamectl`、netplan 的 YAML、`timedatectl`、`update-locale` 四套互不相识的工具；在 NixOS 里它们是同一个文件里的四个选项。

```nix
{
  # —— 基础四件套 ——
  networking.hostName = "thinkpad";

  # 有线无线统一交给 NetworkManager（nmcli / 图形托盘可用）
  # 它与 networking.wireless（wpa_supplicant）互斥，只能开一个
  networking.networkmanager.enable = true;

  time.timeZone = "Asia/Shanghai";

  # 默认 locale：大多数程序界面跟随它
  i18n.defaultLocale = "zh_CN.UTF-8";
  # 想让部分类别保持英文（如错误消息便于搜索），在这里覆盖
  i18n.extraLocaleSettings = {
    LC_MESSAGES = "zh_CN.UTF-8";  # 想看英文报错可改 "en_US.UTF-8"
    LC_TIME = "zh_CN.UTF-8";
  };

  # TTY（虚拟控制台）键盘布局
  # 诚实的提醒：Linux 内核的 VT 不渲染 CJK 字形，TTY 下中文显示为方块，
  # 这是内核限制而非 NixOS 的 bug；图形会话里不受影响
  console.keyMap = "us";
}
```

接下来是中文用户最关心的两件事：输入法与字体。输入法自 NixOS 23.11 起改为 `i18n.inputMethod.type` 选择引擎，`fcitx5` 是当前中文社区的主流选择；字体的关键是同时装上 CJK 字族并在 fontconfig 里声明缺省顺序——只装中文字体、不设 defaultFonts，浏览器里英文会变得又细又丑。

```nix
{
  # —— 输入法：fcitx5 + 中文方案 ——
  i18n.inputMethod = {
    enable = true;
    type = "fcitx5";                      # 23.11+ 的新写法
    fcitx5.addons = with pkgs; [
      fcitx5-chinese-addons               # 拼音/双拼/五笔，装它就够日常
      fcitx5-rime                         # 中州韵：高度可定制，进阶可选
      fcitx5-material-color               # 主题（纯装饰，可删）
    ];
  };
  # 模块会自动设置 GTK_IM_MODULE / QT_IM_MODULE / XMODIFIERS，
  # Wayland 下 GTK/Qt 应用直接走文本输入协议，通常无需手工干预

  # —— 中文字体一站式 ——
  fonts.packages = with pkgs; [
    noto-fonts                # 西文与常用符号
    noto-fonts-cjk-sans       # 中文黑体（界面主力）
    noto-fonts-cjk-serif      # 中文宋体（衬线，阅读用）
    noto-fonts-emoji          # emoji
    nerd-fonts.jetbrains-mono # 终端等宽字体；25.05 前的旧写法是
                              # (nerdfonts.override { fonts = [ "JetBrainsMono" ]; })
  ];
  fonts.fontconfig.defaultFonts = {
    # 为什么显式排序：西文字体优先、中文字体兜底，
    # 避免英文被中文字体里的半角字形渲染得参差不齐
    sansSerif = [ "Noto Sans" "Noto Sans CJK SC" ];
    serif = [ "Noto Serif" "Noto Serif CJK SC" ];
    monospace = [ "JetBrainsMono Nerd Font" "Noto Sans Mono CJK SC" ];
  };
}
```

把 24.1 的骨架与上面两段合并，就是一台开箱即用的中文桌面基础配置。建议第一次 `nixos-rebuild switch` 后注销重新登录，让输入法环境变量生效。

## 24.3 用户管理：users.users 全字段

NixOS 里用户不是「被创建的资源」，而是「被声明的事实」。对照传统做法：Ubuntu 上 `adduser` 改的是 `/etc/passwd` 这一份易失状态，重装即丢；NixOS 上用户是配置的一部分，换机器 rebuild 即复现。逐字段注释如下。

```nix
{
  # 先启用想要的 shell（否则用户登录会退回 /bin/sh 之外的默认）
  programs.zsh.enable = true;   # 为什么单独立项：zsh 的补全等需要系统级初始化

  users.users.alice = {
    isNormalUser = true;        # 分配 1000+ 的 uid、创建 /home/alice
    extraGroups = [
      "wheel"          # sudo 权限的来源
      "networkmanager" # 免密使用 nmcli 修改网络
      "video" "input"  # 桌面/背光/触控板常需要
      "docker"         # 24.6 的 Docker 免 sudo
    ];
    description = "Alice Chen";             # 全名（GECOS 字段）
    shell = pkgs.zsh;                       # 路径写法；也可写 "=pkgs.zsh" 形式
    home = "/home/alice";                   # 默认即此，仅特殊需求才写
    openssh.authorizedKeys.keys = [
      # 公钥直接进配置：换机器时无需再 ssh-copy-id
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... alice@laptop"
    ];

    # —— 密码的三种写法（互斥，按场景选一）——
    # ① 明文初始密码：仅在「创建该用户的那一次」生效，之后改它无效
    #    只适合新装机过渡，绝不要用于服务器
    # initialPassword = "changeme";

    # ② 哈希初始密码：同上，仅创建时生效，但不明文留在配置里
    # initialHashedPassword = "$6$rounds=5000$salt$hash...";

    # ③ 每次激活都强制同步：要求 users.mutableUsers = false 才可靠，
    #    是「完全声明式用户」的核心（第 30 章展开）
    # hashedPassword = "$6$rounds=5000$salt$hash...";

    # ④ 配合 secrets 工具：hash 放在 /run/secrets（第 30 章），
    #    兼顾声明式与「密码不进 store」
    # hashedPasswordFile = "/run/secrets/alice-password";

    # 仅该用户可见的包：装进其个人 profile，不污染系统环境
    packages = with pkgs; [ firefox wechat-uos ];
  };
}
```

生成密码哈希用 `mkpasswd`（来自 whois 套件，Ubuntu/Fedora 一般预装或 `apt install whois`）：

```console
# NixOS 上临时拉取 mkpasswd（nixpkgs 顶层属性就叫 mkpasswd）
$ nix shell nixpkgs#mkpasswd
# 交互式生成 sha-512 哈希（glibc crypt 格式，与 /etc/shadow 兼容）
$ mkpasswd -m sha-512
Password:            # 输入的字符不会回显
$6$rounds=5000$...   # 把整串粘进 hashedPassword
```

`users.mutableUsers` 决定了用户数据库的哲学，这是新手最容易翻车的地方：

- `mutableUsers = true`（默认）：`/etc/passwd`、`/etc/shadow` 是真实的可变文件，`passwd`、`useradd` 照常可用；配置里的 `initial*` 字段只在首次创建用户时生效。
- `mutableUsers = false`：这三个文件变成指向 store 的符号链接，`passwd` 命令直接失效（文件只读）；`hashedPassword` 在每次 rebuild 时强制同步。改密码的流程变成「生成新 hash → 改配置 → rebuild → git commit」。

把 `mutableUsers` 设为 `false` 之前，请务必：

1. 保留一个已登录的 root 或 wheel 会话（或物理控制台访问），防哈希写错当场锁死；
2. 先配好 `openssh.authorizedKeys.keys`，给自己留一条不依赖密码的通道；
3. 在虚拟机或第二台机器上演练一次。

锁死的救援路径（live USB 引导 → 挂载 → `nixos-enter` → 改回配置 → rebuild）在第 30.3 节与第 42 章排错篇有完整步骤。

## 24.4 nix 与 nixpkgs 设置

这一组选项控制 Nix 自身的行为与 nixpkgs 包集的取用方式，对应关系是：`nix.*` 管工具，`nixpkgs.*` 管货源。

```nix
{
  nix.settings = {
    # 新命令行与 flakes：2.35 时代事实上的标准写法（仍属实验特性）
    experimental-features = [ "nix-command" "flakes" ];

    # 二进制缓存：能命中就不本地编译，这是 NixOS 装机快的根基（第 20 章）
    substituters = [ "https://cache.nixos.org" ];
    # trusted-substituters：普通用户无需 --option 即可使用的第三方缓存
    # （如 nix-community 缓存；信任任何缓存前先配好对应的 trusted-public-keys）
    # trusted-substituters = [ "https://nix-community.cachix.org" ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];

    # 写入时自动对相同内容做硬链接去重，省磁盘
    auto-optimise-store = true;
  };

  # 每周自动垃圾回收：只删 30 天前的旧代，保证随时可回滚（第 21 章）
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  # 与 auto-optimise-store 二选一即可：这是「定时全库优化」的另一种节奏
  # nix.optimise.automatic = true;

  # —— nixpkgs 侧 ——
  nixpkgs.config = {
    allowUnfree = true;            # 允许闭源包（nvidia、Steam 等）
    # allowInsecure = [ "openssl-1.0.2u" ];  # 显式豁免已知漏洞的旧包（示例占位）
  };
  nixpkgs.hostPlatform = "x86_64-linux";   # 通常由 hardware-configuration.nix 提供
  nixpkgs.overlays = [
    # 叠加层：在不动 nixpkgs 的前提下增改包，详见第 39 章
    (final: prev: {
      # 例：把 vim 换成自己打补丁的版本
      # my-vim = prev.vim.overrideAttrs (old: { patches = [ ./vim.patch ]; });
    })
  ];
}
```

`allowInsecure` 的条目名要照着报错信息原样填——nixpkgs 用它阻止你「无知情地」装带已知漏洞的包，这是它比传统仓库多出来的一道闸。

## 24.5 environment 系：系统环境的所有开关

`environment.*` 决定「登录后你看到的世界」：装什么包、有哪些命令别名、哪些环境变量、`/etc` 里有什么。

```nix
{
  # 系统包集合：进入所有用户的 PATH（准确说是系统 profile）
  environment.systemPackages = with pkgs; [
    vim git curl wget htop ripgrep
  ];
  # with pkgs 是语法糖，等价于 pkgs.vim、pkgs.git……
  # 注意其坑：with 把 pkgs 里的名字灌进作用域，
  # 如果你恰好在别处绑定了同名标识符，会被遮蔽；大型配置里
  # 显式写 pkgs.foo 更抗坑，团队仓库常约定只用显式写法

  # 命令别名：写入全局 shell 初始化，所有用户生效
  environment.shellAliases = {
    ll = "ls -l";
    # 把最常用的命令缩短——这是声明式的甜点：别名也有版本历史了
    rebuild = "sudo nixos-rebuild switch";
  };

  # 全局环境变量：会被 systemd 服务与登录 shell 同时看到
  environment.variables = {
    EDITOR = "vim";   # 为什么放这里：crontab -e、git commit 都要问它
  };

  # 会话变量：在登录会话建立时注入（/etc/set-environment），
  # 与 environment.variables 高度重叠；日常建议变量只放一处，避免打架
  environment.sessionVariables = {
    # MOZ_ENABLE_WAYLAND = "1";   # 例：Firefox 走 Wayland 原生
  };

  # 直接往 /etc 放文件：内容进 store，/etc/foo/myapp.conf 是符号链接
  environment.etc."foo/myapp.conf".text = ''
    # 由 configuration.nix 生成，手改会在下次 rebuild 被覆盖
    listen = 8080
  '';

  # 把各包里的某类资源链接进系统 profile。
  # 经典场景：zsh 补全分散在每个包的 /share/zsh 下，
  # 不链接的话 tab 补全只有系统命令有
  environment.pathsToLink = [ "/share/zsh" ];

  # 生成系统 user-environment 时的后处理钩子，极少用到，
  # 知道它存在即可（需要往 profile 里塞任意文件时它是逃生门）
  # environment.extraSetup = ''  echo "built at $(date)" > $out/BUILD_INFO  '';
}
```

`environment.etc` 值得单独记住：它是「把配置文件也纳入声明式」的正门。第 26 章会讲这些 `/etc` 条目如何由激活脚本（activation script）落地，第 30 章会讲为什么手改 `/etc` 注定被覆盖。

## 24.6 常用服务大全

本节的每个服务给「可直接粘贴的完整配置 + 一句机制说明」。所有服务选项都能在 <https://search.nixos.org/options> 检索到权威定义。

### 24.6.1 OpenSSH：安全基线模板

```nix
{
  services.openssh = {
    enable = true;
    # 改端口属于「安全靠隐蔽」，防不了针对性扫描，改不改看口味
    ports = [ 22 ];
    settings = {
      PasswordAuthentication = false;     # 只允许密钥登录：消除爆破面
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";             # root 不许直接进，先登录普通用户再 sudo
    };
    openFirewall = true;   # enable 后默认放行 22，显式写出便于阅读
  };
}
```

机制：模块把 `settings` 渲染进 `/etc/ssh/sshd_config`（store 符号链接），rebuild 时按需重启 sshd。上线一台新服务器前，请先在第二个终端里保持一个已登录会话再 rebuild——这也是第 42 章排错的黄金法则。

### 24.6.2 nginx：反代 + 自动 HTTPS

```nix
{
  # ACME（Let's Encrypt）需要的账户邮箱与条款
  security.acme = {
    acceptTerms = true;
    defaults.email = "you@example.com";   # 到期/异常通知会发到这里
  };

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;   # 一键注入 X-Forwarded-For 等反代头
    recommendedGzipSettings = true;
    recommendedTlsSettings = true;     # 保持较新的 TLS 参数基线
    virtualHosts."blog.example.com" = {
      forceSSL = true;      # 80 端口 301 跳 443
      enableACME = true;    # 自动申请并续期证书，存于 /var/lib/acme
      locations."/" = {
        proxyPass = "http://127.0.0.1:8080";
        proxyWebsockets = true;   # 为什么：升级 ws:// 头，聊天类应用必需
      };
    };
  };

  # nginx 模块默认不替你开防火墙，80/443 要手动放行
  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
```

机制：证书申请由独立的 acme 服务单元完成，nginx 配置变化时模块选择 reload 而非重启（连接不断，参见第 27 章）。

### 24.6.3 PostgreSQL：声明式建库建用户

```nix
{
  services.postgresql = {
    enable = true;
    # 主版本随大版本升级而切换；具体可用属性以 nixpkgs 与官方文档为准
    package = pkgs.postgresql_17;
    # 首次激活时自动创建这些库（已存在则不动）
    ensureDatabases = [ "myapp" ];
    # 首次激活时自动创建用户并授权
    ensureUsers = [
      {
        name = "myapp";
        ensureDBOwnership = true;   # 把同名库的 owner 交给该用户
      }
    ];
    # pg_hba.conf：本地走 peer、回环走 scram，比默认的 trust 更安全
    authentication = ''
      local all all peer
      host  myapp myapp 127.0.0.1/32 scram-sha-256
    '';
  };
}
```

升级警告：`postgresql.package` 从 16 改成 17 不会迁移数据——不同版本的数据目录不同，新版本会初始化一个空库。安全路径是「`pg_dumpall` 导出 → 切版本 rebuild → 导入」；想原地 `pg_upgrade` 需要手工操作，细节以 NixOS 手册数据库章节为准。

### 24.6.4 Docker 与 Podman

```nix
{
  virtualisation.docker.enable = true;
  # 免 sudo 跑 docker 的关键：把用户加进 docker 组
  # （注意：docker 组成员等效 root 权限，多用户机器请三思）
  users.users.alice.extraGroups = [ "docker" ];
  # 存储位置、日志驱动等守护进程参数：virtualisation.docker.daemon.settings
  # （以选项检索为准）
}
```

Podman 是无守护进程、默认 rootless 的替代品，与 Docker 命令几乎兼容：

```nix
{
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;   # 提供 docker 命令的兼容别名
    defaultNetwork.settings.dns_enabled = true;   # 容器间可按名字互相解析
  };
}
```

两者怎么选：单机开发、要跑 docker-compose 生态、依赖 Docker 特有行为 → Docker；在意守护进程的安全面、想 rootless 跑容器 → Podman。

### 24.6.5 Syncthing：声明式节点与目录

```nix
{
  services.syncthing = {
    enable = true;
    user = "alice";                    # 以普通用户身份运行，数据权限清晰
    dataDir = "/home/alice/Sync";
    openDefaultPorts = true;           # 放行 22000/tcp 与 21027/udp
    overrideDevices = true;            # 设备/目录完全以配置为准，GUI 手改会被纠正
    overrideFolders = true;
    devices = { "nas" = { id = "ABCD123-XXXX..."; }; };   # id 从对端 GUI 复制
    folders."photos" = {
      path = "/home/alice/Photos";
      devices = [ "nas" ];             # 与哪些设备共享
    };
  };
}
```

### 24.6.6 restic：定时备份

```nix
{
  services.restic.backups."daily-home" = {
    paths = [ "/home/alice" "/var/lib/syncthing" ];   # 备什么
    repository = "/mnt/backup/restic";                # 备到哪（也可 sftp:/对象存储）
    initialize = true;               # 首次运行自动初始化仓库
    passwordFile = "/run/secrets/restic-pw";   # 仓库密钥，见第 30 章 secrets
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;             # 错过的触发在下次开机补跑
    };
    pruneOpts = [ "--keep-daily" "7" "--keep-weekly" "5" "--keep-monthly" "12" ];
  };
}
```

### 24.6.7 Tailscale：十分钟组网

```nix
{
  services.tailscale.enable = true;
  services.tailscale.openFirewall = true;   # 放行 tailscale0 接口流量
  # 首次登录：sudo tailscale up，浏览器授权后设备进入你的 tailnet
}
```

## 24.7 桌面环境常用配置

桌面相关选项近两年经历了一轮大迁移：原先挂在 `services.xserver.*` 下的显示管理器与桌面管理器，自 24.05 起逐步迁往 `services.displayManager.*` 与 `services.desktopManager.*`。新旧写法在过渡期内多有别名，最终以 <https://search.nixos.org/options> 为准。

### 24.7.1 GNOME

```nix
{
  services.xserver.enable = true;   # 基础层；纯 Wayland 会话也依赖它承载的选项
  services.displayManager.gdm.enable = true;       # 新写法；旧：services.xserver.displayManager.gdm.enable
  services.desktopManager.gnome.enable = true;     # 新写法；旧：services.xserver.desktopManager.gnome.enable
}
```

### 24.7.2 KDE Plasma

```nix
{
  services.displayManager.sddm.enable = true;      # 显示管理器
  services.desktopManager.plasma6.enable = true;   # Plasma 6；旧版是 plasma5
}
```

### 24.7.3 Sway 与 Hyprland（Wayland 平铺）

```nix
{
  # Sway：自带合理默认，装完即用
  programs.sway.enable = true;

  # Hyprland：动画与现代特性取向
  programs.hyprland.enable = true;
  # 可选增强：经 systemd 用户会话管理合成器，崩溃恢复更稳
  # programs.hyprland.withUWSM = true;   # 以选项检索为准
}
```

### 24.7.4 音频：PipeWire 全家桶

NixOS 24.05 起 `services.pulseaudio`/`hardware.pulseaudio` 已弃用，正确姿势是 PipeWire 加兼容层：

```nix
{
  security.rtkit.enable = true;   # 允许音频进程申请实时调度——防爆音的关键
  services.pipewire = {
    enable = true;
    alsa.enable = true;           # 兼容直接用 ALSA 的应用
    alsa.support32Bit = true;     # 32 位程序（Wine、老游戏）也能出声
    pulse.enable = true;          # 兼容庞大的 PulseAudio 客户端生态
    jack.enable = true;           # 专业音频软件（DAW）需要时再开
  };
  # 注意：与旧的 hardware.pulseaudio 同开会在求值期直接报错，看到冲突先删旧项
}
```

### 24.7.5 蓝牙

```nix
{
  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;   # 开机自动上电
  services.blueman.enable = true;   # 托盘管理工具；GNOME/KDE 自带，可不装
}
```

### 24.7.6 打印

```nix
{
  services.printing.enable = true;   # CUPS
  # 驱动按打印机品牌选：HP 用 hplip；佳能 cnijfilter2；兄弟 brlaser。
  # 具体属性名以 nixpkgs 检索为准
  services.printing.drivers = [ pkgs.hplip ];
  # 网络打印机自动发现（mDNS）
  services.avahi = {
    enable = true;
    nssmds4 = true;        # 名字解析走 mDNS，找到 printer.local
    openFirewall = true;
  };
}
```

### 24.7.7 笔记本电源

```nix
{
  # 二选一，同时开两个会在求值期冲突报错：
  # ① power-profiles-daemon：GNOME 默认风格，性能/平衡/省电三档，省心
  services.power-profiles-daemon.enable = true;
  # ② TLP：粒度细，适合长期插电的电池养护
  # services.tlp = {
  #   enable = true;
  #   settings = {
  #     CPU_SCALING_GOVERNOR_ON_AC = "performance";
  #     START_CHARGE_THRESH_BAT0 = 75;   # 充到 75% 停，延缓电池老化
  #   };
  # };
}
```

## 24.8 系统维护

### 24.8.1 自动升级：利与弊

```nix
{
  system.autoUpgrade = {
    enable = true;
    dates = "weekly";   # systemd timer 语法；支持 randomizedDelaySec 错峰
    # flake 用户：固定到自己的仓库，升级=拉取仓库最新 commit
    flake = "github:you/nixos-config";
    # 非 flake 用户：用默认 channel 并定期 nix-channel --update 等价物
    allowReboot = false;   # true 时配合 rebootWindow 限时段重启，服务器慎用
  };
}
```

利：安全补丁及时、无人值守、服务器批量跟进。弊：升级未经你审阅——某次 nixpkgs 的破坏性变更会在凌晨自动落到你所有机器上。务实建议：服务器开自动升级但锁定在你自己 fork 的 flake（先在测试机上验证再 merge）；桌面机手动升级，配合 `nix flake update` 后先读 release notes。

### 24.8.2 启动器选型：systemd-boot vs GRUB

```nix
{
  # ① UEFI + 单系统：systemd-boot，最简
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;   # 启动菜单保留的代数
  boot.loader.efi.canTouchEfiVariables = true;
}
```

```nix
{
  # ② BIOS 机器，或需要 os-prober 探测 Windows 双系统：GRUB
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/nvme0n1";   # BIOS 写整盘；EFI 机写 "nodev"
  boot.loader.grub.efiSupport = true;
  boot.loader.grub.useOSProber = true;        # 探测其他系统（Windows）
  boot.loader.grub.configurationLimit = 10;
}
```

经验法则：UEFI 且无特殊需求 → systemd-boot（通常还能自动发现 Windows 的 EFI 启动项）；BIOS、ZFS 根、精细主题或多重引导黑魔法 → GRUB。

### 24.8.3 /tmp 与防火墙

```nix
{
  # 每次开机清空 /tmp：传统发行版靠 tmp cleaner 定时任务，这里是一个布尔值
  boot.tmp.cleanOnBoot = true;

  networking.firewall = {
    enable = true;   # 默认即开启：NixOS 出厂「默认拒绝」，比多数发行版激进
    allowedTCPPorts = [ 80 443 22000 ];     # nginx 与 syncthing
    allowedUDPPorts = [ 21027 ];            # syncthing 发现协议
    # 端口段写法：allowedTCPPortRanges = [ { from = 50000; to = 50100; } ];
    # 信任内网接口（谨慎）：trustedInterfaces = [ "tailscale0" ];
  };
}
```

对照 Ubuntu：ufw 是「装了才有的默认关闭防火墙」，而 NixOS 的防火墙与 nftables 配置由同一个模块系统生成，服务模块还能自报端口需求（如上面的 `openFirewall`），端口声明与服务声明在同一个文件里可审计。

## 24.9 nixos-rebuild 全解

`nixos-rebuild` 是你与整台机器对话的唯一定义入口。五个动作的差异：

| 动作 | 求值/构建 | 激活 | 设为下次默认启动 | 典型用途 |
|---|---|---|---|---|
| `switch` | 是 | 立即 | 是 | 日常修改 |
| `boot` | 是 | 否，重启后生效 | 是 | 激活有风险，等维护窗口 |
| `test` | 是 | 立即 | 否 | 实验；重启即回到上一代 |
| `dry-activate` | 是 | 只打印「将重启/重载哪些单元」不执行 | 否 | 上线前预演影响面 |
| `dry-build` | 是 | 否 | 否 | 只想触发编译/预下载 |

常用组合：

```console
# 传统（channel）方式
$ sudo nixos-rebuild switch
# 先看看会发生什么，再真正执行
$ sudo nixos-rebuild dry-activate
# 升级 channel 后再切换；--rollback 可随时回到上一代
$ sudo nixos-rebuild switch --upgrade
$ sudo nixos-rebuild switch --rollback

# flake 方式：.后面跟 nixosConfigurations 里的主机名
$ sudo nixos-rebuild switch --flake .#thinkpad
# 更新锁定输入（受控升级，替代 channel）
$ nix flake update
# 远程部署到另一台机器（免登录目标机操作，详见第 31 章）
$ nixos-rebuild switch --flake .#web1 \
    --target-host deploy@web1.example.org --use-remote-sudo
```

flake 方式需要仓库里有一份 `flake.nix`（flakes 语法详见第 13—21 章）：

```nix
{
  description = "我的 NixOS 配置";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs, ... }: {
    nixosConfigurations.thinkpad = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ ./configuration.nix ];   # 与传统写法完全复用
    };
  };
}
```

敲下 `nixos-rebuild switch` 之后发生了什么？四步（机制细节在第 25—27 章）：

1. **求值**：模块系统把 `configuration.nix` 与 nixpkgs 里数百个模块合成一份完整的系统派生（derivation，第 14 章），包括每个 systemd 单元、每个 `/etc` 文件。
2. **构建**：realise 这份派生——优先从二进制缓存下载（第 20 章），缺的才本地编译（第 17 章）。
3. **激活**：在目标机上执行 `switch-to-configuration`：运行激活脚本写入 `/etc`、切换 `/run/current-system`、按需重启或重载变更的 systemd 单元（第 26、27、29 章）。
4. **注册新代**：把新系统登记为 `/nix/var/nix/profiles` 里的下一个 generation，更新启动菜单——这就是「回滚」的物理基础（第 18 章 profile 与第 21 章 GC）。

## 24.10 配置组织的实践

配置超过两三百行时，是时候拆分了。原则：`configuration.nix` 只做「组装」，具体内容按主题拆成模块。

```nix
# /etc/nixos/configuration.nix —— 收敛成一个「目录页」
{ ... }:

{
  imports = [
    ./hardware-configuration.nix   # 硬件事实（安装器生成）
    ./modules/base.nix             # 24.2：网络、时区、locale、字体、输入法
    ./modules/users.nix            # 24.3：用户与密码
    ./modules/nix-settings.nix     # 24.4：nix/nixpkgs
    ./modules/desktop.nix          # 24.7：桌面、音频、蓝牙
    ./modules/services.nix         # 24.6：nginx、数据库、备份
  ];
}
```

单机与多机：一台机器时按「主题」拆；多台机器时按「主题 × 主机」两个维度组织，共享的进 `common/`，差异的进各自主机文件，用 `lib.mkIf`/`lib.mkOption` 做开关（模块系统机制见第 25 章）。一个久经考验的仓库结构：

```text
nixos-config/
├── flake.nix            # 声明所有主机的 nixosConfigurations
├── hosts/
│   ├── thinkpad/        # 每台机器一个目录：configuration.nix + hardware-configuration.nix
│   └── server/
├── modules/             # 跨主机共享的主题模块
└── secrets/             # 加密后的机密（第 30 章的 sops-nix/agenix）
```

把这份仓库放进 git，你就同时拥有了：变更历史（git log）、代码评审（PR）、灾难恢复（clone + rebuild）。dotfiles（用户级配置）的管理策略与常见工具对比在第 45 章实战篇展开。

## 24.11 本章小结

- `configuration.nix` 加上安装器生成的 `hardware-configuration.nix` 是机器的完整定义；`system.stateVersion` 只在装机时设定、永不修改。
- 中文桌面三件套：`i18n.defaultLocale = "zh_CN.UTF-8"`、`i18n.inputMethod`（fcitx5 + 中文 addons）、`fonts.packages` + `fonts.fontconfig.defaultFonts`；TTY 下中文显示是内核限制。
- 用户是声明：`initialHashedPassword` 只在创建时生效，`hashedPassword` 配合 `mutableUsers = false` 才是每次激活强制同步；关闭 mutableUsers 前务必留好后门（SSH 密钥、已登录会话）。
- `nix.*` 管工具（实验特性、缓存、GC），`nixpkgs.*` 管货源（unfree、平台、overlay）。
- 服务配置的共同套路：模块把选项渲染成单元文件与配置文件，落在 store 里由激活脚本链接到位；改配置 = rebuild，不是改 `/etc`。
- 桌面选项正在从 `services.xserver.*` 向 `services.displayManager.*`/`services.desktopManager.*` 迁移；音频统一走 `services.pipewire` + `security.rtkit`。
- `nixos-rebuild` 五个动作记住两级：改生产用 `dry-activate` 预演；实验用 `test`（重启即弃）。
- rebuild 四步：求值 → 构建/下载 → 激活 → 注册新代；回滚的底气来自 generation。

**装机 checklist**（新机器按序过一遍）：

- [ ] `boot.loader`：UEFI 选 systemd-boot，设 `configurationLimit`
- [ ] `networking`：hostname、NetworkManager 或 wireless、防火墙端口
- [ ] `i18n` + `fonts` + `inputMethod`：中文一站式（24.2）
- [ ] `users`：wheel 用户、SSH 公钥、密码策略（决定 mutableUsers）
- [ ] `nix.settings`：experimental-features、substituters、GC
- [ ] `services.openssh`：禁密码、禁 root
- [ ] 桌面/音频/蓝牙/打印（按需，24.7）
- [ ] 备份（restic/borg）与 `system.autoUpgrade` 的取舍（24.8）
- [ ] 仓库进 git，`stateVersion` 确认未被改动

## 延伸阅读

- NixOS 选项检索（最重要的工具）：<https://search.nixos.org/options>
- NixOS 手册·配置语法与 rebuild：<https://nixos.org/manual/nixos/stable/#ch-configuration>
- NixOS Wiki·中文相关（Fonts、Input Method）：<https://wiki.nixos.org/wiki/Fonts>、<https://wiki.nixos.org/wiki/Input_Methods_for_Chinese>
- NixOS Wiki·PipeWire：<https://wiki.nixos.org/wiki/PipeWire>
- nixpkgs 源码中的模块定义（选项的最终出处）：<https://github.com/NixOS/nixpkgs/tree/master/nixos/modules>
