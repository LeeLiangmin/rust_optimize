# PGO 实践：优化 ripgrep

本文按 [PGO 通用文档](README.md) 的步骤，对 ripgrep 14.1.1 做一次完整的 PGO 优化，并评测效果。每一步都有对应的脚本，clone 仓库后可以直接复现。

## 1. 实验概述

**要回答的问题**：对一个真实的 Rust 程序做 PGO，能不能让它变快？如果能，快在哪里？

**实验对象**：[ripgrep](https://github.com/BurntSushi/ripgrep)（命令 `rg`）是一个用 Rust 编写的命令行文本搜索工具，功能类似 `grep`：给定一个模式，在目录下的所有文件中查找匹配的行。选择它的原因是：它是广泛使用的真实程序，代码规模适中（约 5 万行 Rust 代码，含注释和测试），并且有作者公开的基准测试可以参考。

**实验做法**：

1. **准备语料**：下载 Linux 6.6 内核源码（8 万多个文件，1.5 GB），作为 ripgrep 的搜索对象。
2. **采集 profile**：构建插桩版 ripgrep，在语料上执行 9 条典型搜索（训练负载），记录程序的实际执行情况。
3. **构建两个版本**：普通 release 构建的 `rg-base`（对照组），以及使用 profile 重新编译的 `rg-pgo`。
4. **对比**：在同一份语料上执行另外 7 条搜索（评测负载，与训练负载不重复），先确认两个版本输出完全一致，再比较性能。

**衡量指标**：

| 指标 | 含义 | 预期的 PGO 效果 |
|:---|:---|:---|
| 墙钟时间 | 一次搜索从开始到结束的实际耗时 | 下降 |
| cycles | CPU 执行 ripgrep 自身代码所用的时钟周期数，越少越快 | 下降 |
| 指令数 | 执行的机器指令条数 | 下降（内联、去掉多余跳转） |
| L1 i-cache miss | 取指令时一级指令缓存未命中的次数 | 下降（热代码更集中） |
| iTLB miss | 取指令时地址翻译缓存未命中的次数 | 下降 |

后四项用 `perf` 读取 CPU 的硬件计数器，并且**只统计用户态**，即 ripgrep 自身代码的开销，不包括读文件等内核操作。它们比墙钟时间稳定得多，也能直接对应 PGO 的原理。

**结论先行**：7 个评测用例中有 6 个，PGO 版的 cycles 减少约 10%、指令数减少 4%–7%；所有用例的 i-cache 未命中都减少约三分之一。这与原理一致。但墙钟时间没有可测的提升，原因见第 7 节。

## 2. 环境要求

| 项 | 要求 | 本文实测环境 |
|:---|:---|:---|
| 系统 | Linux（评测依赖 `perf`） | WSL2，Ubuntu 24.04 |
| CPU | 任意 | Intel Core i7-9750H |
| Rust | rustup 工具链 + `llvm-tools-preview` 组件 | rustc 1.93.1（LLVM 21.1.8） |
| 其他 | `perf`（需能读硬件计数器）、`hyperfine`、`curl` | — |
| 可选 | `cargo-pgo`（仅 `cargo-pgo.sh` 需要） | cargo-pgo 0.3.0 |
| 磁盘 | 约 2.5 GB（语料 1.6 GB，构建缓存与产物约 0.9 GB） | — |

缺少什么不必提前确认，步骤 00 会逐项检查并给出安装方法。

## 3. 一键复现

```bash
git clone <本仓库地址> rust_optimize
cd rust_optimize
bash pgo/practice/run.sh
```

`pgo/` 目录也可以单独拿出去使用，它不依赖仓库中的其他目录，只需要 ripgrep 源码。源码默认取与 `pgo/` 同级的 `ripgrep/`，也可以用 `RIPGREP_SRC` 指定：

```bash
RIPGREP_SRC=/path/to/ripgrep bash pgo/practice/run.sh
```

`run.sh` 依次执行下表中的脚本（均位于 `practice/` 目录，`common/corpus.sh` 除外），任何一步失败都会立即停止。本文环境下全程约 7.5 分钟，其中评测约 3 分钟。

| 脚本 | 内容 | 对应通用文档 | 本文用时 |
|:---|:---|:---|---:|
| `00-check-env.sh` | 检查平台、工具、硬件计数器 | 步骤 0 | 1 秒 |
| `common/corpus.sh` | 下载语料（已存在则跳过） | — | 视网速 |
| `01-build.sh` | 构建基线版和插桩版 | 步骤 1 | 43 秒 |
| `02-collect.sh` | 用插桩版运行训练负载 | 步骤 2 | 204 秒（语料未缓存） |
| `03-merge.sh` | 合并 profile | 步骤 3 | 0 秒 |
| `04-optimize.sh` | 按 profile 重新编译 | 步骤 4 | 20 秒 |
| `05-bench.sh` | 评测，写入 [`results.md`](practice/results.md) | 步骤 5 | 185 秒 |
| `cargo-pgo.sh` | 可选，不在 `run.sh` 中：用 cargo-pgo 完成 01–04 | 第 4 节 | 46 秒 |

每个脚本也可以单独运行；前置产物缺失时，脚本会提示应先运行哪一步。

**可调整的环境变量**：

| 变量 | 默认值 | 说明 |
|:---|:---|:---|
| `RIPGREP_SRC` | 与本目录同级的 `ripgrep/` | ripgrep 源码位置 |
| `WORK_DIR` | `pgo/work/`；本目录位于 WSL 的 `/mnt/*` 下时为 `~/rust_optimize_work/pgo` | 语料、构建产物、profile 的存放位置，已在 `.gitignore` 中忽略。WSL 下不要放在 `/mnt/c` 等 Windows 盘上，否则文件共享的 I/O 开销会掩盖优化效果 |
| `KERNEL_MIRROR` | `https://cdn.kernel.org/pub/linux/kernel` | 语料下载源。国内可用 `https://mirrors.tuna.tsinghua.edu.cn/kernel` |

工作目录的结构：语料在 `linux-6.6/`，cargo 构建缓存在 `target/`，可执行文件在 `bin/`，profile 在 `data/profile/`。

## 4. 负载设计

负载决定 profile 的质量，因此先说明负载。PGO 与 BOLT 两个实践使用同一套语料和负载。

**语料**：Linux 6.6 源码，81,703 个文件，1.5 GB。`corpus.sh` 下载后会校验 sha256。

**训练负载**（[`common/train.sh`](common/train.sh)，用于采集 profile）：9 条搜索，覆盖 ripgrep 的常见用法。

| 命令 | 覆盖的用法 |
|:---|:---|
| `rg 'mutex_lock'` | 字面量 |
| `rg -i 'spin_unlock_irqrestore'` | 忽略大小写 |
| `rg -w 'kfree'` | 整词匹配 |
| `rg '[a-z]+_init\('` | 带字面量后缀的正则 |
| `rg 'EXPORT_SYMBOL_GPL\|MODULE_AUTHOR\|DEFINE_MUTEX'` | 多选一 |
| `rg '\w+_(alloc\|free)\s*\('` | 无长字面量的正则 |
| `rg -c 'TODO'` | 计数 |
| `rg -F 'struct device *dev'` | 固定字符串 |
| `rg --files` | 只遍历目录 |

**评测负载**（[`common/bench.sh`](common/bench.sh)，用于对比性能）：7 条搜索，取自 ripgrep 作者的基准集，**与训练负载不重复**，用来检验优化能否推广到没见过的输入。

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

以下列出每个脚本的核心命令、本文环境下的实际输出及其含义。`$BIN`、`$PGO_DIR` 分别指 `$WORK_DIR/bin`、`$WORK_DIR/data/profile`。

### 00：检查环境

[`00-check-env.sh`](practice/00-check-env.sh) 检查以下各项，必需项缺失时给出安装方法并退出：

- 平台是否为 Linux；
- 工具：`cargo`、`llvm-profdata`、`perf`、`hyperfine`、`curl`；`cargo-pgo` 为可选项；
- `perf stat` 能否读取硬件计数器（步骤 05 需要）；
- 工作目录的位置，以及是否位于 Windows 盘。

本文环境下，`llvm-profdata` 与 rustc 的 LLVM 版本都是 21.1.8。

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

插桩版大了约 18%，多出的是计数器和写出 profile 的运行时代码。

### 02：采集

[`02-collect.sh`](practice/02-collect.sh)：

```bash
rm -rf $PGO_DIR
common/train.sh rg-instr
```

**输出**：

```text
-rw-r--r-- 1 root root 1.9M default_1517753687113566901_0.profraw
```

- 9 次运行只生成了 1 个文件：默认文件名不含进程号，计数累加在同一文件中。
- 本文用时 204 秒，主要花在从磁盘读取 1.5 GB 语料上：当时语料不在页缓存中。语料已在页缓存中时，这一步只需约 5 秒。

### 03：合并

[`03-merge.sh`](practice/03-merge.sh)：

```bash
llvm-profdata merge -o $PGO_DIR/merged.profdata $PGO_DIR
llvm-profdata show $PGO_DIR/merged.profdata
```

**输出**：

```text
Maximum function count: 71371764
Maximum internal block count: 209293178
Total number of blocks: 91148
Total count: 1423882864
```

计数非零，profile 有效。最热的函数被调用了约 7100 万次。

### 04：优化构建

[`04-optimize.sh`](practice/04-optimize.sh)：

```bash
RUSTFLAGS="-Cprofile-use=$PGO_DIR/merged.profdata -Cllvm-args=-pgo-warn-missing-function" \
  cargo build --release --target $TARGET                                       # → rg-pgo
```

脚本把构建日志写入 `$WORK_DIR/data/optimize.log`，并统计 `no profile data available` 告警的条数。

**输出**：

```text
缺少 profile 的函数告警：0 条
```

`rg-pgo` 为 24.9 MB，比基线小 7%。有 profile 时，LLVM 对冷代码减少内联并按体积优化，产物因此变小。

**这项检查是有效的**：作为对照，用一个 hello world 程序的 profile 去编译 ripgrep，会产生 8341 条这类告警。所以 0 条说明 profile 与源码完全匹配。

### 05：评测

[`05-bench.sh`](practice/05-bench.sh) 调用 [`common/bench.sh`](common/bench.sh)，对每个评测用例依次：

1. **校验正确性**：两个版本的输出排序后计算 sha256，必须完全一致，否则报错退出。本文 7 个用例全部通过。
2. **测墙钟时间**：`hyperfine --warmup 3 --runs 50`。
3. **测硬件计数器**：`perf stat -r 5`，只统计用户态（`:u`）的 cycles、指令数、L1 i-cache 未命中、iTLB 未命中。

### 附：cargo-pgo

[`cargo-pgo.sh`](practice/cargo-pgo.sh) 用 cargo-pgo 完成 01–04：

```bash
cargo pgo build
common/train.sh target/$TARGET/release/rg
cargo pgo optimize                               # → rg-cargo-pgo
```

**输出**：

```text
INFO  cargo_pgo::pgo::optimize] Found 1 PGO profile file with total size 1.80 MiB
INFO  cargo_pgo::pgo::optimize] Merged PGO profile(s) to .../merged-<hash>.profdata
```

产物 `rg-cargo-pgo` 为 25.4 MB，在 word 用例上的输出与基线一致。它与手动方式的 `rg-pgo`（24.9 MB）体积相差约 2%，本文没有分析原因，也没有对它做性能评测。

## 6. 结果

两个版本：`rg-base`（基线）、`rg-pgo`（PGO）。完整数据见 [`results.md`](practice/results.md)。

### 5.1 硬件计数器

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

### 5.2 墙钟时间

| 用例 | `rg-base`（ms） | `rg-pgo`（ms） | 变化 |
|:---|---:|---:|---:|
| literal | 190.0 ± 9.9 | 189.6 ± 13.0 | −0.2% |
| literal_casei | 207.7 ± 7.5 | 203.1 ± 10.9 | −2.2% |
| word | 191.6 ± 14.5 | 185.2 ± 8.3 | −3.3% |
| unicode_word | 200.4 ± 16.4 | 194.1 ± 20.3 | −3.1% |
| re_literal_suffix | 189.7 ± 9.7 | 179.2 ± 3.6 | −5.5% |
| alternates | 196.9 ± 5.3 | 192.3 ± 5.3 | −2.3% |
| no_literal | 397.6 ± 9.6 | 403.1 ± 21.0 | +1.4% |

变化在 −5.5% 到 +1.4% 之间，与标准差（最高 21.0 ms）处于同一量级，**无法从墙钟时间得出可靠结论**。

## 7. 分析

1. **PGO 的作用方式与原理一致**。7 个用例中有 6 个指令数减少 4.2%–7.3%，cycles 减少约 10%–12%：内联和分支布局优化减少了要执行的指令。L1 i-cache 未命中也稳定减少约三分之一，说明热代码更集中了。
2. **no_literal 几乎没有提升**。它的时间主要花在正则引擎的一个小循环里，这段热代码本来就很紧凑，PGO 可调整的空间很小。i-cache 未命中虽然同样减少了 33%，但取指不是它的瓶颈，cycles 只减少 1.5%。
3. **墙钟时间没有稳定提升**。以 literal 为例，`rg-base` 的 CPU 时间中 User 820 ms、System 1249 ms，约 60% 花在内核态（读文件、遍历目录）。PGO 只能优化用户态部分，提升被稀释，再加上 WSL2 下计时波动较大，最终看不出稳定的差异。
4. **单次结果有波动**。BOLT 实践中也包含一个用同样流程构建的 PGO 版本，两轮的 cycles 变化大多相差 2 个百分点以内，alternates 一项相差较大（本轮 −10.3%，那一轮 −6.3%）。个别用例的结论应以多轮运行为准。

**结论**：PGO 对 ripgrep 的用户态代码效果明显且稳定（cycles 约 −10%），但由于 ripgrep 在这一负载中以 I/O 为主，端到端收益有限。是否采用 PGO，应以目标程序在自己负载上的实测为准。
