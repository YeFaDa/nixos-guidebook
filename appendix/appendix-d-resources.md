# 附录 D：学习资源索引

> 精选而非罗列：每条说明它是什么、适合什么阶段。中文资源单列一节。所有链接以 2026-08 可访问为准。

## D.1 官方文档（第一梯队）

| 资源 | 链接 | 说明 |
|------|------|------|
| NixOS 官网 | https://nixos.org | 门户：下载、文档、社区入口 |
| Nix 手册 | https://nixos.org/manual/nix/stable | 包管理器权威文档：语言、store、命令 |
| Nix 语言手册 | https://nixos.org/manual/nix/stable/language | 语言规范（附录 A 的来源） |
| Nixpkgs 手册 | https://nixos.org/manual/nixpkgs/unstable | 打包者必读：stdenv、builder、贡献指南 |
| NixOS 手册 | https://nixos.org/manual/nixos/stable | 发行版手册：安装、配置、服务选项 |
| nix.dev | https://nix.dev | 官方教程站：结构化入门路径 |
| 官方 Wiki | https://wiki.nixos.org | 2024 年复活的官方 wiki（下面 D.1.1 有辨析） |
| 选项/包检索 | https://search.nixos.org | 查选项与包的第一入口 |
| 渠道状态 | https://status.nixos.org | unstable/stable 通道健康度 |
| Hydra | https://hydra.nixos.org | 官方构建农场：追踪某个包的构建 |
| GitHub org | https://github.com/NixOS | nix、nixpkgs、rfcs 仓库所在 |
| RFC 仓库 | https://github.com/NixOS/rfcs | 设计决策的一手现场 |

### D.1.1 Wiki 辨析（避坑必读）

- **wiki.nixos.org**：官方 wiki，2024 年复活，内容较新但仍在补全——✅ 优先。
- **nixos.wiki（非官方）**：历史上长期是唯一 wiki，搜索结果里大量出现——⚠️ 部分页面陈旧（channel 时代写法），核对「最后修改时间」再信。
- 两者对同一主题可能都有页面：以官方版与手册为准。

## D.2 经典教程

- **Nix Pills**（https://nixos.org/guides/nix-pills/）：从零徒手写 derivation 的系列短文，理解机制的最佳材料。读完第 13-17 章后再读，会有「互文」的快感。
- **Zero to Nix**（https://zero-to-nix.com）：Determinate Systems 出品的现代教程（厂商背景，技术内容可靠， flakes 优先视角）。
- **nix.dev tutorials**（https://nix.dev/tutorials）：官方教程集，含「Nix 语言」互动教程与最佳实践。

## D.3 英文书籍

- **《Nix in Action》**（Manning）：面向工程实践的系统教程（以出版社页面确认版本状态）。
- **《NixOS in Production》**：生产环境运维视角（以出版社页面为准）。
- 学位论文：Dolstra《The Purely Functional Software Deployment Model》（2006，免费）——思想源头（第 2 章）。

## D.4 中文资源

| 资源 | 位置 | 说明 |
|------|------|------|
| 《NixOS & Flakes 新手入门》 | https://github.com/ryan4yin/nixos-and-flakes-book | 中文社区最流行的入门书，flakes 视角，配套作者 dotfiles 仓库；有在线版 |
| nixos-cn 社区 | https://github.com/nixos-cn | 中文社区仓库：入门材料、flake 模板、交流入口 |
| Discourse 中文分类 | https://discourse.nixos.org | 官方论坛有中文板块，检索历史问答 |
| 本手册 | — | 你正在读的这本书 😄 |

⚠️ 中文资料时效提示：早期中文教程多为 channel+`nix-env` 风格（第 18 章 ⚠️ 过渡机制）；判断标准——示例是否使用 `flake.nix`/`nixos-rebuild --flake`/SRI 哈希。本书附录 A.8 的新旧对照表可作翻译词典。

## D.5 社区与求助

- **Discourse 论坛**（https://discourse.nixos.org）：最重要的问题沉淀地，搜到老帖常常直接解决你的问题。
- **Matrix/Discord**：官方实时频道，入口见 https://nixos.org/community（以官网为准）。
- **GitHub Discussions/Issues**：nixpkgs 的 bug 与特性讨论。
- **NixCon 演讲**（YouTube 搜索 NixCon）：年度大会录像，深度机制的讲座宝库。

## D.6 工具生态速览

| 工具 | 用途 | 仓库 |
|------|------|------|
| Home Manager | 用户环境声明式管理 | github.com/nix-community/home-manager |
| disko | 声明式磁盘分区 | github.com/nix-community/disko |
| nixos-anywhere | 零接触远程装机 | github.com/nix-community/nixos-anywhere |
| deploy-rs | flake 部署（magic rollback） | github.com/serokell/deploy-rs |
| colmena | 类 Ansible 的 NixOS 部署 | github.com/zhaofengli/colmena |
| sops-nix / agenix | 秘密管理 | github.com/Mic92/sops-nix · github.com/ryantm/agenix |
| impermanence | 无状态系统 | github.com/nix-community/impermanence |
| Cachix / Attic / Harmonia | 二进制缓存 | cachix.org · github.com/zhaofengli/attic · github.com/nix-community/harmonia |
| flake-utils / flake-parts | flake 辅助库 | github.com/numtide/flake-utils · github.com/hercules-ci/flake-parts |
| pre-commit-hooks.nix | 代码检查集成 | github.com/cachix/pre-commit-hooks.nix |
| nixd / nil | 语言服务器 | github.com/nix-community/nixd · github.com/oxalica/nil |
| nixfmt / alejandra | 格式化 | github.com/NixOS/nixfmt · github.com/kamadorueda/alejandra |
| deadnix / statix | 静态检查 | github.com/hauleth/deadnix? （nix-community）· github.com/nerdypepper/statix |
| nixpkgs-review | 审 PR | github.com/Mic92/nixpkgs-review |
| nix-diff / nix-tree / nvd | 差异与观测 | github.com/thoughtpolice/nix-diff? （grahamc）· github.com/utdemir/nix-tree · github.com/flyingcircle/nvd |

（个别仓库 owner 如有迁移，以搜索结果为准。）

## D.7 版本时间线简表

| 时间 | 事件 |
|------|------|
| 2003 | 乌得勒支大学项目启动 |
| 2004 | ICSE 论文（部署=内存管理） |
| 2006 | Dolstra 博士论文；6 月 NixOS 原型 |
| 2007-2010 | Hydra 问世；nixpkgs 成形 |
| 2013-12 | 首个稳定版 13.10 "Aardvark" |
| 2015 | NixOS 基金会成立 |
| 2018 | Nix 2.0（新 CLI）；Cachix 上线 |
| 2021 | Nix 2.4（Flakes 试水）；Determinate 成立 |
| 2024 | 治理危机与改革；Lix/Tvix 崛起；官方 wiki 复活 |
| 2026-05 | NixOS 26.05 "Yarara"（当前稳定版） |
| 2026-06 | Nix 2.35（当前稳定版） |

详见第 2 章（Nix 诞生）、第 3 章（生态史）、第 22 章（NixOS 史）。

## D.8 学习路径建议（配合本书）

1. **第 1 周**：第 1-5 章 + 装 NixOS（第 24 章跟随）+ 把玩 `nix repl`（第 6 章）。
2. **第 2-3 周**：第 13-21 章机制 + 第 24 章把自己的机器配置迁移进 git。
3. **第 2 个月**：第 36-38 章实例 + 第 42 章实战，给 nixpkgs 提第一个 PR。
4. **持续**：第 25 章重读（每次都有新收获）、第 43 章写自己的模块、附录 A/B 当工具书。
