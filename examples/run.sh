#!/usr/bin/env bash
# 实践案例的统一入口。
#   bash examples/run.sh              依次运行 pgo、bolt、cargo-pgo 三个案例，再统一评测
#   bash examples/run.sh <名称>       只运行一项：pgo | bolt | cargo-pgo | evaluate
#                                      bolt、cargo-pgo 依赖 pgo 案例的产物，缺失时先运行 pgo
# 产物写入 examples/work/（可用 WORK_DIR 修改），评测结果写入 examples/results.md。
set -euo pipefail
EX=$(cd "$(dirname "$0")" && pwd)             # examples/
WORK=$(realpath -m "${WORK_DIR:-$EX/work}")
BIN=$WORK/bin
VERSIONS=(rg-base rg-pgo rg-bolt rg-bolt-perf rg-pgo-bolt rg-cargo-pgo rg-cargo-pgo-bolt)
TIMES=()

usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; }

# 检查所需工具，缺失时列出安装方法后退出
check_tools() {
    local missing=() t profdata ver
    for t in "$@"; do
        case "$t" in
            cargo) command -v cargo > /dev/null || missing+=("cargo：通过 https://rustup.rs 安装 Rust 工具链") ;;
            llvm-profdata)
                profdata="$(rustc --print sysroot 2> /dev/null)/lib/rustlib/$(rustc -vV 2> /dev/null | sed -n 's/^host: //p')/bin/llvm-profdata"
                [ -x "$profdata" ] || missing+=("llvm-profdata：rustup component add llvm-tools-preview") ;;
            curl) command -v curl > /dev/null || missing+=("curl：sudo apt install curl") ;;
            perf) command -v perf > /dev/null || missing+=("perf：安装发行版的 perf 软件包（如 linux-tools）") ;;
            hyperfine) command -v hyperfine > /dev/null || missing+=("hyperfine：sudo apt install hyperfine 或 cargo install hyperfine") ;;
            llvm-bolt)
                ver=$(llvm-bolt --version 2> /dev/null | sed -n 's/.*LLVM version \([0-9]*\).*/\1/p' | head -1)
                [ "${ver:-0}" -ge 18 ] || missing+=("llvm-bolt（18 及以上）：sudo apt install bolt-21，并执行 export PATH=/usr/lib/llvm-21/bin:\$PATH") ;;
            cargo-pgo) command -v cargo-pgo > /dev/null || missing+=("cargo-pgo：cargo install cargo-pgo") ;;
        esac
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "缺少以下工具：" >&2
        printf '  - %s\n' "${missing[@]}" >&2
        exit 1
    fi
}

stage() {
    local name="$1" start=$SECONDS; shift
    echo; echo "################ $name ################"
    "$@"
    TIMES+=("$name：$((SECONDS - start)) 秒")
}

run_case() { stage "$1" bash "$EX/$1/run.sh"; }

# bolt、cargo-pgo 使用 pgo 案例的 rg-base、rg-pgo 和 PGO profile
ensure_pgo() {
    if [ -x "$BIN/rg-base" ] && [ -x "$BIN/rg-pgo" ] && [ -f "$WORK/pgo-data/merged.profdata" ]; then
        return
    fi
    echo "未找到 pgo 案例的产物，先运行 pgo 案例"
    run_case pgo
}

evaluate() {
    local bins=() v
    for v in "${VERSIONS[@]}"; do [ -x "$BIN/$v" ] && bins+=("$BIN/$v"); done
    [ ${#bins[@]} -ge 2 ] || { echo "work/bin/ 中可评测的版本不足两个，先运行案例" >&2; exit 1; }
    echo "评测版本：$(for b in "${bins[@]}"; do printf '%s ' "$(basename "$b")"; done)"
    bash "$EX/common/bench.sh" run "$EX/results.md" "${bins[@]}"
}

target="${1:-all}"
case "$target" in
    all)
        check_tools cargo llvm-profdata curl perf hyperfine llvm-bolt cargo-pgo
        run_case pgo; run_case bolt; run_case cargo-pgo; stage evaluate evaluate ;;
    pgo)
        check_tools cargo llvm-profdata curl
        run_case pgo ;;
    bolt)
        check_tools cargo llvm-profdata curl llvm-bolt
        ensure_pgo; run_case bolt ;;
    cargo-pgo)
        check_tools cargo llvm-profdata curl llvm-bolt cargo-pgo
        ensure_pgo; run_case cargo-pgo ;;
    evaluate)
        check_tools perf hyperfine
        stage evaluate evaluate ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
esac

echo; echo "################ 完成 ################"
printf '  %s\n' "${TIMES[@]}"
echo "  产物：$BIN"
[ -f "$EX/results.md" ] && echo "  评测结果：$EX/results.md"
true
