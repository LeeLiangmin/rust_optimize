#!/usr/bin/env bash
# 评测：校验各版本输出一致 → hyperfine 测墙钟时间 → perf stat 测用户态硬件计数器。
# 模式取自 ripgrep 作者的 benchsuite（linux_* 系列），与 train.sh 的训练模式不同。
# 用法：bench.sh <结果文件.md> <rg-基线> <rg-对比1> ...
source "$(dirname "$0")/env.sh"
OUT="$1"; shift
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
EVENTS="cycles:u,instructions:u,L1-icache-load-misses:u,iTLB-load-misses:u"

# 每个用例：名称 + rg 参数（模式中无空格，可按空格拆分）
CASES=(
    "literal          PM_RESUME"
    "literal_casei    -i PM_RESUME"
    "word             -w PM_RESUME"
    "unicode_word     \\wAh"
    "re_literal_suffix [A-Z]+_RESUME"
    "alternates       ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT"
    "no_literal       \\w{5}\\s+\\w{5}\\s+\\w{5}\\s+\\w{5}\\s+\\w{5}"
)

{
    echo "# 评测结果"
    echo
    echo "- CPU：$(lscpu | sed -n 's/^Model name: *//p')，$(nproc) 线程"
    echo "- 系统：$(uname -r)"
    echo "- 编译器：$(rustc -V)"
    echo "- 语料：Linux 6.6 源码，81,703 个文件，已在页缓存中"
    echo "- 耗时：hyperfine --warmup 3 --runs 50，均值 ± 标准差"
    echo "- 计数器：perf stat -r 5，仅统计用户态（:u）"
    echo "- 变化：相对第一行（基线），负数表示减少"
} > "$OUT"

for c in "${CASES[@]}"; do
    read -r name argv_str <<< "$c"
    read -r -a argv <<< "$argv_str"
    echo "==> $name"

    # 1. 正确性：各版本输出（排序后）必须一致
    ref=""
    for rg in "$@"; do
        sum=$("$rg" "${argv[@]}" "$CORPUS" | sort | sha256sum)
        ref="${ref:-$sum}"
        [ "$sum" = "$ref" ] || { echo "输出不一致：$rg ($name)"; exit 1; }
    done

    # 2. 墙钟时间
    cmds=()
    for rg in "$@"; do cmds+=(-n "$(basename "$rg")" "$rg $(printf '%q ' "${argv[@]}") $CORPUS"); done
    hyperfine --warmup 3 --runs 50 -N --style none --export-csv "$TMP/time.csv" "${cmds[@]}"

    # 3. 用户态硬件计数器
    : > "$TMP/perf.csv"
    for rg in "$@"; do
        perf stat -r 5 -x, -e "$EVENTS" -o "$TMP/one.csv" -- "$rg" "${argv[@]}" "$CORPUS" > /dev/null
        awk -F, -v b="$(basename "$rg")" 'NF>3 && $1 ~ /^[0-9]/ {print b","$3","$1}' "$TMP/one.csv" >> "$TMP/perf.csv"
    done

    # 4. 汇总成一张表
    {
        echo
        echo "## $name：\`rg ${argv[*]}\`"
        echo
        echo "| 版本 | 耗时 (ms) | cycles | instructions | L1 i-cache miss | iTLB miss |"
        echo "|:---|---:|---:|---:|---:|---:|"
        awk -F, '
            NR==FNR { if (FNR>1) { order[++n]=$1; mean[$1]=$2*1000; sd[$1]=$3*1000 } next }
            { sub(/:u$/, "", $2); v[$1,$2]=$3 }
            function num(x) {
                if (x >= 1e9) return sprintf("%.2f G", x/1e9)
                if (x >= 1e6) return sprintf("%.1f M", x/1e6)
                return sprintf("%.0f K", x/1e3)
            }
            function cell(x, base, first) {
                if (first) return num(x)
                return sprintf("%s (%+.1f%%)", num(x), (x-base)/base*100)
            }
            END {
                split("cycles instructions L1-icache-load-misses iTLB-load-misses", ev, " ")
                b=order[1]
                for (i=1; i<=n; i++) {
                    k=order[i]
                    t = (i==1) ? sprintf("%.1f ± %.1f", mean[k], sd[k]) \
                               : sprintf("%.1f ± %.1f (%+.1f%%)", mean[k], sd[k], (mean[k]-mean[b])/mean[b]*100)
                    line = "| " k " | " t
                    for (j=1; j<=4; j++) line = line " | " cell(v[k,ev[j]], v[b,ev[j]], i==1)
                    print line " |"
                }
            }' "$TMP/time.csv" "$TMP/perf.csv"
    } >> "$OUT"
done
echo "结果写入 $OUT"
