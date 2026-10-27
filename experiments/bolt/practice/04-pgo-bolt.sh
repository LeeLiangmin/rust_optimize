#!/usr/bin/env bash
# 步骤 04：与 PGO 叠加。先完成 PGO（得到 rg-pgo 作对照），
# 再用 PGO profile 构建带重定位的版本，对其重新采集 BOLT profile 并优化，得到 rg-pgo-bolt。
source "$(dirname "$0")/lib.sh"
pgo_dir="$DATA/pgo"

# PGO：插桩构建 → 训练 → 合并
build pgo-gen "-Cprofile-generate=$pgo_dir"
rm -rf "$pgo_dir"
"$COMMON/train.sh" "$BIN/rg-pgo-gen"
"$PROFDATA" merge -o "$pgo_dir/merged.profdata" "$pgo_dir"

# 仅 PGO 的版本，作为对照
build pgo "-Cprofile-use=$pgo_dir/merged.profdata"

# PGO + 保留重定位，再执行 BOLT。BOLT profile 必须在这个二进制上重新采集
build pgo-reloc "-Cprofile-use=$pgo_dir/merged.profdata -Clink-args=-Wl,-q"
instrument_profile "$BIN/rg-pgo-reloc" "$DATA/pgo-instr"
optimize "$BIN/rg-pgo-reloc" "$DATA/pgo-instr/merged.fdata" pgo-bolt
