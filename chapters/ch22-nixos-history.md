# 第 22 章 NixOS 的起源与发展

> **本章导读**：第 2、3 章讲了 Nix 包管理器的来历，本章专门讲发行版：为什么有了 Nix 还要造一个操作系统？Armijn Hemel 的硕士论文原型做了什么？NixOS 如何从 alpha 走到 26.05？它与其他发行版的本质区别在哪？第 23 章起将深入「整机即派生」的机制，本章先把历史与定位讲清。

## 22.1 动机：包管理器管不到的另一半系统

2006 年的 Nix 已经能可靠地构建、安装、回滚软件包，但一台「机器」远不止用户态软件：

- `/etc` 里的配置决定软件如何运行；
- 系统服务（daemon）的启动顺序与依赖；
- 内核与初始内存盘（initrd）；
- 用户与组；
- 引导加载程序（bootloader）。

用传统思路管这些，等于把「声明式、可回滚的包」放进一个「命令式、不可回滚的系统」里——依赖地狱只是从应用层挪到了系统层。NixOS 的动机由此而来：**把 Nix 的不可变、声明式模型贯彻到整台机器**。配置文件、服务单元、用户、内核全部成为派生（第 13 章）的输出，「整机」成为一个可构建、可版本化、可回滚的对象。

## 22.2 2006：Armijn Hemel的原型

同年（2006 年）6 月，乌得勒支的另一名学生 **Armijn Hemel** 在硕士论文中交付了 NixOS 原型：一个用 Nix 原语组装出的最小 GNU/Linux 系统。原型回答了三个关键问题：

1. **「系统」如何成为 store 对象**——内核、initrd、init 脚本、一套基础包，统一构建进一个 `system` 派生，开机时由 bootloader 指向它；
2. **配置如何声明式化**——一份 Nix 表达式描述整台机器（`configuration.nix` 的雏形）；
3. **切换如何发生**——生成「新系统」→ 调用切换脚本激活 → 注册为新的系统代（generation），旧代保留可回滚。

这三板斧至今没有变过——你在 2026 年的 NixOS 上敲 `nixos-rebuild switch`，走的仍是同一条逻辑链（第 26、27 章逐环拆解）。

## 22.3 2008-2010：论文定调

Dolstra 与（后来加入的）Armijn Hemel 等合著的论文 **《NixOS: A Purely Functional Linux Distribution》**（2008 年发表、2010 年扩充）是发行版的「宪法」。核心贡献是把整机构建形式化为：

```
system = build(configuration)        # 一台机器 = 配置的纯函数
配置 = 各模块声明的合并结果          # 模块系统（第 25 章）的雏形
系统切换 = 原子地改变 bootloader 指向 + 激活脚本
```

论文还给出了评估：NixOS 用适度的磁盘与构建开销，换得了传统发行版无法提供的原子升级、回滚与「配置即系统」能力。此后学术界的一系列延伸（Disnix 的服务部署、NixOps 的云部署）都基于这个地基。

## 22.4 早期工程史：init 系统的两次换心

发行版的「服务管理」是最能看出工程演进的切口：

- **SysV init 时代（2006-2011）**：早期 NixOS 生成传统 init 脚本，声明式外壳包着命令式内核，痛点明显（依赖顺序、崩溃恢复全靠脚本约定）。
- **Upstart 时代（2011-2013）**：短暂迁移到事件驱动的 Upstart，改善有限。
- **systemd 时代（2013 至今）**：NixOS 成为**最早全面转向 systemd 的发行版之一**——比多数主流发行版更早、更彻底。原因并非赶时髦：systemd 的单元文件本质是**声明式的期望状态**（「我要一个这样的服务」），与 NixOS 的模型严丝合缝；socket 激活、cgroup 管理、tmpfiles 等设施直接消化进了模块系统（第 29 章详讲）。这次换心让 `services.*` 选项的表达力上了一个台阶。

## 22.5 版本史：从 0.1 到 26.05

- **2007-2013（pre-stable）**：0.1 到 0.2pre 系列的 alpha 版本，版本号零散；社区规模从个位数到数百贡献者。
- **2013-12-01：首个稳定版 13.10 "Aardvark"**。采用 `YY.MM` 版本号；代号从此按字母序选动物。
- **2015**：NixOS 基金会成立（第 3 章）；发布节奏稳定为每年 5 月、11 月两版，每版支持约 7 个月。
- **2018-2021**：生态工具（Home Manager、Cachix、nix.dev）成熟；flakes 出现后 `nixos-rebuild --flake` 成为现代工作流。
- **2024-2025**：治理危机与改革（第 3 章）；systemd in initrd（`boot.initrd.systemd.enable`）从实验走向可用；新模块大量涌现。
- **2026-05-30：26.05 "Yarara"**（当前稳定版，支持至 2026-12-31）；25.11 "Xantusia" 处于支持期尾部。

历代代号（字母序动物，完整年表含日期见附录 D）：

```
13.10 Aardvark → 14.04 Baboon → 14.12 Caterpillar → 15.09 Dingo →
16.03 Emu → 16.09 Flounder → 17.03 Gorilla → 17.09 Hummingbird →
18.03 Impala → 18.09 Jellyfish → 19.03 Koi → 19.09 Loris →
20.03 Markhor → 20.09 Nightingale → 21.05 Okapi → 21.11 Porcupine →
22.05 Quokka → 22.11 Raccoon → 23.05 Stoat → 23.11 Tapir →
24.05 Uakari → 24.11 Vicuña → 25.05 Warbler → 25.11 Xantusia → 26.05 Yarara
```

**stable 与 unstable 的双轨**：`nixos-26.05` 稳定通道只收错误与安全修复；`nixos-unstable` 滚动跟随 nixpkgs master（由 Hydra 构建闸门保证可启动性，第 41 章）。桌面与个人机常用 unstable（软件新），生产常用 stable（变化少）——选择权在 channel/flake 引用上（第 18、21 章）。

## 22.6 NixOS 与传统发行版的本质区别

| 维度 | 传统发行版（Debian/Fedora/Arch） | NixOS |
|------|----------------------------------|-------|
| 系统状态 | 命令历史的累积 | 一份配置的求值结果 |
| 配置文件 | 手工编辑 /etc | 声明生成（改了会被覆盖，第 26 章） |
| 升级 | 原地替换 | 构建新系统代 + 原子切换 |
| 回滚 | 无（或另装工具） | 开机菜单选旧代（内建） |
| 多版本共存 | 系统级无 | 全系统粒度 |
| 内核/驱动/服务 | 混合源码与二进制 | 全部派生化 |
| 复现一台机器 | 重装+脚本+运气 | git clone + nixos-rebuild |
| 学习曲线 | 温和 | 陡峭（先修 Nix 语言） |

也有 honest 的代价清单：闭源内核模块与深度依赖系统内部结构的软件（某些安全工具、旧驱动）更难打包；社区文档对新手不如 Debian 系成熟；出问题时的排错需要同时懂 Nix 与传统 Linux 机制（第 46 章就是为此准备的）。

## 22.7 社区、治理与生态位

- **治理**：NixOS 基金会（2015，荷兰非营利）持有基础设施与商标；技术决策经 RFC 流程（github.com/NixOS/rfcs）；2024 年改革后社区治理结构更加制度化（第 3 章）。
- **NixCon**：2014 年起的年度社区大会，演讲视频是深度学习材料（附录 D）。
- **生态位**：开发者工作站（可复现环境）、服务器/集群（配置即代码、原子部署）、嵌入式与安全敏感场景（可审计、法国政府 DINUM 的 Sécurix 项目即基于 NixOS）、CI 与构建农场（Hydra 本身运行在 NixOS 上）。

## 22.8 本章小结

- NixOS 的动机是把 Nix 模型贯彻到整机：配置、服务、用户、内核全部派生化。
- 2006 年 Armijn Hemel 的原型确定了沿用至今的三大机制：系统派生、声明式配置、原子代切换。
- init 系统历经 SysV → Upstart → systemd（2013）两次换心；systemd 的声明式单元与 NixOS 模型天然契合。
- 版本史：2013 年 13.10 首个稳定版；YY.MM 半年制；26 个动物代号；stable/unstable 双轨。
- 与传统发行版的差异本质在「状态的形式」；代价是学习曲线与部分软件的适配难度。

## 延伸阅读

- 论文《NixOS: A Purely Functional Linux Distribution》：https://edolstra.github.io/pubs/
- NixOS 历史页：https://wiki.nixos.org/wiki/History_of_Nix_and_NixOS
- 各版本发布说明：https://nixos.org/manual/nixos/stable/release-notes
- 下一章（第 23 章）拆解「整机即派生」的内部构造。
