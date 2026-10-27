#!/usr/bin/env bash
# 可选：用 cargo-pgo 完成步骤 01（插桩部分）到 04，得到 rg-cargo-pgo。
# 不在 run.sh 中执行；需要先安装 cargo-pgo，并已下载语料。
source "$(dirname "$0")/lib.sh"
command -v cargo-pgo > /dev/null || { echo "未安装 cargo-pgo：cargo install cargo-pgo" >&2; exit 1; }
need "$BIN/rg-base" 01-build.sh

export CARGO_TARGET_DIR="$TECH_WORK/target/cargo-pgo"
cd "$SRC"

cargo pgo build                                            # 插桩构建
"$COMMON/train.sh" "$CARGO_TARGET_DIR/$TARGET/release/rg"  # 采集
cargo pgo optimize                                         # 合并 + 优化构建
cp "$CARGO_TARGET_DIR/$TARGET/release/rg" "$BIN/rg-cargo-pgo"

# 检查：输出与基线一致
for rg in "$BIN/rg-base" "$BIN/rg-cargo-pgo"; do
    "$rg" -w PM_RESUME "$CORPUS" | sort | sha256sum
done
