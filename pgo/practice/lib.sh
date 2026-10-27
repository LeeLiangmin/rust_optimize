# PGO 实践脚本的公共部分。由同目录的脚本 source，不单独执行。
source "$(dirname "${BASH_SOURCE[0]}")/../common/env.sh"

COMMON="$ROOT/common"
PRACTICE="$ROOT/practice"
BIN="$WORK_DIR/bin"
DATA="$WORK_DIR/data"
# 插桩版程序写出 .profraw 的目录，也是合并后 .profdata 的位置
PGO_DIR="$DATA/profile"
mkdir -p "$BIN" "$DATA"
