# 第 45 章 用户环境与 home-manager

> **本章导读**：第 24 章的 configuration.nix 让「整台机器」声明化了，但登录之后你面对的仍然是传统的 `$HOME`：shell 配置、git 配置、编辑器插件、`~/.local/bin` 里手动装的程序——这一切在第 30 章里被标记为「不由 NixOS 管理」的状态。本章讲社区给出的答案 home-manager：它是什么（一个「单用户版 mini-NixOS」）、两种使用模式怎么选、`home.packages` 与 `programs.*` 各管什么、激活与回滚如何在用户层实现原子切换，以及从 nix-env 和手抄 dotfiles 迁移的完整路线。第 44 章的模板已经给出 flake 里「怎么接线」，本章补齐「为什么这样设计、日常怎么用、坑在哪里」。

## 45.1 问题：系统声明化了，用户呢

假设你已经把一台 NixOS 机器配得很好：内核、服务、字体、系统级包全部来自 configuration.nix，`nixos-rebuild switch --rollback` 随时可退。现在新建一个普通用户 `alice` 并登录，她会发现：

- 想装一个只给自己用的工具（比如 `lazygit`），要么去麻烦管理员写进 `environment.systemPackages`（全体用户可见），要么退回命令式的 `nix profile install`（第 18 章）——后者的「装了什么」是一份操作历史，不是声明；
- shell 是 bash 默认配置，想换 zsh + 插件 + 自己的 prompt，得手改 `~/.zshrc`；
- git 想设置用户名邮箱、默认分支名，得手改 `~/.gitconfig`；
- 这堆 dotfiles 想跨机器同步，传统做法是 git 仓库 + GNU stow 或者一堆 symlink 脚本——但 stow 只管「文件的摆放」，不管「程序有没有装」：新机器上 clone 了 dotfiles，`~/.zshrc` 里引用的 exa、starship、zoxide 一个都不存在。

把这些痛点归拢，本质是三个缺失：

1. **用户级包的声明式管理**：介于「全系统」与「命令式 profile」之间的空白层；
2. **dotfiles 与包的联动**：配置文件引用的程序，应当与配置文件本身来自同一份声明；
3. **用户环境的原子切换与回滚**：改坏了 shell 配置，应该能像 `nixos-rebuild --rollback` 一样一条命令退回去，而不是手忙脚乱地 `git checkout` 再手动重载。

GNU stow / yadm / chezmoi 这类纯 dotfiles 管理器解决不了 1 和 3；`nix profile` 解决不了 2 和 3。home-manager 把三件事一起做掉——这也是它成为生态中使用率最高的第三方工具的原因（另一个常被提起的比较对象 NixGL 管的是 GPU，不在一个赛道）。

## 45.2 心智模型：单用户版 mini-NixOS

一句话定义：**home-manager 是把 NixOS 的「模块系统 + 激活机制 + generation profile」三层结构，在单个用户的 `$HOME` 里重演一遍的产物。** 用全书已有的概念对照着看，它没有任何新魔法：

| NixOS（第 24–27 章） | home-manager | 说明 |
| --- | --- | --- |
| configuration.nix | `home.nix`（或 `home/alice.nix`） | 同一个模块系统的入口 |
| `nixos-rebuild switch` | `home-manager switch` | 求值 → 构建 → 激活 |
| 激活脚本 activation scripts（第 26 章） | home-manager 的 activation | 往 `$HOME` 写文件、生成 symlink |
| 系统 generation（`/nix/var/nix/profiles/system`） | 用户 generation（`~/.local/state/nix/profiles/home-manager`） | 原子切换、可回滚的单位 |
| `systemd.services.*` / `systemd.user` | `systemd.user.services.*` | 用户级服务（如 syncthing、gpg-agent） |
| `environment.systemPackages` | `home.packages` | 只对当前用户可见的包 |
| `environment.etc`（`/etc` 下的只读文件） | `home.file`（`$HOME` 下的 symlink） | 声明式摆放配置文件 |

第 25 章讲过 NixOS 模块系统的 `mkOption`/`mkMerge`/`fixpoint` 合并——home-manager 用的**就是同一套库**（`lib.types`、`lib.evalModules`），只是 option 树的根从 `config.*`（整机）换成了 `home.*`、`programs.*`、`wayland.*` 等（单个用户环境）。所以你在第 25 章学的所有合并语义、`mkIf`/`mkForce` 技巧、模块拆分方法，原封不动可用。

一个关键区别要提前钉住：NixOS 的激活产物是 `/run/current-system`（系统全局、root 所有），而 home-manager 的激活产物落在**用户自己的领地**：

```console
$ readlink -f ~/.config/home-manager 2>/dev/null; readlink ~/.zshrc 2>/dev/null
/nix/store/...-home-manager-files/.zshrc
```

`home-manager switch` 做的事，就是把你声明的那份 `$HOME` 的应有形态构建成一个 store 路径，然后用 symlink 把 `~/.zshrc`、`~/.config/git/config` 等逐个指过去（不会指出去的：`~/downloads` 这类数据目录永远不碰）。这与第 26 章「activation scripts 把 /etc 摆成声明形态」是同一个思想，只是对象从 `/etc` 换成了 `$HOME`。

也因此，第 30 章那张「哪些路径归谁管」的表在引入 home-manager 后可以补全一行：

| 路径 | 归属 |
| --- | --- |
| `~/.zshrc`、`~/.config/...`（被声明的部分） | home-manager（symlink → /nix/store） |
| `~/documents`、`~/.ssh/id_ed25519` 等数据 | 用户自己（声明式系统永不触碰） |

## 45.3 两种模式与两个世界

home-manager 的安装使用由两个正交的选择决定：**以什么身份接入**（NixOS 模块 or 独立运行）与**走哪套包管理世界**（channel or flake）。第 44 章 44.7 给过 flake + 两种身份的接线代码，这里讲清取舍逻辑，再补 channel 世界的最小配置。

### 45.3.1 NixOS 模块模式 vs 独立模式

| | 独立模式（standalone） | NixOS 模块模式（as-NixOS-module） |
| --- | --- | --- |
| 配置入口 | `home-manager switch --flake .#alice` | 跟随 `nixos-rebuild switch` |
| profile 位置 | 用户自己的 home-manager profile | `~/.local/state/nix/profiles/home-manager`（由系统激活时构建） |
| 原子性 | 系统/用户各自切换 | 系统 + 用户一次性原子切换 |
| 依赖 root | 否 | 是（要跑 nixos-rebuild） |
| 适用场景 | 非 NixOS 的 Linux/macOS；服务器上无 root 的账号；root 与普通用户配置分开演进的机器 | 全套 NixOS 的个人机器（本书推荐默认） |

选择逻辑很简单：**你的用户住在一台由你管理的 NixOS 上吗？** 是 → 模块模式，系统和用户环境一起原子切换，`nixos-rebuild switch` 一条命令到位；否（比如公司 Ubuntu 开发机、macOS）→ 独立模式，home-manager 是你在别人领地里唯一的声明式据点。两种模式下 `home.nix` 本身完全相同——差异只在「谁负责激活它」。

### 45.3.2 flake 世界（推荐）

接线方法第 44 章已逐行讲过（`follows` 对齐 nixpkgs、`useGlobalPkgs`/`useUserPackages` 的含义见 45.6.2），这里只给独立模式的最小骨架作为快查：

```nix
# flake.nix —— 独立模式最小骨架（模块模式见第 44 章 44.7）
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    home-manager = {
      # 分支必须与 nixpkgs 大版本匹配：release-26.05 配 nixos-26.05
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";   # 复用同一份 nixpkgs，避免双份闭包
    };
  };
  outputs = { nixpkgs, home-manager, ... }: {
    homeConfigurations."alice" =
      home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        modules = [ ./home/alice.nix ];
        # 参数形状随版本有过调整，以 home-manager 手册当前版本为准
      };
  };
}
```

```console
$ nix run home-manager -- switch --flake .#alice   # 免安装调用，适合初次体验
```

### 45.3.3 channel 世界（了解即可）

在还没迁移到 flakes 的旧式 NixOS 上，home-manager 走 channel：

```console
# root 执行：添加与系统 nixos channel 同版本的 home-manager channel
# nixos-26.05 对应 release-26.05，版本错位是最大坑源（45.6.3）
# sudo nix-channel --add https://github.com/nix-community/home-manager/archive/release-26.05.tar.gz home-manager
# sudo nix-channel --update
```

然后在 configuration.nix 里 `imports = [ <home-manager/nixos> ];` 并写 `home-manager.users.alice = { ... };`。机制与 flake 世界完全一致，只是输入版本由 channel 指针而非 flake.lock 锁定（第 18 章讲过两者的锁定语义差异）。新项目一律建议 flakes。

## 45.4 声明什么：四个层次的配置面

`home.nix` 里能写的东西分四层，从「装包」到「摆文件」到「整段程序配置」到「跑服务」。理解这四层的分工，是写出不拧巴的配置的前提。

### 45.4.1 home.packages：用户级软件

```nix
{ pkgs, ... }: {
  # 只对当前用户可见的包。PATH 通过 profile 的 /bin 注入，
  # 与第 18 章讲的 profile 机制同源
  home.packages = [
    pkgs.lazygit
    pkgs.ripgrep
    pkgs-unstable.some-tool   # 混用 unstable 需先把 unstable pkgs 传进来（第 44 章 specialArgs）
  ];
}
```

它和 `environment.systemPackages` 的边界：**全体用户要用的进系统配置，只给自己用的进 home.packages**。桌面机单人使用时两者皆可，但放进 home 有一个实际好处——换机器/重装时，你的工具清单跟用户配置一起走，不依赖某台特定主机的 configuration.nix。

### 45.4.2 home.file：把文件放进 $HOME

```nix
{ ... }: {
  home.file = {
    # 通用形式：source（文件或目录，会被拷进 store）+ target（相对 $HOME 的路径）
    ".config/some-app/config.toml".source = ./config.toml;

    # 纯文本也可以直接内联，text 会先写进 store 再 symlink
    ".config/gamma/settings.conf".text = ''
      theme = dark
    '';
  };
}
```

`home.file` 是万能底座，但**写配置前先查一层**：home-manager 内置了数百个 `programs.*` 模块，把最常见的配置文件做成了带类型检查的选项。能用 `programs.*` 就不要手写 `home.file`——前者有类型约束、能感知包是否启用，后者只是一段会过期的文本。

### 45.4.3 programs.*：带语义的程序配置

这是 home-manager 真正的招牌。对比同一件事的两种写法：

```nix
# 写法一：home.file 手抄整份配置（能跑，但配置成为孤岛）
home.file.".gitconfig".text = ''
  [user]
    name = Alice
    email = alice@example.com
  [init]
    defaultBranch = main
'';

# 写法二：programs.git（✅ 推荐：类型安全、与包联动）
programs.git = {
  enable = true;                 # 同时负责把 git 装进用户环境
  userName = "Alice";
  userEmail = "alice@example.com";
  extraConfig.init.defaultBranch = "main";   # 选项没覆盖的字段走 extraConfig
  delta.enable = true;           # 子模块：顺手把 delta 也配好
};
```

`programs.*` 的覆盖面在官方手册的 Appendix A（Configuration Options）逐项列出，常用的还有 `programs.zsh`、`programs.bash`、`programs.neovim`（乃至完整插件管理）、`programs.firefox`、`programs.ssh`、`programs.gpg`、`programs.tmux`。每个模块的共同结构是：`enable` 负责「装包 + 写配置」的联动，其余选项负责配置内容，`extraConfig`/`settings` 兜底任意字段。

shell 是一个值得单说的例子：`programs.zsh.enable = true` 在 NixOS 模块模式下还会与系统的 `users.users.alice.shell = pkgs.zsh;` 联动，history、补全、插件（`programs.zsh.plugins` 直接给出插件列表，自动从包里接线）全部声明化，`~/.zshrc` 从此变成 store 里的只读产物。

### 45.4.4 systemd.user：用户级服务

```nix
{ ... }: {
  # 用户登录后由 systemd --user 管理（第 29 章的用户侧对应物）
  systemd.user.services.syncthing-tray = {
    Unit.Description = "Syncthing 托盘";
    Service.ExecStart = "${pkgs.syncthing-tray}/bin/syncthingtray";
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
```

与 NixOS 模块的 `systemd.services.*` 语法一致（第 29 章），只是生命周期挂到用户会话而非系统启动。典型用途：gpg-agent、ssh-agent、壁纸切换器、同步工具。

## 45.5 激活、generation 与回滚

`home-manager switch` 的完整流程，逐条对应第 26–27 章讲的 NixOS 机制：

1. **求值**：Nix 语言求值 `home.nix`（+ 所有 import 的模块），得到一份完整的用户环境描述；
2. **构建**：产出 activation 包——一个含全部文件、包依赖与激活脚本的 store 路径；
3. **激活**：运行 activation 脚本，把 `~/.zshrc` 等 symlink 指向新 store 路径，加载新的用户 profile；
4. **登记**：新 generation 记入 `~/.local/state/nix/profiles/` 下的 profile 链（第 18 章的 generation 机制）。

正因为有第 4 步，回滚是免费的：

```console
$ home-manager generations        # 列出全部代际
2026-08-16 10:12 : id 42 : /nix/store/...-home-manager-generation
2026-08-15 22:04 : id 41 : /nix/store/...-home-manager-generation
$ /nix/store/...-home-manager-generation/activate   # 激活任意旧代际即回滚
```

两个实用细节：

- **与系统回滚的配合**：NixOS 模块模式下，用户环境是系统 closure 的一部分，`nixos-rebuild switch --rollback` 会把用户环境一起带回旧代际；独立模式下两者各自回滚，需要分别执行。这是 45.3.1 表里「原子性」一行的具体含义。
- **旧代际的寿命**：home-manager generation 是 gcroot（第 19 章），不会被垃圾回收误删；但 `nix-collect-garbage -d`（注意 `-d`）会删掉旧 profile 代际，回滚窗口随之消失——与第 19、27 章讨论系统代际时的警告完全一致。

## 45.6 常见坑

### 45.6.1 与 nix-env / nix profile 混用

第 18 章埋过伏笔：`nix-env -iA` 与 `nix profile install` 装的东西走的是**另一个 profile**，home-manager 既不认识也不会接管它们。混用的典型症状是「同一程序两个版本、PATH 里时隐时现」。迁移的正确姿势见 45.7；在此之前，把一条原则贴在显示器上：**用了 home-manager 的用户，不要再碰 nix-env/nix profile 装包**。

### 45.6.2 useGlobalPkgs 与 useUserPackages

第 44 章模板里出现过的两个开关，含义常被问：

- `home-manager.useGlobalPkgs = true`：home-manager 内部求值时复用系统传入的 `pkgs`，不再自己 `import nixpkgs {}`。不开的后果是两套 pkgs 树并存——闭包体积、版本漂移、overlay 不生效（第 39 章的 overlay 只挂在系统那套上）。**默认应开**；
- `home-manager.useUserPackages = true`：`home.packages` 装进**用户 profile**（`~/.local/state/nix/profiles/profile`，可随用户单独回滚），而非系统环境。**默认应开**，它也让 home-manager 的卸载更干净（`home-manager uninstall`）。

### 45.6.3 版本错位：release 分支不匹配

home-manager 的 release 分支必须与 nixpkgs 大版本配对：`release-26.05` 配 `nixos-26.05`，追 unstable 就都用 unstable。错位的症状不一定在求值期暴露，而可能在激活期以莫名其妙的 option 缺失、脚本失败出现——因为 home-manager 的激活脚本依赖特定 nixpkgs 内部接口。channel 世界同理（45.3.3）。报错里出现「unknown option」而你确认文档里有这个选项时，第一件事就是检查两侧版本。

### 45.6.4 用户名对不上

`home-manager.users.alice` 里的 `alice` 必须与 `users.users.<名字>` 完全一致。模块模式下写错用户名不会报错——只是安静地给一个不存在的用户建了环境，登录后什么都没发生。独立模式下则要留意 flake 的 `homeConfigurations."alice"` 与 `home-manager switch --flake .#alice` 引用的名字匹配（必要时含 `@hostname` 后缀）。

### 45.6.5 既有文件挡路

激活时若 `~/.zshrc` 已存在且不是 symlink，home-manager 会拒绝覆盖并报错（防止吞掉你手写的配置）。正确处理：确认内容不再需要后移走（或纳入 git），再重新 switch；想一步到位也可以加 `-b bak` 让它把冲突文件自动改名备份（`home-manager switch -b bak`）。**不要**用 `home.file.<name>.force = true` 静默覆盖，除非你明确知道自己在覆盖什么。

### 45.6.6 infinite recursion

第 25 章讲过的 `infinite recursion encountered` 在 home-manager 里的高发场景：在 `programs.zsh.initExtra` 之类的字符串里引用了 `config.home.sessionVariables`，而该变量又依赖 zsh 模块的输出——读与写在求值图上成环。解法与第 25/46 章一致：`--show-trace` 定位环节点，把读取改为读取更上游的 `let` 绑定，或拆开「谁生产、谁消费」。

## 45.7 迁移实战：从旧世界搬进来

把一个存量用户环境迁到 home-manager，推荐按「先冻结、再替换、后清理」三步走。以下清单可直接当 checklist 用：

**第一步：盘点现状**

```console
$ nix-env -q                       # nix-env 装了什么（第 18 章）
$ nix profile list                 # 新 CLI profile 装了什么
$ ls -A ~ | head -30               # $HOME 顶层有哪些 dotfiles
$ git -C ~/dotfiles log --oneline -5   # 旧 dotfiles 仓库的最近同步点
```

**第二步：搬包与搬配置**

- 把 `nix-env -q` / `nix profile list` 的清单逐项转成 `home.packages = [ pkgs.foo ... ];`；
- 把 dotfiles 逐个搬成 `programs.*`（优先）或 `home.file.*`（兜底）。搬的时候**通读一遍旧配置**，顺手删掉失效项——迁移是清理欠债的最佳时机；
- shell 相关（别名、环境变量）放 `programs.zsh.shellAliases`、`home.sessionVariables`（注意后者写入 `~/.home-manager/session-vars`，需要在 shell rc 里 source 一次，模块模式下 `programs.zsh.enable` 会自动接好这行）。

**第三步：切换与清理**

```console
$ nix-env -e '*'                   # 清空旧 nix-env profile（内容已进 home.packages）
$ nix profile wipe-history         # 新 CLI 的对应清理
$ home-manager switch              # 或 nixos-rebuild switch（模块模式）
```

清理旧 profile 是必要的：不清掉，两套环境继续并存，45.6.1 的幽灵问题就永远阴魂不散。

**dotfiles 仓库的最终形态**：迁移完成后，旧 dotfiles 仓库的价值只剩历史考据——`home/` 目录本身就是新的 dotfiles（第 44 章的仓库结构里它已经就位）。跨机器同步的单位从「一堆 rc 文件」升级为「一个 flake 仓库 + 一份 flake.lock」。

## 45.8 本章小结

- home-manager 补上 NixOS 之外的最后一块空白：用户级包、dotfiles、用户服务的声明式管理，以及用户环境的原子切换与回滚；
- 心智模型是「单用户版 mini-NixOS」：模块系统（第 25 章）、激活脚本（第 26 章）、generation profile（第 18 章）三层机制原样重演，对象从 `/etc`/`/run` 换成 `$HOME`；
- 两种模式按「是否全套 NixOS」选择：个人 NixOS 机器用模块模式（与 nixos-rebuild 一起原子切换），非 NixOS 或无 root 场景用独立模式；`home.nix` 本身两种模式下完全相同；
- 配置分四层：`home.packages` 管包、`home.file` 兜底摆文件、`programs.*` 是带类型与联动的首选、`systemd.user.*` 管用户服务；
- 回滚靠用户级 generation：`home-manager generations` 列出，激活旧代际即回滚；`nix-collect-garbage -d` 会同时删掉回滚窗口；
- 高频坑：与 nix-env/nix profile 混用、release 分支与 nixpkgs 版本错位、用户名对不上、既有文件挡路、`initExtra` 里读 `config` 成环；
- 迁移三步走：盘点（nix-env -q / nix profile list）→ 搬运（转 home.packages 与 programs.*）→ 清理（清空旧 profile），旧 dotfiles 仓库由 flake 仓库取代。

## 延伸阅读

- home-manager 官方手册 —— https://nix-community.github.io/home-manager/ ：安装、选项说明与 Appendix A 全部配置选项，本章所有选项以该手册当前版本为准；
- home-manager 仓库 —— https://github.com/nix-community/home-manager ：源码即文档，`modules/programs/` 下每个程序一个模块，是学习模块写法（第 25、43 章）的绝佳范本；
- NixOS Wiki: Home Manager —— https://wiki.nixos.org/wiki/Home_Manager ：社区维护的安装方式对比与常见问题；
- nix.dev「Declarative and reproducible environments」 —— https://nix.dev/ ：官方教程中对用户环境声明式的定位，可与本章交叉印证。
