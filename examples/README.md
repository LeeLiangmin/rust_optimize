# 实践案例

本目录为 [GUIDE.md](../GUIDE.md) 第 7 章实践案例的脚本、评测结果和实验对象源码。案例说明、各步骤的结果和优化效果见第 7 章，负载与评测方法见本文[最后一节](#负载与评测方法)。

| 目录 | 内容 | 手册中的说明 |
|:---|:---|:---|
| [`pgo/`](pgo/) | `run.sh` 构建普通版与 PGO 版并评测，结果写入 `results.md` | [7.2 节](../GUIDE.md#72-pgo-优化方法) |
| [`bolt/`](bolt/) | `run.sh` 构建 BOLT 版（插桩、采样）与 PGO + BOLT 版并评测，结果写入 `results.md` | [7.3 节](../GUIDE.md#73-bolt-优化方法) |
| [`cargo-pgo/`](cargo-pgo/) | `run.sh` 用 cargo-pgo 完成 PGO 与 PGO + BOLT | [7.4 节](../GUIDE.md#74-cargo-pgo-优化方法) |
| [`common/`](common/) | `workload.sh`（语料下载、训练负载）、`bench.sh`（评测） | [负载与评测方法](#负载与评测方法) |
| [`subjects/`](subjects/) | 实验对象 ripgrep 14.1.1 的源码 | [subjects/README.md](subjects/README.md) |
| `work/` | 运行时生成的语料、构建缓存、可执行文件和 profile，不纳入版本控制 | — |

运行顺序和环境要求见 [GUIDE.md 7.1 节](../GUIDE.md#71-案例说明)。

## 负载与评测方法

训练负载用于采集 profile，由 [`common/workload.sh`](common/workload.sh) 执行 9 条搜索，覆盖字面量、忽略大小写、整词匹配、带字面量后缀的正则、多选一、无长字面量的正则、计数、固定字符串和仅遍历目录。PGO 和 BOLT 使用同一套训练负载。

评测由 [`common/bench.sh`](common/bench.sh) 执行，使用与训练负载不重复的 7 个用例（取自 ripgrep 作者基准集中的 linux_* 系列），检验优化效果能否推广到训练中未出现的输入：

| 用例 | 命令 |
|:---|:---|
| literal | `rg PM_RESUME` |
| literal_casei | `rg -i PM_RESUME` |
| word | `rg -w PM_RESUME` |
| unicode_word | `rg '\wAh'` |
| re_literal_suffix | `rg '[A-Z]+_RESUME'` |
| alternates | `rg 'ERR_SYS\|PME_TURN_OFF\|LINK_REQ_RST\|CFG_BME_EVT'` |
| no_literal | `rg '\w{5}\s+\w{5}\s+\w{5}\s+\w{5}\s+\w{5}'` |

每个用例先比较各版本排序后输出的 sha256，不一致则报错退出；再以 `hyperfine --warmup 3 --runs 50` 测量墙钟时间，以 `perf stat -r 5` 测量用户态的 cycles、指令数、L1 i-cache 未命中和 iTLB 未命中。评测以用户态硬件计数器为主要指标：以 literal 为例，普通版的 CPU 时间为 User 974 ms、System 1343 ms，约 58% 为内核态（读文件、遍历目录），而 PGO 和 BOLT 只作用于用户态代码。
