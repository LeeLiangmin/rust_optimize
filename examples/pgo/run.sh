#!/usr/bin/env bash
# PGO 案例：对 ripgrep 应用 PGO。步骤编号与 GUIDE.md 2.3 节一致，说明见 examples/README.md。
# 通常通过 examples/run.sh 运行；性能评测由 examples/run.sh evaluate 统一完成。
set -euo pipefail
EX=$(cd "$(dirname "$0")/.." && pwd)          # examples/
WORK=$(realpath -m "${WORK_DIR:-$EX/work}")   # 产物目录，可用 WORK_DIR 覆盖
TARGET=$(rustc -vV | sed -n 's/^host: //p')   # 显式指定 target，RUSTFLAGS 不作用于 build script
PROFDATA=$(rustc --print sysroot)/lib/rustlib/$TARGET/bin/llvm-profdata
CARGO=(cargo build --release --quiet --target "$TARGET" --manifest-path "$EX/subjects/ripgrep/Cargo.toml")
BIN=$WORK/bin
PGO_DIR=$WORK/pgo-data
step() { echo; echo "==> 步骤 $*"; }
mkdir -p "$BIN"

step "0：检查环境"
[ -x "$PROFDATA" ] || { echo "缺少 llvm-profdata：rustup component add llvm-tools-preview" >&2; exit 1; }
"$PROFDATA" --version | head -2
"$EX/common/workload.sh" corpus

step "1：普通构建与插桩构建"
"${CARGO[@]}" --target-dir "$WORK/target/base"
cp "$WORK/target/base/$TARGET/release/rg" "$BIN/rg-base"
RUSTFLAGS="-Cprofile-generate=$PGO_DIR" "${CARGO[@]}" --target-dir "$WORK/target/instr"
cp "$WORK/target/instr/$TARGET/release/rg" "$BIN/rg-instr"
ls -lh "$BIN/rg-base" "$BIN/rg-instr"

step "2：采集 profile"
rm -rf "$PGO_DIR"
"$EX/common/workload.sh" train "$BIN/rg-instr"
ls -lh "$PGO_DIR"

step "3：合并 profile"
"$PROFDATA" merge -o "$PGO_DIR/merged.profdata" "$PGO_DIR"
"$PROFDATA" show "$PGO_DIR/merged.profdata" | tail -n 4

step "4：优化构建"
RUSTFLAGS="-Cprofile-use=$PGO_DIR/merged.profdata -Cllvm-args=-pgo-warn-missing-function" \
    "${CARGO[@]}" --target-dir "$WORK/target/pgo" 2>&1 | tee "$WORK/pgo-build.log"
cp "$WORK/target/pgo/$TARGET/release/rg" "$BIN/rg-pgo"
echo "缺少 profile 的函数告警：$(grep -c 'no profile data available' "$WORK/pgo-build.log" || true) 条"
ls -lh "$BIN/rg-pgo"

step "5：验证"
"$EX/common/bench.sh" check "$BIN/rg-base" "$BIN/rg-pgo"
echo "性能评测：bash examples/run.sh evaluate"
