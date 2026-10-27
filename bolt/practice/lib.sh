# BOLT 实践脚本的公共部分。由同目录的脚本 source，不单独执行。
source "$(dirname "${BASH_SOURCE[0]}")/../common/env.sh"

COMMON="$ROOT/common"
PRACTICE="$ROOT/practice"
BIN="$WORK_DIR/bin"
DATA="$WORK_DIR/data"
mkdir -p "$BIN" "$DATA"

# 步骤 03 的优化参数，插桩、采样、PGO+BOLT 三种情况共用
BOLT_FLAGS=(
    -reorder-blocks=ext-tsp
    -reorder-functions=cdsort
    -split-functions
    -split-all-cold
    -split-eh
    -icf
    -dyno-stats
)

# 当前环境能否用 perf 记录分支（LBR）
lbr_supported() {
    local tmp ok=1
    tmp="$(mktemp)"
    perf record -q -e cycles:u -j any,u -o "$tmp" -- true > /dev/null 2>&1 && ok=0
    rm -f "$tmp"
    return $ok
}

# 插桩采集：生成插桩版 → 运行训练负载 → 合并，输出 <目录>/merged.fdata
# 用法：instrument_profile <带重定位的二进制> <profile 目录>
instrument_profile() {
    local input="$1" dir="$2"
    rm -rf "$dir"; mkdir -p "$dir"
    llvm-bolt "$input" -instrument -o "$dir/rg.inst" \
        --instrumentation-file="$dir/prof.fdata" \
        --instrumentation-file-append-pid
    "$COMMON/train.sh" "$dir/rg.inst"
    ls -lh "$dir"/prof.fdata.*.fdata
    merge-fdata "$dir"/prof.fdata.*.fdata > "$dir/merged.fdata"
}

# 优化：按 profile 重排二进制，产物为 $BIN/rg-<名称>
# 用法：optimize <带重定位的二进制> <profile> <名称>
optimize() {
    echo "==> 优化 rg-$3"
    llvm-bolt "$1" -o "$BIN/rg-$3" -data="$2" "${BOLT_FLAGS[@]}"
}
