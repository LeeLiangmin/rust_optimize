# PGO 实践脚本的公共部分。由同目录的脚本 source，不单独执行。
source "$(dirname "${BASH_SOURCE[0]}")/../../common/env.sh"

COMMON="$ROOT/common"
PRACTICE="$ROOT/pgo/practice"
# 本实践的产物独立存放，不与 BOLT 实践混用
BIN="$WORK_DIR/pgo/bin"
DATA="$WORK_DIR/pgo/data"
# 插桩版程序写出 .profraw 的目录，也是合并后 .profdata 的位置
PGO_DIR="$DATA/profile"
mkdir -p "$BIN" "$DATA"
