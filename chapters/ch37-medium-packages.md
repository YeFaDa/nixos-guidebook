# 第 37 章 中等包实例精讲（逐行注释）

> **本章导读**：两个真实的中等复杂度包，代表两门静态编译语言的生态路线：**fzf**（Go，`buildGoModule`，模糊查找器，0.74.2）与 **ripgrep**（Rust，`buildRustPackage`，代码搜索工具，15.2.0）。源码为 nixpkgs master 分支 2026-08 快照的**完整逐字内容**，每行（每块）注释其目的。学完本章，你将能独立打包绝大多数 Go/Rust 命令行工具，并掌握交叉执行测试、shell 补全、多输出等中阶技术。

## 37.1 实例一：fzf——buildGoModule 全解

文件：`pkgs/by-name/fz/fzf/package.nix`。

### 37.1.1 完整源码（逐行注释）

```nix
{
  lib,                     # 标准库：getExe、licenses、maintainers、platforms
  buildGoModule,           # ★ Go 生态构建器（第 35.3 节）——本包的 builder
  fetchFromGitHub,         # GitHub 取源（第 15.3.3 节）
  runtimeShell,            # 「本平台的 shell」路径：写跨平台脚本时用它而非写死 /bin/sh
  installShellFiles,       # 安装 man/补全的钩子（构建期工具 → native）
  bc,                      # fzf-tmux 脚本运行时依赖 bc → 既是构建期也是运行期依赖
  ncurses,                 # 运行时链接的库
  versionCheckHook,        # 版本自检钩子
}:

buildGoModule (finalAttrs: {        # finalAttrs 模式（第 7.5.2 节）——即使是生态 builder 也一样用
  pname = "fzf";
  version = "0.74.2";

  __structuredAttrs = true;         # 参数 JSON 化传入（第 34.9 节）

  src = fetchFromGitHub {           # 源码：GitHub tag（不是 branch——防漂移，第 15 章）
    owner = "junegunn";
    repo = "fzf";
    tag = "v${finalAttrs.version}"; # 引用 finalAttrs：override 版本时源自动跟随
    hash = "sha256-b/dQOebD8pbg+oX2Q9n4hNqdKgW/xLp4HhoGKp6BaTM=";
  };                                # 产物是解压后的源码树（fetchzip 语义）

  vendorHash = "sha256-NojjUf/3c4q4B96eQ/qcI+GdRvHakHUyMRaQ6/IZpEw=";
  # ★ Go 生态的核心参数：go.mod 全部依赖的「供应商树」哈希。
  # buildGoModule 内部用固定输出派生（fetch-go-modules? 事实上的 FOD）按 go.mod
  # 下载所有模块形成 vendor 树——vendorHash 锁定它。打包新包的流程与 src 一样：
  # 先填 lib.fakeHash，构建报 mismatch 后回填真实值（第 42 章实战演示）。

  env.CGO_ENABLED = 0;              # ✅ 现代写法（env.<VAR>，第 34.5 节）：
                                    # 纯 Go 编译、不调 C → 产物无 libc 动态依赖，
                                    # 闭包更小、交叉更省事（fzf 的选择）

  outputs = [
    "out"
    "man"                          # 拆出手册输出：不装 man 的用户闭包更小（第 34.7 节）
  ];

  nativeBuildInputs = [ installShellFiles ];
  # 构建「执行」的工具：装补全的钩子（构建完即弃）

  buildInputs = [ ncurses ];
  # 「链接/运行」进产物的库：fzf 的 tui 需要 ncurses（动态链接）

  ldflags = [
    "-s"
    "-w"                           # 链接器旗标：去符号表/调试信息 → 二进制更小
    "-X main.version=${finalAttrs.version} -X main.revision=${finalAttrs.src.rev}"
    # Go 惯用法：把版本号与 git rev 编译进二进制（fzf --version 显示的就是它）
  ];

  # ── postPatch：打补丁阶段的自定义（第 33 章 patchPhase 的扩展点）──
  postPatch = ''
    sed -i -e "s|expand('<sfile>:h:h')|'$out'|" plugin/fzf.vim
    # vim 插件用相对路径定位二进制 → 改成绝对路径 $out（Nix 的只读 store 语义要求）

    if ! grep -q $out plugin/fzf.vim; then
        echo "Failed to replace vim base_dir path with $out"
        exit 1
    fi
    # 「改完验证」纪律：上游一改格式，silent 失败比报错更可怕——立即退出

    # fzf-tmux 依赖 bc（运行时 shell 里调用）：
    substituteInPlace bin/fzf-tmux \
      --replace-fail "bc" "${lib.getExe bc}"
    # ✅ substituteInPlace + --replace-fail（失败即报错的新参数，替代 --replace）
    # ✅ lib.getExe bc：注入 bc 的完整路径——运行期依赖进闭包的关键一步
  '';

  # ── postInstall：安装阶段追加（make/ninja 默认安装之外的加工）──
  postInstall = ''
    install bin/fzf-tmux $out/bin        # 补装 Go 构建不覆盖的辅助脚本

    installManPage man/man1/fzf.1 man/man1/fzf-tmux.1
    # installShellFiles 的命令：自动识别 gzip 情况并装进 $man 输出

    install -D plugin/* -t $out/share/vim-plugins/fzf/plugin   # vim 插件归位
    mkdir -p $out/share/nvim
    ln -s $out/share/vim-plugins/fzf $out/share/nvim/site      # nvim 复用同目录

    # 安装 shell 集成脚本（bash/zsh/fish 的 key-bindings 等）：
    install -D shell/* -t $out/share/fzf/

    # 生成 fzf-share 帮助脚本：让用户 shell 里能定位集成脚本目录
    cat <<SCRIPT > $out/bin/fzf-share
    #!${runtimeShell}
    # Run this script to find the fzf shared folder where all the shell
    # integration scripts are living.
    echo $out/share/fzf
    SCRIPT
    chmod +x $out/bin/fzf-share
  '';

  nativeInstallCheckInputs = [ versionCheckHook ];   # 安装期自检的钩子依赖
  doInstallCheck = true;                              # 开启：跑 fzf --version 核对 0.74.2

  meta = {
    changelog = "https://github.com/junegunn/fzf/blob/${finalAttrs.src.rev}/CHANGELOG.md";
    description = "Command-line fuzzy finder written in Go";
    homepage = "https://github.com/junegunn/fzf";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [
      ma27
      zowoq
    ];
    mainProgram = "fzf";
    platforms = lib.platforms.unix;      # Go 跨平台容易，但官方只在 unix 家族验证
  };
})
```

### 37.1.2 fzf 教给我们的

- **buildGoModule 的骨架五件**：src（tag 锁定）、vendorHash（依赖锁）、env.CGO_ENABLED、ldflags（版本注入）、meta；一个普通 Go CLI 到此就能打包；
- **运行期 shell 依赖的正确姿势**：`substituteInPlace + lib.getExe` 把 `bc` 变成绝对路径——第 17 章闭包完整性的日常操作；
- **「改完必验」**：`grep 验证 + exit 1`、`--replace-fail`，上游格式变化时宁炸勿静默；
- **outputs 拆 man、runtimeShell 写 shebang**：跨平台与体积意识；
- **vim/nvim 插件的常规处理**：装进 `share/vim-plugins` 并为 nvim 建链接（编辑器生态的约定位置）。

## 37.2 实例二：ripgrep——buildRustPackage 全解

文件：`pkgs/by-name/ri/ripgrep/package.nix`。相比 fzf，它多出**条件特性**（PCRE2 可选）、**交叉执行测试**（模拟器）、**生成的补全与手册**三个中阶主题。

### 37.2.1 完整源码（逐行注释）

```nix
{
  lib,
  stdenv,                     # 本包直接用 stdenv：为读 hostPlatform（交叉判定）
  buildPackages,              # 「构建平台」的包集合（第 40 章）：交叉时与 stdenv 不同
  fetchFromGitHub,
  rustPlatform,               # ★ Rust 构建器家族：buildRustPackage 从这取
  installShellFiles,
  pkg-config,                 # 让 configure/cargo 能找到 pcre2 的 .pc 元数据
  withPCRE2 ? true,           # ★ 包级开关参数（第 7.3 节）：带默认值的开关，
                              # 用户可 pkgs.ripgrep.override { withPCRE2 = false; }
  pcre2,
  writableTmpDirAsHomeHook,   # 交叉到 Windows 用 wine 跑测试时，需要可写的 HOME
}:

let
  canRunRg = stdenv.hostPlatform.emulatorAvailable buildPackages;
  # 判定「本机构建出的 rg 能否在本机（或经模拟器）执行」：
  # 本机编译→true；交叉且无 qemu/wine→false（测试相应跳过）
  rg = "${stdenv.hostPlatform.emulator buildPackages} $out/bin/rg${stdenv.hostPlatform.extensions.executable}";
  # 造一个「如何执行 rg」的命令前缀：本机是空串；交叉 Windows 是 "wine ...rg.exe"
  # ——同一份测试代码在两种世界都能跑（第 40 章的前瞻实战）
in
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "ripgrep";
  version = "15.2.0";

  __structuredAttrs = true;

  src = fetchFromGitHub {
    owner = "BurntSushi";
    repo = "ripgrep";
    tag = finalAttrs.version;      # 上游 tag 无 v 前缀，直接用版本号
    hash = "sha256-BsSIbZwB6s8i3dDTRYJ1EdVbJmiO0oxcLu6qiYlPkOI=";
  };

  cargoHash = "sha256-AqizStE9ICd6mNDZWdeXg6dHuTiY+B0TNauQQYWUa84=";
  # ★ Rust 生态核心参数：Cargo.lock 全部 crate 的取回树哈希（对位 Go 的 vendorHash；
  # 内部由 fetchCargoTarball 固定输出派生完成，第 15 章语义）

  nativeBuildInputs = [
    installShellFiles
    writableTmpDirAsHomeHook # required for wine when cross-compiling to Windows
    # 交叉测试时 wine 需要可写 HOME，此 hook 设 HOME=$TMPDIR
  ]
  ++ lib.optional withPCRE2 pkg-config;
  # 条件追加：开了 PCRE2 才需要 pkg-config（lib.optional：条件+单值→列表，第 12 章）
  buildInputs = lib.optional withPCRE2 pcre2;
  # 链接目标：PCRE2 是 C 库 → buildInputs（不是 native！）

  buildFeatures = lib.optional withPCRE2 "pcre2";
  # cargo 的 feature 旗标：rg 的 SIMD/look-around 高级正则藏在 pcre2 feature 后

  # ── postFixup：fixup 之后的追加（第 33 章最后一个扩展点）──
  postFixup = lib.optionalString canRunRg ''
    # 只有「跑得了 rg」才生成交互产物（交叉且无模拟器时跳过）：
    ${rg} --generate man > rg.1                     # 用 rg 自己生成 man 页
    installManPage rg.1

    installShellCompletion --cmd rg \
      --bash <(${rg} --generate complete-bash) \
      --fish <(${rg} --generate complete-fish) \
      --zsh <(${rg} --generate complete-zsh)
    # 现代 CLI 的最佳实践：补全由程序自生成，nixpkgs 只负责安装
  '';

  doInstallCheck = true;                            # 装完自检（下面的手工用例）
  installCheckPhase = lib.optionalString canRunRg (
    ''
      file="$(mktemp)"
      echo "abc\nbcd\ncde" > "$file"
      ${rg} -N 'bcd' "$file"                        # 基本搜索用例（-N 无行号）
      ${rg} -N 'cd' "$file"
    ''
    + lib.optionalString withPCRE2 ''
      echo '(a(aa)aa)' | ${rg} -P '\((a*|(?R))*\)'  # PCRE2 递归正则用例：
    ''                                              # 只有 -P feature 在场才应通过
  );
  # 整段被 lib.optionalString canRunRg 包裹：不可执行的世界（无模拟器的交叉）
  # 连 installCheck 都整体跳过——「测试与能力对齐」的优雅表达

  meta = {
    description = "Utility that combines the usability of The Silver Searcher with the raw speed of grep";
    homepage = "https://github.com/BurntSushi/ripgrep";
    changelog = "https://github.com/BurntSushi/ripgrep/releases/tag/${finalAttrs.version}";
    license = with lib.licenses; [
      unlicense # or
      mit
    ];
    # 双许可（or）：上游是 Unlicense OR MIT——lib.licenses 列表 + 注释表达
    maintainers = with lib.maintainers; [
      globin
      ma27
      zowoq
    ];
    mainProgram = "rg";
    platforms = lib.platforms.all;      # Rust 交叉性好，全平台
  };
})
```

### 37.2.2 ripgrep 教给我们的

- **包级开关模式**（`withPCRE2 ? true` + `lib.optional` 全家）：一个源码定义出多个变体，用户 `.override` 即选——第 39 章 override 生态的源头活水；
- **依赖的精细分诊**：pkg-config（工具，native）、pcre2（链接库，build）、writableTmpDirAsHomeHook（构建环境修补，native）——第 34.4 节口诀的三次实战；
- **交叉可执行性设计**（`emulatorAvailable`/`emulator`）：让「补全生成、版本自检、功能用例」在交叉世界同样运转或优雅跳过——第 40 章主题的先行案例；
- **测试对齐能力**：PCRE2 用例只在 feature 开启时运行；不可执行则整体沉默；
- **自生成文档/补全**：postFixup + `--generate`——现代 CLI 打包的标准动作。

## 37.3 Go 与 Rust 打包对照表

| 维度 | buildGoModule | rustPlatform.buildRustPackage |
|------|---------------|-------------------------------|
| 依赖锁 | `vendorHash`（go.mod） | `cargoHash`（Cargo.lock） |
| 版本注入 | `ldflags -X` | `buildNoDefaultFeatures`/`cargoBuildFlags` 常配 env |
| 特性开关 | `buildFlags`/tags | `buildFeatures`/`buildNoDefaultFeatures` |
| 测试 | `checkFlags`（跳网络用例常见） | `cargoTestFlags`/`checkFeatures` |
| 首次打包的共同仪式 | 假哈希 → mismatch → 回填 | 同左（第 42 章实操） |

## 37.4 本章小结

- fzf 与 ripgrep 覆盖静态语言 CLI 打包的两大路线，且各带一个「进阶主题」：运行期脚本依赖的闭包化（fzf 的 bc）与能力对齐的条件测试（ripgrep 的交叉执行）。
- 生态 builder = stdenv 的预配置：phases、hook、第 34 章参数一切照旧，外加语言专有参数（vendor/cargo hash、features）。
- 反复出现的现代规范：finalAttrs、structuredAttrs、SRI、substituteInPlace --replace-fail、lib.getExe、installShellFiles、mainProgram。
- 第 38 章将冲击复杂度上限：Python 包、Linux 内核与 Firefox 的世界。

## 延伸阅读

- 源文件：pkgs/by-name/fz/fzf/package.nix、pkgs/by-name/ri/ripgrep/package.nix
- 手册 «Go«、«Rust»：https://nixos.org/manual/nixpkgs/unstable/#sec-language-go
- fzf/ripgrep 上游文档（--generate 的来历、PCRE2 feature 的含义）
