# Rust 程序的 BOLT 优化

> 本文介绍 BOLT 的原理和通用操作步骤，适用于任意 Rust 程序。以 ripgrep 为例的应用示例（含复现脚本与实测数据）见 [experiments/bolt/PRACTICE.md](experiments/bolt/PRACTICE.md)。

## 1. 介绍

BOLT（Binary Optimization and Layout Tool）是 LLVM 项目中的链接后优化器。它不参与编译，而是读取已链接的可执行文件，依据运行时 profile 重新排列其中的机器码，输出新的可执行文件。

BOLT 的优化对象是代码布局：将经常连续执行的指令放在相邻位置，以提高指令缓存和分支预测的效率。

适用场景：

- 代码量大、指令缓存（i-cache）和 iTLB 未命中较多的程序，例如编译器、数据库、大型服务端程序。
- 已经过 PGO、LTO 优化，需要进一步提升性能的程序。BOLT 是对编译器优化的补充。Rust 官方发布的 Linux x86_64 版 rustc 同时使用了 PGO 和 BOLT。

限制：

- 主要面向 Linux 上的 ELF 二进制。macOS 上有初步的 Mach-O 支持，Windows 上目前不可用。常用架构为 x86_64 和 AArch64，完整的支持范围以所用 LLVM 版本的文档为准。
- 收益取决于程序特征。热点代码很少，或主要耗时在 I/O 和系统调用上的程序，收益有限。

版本要求：BOLT 是 LLVM 的子项目，自 LLVM 14 起随 LLVM 发布，部分发行渠道将其作为单独的软件包提供（如 apt.llvm.org 的 `bolt-N`），需单独安装。本文的命令需要 18 及以上版本的 BOLT（使用了 `cdsort`），14–17 版本的替代写法见 3.6 节。

## 2. 基本原理

### 2.1 代码布局与取指性能

CPU 执行指令前需要完成取指：

1. 通过 iTLB 将指令的虚拟地址翻译为物理地址；
2. 从 i-cache 读取指令，未命中时从 L2、L3 或内存读取；
3. 遇到跳转时，由分支预测器决定下一条指令的地址。

iTLB 和 i-cache 容量很小（典型的 L1 i-cache 为 32 KB）。热代码分散在整个二进制中时，未命中频繁发生，CPU 需等待取指完成。

热代码分散的原因在于编译器缺少全局视角：标准库、各个 crate、C 依赖分别编译，最后由链接器按固定规则合并；编译器也不掌握运行时各分支、各函数的执行频率。

### 2.2 BOLT 的工作过程

BOLT 在链接之后运行，处理的是最终的完整机器码，并结合运行时 profile 进行优化：

1. 反汇编：读取 ELF 文件，反汇编各函数并构建控制流图（CFG）。
2. 关联 profile：将 profile 中的执行次数标注到控制流图的边上。
3. 优化布局：
   - 基本块重排：在函数内部按常执行路径顺序排列基本块，减少跳转。
   - 函数拆分：将函数拆分为热、冷两部分，冷的部分移至远处。
   - 函数重排：将经常相继调用的函数放在相邻位置。
4. 重写二进制：输出新的 ELF 文件，并修正所有受影响的地址引用。

优化后热代码集中在一块连续的较小区域，i-cache 和 iTLB 未命中减少，跳转次数也随之减少。BOLT 基本不改变执行的指令，只改变指令的位置。

### 2.3 重定位信息

重定位信息记录了二进制中各位置所引用的地址。BOLT 移动函数后，需要依据这些信息修正所有引用。

链接器默认不在输出文件中保留重定位信息，因此构建时需要加链接参数 `--emit-relocs`（简写 `-q`）。缺少重定位信息时，BOLT 只能在各函数原有位置内调整，无法移动函数，收益明显降低。

### 2.4 profile 的采集方式

BOLT 需要各分支的实际执行次数。获取方式有两种：

| 方式 | 原理 | 优点 | 缺点 |
|:---|:---|:---|:---|
| 插桩 | BOLT 在二进制的分支处插入计数器，运行插桩版程序得到 profile | 计数精确，不依赖硬件 | 插桩版程序运行明显变慢 |
| 采样 | 使用 `perf` 在原程序运行时采样，再转换为 BOLT 的 profile | 开销小，可用于生产环境 | 精度依赖 CPU 的分支记录功能（如 Intel LBR），部分 CPU 和虚拟机不提供 |

两种方式都生成 `.fdata` 文件，后续优化步骤相同。

### 2.5 与 PGO 的关系

| | PGO | BOLT |
|:---|:---|:---|
| 作用阶段 | 编译期，作用于 LLVM IR | 链接后，作用于机器码 |
| 改变内容 | 内联、分支布局等编译决策 | 指令在二进制中的位置 |
| 主要收益 | 执行的指令数减少 | i-cache / iTLB 未命中减少 |

两者可以叠加，顺序为先 PGO、后 BOLT：PGO 决定生成的机器码，BOLT 再对最终的机器码进行布局优化。

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

| 参数 | 含义 | 对应 2.2 节 |
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
