#!/usr/bin/env bash
# 步骤 02a：插桩采集。输出 $DATA/instr/merged.fdata。
source "$(dirname "$0")/lib.sh"
need "$BIN/rg-reloc" 01-build.sh

instrument_profile "$BIN/rg-reloc" "$DATA/instr"
