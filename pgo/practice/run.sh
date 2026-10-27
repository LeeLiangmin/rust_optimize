#!/usr/bin/env bash
# 一键复现 PGO 实践：检查环境 → 下载语料 → 步骤 01–05。
# 任何一步失败都会立即停止；也可以单独运行各步骤脚本。
set -euo pipefail
cd "$(dirname "$0")"

step() {
    echo
    echo "######## $1 ########"
    local start=$SECONDS
    bash "$1"
    echo "######## $1 完成，用时 $((SECONDS - start)) 秒"
}

step 00-check-env.sh
step ../../common/corpus.sh
step 01-build.sh
step 02-collect.sh
step 03-merge.sh
step 04-optimize.sh
step 05-bench.sh
