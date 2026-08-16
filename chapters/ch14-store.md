# 第 14 章 存储模型：/nix/store 的设计

> **本章导读**：上一章的施工单产出的东西住在哪里？本章解剖 Nix 的「堆内存」——/nix/store：目录布局、路径命名规则、store 数据库、不变式（invariants）与安全模型，以及「多 store」抽象如何支撑远程与缓存。理解 store，你就理解了为什么 Nix 敢把整个操作系统都装进一个目录。

## 14.1 store 是 Nix 的「堆」

第 2 章提到，2004 年论文的核心抽象是「部署 = 内存管理」。把类比列全，store 的每个设计都找到了出处：

| 内存管理概念 | Nix 对应物 |
|--------------|-----------|
| 堆（heap） | /nix/store |
| 对象（object） | store 路径（一个构建产物） |
| 指针 | 路径引用（references） |
| 按内容寻址（interner） | 路径哈希 = 输入指纹 |
| GC root | /nix/var/nix/gcroots 里的链接 |
| 垃圾回收 | nix store gc（第 19 章） |
| 不可变性 | store 路径一旦注册，永不修改 |

## 14.2 目录布局

```
/nix
├── store/                        ← ★ 堆本体：全部不可变产物
│   ├── p7dg1vv0c5n...-hello-2.12.3/          目录型产物
│   ├── 1xaf0hd6kmg...-hello-2.12.3.tar.gz    文件型产物（fetcher 产物）
│   ├── 4wkn9akyq7c...-hello-2.12.3.drv       施工单（.drv 也是 store 对象！）
│   └── ...
└── var/nix/                      ← 元数据（可变部分全部集中于此）
    ├── db/                       ← SQLite 数据库：注册表（14.4 节）
    ├── profiles/                 ← 系统级 profile 与 generation 链
    │   ├── system -> system-117-link
    │   ├── system-116-link -> /nix/store/...（旧代）
    │   ├── system-117-link -> /nix/store/...（当前代）
    │   └── per-user/<uid>/       ← 每用户 profile
    ├── gcroots/                  ← GC 根：这里的链接保护对象不被回收
    │   ├── auto/（符号链 → 被保护路径）
    │   └── per-user/
    ├── daemon-socket/socket      ← Nix 守护进程的 Unix socket
    └── build-*/                  ← 构建临时目录（沙箱挂载点）

/run/current-system               ← NixOS 上：指向当前系统闭包的符号链
/etc/...                          ← 大多是符号链 → store 中的文件（第 26 章）
```

两条设计铁律把「可变」与「不可变」彻底隔离：

1. **/nix/store 只增不改**（16.5 节的唯一例外是修复性操作）；删除只由 GC 按可达性统一执行。
2. **一切可变状态（数据库、profile、锁、socket）都在 /nix/var**。备份与迁移时，store 可整体重建，var 需按语义处理。

## 14.3 路径命名规则：32 个字符的身份证

```
/nix/store/p7dg1vv0c5n7vx9cp2r4alla8c0sp0gl-hello-2.12.3
         └──────────┬──────────┘└────────┬────────┘
          32 字符 base32 哈希            名字（含版本）
```

- **哈希**：SHA-256 截断至 160 比特（20 字节），base32 编码得 32 字符。截断是为了路径长度与可读性；160 比特对抗碰撞在工程上足够。
- **哈希的输入**：对输入寻址派生，是「本派生的全部输入」（名字、构建器、依赖路径、环境变量……）；对固定输出派生（第 15 章），是声明的输出哈希。名字本身也是哈希输入的一部分——第 13 章实验里改名字路径就变的原理。
- **名字**：`<名字>-<版本>` 是 nixpkgs 约定（`pname` + `version` 拼接）；工具可用 `builtins.parseDrvName` 拆回两半。

为什么把哈希放路径而不是藏数据库里？三个理由：

1. **自描述**：不查任何数据库也能比对两个路径是否同一产物；
2. **同一性全局成立**：不同机器、不同用户的同一产物路径相同——缓存、复制、部署（第 17、20 章）的一切协议建立在字符串相等上；
3. **文件系统即索引**：存在性检查 = `stat`，无锁、无中心服务。

## 14.4 store 数据库：注册表与不变式

`/nix/var/nix/db` 是一个 SQLite 数据库，登记每个有效（valid）路径的元数据：

```sql
-- 概念性视图（真实 schema 更细，日常用不着直读）
PathTable:
  path        TEXT PRIMARY KEY,   -- /nix/store/...-hello-2.12.3
  deriver     TEXT,               -- 产生它的 .drv 路径
  hash        TEXT,               -- 内容哈希（NAR 哈希）
  references  TEXT                -- 它引用的路径列表（13.7 节扫描所得）
```

由此支撑的查询命令族：

```console
$ nix-store -q --references /nix/store/...-hello-2.12.3    # 直接引用
$ nix-store -q --requisites /nix/store/...-hello-2.12.3    # 闭包（-qR）
$ nix-store -q --referrers /nix/store/...-glibc-2.40        # 谁引用了它（反向）
$ nix-store -q --referrers-closure /nix/store/...-glibc-2.40  # 反向闭包
$ nix-store -q --deriver /nix/store/...-hello-2.12.3        # 生产者 .drv
```

**store 的不变式**（理解违规后果就能理解很多报错）：

1. 注册过的路径内容永不改变（只读挂载 + 只读权限位）；
2. 路径的引用集合登记后不变；
3. `.drv` 与输出路径的映射关系固定；
4. 删除只能通过 GC 整体进行，且必须保留全部「从 gcroot 可达」的路径。

手动 `rm -rf /nix/store/xxx` 会同时违反 1-4 条，后果是数据库与现实脱节——这是「⛔ 永远不要手动删 store 内容」禁令的完整原因（正确姿势见第 19 章）。

## 14.5 权限、只读与多用户模式

**单用户安装**（如 WSL、无 root 环境的临时使用）：store 归当前用户；⚠️ 无沙箱（构建隔离降级），复现性打折。

**多用户安装**（NixOS 与服务器默认，✅ 推荐）：`/nix/store` 由 root 持有、构建由 **nixbld1..nixbldN** 特权构建用户组执行、普通用户通过 `nix-daemon` 的 socket 委托操作。收益：

- 沙箱可靠（构建用户无权限写 store 以外任何地方）；
- 多用户共享同一 store 与缓存；
- `trusted-users` 列表控制谁能让 daemon 构建任意派生（安全边界，第 20 章）。

NixOS 上另有 `nix.readOnlyStore = true`（默认）把 store 以只读挂载，从内核层面锁死不变式。

## 14.6 硬链接去重：auto-optimise-store

store 里大量文件内容重复（同一份 libc 出现在无数个闭包的视图里）。开启优化后：

```nix
# NixOS configuration.nix
nix.settings.auto-optimise-store = true;   # ✅ 推荐：相同内容硬链接合并
```

相同内容的 inode 被硬链接合并，`du -sh /nix/store` 显著下降且不损语义（对使用者完全透明）。`nix store optimise` 可手动触发一次全量优化。代价是首次优化耗时（遍历比对哈希）。

## 14.7 store 抽象：local 之外的世界

现代 Nix 把「store」抽象成可插拔后端（`nix copy` 在其间搬运，第 17、20 章）：

| Store URI | 用途 |
|-----------|------|
| （默认）本地 daemon store | 本机 /nix/store |
| `file:///path` / `local` | 直接读写一个本地目录（无 daemon） |
| `ssh://user@host` | 远程机器的 store（部署基石） |
| `s3://bucket?...` | S3 对象存储（自建缓存） |
| `https://cache.example.org` | 只读二进制缓存（substituter 的本质） |

「同一产物路径全局同一」的设计在这里兑现：任何后端间的复制都以路径哈希为准绳，无需信任传输过程（校验签名与哈希，第 20 章）。这也是 NixOS 「把整个系统闭包 push 到服务器」部署模型的根基（第 31 章）。

## 14.8 观测实践：把 store 玩成工具箱

```console
# 我这台机器的 store 多大？谁是大头？
$ du -sh /nix/store
$ nix path-info -rS /run/current-system | sort -nk2 | tail   # 系统闭包里最大的产物

# 某程序为什么能用？它到底依赖了什么？
$ nix path-info -r $(which hello)

# 两个包共用多少内容？
$ nix path-info -r nixpkgs#hello | sort > /tmp/h
$ nix path-info -r nixpkgs#ripgrep | sort > /tmp/r
$ comm -12 /tmp/h /tmp/r | wc -l

# store 健康检查（NixOS）
# nix-store --verify --check-contents   # ⚠️ 全量校验，较慢，但排查"store 损坏"必杀
```

## 14.9 本章小结

- store 是 Nix 的堆：不可变产物 + 登记于 SQLite 的引用关系；可变状态全部隔离在 /nix/var。
- 路径 = 32 字符 base32（截断 SHA-256）+ 名字；「路径即身份」使一切跨机器协议退化为字符串相等。
- 四条不变式保证可推理性；手动删 store 是禁忌；GC 是唯一合法的清理方式。
- 多用户模式 + 只读挂载 + nixbld 构建用户构成安全模型；auto-optimise 用硬链接去重。
- store 是可插拔抽象：local/ssh/s3/https，支撑复制、缓存与部署。

## 延伸阅读

- Nix 手册 «Store» 一章（后端清单与配置）：https://nixos.org/manual/nix/stable/store/
- 第 17 章（闭包）、第 19 章（GC）、第 20 章（缓存）是本章的三条延伸线。
