# PGO 示例：ripgrep

## 1. 概述

本示例按 [PGO.md](../../PGO.md) 第 3 节的步骤，对 ripgrep 应用 PGO：用 9 条典型搜索采集 profile，重新编译得到 PGO 版，再用 7 条评测搜索对比 PGO 版与普通版。实验对象、语料、负载、评测方法和运行环境见 [示例设计](../README.md)；用 cargo-pgo 完成同样流程的示例见 [cargo-pgo/README.md](../cargo-pgo/README.md)。

| 步骤 | 操作 | 产出 |
|:---|:---|:---|
| 0 | 检查 `llvm-profdata`，下载语料 | `work/linux-6.6/` |
| 1 | 普通构建；插桩构建（`-Cprofile-generate`） | `rg-base`；`rg-instr` |
| 2 | 以 `rg-instr` 执行 9 条训练搜索 | `work/pgo-data/*.profraw` |
| 3 | 合并 profile（`llvm-profdata merge`） | `work/pgo-data/merged.profdata` |
| 4 | 依据 profile 重新编译（`-Cprofile-use`） | `rg-pgo` |
| 5 | 以 7 条评测搜索对比 `rg-base` 与 `rg-pgo` | `results.md` |

全部步骤由 [`run.sh`](run.sh) 完成，每一步开始时打印 `==> 步骤 N：…`：

```bash
bash examples/pgo/run.sh
```

## 2. 操作步骤

以下命令和输出摘自 `run.sh` 及其在测试环境（见[示例设计](../README.md#运行环境)）中的实际运行结果。`$BIN`、`$PGO_DIR` 分别为 `work/bin`、`work/pgo-data`，`$TARGET` 为 `rustc -vV` 输出中的 `host`。

### 步骤 0：检查环境

`run.sh` 检查 `llvm-profdata` 是否存在并输出其版本，然后由 [`common/workload.sh`](../common/workload.sh) 下载并校验语料；语料已存在时跳过。

```text
LLVM version 21.1.8-rust-1.93.1-stable
.../examples/work/linux-6.6.tar.xz: OK
```

`llvm-profdata` 的 LLVM 版本与 rustc 一致（21.1.8）。

### 步骤 1：普通构建与插桩构建

```bash
cargo build --release --target $TARGET --target-dir work/target/base                               # → rg-base
RUSTFLAGS="-Cprofile-generate=$PGO_DIR" cargo build --release --target $TARGET --target-dir work/target/instr   # → rg-instr
```

```text
-rwxr-xr-x 1 root root 27M ... work/bin/rg-base
-rwxr-xr-x 1 root root 31M ... work/bin/rg-instr
```

插桩版为 31.8 MB，比普通版（27.4 MB）大约 16%，增加部分为计数器和写出 profile 的运行时代码。

### 步骤 2：采集 profile

```bash
rm -rf $PGO_DIR
../common/workload.sh train $BIN/rg-instr
```

```text
  rg mutex_lock
  rg -i spin_unlock_irqrestore
  ...
  rg --files
-rw-r--r-- 1 root root 1.9M ... default_1517753687113566901_0.profraw
```

9 条训练搜索只生成 1 个 `.profraw`：默认文件名不含进程号，各次运行的计数累加在同一文件中。

### 步骤 3：合并 profile

```bash
llvm-profdata merge -o $PGO_DIR/merged.profdata $PGO_DIR
llvm-profdata show $PGO_DIR/merged.profdata
```

```text
Maximum function count: 73393094
Maximum internal block count: 209156526
Total number of blocks: 91148
Total count: 1457440383
```

`Total count` 非零表示 profile 有效。

### 步骤 4：优化构建

```bash
RUSTFLAGS="-Cprofile-use=$PGO_DIR/merged.profdata -Cllvm-args=-pgo-warn-missing-function" \
  cargo build --release --target $TARGET --target-dir work/target/pgo                              # → rg-pgo
```

```text
缺少 profile 的函数告警：0 条
-rwxr-xr-x 1 root root 24M ... work/bin/rg-pgo
```

`run.sh` 统计构建日志中 `no profile data available` 告警的条数。0 条表示 profile 与源码匹配；使用无关程序的 profile 编译 ripgrep 时，此类告警为 8341 条。`rg-pgo` 为 24.9 MB，比普通版小约 9%，原因是 LLVM 对冷代码减少内联并按体积优化。

### 步骤 5：验证

```bash
../common/bench.sh results.md $BIN/rg-base $BIN/rg-pgo
```

评测方法见 [示例设计](../README.md#评测方法与指标)。本次运行 7 个用例的输出全部一致，结果写入 [`results.md`](results.md)。

## 3. 结果

`run.sh` 全程用时 354 秒，含语料下载。

`rg-pgo` 相对 `rg-base` 的用户态硬件计数器变化：

| 用例 | cycles | 指令数 | L1 i-cache miss | iTLB miss |
|:---|---:|---:|---:|---:|
| literal | −11.9% | −7.4% | −33.0% | −38.5% |
| literal_casei | −10.3% | −4.2% | −32.8% | −26.6% |
| word | −11.2% | −7.4% | −31.8% | −42.1% |
| unicode_word | −10.4% | −4.9% | −29.8% | −30.1% |
| re_literal_suffix | −9.8% | −7.3% | −30.6% | −36.1% |
| alternates | −12.5% | −4.2% | −34.1% | −35.8% |
| no_literal | −1.5% | +11.1% | −30.9% | −42.3% |

墙钟时间：

| 用例 | `rg-base`（ms） | `rg-pgo`（ms） | 变化 |
|:---|---:|---:|---:|
| literal | 194.8 ± 8.9 | 189.8 ± 14.6 | −2.6% |
| literal_casei | 213.0 ± 9.6 | 206.6 ± 10.9 | −3.0% |
| word | 199.8 ± 11.0 | 197.8 ± 18.8 | −1.0% |
| unicode_word | 204.6 ± 13.0 | 197.5 ± 8.9 | −3.5% |
| re_literal_suffix | 213.0 ± 28.0 | 201.3 ± 21.2 | −5.5% |
| alternates | 232.4 ± 29.9 | 204.9 ± 5.0 | −11.8% |
| no_literal | 438.5 ± 40.0 | 420.8 ± 20.2 | −4.0% |

前六个用例的指令数减少 4.2%–7.4%，cycles 减少 9.8%–12.5%；七个用例的 L1 i-cache 未命中均减少约三分之一。这与 PGO 的作用方式一致：内联和分支布局减少了执行的指令，热代码更集中。

no_literal 的 cycles 只减少 1.5%，指令数增加 11.1%。该用例的耗时集中在正则引擎的一个小循环内；指令数增加的原因本文未分析。

墙钟时间的变化与标准差处于同一量级，不能据此判断端到端性能。以 literal 为例，`rg-base` 的 CPU 时间为 User 974 ms、System 1343 ms，约 58% 为内核态（读文件、遍历目录），PGO 只作用于用户态代码。
