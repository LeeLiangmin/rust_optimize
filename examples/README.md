# 示例设计

本目录以 ripgrep 为实验对象，按 [PGO.md](../PGO.md) 和 [BOLT.md](../BOLT.md) 的步骤完成三个示例。本文说明三个示例共用的设计：目录构成、实验对象、语料、负载、评测方法和运行环境。各示例的操作步骤和结果见对应目录下的 README.md。

## 目录构成

| 目录 | 内容 |
|:---|:---|
| [`pgo/`](pgo/) | PGO 示例：`run.sh` 构建普通版与 PGO 版并评测，结果写入 `results.md` |
| [`bolt/`](bolt/) | BOLT 示例：`run.sh` 构建 BOLT 版（插桩、采样）与 PGO + BOLT 版并评测，结果写入 `results.md` |
| [`cargo-pgo/`](cargo-pgo/) | cargo-pgo 示例：`run.sh` 用 cargo-pgo 完成 PGO 与 PGO + BOLT |
| [`common/`](common/) | 共用脚本：`workload.sh`（语料下载、训练负载）、`bench.sh`（评测） |
| [`subjects/`](subjects/) | 实验对象源码：ripgrep 14.1.1 |
| `work/` | 运行时生成的语料、构建缓存、可执行文件和 profile，不纳入版本控制 |

运行顺序为 `pgo` → `bolt` → `cargo-pgo`。`bolt/run.sh` 的“与 PGO 叠加”使用 `pgo/run.sh` 生成的 PGO profile，评测对象包含 `pgo/run.sh` 生成的 PGO 版；`cargo-pgo/run.sh` 以 `pgo/run.sh` 生成的普通版作为输出对照。

```bash
bash examples/pgo/run.sh
bash examples/bolt/run.sh
bash examples/cargo-pgo/run.sh
```

## 实验对象

实验对象为 ripgrep 14.1.1，一个用 Rust 编写的命令行文本搜索工具，源码未做修改，说明见 [subjects/README.md](subjects/README.md)。ripgrep 仅作为示例程序，相同的流程适用于其他 Rust 程序。

## 语料

语料为 Linux 6.6 内核源码，共 81,703 个文件，解压后 1.5 GB。`common/workload.sh corpus` 在语料不存在时下载 `linux-6.6.tar.xz`（约 140 MB），校验 sha256 后解压到 `work/linux-6.6/`。下载源默认为 `https://cdn.kernel.org/pub/linux/kernel`，可通过环境变量 `KERNEL_MIRROR` 修改，例如 `https://mirrors.tuna.tsinghua.edu.cn/kernel`。

## 训练负载

训练负载用于采集 profile，由 `common/workload.sh train <rg>` 执行，共 9 条搜索，覆盖 ripgrep 的常见用法：

| 命令 | 用法 |
|:---|:---|
| `rg 'mutex_lock'` | 字面量 |
| `rg -i 'spin_unlock_irqrestore'` | 忽略大小写 |
| `rg -w 'kfree'` | 整词匹配 |
| `rg '[a-z]+_init\('` | 带字面量后缀的正则 |
| `rg 'EXPORT_SYMBOL_GPL\|MODULE_AUTHOR\|DEFINE_MUTEX'` | 多选一 |
| `rg '\w+_(alloc\|free)\s*\('` | 无长字面量的正则 |
| `rg -c 'TODO'` | 计数 |
| `rg -F 'struct device *dev'` | 固定字符串 |
| `rg --files` | 仅遍历目录 |

PGO 和 BOLT 的插桩采集、采样采集使用同一套训练负载。

## 评测用例

评测由 `common/bench.sh` 执行，共 7 个用例，取自 ripgrep 作者基准集中的 linux_* 系列。评测用例与训练负载不重复，用于检验优化效果能否推广到训练中未出现的输入。

| 用例 | 命令 | 匹配方式 |
|:---|:---|:---|
| literal | `rg PM_RESUME` | 区分大小写的单个字面量 |
| literal_casei | `rg -i PM_RESUME` | 忽略大小写的单个字面量 |
| word | `rg -w PM_RESUME` | 字面量，且两侧须为单词边界 |
| unicode_word | `rg '\wAh'` | Unicode 单词字符类 `\w` 后接字面量 `Ah` |
| re_literal_suffix | `rg '[A-Z]+_RESUME'` | 字符类重复，后接字面量后缀 `_RESUME` |
| alternates | `rg 'ERR_SYS\|PME_TURN_OFF\|LINK_REQ_RST\|CFG_BME_EVT'` | 4 个字面量的多选一 |
| no_literal | `rg '\w{5}\s+\w{5}\s+\w{5}\s+\w{5}\s+\w{5}'` | 只由字符类和重复组成，不含字面量 |

## 评测方法与指标

`bench.sh <结果文件> <基线版> <对比版>...` 对每个用例依次执行：

1. 正确性校验：各版本的输出排序后计算 sha256，不一致则报错退出。ripgrep 并行搜索时输出顺序不固定，因此先排序再比较。
2. 墙钟时间：`hyperfine --warmup 3 --runs 50`，记录均值和标准差。
3. 硬件计数器：`perf stat -r 5`，只统计用户态（`:u`）事件。

结果写入 Markdown 表格，第一行为基线版，其余各行附相对基线的变化。

| 指标 | 含义 |
|:---|:---|
| 耗时 | 一次搜索的墙钟时间，包含内核态的文件读取和目录遍历 |
| cycles | 用户态 CPU 时钟周期数 |
| instructions | 用户态执行的指令数，PGO 的内联和分支布局优化主要体现在此项 |
| L1 i-cache miss | 取指时一级指令缓存的未命中次数，代码布局优化主要体现在此项 |
| iTLB miss | 取指时 iTLB 的未命中次数 |

评测以用户态硬件计数器为主要指标。墙钟时间包含内核态的 I/O 开销：在该负载下，ripgrep 约 58% 的 CPU 时间为内核态（见 [pgo/README.md](pgo/README.md) 第 3 节），而 PGO 和 BOLT 只作用于用户态代码；此外 WSL2 下墙钟时间的波动较大。

## 运行环境

- Linux；rustup 工具链及 `llvm-tools-preview` 组件；`perf`（需能读取硬件计数器）、`hyperfine`、`curl`。
- BOLT 示例另需 18 及以上版本的 BOLT 工具（`llvm-bolt`、`merge-fdata`、`perf2bolt`），位于 `PATH` 中；采样采集需要 CPU 支持 LBR，不支持时 `bolt/run.sh` 跳过该步骤。
- cargo-pgo 示例另需 `cargo install cargo-pgo`。
- 磁盘空间约 4 GB：语料 1.6 GB，其余为构建缓存和产物。

运行产物默认写入 `examples/work/`，可通过环境变量 `WORK_DIR` 修改。在 WSL 中，仓库或 `WORK_DIR` 应位于 Linux 文件系统内，否则文件共享的 I/O 开销会影响测量结果。

各示例的实测数据来自以下环境：Intel Core i7-9750H，WSL2 Ubuntu 24.04，rustc 1.93.1（LLVM 21.1.8），BOLT 21.1.8。
