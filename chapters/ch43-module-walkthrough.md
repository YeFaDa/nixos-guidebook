# 第 43 章 编写自己的 NixOS 模块

> **本章导读**：这是全书压轴实战之二。我们将从零写一个完整的 NixOS 模块 `services.myapp`：守护进程、专用系统用户、声明式生成的配置文件、防火墙端口、可选的 nginx 反代集成、多实例支持、断言与警告、配套 VM 测试——一个生产级模块该有的元素一个不缺。第 25 章讲过模块系统的原理，本章把原理变成你自己的代码。

## 43.1 需求设定：要为 myapp 写一个什么样的模块

假设 `myapp` 是一个小型 Web 应用：单二进制、监听一个 HTTP 端口、读取 JSON 配置文件、密钥从环境变量注入。我们希望 NixOS 用户只需：

```nix
services.myapp = {
  enable = true;
  port = 8080;
  openFirewall = true;
};
```

就能得到：开机自启的 systemd 服务（第 29 章）、无登录权限的专用系统用户、由 Nix 生成并纳入配置管理的 `config.json`、按需放行的防火墙端口、以及可选的「自动配好 nginx 反向代理」。此外还要支持同一台机器跑多个实例（端口不同）。目标明确了，开始动工。

## 43.2 模块的五要素回顾

第 25 章剖析过模块系统，这里只把骨架立起来。一个 NixOS 模块是一个属性集，关键字段四个半：

| 要素 | 作用 |
| --- | --- |
| `imports` | 引入其他模块（复用与拆分） |
| `options` | 声明本模块提供的**配置接口**（选项的类型与文档） |
| `config` | 根据选项的值**决定**系统状态（服务、用户、文件……） |
| `assertions` / `warnings` | 求值期校验与提醒（43.7 节） |
| `meta.maintainers`（半个） | 维护者署名，出现在文档与 ofBorg/合并机器人的授权判断里（第 41 章） |

心法一句话：**options 是「别人可以对我说什么」，config 是「我听到之后做什么」。** 两者分离，是 NixOS 声明式配置（第 23、30 章）能组合出千机千面的根基。

## 43.3 第一步：最小可用模块

先搭一个只有开关、只起服务的骨架，跑通「写模块 → 引入 → 切换生效」的闭环：

```nix
# modules/myapp.nix —— 第一步:最小可用模块
{ config, lib, pkgs, ... }:
# ^ 模块固定签名:四个形参由模块系统注入
#   config:整机的最终配置(读别人的选项)
#   lib:   标准库(mkOption/mkIf 都在这里)
#   pkgs:  包集合(本配置求值用的那份,第 39 章强调过别自己 import)
#   ...:   忽略多余注入参数(必须加,否则求值报错)

let
  # 惯例缩写:模块内引用自己的选项一律走 cfg
  cfg = config.services.myapp;
in
{
  # ―― 要素一:options,声明接口 ――
  options.services.myapp.enable =
    lib.mkEnableOption "myapp 服务";
    # mkEnableOption 是「布尔开关」的快捷方式:
    # 自动得到 type=bool、default=false、现成的中文可读描述

  # ―― 要素二:config,听到之后做什么 ――
  config = lib.mkIf cfg.enable {
    # mkIf:只有开关打开时,下面这棵配置树才生效(为什么必须加,43.5 节细说)
    systemd.services.myapp = {
      description = "myapp —— 示例 Web 应用";
      wantedBy = [ "multi-user.target" ];
      # ^ 挂到多用户目标下:开机自启(第 28、29 章)
      serviceConfig = {
        ExecStart = "${pkgs.hello}/bin/hello";
        # ^ 先拿现成程序占位,骨架通了再换成真包
        #   为什么用字符串插值:store 路径进配置,升级即换路径,无状态(第 30 章)
        DynamicUser = true;
        # ^ systemd 动态用户:先用最省事的方式拿到非 root 运行,
        #   43.5 节换成我们自己的专用用户
        Restart = "on-failure";
      };
    };
  };
}
```

接入并验证：

```nix
# configuration.nix(节选)
{
  imports = [ ./modules/myapp.nix ];   # 引入模块:从此选项可用
  services.myapp.enable = true;
}
```

```console
$ sudo nixos-rebuild switch      # 切换(第 27 章讲过它做了什么)
$ systemctl status myapp.service # 进程已经以动态用户跑起来了
```

## 43.4 第二步：类型完整的 options

真实模块的接口必须类型精确、文档齐全——因为 `default`、`example`、`description` 会原样出现在 search.nixos.org 与 Options 手册上，**写文档即写代码**：

```nix
# modules/myapp.nix 的 options 部分(替换 43.3 的单开关)
let
  inherit (lib) mkOption mkEnableOption types literalExpression;
in
{
  options.services.myapp = {
    enable = mkEnableOption "myapp 服务";

    package = mkOption {
      type = types.package;              # 必须是一个「包」(派生)
      default = pkgs.myapp;
      # 文档里显示 pkgs.myapp 这个符号,而不是展开后的 store 路径
      defaultText = literalExpression "pkgs.myapp";
      description = "要部署的 myapp 包;换版本或加 overlay 时覆盖此项(第 39 章)。";
    };

    port = mkOption {
      type = types.port;                 # 内置端口类型:只接受 1..65535 的整数
      default = 8080;
      example = 9090;                    # 文档里的示例值,与 default 分开表达意图
      description = "HTTP 监听端口。";
    };

    banner = mkOption {
      type = types.lines;                # 多行文本:多个模块定义会自动拼接
      default = "";
      description = "首页横幅文本,支持多行。";
    };

    environmentFile = mkOption {
      type = types.nullOr types.str;     # nullOr:可以为 null(「不设」也是合法值)
      default = null;
      example = "/run/keys/myapp.env";
      description = ''
        运行时加载的环境变量文件(密钥放这里,不要写进 Nix 配置)。
        为 null 时不加载。
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;                   # 默认关:安全默认值,显式选择才放行
      description = "是否在防火墙放行监听端口。";
    };

    tags = mkOption {
      type = types.attrsOf types.str;    # 属性集:键值都由用户定
      default = { };
      example = { env = "prod"; region = "cn"; };
      description = "附加标签,写入配置文件。";
    };
  };
}
```

常用的类型速查（完整清单见 NixOS 手册 Option Types 一节）：`types.bool`、`types.str`、`types.lines`、`types.port`、`types.int`、`types.package`、`types.path`、`types.listOf t`、`types.attrsOf t`、`types.nullOr t`、`types.enum [ ... ]`、`types.submodule`（43.6 节的主力）。类型的意义不只是文档：写错类型在**求值期**就报错，`nixos-rebuild` 走不到构建就被拦下。

## 43.5 第三步：config 的声明式组合

现在把 config 写丰满。这一步要回答四个问题：mkIf 为什么必须加、mkMerge 何时用、配置文件怎么生成、用户与防火墙怎么配。

```nix
# modules/myapp.nix 的 config 部分(替换 43.3 的骨架 config)
let
  cfg = config.services.myapp;
  # pkgs.formats:声明式配置 → 目标格式的标准帮手(支持 json/toml/yaml/ini…)
  settingsFormat = pkgs.formats.json { };
  configFile = settingsFormat.generate "myapp-config.json" ({
    # 配置内容来自选项:用户改选项,文件自动变
    port = cfg.port;
    inherit (cfg) banner tags;
  });
in
{
  config = lib.mkIf cfg.enable (lib.mkMerge [
    # ―― 基础块:始终生效(在开关打开的前提下) ――
    {
      systemd.services.myapp = {
        description = "myapp —— 示例 Web 应用";
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];   # 等「网络真正可用」再启动
        wantedBy = [ "multi-user.target" ];

        # 环境变量文件:密钥的唯一正确入口(见下文「运行时秘密」)
        environmentFile = lib.mkIf (cfg.environmentFile != null) cfg.environmentFile;

        serviceConfig = {
          ExecStart = "${cfg.package}/bin/myapp --config /etc/myapp/config.json";
          User = "myapp";                        # 专用用户,不再用 DynamicUser
          Group = "myapp";
          StateDirectory = "myapp";
          # ^ systemd 自动创建 /var/lib/myapp 并属主给 myapp:
          #   持久状态唯一应该存在的地方(第 30 章的无状态哲学)
          NoNewPrivileges = true;                # 起步级加固,按需增减
          ProtectSystem = "strict";
          ProtectHome = true;
          Restart = "on-failure";
        };
      };

      # 配置文件进 /etc:由派生生成,内容变化即路径变化,纳入配置管理
      environment.etc."myapp/config.json".source = configFile;

      # 专用系统用户与组:不能登录,只属于这个服务
      users.users.myapp = {
        isSystemUser = true;        # 系统用户:uid 分配在系统区间,不出现在登录界面
        group = "myapp";
        description = "myapp 服务运行账户";
      };
      users.groups.myapp = { };
    }

    # ―― 条件块一:开关打开防火墙时追加 ――
    (lib.mkIf cfg.openFirewall {
      networking.firewall.allowedTCPPorts = [ cfg.port ];
      # 列表型选项天然支持合并:这里 [ 8080 ],别处 [ 22 ],
      # 最终值是拼接而非覆盖——声明式组合的日常
    })

    # ―― 条件块二:指定了虚拟主机时,自动配 nginx 反代 ――
    (lib.mkIf (cfg.virtualHost != null) {
      services.nginx.virtualHosts.${cfg.virtualHost} = {
        locations."/".proxyPass = "http://127.0.0.1:${toString cfg.port}";
        # 跨模块组合:我们在写 nginx 的选项,nginx 模块负责落地
        # 这就是「模块作曲家」模式——你不需要懂 nginx 的配置文件语法
      };
    })
  ]);
}
```

（配套地，给 options 加上 `virtualHost`：`type = types.nullOr types.str; default = null;`，描述为「非 null 时自动配置 nginx 反代到此主机名」。）

**为什么 `mkIf` 必须加**？技术上，不加 mkIf 很多时候也能求值通过——但代价是：只要 import 了这个模块，用户与 systemd 服务**无条件出现**，`enable` 形同虚设。更隐蔽的是语义层级：mkIf 表达的是「这一整块定义是否参与合并」。有了它，别的模块才能用 `mkForce` 优先级、或在自己的 mkIf 里与之自然叠加。所以规矩只有一条：**config 的顶层永远写成 `mkIf cfg.enable (...)`**。

**`mkMerge` 何时用**？当**同一个属性路径有多处定义**且需要合并语义时。列表、属性集类型的选项默认就能跨模块合并（防火墙端口就是例子）；但当你想在**一个 config 里**并列多个 mkIf 块、又要让它们都作用到 `systemd.services.myapp` 这棵树上时，必须用 mkMerge 把多个属性集显式合并——否则就是同一属性的重复定义错误。经验法则：config 里有多个分支块就套 mkMerge，一个整块时可以省。

**运行时秘密的正确姿势**：Nix store 全局可读（第 14 章），任何写进配置的东西都等于公开。所以密钥的通道是 `environmentFile` 指向 `/run/keys/myapp.env`——`/run` 是运行时文件系统（tmpfs），不落盘、不进 store；密钥由部署系统（如 colmena/软盘钥匙）注入，机器重启后无残留，正是第 30 章无状态哲学的安全面。配置文件里的 `settingsFormat.generate` 只负责**非秘密**部分，两者泾渭分明。

## 43.6 第四步：多实例设计

需求升级：同一台机器要跑 myapp 的 `a`、`b` 两个实例，端口、开关各自独立。NixOS 的标准答案是 `attrsOf (submodule ...)`（子模块属性集）——每个属性值都是一套带类型的完整选项，且子模块自动收到 `name`（属性键名）注入：

```nix
# modules/myapp.nix:把 43.4/43.5 的单实例选项改造为 instances
{ config, lib, pkgs, ... }:
let
  cfg = config.services.myapp;
in
{
  options.services.myapp = {
    instances = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
        # ^ submodule 的参数里有 name:即用户写的属性键("a"、"b"……)
        #   模块系统自动注入,这是多实例魔法的全部来源
        options = {
          enable = lib.mkEnableOption "myapp 实例 ${name}";
          # ^ 选项描述里直接引用 name:文档自动个性化

          port = lib.mkOption {
            type = lib.types.port;
            description = "实例 ${name} 的 HTTP 端口。";
          };

          package = lib.mkOption {
            type = lib.types.package;
            default = pkgs.myapp;
            description = "实例 ${name} 使用的包。";
          };

          openFirewall = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "是否放行实例 ${name} 的端口。";
          };
        };
      }));
      default = { };
      example = {
        a.port = 8081;
        b.port = 8082;
      };
      description = "myapp 实例集合,属性名即实例名。";
    };
  };

  config =
    let
      # 只保留启用的实例;filterAttrs 后仍是 attrsOf,键(名字)不丢
      eachInstance = lib.filterAttrs (_: inst: inst.enable) cfg.instances;
    in
    lib.mkIf (eachInstance != { }) (lib.mkMerge [
      {
        # 用户与组全实例共享:机器上不需要 20 个 myapp-a/b/c 用户
        users.users.myapp = {
          isSystemUser = true;
          group = "myapp";
        };
        users.groups.myapp = { };
      }

      # mapAttrsToList:把属性集摊平成列表,每个实例产出一棵配置树,
      # 再由 mkMerge 合成整体——「each attrs' 生成多个 unit」的惯用姿势
      (lib.mkMerge (lib.mapAttrsToList
        (name: inst: {
          # 用名字给 unit 定名:实例 a → myapp-a.service
          systemd.services."myapp-${name}" = {
            description = "myapp 实例 ${name}";
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              ExecStart = "${inst.package}/bin/myapp --port ${toString inst.port}";
              User = "myapp";
              Group = "myapp";
              Restart = "on-failure";
            };
          };
          # 防火墙:每个实例按自己的开关追加端口,列表合并天然支持多实例
          networking.firewall.allowedTCPPorts =
            lib.mkIf inst.openFirewall [ inst.port ];
        })
        eachInstance))
    ]);
}
```

用户侧的使用体验：

```nix
services.myapp.instances = {
  a = { enable = true; port = 8081; openFirewall = true; };
  b = { enable = true; port = 8082; };
};
# 得到 myapp-a.service 与 myapp-b.service,共享 myapp 用户,端口各自放行
```

## 43.7 assertions 与 warnings：把错误提前到求值期

运行时才发现端口冲突是最糟的体验。NixOS 把校验放在**求值期**：`nixos-rebuild` 在构建与切换（第 26、27 章）之前就拒绝非法配置。三件套写法：

```nix
# modules/myapp.nix 内追加(config 部分之外另起一棵,或并入 mkMerge)
let
  ports = lib.mapAttrsToList (_: inst: inst.port) cfg.instances;
  # ^ 收集所有实例端口,用于查重
in
{
  config = {
    # ―― assertions:硬校验,不满足直接失败 ――
    assertions = [
      {
        # 端口查重:去重后长度不变 ⇔ 无重复
        assertion = lib.length (lib.unique ports) == lib.length ports;
        message = "services.myapp: 实例端口冲突,当前端口列表:${toString ports}";
      }
      {
        # 跨选项约束:配了 nginx 集成就得有实例可代理
        assertion = cfg.virtualHost == null || cfg.instances != { };
        message = "services.myapp.virtualHost 已设置,但没有任何实例启用。";
      }
    ];

    # ―― warnings:软提醒,配置仍会构建,但切换时打印醒目警告 ――
    warnings =
      lib.optional (cfg.legacyMode)
        "services.myapp.legacyMode 已弃用,将在下个大版本移除,请迁移。";
    # lib.optional cond x:cond 为真时返回 [x],否则 []
  };
}
```

区别与取舍：`assertions` 用于「继续下去一定错」（端口冲突、必填缺失、互斥选项同开）；`warnings` 用于「能跑但不建议」（弃用提示、性能隐患）。它们的检查发生在求值期，用户在 `nixos-rebuild` 的输出里第一时间看到，而非半夜服务起不来。

## 43.8 测试与调试

**一条 VM 测试**（呼应第 41 章）是模块的出厂体检。用 `testers.nixosTest` 在 nixpkgs 之外写测试：

```nix
# tests/myapp.nix —— myapp 模块的 VM 测试
{ pkgs ? import <nixpkgs> { } }:
pkgs.testers.nixosTest {
  name = "myapp";

  nodes.machine = {
    imports = [ ../modules/myapp.nix ];   # 直接引入被测模块——测的就是你写的这份
    services.myapp.instances = {
      a = {
        enable = true;
        port = 8081;
        openFirewall = true;
      };
    };
  };

  testScript = /* python */ ''
    start_all()
    machine.wait_for_unit("myapp-a.service")   # 等 systemd 单元 active
    machine.wait_for_open_port(8081)           # 等端口就绪
    out = machine.succeed("curl -fsS http://127.0.0.1:8081/")
    assert "myapp" in out, f"响应异常:{out}"
    # 反向断言:没启用的实例不该存在
    machine.fail("systemctl is-active myapp-b.service")
  '';
}
```

```console
$ nix-build tests/myapp.nix     # 构建即运行:VM 起来、脚本跑完、绿了才算过
```

**调试三板斧**：

```console
# 一、nix repl:交互式检查求值结果
$ nix repl
nix-repl> :lf /etc/nixos                # 载入本机 flake(第 21 章)
nix-repl> nixosConfigurations.myhost.config.services.myapp.instances.a.port
8081
nix-repl> :p nixosConfigurations.myhost.config.systemd.services."myapp-a".serviceConfig
# :p 强制完整打印 —— 检查 ExecStart 等最终拼出来的值

# 二、nixos-option:终端里直接查选项的值、默认值与文档
$ nixos-option services.myapp.instances.a.enable
Value:
true
Default:
false
Description:
Whether to enable myapp 实例 a.
# (对 flake 配置的支持以 nixos-option 手册为准)

# 三、diff 与构建演练
$ nixos-rebuild build-vm   # 先在本地 VM 里演练切换,不动真机
$ nixos-rebuild test       # 应用到当前系统但不设为启动默认(第 24 章)
```

## 43.9 发布途径对比：进 nixpkgs 还是自维护 flake

模块写完了，怎么让别人用上？两条路：

**路线一：贡献进 nixpkgs**。约定与要点：

- 模块放 `nixos/modules/services/web-apps/myapp.nix`（按服务类别选目录，`web-apps`、`monitoring`、`networking`……）；
- 在 `nixos/modules/module-list.nix` 注册一行 `./services/web-apps/myapp.nix;`——不注册,模块不会被默认 import;
- 评审要点（前章工具的用武之地，第 41 章）：`meta.maintainers` 加上你自己；选项的 `description`/`example`/`defaultText` 完整（它们直接变成官方文档）；默认关闭、不强制引入额外依赖；附 `nixos/tests/myapp.nix` 测试；类型精确、无 `types.unspecified` 混过场。

**路线二：自维护 flake 模块**。发布节奏完全自主：

```nix
# flake.nix —— 你的模块仓库
{
  description = "myapp 的 NixOS 模块";
  outputs = { self }: {
    nixosModules.default = import ./modules/myapp.nix;
    # ^ default:消费者写 your-flake.nixosModules.default 时的默认入口
    nixosModules.myapp = self.nixosModules.default;
    # ^ 再按名暴露一份,便于显式引用
  };
}
```

消费方式（用户的 flake）：

```nix
{
  inputs.myapp.url = "github:you/nixos-myapp";
  outputs = { self, nixpkgs, myapp }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        myapp.nixosModules.default    # 一行接入,选项即刻可用
        ./configuration.nix
      ];
    };
  };
}
```

| 维度 | 进 nixpkgs | 自维护 flake |
| --- | --- | --- |
| 文档曝光 | search.nixos.org 全网可查 | 靠自己 README |
| 用户升级 | 跟随渠道（第 41 章的晋升节奏） | 跟随你的仓库,即时 |
| 迭代速度 | PR 评审周期 | 秒级 |
| 版本耦合 | 与 channel 绑定 | 可声明兼容多个 nixpkgs 版本 |
| CI 与测试 | Hydra 免费构建你的测试 | 自己搭 CI（第 41.7 节模板） |

常见路径是：先自维护 flake 快速迭代，稳定后贡献 nixpkgs 让它进入默认生态，两不耽误。

## 43.10 接口演进与维护：不破坏用户配置的艺术

模块的公开选项是一次承诺。改名、删选项都可能让用户的配置突然报错，NixOS 为此准备了一组迁移宏：

```nix
# modules/myapp.nix 顶部追加
{
  imports = [
    # 改名:httpPort → port
    # 老配置里写 services.myapp.httpPort 的用户:值自动迁移到新名,
    # 求值时打印弃用警告,一行代码完成无损升级
    (lib.mkRenamedOptionModule
      [ "services" "myapp" "httpPort" ]
      [ "services" "myapp" "port" ])

    # 删除:verbose 已移除
    # 老配置仍写它时:求值报错,并展示你给的迁移指引
    (lib.mkRemovedOptionModule
      [ "services" "myapp" "verbose" ]
      "改用 services.myapp.instances.<name> 的日志配置")
  ];
}
```

同族还有 `mkChangedOptionModule`（值语义变化时转换）、`mkAliasOptionModule`（保留别名）等，以 NixOS 手册与 `lib/modules.nix` 为准。

**settings 风格（RFC 42）** 是现代模块的接口惯例：当上游应用的配置项成百上千、逐项建模不现实时，用一个 `settings` 属性集直通上游配置格式——对已知关键字段强类型建模，其余交给自由格式兜底：

```nix
# RFC 42 settings 惯例(节选)
let
  settingsFormat = pkgs.formats.toml { };
in
{
  options.services.myapp.settings = lib.mkOption {
    type = lib.types.submodule {
      freeformType = settingsFormat.type;   # 自由格式兜底:合法 TOML 键值都接受
      options = {
        workers = lib.mkOption {            # 关键字段仍强类型 + 出文档
          type = lib.types.ints.positive;
          default = 2;
          description = "工作进程数。";
        };
      };
    };
    default = { };
    description = "myapp 的 config.toml 内容(RFC 42 settings 风格)。";
  };

  config.environment.etc."myapp/config.toml".source =
    settingsFormat.generate "config.toml"
      config.services.myapp.settings;
}
```

好处立竿见影：上游加新配置项时用户立刻能用（freeform 兜底），而核心项保留类型校验与文档。第 25 章读过的 nginx、`services.postgresql.settings` 等都是这一惯例的实践者。

## 43.11 本章小结

- 模块四要素加半个：`imports` 复用、`options` 声明接口、`config` 决定状态、`assertions`/`warnings` 求值期把关、`meta.maintainers` 署名并参与合并授权。
- options 的类型要精确（`types.port`/`attrsOf`/`nullOr`/`submodule`……），`default`/`example`/`description` 会直接变成 search.nixos.org 上的文档——写文档即写代码。
- config 顶层永远 `mkIf cfg.enable`；同一属性路径多个定义块用 `mkMerge`；列表型选项跨模块自动拼接。
- 配置文件用 `pkgs.formats.*.generate` 生成；秘密绝不进 store，走 `environmentFile` 指向 `/run/keys`（第 30 章无状态哲学）。
- 多实例 = `attrsOf (submodule ({ name, ... }))` + `filterAttrs` + `mapAttrsToList` + `mkMerge`，`name` 注入让 unit 名、文档自动个性化。
- 端口冲突等非法状态用 `assertions` 在求值期拦截；弃用提醒用 `warnings`。
- 测试用 `testers.nixosTest` 写 VM 测试；调试用 `nix repl` 检查求值结果、`nixos-option` 查选项、`build-vm` 演练。
- 发布两路线：进 nixpkgs（在 module-list.nix 注册、文档测试齐全、生态曝光）或自维护 flake 输出 `nixosModules.default`（迭代快、节奏自主）。
- 接口演进用 `mkRenamedOptionModule`/`mkRemovedOptionModule` 无损迁移；新模块优先采用 RFC 42 的 `settings` 惯例。

## 延伸阅读

- NixOS 手册·编写模块：https://nixos.org/manual/nixos/stable/#sec-writing-modules
- NixOS 手册·选项类型：https://nixos.org/manual/nixos/stable/#sec-option-types
- NixOS 选项检索（看真实模块的 options 长什么样）：https://search.nixos.org/options
- nixpkgs 源码·官方模块目录：https://github.com/NixOS/nixpkgs/tree/master/nixos/modules
- nixpkgs 源码·模块系统库（mkRenamedOptionModule 等实现）：https://github.com/NixOS/nixpkgs/blob/master/lib/modules.nix
- RFC 42·settings 配置惯例：https://github.com/NixOS/rfcs/blob/master/rfcs/0042-config-option.md
