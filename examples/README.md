# 实践案例

本目录在 ripgrep 14.1.1 上按 [GUIDE.md](../GUIDE.md) 的步骤完成 PGO、BOLT 和 cargo-pgo 三个案例，并在同一次运行中评测全部优化版本，结果写入 [`results.md`](results.md)。ripgrep 是用 Rust 编写的命令行文本搜索工具，源码未做修改，来源和许可证见 [subjects/README.md](subjects/README.md)。

## 一键运行

在仓库根目录执行：

```bash
bash examples/run.sh              # 依次运行三个案例并统一评测，测试环境下约 20 分钟
```

也可以只运行其中一项：

```bash
bash examples/run.sh pgo          # PGO 案例
bash examples/run.sh bolt         # BOLT 案例；缺少 pgo 案例的产物时先运行 pgo
bash examples/run.sh cargo-pgo    # cargo-pgo 案例；缺少 pgo 案例的产物时先运行 pgo
bash examples/run.sh evaluate     # 评测 work/bin/ 中已有的版本，重新生成 results.md
```

`run.sh` 开始前检查所需工具，缺少时列出安装方法后退出：

- Linux（x86_64 或 AArch64），rustup 工具链及 `llvm-tools-preview` 组件，`curl`（首次运行下载语料）。
- BOLT 工具 `llvm-bolt`、`merge-fdata`、`perf2bolt`，18 及以上版本，位于 `PATH` 中；采样采集需要 CPU 支持 LBR，不支持时跳过该方式。
- `cargo-pgo`（`cargo install cargo-pgo`）。
- 评测使用 `perf`（需能读取硬件计数器）和 `hyperfine`。

语料和构建产物约占 4 GB，默认写入 `examples/work/`，可通过环境变量 `WORK_DIR` 修改。在 WSL 中，仓库或 `WORK_DIR` 应位于 Linux 文件系统内，否则文件共享的 I/O 开销会影响测量结果。

## 案例一览

| 案例 | 做什么 | 生成的版本 | 依赖 | 耗时 |
|:---|:---|:---|:---|---:|
| [pgo](#pgo-案例) | 按 GUIDE 2.3 节完成插桩构建、采集、合并和 PGO 优化构建 | `rg-base`、`rg-pgo` | — | 188 秒（含下载语料） |
| [bolt](#bolt-案例) | 按 GUIDE 4.4 节以插桩、采样两种方式采集 profile 并优化；按第 5 章在 PGO 版上叠加 BOLT | `rg-bolt`、`rg-bolt-perf`、`rg-pgo-bolt` | pgo 案例的 PGO profile | 107 秒 |
| [cargo-pgo](#cargo-pgo-案例) | 按 GUIDE 第 6 章用 cargo-pgo 完成 PGO 和 PGO + BOLT | `rg-cargo-pgo`、`rg-cargo-pgo-bolt` | pgo 案例的 `rg-base`（输出对照） | 129 秒 |
| [evaluate](#评测) | 对以上 7 个版本运行 7 个评测用例，生成 `results.md` | — | 以上案例的产物 | 723 秒 |

每个案例的最后一步校验本案例的版本与 `rg-base` 在 7 个评测用例上的输出一致；性能评测统一由 evaluate 完成，所有版本的数据来自同一次运行，可以直接比较。

以下各案例的实际结果来自测试环境中的一次完整运行：Intel Core i7-9750H（支持 LBR），WSL2 Ubuntu 24.04，rustc 1.93.1（LLVM 21.1.8），BOLT 21.1.8，cargo-pgo 0.3.0。

## PGO 案例

脚本 [`pgo/run.sh`](pgo/run.sh) 按 GUIDE 2.3 节的步骤对 ripgrep 应用 PGO：用 9 条训练搜索采集 profile，重新编译得到 PGO 版。

| 步骤 | 操作 | 实际结果 |
|:---|:---|:---|
| 0. 准备环境 | 检查 `llvm-profdata`，下载语料 | `llvm-profdata` 的 LLVM 版本为 21.1.8，与 rustc 一致 |
| 1. 插桩构建 | 普通构建得到 `rg-base`；以 `-Cprofile-generate` 构建得到 `rg-instr` | `rg-base` 27.4 MB，`rg-instr` 31.8 MB，增加部分为计数器和写出 profile 的运行时代码 |
| 2. 采集 | 以 `rg-instr` 执行 9 条训练搜索 | 生成 1 个 `.profraw`（1.9 MB）：默认文件名不含进程号，各次运行的计数累加在同一文件中 |
| 3. 合并 | `llvm-profdata merge` | `merged.profdata` 3.2 MB，`Total count: 2278347512`，非零表示 profile 有效 |
| 4. 优化构建 | 以 `-Cprofile-use` 和 `-pgo-warn-missing-function` 重新构建 | 缺少 profile 的函数告警 0 条，profile 与源码匹配；`rg-pgo` 25.1 MB，小于普通版 |
| 5. 验证 | `bench.sh check rg-base rg-pgo` | 7 个用例的输出一致 |

在 7 个评测用例中，`rg-pgo` 的用户态 cycles 减少 2.8%–11.9%，指令数在 6 个用例中减少 5.3%–8.3%，L1 i-cache 未命中减少 28.3%–37.3%。完整数据见 [`results.md`](results.md)，分析见[结果](#结果)。

## BOLT 案例

脚本 [`bolt/run.sh`](bolt/run.sh) 按 GUIDE 4.4 节的步骤对 ripgrep 应用 BOLT，分别以插桩和采样方式采集 profile；再按第 5 章在 PGO 版上叠加 BOLT，使用 pgo 案例的 PGO profile。

| 步骤 | 操作 | 实际结果 |
|:---|:---|:---|
| 0. 准备环境 | 检查 `llvm-bolt` 版本 | 21，满足 18 及以上的要求 |
| 1. 带重定位构建 | 以 `-Clink-args=-Wl,-q` 构建得到 `rg-reloc` | 52.1 MB，包含 `.rela.text`；增加部分为重定位信息，不改变代码，性能对比仍以 `rg-base` 为基线 |
| 2a. 插桩采集 | `llvm-bolt -instrument` 生成 `rg.inst`，执行 9 条训练搜索，`merge-fdata` 合并 | `rg.inst` 26.2 MB；9 次运行生成 9 个 `.fdata` |
| 2b. 采样采集 | 以 `rg-reloc` 执行训练搜索，`perf record -j any,u` 采样，`perf2bolt` 转换 | 采集 84,942 个样本，读取 2,706,739 条 LBR 记录；采样对 `rg-reloc` 本身进行，不需要插桩版 |
| 3. 优化 | 以两份 profile 分别优化 `rg-reloc`，得到 `rg-bolt`、`rg-bolt-perf` | 插桩 profile 覆盖 17.4% 的函数，taken branches −42.0%；采样 profile 覆盖 8.3% 的函数，taken branches −45.8%；产物 12.3–12.4 MB，BOLT 默认丢弃调试信息 |
| 与 PGO 叠加 | 以 PGO profile 和 `-Wl,-q` 构建 `rg-pgo-reloc`（46.8 MB），重复步骤 2a、3 | 覆盖 15.7% 的函数，taken branches −12.6%，降幅小于单独使用 BOLT，因为 PGO 已调整过基本块布局；`rg-pgo-bolt` 12.5 MB |
| 4. 验证 | `bench.sh check` 比较五个版本 | 7 个用例的输出一致 |

`taken branches` 为 BOLT 在各自 profile 上统计的跳转次数，各行不能相互比较。采样只能捕获执行足够频繁的代码，覆盖率约为插桩方式的一半。

在 7 个评测用例中，`rg-bolt` 的指令数变化不超过 2.7%，L1 i-cache 未命中减少 49.5%–53.2%；`rg-pgo-bolt` 的用户态 cycles 减少 3.1%–14.9%。分析见[结果](#结果)。

## cargo-pgo 案例

脚本 [`cargo-pgo/run.sh`](cargo-pgo/run.sh) 按 GUIDE 第 6 章用 cargo-pgo 完成 PGO 以及 PGO + BOLT，命令在 `subjects/ripgrep/` 下执行，Cargo 目标目录为 `work/target/cargo-pgo`。

| 步骤 | 操作 | 实际结果 |
|:---|:---|:---|
| 0. 准备环境 | `cargo pgo info` | 找到 `llvm-profdata`、`llvm-bolt`、`merge-fdata` |
| 1–3. PGO | `cargo pgo build`，执行训练搜索，`cargo pgo optimize` | 合并 1 个 1.81 MiB 的 profile；`rg-cargo-pgo` 25.6 MB |
| 4–6. PGO + BOLT | `cargo pgo bolt build --with-pgo`，执行训练搜索，`cargo pgo bolt optimize --with-pgo` | `rg-cargo-pgo-bolt` 29.1 MB；与手动流程不同，产物保留了调试信息段（`.debug_*`） |
| 7. 验证 | `bench.sh check rg-base rg-cargo-pgo rg-cargo-pgo-bolt` | 7 个用例的输出一致 |

cargo-pgo 的两个产物与手动流程的对应版本效果接近：`rg-cargo-pgo` 的 cycles 在 6 个用例中减少 9.0%–11.5%（`rg-pgo` 为 9.9%–11.9%），`rg-cargo-pgo-bolt` 减少 11.3%–14.7%（`rg-pgo-bolt` 为 11.2%–14.9%）。分析见[结果](#结果)。

## 评测

### 负载与评测方法

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

每个用例先比较各版本排序后输出的 sha256，不一致则报错退出；再以 `hyperfine --warmup 3 --runs 50` 测量墙钟时间，以 `perf stat -r 5` 测量用户态的 cycles、指令数、L1 i-cache 未命中和 iTLB 未命中。评测以用户态硬件计数器为主要指标：以 literal 为例，`rg-base` 的 CPU 时间中用户态和内核态（读文件、遍历目录）各约 1.1 s，而 PGO 和 BOLT 只作用于用户态代码。

### 结果

[`results.md`](results.md) 依次包含运行信息、各版本的来源、汇总表（cycles、指令数、L1 i-cache 未命中、iTLB 未命中、墙钟时间，均为相对 `rg-base` 的变化）和逐用例的原始数据。用户态 cycles 的变化：

| 用例 | `rg-pgo` | `rg-bolt` | `rg-bolt-perf` | `rg-pgo-bolt` | `rg-cargo-pgo` | `rg-cargo-pgo-bolt` |
|:---|---:|---:|---:|---:|---:|---:|
| literal | −11.9% | −7.9% | −10.2% | −14.9% | −10.0% | −14.7% |
| literal_casei | −11.2% | −4.8% | −8.8% | −11.2% | −11.5% | −12.7% |
| word | −9.9% | −11.2% | −8.5% | −13.3% | −9.0% | −12.8% |
| unicode_word | −10.6% | −7.7% | −10.3% | −13.3% | −9.1% | −12.0% |
| re_literal_suffix | −10.2% | −10.0% | −8.8% | −13.2% | −9.2% | −11.8% |
| alternates | −10.9% | −5.7% | −8.3% | −11.6% | −9.4% | −11.3% |
| no_literal | −2.8% | −3.1% | −1.8% | −3.1% | −2.6% | −3.3% |

主要结论：

- PGO 主要减少执行的指令数：6 个用例中指令数减少 5.3%–8.3%，L1 i-cache 未命中减少约三分之一。
- BOLT 几乎不改变指令数（6 个用例中变化不超过 2.8%），L1 i-cache 未命中减少约一半，与其只改变代码布局的原理一致；插桩与采样两种 profile 的 i-cache 降幅接近。
- 每个用例中 cycles 降幅最大的都是 PGO + BOLT 版本（手动流程或 cargo-pgo），除 no_literal 外 cycles 减少 11.6%–14.9%。
- no_literal 的耗时集中在正则引擎的一个小循环内，各版本的 cycles 变化不超过 3.3%。该用例中手动流程的 PGO 版指令数增加 9.8%，cargo-pgo 的 PGO 版减少 1.2%，原因未分析。
- 墙钟时间的变化方向不一致，幅度与测量的标准差处于同一量级（如 literal 中 `rg-base` 为 221.0 ± 16.9 ms），不能据此判断端到端性能。

## 用于其他 Rust 程序

替换实验对象时需要修改：

- 各案例 `run.sh` 中的源码路径（`--manifest-path` 和 `SRC`）及可执行文件名 `rg`。
- [`common/workload.sh`](common/workload.sh)：语料的下载（`corpus`）和训练负载（`train`）。
- [`common/bench.sh`](common/bench.sh)：评测用例（`CASES`）和版本说明（`ORIGIN`）。

## 产物

产物位于 `examples/work/`：

| 路径 | 内容 |
|:---|:---|
| `linux-6.6/` | 语料（Linux 6.6 源码，81,703 个文件，1.5 GB） |
| `bin/` | 各版本的可执行文件，见下表 |
| `pgo-data/` | PGO profile：`*.profraw` 和合并后的 `merged.profdata` |
| `bolt-data/` | BOLT profile：`instr/`（插桩）、`perf/`（采样）、`pgo-instr/`（PGO 版上的插桩） |
| `target/` | 各次构建的 Cargo 目标目录（`base`、`instr`、`pgo`、`reloc`、`pgo-reloc`、`cargo-pgo`） |
| `pgo-build.log` | PGO 优化构建的日志，用于统计缺少 profile 的函数告警 |

| 可执行文件 | 来源 | 是否评测 |
|:---|:---|:---|
| `rg-base` | 普通 release 构建 | 是（基线） |
| `rg-instr` | PGO 插桩版 | 否 |
| `rg-pgo` | PGO 优化构建 | 是 |
| `rg-reloc` | 带重定位的普通构建，BOLT 的输入 | 否 |
| `rg-bolt`、`rg-bolt-perf` | 对 `rg-reloc` 执行 BOLT，分别使用插桩、采样 profile | 是 |
| `rg-pgo-reloc` | 带重定位的 PGO 优化构建，叠加 BOLT 的输入 | 否 |
| `rg-pgo-bolt` | 对 `rg-pgo-reloc` 执行 BOLT | 是 |
| `rg-cargo-pgo`、`rg-cargo-pgo-bolt` | cargo-pgo 生成的 PGO 版、PGO + BOLT 版 | 是 |
