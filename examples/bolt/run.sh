#!/usr/bin/env bash
# BOLT 示例：对 ripgrep 应用 BOLT（插桩、采样两种方式），并与 PGO 叠加。
# 步骤编号与 BOLT.md 第 3 节一致，与 PGO 叠加对应 BOLT.md 第 4 节，说明见同目录的 README.md。
# 与 PGO 叠加需要先运行 ../pgo/run.sh。
set -euo pipefail
EX=$(cd "$(dirname "$0")/.." && pwd)          # examples/
WORK=$(realpath -m "${WORK_DIR:-$EX/work}")   # 产物目录，可用 WORK_DIR 覆盖
TARGET=$(rustc -vV | sed -n 's/^host: //p')
CARGO=(cargo build --release --quiet --target "$TARGET" --manifest-path "$EX/subjects/ripgrep/Cargo.toml")
BIN=$WORK/bin
DATA=$WORK/bolt-data
BOLT_OPTS=(-reorder-blocks=ext-tsp -reorder-functions=cdsort -split-functions -split-all-cold -split-eh -icf -dyno-stats)
step() { echo; echo "==> 步骤 $*"; }
mkdir -p "$BIN" "$DATA"

# 插桩采集：生成插桩版 → 运行训练负载 → 合并为 <目录>/merged.fdata
instrument() {
    local input="$1" dir="$2"
    rm -rf "$dir"; mkdir -p "$dir"
    llvm-bolt "$input" -instrument -o "$dir/rg.inst" \
        --instrumentation-file="$dir/prof.fdata" --instrumentation-file-append-pid > /dev/null
    "$EX/common/workload.sh" train "$dir/rg.inst"
    merge-fdata "$dir"/prof.fdata.*.fdata > "$dir/merged.fdata"
    ls "$dir"/prof.fdata.*.fdata | wc -l | xargs echo "profile 文件数："
}

# 优化：输出中只显示 profile 覆盖率和跳转次数变化
optimize() {
    llvm-bolt "$1" -o "$2" -data="$3" "${BOLT_OPTS[@]}" 2>&1 \
        | grep -E 'out of .* functions .* profile|taken branches \(' | grep -v ' 0 out of' || true
    ls -lh "$2"
}

step "0：检查环境"
command -v llvm-bolt > /dev/null || { echo "缺少 llvm-bolt：安装 bolt-N 后执行 export PATH=/usr/lib/llvm-N/bin:\$PATH" >&2; exit 1; }
ver=$(llvm-bolt --version | sed -n 's/.*LLVM version \([0-9]*\).*/\1/p')
echo "BOLT 版本：$ver"
[ "$ver" -ge 18 ] || { echo "需要 18 及以上版本（使用了 -reorder-functions=cdsort）" >&2; exit 1; }
"$EX/common/workload.sh" corpus

step "1：普通构建与带重定位构建"
"${CARGO[@]}" --target-dir "$WORK/target/base"
cp "$WORK/target/base/$TARGET/release/rg" "$BIN/rg-base"
RUSTFLAGS="-Clink-args=-Wl,-q" "${CARGO[@]}" --target-dir "$WORK/target/reloc"
cp "$WORK/target/reloc/$TARGET/release/rg" "$BIN/rg-reloc"
readelf -S "$BIN/rg-reloc" | grep -q rela.text && echo "重定位信息已保留"
ls -lh "$BIN/rg-base" "$BIN/rg-reloc"

step "2a：插桩采集"
instrument "$BIN/rg-reloc" "$DATA/instr"

step "2b：采样采集"
if perf record -q -e cycles:u -j any,u -o /tmp/lbr-check.data -- true > /dev/null 2>&1; then
    rm -rf "$DATA/perf"; mkdir -p "$DATA/perf"
    perf record -e cycles:u -j any,u -o "$DATA/perf/perf.data" -- "$EX/common/workload.sh" train "$BIN/rg-reloc"
    perf2bolt -p "$DATA/perf/perf.data" -o "$DATA/perf/rg.fdata" "$BIN/rg-reloc" 2>&1 \
        | grep -E 'PERF2BOLT: read|out of .* functions .* profile' || true
else
    echo "CPU 不支持 LBR，跳过采样方式"
fi
rm -f /tmp/lbr-check.data

step "3：优化"
optimize "$BIN/rg-reloc" "$BIN/rg-bolt" "$DATA/instr/merged.fdata"
[ -f "$DATA/perf/rg.fdata" ] && optimize "$BIN/rg-reloc" "$BIN/rg-bolt-perf" "$DATA/perf/rg.fdata"

echo; echo "==> 与 PGO 叠加"
PGO_PROFILE=$WORK/pgo-data/merged.profdata
if [ -f "$PGO_PROFILE" ]; then
    RUSTFLAGS="-Cprofile-use=$PGO_PROFILE -Clink-args=-Wl,-q" "${CARGO[@]}" --target-dir "$WORK/target/pgo-reloc"
    cp "$WORK/target/pgo-reloc/$TARGET/release/rg" "$BIN/rg-pgo-reloc"
    instrument "$BIN/rg-pgo-reloc" "$DATA/pgo-instr"
    optimize "$BIN/rg-pgo-reloc" "$BIN/rg-pgo-bolt" "$DATA/pgo-instr/merged.fdata"
else
    echo "未找到 PGO profile，跳过本步骤（先运行 ../pgo/run.sh）"
fi

step "4：验证"
bins=()
for v in base pgo bolt bolt-perf pgo-bolt; do
    [ -x "$BIN/rg-$v" ] && bins+=("$BIN/rg-$v")
done
"$EX/common/bench.sh" "$EX/bolt/results.md" "${bins[@]}"
