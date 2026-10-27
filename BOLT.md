# Rust 程序的 BOLT 优化

> 本文介绍 BOLT 的原理和通用操作步骤，适用于任意 Rust 程序。以 ripgrep 为例的应用示例（含复现脚本与实测数据）见 [experiments/bolt/PRACTICE.md](experiments/bolt/PRACTICE.md)。

## 1. 介绍

BOLT（Binary Optimization and Layout Tool）是 LLVM 项目中的链接后优化器：读取已链接的可执行文件，依据运行时 profile 重排其中的机器码，使热代码集中，从而减少指令缓存（i-cache）和 iTLB 未命中。它基本不改变执行的指令，只改变指令的位置，因此可以叠加在 PGO、LTO 之上，顺序为先 PGO、后 BOLT。

BOLT 适用于代码量大、取指开销高的程序，如编译器、数据库、大型服务端程序；热点很少或主要耗时在 I/O 上的程序收益有限。使用时需注意：

- 主要面向 Linux 上的 ELF 二进制（x86_64、AArch64）；macOS 仅有初步的 Mach-O 支持，Windows 不可用；
- BOLT 不随 Rust 工具链分发，需单独安装，如 apt.llvm.org 的 `bolt-N` 包；
- BOLT 自 LLVM 14 起提供。本文的命令需要 18 及以上版本（使用了 `cdsort`），14–17 版本的替代写法见 3.6 节。

## 2. 基本原理

### 2.1 工作过程

热代码分散在二进制中时，i-cache 和 iTLB 频繁未命中。编译器分别编译各 crate，再由链接器按固定规则合并，缺少全局视角；BOLT 在链接之后处理完整的机器码，可以进行全局布局。其过程为：

1. 反汇编各函数，构建控制流图（CFG），并关联 profile 中的执行次数；
2. 基本块重排：在函数内部按常执行路径顺序排列基本块，减少跳转；
3. 函数拆分：将函数拆分为热、冷两部分，冷的部分移至远处；
4. 函数重排：将经常相继调用的函数放在相邻位置；
5. 重写二进制，并修正所有受影响的地址引用。

### 2.2 前提条件

- 重定位信息：BOLT 移动函数后需要修正所有地址引用，因此链接时须保留重定位信息（`--emit-relocs`，简写 `-q`）。缺少重定位信息时，BOLT 只能在函数内部调整，收益明显降低。
- profile：可通过插桩获得（计数精确，但插桩版运行较慢），也可通过 `perf` 采样获得（开销小，精度依赖 CPU 的分支记录功能，如 Intel LBR）。两种方式都生成 `.fdata` 文件，后续步骤相同。

## 3. 操作步骤

### 3.1 流程总览

![BOLT 优化原理流程图](assets/BOLT优化原理流程图.png)

| 步骤 | 目的 | 输入 | 输出 |
|:---|:---|:---|:---|
| 0. 准备环境 | 安装 BOLT | — | `llvm-bolt`、`merge-fdata`、`perf2bolt` |
| 1. 带重定位构建 | 生成 BOLT 可重排的二进制 | 源码 | `<app>` |
| 2a. 插桩采集 | 以插桩方式获取 profile | `<app>` | `<app>.fdata` |
| 2b. 采样采集 | 以采样方式获取 profile，与 2a 二选一 | `<app>` | `<app>.fdata` |
| 3. 优化 | 依据 profile 重排二进制 | `<app>` + `<app>.fdata` | `<app>.bolt` |
| 4. 验证 | 确认行为不变、性能提升 | `<app>`、`<app>.bolt` | 对比结果 |

下文中，`<app>` 为程序名，`<workload>` 为代表实际使用场景的运行参数，`<triple>` 为目标平台（如 `x86_64-unknown-linux-gnu`）。

### 3.2 步骤 0：准备环境

**目的**：安装 BOLT 工具链。

**命令**（Ubuntu / Debian，以 LLVM 21 为例）：

```bash
wget https://apt.llvm.org/llvm.sh
sudo bash llvm.sh 21
sudo apt install bolt-21
export PATH=/usr/lib/llvm-21/bin:$PATH
```

**说明**：

| 工具 | 用途 |
|:---|:---|
| `llvm-bolt` | 插桩与优化 |
| `merge-fdata` | 合并多个 `.fdata` |
| `perf2bolt` | 将 `perf` 采样数据转换为 `.fdata`（仅采样方式需要） |

BOLT 处理的是机器码，其版本无需与 rustc 内置的 LLVM 一致。

**检查**：`llvm-bolt --version` 输出版本号。

### 3.3 步骤 1：带重定位构建

**目的**：生成保留重定位信息和符号表的二进制。

**命令**：

```bash
RUSTFLAGS="-Clink-args=-Wl,-q" cargo build --release --target <triple>
```

**说明**：

| 参数 | 含义 |
|:---|:---|
| `-Clink-args=-Wl,-q` | rustc 将 `-Wl,-q` 传给链接器，链接器保留重定位信息 |
| `--target <triple>` | 显式指定 target 后，`RUSTFLAGS` 只作用于目标程序，不作用于 build script 和过程宏 |

BOLT 依靠符号表识别函数，因此不能剥离符号表：`Cargo.toml` 的 profile 中不应设置 `strip = "symbols"` 或 `strip = true`。

**输出**：`target/<triple>/release/<app>`

**检查**：

```bash
readelf -S <app> | grep rela.text     # 有输出：重定位信息已保留
readelf -S <app> | grep symtab        # 有输出：符号表存在
```

### 3.4 步骤 2a：插桩采集

**目的**：以插桩版程序运行典型负载，获取精确的 profile。

**命令**：

```bash
# 1. 生成插桩版程序
llvm-bolt <app> -instrument -o <app>.inst \
  --instrumentation-file=/tmp/bolt/prof.fdata \
  --instrumentation-file-append-pid

# 2. 以插桩版程序运行典型负载，可多次运行
./<app>.inst <workload>

# 3. 合并多次运行的 profile
merge-fdata /tmp/bolt/prof.fdata.*.fdata > <app>.fdata
```

**说明**：

| 参数 | 含义 |
|:---|:---|
| `-instrument` | 生成插桩版程序，不做优化 |
| `-o <app>.inst` | 插桩版程序的输出路径 |
| `--instrumentation-file=<路径>` | 插桩版程序退出时 profile 的写出位置 |
| `--instrumentation-file-append-pid` | 文件名追加进程号（`prof.fdata.<pid>.fdata`），多次运行互不覆盖 |

不会主动退出的服务端程序可使用以下参数：

| 参数 | 含义 |
|:---|:---|
| `--instrumentation-sleep-time=<秒>` | 按指定间隔写出 profile，无需等待程序退出 |
| `--instrumentation-no-counters-clear` | 写出后不清零计数，profile 持续累积 |
| `--instrumentation-wait-forks` | 等待所有子进程结束后再写出 |

**输出**：`<app>.fdata`

**检查**：每次运行均生成一个非空的 `prof.fdata.<pid>.fdata`。

### 3.5 步骤 2b：采样采集

**目的**：在原程序（步骤 1 的 `<app>`）运行时采样。开销小，适用于生产环境。与步骤 2a 二选一。

**命令**（CPU 支持 LBR，例如 Intel 物理机）：

```bash
# 1. 采样
perf record -e cycles:u -j any,u -o perf.data -- ./<app> <workload>
# 2. 转换为 BOLT 的 profile
perf2bolt -p perf.data -o <app>.fdata ./<app>
```

**命令**（CPU 不支持 LBR，例如多数 AArch64 机器、部分虚拟机）：

```bash
perf record -e cycles:u -o perf.data -- ./<app> <workload>
perf2bolt -p perf.data -o <app>.fdata -nl ./<app>
```

**说明**：

| 参数 | 含义 |
|:---|:---|
| `-e cycles:u` | 仅对用户态 cycles 事件采样 |
| `-j any,u` | 同时记录用户态分支（依赖 LBR），BOLT 据此获得每次跳转的源地址和目标地址 |
| `perf2bolt -p <文件>` | 输入的 `perf.data` |
| `-nl` | 输入不含分支记录，只能统计各位置的执行次数，精度较低 |

LBR 支持情况可通过以下方式确认：用第一组命令采样后执行 `perf report -i perf.data --header-only | grep "branch stack"`，有输出即表示支持。

对运行中的服务，可使用 `perf record ... -p <pid> -- sleep 60` 采样 60 秒。

**输出**：`<app>.fdata`

### 3.6 步骤 3：优化

**目的**：依据 profile 重排步骤 1 生成的二进制。

**命令**：

```bash
llvm-bolt <app> -o <app>.bolt -data=<app>.fdata \
  -reorder-blocks=ext-tsp \
  -reorder-functions=cdsort \
  -split-functions \
  -split-all-cold \
  -split-eh \
  -icf \
  -dyno-stats
```

**说明**：输入为步骤 1 的 `<app>`，而非插桩版 `<app>.inst`。

| 参数 | 含义 | 对应 2.1 节 |
|:---|:---|:---|
| `-data=<文件>` | 使用的 profile | 关联 profile |
| `-reorder-blocks=ext-tsp` | 以 ext-tsp 算法重排函数内的基本块 | 基本块重排 |
| `-split-functions` | 将函数拆分为热、冷两部分 | 函数拆分 |
| `-split-all-cold` | 尽可能多地移出冷基本块 | 函数拆分 |
| `-split-eh` | 将异常处理代码（Rust 中即 panic 展开）移出热区 | 函数拆分 |
| `-reorder-functions=cdsort` | 以 cache-directed sort 算法重排函数 | 函数重排 |
| `-icf` | 合并机器码完全相同的函数 | — |
| `-dyno-stats` | 输出 profile 上优化前后的分支统计 | 用于检查 |

LLVM 14–17 中没有 `cdsort`，应将 `-reorder-functions=cdsort` 替换为 `-reorder-functions=hfsort+`，其余参数不变。

**输出**：`<app>.bolt`

**检查**：输出中的以下两类信息：

```text
BOLT-INFO: N out of M functions in the binary (X%) have non-empty execution profile
...
    ... : taken branches (-Y%)
```

- `X%` 为 profile 覆盖的函数比例。接近 0 表示 profile 与二进制不匹配，或负载未执行到主要代码。
- `taken branches` 为实际发生的跳转次数，下降表示基本块重排生效。

### 3.7 步骤 4：验证

**目的**：确认优化未改变程序行为，并测量性能变化。

1. 正确性：使用测试集或一组固定输入，比较 `<app>` 与 `<app>.bolt` 的输出，两者应完全一致。
2. 性能：使用与训练负载不同的输入进行测量，避免结果只反映训练数据上的表现。

```bash
# 墙钟时间
hyperfine --warmup 3 './<app> <bench>' './<app>.bolt <bench>'
# 硬件计数器：BOLT 的效果主要体现为 i-cache 和 iTLB 未命中减少
perf stat -e cycles:u,instructions:u,L1-icache-load-misses:u,iTLB-load-misses:u -- ./<app>.bolt <bench>
```

### 3.8 与 PGO 叠加（可选）

程序已采用 PGO 时，可在 PGO 的基础上再进行 BOLT 优化；否则跳过本节。做法是将步骤 1 的构建替换为带 PGO profile 的构建：

1. 按 PGO 流程获得 `merged.profdata`。
2. 使用 PGO profile 构建，同时保留重定位信息：

   ```bash
   RUSTFLAGS="-Cprofile-use=/path/to/merged.profdata -Clink-args=-Wl,-q" \
   cargo build --release --target <triple>
   ```

3. 对该二进制执行步骤 2–4。

BOLT profile 必须在 PGO 版本上重新采集。PGO 版与普通版的机器码不同，普通版上采集的 `.fdata` 不能复用。

## 4. 使用 cargo-pgo

cargo-pgo 可替代第 3 节的步骤 1–3，两种方式任选其一。得到优化版后，仍按步骤 4 验证。

项目地址：<https://crates.io/crates/cargo-pgo>

cargo-pgo 将步骤 1–3 封装为几条命令，自动添加重定位参数并管理 profile 目录。它通过 `PATH` 查找 `llvm-bolt` 和 `merge-fdata`，`cargo pgo info` 可用于检查环境。

```bash
cargo install cargo-pgo

# 仅 BOLT
cargo pgo bolt build                                            # 步骤 1 + 生成插桩版
./target/<triple>/release/<app>-bolt-instrumented <workload>    # 运行负载
cargo pgo bolt optimize                                         # 合并 profile + 步骤 3

# PGO + BOLT
cargo pgo build
./target/<triple>/release/<app> <workload>
cargo pgo bolt build --with-pgo
./target/<triple>/release/<app>-bolt-instrumented <workload>
cargo pgo bolt optimize --with-pgo
```

优化后的产物为 `target/<triple>/release/<app>-bolt-optimized`。

## 5. 注意事项

1. profile 与二进制一一对应。修改代码、修改编译选项或叠加 PGO 后，都需要重新执行步骤 1–3。
2. 训练负载应具有代表性。BOLT 只将负载中执行过的代码视为热代码。
3. 调试信息默认被丢弃。需要保留时，在步骤 3 中加 `-update-debug-sections`。
4. 插桩版运行较慢，插桩负载不宜过大；生产环境优先使用采样方式。

## 参考

- [BOLT README](https://github.com/llvm/llvm-project/blob/main/bolt/README.md)
- Jakub Beránek，[Optimizing Rust programs with PGO and BOLT using cargo-pgo](https://kobzol.github.io/rust/cargo/2023/07/28/rust-cargo-pgo.html)
