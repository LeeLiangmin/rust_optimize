#!/usr/bin/env bash
# 语料与训练负载，供各示例的 run.sh 及 bench.sh 调用。
#   workload.sh corpus       下载并解压语料（Linux 6.6 源码），已存在则跳过
#   workload.sh train <rg>   用指定的 rg 在语料上执行 9 条训练搜索，用于采集 profile
set -euo pipefail
EX=$(cd "$(dirname "$0")/.." && pwd)             # examples/
WORK=$(realpath -m "${WORK_DIR:-$EX/work}")
CORPUS="$WORK/linux-6.6"

corpus() {
    [ -d "$CORPUS" ] && return
    local tarball="$WORK/linux-6.6.tar.xz"
    local url="${KERNEL_MIRROR:-https://cdn.kernel.org/pub/linux/kernel}/v6.x/linux-6.6.tar.xz"
    mkdir -p "$WORK"
    [ -f "$tarball" ] || { echo "下载 $url"; curl -fsSL -o "$tarball" "$url"; }
    echo "d926a06c63dd8ac7df3f86ee1ffc2ce2a3b81a2d168484e76b5b389aba8e56d0  $tarball" | sha256sum -c -
    tar -xf "$tarball" -C "$WORK"
}

# 训练负载覆盖 ripgrep 的常见用法；与 bench.sh 的评测负载不重复
train() {
    local rg="$1"
    run() { echo "  rg $*"; "$rg" "$@" "$CORPUS" > /dev/null || true; }
    run 'mutex_lock'                                     # 字面量
    run -i 'spin_unlock_irqrestore'                      # 忽略大小写
    run -w 'kfree'                                       # 整词匹配
    run '[a-z]+_init\('                                  # 带字面量后缀的正则
    run 'EXPORT_SYMBOL_GPL|MODULE_AUTHOR|DEFINE_MUTEX'   # 多选一
    run '\w+_(alloc|free)\s*\('                          # 无长字面量的正则
    run -c 'TODO'                                        # 计数
    run -F 'struct device *dev'                          # 固定字符串
    run --files                                          # 仅遍历目录
}

case "${1:-}" in
    corpus) corpus ;;
    train)  train "$2" ;;
    *)      echo "用法：workload.sh corpus | train <rg>" >&2; exit 1 ;;
esac
