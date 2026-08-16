# 附录 C：中英术语对照表

> 全书术语集中对照，每条一句话定义。按主题分组；括号内为主要讲解章节。

## C.1 核心概念

| 英文 | 中译 | 一句话定义 |
|------|------|-----------|
| derivation | 派生 | 一次构建的全部输入清单，构建的原子单位（13） |
| `.drv` | 施工单文件 | 派生在 store 中的 ATerm 格式表示（13） |
| store path | store 路径 | /nix/store 下以哈希命名的产物路径（14） |
| output | 输出 | 一个派生的产物（out/dev/man...），各占一个路径（13/34） |
| closure | 闭包 | 一个对象运行所需的全部依赖集合（17） |
| references | 引用 | 构建后扫描登记的「本产物依赖哪些路径」（13/14） |
| referrers | 反向引用 | 「谁依赖本产物」（19） |
| substituter | 替代者/二进制缓存源 | 按派生哈希提供预构建产物的服务（20） |
| profile | 用户环境 | 「当前装了什么」的 store 对象（18） |
| generation | 代 | profile 或系统的历史快照，回滚单位（18/27） |
| channel | 通道 | channel 时代的 nixpkgs 订阅机制（18） |
| GC root | 垃圾回收根 | 保护对象不被回收的注册链接（19） |
| NAR | NAR 归档 | store 对象的规范归档格式，缓存传输单位（20） |
| narinfo | 缓存元数据 | 二进制缓存里描述产物哈希/引用/签名的文件（20） |
| fixed-output derivation | 固定输出派生 | 预声明输出哈希、唯一可联网的派生（15） |
| content-addressed derivation | 内容寻址派生 | 路径由输出内容决定的派生（实验）（15） |
| input-addressed | 输入寻址 | 路径由输入哈希决定的默认模型（15） |
| purity / impurity | 纯/不纯 | 结果只依赖显式输入与否（4/16） |
| evaluation | 求值 | 把 Nix 表达式算成值（图纸阶段）（6） |
| build / realisation | 构建/实现 | 照施工单施工产出 store 对象（16） |
| substitution | 替代下载 | 从缓存取产物代替本地构建（20） |
| string context | 字符串上下文 | 字符串携带的 store 路径记录（9） |
| sandbox | 沙箱 | 构建隔离环境：私有文件系统+断网（16） |
| lazy evaluation | 惰性求值 | 按需计算的表达式求值模型（11） |
| fixed point | 不动点 | 自引用结构的数学基础 lib.fix（7/25/32） |

## C.2 工具与设施

| 英文 | 中译 | 一句话定义 |
|------|------|-----------|
| Hydra | — | nixpkgs 官方构建农场与 CI（3/41） |
| ofBorg | — | GitHub PR 自动求值/构建机器人（41/42） |
| Cachix | — | 托管二进制缓存服务（SaaS）（20） |
| Attic / Harmonia | — | 开源自托管缓存服务（20） |
| nixpkgs-review | — | 本地构建 PR 受影响包的工具（41） |
| nixfmt / alejandra | 格式化器 | Nix 代码格式化（nixfmt 为 nixpkgs 官方）（12） |
| statix / deadnix | 静态检查 | 反模式与未用绑定检查（12） |
| patchelf | — | 修改 ELF 的 RPATH/interpreter 等的工具（17/33） |
| nixd / nil | LSP | Nix 语言服务器（12/45） |
| Nix Pills | — | 经典徒手教学系列（13） |
| nix.dev | — | 官方教程站（附录 D） |
| Lix | — | 社区 fork 的 Nix 实现，重错误信息（3） |
| Tvix | — | TVL 的 Rust 重写 Nix 实现（3） |
| Determinate Systems | — | Nix 生态商业公司（安装器/FlakeHub）（3） |

## C.3 NixOS

| 英文 | 中译 | 一句话定义 |
|------|------|-----------|
| module | 模块 | options+config 的配置单元（25） |
| option | 选项 | 模块对外暴露的声明式参数（25） |
| configuration.nix | 主配置文件 | 传统入口配置文件（24） |
| hardware-configuration.nix | 硬件配置 | 安装器生成的文件系统/硬件声明（24） |
| activation script | 激活脚本 | 把系统闭包落实为机器状态的片段（26） |
| switch-to-configuration | 切换脚本 | 单元 diff+切代+菜单更新的执行者（27） |
| specialisation | 特化 | 同代系统内预置的变体（27） |
| nixos-rebuild | 重建命令 | rebuild 四动作的入口（24/27） |
| generation（系统） | 系统代 | 整机级快照，boot 菜单项（18/27/28） |
| initrd | 初始内存盘 | stage 1 的迷你根，负责挂真根（28） |
| stage 1 / stage 2 | 启动两阶段 | initrd 与系统初始化（28） |
| systemd unit | systemd 单元 | 服务/计时器等的标准描述（29） |
| systemd-boot / GRUB | 引导器 | UFI/BIOS 引导加载程序（28） |
| tmpfiles | 临时文件规则 | 声明式创建运行时目录（26/29） |
| wrappers（setuid） | 特权包装器 | /run/wrappers 下的 setuid 通道（26） |
| mutableUsers | 可变用户开关 | 是否允许本地改账户库（26/30） |
| impermanence | 无状态化 | 「重置一切、显式保留」的管理思想（30） |
| sops-nix / agenix | 密钥管理 | 加密秘密进配置、运行期解密（30） |
| disko | 声明式分区 | 用 Nix 描述并执行磁盘分区（31） |
| nixos-anywhere | 远程装机 | SSH+kexec 的零接触安装（31） |
| deploy-rs / colmena | 部署工具 | flake 化多机部署（31） |
| Home Manager | 用户环境管理 | 声明式管理用户级配置（24/30） |
| NixOS test | VM 测试 | python 驱动的系统级测试框架（41） |
| nixosSystem | 系统求值入口 | flake 里组装一台机器的函数（21/25） |

## C.4 打包（nixpkgs）

| 英文 | 中译 | 一句话定义 |
|------|------|-----------|
| nixpkgs | — | 包+发行版的单巨仓库（32） |
| by-name | 新包目录约定 | pkgs/by-name/xx/名字/package.nix（32） |
| all-packages.nix | 总目录 | 旧式包注册表（32） |
| callPackage | 注入调用 | 按形参自动供依赖的调用约定（32） |
| stdenv | 标准构建环境 | 工具链+phases 框架+工厂（33） |
| setup.sh | 构建框架脚本 | stdenv 的 builder 主体（33） |
| phase | 阶段 | unpack/patch/configure...（33） |
| hook | 钩子 | 满足条件自动生效的扩展（33） |
| builder | 构建器 | 语言生态的预配置构建器（35） |
| mkDerivation | 派生工厂 | 参数化的 derivation 生成器（34） |
| finalAttrs | 最终属性集 | override 后仍一致的自引用模式（7/34） |
| nativeBuildInputs | 构建期依赖 | 构建时「执行」的依赖（34） |
| buildInputs | 目标依赖 | 「链接/包含」进产物的依赖（34） |
| propagated inputs | 传递依赖 | 下游隐式获得的依赖（34） |
| strictDeps | 严格依赖 | 关闭依赖泄漏的开关（34） |
| __structuredAttrs | 结构化参数 | 参数以 JSON 传递（34） |
| placeholder | 占位符 | 构建前引用输出路径（34） |
| multiple outputs | 多输出 | out/dev/man 拆分（13/34） |
| override / overrideAttrs | 覆盖 | 求值层定制包的两把刀（39） |
| overlay | 叠加层 | final:prev 的全局包定制（39） |
| makeScope | 作用域工厂 | 语言包集合的组织器（39） |
| splicing | 拼接 | 交叉时双包集合的缝合机制（40） |
| build / host / target platform | 三平台 | 编译的三元组角色（40） |
| pkgsCross / pkgsStatic / pkgsMusl | 平台变体 | 交叉/静态/musl 的包集合入口（40） |
| fetcher | 取源器 | fetchurl/fetchFromGitHub 等（15） |
| vendorHash / cargoHash / npmDepsHash | 依赖锁哈希 | 语言依赖树哈希（37/42） |
| meta | 元数据 | license/maintainers/platforms（34/36） |
| maintainer | 维护者 | 对包负责的名单成员（36/42） |
| passthru | 旁路属性 | 不进构建的附加属性（34） |
| passthru.tests | 附加测试 | Hydra 会构建的包级测试（41） |
| staging | staging 分支 | 大量重建的缓冲分支（32/42） |
| mass-rebuild | 大规模重建 | 触碰基础包引发的连锁重建（32） |
| r13y | 可复现性检查 | reproducibility 检查任务（41） |
| autoPatchelfHook | 自动补丁钩子 | 预编译二进制的依赖修补（35） |
| makeWrapper / wrapProgram | 包装器 | 给程序注入 PATH/环境的胶布（35） |
| versionCheckHook | 版本检查钩子 | installCheck 校验 --version（36） |
| testers | 测试器集 | testVersion 等通用测试（41） |

## C.5 Flakes

| 英文 | 中译 | 一句话定义 |
|------|------|-----------|
| flake | 雪花/项目单元 | flake.nix+lock 的可复现项目（21） |
| flake.lock | 锁文件 | 输入的精确版本记录（21） |
| input | 输入 | flake 声明的依赖（21） |
| output | 输出 | packages/nixosConfigurations 等约定属性（21） |
| follows | 跟随 | 一个输入复用另一个输入的锁定（21/44） |
| flake registry | 注册表 | 便捷名到 URL 的映射（21） |
| git tree dirty | 脏树 | 未提交改动导致的警告/差异（21/45） |
| pure evaluation | 纯求值 | 禁环境访问的求值模式（11/21） |

## C.6 社区与历史

| 英文 | 中译 | 一句话定义 |
|------|------|-----------|
| NixOS Foundation | NixOS 基金会 | 2015 年成立的荷兰非营利，持有基础设施（3/22） |
| NixCon | 年会 | 2014 年起的社区大会（3） |
| RFC | 征求意见稿 | nixpkgs/rfcs 的技术决策流程（3/32） |
| Dolstra / Utrecht | — | 创始人与发源大学（2） |
| Stratego/XT | — | 催生 Nix 的程序变换工具链（2） |
| GNU Guix | — | 受 Nix 启发的姊妹项目（GPL，Guile） |

## C.7 延伸阅读

- 各术语的章节号即最佳详解位置；本表配合第 5 章概念地图使用。
