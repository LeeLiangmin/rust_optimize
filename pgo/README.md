# Rust 程序的 PGO 优化

> 本文介绍 PGO 的原理和通用操作步骤，适用于任意 Rust 程序。以 ripgrep 为例的完整实践、复现脚本与实测数据见 [practice/](practice/README.md)。

## 1. 介绍

PGO（Profile-Guided Optimization，基于剖析数据的优化，也称反馈优化 FDO）是一种**编译期优化**。它先让程序在典型负载下运行，记录每个分支、每个函数的实际执行次数（profile），再把这份 profile 交给编译器重新编译。编译器据此做优化决策，而不是依赖静态规则去猜。

rustc 基于 LLVM，PGO 能力直接来自 LLVM，通过 `-Cprofile-generate` 和 `-Cprofile-use` 两个稳定的编译选项使用。

**适用场景**：

- CPU 密集、分支多、代码量大的程序，例如编译器、解释器、数据库、序列化库。Rust 官方发布的 Linux x86_64 版 rustc 就使用了 PGO。
- 能够构造出代表真实使用场景的负载的程序。

**限制**：

- 收益取决于程序本身。时间主要花在 I/O 和系统调用上的程序，收益有限。
- 需要多一次构建和一次负载运行，构建流程更复杂。
- 平台限制很少：rustc 支持的主流平台（Linux、macOS、Windows）都可以使用。

## 2. 基本原理

### 2.1 编译器为什么需要运行时信息

编译器优化时要不断做判断，但很多判断依赖运行时才知道的信息：

| 问题 | 没有运行时信息时 |
|:---|:---|
| 这个分支通常走哪边？ | 按静态规则猜，例如"循环通常继续" |
| 这个函数值不值得内联？ | 只看函数大小，不知道调用点是否频繁 |
| 哪些代码是热点？ | 无从区分，热代码与冷代码混在一起 |
| `dyn Trait` 调用通常落到哪个实现？ | 只能保留间接调用 |

猜错的代价是：常走的路径上多了跳转，热调用点没有内联，冷代码挤占了指令缓存。

### 2.2 PGO 的三个阶段

1. **插桩构建**：`-Cprofile-generate` 让 LLVM 在函数入口和控制流的边上插入计数器。得到的插桩版程序功能不变，但更大、更慢。
2. **采集**：用插桩版程序运行典型负载。程序退出时，计数器的值写入 `.profraw` 文件。
3. **使用**：先用 `llvm-profdata` 把 `.profraw` 合并、转换为编译器可读的 `.profdata`，再用 `-Cprofile-use` 重新编译。LLVM 把计数换算为每个分支的概率和每个函数的热度，用于指导后续优化。

### 2.3 profile 指导了哪些优化

| 优化 | 有 profile 后的变化 |
|:---|:---|
| 内联 | 热调用点更积极地内联，冷调用点不内联，避免代码膨胀 |
| 基本块布局 | 常走的路径排成顺序执行（fall-through），减少跳转 |
| 冷热分离 | 冷函数放入 `.text.unlikely` 段，热代码更紧凑 |
| 寄存器分配 | 溢出（spill）代码尽量放在冷路径上 |
| 间接调用提升 | 热的间接调用（如 `dyn Trait`）被特化为直接调用，进而可以内联 |

收益来自两方面：**执行的指令更少**（内联消除了调用开销和冗余跳转），**指令缓存利用率更高**（热代码更集中）。

### 2.4 插桩式与采样式

上面描述的是**插桩式 PGO**：计数精确，但需要专门构建一个插桩版程序。

另一种是**采样式 PGO**（AutoFDO）：直接用 `perf` 对普通程序采样，再转换为 profile。它开销小，可以在生产环境采集，但精度较低。rustc 目前只在 nightly 版本中通过不稳定选项 `-Zprofile-sample-use` 支持采样式 PGO，因此本文只介绍插桩式。

### 2.5 与 BOLT 的关系

| | PGO | BOLT |
|:---|:---|:---|
| 作用阶段 | 编译期，作用于 LLVM IR | 链接后，作用于机器码 |
| 改变什么 | 内联、分支布局等编译决策 | 指令在二进制中的位置 |
| 主要收益 | 执行的指令更少 | i-cache / iTLB 未命中更少 |

两者可以叠加，顺序必须是**先 PGO，后 BOLT**，详见 [BOLT 文档](../bolt/README.md)。

## 3. 操作步骤

### 3.1 流程总览

![PGO 优化流程图](../assets/PGO优化流程图.png)

| 步骤 | 目的 | 输入 | 输出 |
|:---|:---|:---|:---|
| 0. 准备环境 | 安装 `llvm-profdata` | — | `llvm-profdata` |
| 1. 插桩构建 | 得到会记录执行次数的程序 | 源码 | 插桩版 `<app>` |
| 2. 采集 | 用插桩版运行典型负载 | 插桩版 `<app>` | `*.profraw` |
| 3. 合并 | 转换为编译器可读的格式 | `*.profraw` | `merged.profdata` |
| 4. 优化构建 | 按 profile 重新编译 | 源码 + `merged.profdata` | 优化版 `<app>` |
| 5. 验证 | 确认行为不变、性能提升 | 普通版、优化版 `<app>` | 对比结果 |

下文用 `<app>` 表示你的程序名，`<workload>` 表示能代表真实使用场景的运行参数，`<triple>` 表示目标平台（如 `x86_64-unknown-linux-gnu`，可用 `rustc -vV` 中的 `host` 一行查看）。

### 3.2 步骤 0：准备环境

**目的**：安装合并 profile 用的 `llvm-profdata`。

**命令**：

```bash
rustup component add llvm-tools-preview
PROFDATA=$(rustc --print sysroot)/lib/rustlib/<triple>/bin/llvm-profdata
```

**说明**：`llvm-profdata` 的 LLVM 版本必须与 rustc 内置的 LLVM 一致，否则无法读取或生成兼容的 profile。rustup 的 `llvm-tools-preview` 组件与当前工具链配套，可以保证这一点。不要使用系统包管理器安装的其他版本。

**检查**：`$PROFDATA --version` 输出的 LLVM 版本与 `rustc -vV` 中的 `LLVM version` 相同。

### 3.3 步骤 1：插桩构建

**目的**：得到一个会记录每个分支执行次数的程序。

**命令**：

```bash
RUSTFLAGS="-Cprofile-generate=/tmp/pgo-data" \
cargo build --release --target <triple>
```

**说明**：

| 参数 | 含义 |
|:---|:---|
| `-Cprofile-generate=<目录>` | 让 LLVM 插入计数器；插桩版程序退出时把计数写到该目录 |
| `--target <triple>` | 显式指定 target 后，`RUSTFLAGS` 只作用于目标程序，不作用于 build script 和过程宏。否则它们也会被插桩，在构建过程中写出无关的 profile |

**输出**：`target/<triple>/release/<app>`（插桩版）

**检查**：插桩版明显比普通 release 版大。此时 profile 目录还不存在，计数要到运行时才产生。

### 3.4 步骤 2：采集

**目的**：用插桩版程序执行典型任务，记录真实的执行路径。

**命令**：

```bash
rm -rf /tmp/pgo-data                     # 清掉旧的 profile
./target/<triple>/release/<app> <workload>   # 可以运行多次、使用不同的输入
```

**说明**：

- 编译器只会针对负载中出现的路径做优化，负载必须贴近真实用法，覆盖主要功能。
- profile 在程序**正常退出**时写出。被 `SIGKILL` 强制终止的进程不会写出 profile；服务端程序应通过正常的关闭流程退出。
- 默认文件名形如 `default_<签名>_<编号>.profraw`，多次运行的计数累加到同一文件。多个进程**同时**运行时，可以设置环境变量 `LLVM_PROFILE_FILE=/tmp/pgo-data/%p.profraw`，让每个进程（`%p` 为进程号）写入独立的文件。

**输出**：`/tmp/pgo-data/*.profraw`

**检查**：`ls -l /tmp/pgo-data` 能看到非空的 `.profraw` 文件。

### 3.5 步骤 3：合并

**目的**：把原始计数转换为编译器可读的索引格式。

**命令**：

```bash
$PROFDATA merge -o /tmp/pgo-data/merged.profdata /tmp/pgo-data
```

**说明**：

| 参数 | 含义 |
|:---|:---|
| `merge` | 合并一个或多个 `.profraw`，输出 `.profdata` |
| `-o <文件>` | 输出文件 |
| `/tmp/pgo-data` | 输入；传目录时读取其中所有 `.profraw`，也可以逐个列出文件 |

**输出**：`/tmp/pgo-data/merged.profdata`

**检查**：`$PROFDATA show /tmp/pgo-data/merged.profdata` 输出摘要，其中 `Total count`（总计数）应当非零。

### 3.6 步骤 4：优化构建

**目的**：让编译器按 profile 重新编译。

**命令**：

```bash
RUSTFLAGS="-Cprofile-use=/tmp/pgo-data/merged.profdata -Cllvm-args=-pgo-warn-missing-function" \
cargo build --release --target <triple>
```

**说明**：

| 参数 | 含义 |
|:---|:---|
| `-Cprofile-use=<文件>` | 读取 profile，用于指导优化 |
| `-Cllvm-args=-pgo-warn-missing-function` | 函数在 profile 中找不到时发出警告，用于检查 profile 是否与源码匹配 |

源码、依赖版本和其他编译选项必须与步骤 1 相同，只把 `-Cprofile-generate` 换成 `-Cprofile-use`。PGO 可以与 LTO（`lto = "fat"`、`codegen-units = 1`）同时使用。

**输出**：`target/<triple>/release/<app>`（优化版）

**检查**：构建过程中没有大量 `no profile data available` 警告。大量警告说明 profile 与源码不匹配，例如采集后修改过代码，需要回到步骤 1 重新采集。

### 3.7 步骤 5：验证

**目的**：先确认优化没有改变程序行为，再确认性能提升。

1. **正确性**：用测试集或一组固定输入，比较普通版与优化版的输出，必须完全一致。
2. **性能**：用**不同于**训练负载的输入测量，避免只在训练数据上表现好。

```bash
# 墙钟时间
hyperfine --warmup 3 './<app>-base <bench>' './<app>-pgo <bench>'
# 硬件计数器：PGO 的效果应主要体现为指令数减少
perf stat -e cycles:u,instructions:u,L1-icache-load-misses:u -- ./<app>-pgo <bench>
```

### 3.8 使用 cargo-pgo 简化

[cargo-pgo](https://github.com/Kobzol/cargo-pgo) 把步骤 1–4 封装为命令，自动处理 `--target`、profile 目录和 `llvm-profdata` 路径。可用 `cargo pgo info` 检查环境。

```bash
cargo install cargo-pgo

cargo pgo build                                  # 步骤 1
./target/<triple>/release/<app> <workload>       # 步骤 2
cargo pgo optimize                               # 步骤 3 + 4
```

也可以用测试或基准测试作为负载：`cargo pgo test`、`cargo pgo bench` 会以插桩方式运行它们并采集 profile。

## 4. 注意事项

1. **profile 与源码对应**。改动过的函数无法使用旧 profile。代码变化较大时要重新执行步骤 1–3。
2. **训练负载决定效果**。负载缺乏代表性时，真实热点会被当成冷代码处理，程序反而可能变慢。
3. **工具版本要一致**。`llvm-profdata` 必须与 rustc 的 LLVM 版本相同。
4. **构建成本增加**。需要构建两次，中间还要运行一次负载。CI 中可以缓存 `.profdata`，只在发版前重新采集。

## 参考

- [The rustc book：Profile-guided Optimization](https://doc.rust-lang.org/rustc/profile-guided-optimization.html)
- [Clang：Profile Guided Optimization](https://clang.llvm.org/docs/UsersManual.html#profile-guided-optimization)
- Jakub Beránek，[Optimizing Rust programs with PGO and BOLT using cargo-pgo](https://kobzol.github.io/rust/cargo/2023/07/28/rust-cargo-pgo.html)
