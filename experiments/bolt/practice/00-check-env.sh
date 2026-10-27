#!/usr/bin/env bash
# 步骤 00：检查运行环境。缺少必需工具时给出安装方法并以非 0 退出。
source "$(dirname "$0")/lib.sh"
fail=0

# 用法：check <命令> <安装方法>
check() {
    if command -v "$1" > /dev/null; then
        printf '  %-14s %s\n' "$1" "$(command -v "$1")"
    else
        printf '  %-14s 缺失。安装：%s\n' "$1" "$2"; fail=1
    fi
}

echo "==> 平台"
echo "  $(uname -s) $(uname -m)"
case "$(uname -s)/$(uname -m)" in
    Linux/x86_64 | Linux/aarch64) ;;
    *) echo "  BOLT 需要 Linux x86_64 或 AArch64"; fail=1 ;;
esac

echo "==> ripgrep 源码"
if [ -f "$SRC/Cargo.toml" ]; then
    echo "  $SRC"
else
    echo "  未找到 $SRC/Cargo.toml"; fail=1
fi

echo "==> 工具"
BOLT_HINT="wget https://apt.llvm.org/llvm.sh && sudo bash llvm.sh 21 && sudo apt install bolt-21"
check cargo       "https://rustup.rs"
check llvm-bolt   "$BOLT_HINT"
check merge-fdata "$BOLT_HINT"
check perf2bolt   "$BOLT_HINT"
check perf        "原生 Ubuntu：sudo apt install linux-tools-\$(uname -r)；WSL2：从 WSL 内核源码编译 tools/perf"
check hyperfine   "cargo install hyperfine"
check curl        "sudo apt install curl"
if [ -x "$PROFDATA" ]; then
    printf '  %-14s %s\n' llvm-profdata "$PROFDATA"
else
    printf '  %-14s 缺失。安装：rustup component add llvm-tools-preview\n' llvm-profdata; fail=1
fi
if command -v cargo-pgo > /dev/null; then
    printf '  %-14s %s\n' cargo-pgo "$(command -v cargo-pgo)"
else
    printf '  %-14s 未安装（可选，仅 cargo-pgo.sh 需要）：cargo install cargo-pgo\n' cargo-pgo
fi
[ "$fail" = 0 ] || { echo "请先安装缺失的工具"; exit 1; }

echo "==> 版本"
echo "  $(rustc -V)，$(rustc -vV | grep LLVM)"
bolt_ver="$(llvm-bolt --version | sed -n 's/.*LLVM version //p')"
echo "  BOLT $bolt_ver"
# 步骤 03 使用 -reorder-functions=cdsort，LLVM 18 才提供
if [ "${bolt_ver%%.*}" -lt 18 ]; then
    echo "  BOLT 版本需要 18 及以上（步骤 03 用到 cdsort）。可用 LLVM_BIN 指定较新版本的目录"; fail=1
fi

echo "==> 硬件计数器（评测需要）"
if perf stat -e cycles:u,instructions:u -- true > /dev/null 2>&1; then
    echo "  可用"
else
    echo "  不可用。可尝试：sudo sysctl kernel.perf_event_paranoid=1"; fail=1
fi

echo "==> LBR（步骤 02b 需要）"
if lbr_supported; then
    echo "  可用"
else
    echo "  不可用，步骤 02b（采样方式）将被跳过"
fi

echo "==> 工作目录"
echo "  $WORK_DIR"
case "$WORK_DIR" in
    /mnt/*) echo "  警告：位于 Windows 盘，I/O 开销会掩盖优化效果，建议设置 WORK_DIR=\$HOME/..." ;;
esac
if [[ "$ROOT" == /mnt/* && "$WORK_DIR" != "$ROOT/work" ]]; then
    echo "  仓库位于 Windows 盘，产物改放在 Linux 文件系统中，以免 I/O 开销掩盖优化效果"
fi

exit $fail
