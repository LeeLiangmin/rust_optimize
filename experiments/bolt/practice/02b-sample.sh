#!/usr/bin/env bash
# 步骤 02b：采样采集（perf + LBR）。输出 $DATA/perf/rg.fdata。
# 当前环境不支持 LBR 时跳过，后续步骤只使用插桩方式的 profile。
source "$(dirname "$0")/lib.sh"
need "$BIN/rg-reloc" 01-build.sh

dir="$DATA/perf"
rm -rf "$dir"

if ! lbr_supported; then
    echo "当前环境不支持 LBR，跳过采样方式"
    exit 0
fi

mkdir -p "$dir"
# 对带重定位的原程序（不是插桩版）运行同一套训练负载并采样
perf record -e cycles:u -j any,u -o "$dir/perf.data" -- \
    "$COMMON/train.sh" "$BIN/rg-reloc"
# 转换为 BOLT 的 profile；只提取属于 rg-reloc 的样本
perf2bolt -p "$dir/perf.data" -o "$dir/rg.fdata" "$BIN/rg-reloc"
