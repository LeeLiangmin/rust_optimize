# 公共变量与函数。由其他脚本 source，不单独执行。
set -euo pipefail

# 本技术目录（pgo/ 或 bolt/），可以单独拿出去使用
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# ripgrep 源码：默认为与本目录同级的 ripgrep/；单独使用本目录时，用 RIPGREP_SRC 指定
SRC="${RIPGREP_SRC:-$(dirname "$ROOT")/ripgrep}"

# 构建产物、profile、语料的存放位置。默认为本目录下的 work/（已在 .gitignore 中忽略）。
# 本目录位于 WSL 的 Windows 盘（/mnt/*）时，文件共享的 I/O 开销会掩盖优化效果，
# 改用 Linux 文件系统中的 ~/rust_optimize_work/<本目录名>。也可用 WORK_DIR 直接指定。
if [ -z "${WORK_DIR:-}" ]; then
    case "$ROOT" in
        /mnt/*) WORK_DIR="$HOME/rust_optimize_work/$(basename "$ROOT")" ;;
        *)      WORK_DIR="$ROOT/work" ;;
    esac
fi
CORPUS="${CORPUS:-$WORK_DIR/linux-6.6}"

# 目标平台默认取 rustc 的宿主平台。显式传给 cargo 后，RUSTFLAGS 只作用于目标程序，
# 不作用于 build script 和过程宏。
TARGET="${TARGET:-$(rustc -vV 2>/dev/null | sed -n 's/^host: //p')}"

# llvm-profdata 来自 rustup 的 llvm-tools 组件，与 rustc 内置 LLVM 版本一致。
PROFDATA="$(rustc --print sysroot 2>/dev/null)/lib/rustlib/$TARGET/bin/llvm-profdata"

# llvm-bolt、merge-fdata、perf2bolt：PATH 中没有时，自动使用 /usr/lib/llvm-*/bin 中
# 版本最高的一个（apt.llvm.org 的 bolt-N 包安装在这里）。也可用 LLVM_BIN 指定。
if [ -z "${LLVM_BIN:-}" ] && ! command -v llvm-bolt > /dev/null; then
    for d in $(ls -d /usr/lib/llvm-*/bin 2>/dev/null | sort -V); do
        [ -x "$d/llvm-bolt" ] && LLVM_BIN="$d"
    done
fi
[ -n "${LLVM_BIN:-}" ] && export PATH="$LLVM_BIN:$PATH"

mkdir -p "$WORK_DIR"

# 前置产物不存在时，提示应先运行哪个脚本
# 用法：need <文件> <产生它的脚本>
need() {
    [ -e "$1" ] || { echo "缺少 $1，请先运行 $2" >&2; exit 1; }
}

# 用法：build <名称> <RUSTFLAGS>，产物复制为 $BIN/rg-<名称>（BIN 由各实践的 lib.sh 设置）
build() {
    local name="$1" flags="$2"
    echo "==> 构建 rg-$name  RUSTFLAGS='$flags'"
    RUSTFLAGS="$flags" cargo build --release --quiet \
        --manifest-path "$SRC/Cargo.toml" \
        --target "$TARGET" \
        --target-dir "$WORK_DIR/target/$name"
    cp "$WORK_DIR/target/$name/$TARGET/release/rg" "$BIN/rg-$name"
}
