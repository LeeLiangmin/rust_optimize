# BOLT 实践：优化 ripgrep

本文按 [BOLT 通用文档](README.md) 的步骤，对 ripgrep 14.1.1 做一次完整的 BOLT 优化：插桩和采样两种采集方式都做，并与 PGO 叠加，最后评测各版本的效果。每一步都有对应的脚本，clone 仓库后可以直接复现。

## 1. 实验概述

**要回答的问题**：

1. 对一个真实的 Rust 程序做 BOLT，能不能让它变快？快在哪里？
2. 两种采集 profile 的方式（插桩、采样）效果有没有差别？
3. 在 PGO 的基础上再做 BOLT，能不能进一步提升？

**实验对象**：[ripgrep](https://github.com/BurntSushi/ripgrep)（命令 `rg`）是一个用 Rust 编写的命令行文本搜索工具，功能类似 `grep`：给定一个模式，在目录下的所有文件中查找匹配的行。选择它的原因是：它是广泛使用的真实程序，代码规模适中（约 5 万行 Rust 代码，含注释和测试），并且有作者公开的基准测试可以参考。

**实验做法**：

1. **准备语料**：下载 Linux 6.6 内核源码（8 万多个文件，1.5 GB），作为 ripgrep 的搜索对象。
2. **采集 profile**：在语料上执行 9 条典型搜索（训练负载），分别用插桩和采样两种方式记录程序的实际执行情况。
3. **构建五个版本**：

   | 版本 | 做法 | 用于回答 |
   |:---|:---|:---|
   | `rg-base` | 普通 release 构建 | 对照组 |
   | `rg-bolt` | BOLT，插桩方式采集 profile | 问题 1 |
   | `rg-bolt-perf` | BOLT，采样方式采集 profile | 问题 2 |
   | `rg-pgo` | 仅 PGO | 问题 3 的对照 |
   | `rg-pgo-bolt` | 先 PGO，再 BOLT | 问题 3 |

4. **对比**：在同一份语料上执行另外 7 条搜索（评测负载，与训练负载不重复），先确认各版本输出完全一致，再比较性能。

**衡量指标**：

| 指标 | 含义 | 预期的 BOLT 效果 |
|:---|:---|:---|
| 墙钟时间 | 一次搜索从开始到结束的实际耗时 | 下降 |
| cycles | CPU 执行 ripgrep 自身代码所用的时钟周期数，越少越快 | 下降 |
| 指令数 | 执行的机器指令条数 | 基本不变（BOLT 只改变代码位置） |
| L1 i-cache miss | 取指令时一级指令缓存未命中的次数 | 明显下降（热代码更集中） |
| iTLB miss | 取指令时地址翻译缓存未命中的次数 | 下降 |

后四项用 `perf` 读取 CPU 的硬件计数器，并且**只统计用户态**，即 ripgrep 自身代码的开销，不包括读文件等内核操作。它们比墙钟时间稳定得多，也能直接对应 BOLT 的原理。

**结论先行**：

1. BOLT 版的 i-cache 未命中减少 42%–49%，指令数基本不变，与原理一致。
2. 插桩与采样两种方式效果接近，采样更快、开销更小。
3. PGO + BOLT 的效果最好，cycles 最多减少约 15%，i-cache 未命中约减半。
4. 墙钟时间没有可测的提升，原因见第 7 节。

## 2. 环境要求

| 项 | 要求 | 本文实测环境 |
|:---|:---|:---|
| 系统 | Linux x86_64 或 AArch64 | WSL2，Ubuntu 24.04 |
| CPU | 任意；采样方式需要支持 LBR | Intel Core i7-9750H（支持 LBR） |
| Rust | rustup 工具链 + `llvm-tools-preview` 组件 | rustc 1.93.1（LLVM 21.1.8） |
| BOLT | LLVM 18 及以上的 `llvm-bolt`、`merge-fdata`、`perf2bolt`（步骤 03 用到 `cdsort`） | 21.1.8，apt.llvm.org 的 `bolt-21` |
| 其他 | `perf`（需能读硬件计数器）、`hyperfine`、`curl` | — |
| 可选 | `cargo-pgo`（仅 `cargo-pgo.sh` 需要） | cargo-pgo 0.3.0 |
| 磁盘 | 约 3 GB（语料 1.6 GB，构建缓存 0.8 GB，产物与 profile 0.4 GB） | — |

缺少什么不必提前确认，步骤 00 会逐项检查并给出安装方法。

## 3. 一键复现

```bash
git clone <本仓库地址> rust_optimize
cd rust_optimize
bash bolt/practice/run.sh
```

`run.sh` 依次执行下表中的脚本（除仓库根目录的 `common/corpus.sh` 外，均位于 `practice/` 目录），任何一步失败都会立即停止。本文环境下全程约 14 分钟，其中评测约 8 分钟。

| 脚本 | 内容 | 对应通用文档 | 本文用时 |
|:---|:---|:---|---:|
| `00-check-env.sh` | 检查平台、工具、硬件计数器、LBR | 步骤 0 | 10 秒 |
| `common/corpus.sh` | 下载语料（已存在则跳过） | — | 视网速 |
| `01-build.sh` | 构建基线版和带重定位版 | 步骤 1 | 55 秒 |
| `02a-instrument.sh` | 插桩采集 | 步骤 2a | 211 秒（语料未缓存） |
| `02b-sample.sh` | 采样采集（不支持 LBR 时跳过） | 步骤 2b | 5 秒 |
| `03-optimize.sh` | BOLT 优化 | 步骤 3 | 2 秒 |
| `04-pgo-bolt.sh` | 与 PGO 叠加 | 3.8 节 | 89 秒 |
| `05-bench.sh` | 评测所有版本，写入 [`results.md`](practice/results.md) | 步骤 4 | 455 秒 |
| `cargo-pgo.sh` | 可选，不在 `run.sh` 中：用 cargo-pgo 完成 04 的 PGO + BOLT | 第 4 节 | 67 秒 |

每个脚本也可以单独运行；前置产物缺失时，脚本会提示应先运行哪一步。

**可调整的环境变量**：

| 变量 | 默认值 | 说明 |
|:---|:---|:---|
| `WORK_DIR` | 仓库根目录下的 `work/`；仓库位于 WSL 的 `/mnt/*` 下时为 `~/rust_optimize_work` | 语料、构建产物、profile 的存放位置，已在 `.gitignore` 中忽略。WSL 下不要放在 `/mnt/c` 等 Windows 盘上，否则文件共享的 I/O 开销会掩盖优化效果 |
| `LLVM_BIN` | 自动探测 | BOLT 工具所在目录。默认先找 `PATH`，再找 `/usr/lib/llvm-*/bin` 中版本最高的 |
| `KERNEL_MIRROR` | `https://cdn.kernel.org/pub/linux/kernel` | 语料下载源。国内可用 `https://mirrors.tuna.tsinghua.edu.cn/kernel` |

工作目录的结构：语料在 `linux-6.6/`，与另一个实践共用；本实践的文件都在 `bolt/` 下，cargo 构建缓存在 `bolt/target/`，可执行文件在 `bolt/bin/`，profile 在 `bolt/data/`。

## 4. 负载设计

负载决定 profile 的质量，因此先说明负载。PGO 与 BOLT 两个实践使用同一套语料和负载。

**语料**：Linux 6.6 源码，81,703 个文件，1.5 GB。`corpus.sh` 下载后会校验 sha256。

**训练负载**（[`common/train.sh`](../common/train.sh)，用于采集 profile）：9 条搜索，覆盖 ripgrep 的常见用法。

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

**评测负载**（[`common/bench.sh`](../common/bench.sh)，用于对比性能）：7 条搜索，取自 ripgrep 作者的基准集，**与训练负载不重复**，用来检验优化能否推广到没见过的输入。

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

以下列出每个脚本的核心命令、本文环境下的实际输出及其含义。`$BIN`、`$DATA` 分别指 `$WORK_DIR/bolt/bin`、`$WORK_DIR/bolt/data`。

### 00：检查环境

[`00-check-env.sh`](practice/00-check-env.sh) 检查以下各项，必需项缺失时给出安装方法并退出：

- 平台是否为 Linux x86_64 / AArch64；
- 工具：`cargo`、`llvm-profdata`、`llvm-bolt`、`merge-fdata`、`perf2bolt`、`perf`、`hyperfine`、`curl`；BOLT 版本是否为 18 及以上；
- `perf stat` 能否读取硬件计数器（步骤 05 需要）；
- 能否用 `perf record -j any,u` 记录分支，即是否支持 LBR（步骤 02b 需要，不支持时只跳过 02b）；
- 工作目录的位置，以及是否位于 Windows 盘。

### 01：构建

[`01-build.sh`](practice/01-build.sh)：

```bash
cargo build --release --target $TARGET                                   # → rg-base
RUSTFLAGS="-Clink-args=-Wl,-q" cargo build --release --target $TARGET    # → rg-reloc
```

| 文件 | 大小 | 用途 |
|:---|---:|:---|
| `rg-base` | 26.9 MB | 对照组 |
| `rg-reloc` | 52.2 MB | BOLT 的输入 |

`rg-reloc` 几乎大了一倍，多出的就是重定位信息。脚本用 `readelf -S rg-reloc | grep rela.text` 确认它已保留。重定位信息不改变代码本身，所以性能对比直接用 `rg-base` 作为基线。

ripgrep 的 release profile 为 `debug = 1`，没有设置 `strip`，符号表完整，满足 BOLT 的输入要求。

### 02a：插桩采集

[`02a-instrument.sh`](practice/02a-instrument.sh)：

```bash
llvm-bolt rg-reloc -instrument -o rg.inst \
  --instrumentation-file=$DATA/instr/prof.fdata --instrumentation-file-append-pid
common/train.sh rg.inst
merge-fdata $DATA/instr/prof.fdata.*.fdata > $DATA/instr/merged.fdata
```

**输出**：

- 插桩版 `rg.inst` 为 26.2 MB。
- 9 次运行生成 9 个 `prof.fdata.<pid>.fdata`，每个 2.0–2.4 MB；`merge-fdata` 输出 `Profile from 9 files merged.`
- 本文用时 211 秒，主要花在从磁盘读取 1.5 GB 语料上：当时语料不在页缓存中。语料已在页缓存中时，这一步约需 20 秒，约为采样方式（02b，5 秒）的 4 倍：插桩版运行较慢。

### 02b：采样采集

[`02b-sample.sh`](practice/02b-sample.sh)：对 `rg-reloc` 本身（不是插桩版）运行同一套训练负载并采样。

```bash
perf record -e cycles:u -j any,u -o $DATA/perf/perf.data -- common/train.sh rg-reloc
perf2bolt -p $DATA/perf/perf.data -o $DATA/perf/rg.fdata rg-reloc
```

`perf record` 会跟踪 `train.sh` 启动的所有子进程；`perf2bolt` 只提取属于 `rg-reloc` 的样本。

**输出**：

```text
[ perf record: Captured and wrote 65.161 MB perf.data (83951 samples) ]
PERF2BOLT: read 83758 samples and 2666403 LBR entries
BOLT-INFO: 598 out of 7147 functions in the binary (8.4%) have non-empty execution profile
BOLT-WARNING: BOLT is estimated to optimize better with 4.8x more samples.
```

- 约 8.4 万个样本，共 267 万条分支记录，用时 5 秒。
- profile 覆盖 8.4% 的函数，约为插桩方式的一半：采样只能捕获足够热的代码。
- BOLT 提示样本再多 4.8 倍效果会更好。可以用 `perf record -F <频率>` 提高采样频率，或延长负载。

### 03：优化

[`03-optimize.sh`](practice/03-optimize.sh)：分别用两份 profile 优化 `rg-reloc`。

```bash
llvm-bolt rg-reloc -o rg-bolt      -data=$DATA/instr/merged.fdata <优化参数>
llvm-bolt rg-reloc -o rg-bolt-perf -data=$DATA/perf/rg.fdata      <优化参数>
```

优化参数为 `-reorder-blocks=ext-tsp -reorder-functions=cdsort -split-functions -split-all-cold -split-eh -icf -dyno-stats`，含义见通用文档 3.6 节。

**输出**：

| 信息 | `rg-bolt`（插桩） | `rg-bolt-perf`（采样） |
|:---|---:|---:|
| 有 profile 的函数 | 1198 / 7147（16.8%） | 576 / 7147（8.1%） |
| 基本块顺序被调整的函数 | 714 | 441 |
| ICF 合并的函数 | 70 | 27 |
| taken branches 变化 | −35.5% | −41.3% |
| 文件大小 | 12.4 MB | 12.3 MB |

- 7147 个函数中只有约 17% 在训练中执行过，其余都是冷代码。这些冷代码原本和热代码混在一起，正是布局优化的空间。
- taken branches 是 profile 上实际发生的跳转次数，下降说明基本块重排生效。两列的统计基于各自的 profile，不能直接横向比较。
- 产物比 `rg-base` 小一半多，因为 BOLT 默认丢弃了调试信息。

### 04：与 PGO 叠加

[`04-pgo-bolt.sh`](practice/04-pgo-bolt.sh)：

```bash
# PGO：插桩构建 → 训练 → 合并 → 优化构建（得到对照组 rg-pgo）
RUSTFLAGS="-Cprofile-generate=$DATA/pgo" cargo build ...         # → rg-pgo-gen
common/train.sh rg-pgo-gen
llvm-profdata merge -o $DATA/pgo/merged.profdata $DATA/pgo
RUSTFLAGS="-Cprofile-use=$DATA/pgo/merged.profdata" cargo build ...   # → rg-pgo

# PGO + 重定位，再对它重新采集 BOLT profile 并优化
RUSTFLAGS="-Cprofile-use=$DATA/pgo/merged.profdata -Clink-args=-Wl,-q" cargo build ...   # → rg-pgo-reloc
# 对 rg-pgo-reloc 重复 02a、03                                                            # → rg-pgo-bolt
```

**输出**：

```text
BOLT-INFO: 1197 out of 8012 functions in the binary (14.9%) have non-empty execution profile
           644630737 : taken branches (-7.4%)
```

跳转只减少了 7.4%，远小于单独使用 BOLT 时的 35.5%。原因是 PGO 已经按 profile 排过一次基本块，留给 BOLT 的空间变小了。

### 05：评测

[`05-bench.sh`](practice/05-bench.sh) 调用 [`common/bench.sh`](../common/bench.sh)，对每个评测用例依次：

1. **校验正确性**：各版本输出排序后计算 sha256，必须完全一致，否则报错退出。本文 7 个用例全部通过。
2. **测墙钟时间**：`hyperfine --warmup 3 --runs 50`。
3. **测硬件计数器**：`perf stat -r 5`，只统计用户态（`:u`）的 cycles、指令数、L1 i-cache 未命中、iTLB 未命中。

### 附：cargo-pgo

[`cargo-pgo.sh`](practice/cargo-pgo.sh) 用 cargo-pgo 完成与 04 相同的 PGO + BOLT 流程：

```bash
cargo pgo build                                            # PGO 插桩构建
common/train.sh target/$TARGET/release/rg                  # PGO 采集
cargo pgo bolt build --with-pgo                            # PGO 优化构建 + 带重定位 + BOLT 插桩
common/train.sh target/$TARGET/release/rg-bolt-instrumented   # BOLT 采集
cargo pgo bolt optimize --with-pgo                         # BOLT 优化 → rg-cargo-pgo-bolt
```

**输出**：

```text
INFO  cargo_pgo::bolt::optimize] Merged BOLT profile(s) to .../bolt-profiles/rg/merged.profdata.
INFO  cargo_pgo::bolt::optimize] Binary rg successfully optimized with BOLT.
```

产物 `rg-cargo-pgo-bolt` 在 word 用例上的输出与基线一致。本文没有对它做性能评测。

## 6. 结果

五个版本：`rg-base`（基线）、`rg-pgo`（仅 PGO）、`rg-bolt`（BOLT，插桩）、`rg-bolt-perf`（BOLT，采样）、`rg-pgo-bolt`（PGO + BOLT）。完整数据见 [`results.md`](practice/results.md)。

### 5.1 硬件计数器

用户态 cycles 相对 `rg-base` 的变化：

| 用例 | PGO | BOLT（插桩） | BOLT（采样） | PGO + BOLT |
|:---|---:|---:|---:|---:|
| literal | −10.7% | −9.3% | −9.7% | −14.8% |
| literal_casei | −10.7% | +0.5% | −5.1% | −10.6% |
| word | −8.9% | −8.9% | −10.5% | −11.6% |
| unicode_word | −11.5% | −10.2% | −9.4% | −13.7% |
| re_literal_suffix | −10.4% | −12.4% | −10.5% | −14.8% |
| alternates | −6.3% | +0.4% | −2.4% | −8.4% |
| no_literal | −1.8% | −2.1% | −1.1% | −2.3% |

其他计数器在 7 个用例中的变化范围：

| 指标 | PGO | BOLT（插桩） | BOLT（采样） | PGO + BOLT |
|:---|---:|---:|---:|---:|
| 指令数 | −0.6% ~ −7.4% | −0.1% ~ −3.4% | +2.9% ~ −3.4% | −0.6% ~ −7.4% |
| L1 i-cache miss | −30.3% ~ −34.5% | −41.6% ~ −49.1% | −43.7% ~ −47.8% | −44.2% ~ −50.6% |
| iTLB miss | −15.8% ~ −34.6% | −1.7% ~ −27.4% | −16.5% ~ −53.0% | −21.1% ~ −52.2% |

### 5.2 墙钟时间

| 用例 | `rg-base`（ms） | PGO | BOLT（插桩） | BOLT（采样） | PGO + BOLT |
|:---|---:|---:|---:|---:|---:|
| literal | 193.8 ± 13.2 | −9.9% | −8.7% | −6.6% | −2.7% |
| literal_casei | 197.1 ± 5.3 | −4.1% | −0.9% | −2.0% | −4.6% |
| word | 193.7 ± 16.5 | −4.1% | +0.7% | −8.3% | −10.3% |
| unicode_word | 187.4 ± 5.4 | −0.7% | −2.9% | −1.1% | −2.5% |
| re_literal_suffix | 183.0 ± 4.1 | −2.5% | −0.4% | +7.1% | −4.5% |
| alternates | 199.6 ± 4.3 | −4.6% | −2.2% | −3.7% | −5.4% |
| no_literal | 402.8 ± 9.6 | −2.2% | −5.8% | −1.8% | −2.2% |

变化在 −10.3% 到 +7.1% 之间，方向不一致，与 cycles 的变化也不对应；基线自身的标准差最高达 16.5 ms（约 9%）。因此**无法从墙钟时间得出可靠结论**。

## 7. 分析

1. **BOLT 的作用方式与原理一致**。BOLT 版的指令数几乎不变（最多 −3.4%），但 L1 i-cache 未命中减少 42%–49%。它没有减少要做的工作，而是让取指更顺畅。PGO 则相反，主要减少指令数（最多 −7.4%），i-cache 未命中只减少约三分之一。
2. **i-cache 未命中减少不一定带来 cycles 下降**。literal_casei 和 alternates 两个用例中，BOLT（插桩）版的 i-cache 未命中减少了 40% 以上，cycles 却几乎不变。一个可能的解释是这两个用例的热点集中在少数几个匹配循环里，取指本来就不是瓶颈；本文没有进一步验证。
3. **叠加效果最好**。PGO + BOLT 在 7 个用例中有 6 个 cycles 降幅最大（literal_casei 与 PGO 持平），i-cache 未命中约减半。
4. **采样与插桩效果接近**。采样版的 i-cache 未命中降幅与插桩版相当，cycles 降幅互有高低，而采集更快（页缓存命中时，采样 5 秒，插桩约 20 秒）。唯一的反常是 no_literal：采样版的指令数增加了 2.9%，在三次独立运行中都出现。一个可能的原因是采样漏掉了部分热路径，这些代码被当成冷代码拆分出去，执行时多了跳转；本文没有进一步验证。
5. **no_literal 几乎没有提升**。它的时间主要花在正则引擎的一个小循环里，这段热代码本来就很紧凑，布局优化的空间很小。
6. **墙钟时间没有稳定提升**。以 literal 为例，`rg-base` 的 CPU 时间中 User 820 ms、System 1249 ms，约 60% 花在内核态（读文件、遍历目录）。BOLT 只能优化用户态部分，提升被稀释，再加上 WSL2 下计时波动较大，最终看不出稳定的差异。
7. **单次结果有波动**。本仓库的 PGO 实践（`pgo/practice/`）用同样流程构建了 PGO 版本，与本文的 PGO 列相比，两轮的 cycles 变化大多相差 2 个百分点以内，alternates 一项相差较大（本轮 −6.3%，PGO 实践中 −10.3%）。个别用例的结论应以多轮运行为准。

**结论**：对 ripgrep 这类以 I/O 为主、热点集中的程序，BOLT 的微架构效果明显，但端到端收益有限。是否采用 BOLT，应以目标程序在自己负载上的实测为准。
