# 《Nix 与 NixOS 中文手册》

> 一本全面、深入、以中文写就的 Nix / NixOS / nixpkgs 参考书。
> 涵盖思想源流、历史沿革、语言规范、构建机制、操作系统原理与真实打包实例。

## 本书定位

网络上关于 Nix 生态的优质资料几乎全部是英文：官方手册、NixOS Wiki、nix.dev 教程、nixpkgs 源码注释……
这为中文用户设下了太高的门槛。本书的目标是把这套知识体系**完整地翻译成中文并重新组织**：
不仅讲"怎么做"，更讲"为什么这么设计"，并配以 nixpkgs 仓库中的**真实打包源码逐行注释精讲**。

## 读者对象

- 想系统学习 Nix/NixOS 的中文用户（从零开始）
- 已有一定 Linux 使用经验、被"依赖地狱"折磨过的开发者
- 想给 nixpkgs 贡献包、或在自己公司内部使用 Nix 的工程师
- 对函数式思想在系统软件领域落地感兴趣的研究者

## 全书结构

### 第一部分：思想与历史（第 1–5 章）
1. [软件部署的问题——为什么需要 Nix](chapters/ch01-why-nix.md)
2. [Nix 的诞生——Dolstra 论文与乌得勒支](chapters/ch02-birth-of-nix.md)
3. [Nix 生态发展史（2003–2026）](chapters/ch03-history.md)
4. [声明式与纯函数式包管理思想](chapters/ch04-philosophy.md)
5. [核心概念地图：一图看懂 Nix 世界](chapters/ch05-concept-map.md)

### 第二部分：Nix 语言（第 6–12 章）
6. [Nix 语言基础：值、类型与表达式](chapters/ch06-language-basics.md)
7. [函数：lambda、多参数与柯里化](chapters/ch07-functions.md)
8. [let、with 与作用域规则](chapters/ch08-scope.md)
9. [字符串：深入字符串上下文与模板](chapters/ch09-strings.md)
10. [属性集：Nix 世界的中心数据结构](chapters/ch10-attrsets.md)
11. [惰性求值：Nix 的执行模型](chapters/ch11-laziness.md)
12. [惯用法：写出地道的 Nix 代码](chapters/ch12-idioms.md)

### 第三部分：Nix 包管理器机制（第 13–21 章）
13. [派生（Derivation）：构建的原子](chapters/ch13-derivation.md)
14. [存储模型：/nix/store 的设计](chapters/ch14-store.md)
15. [哈希、固定输出与内容寻址](chapters/ch15-hashes.md)
16. [构建过程：沙箱、钩子与复现](chapters/ch16-build.md)
17. [闭包：依赖的完整图谱](chapters/ch17-closure.md)
18. [Profile、channel 与 generation](chapters/ch18-profiles.md)
19. [垃圾回收：gcroots 与安全删除](chapters/ch19-gc.md)
20. [二进制缓存与 substituter 生态](chapters/ch20-binary-cache.md)
21. [Flakes：新一代 Nix 工作流](chapters/ch21-flakes.md)

### 第四部分：NixOS（第 22–31 章）
22. [NixOS 的起源与发展](chapters/ch22-nixos-history.md)
23. [从包到操作系统：NixOS 的构建哲学](chapters/ch23-from-packages-to-os.md)
24. [configuration.nix 全面精讲](chapters/ch24-configuration-nix.md)
25. [模块系统深度剖析](chapters/ch25-module-system.md)
26. [激活机制：activation scripts](chapters/ch26-activation.md)
27. [switch-to-configuration：系统切换的内部](chapters/ch27-switch.md)
28. [启动流程：从 bootloader 到登录提示符](chapters/ch28-boot.md)
29. [systemd 集成](chapters/ch29-systemd.md)
30. [用户、状态与"无状态"哲学](chapters/ch30-state.md)
31. [部署工具生态](chapters/ch31-deploy.md)

### 第五部分：nixpkgs 与打包（第 32–41 章）
32. [nixpkgs 仓库全景与组织思想](chapters/ch32-nixpkgs-overview.md)
33. [stdenv：标准构建环境](chapters/ch33-stdenv.md)
34. [mkDerivation 逐行剖析](chapters/ch34-mkderivation.md)
35. [打包方式总览：全部 builder 分类详解](chapters/ch35-builders-overview.md)
36. [简单包实例精讲（逐行注释）](chapters/ch36-simple-packages.md)
37. [中等包实例精讲（逐行注释）](chapters/ch37-medium-packages.md)
38. [复杂包实例精讲（逐行注释）](chapters/ch38-complex-packages.md)
39. [override 与 overlay：定制一切](chapters/ch39-overrides.md)
40. [交叉编译](chapters/ch40-cross.md)
41. [测试与持续集成](chapters/ch41-ci.md)

### 第六部分：实战（第 42–46 章）
42. [从零打包一个软件：完整实战](chapters/ch42-package-walkthrough.md)
43. [编写自己的 NixOS 模块](chapters/ch43-module-walkthrough.md)
44. [Flake 应用开发模板](chapters/ch44-flake-templates.md)
45. [用户环境与 home-manager](chapters/ch45-home-manager.md)
46. [常见问题与排错手册](chapters/ch46-troubleshooting.md)

### 附录
- [附录 A：Nix 语言速查表](appendix/appendix-a-cheatsheet.md)
- [附录 B：常用命令参考](appendix/appendix-b-commands.md)
- [附录 C：中英术语对照表](appendix/appendix-c-glossary.md)
- [附录 D：学习资源索引](appendix/appendix-d-resources.md)

## 完成状态与统计（2026-08-16）

全书已完成：**46 章 + 4 个附录**，共 52 个文件。

- 总计约 **16,070 行 / 54.7 万字符**（其中中文正文约 14.9 万字，其余为代码与英文术语）；
- 按中文技术书籍常规排版（每页约 800–1000 字符）估算，约 **550–680 页**，满足「不少于 500 页」的目标；
- 打包实例章（36–38）采用 nixpkgs master 分支 2026-08 的**真实源码逐行注释**（hello、figlet、fzf、ripgrep、requests 为完整逐字源码；linux 内核与 firefox 为结构精讲）；
- 语言与打包章节全程标注 **✅ 现行规范 / ⚠️ 过渡机制 / ⛔ 已弃用写法**（finalAttrs、SRI 哈希、nixfmt-rfc-style、flakes 新命令等）。

### 导出 PDF

```bash
nix shell nixpkgs#pandoc nixpkgs#texliveFull   # 或自行安装 pandoc + xelatex
bash build/build-pdf.sh                        # 产出 build/Nix与NixOS中文手册.pdf
```

## 约定

- 本书中命令行示例以 `$` 开头表示普通用户命令，`#` 开头表示 root 命令。
- 涉及真实 nixpkgs 源码的章节，文件路径均标注仓库内相对路径，代码逐行（逐块）注释。
- 版本说明：以 2026 年 8 月的 NixOS 26.05（Yarara）/ Nix 2.35（含 Lix、Determinate 等实现）为准，机制层面的内容对所有现代版本通用。

## 阅读建议

- **入门路线**：第 1 → 4 → 5 → 6 → 13 → 14 章，然后直接安装 NixOS 边用边读第四部分。
- **打包贡献路线**：第 4 → 6–12（语言）→ 32–38（nixpkgs 与实例）→ 42（实战）。
- **深度理解路线**：按顺序通读，重点精读第 25（模块系统）与 34（mkDerivation）两章。

## 来源与版权声明

本书为个人学习笔记性质的整理汇编，内容参考并整理自 Nix / NixOS 官方手册、NixOS Wiki、nix.dev、nixpkgs 源码及社区公开资料（正文中尽可能标注了来源），仅供学习与研究参考，不作商业用途。书中引用的 nixpkgs 源码版权归其贡献者所有（MIT 许可证）。如有侵权或来源标注遗漏，请提 issue 或联系作者，将及时处理。在未补充正式许可证之前，本书内容默认保留所有权利，请勿整体转载。
