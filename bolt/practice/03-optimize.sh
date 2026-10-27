#!/usr/bin/env bash
# 步骤 03：按 profile 优化 rg-reloc。插桩 profile → rg-bolt；采样 profile（若有）→ rg-bolt-perf。
source "$(dirname "$0")/lib.sh"
need "$DATA/instr/merged.fdata" 02a-instrument.sh

optimize "$BIN/rg-reloc" "$DATA/instr/merged.fdata" bolt

if [ -f "$DATA/perf/rg.fdata" ]; then
    optimize "$BIN/rg-reloc" "$DATA/perf/rg.fdata" bolt-perf
else
    rm -f "$BIN/rg-bolt-perf"
    echo "没有采样 profile，跳过 rg-bolt-perf"
fi
