# 第 5 章 核心概念地图：一图看懂 Nix 世界

> **本章导读**：前四章建立了「为什么」，后面三十几章展开「怎么做」。中间放一张地图：Nix 世界的全部核心概念、它们的关系、每个概念的一句话定义与详解章节号。初次阅读可以只看图和表，之后随时回来查路。

## 5.1 全景图：从源码到运行中的操作系统

```
你的配置仓库                    nixpkgs 仓库
┌──────────────────┐          ┌─────────────────────────────┐
│ flake.nix        │          │ pkgs/by-name/**/package.nix │ ← 10万+ 包定义
│ flake.lock ──────┼──锁定──→ │ modules/nixos/**            │ ← NixOS 模块
│ hosts/*.nix      │          │ lib/  stdenv/  build-support│
└────────┬─────────┘          └──────────────┬──────────────┘
         │                                   │
         └──────────── 求值（Nix 语言，惰性）┘
                          │
                          ▼
              ┌───────────────────────────┐
              │  派生 derivation（.drv）   │  ← 构建的原子单位 [ch13]
              │  = 完整输入清单的纯描述    │
              └─────────────┬─────────────┘
                            │  构建（沙箱，无网络）[ch16]
                            │  或 从二进制缓存下载 [ch20]
                            ▼
              ┌───────────────────────────┐
              │  /nix/store/<哈希>-<名字>  │  ← 不可变产物 [ch14]
              │  （对象间的引用构成闭包）   │  ← 运行时完整依赖 [ch17]
              └─────────────┬─────────────┘
                            │  组装
              ┌─────────────┴──────────────┐
              ▼                            ▼
     ┌────────────────┐           ┌────────────────┐
     │ 用户环境        │           │ 系统闭包        │
     │ profile [ch18] │           │ system [ch23]  │
     │ （nix profile） │           │ （NixOS 整机）  │
     └────────────────┘           └───────┬────────┘
                                          │ 激活 [ch26/27]
                                          ▼
                                   运行中的 NixOS
                              （generation，可回滚 [ch18]）
```

## 5.2 概念速查表

按「构建流水线」顺序排列。右列为详解章节。

| 概念 | 一句话定义 | 章节 |
|------|-----------|------|
| **Nix 语言** | 描述构建组合的惰性纯函数式 DSL | 6-12 |
| **求值 vs 构建** | 先把表达式算成描述（求值），再照描述施工（构建） | 6 |
| **派生 derivation** | 一次构建的全部输入（源码、脚本、依赖、环境）的清单 | 13 |
| **store** | 存放全部不可变产物的目录（/nix/store） | 14 |
| **store 路径哈希** | 由全部输入算出的指纹，路径即身份 | 14-15 |
| **fixed-output derivation** | 输出哈希预先声明的特例（fetchers），唯一可联网的构建 | 15 |
| **沙箱** | 构建隔离环境：私有文件系统视图、无网络 | 16 |
| **闭包 closure** | 一个对象运行所需的全部依赖（引用的传递闭包） | 17 |
| **profile** | 用户「当前安装了什么」的 store 对象 | 18 |
| **generation** | profile 的历史快照，回滚的单位 | 18 |
| **channel** | channel 时代的 nixpkgs 订阅机制（flakes 前身） | 18 |
| **GC / gcroot** | 只删「不可达」对象；可达性由 GC root 定义 | 19 |
| **二进制缓存 substituter** | 按派生哈希复用他人构建产物的服务 | 20 |
| **flake** | 带 flake.nix + flake.lock 的可复现项目单元 | 21 |
| **NixOS 模块** | options（接口）+ config（实现）的配置单元 | 25 |
| **activation script** | rebuild 时把「系统闭包」落为真实状态的脚本 | 26 |
| **switch-to-configuration** | 切换系统代：diff systemd 单元并 reload/restart | 27 |
| **generation（系统级）** | 开机菜单里可选的「整套旧系统」 | 18/27 |
| **stdenv** | 标准构建环境：phases、hooks、依赖注入 | 33 |
| **mkDerivation** | stdenv 的派生工厂，绝大多数包的入口 | 34 |
| **builder** | 语言生态专用构建器（buildGoModule 等） | 35 |
| **callPackage** | 按函数形参自动注入依赖的调用约定 | 32 |
| **override / overlay** | 不改仓库源码的求值层定制 | 39 |
| **交叉编译** | build/host/target 三平台分离的构建 | 40 |

## 5.3 三个最易混淆的概念对

**profile vs generation**：profile 是「当前生效的那份环境」（一个符号链接）；generation 是 profile 的历史版本（profile-42-link 这样的兄弟链接）。回滚 = 把 profile 链接切到旧 generation。

**channel vs flake**：两者都是「你的配置引用哪个 nixpkgs 快照」的答案。channel 是全局环境变量式的订阅（机器上所有命令共享、随 update 漂移）；flake 是项目级锁定（每个项目一个 flake.lock，进 git，永不漂移）。心智模型：**channel 像「系统源」，flake 像「git 依赖」**（第 18、21 章）。

**derivation vs store path**：derivation（.drv）是**配方**（要怎么构建）；store path（/nix/store/...-hello-2.12.3）是**产物**（构建出来/下载下来的东西）。一个 .drv 可能有多个输出（out、dev、man...），每个输出一个 store 路径（第 13、34 章）。

## 5.4 两条命令的世界对照

同一个任务，两个时代的写法。全书机制章会同时给出两套，但**新项目一律推荐左列（flakes）**：

| 任务 | 传统（channel 时代）⚠️ | 现代（flakes 时代）✅ |
|------|------------------------|----------------------|
| 构建一个包 | `nix-build '<nixpkgs>' -A hello` | `nix build nixpkgs#hello` |
| 进开发环境 | `nix-shell '<nixpkgs>' -A hello` | `nix develop nixpkgs#hello` |
| 临时运行 | `$(nix-build '<nixpkgs>' -A hello)/bin/hello` | `nix run nixpkgs#hello` |
| 进入 shell 环境 | `nix-shell -p ripgrep` | `nix shell nixpkgs#ripgrep` |
| 搜索 | `nix search nixpkgs hello` | 同左 |
| 安装到 profile | `nix-env -iA nixpkgs.hello` | `nix profile install nixpkgs#hello` |
| 重建系统 | `nixos-rebuild switch --upgrade` | `nixos-rebuild switch --flake .#myhost` |

## 5.5 三条阅读路线

**入门路线（边用边学）**：第 6 章（语言基础）→ 第 13、14 章（派生与 store 直觉）→ 直接跳第 24 章（configuration.nix）把系统用起来 → 遇到概念疑问回到第 17-21 章。约两周后按目录补全。

**打包贡献路线**：第 7、8、10 章（语言核心）→ 第 32、33、34 章（nixpkgs 与 stdenv）→ 第 36、37、38 章（三档实例精讲）→ 第 42 章（实战）→ 提交你的第一个 PR。

**深度理解路线**：按顺序通读；重点精读第 25 章（模块系统）与第 34 章（mkDerivation）——这两章是 Nix 与 NixOS 各自的「心脏手术」级内容。

## 5.6 本章小结

- 全景流水线：配置 →（求值）→ 派生 →（构建/下载）→ store 对象 →（组装）→ profile / 系统闭包 →（激活）→ 运行中的系统。
- 概念速查表覆盖全书 20+ 核心术语，是后续阅读的「路牌」。
- 三对易混概念：profile/generation、channel/flake、derivation/store path。
- 新旧命令两套世界并存，新项目选 flakes 路线。

## 延伸阅读

- nix.dev 的概念图解（官方入门材料）：https://nix.dev/concepts
- 后续各章开头的「本章导读」都会回扣这张地图的位置。
