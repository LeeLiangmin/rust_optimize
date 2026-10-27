# 评测结果

- CPU：Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz，12 线程
- 系统：6.18.54.1-microsoft-standard-WSL2
- 编译器：rustc 1.93.1 (01f6ddf75 2026-02-11)
- 语料：Linux 6.6 源码，81,703 个文件，已在页缓存中
- 耗时：hyperfine --warmup 3 --runs 50，均值 ± 标准差
- 计数器：perf stat -r 5，仅统计用户态（:u）
- 变化：相对第一行（基线），负数表示减少

## literal：`rg PM_RESUME`

| 版本 | 耗时 (ms) | cycles | instructions | L1 i-cache miss | iTLB miss |
|:---|---:|---:|---:|---:|---:|
| rg-base | 190.0 ± 9.9 | 1.77 G | 1.42 G | 45.8 M | 253 K |
| rg-pgo | 189.6 ± 13.0 (-0.2%) | 1.55 G (-12.4%) | 1.31 G (-7.3%) | 30.4 M (-33.6%) | 181 K (-28.3%) |

## literal_casei：`rg -i PM_RESUME`

| 版本 | 耗时 (ms) | cycles | instructions | L1 i-cache miss | iTLB miss |
|:---|---:|---:|---:|---:|---:|
| rg-base | 207.7 ± 7.5 | 2.53 G | 2.54 G | 49.1 M | 256 K |
| rg-pgo | 203.1 ± 10.9 (-2.2%) | 2.27 G (-10.5%) | 2.43 G (-4.2%) | 33.1 M (-32.6%) | 195 K (-23.8%) |

## word：`rg -w PM_RESUME`

| 版本 | 耗时 (ms) | cycles | instructions | L1 i-cache miss | iTLB miss |
|:---|---:|---:|---:|---:|---:|
| rg-base | 191.6 ± 14.5 | 1.81 G | 1.42 G | 46.6 M | 259 K |
| rg-pgo | 185.2 ± 8.3 (-3.3%) | 1.63 G (-10.0%) | 1.31 G (-7.3%) | 31.4 M (-32.8%) | 184 K (-29.0%) |

## unicode_word：`rg \wAh`

| 版本 | 耗时 (ms) | cycles | instructions | L1 i-cache miss | iTLB miss |
|:---|---:|---:|---:|---:|---:|
| rg-base | 200.4 ± 16.4 | 1.80 G | 1.44 G | 47.5 M | 239 K |
| rg-pgo | 194.1 ± 20.3 (-3.1%) | 1.61 G (-10.5%) | 1.37 G (-5.0%) | 31.4 M (-34.0%) | 166 K (-30.5%) |

## re_literal_suffix：`rg [A-Z]+_RESUME`

| 版本 | 耗时 (ms) | cycles | instructions | L1 i-cache miss | iTLB miss |
|:---|---:|---:|---:|---:|---:|
| rg-base | 189.7 ± 9.7 | 1.81 G | 1.43 G | 47.9 M | 285 K |
| rg-pgo | 179.2 ± 3.6 (-5.5%) | 1.61 G (-10.6%) | 1.32 G (-7.3%) | 31.4 M (-34.4%) | 197 K (-31.1%) |

## alternates：`rg ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT`

| 版本 | 耗时 (ms) | cycles | instructions | L1 i-cache miss | iTLB miss |
|:---|---:|---:|---:|---:|---:|
| rg-base | 196.9 ± 5.3 | 2.57 G | 2.59 G | 46.4 M | 216 K |
| rg-pgo | 192.3 ± 5.3 (-2.3%) | 2.31 G (-10.3%) | 2.48 G (-4.2%) | 30.6 M (-34.1%) | 163 K (-24.5%) |

## no_literal：`rg \w{5}\s+\w{5}\s+\w{5}\s+\w{5}\s+\w{5}`

| 版本 | 耗时 (ms) | cycles | instructions | L1 i-cache miss | iTLB miss |
|:---|---:|---:|---:|---:|---:|
| rg-base | 397.6 ± 9.6 | 10.03 G | 11.57 G | 47.0 M | 293 K |
| rg-pgo | 403.1 ± 21.0 (+1.4%) | 9.88 G (-1.5%) | 11.50 G (-0.6%) | 31.5 M (-33.0%) | 175 K (-40.4%) |
