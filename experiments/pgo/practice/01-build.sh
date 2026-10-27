#!/usr/bin/env bash
# 步骤 01：构建基线版（对照组）和插桩版（用于采集 profile）。
source "$(dirname "$0")/lib.sh"

build base ""
build instr "-Cprofile-generate=$PGO_DIR"

ls -lh "$BIN/rg-base" "$BIN/rg-instr"
