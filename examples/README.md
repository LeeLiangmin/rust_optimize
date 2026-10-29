# 实践案例

以 ripgrep 14.1.1 源码为实验对象（未修改，来源见 [subjects/README.md](subjects/README.md)），按 [GUIDE.md](../GUIDE.md) 完成 PGO、BOLT 和 cargo-pgo 三个案例，再在同一次运行中评测全部版本，结果写入 [`results.md`](results.md)。

## 运行

在仓库根目录执行：

```bash
bash examples/run.sh              # 全部案例 + 评测，测试环境下约 20 分钟
bash examples/run.sh pgo          # 只运行一项：pgo | bolt | cargo-pgo | evaluate
```

bolt、cargo-pgo 依赖 pgo 的产物，缺失时 `run.sh` 先运行 pgo。`run.sh` 开始前检查以下工具，缺少时给出安装方法：

- rustup 工具链及 `llvm-tools-preview` 组件、`curl`
- BOLT 工具 18 及以上版本（`llvm-bolt`、`merge-fdata`、`perf2bolt`），位于 `PATH` 中
- `cargo-pgo`
- `perf`（需能读取硬件计数器）、`hyperfine`

运行需要 Linux 和约 4 GB 磁盘空间。产物默认写入 `examples/work/`，可用环境变量 `WORK_DIR` 修改；在 WSL 中应放在 Linux 文件系统内。

## 案例

| 案例 | 内容 | 生成的版本 | 耗时 |
|:---|:---|:---|---:|
| [pgo](#pgo) | GUIDE 2.3 节：插桩构建、采集、合并、优化构建 | `rg-base`、`rg-pgo` | 188 秒 |
| [bolt](#bolt) | GUIDE 4.4 节：插桩、采样两种 profile；第 5 章：在 PGO 版上叠加 | `rg-bolt`、`rg-bolt-perf`、`rg-pgo-bolt` | 107 秒 |
| [cargo-pgo](#cargo-pgo) | GUIDE 第 6 章：用 cargo-pgo 完成 PGO 和 PGO + BOLT | `rg-cargo-pgo`、`rg-cargo-pgo-bolt` | 129 秒 |
| [evaluate](#评测) | 对以上 7 个版本运行 7 个评测用例 | `results.md` | 723 秒 |

各案例的最后一步只校验输出与 `rg-base` 一致；性能统一由 evaluate 测量，所有版本的数据可以直接比较。以下结果来自一次完整运行，环境为 Intel Core i7-9750H（支持 LBR）、WSL2 Ubuntu 24.04、rustc 1.93.1、BOLT 21.1.8、cargo-pgo 0.3.0。

### pgo

脚本：[`pgo/run.sh`](pgo/run.sh)

| 步骤 | 实际结果 |
|:---|:---|
| 0. 准备环境 | `llvm-profdata` 为 LLVM 21.1.8，与 rustc 一致 |
| 1. 插桩构建 | `rg-base` 27.4 MB；插桩版 `rg-instr` 31.8 MB |
| 2. 采集 | 9 条训练搜索生成 1 个 `.profraw`（1.9 MB），各次运行的计数累加在同一文件 |
| 3. 合并 | `Total count: 2278347512`，非零表示 profile 有效 |
| 4. 优化构建 | 缺少 profile 的函数告警 0 条；`rg-pgo` 25.1 MB |
| 5. 验证 | 7 个用例的输出一致 |

### bolt

脚本：[`bolt/run.sh`](bolt/run.sh)

| 步骤 | 实际结果 |
|:---|:---|
| 1. 带重定位构建 | `rg-reloc` 52.1 MB，包含 `.rela.text`；重定位信息不改变代码，基线仍为 `rg-base` |
| 2a. 插桩采集 | 9 次运行生成 9 个 `.fdata` 并合并 |
| 2b. 采样采集 | 84,942 个样本，2,706,739 条 LBR 记录 |
| 3. 优化 | 插桩 profile 覆盖 17.4% 的函数，taken branches −42.0%；采样 profile 覆盖 8.3%，−45.8%；产物约 12.4 MB（BOLT 默认丢弃调试信息） |
| 与 PGO 叠加 | 覆盖 15.7% 的函数，taken branches −12.6%，降幅较小是因为 PGO 已调整过基本块布局 |
| 4. 验证 | 5 个版本在 7 个用例上的输出一致 |

taken branches 基于各自的 profile 统计，各行之间不可比较。

### cargo-pgo

脚本：[`cargo-pgo/run.sh`](cargo-pgo/run.sh)

| 步骤 | 实际结果 |
|:---|:---|
| 0. 准备环境 | `cargo pgo info` 找到 `llvm-profdata`、`llvm-bolt`、`merge-fdata` |
| 1–3. PGO | 合并 1 个 1.81 MiB 的 profile；`rg-cargo-pgo` 25.6 MB |
| 4–6. PGO + BOLT | `rg-cargo-pgo-bolt` 29.1 MB，与手动流程不同，保留了调试信息段 |
| 7. 验证 | 7 个用例的输出一致 |

## 评测

训练负载（[`common/workload.sh`](common/workload.sh)）为 9 条搜索，覆盖字面量、忽略大小写、整词、正则、多选一、计数、固定字符串和仅遍历目录。评测（[`common/bench.sh`](common/bench.sh)）使用另外 7 个用例，取自 ripgrep 作者基准集的 linux_* 系列：

| 用例 | 命令 |
|:---|:---|
| literal | `rg PM_RESUME` |
| literal_casei | `rg -i PM_RESUME` |
| word | `rg -w PM_RESUME` |
| unicode_word | `rg '\wAh'` |
| re_literal_suffix | `rg '[A-Z]+_RESUME'` |
| alternates | `rg 'ERR_SYS\|PME_TURN_OFF\|LINK_REQ_RST\|CFG_BME_EVT'` |
| no_literal | `rg '\w{5}\s+\w{5}\s+\w{5}\s+\w{5}\s+\w{5}'` |

每个用例先校验各版本输出一致，再用 `hyperfine` 测墙钟时间、`perf stat` 测用户态计数器。主要指标为用户态计数器：`rg-base` 的 CPU 时间约一半在内核态（读文件、遍历目录），而 PGO 和 BOLT 只优化用户态代码。

用户态 cycles 相对 `rg-base` 的变化（其他指标见 [`results.md`](results.md)）：

| 用例 | `rg-pgo` | `rg-bolt` | `rg-bolt-perf` | `rg-pgo-bolt` | `rg-cargo-pgo` | `rg-cargo-pgo-bolt` |
|:---|---:|---:|---:|---:|---:|---:|
| literal | −11.9% | −7.9% | −10.2% | −14.9% | −10.0% | −14.7% |
| literal_casei | −11.2% | −4.8% | −8.8% | −11.2% | −11.5% | −12.7% |
| word | −9.9% | −11.2% | −8.5% | −13.3% | −9.0% | −12.8% |
| unicode_word | −10.6% | −7.7% | −10.3% | −13.3% | −9.1% | −12.0% |
| re_literal_suffix | −10.2% | −10.0% | −8.8% | −13.2% | −9.2% | −11.8% |
| alternates | −10.9% | −5.7% | −8.3% | −11.6% | −9.4% | −11.3% |
| no_literal | −2.8% | −3.1% | −1.8% | −3.1% | −2.6% | −3.3% |

- PGO 主要减少指令数（6 个用例中 −5.3%～−8.3%），L1 i-cache 未命中减少约三分之一。
- BOLT 几乎不改变指令数（不超过 2.8%），L1 i-cache 未命中减少约一半；插桩、采样两种 profile 的 i-cache 降幅接近。
- 每个用例中 cycles 降幅最大的都是 PGO + BOLT 版本；cargo-pgo 的两个版本与手动流程效果接近。
- no_literal 的耗时集中在正则引擎的一个小循环内，各版本 cycles 变化不超过 3.3%。
- 墙钟时间的变化与测量标准差同一量级（如 literal 中 `rg-base` 为 221.0 ± 16.9 ms），不能据此判断端到端性能。

## 产物

`examples/work/` 下：

| 路径 | 内容 |
|:---|:---|
| `linux-6.6/` | 语料，Linux 6.6 源码（81,703 个文件，1.5 GB），首次运行时下载 |
| `bin/` | 评测的 7 个版本，以及中间产物 `rg-instr`（PGO 插桩版）、`rg-reloc`、`rg-pgo-reloc`（带重定位，BOLT 的输入） |
| `pgo-data/`、`bolt-data/` | PGO 和 BOLT 的 profile |
| `target/` | 各次构建的 Cargo 目标目录 |

## 用于其他 Rust 程序

替换实验对象时修改：各案例 `run.sh` 中的源码路径和可执行文件名 `rg`；[`common/workload.sh`](common/workload.sh) 中的语料和训练负载；[`common/bench.sh`](common/bench.sh) 中的评测用例 `CASES`。
