#!/usr/bin/env bash
# 评测：7 个评测用例，取自 ripgrep 作者的基准集（linux_* 系列），与训练负载不重复。
#   bench.sh check <rg>...            只校验各版本在 7 个用例上的输出一致（排序后 sha256）
#   bench.sh run <结果.md> <rg>...     校验输出，再测墙钟时间（hyperfine）和用户态硬件计数器
#                                      （perf stat），第一个 rg 为基线，结果写入 Markdown
set -euo pipefail
EX=$(cd "$(dirname "$0")/.." && pwd)             # examples/
WORK=$(realpath -m "${WORK_DIR:-$EX/work}")
CORPUS="$WORK/linux-6.6"
EVENTS="cycles:u,instructions:u,L1-icache-load-misses:u,iTLB-load-misses:u"

# 每个用例：名称 + rg 参数（模式中无空格，可按空格拆分）
CASES=(
    "literal           PM_RESUME"
    "literal_casei     -i PM_RESUME"
    "word              -w PM_RESUME"
    "unicode_word      \\wAh"
    "re_literal_suffix [A-Z]+_RESUME"
    "alternates        ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT"
    "no_literal        \\w{5}\\s+\\w{5}\\s+\\w{5}\\s+\\w{5}\\s+\\w{5}"
)

# 各版本的来源，写入结果文件的版本说明表
declare -A ORIGIN=(
    [rg-base]="普通 release 构建（pgo 案例步骤 1）"
    [rg-pgo]="PGO 优化构建（pgo 案例步骤 4）"
    [rg-bolt]="带重定位构建 + BOLT，插桩 profile（bolt 案例步骤 3）"
    [rg-bolt-perf]="带重定位构建 + BOLT，采样 profile（bolt 案例步骤 3）"
    [rg-pgo-bolt]="PGO 优化构建 + BOLT，插桩 profile（bolt 案例“与 PGO 叠加”）"
    [rg-cargo-pgo]="cargo pgo optimize（cargo-pgo 案例步骤 3）"
    [rg-cargo-pgo-bolt]="cargo pgo bolt optimize --with-pgo（cargo-pgo 案例步骤 6）"
)

# 校验各版本在一个用例上的输出一致
check_case() {
    local name="$1"; shift
    local -n args="$1"; shift
    local ref="" sum rg
    for rg in "$@"; do
        sum=$("$rg" "${args[@]}" "$CORPUS" | sort | sha256sum | cut -c1-16)
        ref="${ref:-$sum}"
        [ "$sum" = "$ref" ] || { echo "输出不一致：$(basename "$rg")（$name）" >&2; exit 1; }
    done
    printf '  %-18s 输出一致（%s）\n' "$name" "$ref"
}

mode="${1:-}"; shift || true
case "$mode" in
    check)
        for c in "${CASES[@]}"; do
            read -r name argv_str <<< "$c"; read -r -a argv <<< "$argv_str"
            check_case "$name" argv "$@"
        done
        exit 0 ;;
    run) OUT="$1"; shift ;;
    *) echo "用法：bench.sh check <rg>... | bench.sh run <结果.md> <rg>..." >&2; exit 1 ;;
esac

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
: > "$TMP/data.csv"                     # 用例,版本,指标,数值
for c in "${CASES[@]}"; do
    read -r name argv_str <<< "$c"; read -r -a argv <<< "$argv_str"
    check_case "$name" argv "$@"

    cmds=()
    for rg in "$@"; do cmds+=(-n "$(basename "$rg")" "$rg $(printf '%q ' "${argv[@]}") $CORPUS"); done
    hyperfine --warmup 3 --runs 50 -N --style none --export-csv "$TMP/time.csv" "${cmds[@]}" \
        > /dev/null 2> "$TMP/hyperfine.err" || { cat "$TMP/hyperfine.err" >&2; exit 1; }
    awk -F, -v c="$name" 'FNR>1 {print c","$1",time,"$2*1000; print c","$1",sd,"$3*1000}' "$TMP/time.csv" >> "$TMP/data.csv"

    for rg in "$@"; do
        perf stat -r 5 -x, -e "$EVENTS" -o "$TMP/one.csv" -- "$rg" "${argv[@]}" "$CORPUS" > /dev/null
        awk -F, -v c="$name" -v b="$(basename "$rg")" \
            'NF>3 && $1 ~ /^[0-9]/ {sub(/:u$/, "", $3); print c","b","$3","$1}' "$TMP/one.csv" >> "$TMP/data.csv"
    done
done

versions=(); for rg in "$@"; do versions+=("$(basename "$rg")"); done
cases=(); for c in "${CASES[@]}"; do read -r name _ <<< "$c"; cases+=("$name"); done
cmdline=(); for c in "${CASES[@]}"; do read -r name argv_str <<< "$c"; cmdline+=("$name=rg $argv_str"); done

mkdir -p "$(dirname "$OUT")"
{
    echo "# 评测结果"
    echo
    echo "本文件由 \`examples/run.sh evaluate\` 生成。所有版本在同一次运行中评测，相对第一个版本（基线）计算变化，负数表示减少。"
    echo
    echo "## 运行信息"
    echo
    echo "| 项目 | 内容 |"
    echo "|:---|:---|"
    echo "| 日期 | $(date +%F) |"
    echo "| 仓库 commit | $(git -C "$EX" rev-parse --short HEAD 2>/dev/null || echo 未知) |"
    echo "| CPU | $(lscpu | sed -n 's/^Model name: *//p')，$(nproc) 线程 |"
    echo "| 内核 | $(uname -r) |"
    echo "| rustc | $(rustc -V) |"
    echo "| BOLT | $(llvm-bolt --version 2>/dev/null | sed -n 's/.*LLVM version //p' | head -1 || true) |"
    echo "| cargo-pgo | $(cargo install --list 2>/dev/null | sed -n 's/^cargo-pgo v\([^:]*\):.*/\1/p') |"
    echo "| 语料 | Linux 6.6 源码，81,703 个文件，已在页缓存中 |"
    echo "| 墙钟时间 | hyperfine --warmup 3 --runs 50，均值 ± 标准差 |"
    echo "| 计数器 | perf stat -r 5，仅统计用户态（:u） |"
    echo
    echo "## 版本"
    echo
    echo "| 版本 | 来源 |"
    echo "|:---|:---|"
    for v in "${versions[@]}"; do echo "| \`$v\` | ${ORIGIN[$v]:-—} |"; done
} > "$OUT"

# 汇总表与逐用例原始数据
CMDS="$(IFS=$'\t'; echo "${cmdline[*]}")" awk -F, -v vers="${versions[*]}" -v cases="${cases[*]}" '
    { v[$1, $2, $3] = $4 }
    function num(x) {
        if (x >= 1e9) return sprintf("%.2f G", x/1e9)
        if (x >= 1e6) return sprintf("%.1f M", x/1e6)
        return sprintf("%.0f K", x/1e3)
    }
    function pct(x, b) { s = sprintf("%+.1f%%", (x-b)/b*100); sub(/^-/, "−", s); return s }
    function summary(title, m,    i, j, line) {
        print ""; print "### " title; print ""
        line = "| 用例"; for (j=2; j<=nv; j++) line = line " | `" V[j] "`"; print line " |"
        line = "|:---"; for (j=2; j<=nv; j++) line = line "|---:"; print line "|"
        for (i=1; i<=nc; i++) {
            line = "| " C[i]
            for (j=2; j<=nv; j++) line = line " | " pct(v[C[i],V[j],m], v[C[i],V[1],m])
            print line " |"
        }
    }
    END {
        nv = split(vers, V, " "); nc = split(cases, C, " "); split(ENVIRON["CMDS"], CMD, "\t")
        print ""; print "## 汇总"
        print ""; print "各单元格为相对 `" V[1] "` 的变化。"
        summary("用户态 cycles", "cycles")
        summary("用户态指令数", "instructions")
        summary("L1 i-cache 未命中", "L1-icache-load-misses")
        summary("iTLB 未命中", "iTLB-load-misses")
        summary("墙钟时间", "time")
        print ""; print "## 逐用例数据"
        for (i=1; i<=nc; i++) {
            c = C[i]; sub(/^[^=]*=/, "", CMD[i])
            print ""; print "### " c "：`" CMD[i] "`"; print ""
            print "| 版本 | 耗时 (ms) | cycles | instructions | L1 i-cache miss | iTLB miss |"
            print "|:---|---:|---:|---:|---:|---:|"
            for (j=1; j<=nv; j++) {
                k = V[j]
                t = sprintf("%.1f ± %.1f", v[c,k,"time"], v[c,k,"sd"])
                line = "| `" k "` | " t
                split("cycles instructions L1-icache-load-misses iTLB-load-misses", ev, " ")
                for (e=1; e<=4; e++) {
                    x = v[c,k,ev[e]]
                    line = line " | " num(x) (j>1 ? " (" pct(x, v[c,V[1],ev[e]]) ")" : "")
                }
                print line " |"
            }
        }
    }' "$TMP/data.csv" >> "$OUT"
echo "  结果写入 $OUT"
