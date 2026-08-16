#!/usr/bin/env bash
# build-pdf.sh —— 把全书导出为单个 PDF（需要安装 pandoc 与 xelatex）
#
# 依赖安装：
#   - 已有 Nix 的机器（推荐）： nix shell nixpkgs#pandoc nixpkgs#texliveFull
#   - 其他平台： 安装 pandoc（https://pandoc.org）与 TeX Live（含 xelatex、CJK 支持）
#
# 用法： bash build/build-pdf.sh
# 产出： build/Nix与NixOS中文手册.pdf

set -euo pipefail
cd "$(dirname "$0")/.."

OUT="build/Nix与NixOS中文手册.pdf"
mkdir -p build

# 按章节号排序拼接全部 markdown（README 开头，其后 45 章，最后附录 A-D）
FILES=$(ls README.md chapters/ch*.md appendix/appendix-*.md | sort -t- -k1,1)

pandoc $FILES \
  -o "$OUT" \
  --pdf-engine=xelatex \
  -V CJKmainfont="Noto Serif CJK SC" \
  -V mainfont="Noto Serif" \
  -V monofont="JetBrains Mono" \
  -V geometry:margin=2.2cm \
  -V fontsize=10pt \
  -V documentclass=report \
  --toc \
  --toc-depth=2 \
  --highlight-style=tango \
  -f markdown+smart \
  --resource-path=.

echo "完成：$OUT"
