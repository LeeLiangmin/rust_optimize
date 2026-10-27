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
| rg-base | 194.8 ± 8.9 | 1.82 G | 1.43 G | 46.2 M | 243 K |
| rg-pgo | 189.8 ± 14.6 (-2.6%) | 1.60 G (-11.9%) | 1.32 G (-7.4%) | 30.9 M (-33.0%) | 149 K (-38.5%) |

## literal_casei：`rg -i PM_RESUME`

| 版本 | 耗时 (ms) | cycles | instructions | L1 i-cache miss | iTLB miss |
|:---|---:|---:|---:|---:|---:|
| rg-base | 213.0 ± 9.6 | 2.57 G | 2.55 G | 50.9 M | 277 K |
| rg-pgo | 206.6 ± 10.9 (-3.0%) | 2.31 G (-10.3%) | 2.45 G (-4.2%) | 34.2 M (-32.8%) | 204 K (-26.6%) |

## word：`rg -w PM_RESUME`

| 版本 | 耗时 (ms) | cycles | instructions | L1 i-cache miss | iTLB miss |
|:---|---:|---:|---:|---:|---:|
| rg-base | 199.8 ± 11.0 | 1.80 G | 1.43 G | 45.5 M | 252 K |
| rg-pgo | 197.8 ± 18.8 (-1.0%) | 1.60 G (-11.2%) | 1.33 G (-7.4%) | 31.0 M (-31.8%) | 146 K (-42.1%) |

## unicode_word：`rg \wAh`

| 版本 | 耗时 (ms) | cycles | instructions | L1 i-cache miss | iTLB miss |
|:---|---:|---:|---:|---:|---:|
| rg-base | 204.6 ± 13.0 | 1.83 G | 1.45 G | 46.2 M | 267 K |
| rg-pgo | 197.5 ± 8.9 (-3.5%) | 1.64 G (-10.4%) | 1.38 G (-4.9%) | 32.5 M (-29.8%) | 187 K (-30.1%) |

## re_literal_suffix：`rg [A-Z]+_RESUME`

| 版本 | 耗时 (ms) | cycles | instructions | L1 i-cache miss | iTLB miss |
|:---|---:|---:|---:|---:|---:|
| rg-base | 213.0 ± 28.0 | 1.82 G | 1.44 G | 46.9 M | 269 K |
| rg-pgo | 201.3 ± 21.2 (-5.5%) | 1.65 G (-9.8%) | 1.34 G (-7.3%) | 32.6 M (-30.6%) | 172 K (-36.1%) |

## alternates：`rg ERR_SYS|PME_TURN_OFF|LINK_REQ_RST|CFG_BME_EVT`

| 版本 | 耗时 (ms) | cycles | instructions | L1 i-cache miss | iTLB miss |
|:---|---:|---:|---:|---:|---:|
| rg-base | 232.4 ± 29.9 | 2.62 G | 2.61 G | 48.3 M | 268 K |
| rg-pgo | 204.9 ± 5.0 (-11.8%) | 2.29 G (-12.5%) | 2.50 G (-4.2%) | 31.8 M (-34.1%) | 172 K (-35.8%) |

## no_literal：`rg \w{5}\s+\w{5}\s+\w{5}\s+\w{5}\s+\w{5}`

| 版本 | 耗时 (ms) | cycles | instructions | L1 i-cache miss | iTLB miss |
|:---|---:|---:|---:|---:|---:|
| rg-base | 438.5 ± 40.0 | 10.09 G | 11.58 G | 48.8 M | 321 K |
| rg-pgo | 420.8 ± 20.2 (-4.0%) | 9.94 G (-1.5%) | 12.87 G (+11.1%) | 33.7 M (-30.9%) | 185 K (-42.3%) |
