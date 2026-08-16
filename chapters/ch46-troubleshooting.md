# 第 46 章 常见问题与排错手册

> **本章导读**：这是一本可以「从中间开始读」的手册。我们按求值期、构建期、系统运行、Flakes、环境与网络五个阶段归类，收录 28 个 Nix 与 NixOS 最高频的问题，每个都按「症状 → 根因 → 诊断 → 修复」四段展开，修复命令可直接复制粘贴。排错的总心法只有一句：**先读完整的报错**——Nix 的错误信息量很大，第一行告诉你哪一层失败，最后一行往往就是答案。

使用建议：遇到问题时按「你卡在哪个阶段」跳到对应小节；46.6 的调试工具箱总表值得先通读一遍，知道手里有哪些武器，遇到问题才知道派谁上场。

## 46.1 求值期错误

求值期（evaluation）错误发生在「Nix 读你的配置做计算」的阶段，还没开始任何构建。共同特征是报错里没有 builder、没有 exit code，只有 attribute、value 之类的字眼。

#### 问题 1：infinite recursion（无限递归）

- **症状**：

```
error: infinite recursion encountered
at /nix/store/…-source/modules/foo.nix:12:9
```

- **根因**：配置的求值形成了环——A 依赖 B、B 又依赖 A。五种最常见来源：① 选项默认值引用了自身或互相引用，如 `services.a.enable = mkDefault (config.services.b.enable);` 而 b 的默认值又反向引用 a；② 在模块里用 `config.…` 拼出「正在定义的那个值」，例如定义 `environment.variables.X` 时又去读它；③ **裸 if 替代 mkIf**：`config = if config.services.foo.enable then { … } else { … };`——if 的条件与分支都在求值期立即展开，强迫 Nix 在「还没算完」的状态下读结果；④ 模块互相 import 形成环；⑤ 顶层把 `config` 整体塞进某个选项，导致任何对该选项的读取都牵动整个 config 再求值。
- **诊断**：加 `--show-trace` 让 Nix 打印完整调用链，从栈里找「谁引用了谁」：

```console
# nixos-rebuild 原生支持 --show-trace（注意要放在子命令前）
$ nixos-rebuild build --show-trace --flake .#myhost

# 或用 nix eval 直接求值某个属性，定位到具体选项
$ nix eval --show-trace .#nixosConfigurations.myhost.config.services.foo.bar
```

- **修复**：按来源对号入座——③ 改成 `mkIf`（延迟合并，第 25 章）：`config = lib.mkIf config.services.foo.enable { … };`；① 拆掉互相引用，改成显式的公共变量（let 绑定）；② 让定义值只依赖输入而不是自身。

#### 问题 2：attribute missing（属性不存在）

- **症状**：

```
error: attribute 'realese' missing
at /nix/store/…-source/flake.nix:9:20
```

- **根因**：拼错属性名（本例 real→realese），或引用了不存在的层级——最典型的是忘了系统层：`inputs.foo.packages.default` 少写了 `.x86_64-linux`。
- **诊断**：在 nix repl 里逐层查看集合里到底有什么（`:p` 打印全量，`:t` 看类型）：

```console
$ nix repl
nix-repl> :lf .                       # 加载当前 flake
nix-repl> inputs.foo.packages <Tab>   # Tab 补全列出全部属性
nix-repl> inputs.foo.packages.x86_64-linux <Tab>
```

- **修复**：改正拼写或补全层级。若上游 flake 确实没有该输出，用 `nix flake show github:owner/repo` 先核对再写。

#### 问题 3：undefined variable（未定义变量）

- **症状**：

```
error: undefined variable 'lib'
at /nix/store/…-source/modules/my.nix:3:5
```

- **根因**：模块函数参数没声明就用了 `lib`（Nix 函数参数没有隐式注入）；或 flake 的 outputs 少解构了某个 input；或作用域里根本没有这个名（with pkgs 旧写法被移除后暴露的一批此类问题）。
- **诊断**：看报错行号，确认变量「应当从哪来」——模块参数、函数参数还是 import。
- **修复**：模块文件补参数并保持 `…` 通配以便后续注入：

```nix
# ✅ 模块标准头：声明会用到的参数，... 保留扩展位（第 25 章）
{ config, lib, pkgs, ... }:
{ }
```

flake 侧则补 outputs 解构：`outputs = { self, nixpkgs, ... }@inputs:`。

#### 问题 4：multiple definitions of option（选项多重定义）

- **症状**：

```
error: The option `networking.hostName' has multiple definitions.
First definition, at /etc/nixos/hosts/a.nix:3:5
Second definition, at /etc/nixos/hosts/b.nix:12:5
```

- **根因**：两个模块对同一个「不可合并」选项（字符串、整数等）都赋了值。hostName 这类标量选项没有合并语义，Nix 不知道听谁的（合并语义的细节见第 25 章）。
- **诊断**：报错直接给出两处定义位置；`nix eval` 可看当前生效值辅助判断哪边是想要的。
- **修复**：三选一——① 收敛到一处定义（最干净）；② 显式定优先级：

```nix
# mkDefault：降优先级（1000），别处有普通定义就让位
networking.hostName = lib.mkDefault "myhost";

# mkForce：升优先级（50），声明「这里说了算」
networking.hostName = lib.mkForce "myhost";
```

优先级数字越小越强：mkOptionDefault(1500) < 选项默认值 < mkDefault(1000) < 普通(100) < mkForce(50)；③ 用 mkIf 让冲突的两处互斥。

#### 问题 5：value is a set while a string was expected

- **症状**：

```
error: A definition for option `environment.variables.API_URL' is not of type `string'.
Value: { … }
```

或求值表达式时 `cannot coerce a set to a string: { type = "derivation"; … }`。
- **根因**：把集合（set）塞给了要字符串的位置。两种高频写法：把 derivation 直接内插进字符串（想写的其实是它的可执行文件路径）；把 `{ }` 值赋给标量选项。
- **诊断**：看报错的选项名/表达式位置，检查赋值右侧的类型。
- **修复**：对「包 → 可执行文件路径」用标准工具函数：

```nix
# ✅ lib.getExe：按 meta.mainProgram 取 $out/bin 下的可执行文件
environment.variables.EDITOR = lib.getExe pkgs.vim;

# ✅ 想要 store 输出路径本身时，用内置 toString（仅对含 outPath 的值成立）
environment.variables.MANPATH = toString pkgs.man-pages;
```

---

## 46.2 构建期错误

构建期错误发生在派生已经开跑之后，报错里通常有 builder、exit code 与日志行。

#### 问题 6：hash mismatch（哈希不匹配）详解

- **症状**：

```
error: hash mismatch in fixed-output derivation '/nix/store/…-source.drv':
         specified: sha256-11ZmSM3gqx1HOn1Kcjb9dNdVPSTnPP5x0c5MNcMPi98=
         got:       sha256-Kc4bT7…=
```

- **根因**：三类。① **上游真的变了**：同一 URL 指向的内容被替换（开发者重新打包了 release 附件、tarball 被覆盖）——这是最值得警惕的一类，因为说明你的供应链里出现了「同址不同物」；② **你的 fetcher 用错了**：把 fetchurl 的哈希填给了 fetchzip，或漏了 postFetch 处理（语义差异见第 15、42 章）；③ 复制粘贴串了行。
- **诊断**：先判断「谁对」。下载一份亲自校验：

```console
# 独立校验：下载后算 SRI 哈希，与报错两侧对比
$ nix store prefetch-file --hash-type sha256 <URL>
```

- **修复**：确认新哈希对应可信内容后，把 `got:` 回填（第 42 章的标准循环）。若是①，最好顺手检查上游公告，确认不是攻击者在替换产物。

#### 问题 7：fixed-output 回填后仍失败

- **症状**：哈希已按报错回填，再次构建却报新的 mismatch，或报 `got: sha256-0…`（空值哈希）。
- **根因**：回填进了错的地方（源码哈希填进了 vendorHash，或反之）；或 fetchzip/fetchurl 混用；或固定输出派生里的脚本改了内容（自定义 postFetch 改动后哈希必然变化）。
- **诊断**：`nix derivation show` 看清到底有几个固定输出派生、各自的输出是什么：

```console
$ nix derivation show .#gcat | grep -E 'name|hash'
```

- **修复**：逐个固定输出派生单独跑 prefetch 验证；改过 postFetch 就重新走假哈希循环拿新值。

#### 问题 8：找不到编译器或头文件

- **症状**：

```
> make: bison: No such file or directory
```
```
> src/greet.c:1:10: fatal error: 'glib.h': No such file or directory
```

- **根因**：依赖缺失。判定法（呼应第 34 章）：**构建期间在宿主侧运行的程序 → nativeBuildInputs；编译链接时吃进产物的库与头文件 → buildInputs**。bison/pkg-config/autoreconfHook 属于前者，glib/openssl/zlib 属于后者。
- **诊断**：在手动环境里验证缺谁（第 42.5 节的完整流程）：

```console
$ nix develop .#ghello    # 或 nix-shell -A ghello
[nix-shell]$ which bison
[nix-shell]$ echo $NIX_CFLAGS_COMPILE    # 看 include 搜索路径里有没有目标库
```

- **修复**：

```nix
nativeBuildInputs = [ bison pkg-config ];   # 工具类
buildInputs = [ glib ];                     # 库与头文件类
```

头文件场景注意：若库存在仍找不到，检查是否需要 `dev` 输出（stdenv 默认已自动选 dev，通常无需干预）。

#### 问题 9：pkg-config 找不到 .pc 文件

- **症状**：

```
Package 'glib-2.0' was not found in the pkg-config search path.
Perhaps you should add the directory containing `glib-2.0.pc'
to the PKG_CONFIG_PATH environment variable
```

- **根因**：库没进 buildInputs（stdenv 正是靠 buildInputs 自动拼 PKG_CONFIG_PATH，参见第 33 章），或探测工具 pkg-config 本身没装。
- **诊断**：开发环境里直接查：

```console
[nix-shell]$ pkg-config --modversion glib-2.0   # 复现问题
[nix-shell]$ echo $PKG_CONFIG_PATH              # 看搜索路径里有什么
```

- **修复**：库进 buildInputs、pkg-config 进 nativeBuildInputs，两条都要有。若 `.pc` 名带后缀版本（如 `lua5.2`），configureFlags 用准确名字：`configureFlags = [ "--with-lua=lua5.2" ];`。

#### 问题 10：沙箱内无网络

- **症状**：

```
> curl: (7) Couldn't connect to server
> make: *** [Makefile:21: fetch-data] Error 7
error: builder for '/nix/store/…-ghello-1.0.0.drv' failed with exit code 2
```

- **根因**：构建沙箱默认完全断网（第 16 章的设计决策：可复现性优先）。构建脚本里有任何「运行时拉取」动作都会撞墙。
- **诊断**：看日志定位到哪一步访问了网络；`nix derivation show` 确认该派生不是固定输出类型（普通派生必然无网）。
- **修复**：**把联网需求改造为 fetchers**——所有数据在构建前经 fetchurl/fetchgit/fetchFromGitHub 等固定输出派生取好放进 store（这是原则，不是技巧）。构建脚本改为读本地路径：

```nix
# ✅ 数据文件先取好，构建期只读本地
src = fetchurl { url = "…"; hash = "sha256-…"; };
dataFile = fetchurl { url = "…"; hash = "sha256-…"; };
postPatch = ''
  substituteInPlace Makefile --replace 'https://example.com/data.bin' '${dataFile}'
'';
```

⚠️ 不要试图关沙箱来绕过；确属例外场景（如包管理器自身）的沙箱配置以官方手册为准。

#### 问题 11：磁盘满导致 builder 失败

- **症状**：

```
error: writing to file '/nix/store/…/bin/tool': No space left on device
```

- **根因**：`/nix`（或构建暂存区所在文件系统）空间耗尽；也可能 `/tmp` 是 tmpfs 被超大构建撑爆。
- **诊断**：

```console
$ df -h /nix /tmp        # 看两处空间
$ du -sh ~/.cache/nix    # 顺带看下载缓存
```

- **修复**：清理后重试（GC 原理见第 19 章）：

```console
# 只回收无引用垃圾
$ nix store gc
# 更彻底：删掉旧 generation 再 GC（ ⚠️ 会失去旧系统回滚点）
$ sudo nix-collect-garbage -d
# 长效：NixOS 上声明定期 GC（第 19 章有完整策略讨论）
# nix.gc = { automatic = true; dates = "weekly"; options = "--delete-older-than 30d"; };
```

---

## 46.3 系统运行问题

这一节的问题发生在「系统已经装好、正在跑」的阶段。

#### 问题 12：rebuild 失败后回滚

- **症状**：`nixos-rebuild switch` 后系统异常——ssh 连不上、图形界面黑屏、某个关键服务挂了。
- **根因**：新 generation 的问题，不影响旧 generation 完好躺在 store 里（第 18、27 章的回滚机制）。
- **诊断**：能进系统就 `nixos-rebuild list-generations` 看序号；进不去就在引导菜单（GRUB/systemd-boot 的「NixOS - Configuration fallback」入口）里直接选上一个 generation 启动。
- **修复**：

```console
# 能进系统：一步回滚（激活上一个 generation）
$ sudo nixos-rebuild switch --rollback

# 引导菜单都不行时：live USB 救援（见问题 15 的完整流程）
```

#### 问题 13：改了配置没生效

- **症状**：明明改了配置文件、程序行为却纹丝不动。
- **根因**：四个高频原因——① 改完忘了 rebuild；② 用了 `dry-activate`/`dry-build` 只看了预览没真正激活（第 27 章讲过 dry 系列只打印差异）；③ rebuild 的是另一份配置（改的是 `~/my-config`，系统却从 `/etc/nixos` 构建，flake 路径指错）；④ 新文件没 `git add`，flake 根本没把它复制进求值（见问题 19）。
- **诊断**：

```console
# 确认当前系统指向的配置来源与时间
$ nixos-rebuild list-generations
# 预览差异：看这次 switch 到底会不会改你关心的东西
$ sudo nixos-rebuild dry-activate --flake .#myhost
```

- **修复**：对症——真正执行 `sudo nixos-rebuild test --flake /绝对路径/#myhost`（test 立即生效不写引导项，先用它验证再 switch）；确认编辑的就是启动用的仓库；`git status` 确认无未跟踪文件。

#### 问题 14：服务起不来

- **症状**：`systemctl status foo` 显示 failed 或 activating (auto-restart)，网站打不开。
- **根因**：程序自身崩溃、配置错误、单元类型不匹配（`Type=notify` 但程序不调用 sd_notify 会一直卡到超时）、依赖顺序错（没等数据库就启动）。
- **诊断**：三板斧（第 29 章有 systemd 详解）：

```console
$ systemctl status foo                 # 状态、PID、退出码
$ journalctl -u foo -b --no-pager      # 本次开机的完整日志（90% 答案在这）
$ systemctl cat foo                    # 实际生效的单元文件，与你的声明对照
```

- **修复**：按诊断结果修配置；类型不匹配时在 NixOS 侧改声明：

```nix
systemd.services.foo.serviceConfig = {
  Type = "simple";        # 程序不支持 notify 就别硬要
  # ExecStart 的路径写错也常在这里现形——systemctl cat 一眼可见
};
```

#### 问题 15：开机进 emergency mode

- **症状**：启动卡住，出现 `You are in emergency mode.` 的提示与维护 shell。
- **根因**：几乎总是 `fileSystems` 挂载失败——UUID 写错、分区没格式化、fscker 缺失、加密卷没配好。
- **诊断**：emergency shell 里看 journal：`journalctl -xb` 找 `Dependency failed for /…`。
- **修复**（live USB 完整救援流程，命令可直接照抄）：

```console
# —— 在 live USB 中以 root 操作 ——
$ sudo -i
# ① 确认分区与文件系统（找到根分区与 ESP 的真实设备名）
# lsblk -f
# ② 挂载根分区到 /mnt
# mount /dev/nvme0n1p2 /mnt
# ③ 挂载 EFI 分区（位置必须与配置里的 fileSystems 一致）
# mount /dev/nvme0n1p1 /mnt/boot
# ④ 有 swap 分区的话顺带 swapon，避免内存不足
# ⑤ 进入已安装的系统（自动 bind /nix/store、/dev、/proc、/sys）
# nixos-enter --root /mnt
# ⑥ 在旧系统环境里改配置并重建，或直接回滚：
# nixos-rebuild switch --flake /etc/nixos#myhost     # 需网络
# nixos-rebuild boot --rollback                      # 只修引导项，最稳妥
# exit
# umount -R /mnt
# reboot
```

若只是想先开机：emergency shell 里输 root 密码后 `journalctl -xb` 排查，`systemctl daemon-reload && exit` 有时可继续启动。

#### 问题 16：/nix/store 磁盘满（系统还能进）

- **症状**：`No space left on device` 频繁出现、rebuild 失败，但系统本身还能运行。
- **根因**：长期不 GC，旧 generation 与构建中间产物堆积（第 19 章专题）。
- **诊断**：

```console
$ df -h /nix
# 看有哪些 GC roots 钉住了垃圾（谁在引用谁）
$ nix-store --gc --print-roots | sort | head -30
```

- **修复**：分三步走，从保守到彻底：

```console
# ① 保守：只删构建缓存类垃圾，不动任何 generation
$ nix store gc
# ② 标准：删 30 天前的 generation 再 GC（保留近期回滚能力）
$ sudo nix-collect-garbage --delete-older-than 30d
# ③ 彻底（⚠️ 失去全部旧版本回滚点）
$ sudo nix-collect-garbage -d
```

#### 问题 17：/boot 空间不足

- **症状**：rebuild 报 `No space left on device`，且失败点在复制内核/initrd 到 `/boot` 时。
- **根因**：ESP 太小，而每个 generation 都要在 `/boot` 存一份内核与 initrd。
- **诊断**：`df -h /boot`；`ls /boot/loader/entries` 或 `ls /boot/kernels` 看历史条目数量。
- **修复**：清旧 generation 加上限额：

```console
# 清掉旧 generation（/boot 条目随之消失），再 GC 释放 store
$ sudo nix-collect-garbage --delete-older-than 14d
```

```nix
# 长效：限制保留的引导项数量（systemd-boot 与 GRUB 均支持）
boot.loader.systemd-boot.configurationLimit = 5;
boot.loader.grub.configurationLimit = 5;
```

#### 问题 18：error: file 'nixpkgs' was not found

- **症状**：

```
error: file 'nixpkgs' was not found in the Nix search path
```

- **根因**：两套世界打架（第 18、21 章）。命令用了 `<nixpkgs>` 尖括号语法（如 `nix-build '<nixpkgs>' -A hello`、某些脚本的 nix-shell），而你的机器只装了 flake 世界——没有安装 channel，`NIX_PATH` 里没有 nixpkgs 条目。
- **诊断**：`echo $NIX_PATH`（flakes 世界通常为空或缺失）。
- **修复**：改用 flake 语法是正道；确需兼容旧脚本时，显式桥接：

```console
# ✅ 现代：直接以 flake 引用（无需任何 channel）
$ nix build nixpkgs#hello
$ nix shell nixpkgs#hello
```

```nix
# 需要让 <nixpkgs> 继续可用的桥接（NixOS 上注册到 registry 与 NIX_PATH）
nix.registry.nixpkgs.flake = nixpkgs;                 # inputs.nixpkgs
nix.nixPath = [ "nixpkgs=${nixpkgs}" "flake:nixpkgs" ];  # ⚠️ 桥接用途，能删则删
```

⛔ 不建议再 `nix-channel --add` 安装 channel——那是被取代的旧世界。

---

## 46.4 Flakes 相关

#### 问题 19：flake.lock 不更新 / git tree is dirty

- **症状**：两种表现。其一：

```
warning: Git tree '/etc/nixos' is dirty
```
其二：新加的文件报 `error: … No such file or directory`，明明文件就在那里。
- **根因**：flake 从 git 仓库取文件时**只认已被 git 跟踪的文件**。新建的 `hosts/nas/configuration.nix` 没 `git add`，等于不存在——这就是「file not found」最常见根因。dirty 警告本身只是提示（未提交修改以临时快照参与求值），但它的存在说明你的求值内容没进版本控制。
- **诊断**：`git status`——重点看 Untracked files。
- **修复**：

```console
# 新文件立即纳入跟踪（内容仍可继续改）
$ git add hosts/nas/configuration.nix

# 让警告闭嘴且保证可复现：提交
$ git commit -am "hosts: add nas"
```

顺带一提 lock 不更新的另一种情况：见问题 22 的「更新后没提交 lock」。

#### 问题 20：flake does not provide attribute

- **症状**：

```
error: flake 'git+file:///etc/nixos' does not provide attribute
       'packages.x86_64-linux.foo', 'legacyPackages.x86_64-linux.foo' or 'foo'
```

- **根因**：outputs 结构写错或名字不匹配。高频形态：① 忘了按系统分层，`packages.foo = …` 而不是 `packages.x86_64-linux.foo`；② 拼写/大小写不一致；③ 引用了别的 flake 没有的输出（比如对方只有 legacyPackages 而你写 packages）。
- **诊断**：让 flake 自己告诉你有什么：

```console
$ nix flake show
```

- **修复**：对照 show 的结果修正引用或 outputs（44.3 节的 perSystem 模板可从根上避免①）。

#### 问题 21：experimental features 提示

- **症状**：

```
error: experimental Nix feature 'nix-command' is disabled; use '--extra-experimental-features nix-command' to try it out
```

- **根因**：`nix build` 这类新 CLI 与 flakes 默认未标「稳定」，需要显式开启。三层开关由临时到永久：
- **诊断与修复**（选一层）：

```console
# 第 1 层：单次命令（应急）
$ nix --option experimental-features "nix-command flakes" build .#foo
```

```bash
# 第 2 层：用户级/系统级 nix.conf（~/.config/nix/nix.conf 或 /etc/nix/nix.conf）
experimental-features = nix-command flakes
```

```nix
// 第 3 层：NixOS 声明式（推荐，随配置进版本库）
nix.settings.experimental-features = [ "nix-command" "flakes" ];
```

三层效力：命令行参数只管当次；nix.conf 管这台机器；NixOS 模块管「随配置重建的这台机器」——配置漂移最小。

#### 问题 22：更新了输入但构建仍用旧版本

- **症状**：`nix flake update` 跑了，构建结果却毫无变化。
- **根因**：① 更新只改了工作区的 flake.lock，但**忘了提交**，而 CI/别的机器读的是已提交版本；② 该输入被 `follows` 钉在别的输入上，更新它本身无效（要更新被跟随者）；③ 在错误目录跑了 update（更新了别的 flake 的 lock）。
- **诊断**：

```console
$ nix flake metadata           # 看各输入实际锁定的 commit 与时间
$ git diff flake.lock          # 确认 lock 变化是否已存在、是否已提交
```

- **修复**：提交 lock；follows 链条上找到源头更新；临时验证可用 `--override-input`（44.10 有示例）。

#### 问题 23：root 操作你的 git 仓库报 dubious ownership

- **症状**：

```
fatal: detected dubious ownership in repository at '/home/alice/my-config'
error: cannot fetch flake 'git+file:///home/alice/my-config'
```

- **根因**：`sudo nixos-rebuild --flake /home/alice/my-config#…` 时 root 读取属于 alice 的 git 仓库，git 的安全机制（safe.directory）拒绝。
- **诊断**：命令是否混用了 sudo 与他人拥有的仓库路径。
- **修复**：优先「不混用」——NixOS 上 wheel 组用户直接跑 `nixos-rebuild switch --flake .#myhost`，nixos-rebuild 自己会在需要的步骤提权（这也是推荐姿势）。确需 root 操作时：

```console
# 方案一：给 root 加白名单（对特定仓库放行）
$ sudo git config --global --add safe.directory /home/alice/my-config
# 方案二：改用 sudo 时以源仓库属主读取（约束更细，按需）
```

---

## 46.5 环境与网络

#### 问题 24：公司代理环境下无法下载

- **症状**：`nix build` 报连接超时/拒绝，但 `curl` 在 shell 里明明能走代理访问外网。
- **根因**：**Nix 守护进程（nix-daemon）不继承你 shell 里的代理环境变量**。下载是 daemon 干的，你在终端里 export 的 `http_proxy` 它看不见。
- **诊断**：`systemctl show nix-daemon -p Environment` 看 daemon 当前环境。
- **修复**：让代理配置作用到 daemon（NixOS 声明式与非 NixOS 两种写法）：

```nix
// NixOS：经 nix.envVars 注入 daemon 环境（第 24 章的配置文件风格）
nix.envVars = {
  http_proxy = "http://proxy.corp.example:3128";
  https_proxy = "http://proxy.corp.example:3128";
  no_proxy = "localhost,127.0.0.1,.corp.example";
};
# 改后需 systemctl restart nix-daemon（rebuild switch 会自动处理）
```

```ini
# 非 NixOS：systemd override（/etc/systemd/system/nix-daemon.service.d/override.conf）
[Service]
Environment="http_proxy=http://proxy.corp.example:3128"
Environment="https_proxy=http://proxy.corp.example:3128"
Environment="no_proxy=localhost,127.0.0.1,.corp.example"
```

```console
# 非 NixOS 应用 override 后：
# systemctl daemon-reload && systemctl restart nix-daemon
```

#### 问题 25：自签证书导致下载失败

- **症状**：

```
error: unable to download 'https://…': SSL certificate problem: self signed certificate in certificate chain (60)
```

- **根因**：公司网络做 TLS 拦截（中间人代理重签证书），Nix（以及它内置的 curl）不认你们的根证书。
- **诊断**：确认公司根 CA 文件路径（IT 部门提供，通常为 .pem/.crt）。
- **修复**：把根证书并入信任链并指给 Nix：

```nix
// NixOS：加入系统信任库（其他程序也一并受益），并显式告知 Nix
security.pki.certificateFiles = [ ./certs/corp-root.pem ];
nix.settings.ssl-cert-file = "/etc/ssl/certs/ca-certificates.crt";  # 重建后的合并包
```

```console
# 非 NixOS：环境变量指向包含公司根证书的 bundle（对 nix 命令行生效）
$ export NIX_SSL_CERT_FILE=/path/to/corp-bundle.pem
# daemon 侧同样要设：放进 46.5 问题 24 的 override.conf Environment= 即可
```

#### 问题 26：中文 locale 乱码

- **症状**：界面方块字、终端提示 `Locale not supported by C library`、日期格式错乱。
- **根因**：locale 未声明或字体缺失——NixOS 不预装任何 CJK 字体（无状态哲学的结果，参见第 24、30 章）。
- **诊断**：`locale` 看当前值是否有 `cannot set locale` 警告；`localectl status`。
- **修复**：

```nix
// NixOS：声明 locale 与 CJK 字体（第 24 章 i18n 一节的完整版）
i18n.defaultLocale = "zh_CN.UTF-8";
fonts.packages = with pkgs; [
  noto-fonts-cjk-sans       # 思源黑体系 CJK 无衬线字体
  noto-fonts-emoji          # 表情符号
];
```

改后 `sudo nixos-rebuild switch`，注销重登生效。

#### 问题 27：中文输入法不工作（排查清单）

- **症状**：切不出输入法、某些应用里输入法不生效、候选框不跟随。
- **根因**：输入法框架没启用、环境变量未传导到应用、或 addon 缺失。按清单逐项排查。
- **诊断与修复清单**：

```console
# ① 框架进程在跑吗？
$ ps aux | grep -E 'fcitx5|ibus'
```

```nix
// ② 声明框架与中文 addon（缺 addon 是「有框架没拼音」的根因）
i18n.inputMethod = {
  type = "fcitx5";
  fcitx5.addons = [ pkgs.fcitx5-chinese-addons ];
};
```

```nix
// ③ 环境变量：X11 会话需要三件套；Wayland 下 GTK 应用建议
//    留空走 text-input 协议（具体建议随版本演进，以 NixOS Wiki 为准）
environment.sessionVariables = {
  GTK_IM_MODULE = "fcitx";
  QT_IM_MODULE = "fcitx";
  XMODIFIERS = "@im=fcitx";
};
```

```console
# ④ 终端诊断：fcitx5 自带的体检工具，输出会直接指出缺什么
$ fcitx5-diagnose | head -50
```

KDE Plasma 6 等已内置输入法集成时可省去③；排错时先跑④再看其他。

#### 问题 28：双系统时间错乱

- **症状**：Windows 与 NixOS 双系统，切一次系统时钟差 8 小时。
- **根因**：Windows 把 RTC（实时时钟）当本地时间读写，Linux 惯例是当 UTC——两边各改各的，互相「纠正」。
- **诊断**：两系统各看一次时钟与 `timedatectl`，偏差恰为时区小时数即可确认。
- **修复**：让 NixOS 迁就 Windows（改 Windows 注册表也可以，但改 NixOS 一行更省事）：

```nix
// 把 RTC 解释为本地时间（含夏令时漂移的小代价，双系统场景可接受）
time.hardwareClockInLocalTime = true;
```

---

## 46.6 调试工具箱总表

最后一节是全章的「武器架」。熟记每个工具的适用层，排错时按图索骥：

| 工具 | 适用阶段 | 一句话用途 | 典型命令 |
| --- | --- | --- | --- |
| `nix eval` | 求值 | 查看任何属性的值 | `nix eval --json .#nixosConfigurations.h.config.networking.hostName` |
| `nix eval --show-trace` | 求值 | 打印完整调用栈定位环/缺失 | `nix eval --show-trace .#…config.foo` |
| `nix repl` | 求值 | 交互式检查（`:lf` 加载 flake，`:t` 类型，`:p` 打印） | `nix repl` 后 `:lf .` |
| `nix flake show` | 求值 | 列出 flake 全部 outputs 结构 | `nix flake show` |
| `nix build -L` | 构建 | 构建并实时输出日志 | `nix build -L .#foo` |
| `nix log` | 构建 | 事后查看（失败的）构建日志 | `nix log .#foo` |
| `nix derivation show` | 构建 | 展开派生的完整输入与环境变量 | `nix derivation show .#foo` |
| `nix path-info -rSh` | 构建/闭包 | 递归看闭包路径与总大小（`-S` 尺寸 `-h` 人类可读） | `nix path-info -rSh ./result` |
| `nix-diff` | 构建 | 对比两个派生差在哪一步 | `nix run nixpkgs#nix-diff -- /nix/store/A.drv /nix/store/B.drv` |
| `nix-tree` | 闭包 | 交互式浏览闭包依赖树、找体积元凶 | `nix run nixpkgs#nix-tree -- ./result` |
| `nvd` | 系统 | 对比两个 generation 的包差异 | `nix run nixpkgs#nvd -- diff /run/current-system /run/booted-system` |
| `patchelf` | 运行 | 查看/修改 ELF 的解释器与 rpath | `patchelf --print-interpreter ./bin/foo` |
| `readelf` / `ldd` | 运行 | 查看动态段/依赖（Nix 上 ldd 只对「环境齐备」的二进制有意义） | `readelf -d ./bin/foo \| grep NEEDED` |
| `systemd-analyze` | 运行 | 校验单元文件、分析启动耗时 | `systemd-analyze security foo.service` |

三个使用提示：ELF 工具在 Nix 上有个语义要点——`ldd` 找不到解释器时报的错未必是缺库，先用 `patchelf --print-interpreter` 确认解释器路径存在；`nix path-info -rSh` 配合 `sort -h` 是「这个包怎么这么大」的标准开局；`nix-diff` 在「两台机器同一配置构建结果不同」时是唯一称手的放大镜。

## 46.7 本章小结

- 排错第一原则：读完整报错；Nix 报错的第一行定位层（求值/构建/运行），最后一行常常就是答案。
- 求值期五连：infinite recursion 用 --show-trace 找环、裸 if 改 mkIf；attribute/undefined 是拼写与参数声明；multiple definitions 用优先级函数（mkDefault/mkForce）裁决。
- hash mismatch 的正解是独立 prefetch 验证后回填；上游同址换物时先怀疑供应链再改哈希。
- 依赖判定口诀：构建期宿主侧工具进 nativeBuildInputs，链接进产物的库进 buildInputs；pkg-config 找不到是两处没配齐的信号。
- 联网需求必须改造为 fetchers，沙箱断网是特性不是故障；磁盘满按「GC → 删旧代 → 配额」三级处理。
- 系统侧救命三招：switch --rollback、引导菜单选旧代、live USB 挂载 + nixos-enter 救援。
- Flakes 的两大高频坑：新文件必须 git add（file not found 的第一嫌疑）；root 读写他人 git 仓库的 dubious ownership。
- 代理与自签证书都要配置到 nix-daemon 层面（NIX_SSL_CERT_FILE / nix.envVars），shell 里 export 对 daemon 无效。
- 把 46.6 的工具箱当作常备武器：eval 管求值、log 管构建、path-info/nix-tree 管闭包、nvd 管代际、systemd-analyze 管服务。

## 延伸阅读

- Nix 手册（错误信息与排查章节）—— https://nixos.org/manual/nix/stable/
- NixOS 手册 —— https://nixos.org/manual/nixos/stable/
- NixOS Wiki：故障排除专题合集 —— https://wiki.nixos.org/wiki/Category:Troubleshooting
- nix.dev：调试构建教程 —— https://nix.dev/tutorials/debugging-builds
- systemd 手册：journalctl —— https://www.freedesktop.org/software/systemd/man/journalctl.html
- nixos-anywhere 相关救援场景 —— https://github.com/nix-community/nixos-anywhere
