# 附录 B：常用命令参考

> 按使用场景分组的命令手册（Nix 2.35 / NixOS 26.05 基准，2026-08）。✅ 新命令为主，遗留命令单列一节（读懂旧教程与旧脚本必需）。命令细节以 `nix help <子命令>` 与官方手册为准。

## B.1 nix 新 CLI（按子命令）

### 构建与运行

```console
$ nix build nixpkgs#hello              # 构建并链接到 ./result
$ nix build .#myapp                     # 当前 flake 的包
$ nix build github:NixOS/nixpkgs/nixos-26.05#ripgrep   # 直接远程引用（无本地仓库）
$ nix run nixpkgs#hello                 # 构建并运行（不装）
$ nix run github:yang991178/flakelite# # 示例形态：run 一个 flake 的默认 app
$ nix build --print-build-logs .#x      # -L：实时日志
$ nix build --rebuild --dry-run?        # 相关：nix build --dry-run 显示将要构建/下载什么
```

### 开发环境

```console
$ nix develop                           # 进入 flake 的 devShell
$ nix develop nixpkgs#hello             # 进包的构建环境（排错利器，第 42 章）
$ nix develop -c make test              # 进环境并执行单条命令
$ nix shell nixpkgs#ripgrep nixpkgs#jq  # 临时把包注入当前 shell（一次性）
$ nix shell nixpkgs#hello -c hello      # 注入后执行单命令
```

### 包管理（用户 profile）

```console
$ nix profile install nixpkgs#ripgrep
$ nix profile list                       # 已安装清单
$ nix profile upgrade ripgrep            # 升级（按 flake ref 重求值）
$ nix profile rollback                   # 回滚上一代
$ nix profile history                    # 各代变更史
$ nix profile wipe-history && nix profile gc?  # 清历史/清不可达
```

### store 与信息查询

```console
$ nix path-info nixpkgs#hello           # 路径
$ nix path-info -r nixpkgs#firefox      # 闭包清单（-r 递归）
$ nix path-info -rSh nixpkgs#firefox    # -S 闭包大小 -h 人类可读
$ nix derivation show nixpkgs#hello     # .drv 的 JSON 视图（第 13 章）
$ nix derivation show /nix/store/*.drv  # 已有 .drv
$ nix log /nix/store/xxx-hello-2.12.3   # 取构建日志
$ nix log nixpkgs#hello                  # 按包取（失败排查）
$ nix store gc                           # 垃圾回收（第 19 章）
$ nix store optimise                     # 硬链接去重
$ nix store verify --all --verify-contents?  # 完整性检查（较慢）
$ nix copy --to ssh://server /nix/store/xxx  # 搬运闭包（部署基石，第 17/31 章）
$ nix search nixpkgs "fuzzy finder"     # 搜索包（可加 -u unstable）
```

### 求值与 REPL

```console
$ nix eval nixpkgs#hello.version        # 求值任意属性
$ nix eval --raw nixpkgs#hello.name
$ nix eval --json .#nixosConfigurations.myhost.config.services.nginx.port
$ nix eval --show-trace .#x             # 求值错误带全堆栈（排错必开，第 45 章）
$ nix repl                               # 交互求值：:t 类型 / :p 完整打印 / :lf 载入 flake / :q 退出
```

### flake

```console
$ nix flake init                         # 生成模板 flake.nix
$ nix flake new myproj -t templates#...  # 从模板建项目
$ nix flake show                         # 列出 flake 的全部输出
$ nix flake check                        # 检查（格式/构建/测试）
$ nix flake metadata                     # 输入清单与锁定状态
$ nix flake update                       # 更新全部输入锁
$ nix flake update nixpkgs               # 只更新一个输入（新旧语法并存，以手册为准）
$ nix flake lock --update-input nixpkgs  # 旧式单输入更新（⚠️ 过渡期兼容）
$ nix flake archive                      # 把 flake 源树存入 store（复现用）
```

## B.2 遗留命令（读旧教程/旧脚本必备）

```console
$ nix-build '<nixpkgs>' -A hello        # ≈ nix build nixpkgs#hello（产 ./result）
$ nix-build default.nix                  # 直接求值文件
$ nix-build -K                           # --keep-failed 保留失败现场（调试）
$ nix-shell '<nixpkgs>' -A hello        # ≈ nix develop nixpkgs#hello
$ nix-shell -p ripgrep jq                # ≈ nix shell nixpkgs#ripgrep nixpkgs#jq
$ nix-shell --run "make test"            # 进环境执行
$ nix-env -iA nixpkgs.hello              # ≈ nix profile install nixpkgs#hello
$ nix-env -q                             # 已装列表；-q --installed / -qa 可用包
$ nix-env -e hello                       # 卸载
$ nix-env -u '*'                         # 全升级
$ nix-env --list-generations / --rollback / --switch-generation 42
$ nix-channel --list / --add URL 名字 / --remove 名字 / --update
$ nix-instantiate --eval -E '1 + 1'      # ≈ nix eval --expr
$ nix-instantiate default.nix            # 只求值出 .drv（不构建）
$ nix-copy-closure --to server /nix/store/xxx  # ≈ nix copy --to ssh://server
$ nix-store -q --references 路径         # 直接引用
$ nix-store -qR 路径                      # 闭包（--requisites）
$ nix-store -q --referrers 路径          # 谁引用它（一层）
$ nix-store -q --referrers-closure 路径  # 反向闭包（删东西前必看）
$ nix-store -q --deriver 路径            # 产出它的 .drv
$ nix-store --gc --print-roots           # 列 GC roots（第 19 章）
$ nix-store --verify --check-contents    # 内容校验
$ nix-collect-garbage -d                 # 删旧代并回收（NixOS 系统代同理，第 19 章）
```

## B.3 NixOS 专属

```console
# 重建四动作 + 变体（第 24/27 章）
$ sudo nixos-rebuild switch              # 激活+注册新代
$ sudo nixos-rebuild boot                # 只备好下一代（重启生效）
$ sudo nixos-rebuild test                # 激活但不注册（重启回旧代）
$ sudo nixos-rebuild dry-activate        # 彩排（打印不执行）
$ sudo nixos-rebuild switch --upgrade    # 先更新 channel 再切（channel 世界）
$ sudo nixos-rebuild switch --flake .#myhost      # flake 世界（.# 可省主机名则取当前）
$ sudo nixos-rebuild switch --flake . --target-host root@srv1  # 远程部署（第 31 章）
$ sudo nixos-rebuild switch --rollback   # 回滚上一代
$ sudo nixos-rebuild list-generations
$ sudo nixos-rebuild delete-generations old   # 按策略删旧代（配合 GC）
$ sudo nixos-rebuild build-vm            # 生成可跑的 VM 脚本（./result/bin/run-vm-*)
$ nixos-option services.nginx.enable     # 查询选项：值/默认/定义处（第 25 章）
$ nixos-version                          # 版本串（含代与 git 短哈希）
$ sudo nixos-enter                       # live/维护环境进入本机系统（第 28 章）
$ sudo nixos-install --flake .#myhost    # 安装到挂载的目标根（第 31 章）
$ sudo nixos-generate-config --root /mnt # 生成 hardware-configuration.nix
```

## B.4 Home Manager

```console
$ home-manager switch                    # channel 世界
$ home-manager switch --flake .#alice@hostname   # flake 世界
$ nix run home-manager -- switch --flake .#alice # 免安装调用（GitHub: nix-community/home-manager）
$ home-manager generations               # 代清单
$ home-manager build                     # 只构建不切换
```

## B.5 诊断与观测

```console
$ nix path-info -rS /run/current-system | sort -k2 -n | tail   # 系统闭包大头
$ du -sh /nix/store; ncdu /nix/store     # 空间观测（ncdu 需安装）
$ nix-diff /nix/store/a.drv /nix/store/b.drv   # 两个 .drv 差在哪（nixpkgs#nix-diff）
$ nix-tree $(realpath $(which hello))    # 交互式闭包浏览（nixpkgs#nix-tree）
$ nvd diff /nix/var/nix/profiles/system-117-link /nix/var/nix/profiles/system-118-link  # 代间包变化
$ nix flake metadata --json | jq '.locks'  # 锁定状态机器可读
$ nix hash path ./src; nix hash file x.tar.gz; nix hash convert --to sri <hash>  # 第 15 章
$ nix-store -q --referrers-closure /nix/store/xxx  # 「删它之前谁还在用」（第 19 章）
```

## B.6 常见任务配方

```console
# ① 这个程序运行时到底依赖什么？
$ nix path-info -r $(readlink -f $(which hello))

# ② 为什么这个包要重新构建？（谁动了它的输入）
$ nix build --dry-run nixpkgs#hello 2>&1   # 列出将建/将下的清单
$ nix-diff <旧.drv> <新.drv>

# ③ 清理磁盘到只剩最近 5 代
$ sudo nixos-rebuild delete-generations old? （或：nix-env -p /nix/var/nix/profiles/system --delete-generations 5）
$ sudo nix-collect-garbage -d

# ④ 把我的环境完整搬到另一台机器
$ nix copy --to ssh://newhost $(readlink -f ~/.nix-profile)   # 用户环境闭包
$ nix copy --to ssh://newhost /run/current-system             # 整个系统闭包（服务器）

# ⑤ 对比「上一个系统代」与「当前代」的包差异
$ nvd diff /nix/var/nix/profiles/system-{117,118}-link

# ⑥ 临时用另一个版本的 nixpkgs 跑命令（不污染任何配置）
$ nix run github:NixOS/nixpkgs/nixos-25.11#hello -- --version

# ⑦ 从缓存重新拉回被 GC 掉的产物（只要 .drv 还能求值出来）
$ nix build nixpkgs#hello   # 缓存命中即自动补齐
```

## B.7 延伸阅读

- 新 CLI 全索引：https://nixos.org/manual/nix/stable/command/new-cli/nix
- NixOS 管理：https://nixos.org/manual/nixos/stable/#sec-changing-config
- 第 45 章的排错场景大量使用本附录命令。
