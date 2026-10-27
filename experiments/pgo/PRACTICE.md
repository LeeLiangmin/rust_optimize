# PGO 实践：优化 ripgrep

本文按 [PGO 通用文档](../../PGO.md) 的步骤，对 ripgrep 14.1.1 进行 PGO 优化并评测效果。各步骤均有对应脚本，可在克隆仓库后直接复现。

## 1. 实验概述

### 1.1 目的

评估 PGO 对一个实际 Rust 程序的性能影响，并通过硬件计数器分析其作用方式。

### 1.2 实验对象

[ripgrep](https://github.com/BurntSushi/ripgrep)（命令 `rg`）是用 Rust 编写的命令行文本搜索工具，功能与 `grep` 类似：在目录下的文件中查找与给定模式匹配的行。选用 ripgrep 的原因：它是广泛使用的实际程序，代码规模适中（约 5 万行 Rust 代码，含注释和测试），且作者公开了基准测试，可供参照。所用版本为 14.1.1，源码未做修改，位于仓库的 [`experiments/subjects/ripgrep/`](../subjects/ripgrep)。

### 1.3 方法

1. 准备语料：下载 Linux 6.6 内核源码（8 万多个文件，1.5 GB），作为搜索对象。
2. 采集 profile：构建插桩版 ripgrep，在语料上执行 9 条典型搜索（训练负载）。
3. 构建两个版本：普通 release 构建的 `rg-base`（对照组），以及使用 profile 重新编译的 `rg-pgo`。
4. 对比：在同一语料上执行另外 7 条搜索（评测负载，与训练负载不重复），确认两个版本输出一致后比较性能。

### 1.4 评价指标

| 指标 | 含义 | 预期变化 |
|:---|:---|:---|
| 墙钟时间 | 一次搜索从开始到结束的实际耗时 | 下降 |
| cycles | 执行 ripgrep 自身代码所用的 CPU 时钟周期数 | 下降 |
| 指令数 | 执行的机器指令条数 | 下降（内联、减少冗余跳转） |
| L1 i-cache miss | 取指时一级指令缓存的未命中次数 | 下降（热代码更集中） |
| iTLB miss | 取指时 iTLB 的未命中次数 | 下降 |

后四项由 `perf` 读取 CPU 硬件计数器，且只统计用户态，即 ripgrep 自身代码的开销，不含读文件等内核操作。这些指标比墙钟时间稳定，并能直接对应 PGO 的原理。

### 1.5 主要结论

7 个评测用例中有 6 个，PGO 版的 cycles 减少约 10%，指令数减少 4%–7%；全部用例的 i-cache 未命中减少约三分之一，与原理一致。墙钟时间没有可测的提升，原因见第 7 节。

## 2. 环境要求

| 项 | 要求 | 本文实测环境 |
|:---|:---|:---|
| 系统 | Linux（评测依赖 `perf`） | WSL2，Ubuntu 24.04 |
| CPU | 无特殊要求 | Intel Core i7-9750H |
| Rust | rustup 工具链 + `llvm-tools-preview` 组件 | rustc 1.93.1（LLVM 21.1.8） |
| 其他 | `perf`（需能读取硬件计数器）、`hyperfine`、`curl` | — |
| 可选 | `cargo-pgo`（仅 `cargo-pgo.sh` 需要） | cargo-pgo 0.3.0 |
| 磁盘 | 约 2.5 GB（语料 1.6 GB，构建缓存与产物约 0.9 GB） | — |

步骤 00 会检查上述依赖，缺失时给出安装方法。

## 3. 复现

```bash
git clone <本仓库地址> rust_optimize
cd rust_optimize
bash experiments/pgo/practice/run.sh
```

`run.sh` 依次执行下表中的脚本（除 `experiments/common/corpus.sh` 外，均位于 `practice/` 目录），任一步骤失败即停止。本文环境下全程约 7.5 分钟，其中评测约 3 分钟。

| 脚本 | 内容 | 对应通用文档 | 本文用时 |
|:---|:---|:---|---:|
| `00-check-env.sh` | 检查平台、工具、硬件计数器 | 步骤 0 | 1 秒 |
| `common/corpus.sh` | 下载语料（已存在则跳过） | — | 视网速 |
| `01-build.sh` | 构建基线版和插桩版 | 步骤 1 | 43 秒 |
| `02-collect.sh` | 以插桩版运行训练负载 | 步骤 2 | 204 秒（语料未缓存） |
| `03-merge.sh` | 合并 profile | 步骤 3 | 0 秒 |
| `04-optimize.sh` | 依据 profile 重新编译 | 步骤 4 | 20 秒 |
| `05-bench.sh` | 评测，结果写入 [`results.md`](practice/results.md) | 步骤 5 | 185 秒 |
| `cargo-pgo.sh` | 可选，不在 `run.sh` 中：用 cargo-pgo 完成 01–04 | 第 4 节 | 46 秒 |

各脚本也可单独运行；前置产物缺失时，脚本会提示需要先运行的步骤。

可通过以下环境变量调整：

| 变量 | 默认值 | 说明 |
|:---|:---|:---|
| `WORK_DIR` | `experiments/work/`；仓库位于 WSL 的 `/mnt/*` 下时为 `~/rust_optimize_work` | 语料、构建产物、profile 的存放位置，已在 `.gitignore` 中忽略。WSL 下不应放在 `/mnt/c` 等 Windows 盘上，否则文件共享的 I/O 开销会掩盖优化效果 |
| `KERNEL_MIRROR` | `https://cdn.kernel.org/pub/linux/kernel` | 语料下载源。国内可使用 `https://mirrors.tuna.tsinghua.edu.cn/kernel` |

工作目录结构：语料位于 `linux-6.6/`，与 BOLT 实践共用；本实践的文件位于 `pgo/` 下，其中构建缓存在 `pgo/target/`，可执行文件在 `pgo/bin/`，profile 在 `pgo/data/profile/`。

## 4. 负载设计

profile 的质量取决于负载。PGO 与 BOLT 两个实践使用相同的语料和负载。

### 4.1 语料

Linux 6.6 源码，81,703 个文件，1.5 GB。`corpus.sh` 下载后校验 sha256。

### 4.2 训练负载

[`common/train.sh`](../common/train.sh)，用于采集 profile。共 9 条搜索，覆盖 ripgrep 的常见用法：

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

### 4.3 评测负载

[`common/bench.sh`](../common/bench.sh)，用于对比性能。共 7 条搜索，取自 ripgrep 作者的基准集，与训练负载不重复，用于检验优化效果能否推广到训练中未出现的输入：

| 用例 | 命令 |
|:---|:---|
| literal | `rg PM_RESUME` |
| literal_casei | `rg -i PM_RESUME` |
| word | `rg -w PM_RESUME` |
| unicode_word | `rg '\wAh'` |
| re_literal_suffix | `rg '[A-Z]+_RESUME'` |
| alternates | `rg 'ERR_SYS\|PME_TURN_OFF\|LINK_REQ_RST\|CFG_BME_EVT'` |
| no_literal | `rg '\w{5}\s+\w{5}\s+\w{5}\s+\w{5}\s+\w{5}'` |

## 5. 分步说明

以下列出各脚本的核心命令、本文环境下的实际输出及其含义。`$BIN`、`$PGO_DIR` 分别指 `$WORK_DIR/pgo/bin`、`$WORK_DIR/pgo/data/profile`。

### 00：检查环境

[`00-check-env.sh`](practice/00-check-env.sh) 检查以下各项，必需项缺失时给出安装方法并退出：

- 平台是否为 Linux；
- 工具：`cargo`、`llvm-profdata`、`perf`、`hyperfine`、`curl`；`cargo-pgo` 为可选项；
- `perf stat` 能否读取硬件计数器（步骤 05 需要）；
- 工作目录的位置，以及是否位于 Windows 盘。

本文环境下，`llvm-profdata` 与 rustc 的 LLVM 版本均为 21.1.8。

### 01：构建

[`01-build.sh`](practice/01-build.sh)：

```bash
cargo build --release --target $TARGET                                         # → rg-base
RUSTFLAGS="-Cprofile-generate=$PGO_DIR" cargo build --release --target $TARGET  # → rg-instr
```

| 文件 | 大小 | 用途 |
|:---|---:|:---|
| `rg-base` | 26.9 MB | 对照组 |
| `rg-instr` | 31.8 MB | 采集 profile |

插桩版体积增加约 18%，增加部分为计数器和写出 profile 的运行时代码。

### 02：采集

[`02-collect.sh`](practice/02-collect.sh)：

```bash
rm -rf $PGO_DIR
common/train.sh rg-instr
```

输出：

```text
-rw-r--r-- 1 root root 1.9M default_1517753687113566901_0.profraw
```

- 9 次运行只生成 1 个文件：默认文件名不含进程号，计数累加在同一文件中。
- 本文用时 204 秒，主要用于从磁盘读取 1.5 GB 语料（当时语料不在页缓存中）。语料已在页缓存中时，该步骤约需 5 秒。

### 03：合并

[`03-merge.sh`](practice/03-merge.sh)：

```bash
llvm-profdata merge -o $PGO_DIR/merged.profdata $PGO_DIR
llvm-profdata show $PGO_DIR/merged.profdata
```

输出：

```text
Maximum function count: 71371764
Maximum internal block count: 209293178
Total number of blocks: 91148
Total count: 1423882864
```

计数非零，profile 有效。调用次数最多的函数被调用约 7100 万次。

### 04：优化构建

[`04-optimize.sh`](practice/04-optimize.sh)：

```bash
RUSTFLAGS="-Cprofile-use=$PGO_DIR/merged.profdata -Cllvm-args=-pgo-warn-missing-function" \
  cargo build --release --target $TARGET                                       # → rg-pgo
```

脚本将构建日志写入 `$WORK_DIR/pgo/data/optimize.log`，并统计 `no profile data available` 告警的条数。

输出：

```text
缺少 profile 的函数告警：0 条
```

`rg-pgo` 为 24.9 MB，比基线小 7%。使用 profile 时，LLVM 对冷代码减少内联并按体积优化，产物因此变小。

作为对照，使用 hello world 程序的 profile 编译 ripgrep 时会产生 8341 条此类告警。因此 0 条告警表明 profile 与源码匹配，该检查有效。

### 05：评测

[`05-bench.sh`](practice/05-bench.sh) 调用 [`common/bench.sh`](../common/bench.sh)，对每个评测用例依次执行：

1. 正确性校验：两个版本的输出排序后计算 sha256，不一致则报错退出。本文 7 个用例全部通过。
2. 墙钟时间：`hyperfine --warmup 3 --runs 50`。
3. 硬件计数器：`perf stat -r 5`，只统计用户态（`:u`）的 cycles、指令数、L1 i-cache 未命中、iTLB 未命中。

### cargo-pgo 方式（可选）

[`cargo-pgo.sh`](practice/cargo-pgo.sh) 使用 cargo-pgo 完成 01–04：

```bash
cargo pgo build
common/train.sh target/$TARGET/release/rg
cargo pgo optimize                               # → rg-cargo-pgo
```

输出：

```text
INFO  cargo_pgo::pgo::optimize] Found 1 PGO profile file with total size 1.80 MiB
INFO  cargo_pgo::pgo::optimize] Merged PGO profile(s) to .../merged-<hash>.profdata
```

产物 `rg-cargo-pgo` 为 25.4 MB，在 word 用例上的输出与基线一致。与手动方式的 `rg-pgo`（24.9 MB）相比体积相差约 2%，本文未分析原因，也未对其进行性能评测。

## 6. 结果

参与评测的版本为 `rg-base`（基线）和 `rg-pgo`（PGO）。完整数据见 [`results.md`](practice/results.md)。

### 6.1 硬件计数器

`rg-pgo` 相对 `rg-base` 的变化（用户态）：

| 用例 | cycles | 指令数 | L1 i-cache miss | iTLB miss |
|:---|---:|---:|---:|---:|
| literal | −12.4% | −7.3% | −33.6% | −28.3% |
| literal_casei | −10.5% | −4.2% | −32.6% | −23.8% |
| word | −10.0% | −7.3% | −32.8% | −29.0% |
| unicode_word | −10.5% | −5.0% | −34.0% | −30.5% |
| re_literal_suffix | −10.6% | −7.3% | −34.4% | −31.1% |
| alternates | −10.3% | −4.2% | −34.1% | −24.5% |
| no_literal | −1.5% | −0.6% | −33.0% | −40.4% |

### 6.2 墙钟时间

| 用例 | `rg-base`（ms） | `rg-pgo`（ms） | 变化 |
|:---|---:|---:|---:|
| literal | 190.0 ± 9.9 | 189.6 ± 13.0 | −0.2% |
| literal_casei | 207.7 ± 7.5 | 203.1 ± 10.9 | −2.2% |
| word | 191.6 ± 14.5 | 185.2 ± 8.3 | −3.3% |
| unicode_word | 200.4 ± 16.4 | 194.1 ± 20.3 | −3.1% |
| re_literal_suffix | 189.7 ± 9.7 | 179.2 ± 3.6 | −5.5% |
| alternates | 196.9 ± 5.3 | 192.3 ± 5.3 | −2.3% |
| no_literal | 397.6 ± 9.6 | 403.1 ± 21.0 | +1.4% |

变化范围为 −5.5% 到 +1.4%，与标准差（最高 21.0 ms）处于同一量级，无法据此得出可靠结论。

## 7. 分析

1. 作用方式与原理一致。7 个用例中有 6 个指令数减少 4.2%–7.3%、cycles 减少约 10%–12%，说明内联和分支布局优化减少了需要执行的指令。L1 i-cache 未命中稳定减少约三分之一，说明热代码分布更集中。
2. no_literal 几乎没有提升。该用例的耗时主要集中在正则引擎的一个小循环内，热代码本身已经很紧凑，PGO 的调整空间很小。其 i-cache 未命中同样减少了 33%，但取指不是瓶颈，cycles 仅减少 1.5%。
3. 墙钟时间没有稳定提升。以 literal 为例，`rg-base` 的 CPU 时间中 User 为 820 ms、System 为 1249 ms，约 60% 花在内核态（读文件、遍历目录）。PGO 只作用于用户态部分，其收益在总耗时中被稀释；同时 WSL2 下计时波动较大，最终没有观察到稳定差异。
4. 单次结果存在波动。BOLT 实践中也包含按相同流程构建的 PGO 版本。两轮的 cycles 变化大多相差 2 个百分点以内，alternates 相差较大（本轮 −10.3%，另一轮 −6.3%）。针对个别用例的结论应以多轮运行结果为准。

结论：PGO 对 ripgrep 用户态代码的优化效果明显且稳定（cycles 约 −10%）；但在该负载下 ripgrep 以 I/O 为主，端到端收益有限。是否采用 PGO，应以目标程序在实际负载上的测量结果为准。
