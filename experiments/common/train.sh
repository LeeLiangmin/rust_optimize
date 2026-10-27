#!/usr/bin/env bash
# 训练负载：用待采集 profile 的 rg 跑一组典型搜索。
# 刻意与 bench.sh 的模式不同，避免"在考题上训练"。
# 用法：train.sh <rg 可执行文件>
source "$(dirname "$0")/env.sh"
RG="$1"

run() { echo "  rg $*"; "$RG" "$@" "$CORPUS" > /dev/null || true; }

echo "==> 训练：$RG"
run 'mutex_lock'                       # 字面量
run -i 'spin_unlock_irqrestore'        # 忽略大小写
run -w 'kfree'                         # 整词
run '[a-z]+_init\('                    # 带字面量后缀的正则
run 'EXPORT_SYMBOL_GPL|MODULE_AUTHOR|DEFINE_MUTEX'  # 多选一
run '\w+_(alloc|free)\s*\('            # 无长字面量的正则
run -c 'TODO'                          # 计数
run -F 'struct device *dev'            # 固定字符串
run --files                            # 仅遍历目录
