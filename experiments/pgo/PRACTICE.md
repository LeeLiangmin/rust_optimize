# PGO 应用示例：ripgrep

本示例对 Rust 项目 ripgrep 实际应用一次 PGO：先让 ripgrep 执行一组典型搜索，采集其运行时 profile；再用这份 profile 重新编译，得到 PGO 版 ripgrep；最后在另一组搜索上将 PGO 版与普通版对比，确认两者输出一致，并测量性能变化。

通过这个示例可以看到：

- PGO 在一个实际 Rust 项目中的完整操作，即 [PGO 通用文档](../../PGO.md) 中各步骤的具体命令和实际输出；
- 每一步如何检查是否成功，例如 profile 是否有效、是否与源码匹配；
- 如何测量并判断优化是否按原理生效。

全部步骤由脚本完成，运行 `bash experiments/pgo/practice/run.sh` 即可复现，结果写入 [`practice/results.md`](practice/results.md)。ripgrep 仅作为示例程序，相同的流程适用于其他 Rust 程序。

## 1. 示例说明

示例程序为 [ripgrep](https://github.com/BurntSushi/ripgrep) 14.1.1（命令行文本搜索工具，源码未修改，位于 [`experiments/subjects/ripgrep/`](../subjects/ripgrep)），语料为 Linux 6.6 内核源码（81,703 个文件，1.5 GB）。流程如下：

1. 构建普通版 `rg-base` 和插桩版 `rg-instr`；
2. 以插桩版在语料上执行 9 条典型搜索（训练负载），采集 profile；
3. 合并 profile，重新编译得到 `rg-pgo`；
4. 以另外 7 条搜索（评测负载，与训练负载不重复）对比 `rg-base` 与 `rg-pgo`。

评测先确认两个版本输出一致，再测量墙钟时间，以及 `perf` 读取的用户态硬件计数器（cycles、指令数、L1 i-cache 和 iTLB 未命中）。硬件计数器只反映 ripgrep 自身代码的开销，比墙钟时间稳定。

## 2. 运行

环境要求：Linux、rustup 工具链（含 `llvm-tools-preview`）、`perf`（需能读取硬件计数器）、`hyperfine`、`curl`；`cargo-pgo` 为可选项。约需 2.5 GB 磁盘空间。

```bash
bash experiments/pgo/practice/run.sh
```

`run.sh` 依次执行下表中的脚本（除 `experiments/common/corpus.sh` 外均位于 `practice/`），任一步骤失败即停止。各脚本也可单独运行。

| 脚本 | 内容 | 对应通用文档 | 本文用时 |
|:---|:---|:---|---:|
| `00-check-env.sh` | 检查平台、工具、硬件计数器，缺失时给出安装方法 | 步骤 0 | 1 秒 |
| `common/corpus.sh` | 下载并校验语料（已存在则跳过） | — | 视网速 |
| `01-build.sh` | 构建基线版和插桩版 | 步骤 1 | 43 秒 |
| `02-collect.sh` | 以插桩版运行训练负载 | 步骤 2 | 204 秒（语料未缓存） |
| `03-merge.sh` | 合并 profile | 步骤 3 | 0 秒 |
| `04-optimize.sh` | 依据 profile 重新编译 | 步骤 4 | 20 秒 |
| `05-bench.sh` | 评测，结果写入 [`results.md`](practice/results.md) | 步骤 5 | 185 秒 |
| `cargo-pgo.sh` | 可选，不在 `run.sh` 中：用 cargo-pgo 完成 01–04 | 第 4 节 | 46 秒 |

语料、构建产物和 profile 存放在 `experiments/work/`（仓库位于 WSL 的 Windows 盘时为 `~/rust_optimize_work`），可用环境变量 `WORK_DIR` 修改；语料下载源可用 `KERNEL_MIRROR` 修改，国内可使用 `https://mirrors.tuna.tsinghua.edu.cn/kernel`。

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

评测负载（[`common/bench.sh`](../common/bench.sh)）取自 ripgrep 作者的基准集：

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

`$BIN`、`$PGO_DIR` 分别指 `$WORK_DIR/pgo/bin`、`$WORK_DIR/pgo/data/profile`。

### 01：构建

```bash
cargo build --release --target $TARGET                                         # → rg-base
RUSTFLAGS="-Cprofile-generate=$PGO_DIR" cargo build --release --target $TARGET  # → rg-instr
```

`rg-base` 为 26.9 MB，插桩版 `rg-instr` 为 31.8 MB，增加部分为计数器和写出 profile 的运行时代码。

### 02：采集

```bash
rm -rf $PGO_DIR
common/train.sh rg-instr
```

生成 1 个 1.9 MB 的 `default_<签名>_0.profraw`：默认文件名不含进程号，9 次运行的计数累加在同一文件中。语料在页缓存中时，本步骤约需 5 秒。

### 03：合并

```bash
llvm-profdata merge -o $PGO_DIR/merged.profdata $PGO_DIR
llvm-profdata show $PGO_DIR/merged.profdata
```

```text
Maximum function count: 71371764
Total number of blocks: 91148
Total count: 1423882864
```

计数非零，profile 有效。

### 04：优化构建

```bash
RUSTFLAGS="-Cprofile-use=$PGO_DIR/merged.profdata -Cllvm-args=-pgo-warn-missing-function" \
  cargo build --release --target $TARGET                                       # → rg-pgo
```

脚本统计构建日志中 `no profile data available` 告警的条数，本文为 0 条，表明 profile 与源码匹配（作为对照，使用无关程序的 profile 时会产生 8341 条）。`rg-pgo` 为 24.9 MB，比基线小 7%：LLVM 对冷代码减少内联并按体积优化。

### 05：评测

对每个评测用例，先比较两个版本输出排序后的 sha256（本文全部一致），再执行 `hyperfine --warmup 3 --runs 50` 和 `perf stat -r 5`。

### cargo-pgo 方式（可选）

```bash
cargo pgo build
common/train.sh target/$TARGET/release/rg
cargo pgo optimize                               # → rg-cargo-pgo
```

产物 `rg-cargo-pgo` 的输出与基线一致，未对其进行性能评测。

## 5. 结果

测试环境：Intel Core i7-9750H、WSL2 Ubuntu 24.04、rustc 1.93.1（LLVM 21.1.8）。完整数据见 [`results.md`](practice/results.md)。

`rg-pgo` 相对 `rg-base` 的变化（用户态硬件计数器）：

| 用例 | cycles | 指令数 | L1 i-cache miss | iTLB miss |
|:---|---:|---:|---:|---:|
| literal | −12.4% | −7.3% | −33.6% | −28.3% |
| literal_casei | −10.5% | −4.2% | −32.6% | −23.8% |
| word | −10.0% | −7.3% | −32.8% | −29.0% |
| unicode_word | −10.5% | −5.0% | −34.0% | −30.5% |
| re_literal_suffix | −10.6% | −7.3% | −34.4% | −31.1% |
| alternates | −10.3% | −4.2% | −34.1% | −24.5% |
| no_literal | −1.5% | −0.6% | −33.0% | −40.4% |

墙钟时间：

| 用例 | `rg-base`（ms） | `rg-pgo`（ms） | 变化 |
|:---|---:|---:|---:|
| literal | 190.0 ± 9.9 | 189.6 ± 13.0 | −0.2% |
| literal_casei | 207.7 ± 7.5 | 203.1 ± 10.9 | −2.2% |
| word | 191.6 ± 14.5 | 185.2 ± 8.3 | −3.3% |
| unicode_word | 200.4 ± 16.4 | 194.1 ± 20.3 | −3.1% |
| re_literal_suffix | 189.7 ± 9.7 | 179.2 ± 3.6 | −5.5% |
| alternates | 196.9 ± 5.3 | 192.3 ± 5.3 | −2.3% |
| no_literal | 397.6 ± 9.6 | 403.1 ± 21.0 | +1.4% |

## 6. 分析

1. 作用方式与原理一致：7 个用例中有 6 个指令数减少 4.2%–7.3%、cycles 减少约 10%–12%；全部用例的 L1 i-cache 未命中减少约三分之一。
2. no_literal 几乎没有提升：其耗时集中在正则引擎的一个小循环内，热代码本已紧凑，PGO 的调整空间很小。
3. 墙钟时间的变化（−5.5% 到 +1.4%）与标准差处于同一量级，没有稳定差异。在该负载下，ripgrep 约 60% 的 CPU 时间花在内核态（读文件、遍历目录），用户态的收益被稀释。

结论：PGO 对 ripgrep 用户态代码的优化效果明显（cycles 约 −10%），但在以 I/O 为主的负载下端到端收益有限。实际收益应以目标程序在自身负载上的测量为准。
