#!/usr/bin/env bash
# 步骤 02：用插桩版运行训练负载，在 $PGO_DIR 下生成 .profraw。
source "$(dirname "$0")/lib.sh"
need "$BIN/rg-instr" 01-build.sh

# 清掉旧的 profile，避免与本次计数混在一起
rm -rf "$PGO_DIR"
"$COMMON/train.sh" "$BIN/rg-instr"

ls -lh "$PGO_DIR"
