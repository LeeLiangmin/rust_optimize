#!/usr/bin/env bash
# 步骤 01：构建基线版（对照组）和带重定位信息的版本（BOLT 的输入）。
source "$(dirname "$0")/lib.sh"

build base ""
build reloc "-Clink-args=-Wl,-q"

# 检查：重定位信息已保留
readelf -S "$BIN/rg-reloc" | grep -q rela.text \
    || { echo "rg-reloc 中没有 .rela.text，重定位信息未保留" >&2; exit 1; }
ls -lh "$BIN/rg-base" "$BIN/rg-reloc"
