# Rust 程序的 PGO 优化

> 本文介绍 PGO 的原理和通用操作步骤，适用于任意 Rust 程序。以 ripgrep 为例的应用示例（含复现脚本与实测数据）见 [examples/pgo.md](examples/pgo.md)。

## 1. 介绍

PGO（Profile-Guided Optimization，又称反馈优化 FDO）是一种编译期优化：先以插桩版程序运行典型负载，记录各分支、各函数的执行次数（profile），再依据 profile 重新编译，以实际执行情况代替静态启发式规则指导优化。rustc 自 1.37 起通过稳定的编译选项 `-Cprofile-generate`、`-Cprofile-use` 支持 PGO，能力来自 LLVM。

PGO 适用于 CPU 密集、分支多、代码量大的程序，如编译器、解释器、数据库；主要耗时在 I/O 和系统调用上的程序收益有限。使用时需注意：

- 支持 rustc 的主流平台（Linux、macOS、Windows）；
- rustup 分发的标准库是预编译的，不参与优化，PGO 只覆盖本次构建编译的 crate 及其中实例化、内联的标准库泛型代码；
- 采样式 PGO（AutoFDO）目前仅在 nightly 中可用（`-Zprofile-sample-use`，稳定化变更已合并，里程碑为 Rust 1.100），本文只介绍插桩式。

## 2. 基本原理

PGO 分为三个阶段：

1. 插桩构建：`-Cprofile-generate` 使 LLVM 在函数入口和控制流边上插入计数器。
2. 采集：插桩版程序运行典型负载，退出时将计数写入 `.profraw` 文件。
3. 优化构建：`llvm-profdata` 将 `.profraw` 合并为 `.profdata`，再以 `-Cprofile-use` 重新编译。LLVM 据此得到各分支的概率和各函数的热度。

LLVM 利用 profile 进行的主要优化：

| 优化 | 作用 |
|:---|:---|
| 内联 | 对频繁执行的调用点积极内联，对冷调用点不内联 |
| 基本块布局 | 常执行路径按顺序排列，减少跳转 |
| 冷热分离 | 冷函数移入 `.text.unlikely` 段，热代码更紧凑 |
| 间接调用提升 | 频繁执行的间接调用（如 `dyn Trait`）特化为直接调用 |

收益主要体现为执行的指令数减少和指令缓存利用率提高。PGO 可与 BOLT 叠加，顺序为先 PGO、后 BOLT，详见 BOLT 文档。

## 3. 操作步骤

### 3.1 流程总览

![PGO 优化流程图](assets/PGO优化流程图.png)

| 步骤 | 目的 | 输入 | 输出 |
|:---|:---|:---|:---|
| 0. 准备环境 | 安装 `llvm-profdata` | — | `llvm-profdata` |
| 1. 插桩构建 | 生成记录执行次数的程序 | 源码 | 插桩版 `<app>` |
| 2. 采集 | 以插桩版运行典型负载 | 插桩版 `<app>` | `*.profraw` |
| 3. 合并 | 转换为编译器可读的格式 | `*.profraw` | `merged.profdata` |
| 4. 优化构建 | 依据 profile 重新编译 | 源码 + `merged.profdata` | 优化版 `<app>` |
| 5. 验证 | 确认行为不变、性能提升 | 普通版、优化版 `<app>` | 对比结果 |

下文中，`<app>` 为程序名，`<workload>` 为代表实际使用场景的运行参数，`<triple>` 为目标平台（如 `x86_64-unknown-linux-gnu`，可由 `rustc -vV` 输出中的 `host` 行获得）。

### 3.2 步骤 0：准备环境

**目的**：安装合并 profile 所需的 `llvm-profdata`。

**命令**：

```bash
rustup component add llvm-tools-preview
PROFDATA=$(rustc --print sysroot)/lib/rustlib/<triple>/bin/llvm-profdata
```

**说明**：`llvm-profdata` 生成的 `.profdata` 须能被 rustc 内置的 LLVM 读取。rustup 的 `llvm-tools-preview` 组件与当前工具链配套，可保证版本匹配，推荐使用；rustc 官方文档指出，较新 LLVM 或 Clang 自带的 `llvm-profdata` 通常也可用。另需 Cargo 1.39 及以上，更早的版本存在影响 PGO 的已知问题。

**检查**：`$PROFDATA --version` 能输出版本号；使用 rustup 组件时，其 LLVM 版本与 `rustc -vV` 中的 `LLVM version` 一致。

### 3.3 步骤 1：插桩构建

**目的**：生成记录各分支执行次数的程序。

**命令**：

```bash
RUSTFLAGS="-Cprofile-generate=/tmp/pgo-data" \
cargo build --release --target <triple>
```

**说明**：

| 参数 | 含义 |
|:---|:---|
| `-Cprofile-generate=<目录>` | 使 LLVM 插入计数器；插桩版程序退出时将计数写入该目录 |
| `--target <triple>` | 显式指定 target 后，`RUSTFLAGS` 只作用于目标程序，不作用于 build script 和过程宏。否则后者也会被插桩，并在构建过程中写出无关的 profile |

**输出**：`target/<triple>/release/<app>`（插桩版）

**检查**：插桩版体积明显大于普通 release 版。此时 profile 目录尚不存在，计数在运行时才产生。

### 3.4 步骤 2：采集

**目的**：以插桩版程序执行典型任务，记录实际执行路径。

**命令**：

```bash
rm -rf /tmp/pgo-data                         # 清除旧的 profile
./target/<triple>/release/<app> <workload>   # 可多次运行，使用不同输入
```

**说明**：

- 编译器只针对负载中出现的路径进行优化，负载应贴近实际用法，覆盖主要功能。
- profile 在程序正常退出时写出。被 `SIGKILL` 强制终止的进程不会写出 profile，服务端程序应通过正常的关闭流程退出。
- 默认文件名形如 `default_<签名>_<编号>.profraw`，多次运行的计数累加到同一文件。多个进程同时运行时，可设置环境变量 `LLVM_PROFILE_FILE=/tmp/pgo-data/%p.profraw`，使每个进程（`%p` 为进程号）写入独立文件。

**输出**：`/tmp/pgo-data/*.profraw`

**检查**：`ls -l /tmp/pgo-data` 中有非空的 `.profraw` 文件。

### 3.5 步骤 3：合并

**目的**：将原始计数转换为编译器可读的索引格式。

**命令**：

```bash
$PROFDATA merge -o /tmp/pgo-data/merged.profdata /tmp/pgo-data
```

**说明**：

| 参数 | 含义 |
|:---|:---|
| `merge` | 合并一个或多个 `.profraw`，输出 `.profdata` |
| `-o <文件>` | 输出文件 |
| `/tmp/pgo-data` | 输入；传入目录时读取其中所有 `.profraw`，也可逐个列出文件 |

**输出**：`/tmp/pgo-data/merged.profdata`

**检查**：`$PROFDATA show /tmp/pgo-data/merged.profdata` 输出摘要，其中 `Total count`（总计数）应非零。

### 3.6 步骤 4：优化构建

**目的**：依据 profile 重新编译。

**命令**：

```bash
RUSTFLAGS="-Cprofile-use=/tmp/pgo-data/merged.profdata -Cllvm-args=-pgo-warn-missing-function" \
cargo build --release --target <triple>
```

**说明**：

| 参数 | 含义 |
|:---|:---|
| `-Cprofile-use=<文件>` | 读取 profile，用于指导优化 |
| `-Cllvm-args=-pgo-warn-missing-function` | 函数在 profile 中缺失时发出警告，用于检查 profile 与源码是否匹配 |

源码、依赖版本和其他编译选项须与步骤 1 相同，仅将 `-Cprofile-generate` 替换为 `-Cprofile-use`。PGO 可与 LTO（`lto = "fat"`、`codegen-units = 1`）同时使用。

**输出**：`target/<triple>/release/<app>`（优化版）

**检查**：构建过程中没有大量 `no profile data available` 警告。出现大量此类警告表示 profile 与源码不匹配（例如采集后修改过代码），需从步骤 1 重新采集。

### 3.7 步骤 5：验证

**目的**：确认优化未改变程序行为，并测量性能变化。

1. 正确性：使用测试集或一组固定输入，比较普通版与优化版的输出，两者应完全一致。
2. 性能：使用与训练负载不同的输入进行测量，避免结果只反映训练数据上的表现。

```bash
# 墙钟时间
hyperfine --warmup 3 './<app>-base <bench>' './<app>-pgo <bench>'
# 硬件计数器：PGO 的效果主要体现为指令数减少
perf stat -e cycles:u,instructions:u,L1-icache-load-misses:u -- ./<app>-pgo <bench>
```

## 4. 使用 cargo-pgo

cargo-pgo 可替代第 3 节的步骤 1–4，两种方式任选其一。得到优化版后，仍按步骤 5 验证。

项目地址：<https://crates.io/crates/cargo-pgo>

cargo-pgo 将步骤 1–4 封装为几条命令，自动处理 `--target`、profile 目录和 `llvm-profdata` 路径。`cargo pgo info` 可用于检查环境。完整示例见 [examples/cargo-pgo.sh](examples/cargo-pgo.sh)。

```bash
cargo install cargo-pgo

cargo pgo build                                  # 步骤 1
./target/<triple>/release/<app> <workload>       # 步骤 2
cargo pgo optimize                               # 步骤 3 + 4
```

也可以使用测试或基准测试作为负载：`cargo pgo test`、`cargo pgo bench` 以插桩方式运行测试或基准测试并采集 profile。

## 5. 注意事项

1. profile 与源码相对应。修改过的函数无法使用旧 profile，代码变化较大时应重新执行步骤 1–3。
2. 训练负载决定优化效果。负载缺乏代表性时，实际热点可能被当作冷代码处理，导致性能下降。
3. 推荐使用 rustup 组件提供的 `llvm-profdata`，以保证与 rustc 的 LLVM 版本匹配。
4. 构建成本增加：需要两次构建和一次负载运行。CI 中可缓存 `.profdata`，仅在发版前重新采集。

## 参考

- [The rustc book：Profile-guided Optimization](https://doc.rust-lang.org/rustc/profile-guided-optimization.html)
- [Clang：Profile Guided Optimization](https://clang.llvm.org/docs/UsersManual.html#profile-guided-optimization)
- Jakub Beránek，[Optimizing Rust programs with PGO and BOLT using cargo-pgo](https://kobzol.github.io/rust/cargo/2023/07/28/rust-cargo-pgo.html)
