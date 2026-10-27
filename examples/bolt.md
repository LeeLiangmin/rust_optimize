# BOLT 示例：ripgrep

## 1. 概述

本示例按 [BOLT.md](../BOLT.md) 第 3 节的步骤，对 ripgrep 14.1.1（源码位于 `examples/ripgrep/`，未修改）应用 BOLT：分别以插桩和采样方式采集 profile，生成 BOLT 版；再在 PGO 版的基础上执行 BOLT，生成 PGO + BOLT 版；最后用 7 条评测搜索对比各版本与普通版。语料、训练负载和评测负载与 [PGO 示例](pgo.md) 相同。ripgrep 是示例程序，同一流程适用于其他 Rust 程序。

| 步骤 | 操作 | 产出 |
|:---|:---|:---|
| 0 | 检查 BOLT 工具及版本，下载语料 | `work/linux-6.6/` |
| 1 | 普通构建；带重定位构建（`-Wl,-q`） | `rg-base`；`rg-reloc` |
| 2a | 插桩：`llvm-bolt -instrument` 生成插桩版，执行 9 条训练搜索，`merge-fdata` 合并 | `work/bolt-data/instr/merged.fdata` |
| 2b | 采样：以 `rg-reloc` 执行训练搜索，`perf record` 采样，`perf2bolt` 转换；CPU 不支持 LBR 时跳过 | `work/bolt-data/perf/rg.fdata` |
| 3 | 以两份 profile 分别优化 `rg-reloc` | `rg-bolt`；`rg-bolt-perf` |
| 3.8 | 用 PGO profile 构建带重定位的版本，重复插桩采集和优化 | `rg-pgo-bolt` |
| 4 | 以 7 条评测搜索对比各版本与 `rg-base` | `results/bolt.md` |

全部步骤由 [`bolt.sh`](bolt.sh) 完成，每一步开始时打印 `==> 步骤 N：…`。步骤 3.8 使用 `pgo.sh` 生成的 PGO profile，且步骤 4 的对比包含 `pgo.sh` 生成的 `rg-pgo`，因此先运行 `pgo.sh`：

```bash
bash examples/pgo.sh
bash examples/bolt.sh
```

未运行 `pgo.sh` 时，`bolt.sh` 跳过步骤 3.8，其余步骤正常执行。

## 2. 环境要求

Linux（x86_64 或 AArch64）；rustup 工具链；18 及以上版本的 BOLT 工具 `llvm-bolt`、`merge-fdata`、`perf2bolt`，位于 `PATH` 中（apt.llvm.org 的 `bolt-21` 安装在 `/usr/lib/llvm-21/bin`）；`perf`（需能读取硬件计数器）、`hyperfine`、`curl`；步骤 2b 需要 CPU 支持 LBR；约 3 GB 磁盘空间。产物目录和 WSL 下的注意事项与 [PGO 示例](pgo.md) 相同。

## 3. 操作步骤

以下命令和输出摘自 `bolt.sh` 及其在测试环境（第 5 节）中的实际运行结果。`$BIN`、`$DATA` 分别为 `work/bin`、`work/bolt-data`；`<优化参数>` 为 `-reorder-blocks=ext-tsp -reorder-functions=cdsort -split-functions -split-all-cold -split-eh -icf -dyno-stats`，含义见 BOLT.md 3.6 节。

### 步骤 0：检查环境

`bolt.sh` 检查 `llvm-bolt` 是否在 `PATH` 中，以及版本是否为 18 及以上，然后下载语料（已存在时跳过）。

```text
BOLT 版本：21
```

### 步骤 1：普通构建与带重定位构建

```bash
cargo build --release --target $TARGET --target-dir work/target/base                           # → rg-base
RUSTFLAGS="-Clink-args=-Wl,-q" cargo build --release --target $TARGET --target-dir work/target/reloc   # → rg-reloc
readelf -S $BIN/rg-reloc | grep -q rela.text && echo "重定位信息已保留"
```

```text
重定位信息已保留
-rwxr-xr-x 1 root root 27M ... work/bin/rg-base
-rwxr-xr-x 1 root root 50M ... work/bin/rg-reloc
```

`rg-reloc` 为 52.2 MB，普通版为 27.4 MB，增加部分为重定位信息。重定位信息不改变代码，因此性能对比以 `rg-base` 为基线。ripgrep 的 release profile 未剥离符号表，满足 BOLT 的输入要求。

### 步骤 2a：插桩采集

```bash
llvm-bolt $BIN/rg-reloc -instrument -o $DATA/instr/rg.inst \
  --instrumentation-file=$DATA/instr/prof.fdata --instrumentation-file-append-pid
./workload.sh train $DATA/instr/rg.inst
merge-fdata $DATA/instr/prof.fdata.*.fdata > $DATA/instr/merged.fdata
```

```text
BOLT-WARNING: debug info will be stripped from the binary. Use -update-debug-sections to keep it.
  rg mutex_lock
  ...
Profile from 9 files merged.
profile 文件数： 9
```

插桩版 `rg.inst` 为 26.2 MB。9 次运行各生成一个 `prof.fdata.<pid>.fdata`（2.1–2.5 MB），合并为 `merged.fdata`。

### 步骤 2b：采样采集

```bash
perf record -e cycles:u -j any,u -o $DATA/perf/perf.data -- ./workload.sh train $BIN/rg-reloc
perf2bolt -p $DATA/perf/perf.data -o $DATA/perf/rg.fdata $BIN/rg-reloc
```

```text
[ perf record: Captured and wrote 67.328 MB .../perf.data (86719 samples) ]
PERF2BOLT: read 86685 samples and 2759779 LBR entries
BOLT-INFO: 580 out of 7147 functions in the binary (8.1%) have non-empty execution profile
```

采样对 `rg-reloc` 本身进行，不需要插桩版。`perf record` 跟踪 `workload.sh` 启动的所有子进程，`perf2bolt` 只提取属于 `rg-reloc` 的样本。采样得到的 profile 覆盖 8.1% 的函数，约为插桩方式的一半，因为采样只能捕获执行足够频繁的代码。

### 步骤 3：优化

```bash
llvm-bolt $BIN/rg-reloc -o $BIN/rg-bolt      -data=$DATA/instr/merged.fdata <优化参数>
llvm-bolt $BIN/rg-reloc -o $BIN/rg-bolt-perf -data=$DATA/perf/rg.fdata      <优化参数>
```

`bolt.sh` 只显示 BOLT 输出中的 profile 覆盖率、基本块重排和跳转统计：

```text
BOLT-INFO: 1197 out of 7147 functions in the binary (16.7%) have non-empty execution profile
BOLT-INFO: basic block reordering modified layout of 714 functions (59.65% of profiled, 10.08% of total)
           656075104 : taken branches (-36.0%)
-rwxr-xr-x 1 root root 12M ... work/bin/rg-bolt
BOLT-INFO: 559 out of 7147 functions in the binary (7.8%) have non-empty execution profile
BOLT-INFO: basic block reordering modified layout of 429 functions (76.74% of profiled, 6.02% of total)
              922208 : taken branches (-41.6%)
-rwxr-xr-x 1 root root 12M ... work/bin/rg-bolt-perf
```

插桩 profile 覆盖 16.7% 的函数，其余为冷代码。`taken branches` 为 profile 上实际发生的跳转次数，其下降表示基本块重排生效；两组数据分别基于各自的 profile，不能直接比较。产物为 12.3–12.4 MB，小于普通版，原因是 BOLT 默认丢弃调试信息。

### 步骤 3.8：与 PGO 叠加

```bash
RUSTFLAGS="-Cprofile-use=work/pgo-data/merged.profdata -Clink-args=-Wl,-q" \
  cargo build --release --target $TARGET --target-dir work/target/pgo-reloc                     # → rg-pgo-reloc
# 对 rg-pgo-reloc 重复步骤 2a 和步骤 3                                                          # → rg-pgo-bolt
```

```text
BOLT-INFO: 1205 out of 8016 functions in the binary (15.0%) have non-empty execution profile
BOLT-INFO: basic block reordering modified layout of 523 functions (43.40% of profiled, 6.55% of total)
           648513944 : taken branches (-7.6%)
```

BOLT profile 在 PGO 版上重新采集。跳转次数减少 7.6%，小于单独使用 BOLT 时的 36.0%，因为 PGO 已依据 profile 调整过基本块布局。

### 步骤 4：验证

```bash
./bench.sh results/bolt.md $BIN/rg-base $BIN/rg-pgo $BIN/rg-bolt $BIN/rg-bolt-perf $BIN/rg-pgo-bolt
```

评测方法与 [PGO 示例](pgo.md) 的步骤 5 相同。本次运行 7 个用例中五个版本的输出全部一致，结果写入 [`results/bolt.md`](results/bolt.md)。

## 4. 使用 cargo-pgo

[`cargo-pgo.sh`](cargo-pgo.sh) 的步骤 4–6 用 cargo-pgo 完成与步骤 3.8 相同的 PGO + BOLT 流程（其步骤 1–3 为 PGO，见 [PGO 示例](pgo.md) 第 4 节）。cargo-pgo 自动添加重定位参数，并通过 `PATH` 查找 `llvm-bolt` 和 `merge-fdata`。

```bash
(cd ripgrep && cargo pgo bolt build --with-pgo)              # PGO 优化构建并生成 BOLT 插桩版
./workload.sh train $OUT/rg-bolt-instrumented                # 采集
(cd ripgrep && cargo pgo bolt optimize --with-pgo)           # BOLT 优化 → rg-cargo-pgo-bolt
```

```text
INFO  cargo_pgo::bolt::instrument] Binary rg instrumented successfully. Now run .../rg-bolt-instrumented on your workload.
INFO  cargo_pgo::bolt::optimize] Merged BOLT profile(s) to .../bolt-profiles/rg/merged.profdata.
INFO  cargo_pgo::bolt::optimize] Binary rg successfully optimized with BOLT.
```

`cargo-pgo.sh` 最后比较产物与 `rg-base` 在 `rg -w PM_RESUME` 上的输出 sha256，两者一致。`rg-cargo-pgo-bolt` 为 28.9 MB，未对其进行性能评测。

## 5. 结果

测试环境：Intel Core i7-9750H（支持 LBR），WSL2 Ubuntu 24.04，rustc 1.93.1，BOLT 21.1.8。`bolt.sh` 全程用时 567 秒。

用户态 cycles 相对 `rg-base` 的变化：

| 用例 | PGO | BOLT（插桩） | BOLT（采样） | PGO + BOLT |
|:---|---:|---:|---:|---:|
| literal | −11.4% | −10.5% | −10.8% | −15.4% |
| literal_casei | −11.8% | −4.8% | −7.6% | −13.5% |
| word | −15.2% | −11.6% | −11.4% | −16.8% |
| unicode_word | −11.5% | −10.6% | −8.9% | −13.0% |
| re_literal_suffix | −12.4% | −12.9% | −10.6% | −14.7% |
| alternates | −10.0% | −4.0% | −7.7% | −12.1% |
| no_literal | −1.5% | −1.9% | −0.9% | −1.7% |

其他计数器在 7 个用例中的变化范围：

| 指标 | PGO | BOLT（插桩） | BOLT（采样） | PGO + BOLT |
|:---|---:|---:|---:|---:|
| 指令数 | +11.1% ~ −7.4% | 0.0% ~ −3.5% | +2.9% ~ −3.4% | +11.1% ~ −7.5% |
| L1 i-cache miss | −30.3% ~ −34.0% | −44.3% ~ −48.1% | −43.7% ~ −47.3% | −44.4% ~ −48.8% |
| iTLB miss | −22.7% ~ −38.5% | +4.5% ~ −53.4% | +24.9% ~ −39.1% | −40.4% ~ −54.7% |

墙钟时间：

| 用例 | `rg-base`（ms） | PGO | BOLT（插桩） | BOLT（采样） | PGO + BOLT |
|:---|---:|---:|---:|---:|---:|
| literal | 184.8 ± 4.2 | −2.9% | +5.5% | +8.6% | +6.0% |
| literal_casei | 221.8 ± 6.1 | −4.0% | −2.1% | −1.4% | +0.4% |
| word | 185.6 ± 3.2 | −1.8% | +23.1% | +3.2% | −3.4% |
| unicode_word | 191.5 ± 4.7 | −4.1% | −3.2% | +5.6% | −5.0% |
| re_literal_suffix | 188.9 ± 5.4 | −3.9% | −4.1% | −4.1% | +11.5% |
| alternates | 209.5 ± 9.7 | +1.0% | +0.7% | −5.3% | −6.1% |
| no_literal | 407.0 ± 9.4 | −0.5% | −0.2% | +6.9% | +5.5% |

BOLT 版的指令数基本不变（变化不超过 3.5%），L1 i-cache 未命中减少 44.3%–48.1%，与 BOLT 只改变代码布局的原理一致；PGO 主要减少指令数。literal_casei 和 alternates 中，BOLT（插桩）版的 i-cache 未命中减少超过 46%，cycles 只减少 4.8% 和 4.0%。

采样方式的 i-cache 未命中降幅与插桩方式接近，profile 采集不需要插桩版。no_literal 中采样版的指令数增加 2.9%，原因本文未分析。

PGO + BOLT 在 6 个用例中 cycles 降幅最大，i-cache 未命中减少 44.4%–48.8%。no_literal 的耗时集中在正则引擎的一个小循环内，各版本的 cycles 变化均不超过 2%；PGO 版和 PGO + BOLT 版在该用例中的指令数增加 11.1%，原因本文未分析。

墙钟时间的变化方向不一致，与 cycles 的变化也不对应（BOLT 插桩版在 word 中的标准差为 39.7 ms），不能据此判断端到端性能。ripgrep 在该负载下的 CPU 时间约 58% 为内核态（见 [PGO 示例](pgo.md) 第 5 节），BOLT 只作用于用户态代码。
