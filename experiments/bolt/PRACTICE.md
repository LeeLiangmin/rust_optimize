# BOLT 应用示例：ripgrep

本示例对 Rust 项目 ripgrep 实际应用一次 BOLT：先构建保留重定位信息的 ripgrep，让它执行一组典型搜索，分别用插桩和采样两种方式采集运行时 profile；再用 BOLT 依据 profile 重排二进制，得到 BOLT 版 ripgrep；另外在 PGO 版的基础上再做一次 BOLT。最后在另一组搜索上将各版本与普通版对比，确认输出一致，并测量性能变化。

通过这个示例可以看到：

- BOLT 在一个实际 Rust 项目中的完整操作，即 [BOLT 通用文档](../../BOLT.md) 中各步骤的具体命令和实际输出；
- 插桩与采样两种 profile 采集方式的用法和效果差异；
- 在 PGO 的基础上叠加 BOLT 的做法；
- 如何测量并判断优化是否按原理生效。

全部步骤由脚本完成，运行 `bash experiments/bolt/practice/run.sh` 即可复现，结果写入 [`practice/results.md`](practice/results.md)。ripgrep 仅作为示例程序，相同的流程适用于其他 Rust 程序。

## 1. 示例说明

示例程序为 [ripgrep](https://github.com/BurntSushi/ripgrep) 14.1.1（命令行文本搜索工具，源码未修改，位于 [`experiments/subjects/ripgrep/`](../subjects/ripgrep)），语料为 Linux 6.6 内核源码（81,703 个文件，1.5 GB）。profile 由 9 条典型搜索（训练负载）采集，评测使用另外 7 条搜索（评测负载）。共构建五个版本：

| 版本 | 构建方式 | 用途 |
|:---|:---|:---|
| `rg-base` | 普通 release 构建 | 对照组 |
| `rg-bolt` | BOLT，插桩方式采集 profile | 演示 BOLT 的基本流程 |
| `rg-bolt-perf` | BOLT，采样方式采集 profile | 与插桩方式对比 |
| `rg-pgo` | 仅 PGO | 叠加效果的对照 |
| `rg-pgo-bolt` | 先 PGO，再 BOLT | 演示与 PGO 叠加 |

评测先确认各版本输出一致，再测量墙钟时间，以及 `perf` 读取的用户态硬件计数器（cycles、指令数、L1 i-cache 和 iTLB 未命中）。硬件计数器只反映 ripgrep 自身代码的开销，比墙钟时间稳定。

## 2. 运行

环境要求：Linux（x86_64 或 AArch64）、rustup 工具链（含 `llvm-tools-preview`）、18 及以上版本的 BOLT 工具（`llvm-bolt`、`merge-fdata`、`perf2bolt`）、`perf`（需能读取硬件计数器）、`hyperfine`、`curl`；采样方式需要 CPU 支持 LBR，`cargo-pgo` 为可选项。约需 3 GB 磁盘空间。

```bash
bash experiments/bolt/practice/run.sh
```

`run.sh` 依次执行下表中的脚本（除 `experiments/common/corpus.sh` 外均位于 `practice/`），任一步骤失败即停止。各脚本也可单独运行。

| 脚本 | 内容 | 对应通用文档 | 本文用时 |
|:---|:---|:---|---:|
| `00-check-env.sh` | 检查平台、工具及版本、硬件计数器、LBR，缺失时给出安装方法 | 步骤 0 | 10 秒 |
| `common/corpus.sh` | 下载并校验语料（已存在则跳过） | — | 视网速 |
| `01-build.sh` | 构建基线版和带重定位版 | 步骤 1 | 55 秒 |
| `02a-instrument.sh` | 插桩采集 | 步骤 2a | 211 秒（语料未缓存） |
| `02b-sample.sh` | 采样采集（不支持 LBR 时跳过） | 步骤 2b | 5 秒 |
| `03-optimize.sh` | BOLT 优化 | 步骤 3 | 2 秒 |
| `04-pgo-bolt.sh` | 与 PGO 叠加 | 3.8 节 | 89 秒 |
| `05-bench.sh` | 评测所有版本，结果写入 [`results.md`](practice/results.md) | 步骤 4 | 455 秒 |
| `cargo-pgo.sh` | 可选，不在 `run.sh` 中：用 cargo-pgo 完成 04 的 PGO + BOLT | 第 4 节 | 67 秒 |

语料、构建产物和 profile 存放在 `experiments/work/`（仓库位于 WSL 的 Windows 盘时为 `~/rust_optimize_work`），可用环境变量 `WORK_DIR` 修改；BOLT 工具目录默认自动探测，可用 `LLVM_BIN` 指定；语料下载源可用 `KERNEL_MIRROR` 修改，国内可使用 `https://mirrors.tuna.tsinghua.edu.cn/kernel`。

## 3. 负载

训练负载（[`common/train.sh`](../common/train.sh)）覆盖 ripgrep 的常见用法：

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

评测负载（[`common/bench.sh`](../common/bench.sh)）取自 ripgrep 作者的基准集，与训练负载不重复：

| 用例 | 命令 |
|:---|:---|
| literal | `rg PM_RESUME` |
| literal_casei | `rg -i PM_RESUME` |
| word | `rg -w PM_RESUME` |
| unicode_word | `rg '\wAh'` |
| re_literal_suffix | `rg '[A-Z]+_RESUME'` |
| alternates | `rg 'ERR_SYS\|PME_TURN_OFF\|LINK_REQ_RST\|CFG_BME_EVT'` |
| no_literal | `rg '\w{5}\s+\w{5}\s+\w{5}\s+\w{5}\s+\w{5}'` |

## 4. 分步说明

`$BIN`、`$DATA` 分别指 `$WORK_DIR/bolt/bin`、`$WORK_DIR/bolt/data`。

### 01：构建

```bash
cargo build --release --target $TARGET                                   # → rg-base
RUSTFLAGS="-Clink-args=-Wl,-q" cargo build --release --target $TARGET    # → rg-reloc
```

`rg-base` 为 26.9 MB，`rg-reloc` 为 52.2 MB，增加部分为重定位信息，脚本通过 `readelf -S rg-reloc | grep rela.text` 确认其已保留。重定位信息不改变代码本身，性能对比以 `rg-base` 为基线。ripgrep 的 release profile 未剥离符号表，满足 BOLT 的输入要求。

### 02a：插桩采集

```bash
llvm-bolt rg-reloc -instrument -o rg.inst \
  --instrumentation-file=$DATA/instr/prof.fdata --instrumentation-file-append-pid
common/train.sh rg.inst
merge-fdata $DATA/instr/prof.fdata.*.fdata > $DATA/instr/merged.fdata
```

9 次运行生成 9 个 `prof.fdata.<pid>.fdata`，每个 2.0–2.4 MB。语料在页缓存中时本步骤约需 20 秒，约为采样方式的 4 倍。

### 02b：采样采集

```bash
perf record -e cycles:u -j any,u -o $DATA/perf/perf.data -- common/train.sh rg-reloc
perf2bolt -p $DATA/perf/perf.data -o $DATA/perf/rg.fdata rg-reloc
```

```text
PERF2BOLT: read 83758 samples and 2666403 LBR entries
BOLT-INFO: 598 out of 7147 functions in the binary (8.4%) have non-empty execution profile
BOLT-WARNING: BOLT is estimated to optimize better with 4.8x more samples.
```

采样对 `rg-reloc` 本身进行，用时 5 秒。profile 覆盖 8.4% 的函数，约为插桩方式的一半；可通过 `perf record -F <频率>` 或延长负载增加样本数。

### 03：优化

```bash
llvm-bolt rg-reloc -o rg-bolt      -data=$DATA/instr/merged.fdata <优化参数>
llvm-bolt rg-reloc -o rg-bolt-perf -data=$DATA/perf/rg.fdata      <优化参数>
```

优化参数含义见通用文档 3.6 节。BOLT 输出的关键信息：

| 项目 | `rg-bolt`（插桩） | `rg-bolt-perf`（采样） |
|:---|---:|---:|
| 有 profile 的函数 | 1198 / 7147（16.8%） | 576 / 7147（8.1%） |
| 基本块顺序被调整的函数 | 714 | 441 |
| taken branches 变化 | −35.5% | −41.3% |
| 文件大小 | 12.4 MB | 12.3 MB |

约 17% 的函数在训练中被执行，其余为冷代码，这是布局优化的空间所在。taken branches 下降表明基本块重排生效（两列分别基于各自的 profile，不能直接比较）。产物变小是因为 BOLT 默认丢弃调试信息。

### 04：与 PGO 叠加

```bash
# PGO：插桩构建 → 训练 → 合并 → 优化构建，得到 rg-pgo
RUSTFLAGS="-Cprofile-generate=$DATA/pgo" cargo build ...
common/train.sh rg-pgo-gen
llvm-profdata merge -o $DATA/pgo/merged.profdata $DATA/pgo
RUSTFLAGS="-Cprofile-use=$DATA/pgo/merged.profdata" cargo build ...

# PGO + 重定位构建 rg-pgo-reloc，再对其重复 02a、03，得到 rg-pgo-bolt
RUSTFLAGS="-Cprofile-use=$DATA/pgo/merged.profdata -Clink-args=-Wl,-q" cargo build ...
```

BOLT 输出 `taken branches (-7.4%)`，远小于单独使用 BOLT 时的 35.5%：PGO 已依据 profile 调整过基本块布局。

### 05：评测

对每个评测用例，先比较各版本输出排序后的 sha256（本文全部一致），再执行 `hyperfine --warmup 3 --runs 50` 和 `perf stat -r 5`。

### cargo-pgo 方式（可选）

```bash
cargo pgo build
common/train.sh target/$TARGET/release/rg
cargo pgo bolt build --with-pgo
common/train.sh target/$TARGET/release/rg-bolt-instrumented
cargo pgo bolt optimize --with-pgo                            # → rg-cargo-pgo-bolt
```

产物 `rg-cargo-pgo-bolt` 的输出与基线一致，未对其进行性能评测。

## 5. 结果

测试环境：Intel Core i7-9750H（支持 LBR）、WSL2 Ubuntu 24.04、rustc 1.93.1、BOLT 21.1.8。完整数据见 [`results.md`](practice/results.md)。

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

墙钟时间：

| 用例 | `rg-base`（ms） | PGO | BOLT（插桩） | BOLT（采样） | PGO + BOLT |
|:---|---:|---:|---:|---:|---:|
| literal | 193.8 ± 13.2 | −9.9% | −8.7% | −6.6% | −2.7% |
| literal_casei | 197.1 ± 5.3 | −4.1% | −0.9% | −2.0% | −4.6% |
| word | 193.7 ± 16.5 | −4.1% | +0.7% | −8.3% | −10.3% |
| unicode_word | 187.4 ± 5.4 | −0.7% | −2.9% | −1.1% | −2.5% |
| re_literal_suffix | 183.0 ± 4.1 | −2.5% | −0.4% | +7.1% | −4.5% |
| alternates | 199.6 ± 4.3 | −4.6% | −2.2% | −3.7% | −5.4% |
| no_literal | 402.8 ± 9.6 | −2.2% | −5.8% | −1.8% | −2.2% |

## 6. 分析

1. 作用方式与原理一致：BOLT 版的指令数基本不变（最多 −3.4%），L1 i-cache 未命中减少 42%–49%；PGO 则主要减少指令数。
2. i-cache 未命中减少不一定带来 cycles 下降：literal_casei 和 alternates 中，BOLT（插桩）版的 i-cache 未命中减少 40% 以上，cycles 基本不变，可能是因为这两个用例的取指并非瓶颈（未进一步验证）。
3. 叠加效果最好：PGO + BOLT 在 7 个用例中有 6 个 cycles 降幅最大，i-cache 未命中约减少一半。
4. 采样与插桩效果接近，且采集更快。例外是 no_literal：采样版的指令数增加 2.9%，在三次独立运行中均出现，可能是采样遗漏了部分热路径（未进一步验证）。
5. 墙钟时间的变化（−10.3% 到 +7.1%）方向不一致，与 cycles 也不对应，没有稳定差异。在该负载下，ripgrep 约 60% 的 CPU 时间花在内核态，用户态的收益被稀释。

结论：BOLT 对 ripgrep 在微架构层面的效果明显，与 PGO 叠加效果最好，但在以 I/O 为主的负载下端到端收益有限。实际收益应以目标程序在自身负载上的测量为准。
