#!/usr/bin/env bash
# 步骤 05：评测所有已生成的版本，结果写入 experiments/bolt/practice/results.md。
source "$(dirname "$0")/lib.sh"
need "$BIN/rg-base" 01-build.sh

bins=()
for v in base pgo bolt bolt-perf pgo-bolt; do
    [ -x "$BIN/rg-$v" ] && bins+=("$BIN/rg-$v")
done
"$COMMON/bench.sh" "$PRACTICE/results.md" "${bins[@]}"
