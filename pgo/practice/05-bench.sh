#!/usr/bin/env bash
# 步骤 05：评测基线版与 PGO 版，结果写入 pgo/practice/results.md。
source "$(dirname "$0")/lib.sh"
need "$BIN/rg-base" 01-build.sh
need "$BIN/rg-pgo" 04-optimize.sh

"$COMMON/bench.sh" "$PRACTICE/results.md" "$BIN/rg-base" "$BIN/rg-pgo"
