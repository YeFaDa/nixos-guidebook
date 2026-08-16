# 第 25 章 模块系统深度剖析

> **本章导读**：`configuration.nix` 里的一个 `services.nginx.enable = true;`，如何变成机器上运行的服务？答案是一台由约 1500 个模块组成的「求值机器」——NixOS 模块系统。它既是普通用户每天在用的东西，也可能是全书最深的一章：options 与 config 的分离、类型驱动的合并、优先级与条件、以及让这一切不打架的 fixed point。本章值得慢读两遍。

## 25.1 问题的形状：把一千个声明合并成一台机器

一台 NixOS 机器的配置来自四面八方：

- 你的 `configuration.nix` 与 `hardware-configuration.nix`；
- 每个启用服务的模块（nginx、postgresql、ssh……）；
- 硬件与安装器生成的模块；
- nixpkgs 自带的几百个基础模块（文件系统、用户、网络、引导……）。

每个模块都想对同一台机器说话：nginx 模块想声明「80 端口归我」，防火墙模块想知道「哪些端口要放行」，你本人还想加一条自定义规则。**模块系统的唯一任务：把任意多个模块的声明，合并（merge）成一份无矛盾的 `config`，并且让每个模块都能看到合并后的最终结果。**

## 25.2 模块的解剖：imports / options / config

一个模块就是一个属性集，四个可选部件：

```nix
# 一个典型的 NixOS 模块（逐行注释）
{
  # ① imports：引入其他模块（递归）
  imports = [ ./my-disk.nix ];

  # ② options：本模块对外暴露的「接口」——
  #    声明别人可以设置哪些选项、什么类型、默认值、文档
  options.services.myapp = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "是否启用 myapp 服务";
    };
    port = mkOption {
      type = types.port;
      default = 8080;
    };
  };

  # ③ config：本模块对「实现」的贡献——
  #    当接口被设置时，应该发生什么（贡献到全局 config 的其他选项）
  config = mkIf cfg.enable {
    systemd.services.myapp = { ... };        # 见第 29 章
    networking.firewall.allowedTCPPorts = [ cfg.port ];
    users.users.myapp = { isSystemUser = true; ... };
  };

  # ④ assertions/warnings：条件检查与提醒（43 章实战中展开）
}
```

两个关键直觉：

- **options 与 config 是一份合同的两面**：options 是「我提供什么参数」，config 是「拿到参数后我往系统里贡献什么」。分离使得系统可以两阶段求值：先收集全部接口 → 再合并全部实现。
- **`config.services.myapp.*` 读到的是「最终合并值」**：`cfg.port` 不是你写的那份原始值，而是全体模块（含你的 configuration.nix）合并、类型检查之后的定值。

## 25.3 两阶段求值与 fixed point：为什么不会死循环

棘手之处：nginx 模块的 config 想读防火墙的最终值，防火墙的 config 又想读 nginx 的最终值——**互相读对方的产出**。NixOS 的解法是把第 7 章的 `lib.fix`（不动点）用在模块集合上：

```
merged config = merge(所有模块在 merged config 下的 config)

即：先假设已有最终 config → 每个模块基于它求值 → 合并结果恰好收敛
```

惰性求值（第 11 章）保证了这不是诡辩而是可行的算法：只要「模块 A 读的值不直接依赖 A 贡献的值」，图就是无环的，fixpoint 一层层展开即可。若真的成环（A 的值依赖自己），你会收到 Nix 最著名的报错：`infinite recursion encountered`（排错方法见第 25.7 节与第 45 章）。

实际代码入口（nixpkgs/nixos/lib/eval-config.nix）：

```nix
# 概念形态（真实实现是 lib.evalModules 的层层封装）：
lib.evalModules {
  modules = [
    ./modules/list.nix 里的全部模块
    你的 configuration.nix
    ./hardware-configuration.nix
    { nixpkgs.hostPlatform = "x86_64-linux"; }  # 内置基础
  ];
  specialArgs = { inherit inputs; };   # 额外注入的参数（flakes 世界常用）
}
# 产出：{ options = ...; config = ...; }
```

`nixosSystem`（flake 场景）与 `<nixpkgs/nixos>`（channel 场景）都是它的皮。

## 25.4 类型驱动合并：为什么 listOf 能“相加”

合并语义由 **option 的类型**决定，这是模块系统最精妙的设计。同一选项被多个模块设置时：

| 类型 | 多来源合并规则 | 例子 |
|------|----------------|------|
| `types.bool` | 冲突报错（除非用优先级，25.5 节） | `enable` |
| `types.listOf types.package` | **拼接**（++） | `environment.systemPackages` |
| `types.str` / `types.lines` | str 冲突；lines **按行拼接** | `environment.etc."x".text` |
| `types.attrsOf types.str` | 按键合并 | `users.users`（每人一摊） |
| `types.int` / `types.port` | 冲突 | `port` |
| `types.submodule` | 递归进入子模块合并 | `services.myapp.instances` |
| `types.anything` | 结构化自动推断 | 高级用法 |

例子：三个模块各写一行 `environment.systemPackages = [ pkgs.git ];` 等，结果自动是三个包的并集——**这就是「声明式」的合力**：你写你的、我写我的，系统负责合并，而传统世界要由包管理器逐台机器执行命令拼凑出同样状态。

冲突处理原则同样明确：语义上可合并的类型自动合并；不可合并的类型一旦两个来源都给值就报「option ... has value ... while it should already have ...」——宁死不猜，把裁量权交给优先级机制（下节）。

## 25.5 优先级与条件：mkDefault / mkIf / mkMerge

四个日常最重要的修饰函数（全部来自 `lib`）：

```nix
# ① mkDefault：降低优先级（默认值可被普通设置覆盖）
#    模块作者给默认行为的写法；用户写普通值即可赢
sound.enable = mkDefault true;

# ② mkForce：提升优先级（强行覆盖其他模块/用户的普通设置）
networking.firewall.enable = mkForce true;
```

优先级是 `mkOverride 优先级 值` 的语法糖，**数值越小越「固执」**。阶梯如下（准确数值以 `lib` 文档为准）：

| 标记 | 优先级 | 合并时谁赢 |
|------|--------|-----------|
| `mkOptionDefault v` | 1500 | 任何显式设置都覆盖它（option 声明里的 default 即此级） |
| `mkDefault v` | 1000 | 输给一切无标记设置；模块作者给默认值的标准写法 |
| 无标记（`v`） | 100 | 赢 mkDefault；与另一份无标记同设一个不可合并选项时冲突报错 |
| `mkForce v` | 50 | 赢普通设置；通常只该由用户「最后拍板」时使用 |
| `mkOverride 0 v` | 0 | 理论极限，极少需要 |

```nix
# ③ mkIf：条件贡献（整个 config 块生效与否）
config = mkIf cfg.enable { ... };

# ④ mkMerge：同一选项多处贡献的显式合并（写在同一模块内时）
config = mkMerge [
  { environment.systemPackages = [ pkgs.hello ]; }
  (mkIf cfg.withExtra {
    environment.systemPackages = [ pkgs.hello-extras ];
  })
];
```

`mkIf` 的深层机制：它产生「条件配置」，模块系统在做冲突检测时会看穿条件（两个 `mkIf` 条件相同才可能冲突）。**不要用 `if cfg.enable then { ... } else { }` 替代 `mkIf`**——裸 if 会在两阶段求值中过早强制求值 `cfg.enable`，制造假性循环依赖，这是「infinite recursion」的第二大来源（第一大是 config 引用自身贡献的选项）。

## 25.6 站在模块作者肩上：怎么查、怎么试

```console
# 查看某选项的最终值与定义来源（调试第一利器）
$ nixos-option services.nginx.enable
Value:
true
Default:
false
Declarations:
/nix/store/...-source/nixos/modules/services/web-servers/nginx/nginx.nix

# 在 nix repl 里解剖（flakes 用户）
$ nix repl
nix-repl> :lf .
nix-repl> nixosConfigurations.myhost.config.services.nginx
nix-repl> nixosConfigurations.myhost.options.services.myapp.port.type.description

# 求值整个 config 为 JSON（脚本化检查）
$ nix eval .#nixosConfigurations.myhost.config.services.nginx.port
```

## 25.7 无限递归：症状与出路

模块世界的经典报错，三种主要成因与修法：

1. **config 自引用**：模块在 `config.services.myapp.port` 的计算里引用了 `config.services.myapp.port`（哪怕隔着几层函数）。修：改读 option 原始输入或拆分模块。
2. **裸 if 替代 mkIf**：过早强制求值（25.5 节）。修：换 `mkIf`。
3. **options/config 交叉**：把实现写进了 options 声明（或反之）。修：按合同归位。

定位：`nix eval --show-trace`（第 45 章），堆栈里反复出现的选项名就是环所在。

## 25.8 注入参数：_module.args 与 specialArgs

模块里访问「非选项」的外部数据（如 flake inputs）的两条路：

```nix
# 路 A（推荐，显式）：求值时注入
nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
  modules = [ ./hosts/myhost ];
  specialArgs = { inherit inputs; };   # 每个模块可直接 { inputs, ... }: 使用
};

# 路 B：作为「选项」注入（走模块系统，更可发现但更绕）
modules = [ { _module.args = { inherit inputs; }; } ];
```

`_module.args` 同样是官方支持的注入点；差异在调试可见性与覆盖行为，社区惯例偏向 specialArgs（简单直接）。

## 25.9 模块系统不是 NixOS 专属

`lib.evalModules` 是 nixpkgs 的通用库——Home Manager（第 24 章配置实践、第 30 章生态）、flake-parts、各类工具的配置系统全都用它实现。**学会了本章，你同时学会了整个 Nix 生态的配置内核**。第 43 章将带你完整写一个自己的模块。

## 25.10 本章小结

- 模块系统 = 把任意多模块的声明合并成一份 `config` 的求值机器；模块四要素：imports、options（接口）、config（实现）、assertions。
- 两阶段求值 + `lib.fix` + 惰性 = 「互相读最终值」不死循环；真环则报 infinite recursion。
- 合并规则由类型决定：listOf 拼接、attrsOf 按键、submodule 递归；不可合并类型冲突即报错。
- 优先级阶梯 mkOptionDefault < mkDefault < 无标记 < mkForce；条件用 mkIf（勿用裸 if），同模块多处贡献用 mkMerge。
- 调试三件套：nixos-option、nix repl、nix eval --show-trace；模块系统是全生态通用的（Home Manager、flake-parts）。

## 延伸阅读

- 「NixOS: A Purely Functional Linux Distribution」论文第 4 节（模块系统原始设计）
- nixpkgs 模块系统源码导览：lib/modules.nix（merge 的真正实现，值得一读）
- 手册 «Writing NixOS Modules»：https://nixos.org/manual/nixpkgs/unstable/#sec-writing-modules
