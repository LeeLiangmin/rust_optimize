#!/usr/bin/env bash
# cargo-pgo 示例：用 cargo-pgo 完成 PGO，以及 PGO + BOLT。
# 步骤 1–3 对应 pgo.sh 的 PGO 流程，步骤 4–6 对应 bolt.sh 的"与 PGO 叠加"。
# 说明见 pgo.md、bolt.md 的"使用 cargo-pgo"一节。需要先运行 pgo.sh（用其 rg-base 做输出对照），
# 步骤 4–6 需要 llvm-bolt 在 PATH 中。
set -euo pipefail
cd "$(dirname "$0")"
WORK=$(realpath -m "${WORK_DIR:-work}")
TARGET=$(rustc -vV | sed -n 's/^host: //p')
export CARGO_TARGET_DIR=$WORK/target/cargo-pgo
OUT=$CARGO_TARGET_DIR/$TARGET/release
BIN=$WORK/bin
step() { echo; echo "==> 步骤 $*"; }

step "0：检查环境"
command -v cargo-pgo > /dev/null || { echo "缺少 cargo-pgo：cargo install cargo-pgo" >&2; exit 1; }
[ -x "$BIN/rg-base" ] || { echo "未找到 $BIN/rg-base，先运行 pgo.sh" >&2; exit 1; }
(cd ripgrep && cargo pgo info)
./workload.sh corpus

step "1：PGO 插桩构建（cargo pgo build）"
(cd ripgrep && cargo pgo build)

step "2：采集 PGO profile"
./workload.sh train "$OUT/rg"

step "3：PGO 优化构建（cargo pgo optimize）"
(cd ripgrep && cargo pgo optimize)
cp "$OUT/rg" "$BIN/rg-cargo-pgo"
ls -lh "$BIN/rg-cargo-pgo"

step "4：PGO 优化构建并生成 BOLT 插桩版（cargo pgo bolt build --with-pgo）"
(cd ripgrep && cargo pgo bolt build --with-pgo)

step "5：采集 BOLT profile"
./workload.sh train "$OUT/rg-bolt-instrumented"

step "6：BOLT 优化（cargo pgo bolt optimize --with-pgo）"
(cd ripgrep && cargo pgo bolt optimize --with-pgo)
cp "$OUT/rg-bolt-optimized" "$BIN/rg-cargo-pgo-bolt"
ls -lh "$BIN/rg-cargo-pgo-bolt"

step "7：验证（输出与普通构建一致）"
for rg in "$BIN/rg-base" "$BIN/rg-cargo-pgo" "$BIN/rg-cargo-pgo-bolt"; do
    printf '%-20s %s\n' "$(basename "$rg")" "$("$rg" -w PM_RESUME "$WORK/linux-6.6" | sort | sha256sum | cut -c1-16)"
done
