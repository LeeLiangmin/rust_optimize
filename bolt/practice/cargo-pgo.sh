#!/usr/bin/env bash
# 可选：用 cargo-pgo 完成 PGO + BOLT（对应 04-pgo-bolt.sh），得到 rg-cargo-pgo-bolt。
# 不在 run.sh 中执行；需要先安装 cargo-pgo，并已下载语料。
source "$(dirname "$0")/lib.sh"
command -v cargo-pgo > /dev/null || { echo "未安装 cargo-pgo：cargo install cargo-pgo" >&2; exit 1; }
need "$BIN/rg-base" 01-build.sh

export CARGO_TARGET_DIR="$WORK_DIR/target/cargo-pgo"
OUT="$CARGO_TARGET_DIR/$TARGET/release"
cd "$SRC"

cargo pgo build                                       # PGO 插桩构建
"$COMMON/train.sh" "$OUT/rg"                          # PGO 采集
cargo pgo bolt build --with-pgo                       # PGO 优化构建 + 带重定位 + BOLT 插桩
"$COMMON/train.sh" "$OUT/rg-bolt-instrumented"        # BOLT 采集
cargo pgo bolt optimize --with-pgo                    # BOLT 优化
cp "$OUT/rg-bolt-optimized" "$BIN/rg-cargo-pgo-bolt"

# 检查：输出与基线一致
for rg in "$BIN/rg-base" "$BIN/rg-cargo-pgo-bolt"; do
    "$rg" -w PM_RESUME "$CORPUS" | sort | sha256sum
done
