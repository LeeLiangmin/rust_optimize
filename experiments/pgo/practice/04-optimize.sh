#!/usr/bin/env bash
# 步骤 04：按 profile 重新编译，得到 rg-pgo。
source "$(dirname "$0")/lib.sh"
need "$PGO_DIR/merged.profdata" 03-merge.sh

log="$DATA/optimize.log"
build pgo "-Cprofile-use=$PGO_DIR/merged.profdata -Cllvm-args=-pgo-warn-missing-function" \
    2>&1 | tee "$log"

# 检查：大量告警说明 profile 与源码不匹配
n=$(grep -c "no profile data available" "$log" || true)
echo "缺少 profile 的函数告警：$n 条"
ls -lh "$BIN/rg-pgo"
