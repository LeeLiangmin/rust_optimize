# PGO 示例脚本的公共部分。由同目录的脚本 source，不单独执行。
export TECH=pgo
source "$(dirname "${BASH_SOURCE[0]}")/../../common/env.sh"

COMMON="$ROOT/common"
PRACTICE="$TECH_DIR/practice"
BIN="$TECH_WORK/bin"
DATA="$TECH_WORK/data"
# 插桩版程序写出 .profraw 的目录，也是合并后 .profdata 的位置
PGO_DIR="$DATA/profile"
mkdir -p "$BIN" "$DATA"
