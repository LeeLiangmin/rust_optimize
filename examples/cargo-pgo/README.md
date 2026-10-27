# cargo-pgo 示例：ripgrep

## 1. 概述

本示例用 [cargo-pgo](https://crates.io/crates/cargo-pgo) 0.3.0 对 ripgrep 完成 PGO 以及 PGO + BOLT，流程与 [PGO 示例](../pgo/README.md)、[BOLT 示例](../bolt/README.md)中的“与 PGO 叠加”相同。cargo-pgo 自动设置 `--target`、profile 目录、`llvm-profdata` 路径和 BOLT 所需的重定位参数，并通过 `PATH` 查找 `llvm-bolt` 和 `merge-fdata`。用法说明见 [PGO.md](../../PGO.md) 第 4 节和 [BOLT.md](../../BOLT.md) 第 5 节；实验对象、负载和运行环境见 [示例设计](../README.md)。

| 步骤 | 操作 | 产出 |
|:---|:---|:---|
| 0 | 检查环境，下载语料（已存在时跳过） | — |
| 1 | `cargo pgo build`：PGO 插桩构建 | 插桩版 `rg` |
| 2 | 以训练负载运行插桩版 | `pgo-profiles/*.profraw` |
| 3 | `cargo pgo optimize`：合并 profile 并优化构建 | `rg-cargo-pgo` |
| 4 | `cargo pgo bolt build --with-pgo`：PGO 优化构建并生成 BOLT 插桩版 | `rg-bolt-instrumented` |
| 5 | 以训练负载运行 BOLT 插桩版 | `bolt-profiles/rg/*.fdata` |
| 6 | `cargo pgo bolt optimize --with-pgo`：PGO 优化构建并执行 BOLT 优化 | `rg-cargo-pgo-bolt` |
| 7 | 比较各版本与普通版的输出 | 输出摘要 |

全部步骤由 [`run.sh`](run.sh) 完成。脚本以 PGO 示例生成的 `rg-base` 作为输出对照，因此先运行 PGO 示例；步骤 4–6 需要 BOLT 工具位于 `PATH` 中。

```bash
cargo install cargo-pgo
bash examples/pgo/run.sh
bash examples/cargo-pgo/run.sh
```

## 2. 操作步骤

以下命令和输出摘自 `run.sh` 及其在测试环境（见[示例设计](../README.md#运行环境)）中的实际运行结果。命令在 `subjects/ripgrep/` 下执行；`CARGO_TARGET_DIR` 设为 `work/target/cargo-pgo`，`$OUT` 为其下的 `x86_64-unknown-linux-gnu/release`；输出中的长路径以 `...` 代替，时间戳已删除。

### 步骤 0：检查环境

`cargo pgo info` 检查 rustc 版本和所需工具：

```text
[rustc version]: 1.93.1 is recent enough
[llvm-profdata]: found at .../lib/rustlib/x86_64-unknown-linux-gnu/bin/llvm-profdata
[llvm-bolt]: found at /usr/lib/llvm-21/bin/llvm-bolt
[merge-fdata]: found at /usr/lib/llvm-21/bin/merge-fdata
```

### 步骤 1–3：PGO

```bash
cargo pgo build                                  # 插桩构建
../../common/workload.sh train $OUT/rg           # 采集
cargo pgo optimize                               # 合并并优化构建
```

`cargo pgo build` 清空 profile 目录，构建插桩版，并提示多进程或并行运行时可设置 `LLVM_PROFILE_FILE=.../pgo-profiles/rg_%m_%p.profraw`。`cargo pgo optimize` 的输出：

```text
INFO  cargo_pgo::pgo::optimize] Found 1 PGO profile file with total size 1.80 MiB at .../pgo-profiles.
INFO  cargo_pgo::pgo::optimize] Merged PGO profile(s) to .../pgo-profiles/merged-<hash>.profdata.
INFO  cargo_pgo::pgo::optimize] PGO-optimized binary rg built successfully.
PGO optimized build successfully finished.
```

产物复制为 `rg-cargo-pgo`，25.4 MB。

### 步骤 4–6：PGO + BOLT

```bash
cargo pgo bolt build --with-pgo                            # PGO 优化构建并生成 BOLT 插桩版
../../common/workload.sh train $OUT/rg-bolt-instrumented   # 采集
cargo pgo bolt optimize --with-pgo                         # PGO 优化构建并执行 BOLT 优化
```

`--with-pgo` 使两条命令都以步骤 3 合并的 PGO profile 构建。`cargo pgo bolt optimize --with-pgo` 的输出：

```text
INFO  cargo_pgo::bolt::optimize] Binary rg built successfully. It will be now optimized with BOLT.
INFO  cargo_pgo::bolt::optimize] Merged BOLT profile(s) to .../bolt-profiles/rg/merged.profdata.
INFO  cargo_pgo::bolt::optimize] Binary rg successfully optimized with BOLT. You can find it at $OUT/rg-bolt-optimized.
```

产物 `rg-bolt-optimized` 复制为 `rg-cargo-pgo-bolt`，28.9 MB。

### 步骤 7：验证

比较各版本在 `rg -w PM_RESUME` 上排序后输出的 sha256（前 16 位）：

```text
rg-base              69ac725be6017a0d
rg-cargo-pgo         69ac725be6017a0d
rg-cargo-pgo-bolt    69ac725be6017a0d
```

三者一致。本示例只验证 cargo-pgo 的流程和产物的正确性，未对产物进行性能评测。`run.sh` 全程用时 349 秒。
