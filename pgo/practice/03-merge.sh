#!/usr/bin/env bash
# 步骤 03：把 .profraw 合并为编译器可读的 merged.profdata。
source "$(dirname "$0")/lib.sh"
need "$PGO_DIR" 02-collect.sh

"$PROFDATA" merge -o "$PGO_DIR/merged.profdata" "$PGO_DIR"

# 检查：摘要中的计数应当非零
"$PROFDATA" show "$PGO_DIR/merged.profdata" | tail -n 4
