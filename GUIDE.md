# Rust 程序反馈式优化指导

## 1 概述

反馈式优化依据程序运行时采集的 profile 指导优化，无需修改源码。本手册说明三项反馈式优化技术：

| 技术 | 作用阶段 | 作用 |
|:---|:---|:---|
| PGO | 编译期 | 依据 profile 调整内联、分支布局等编译决策 |
| FGO | 编译期 | 华为毕昇编译器的自研特性，先由 profile 生成可审计的反馈信息文件，再据此优化编译 |
| BOLT | 链接后 | 依据 profile 重排二进制中的机器码，使热代码集中 |

PGO 与 BOLT 可以单独使用，也可以叠加使用，叠加时先 PGO、后 BOLT。

Rust 对 PGO 和 BOLT 的支持情况：

| 项目 | PGO | BOLT |
|:---|:---|:---|
| 支持方式 | rustc 自 1.37 起提供稳定的编译选项 `-Cprofile-generate`、`-Cprofile-use` | 单独安装 LLVM 的 BOLT 工具（LLVM 14 起提供）；构建时以 `-Clink-args=-Wl,-q` 保留重定位信息 |
| 所需工具 | `llvm-profdata`，由 rustup 组件 `llvm-tools-preview` 提供 | `llvm-bolt`、`merge-fdata`；采样方式另需 `perf`、`perf2bolt` |
| profile 采集 | 插桩；采样式 PGO（`-Zprofile-sample-use`）仅在 nightly 中可用，稳定化变更已合并，里程碑为 1.100 | 插桩或 `perf` 采样 |
| 平台 | rustc 支持的主流平台（Linux、macOS、Windows） | Linux ELF（x86_64、AArch64）；macOS 仅有初步的 Mach-O 支持；Windows 不可用 |
| 主要限制 | rustup 分发的标准库为预编译，不参与优化 | 默认丢弃调试信息 |

rustc 目前不支持 FGO，见第 3 章。社区工具 [cargo-pgo](https://crates.io/crates/cargo-pgo) 将 PGO 和 BOLT 的构建、采集和合并封装为 Cargo 子命令，见第 6 章。

第 2–4 章分别说明 PGO、FGO、BOLT，第 5 章说明 PGO 与 BOLT 叠加，第 6 章说明 cargo-pgo，第 7 章以 ripgrep 为实践案例给出完整的操作记录和实测数据。第 2、4–6 章的内容适用于任意 Rust 程序。

## 2 PGO

### 2.1 简介

PGO（Profile-Guided Optimization，又称反馈优化 FDO）是一种编译期优化：先以插桩版程序运行典型负载，记录各分支、各函数的执行次数（profile），再依据 profile 重新编译，以实际执行情况代替静态启发式规则指导优化。

PGO 适用于 CPU 密集、分支多、代码量大的程序，如编译器、解释器、数据库。主要耗时在 I/O 和系统调用上的程序收益有限。PGO 只覆盖本次构建编译的 crate，以及在其中实例化、内联的标准库泛型代码。本手册只介绍插桩式 PGO。ripgrep 上的实测效果见 7.6 节。

### 2.2 优化原理

PGO 分为三个阶段：

1. 插桩构建：`-Cprofile-generate` 使 LLVM 在函数入口和控制流边上插入计数器。
2. 采集：插桩版程序运行典型负载，退出时将计数写入 `.profraw` 文件。
3. 优化构建：`llvm-profdata` 将 `.profraw` 合并为 `.profdata`，再以 `-Cprofile-use` 重新编译。

LLVM 利用 profile 进行的主要优化：

| 优化 | 作用 |
|:---|:---|
| 内联 | 对频繁执行的调用点积极内联，对冷调用点不内联 |
| 基本块布局 | 常执行路径按顺序排列，减少跳转 |
| 冷热分离 | 冷函数移入 `.text.unlikely` 段，热代码更紧凑 |
| 间接调用提升 | 频繁执行的间接调用特化为直接调用 |

收益主要体现为执行的指令数减少和指令缓存利用率提高。

### 2.3 使用方法

![PGO 优化流程图](assets/PGO优化流程图.png)

| 步骤 | 目的 | 输入 | 输出 |
|:---|:---|:---|:---|
| 0. 准备环境 | 安装 `llvm-profdata` | — | `llvm-profdata` |
| 1. 插桩构建 | 生成记录执行次数的程序 | 源码 | 插桩版 `<app>` |
| 2. 采集 | 以插桩版运行典型负载 | 插桩版 `<app>` | `*.profraw` |
| 3. 合并 | 转换为编译器可读的格式 | `*.profraw` | `merged.profdata` |
| 4. 优化构建 | 依据 profile 重新编译 | 源码 + `merged.profdata` | 优化版 `<app>` |
| 5. 验证 | 确认行为不变并测量性能 | 普通版、优化版 `<app>` | 对比结果 |

下文中，`<app>` 为程序名，`<workload>` 为代表实际使用场景的运行参数，`<triple>` 为目标平台（如 `x86_64-unknown-linux-gnu`，由 `rustc -vV` 输出中的 `host` 行获得）。

步骤 0：准备环境。安装合并 profile 所需的 `llvm-profdata`。

```bash
rustup component add llvm-tools-preview
PROFDATA=$(rustc --print sysroot)/lib/rustlib/<triple>/bin/llvm-profdata
```

`llvm-profdata` 生成的 `.profdata` 须能被 rustc 内置的 LLVM 读取。rustup 的 `llvm-tools-preview` 组件与当前工具链配套，版本一致；rustc 官方文档指出，较新 LLVM 或 Clang 自带的 `llvm-profdata` 通常也可用。Cargo 需为 1.39 及以上，更早的版本存在影响 PGO 的已知问题。检查方法：`$PROFDATA --version` 输出的 LLVM 版本应与 `rustc -vV` 中的 `LLVM version` 一致。

步骤 1：插桩构建。生成记录各分支执行次数的程序。

```bash
RUSTFLAGS="-Cprofile-generate=/tmp/pgo-data" \
cargo build --release --target <triple>
```

| 参数 | 含义 |
|:---|:---|
| `-Cprofile-generate=<目录>` | 使 LLVM 插入计数器；插桩版程序退出时将计数写入该目录 |
| `--target <triple>` | 显式指定 target 后，`RUSTFLAGS` 只作用于目标程序，不作用于 build script 和过程宏；否则后者也会被插桩，并在构建过程中写出无关的 profile |

产物为 `target/<triple>/release/<app>`，体积明显大于普通 release 版。profile 目录在程序运行时才生成。

步骤 2：采集。以插桩版程序执行典型任务。

```bash
rm -rf /tmp/pgo-data                         # 清除旧的 profile
./target/<triple>/release/<app> <workload>   # 可多次运行，使用不同输入
```

编译器只针对负载中出现的路径进行优化，负载应贴近实际用法，覆盖主要功能。默认文件名形如 `default_<签名>_<编号>.profraw`，多次运行的计数累加到同一文件。检查方法：采集完成后，`/tmp/pgo-data` 中应有非空的 `.profraw` 文件。

步骤 3：合并。将原始计数转换为编译器可读的索引格式。

```bash
$PROFDATA merge -o /tmp/pgo-data/merged.profdata /tmp/pgo-data
```

| 参数 | 含义 |
|:---|:---|
| `merge` | 合并一个或多个 `.profraw`，输出 `.profdata` |
| `-o <文件>` | 输出文件 |
| `/tmp/pgo-data` | 输入；传入目录时读取其中所有 `.profraw`，也可逐个列出文件 |

检查方法：`$PROFDATA show /tmp/pgo-data/merged.profdata` 输出摘要，其中 `Total count`（总计数）应非零。

步骤 4：优化构建。依据 profile 重新编译。

```bash
RUSTFLAGS="-Cprofile-use=/tmp/pgo-data/merged.profdata -Cllvm-args=-pgo-warn-missing-function" \
cargo build --release --target <triple>
```

| 参数 | 含义 |
|:---|:---|
| `-Cprofile-use=<文件>` | 读取 profile，用于指导优化 |
| `-Cllvm-args=-pgo-warn-missing-function` | 函数在 profile 中缺失时发出警告，用于检查 profile 与源码是否匹配 |

源码、依赖版本和其他编译选项须与步骤 1 相同，仅将 `-Cprofile-generate` 替换为 `-Cprofile-use`。PGO 可与 LTO（`lto = "fat"`、`codegen-units = 1`）同时使用。产物为 `target/<triple>/release/<app>`。检查方法：构建过程中出现大量 `no profile data available` 警告时，表示 profile 与源码不匹配（例如采集后修改过代码），需从步骤 1 重新采集。

步骤 5：验证。

1. 正确性：使用测试集或一组固定输入，比较普通版与优化版的输出，两者应完全一致。
2. 性能：使用与训练负载不同的输入测量，避免结果只反映训练数据上的表现。

```bash
hyperfine --warmup 3 './<app>-base <bench>' './<app>-pgo <bench>'                   # 墙钟时间
perf stat -e cycles:u,instructions:u,L1-icache-load-misses:u -- ./<app>-pgo <bench>   # 用户态硬件计数器
```

PGO 的效果主要体现为用户态指令数减少。

### 2.4 注意事项

1. profile 与源码相对应。修改过的函数无法使用旧 profile，代码变化较大时应重新执行步骤 1–3。
2. 负载缺乏代表性时，实际热点可能被当作冷代码处理，导致性能下降。
3. profile 在插桩版程序正常退出时写出，被 `kill -9`（`SIGKILL`）终止的进程不写出 profile。服务端程序应通过正常的关闭流程退出。
4. 程序无法正常退出时，可用 gdb 附加到进程，调用插桩运行时的 `__llvm_profile_write_file()` 写出 profile。该方法要求二进制未剥离符号表；在 ripgrep 插桩版上调用后，即使随后以 `kill -9` 终止进程，写出的 `.profraw` 也能正常合并。

   ```bash
   cat > gdb.cmd <<'EOF'
   set height 0
   call (int)__llvm_profile_write_file()
   detach
   quit
   EOF
   gdb -batch -x gdb.cmd -p <pid>     # 输出 $1 = 0 表示写出成功
   ```

5. 多个进程同时运行时，应设置环境变量 `LLVM_PROFILE_FILE=/tmp/pgo-data/%p.profraw`，使每个进程（`%p` 为进程号）写入独立文件，避免多进程写同一文件导致 profile 异常（如合并时报 `counter overflow`）。
6. 构建成本增加：需要两次构建和一次负载运行。CI 中可缓存 `.profdata`，仅在发版前重新采集。

## 3 FGO

### 3.1 简介

FGO 是 HCC 在毕昇编译器上构建的自研反馈优化特性，在华为 ICT 各产品线的应用中取得了性能收益。FGO 沿用 PGO 的插桩和采集流程，区别在于优化构建之前增加一次编译：依据 profile 生成反馈信息文件 `profile.cfg`，再以 `profile.cfg` 指导优化编译。`profile.cfg` 便于审计，可在优化构建前检查编译器将依据哪些反馈信息进行优化。

本章内容来自毕昇编译器的使用说明，未在本手册的环境中验证。

### 3.2 与 PGO 的差别

| 项目 | PGO | FGO |
|:---|:---|:---|
| 插桩与采集 | `-fprofile-generate`，运行负载得到 `.profraw` | 与 PGO 相同 |
| 合并 | `llvm-profdata merge` 得到 `.profdata` | 与 PGO 相同 |
| 生成反馈信息 | 无此步骤 | `-fprofile-use` 与 `-ffgo-feature-gen` 共同使用，依据 profile 生成 `profile.cfg` |
| 优化构建 | `-fprofile-use=<.profdata>` | `-ffgo-feature-use=profile.cfg` |
| 编译次数 | 2 次（插桩构建、优化构建） | 3 次（插桩构建、生成 `profile.cfg`、优化构建） |
| 审计 | 优化直接使用 `.profdata` | 可在优化构建前审计 `profile.cfg` |

### 3.3 使用方法（毕昇编译器）

1. 构建插桩版：

   ```bash
   clang <编译选项> -fprofile-generate=/path/pgo-data ...
   ```

2. 以插桩版运行典型负载，在 `/path/pgo-data` 下得到 `default_*.profraw`。
3. 合并 profile：

   ```bash
   llvm-profdata merge -o ir.profdata /path/pgo-data/*.profraw
   ```

4. 依据 profile 重新编译，生成可审计的 `profile.cfg`。这一步为 FGO 特有：

   ```bash
   clang <编译选项> -fprofile-use=ir.profdata -ffgo-feature-gen=profile.cfg ...
   ```

5. 以 `profile.cfg` 编译优化版：

   ```bash
   clang <编译选项> -ffgo-feature-use=profile.cfg ...
   ```

### 3.4 Rust 中的现状

rustc 未提供与 `-ffgo-feature-gen`、`-ffgo-feature-use` 对应的选项，目前没有在 Rust 程序上应用 FGO 的已知方法。以下问题待确认：

- 这两个选项由毕昇的 clang 前端处理，还是实现在 LLVM 优化层。
- 若实现在 LLVM 层，能否通过 `-Cllvm-args` 传给 rustc 内置的 LLVM。
- rustc 内置的 LLVM 来自上游 LLVM，不含毕昇的自研特性；在 Rust 中使用 FGO 是否需要基于毕昇 LLVM 构建的 rustc。

## 4 BOLT

### 4.1 简介

BOLT（Binary Optimization and Layout Tool）是 LLVM 项目中的链接后优化器：读取已链接的可执行文件，依据运行时 profile 重排其中的机器码，使热代码集中，从而减少指令缓存（i-cache）和 iTLB 未命中。BOLT 基本不改变执行的指令，只改变指令的位置，因此可以叠加在 PGO、LTO 之上。

BOLT 适用于代码量大、取指开销高的程序，如编译器、数据库、大型服务端程序。热点很少或主要耗时在 I/O 上的程序收益有限。BOLT 处理机器码，其版本无需与 rustc 内置的 LLVM 一致。ripgrep 上的实测效果见 7.6 节。

### 4.2 优化原理

编译器分别编译各 crate，再由链接器按固定规则合并，热代码分散在二进制中，导致 i-cache 和 iTLB 频繁未命中。BOLT 在链接之后处理完整的机器码，过程如下：

1. 反汇编各函数，构建控制流图（CFG），并关联 profile 中的执行次数；
2. 基本块重排：在函数内部按常执行路径顺序排列基本块，减少跳转；
3. 函数拆分：将函数拆分为热、冷两部分，冷的部分移至远处；
4. 函数重排：将经常相继调用的函数放在相邻位置；
5. 重写二进制，并修正所有受影响的地址引用。

profile 可通过插桩获得（计数精确，插桩版运行较慢），也可通过 `perf` 采样获得（开销小，精度依赖 CPU 的分支记录功能，如 Intel LBR）。两种方式都生成 `.fdata` 文件，后续步骤相同。

### 4.3 输入二进制的要求

1. 格式为 Linux ELF，架构为 x86_64 或 AArch64。macOS 仅有初步的 Mach-O 支持，Windows 不可用。
2. 保留符号表。BOLT 依靠符号表识别函数，`Cargo.toml` 的 profile 中不应设置 `strip = "symbols"` 或 `strip = true`。
3. 链接时保留重定位信息（`--emit-relocs`，简写 `-q`）。BOLT 移动函数后需要修正所有地址引用；缺少重定位信息时，BOLT 只能在函数内部调整，收益明显降低。
4. BOLT 版本为 18 及以上。本手册的命令使用 `-reorder-functions=cdsort`，LLVM 14–17 中没有该算法，替代写法见 4.5 节步骤 3。

### 4.4 验证范围

本手册的 BOLT 命令在 x86_64（Intel Core i7-9750H，支持 LBR）、BOLT 21.1.8 上验证，验证过的功能如下；AArch64 和其他选项未验证。

| 类别 | 选项 |
|:---|:---|
| 插桩 | `-instrument`、`--instrumentation-file`、`--instrumentation-file-append-pid` |
| 采样 | `perf record -e cycles:u -j any,u`、`perf2bolt`（含 LBR） |
| 优化 | `-reorder-blocks=ext-tsp`、`-reorder-functions=cdsort`、`-split-functions`、`-split-all-cold`、`-split-eh`、`-icf`、`-dyno-stats` |

### 4.5 使用方法

![BOLT 优化原理流程图](assets/BOLT优化原理流程图.png)

| 步骤 | 目的 | 输入 | 输出 |
|:---|:---|:---|:---|
| 0. 准备环境 | 安装 BOLT | — | `llvm-bolt`、`merge-fdata`、`perf2bolt` |
| 1. 带重定位构建 | 生成 BOLT 可重排的二进制 | 源码 | `<app>` |
| 2a. 插桩采集 | 以插桩方式获取 profile | `<app>` | `<app>.fdata` |
| 2b. 采样采集 | 以采样方式获取 profile，与 2a 二选一 | `<app>` | `<app>.fdata` |
| 3. 优化 | 依据 profile 重排二进制 | `<app>` + `<app>.fdata` | `<app>.bolt` |
| 4. 验证 | 确认行为不变并测量性能 | `<app>`、`<app>.bolt` | 对比结果 |

下文中，`<app>`、`<workload>`、`<triple>` 的含义与 2.3 节相同。

步骤 0：准备环境。安装 BOLT 工具（Ubuntu / Debian，以 LLVM 21 为例）。

```bash
wget https://apt.llvm.org/llvm.sh
sudo bash llvm.sh 21
sudo apt install bolt-21
export PATH=/usr/lib/llvm-21/bin:$PATH
```

| 工具 | 用途 |
|:---|:---|
| `llvm-bolt` | 插桩与优化 |
| `merge-fdata` | 合并多个 `.fdata` |
| `perf2bolt` | 将 `perf` 采样数据转换为 `.fdata`（仅采样方式需要） |

检查方法：`llvm-bolt --version` 应输出版本号。

步骤 1：带重定位构建。生成保留重定位信息和符号表的二进制。

```bash
RUSTFLAGS="-Clink-args=-Wl,-q" cargo build --release --target <triple>
```

| 参数 | 含义 |
|:---|:---|
| `-Clink-args=-Wl,-q` | rustc 将 `-Wl,-q` 传给链接器，链接器保留重定位信息 |
| `--target <triple>` | 显式指定 target 后，`RUSTFLAGS` 只作用于目标程序，不作用于 build script 和过程宏 |

产物为 `target/<triple>/release/<app>`。检查方法：

```bash
readelf -S <app> | grep rela.text     # 有输出：重定位信息已保留
readelf -S <app> | grep symtab        # 有输出：符号表存在
```

步骤 2a：插桩采集。以插桩版程序运行典型负载，获取精确的 profile。

```bash
llvm-bolt <app> -instrument -o <app>.inst \
  --instrumentation-file=/tmp/bolt/prof.fdata \
  --instrumentation-file-append-pid               # 生成插桩版程序
./<app>.inst <workload>                           # 运行典型负载，可多次运行
merge-fdata /tmp/bolt/prof.fdata.*.fdata > <app>.fdata   # 合并多次运行的 profile
```

| 参数 | 含义 |
|:---|:---|
| `-instrument` | 生成插桩版程序，不做优化 |
| `-o <app>.inst` | 插桩版程序的输出路径 |
| `--instrumentation-file=<路径>` | 插桩版程序退出时 profile 的写出位置 |
| `--instrumentation-file-append-pid` | 文件名追加进程号（`prof.fdata.<pid>.fdata`），多次运行互不覆盖 |
| `--instrumentation-sleep-time=<秒>` | 按指定间隔写出 profile，用于不会主动退出的服务端程序 |
| `--instrumentation-no-counters-clear` | 写出后不清零计数，与 `--instrumentation-sleep-time` 配合使用 |
| `--instrumentation-wait-forks` | 等待所有子进程结束后再写出 |

检查方法：每次运行生成一个非空的 `prof.fdata.<pid>.fdata`，合并后得到 `<app>.fdata`。

步骤 2b：采样采集。在原程序（步骤 1 的 `<app>`）运行时采样，开销小，适用于生产环境，与步骤 2a 二选一。CPU 支持 LBR 时（如 Intel 物理机）：

```bash
perf record -e cycles:u -j any,u -o perf.data -- ./<app> <workload>
perf2bolt -p perf.data -o <app>.fdata ./<app>
```

CPU 不支持 LBR 时（如多数 AArch64 机器、部分虚拟机）：

```bash
perf record -e cycles:u -o perf.data -- ./<app> <workload>
perf2bolt -p perf.data -o <app>.fdata -nl ./<app>
```

| 参数 | 含义 |
|:---|:---|
| `-e cycles:u` | 仅对用户态 cycles 事件采样 |
| `-j any,u` | 同时记录用户态分支（依赖 LBR），BOLT 据此获得每次跳转的源地址和目标地址 |
| `perf2bolt -p <文件>` | 输入的 `perf.data` |
| `-nl` | 输入不含分支记录，只统计各位置的执行次数，精度较低 |

检查方法：用第一组命令采样后，`perf report -i perf.data --header-only | grep "branch stack"` 有输出即表示 CPU 支持 LBR。对运行中的服务，可使用 `perf record ... -p <pid> -- sleep 60` 采样 60 秒。

步骤 3：优化。依据 profile 重排步骤 1 生成的二进制（输入为 `<app>`，而非插桩版 `<app>.inst`）。

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

| 参数 | 含义 | 对应 4.2 节的环节 |
|:---|:---|:---|
| `-data=<文件>` | 使用的 profile | 关联 profile |
| `-reorder-blocks=ext-tsp` | 以 ext-tsp 算法重排函数内的基本块 | 基本块重排 |
| `-split-functions` | 将函数拆分为热、冷两部分 | 函数拆分 |
| `-split-all-cold` | 尽可能多地移出冷基本块 | 函数拆分 |
| `-split-eh` | 将异常处理代码（Rust 中即 panic 展开）移出热区 | 函数拆分 |
| `-reorder-functions=cdsort` | 以 cache-directed sort 算法重排函数 | 函数重排 |
| `-icf` | 合并机器码完全相同的函数 | — |
| `-dyno-stats` | 输出 profile 上优化前后的分支统计 | 用于检查 |

LLVM 14–17 中没有 `cdsort`，应将 `-reorder-functions=cdsort` 替换为 `-reorder-functions=hfsort+`，其余参数不变。产物为 `<app>.bolt`。检查方法：BOLT 的输出中包含以下两类信息。

```text
BOLT-INFO: N out of M functions in the binary (X%) have non-empty execution profile
...
    ... : taken branches (-Y%)
```

`X%` 为 profile 覆盖的函数比例，接近 0 表示 profile 与二进制不匹配，或负载未执行到主要代码。`taken branches` 为 profile 上实际发生的跳转次数，其下降表示基本块重排生效。

步骤 4：验证。

1. 正确性：使用测试集或一组固定输入，比较 `<app>` 与 `<app>.bolt` 的输出，两者应完全一致。
2. 性能：使用与训练负载不同的输入测量，避免结果只反映训练数据上的表现。

```bash
hyperfine --warmup 3 './<app> <bench>' './<app>.bolt <bench>'      # 墙钟时间
perf stat -e cycles:u,instructions:u,L1-icache-load-misses:u,iTLB-load-misses:u -- ./<app>.bolt <bench>
```

BOLT 的效果主要体现为 i-cache 和 iTLB 未命中减少。

### 4.6 注意事项

1. profile 与二进制一一对应。修改代码或编译选项后，需重新执行步骤 1–3。
2. 训练负载应具有代表性。BOLT 只将负载中执行过的代码视为热代码。
3. BOLT 默认丢弃调试信息。需要保留时，在步骤 3 中加 `-update-debug-sections`。
4. 插桩版运行较慢，插桩负载不宜过大；生产环境优先使用采样方式。

## 5 PGO 与 BOLT 叠加

已采用 PGO 的程序可在 PGO 的基础上再执行 BOLT，顺序为先 PGO、后 BOLT：PGO 决定生成的机器码，BOLT 对最终的机器码进行布局优化。操作上，将 4.5 节步骤 1 的构建替换为带 PGO profile 的构建：

1. 按 2.3 节的步骤 1–3 获得 `merged.profdata`。
2. 使用 PGO profile 构建，同时保留重定位信息：

   ```bash
   RUSTFLAGS="-Cprofile-use=/path/to/merged.profdata -Clink-args=-Wl,-q" \
   cargo build --release --target <triple>
   ```

3. 对该二进制执行 4.5 节的步骤 2–4。

BOLT profile 须在 PGO 版本上重新采集。PGO 版与普通版的机器码不同，普通版上采集的 `.fdata` 不能复用。

## 6 使用 cargo-pgo

[cargo-pgo](https://crates.io/crates/cargo-pgo) 将 PGO 和 BOLT 的构建、采集后的合并和优化构建封装为几条命令，自动处理 `--target`、profile 目录、`llvm-profdata` 路径和 BOLT 所需的重定位参数，并通过 `PATH` 查找 `llvm-bolt` 和 `merge-fdata`。得到优化版后，仍按 2.3 节步骤 5 或 4.5 节步骤 4 验证。

```bash
cargo install cargo-pgo
cargo pgo info                                                  # 检查 rustc 版本和所需工具

# PGO
cargo pgo build                                                 # 2.3 节步骤 1
./target/<triple>/release/<app> <workload>                      # 步骤 2
cargo pgo optimize                                              # 步骤 3、4

# 仅 BOLT
cargo pgo bolt build                                            # 4.5 节步骤 1，并生成插桩版
./target/<triple>/release/<app>-bolt-instrumented <workload>    # 采集
cargo pgo bolt optimize                                         # 合并 profile 并执行步骤 3

# PGO + BOLT
cargo pgo build
./target/<triple>/release/<app> <workload>
cargo pgo bolt build --with-pgo
./target/<triple>/release/<app>-bolt-instrumented <workload>
cargo pgo bolt optimize --with-pgo
```

BOLT 优化后的产物为 `target/<triple>/release/<app>-bolt-optimized`。`cargo pgo test`、`cargo pgo bench` 以插桩方式运行测试或基准测试并采集 profile，适用于以测试或基准测试作为负载的情况。

## 7 实践案例：ripgrep

### 7.1 案例说明

本章以 ripgrep 14.1.1（一个用 Rust 编写的命令行文本搜索工具）为实验对象，按第 2、4、5、6 章的步骤完成 PGO、BOLT、PGO + BOLT 和 cargo-pgo 的完整流程，并给出每一步的命令、实际输出和评测数据。ripgrep 的源码位于 `examples/subjects/ripgrep/`，未做修改，来源和许可证见 [examples/subjects/README.md](examples/subjects/README.md)。ripgrep 仅作为示例程序，相同的流程适用于其他 Rust 程序。

每个案例对应 `examples/` 下的一个脚本，脚本按本章的步骤执行，运行时打印各步骤的标题和产出：

| 案例 | 脚本 | 结果 | 测试环境下的耗时 |
|:---|:---|:---|---:|
| PGO（7.3 节） | `examples/pgo/run.sh` | `examples/pgo/results.md` | 354 秒（含语料下载） |
| BOLT 及 PGO + BOLT（7.4 节） | `examples/bolt/run.sh` | `examples/bolt/results.md` | 567 秒 |
| cargo-pgo（7.5 节） | `examples/cargo-pgo/run.sh` | — | 349 秒 |

BOLT 和 cargo-pgo 案例使用 PGO 案例的产物，需按以下顺序运行：

```bash
bash examples/pgo/run.sh
bash examples/bolt/run.sh
bash examples/cargo-pgo/run.sh
```

语料为 Linux 6.6 内核源码，共 81,703 个文件，解压后 1.5 GB。`examples/common/workload.sh corpus` 在语料不存在时下载 `linux-6.6.tar.xz`（约 140 MB），校验 sha256 后解压到 `examples/work/linux-6.6/`。下载源默认为 `https://cdn.kernel.org/pub/linux/kernel`，可通过环境变量 `KERNEL_MIRROR` 修改，例如 `https://mirrors.tuna.tsinghua.edu.cn/kernel`。

运行环境：

- Linux；rustup 工具链及 `llvm-tools-preview` 组件；`perf`（需能读取硬件计数器）、`hyperfine`、`curl`。
- BOLT 案例另需 18 及以上版本的 BOLT 工具（`llvm-bolt`、`merge-fdata`、`perf2bolt`），位于 `PATH` 中；采样采集需要 CPU 支持 LBR，不支持时 `bolt/run.sh` 跳过该步骤。
- cargo-pgo 案例另需 `cargo install cargo-pgo`。
- 磁盘空间约 4 GB：语料 1.6 GB，其余为构建缓存和产物。

运行产物默认写入 `examples/work/`，可通过环境变量 `WORK_DIR` 修改。在 WSL 中，仓库或 `WORK_DIR` 应位于 Linux 文件系统内，否则文件共享的 I/O 开销会影响测量结果。

本章的实测数据来自以下环境：Intel Core i7-9750H（支持 LBR），WSL2 Ubuntu 24.04，rustc 1.93.1（LLVM 21.1.8），BOLT 21.1.8。

### 7.2 负载与评测方法

训练负载用于采集 profile，由 `examples/common/workload.sh train <rg>` 执行，共 9 条搜索，覆盖 ripgrep 的常见用法：

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

PGO 和 BOLT 的插桩采集、采样采集使用同一套训练负载。

评测由 `examples/common/bench.sh` 执行，共 7 个用例，取自 ripgrep 作者基准集中的 linux_* 系列。评测用例与训练负载不重复，用于检验优化效果能否推广到训练中未出现的输入。

| 用例 | 命令 | 匹配方式 |
|:---|:---|:---|
| literal | `rg PM_RESUME` | 区分大小写的单个字面量 |
| literal_casei | `rg -i PM_RESUME` | 忽略大小写的单个字面量 |
| word | `rg -w PM_RESUME` | 字面量，且两侧须为单词边界 |
| unicode_word | `rg '\wAh'` | Unicode 单词字符类 `\w` 后接字面量 `Ah` |
| re_literal_suffix | `rg '[A-Z]+_RESUME'` | 字符类重复，后接字面量后缀 `_RESUME` |
| alternates | `rg 'ERR_SYS\|PME_TURN_OFF\|LINK_REQ_RST\|CFG_BME_EVT'` | 4 个字面量的多选一 |
| no_literal | `rg '\w{5}\s+\w{5}\s+\w{5}\s+\w{5}\s+\w{5}'` | 只由字符类和重复组成，不含字面量 |

`bench.sh <结果文件> <基线版> <对比版>...` 对每个用例依次执行：

1. 正确性校验：各版本的输出排序后计算 sha256，不一致则报错退出。ripgrep 并行搜索时输出顺序不固定，因此先排序再比较。
2. 墙钟时间：`hyperfine --warmup 3 --runs 50`，记录均值和标准差。
3. 硬件计数器：`perf stat -r 5`，只统计用户态（`:u`）事件。

结果写入 Markdown 表格，第一行为基线版，其余各行附相对基线的变化。

| 指标 | 含义 |
|:---|:---|
| 耗时 | 一次搜索的墙钟时间，包含内核态的文件读取和目录遍历 |
| cycles | 用户态 CPU 时钟周期数 |
| instructions | 用户态执行的指令数，PGO 的内联和分支布局优化主要体现在此项 |
| L1 i-cache miss | 取指时一级指令缓存的未命中次数，代码布局优化主要体现在此项 |
| iTLB miss | 取指时 iTLB 的未命中次数 |

评测以用户态硬件计数器为主要指标。墙钟时间包含内核态的 I/O 开销：在该负载下，ripgrep 约 58% 的 CPU 时间为内核态（见 7.6 节），而 PGO 和 BOLT 只作用于用户态代码；此外 WSL2 下墙钟时间的波动较大。

### 7.3 PGO 优化方法

本案例按 2.3 节的步骤对 ripgrep 应用 PGO：用 9 条训练搜索采集 profile，重新编译得到 PGO 版，再用 7 条评测搜索对比 PGO 版与普通版。

| 步骤 | 操作 | 产出 |
|:---|:---|:---|
| 0 | 检查 `llvm-profdata`，下载语料 | `work/linux-6.6/` |
| 1 | 普通构建；插桩构建（`-Cprofile-generate`） | `rg-base`；`rg-instr` |
| 2 | 以 `rg-instr` 执行 9 条训练搜索 | `work/pgo-data/*.profraw` |
| 3 | 合并 profile（`llvm-profdata merge`） | `work/pgo-data/merged.profdata` |
| 4 | 依据 profile 重新编译（`-Cprofile-use`） | `rg-pgo` |
| 5 | 以 7 条评测搜索对比 `rg-base` 与 `rg-pgo` | `examples/pgo/results.md` |

以下命令和输出摘自 `examples/pgo/run.sh` 及其在测试环境中的实际运行结果，脚本每一步开始时打印 `==> 步骤 N：…`。路径 `work/` 指 `examples/work/`；`$BIN`、`$PGO_DIR` 分别为 `work/bin`、`work/pgo-data`，`$TARGET` 为 `rustc -vV` 输出中的 `host`。

步骤 0：检查环境。`run.sh` 检查 `llvm-profdata` 是否存在并输出其版本，然后下载并校验语料；语料已存在时跳过。

```text
LLVM version 21.1.8-rust-1.93.1-stable
.../examples/work/linux-6.6.tar.xz: OK
```

`llvm-profdata` 的 LLVM 版本与 rustc 一致（21.1.8）。

步骤 1：普通构建与插桩构建。

```bash
cargo build --release --target $TARGET --target-dir work/target/base                               # → rg-base
RUSTFLAGS="-Cprofile-generate=$PGO_DIR" cargo build --release --target $TARGET --target-dir work/target/instr   # → rg-instr
```

```text
-rwxr-xr-x 1 root root 27M ... work/bin/rg-base
-rwxr-xr-x 1 root root 31M ... work/bin/rg-instr
```

插桩版为 31.8 MB，比普通版（27.4 MB）大约 16%，增加部分为计数器和写出 profile 的运行时代码。

步骤 2：采集 profile。

```bash
rm -rf $PGO_DIR
examples/common/workload.sh train $BIN/rg-instr
```

```text
  rg mutex_lock
  rg -i spin_unlock_irqrestore
  ...
  rg --files
-rw-r--r-- 1 root root 1.9M ... default_1517753687113566901_0.profraw
```

9 条训练搜索只生成 1 个 `.profraw`：默认文件名不含进程号，各次运行的计数累加在同一文件中。

步骤 3：合并 profile。

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

步骤 4：优化构建。

```bash
RUSTFLAGS="-Cprofile-use=$PGO_DIR/merged.profdata -Cllvm-args=-pgo-warn-missing-function" \
  cargo build --release --target $TARGET --target-dir work/target/pgo                              # → rg-pgo
```

```text
缺少 profile 的函数告警：0 条
-rwxr-xr-x 1 root root 24M ... work/bin/rg-pgo
```

`run.sh` 统计构建日志中 `no profile data available` 告警的条数。0 条表示 profile 与源码匹配；使用无关程序的 profile 编译 ripgrep 时，此类告警为 8341 条。`rg-pgo` 为 24.9 MB，比普通版小约 9%，原因是 LLVM 对冷代码减少内联并按体积优化。

步骤 5：验证。

```bash
examples/common/bench.sh examples/pgo/results.md $BIN/rg-base $BIN/rg-pgo
```

评测方法见 7.2 节。本次运行 7 个用例的输出全部一致，结果写入 [`examples/pgo/results.md`](examples/pgo/results.md)，分析见 7.6 节。

### 7.4 BOLT 优化方法

本案例按 4.5 节和第 5 章的步骤对 ripgrep 应用 BOLT：分别以插桩和采样方式采集 profile，生成 BOLT 版；再在 PGO 版的基础上执行 BOLT，生成 PGO + BOLT 版；最后用 7 条评测搜索对比各版本与普通版。

| 步骤 | 操作 | 产出 |
|:---|:---|:---|
| 0 | 检查 BOLT 工具及版本，下载语料 | `work/linux-6.6/` |
| 1 | 普通构建；带重定位构建（`-Wl,-q`） | `rg-base`；`rg-reloc` |
| 2a | 插桩：`llvm-bolt -instrument` 生成插桩版，执行 9 条训练搜索，`merge-fdata` 合并 | `work/bolt-data/instr/merged.fdata` |
| 2b | 采样：以 `rg-reloc` 执行训练搜索，`perf record` 采样，`perf2bolt` 转换；CPU 不支持 LBR 时跳过 | `work/bolt-data/perf/rg.fdata` |
| 3 | 以两份 profile 分别优化 `rg-reloc` | `rg-bolt`；`rg-bolt-perf` |
| 叠加 | 用 PGO profile 构建带重定位的版本，重复插桩采集和优化 | `rg-pgo-bolt` |
| 4 | 以 7 条评测搜索对比各版本与 `rg-base` | `examples/bolt/results.md` |

与 PGO 叠加使用 PGO 案例生成的 profile，步骤 4 的对比包含 PGO 案例生成的 `rg-pgo`；未运行 PGO 案例时，脚本跳过与 PGO 叠加，其余步骤正常执行。

以下命令和输出摘自 `examples/bolt/run.sh` 及其在测试环境中的实际运行结果，脚本每一步开始时打印 `==> 步骤 N：…`（与 PGO 叠加一步打印 `==> 与 PGO 叠加`）。`$BIN`、`$DATA` 分别为 `work/bin`、`work/bolt-data`；`<优化参数>` 为 `-reorder-blocks=ext-tsp -reorder-functions=cdsort -split-functions -split-all-cold -split-eh -icf -dyno-stats`，含义见 4.5 节步骤 3。

步骤 0：检查环境。`run.sh` 检查 `llvm-bolt` 是否在 `PATH` 中，以及版本是否为 18 及以上，然后下载语料（已存在时跳过）。apt.llvm.org 的 `bolt-21` 安装在 `/usr/lib/llvm-21/bin`，需先将该目录加入 `PATH`。

```text
BOLT 版本：21
```

步骤 1：普通构建与带重定位构建。

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

步骤 2a：插桩采集。

```bash
llvm-bolt $BIN/rg-reloc -instrument -o $DATA/instr/rg.inst \
  --instrumentation-file=$DATA/instr/prof.fdata --instrumentation-file-append-pid
examples/common/workload.sh train $DATA/instr/rg.inst
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

步骤 2b：采样采集。

```bash
perf record -e cycles:u -j any,u -o $DATA/perf/perf.data -- examples/common/workload.sh train $BIN/rg-reloc
perf2bolt -p $DATA/perf/perf.data -o $DATA/perf/rg.fdata $BIN/rg-reloc
```

```text
[ perf record: Captured and wrote 67.328 MB .../perf.data (86719 samples) ]
PERF2BOLT: read 86685 samples and 2759779 LBR entries
BOLT-INFO: 580 out of 7147 functions in the binary (8.1%) have non-empty execution profile
```

采样对 `rg-reloc` 本身进行，不需要插桩版。`perf record` 跟踪 `workload.sh` 启动的所有子进程，`perf2bolt` 只提取属于 `rg-reloc` 的样本。采样得到的 profile 覆盖 8.1% 的函数，约为插桩方式的一半，因为采样只能捕获执行足够频繁的代码。

步骤 3：优化。

```bash
llvm-bolt $BIN/rg-reloc -o $BIN/rg-bolt      -data=$DATA/instr/merged.fdata <优化参数>
llvm-bolt $BIN/rg-reloc -o $BIN/rg-bolt-perf -data=$DATA/perf/rg.fdata      <优化参数>
```

`run.sh` 只显示 BOLT 输出中的 profile 覆盖率、基本块重排和跳转统计：

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

与 PGO 叠加。

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

步骤 4：验证。

```bash
examples/common/bench.sh examples/bolt/results.md $BIN/rg-base $BIN/rg-pgo $BIN/rg-bolt $BIN/rg-bolt-perf $BIN/rg-pgo-bolt
```

评测方法见 7.2 节。本次运行 7 个用例中五个版本的输出全部一致，结果写入 [`examples/bolt/results.md`](examples/bolt/results.md)，分析见 7.6 节。

### 7.5 cargo-pgo 优化方法

本案例按第 6 章的用法，用 cargo-pgo 0.3.0 对 ripgrep 完成 PGO 以及 PGO + BOLT，流程与 7.3 节、7.4 节中的“与 PGO 叠加”相同。

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

脚本以 PGO 案例生成的 `rg-base` 作为输出对照；步骤 4–6 需要 BOLT 工具位于 `PATH` 中。

以下命令和输出摘自 `examples/cargo-pgo/run.sh` 及其在测试环境中的实际运行结果。命令在 `examples/subjects/ripgrep/` 下执行；`CARGO_TARGET_DIR` 设为 `work/target/cargo-pgo`，`$OUT` 为其下的 `x86_64-unknown-linux-gnu/release`；输出中的长路径以 `...` 代替，时间戳已删除。

步骤 0：检查环境。`cargo pgo info` 检查 rustc 版本和所需工具：

```text
[rustc version]: 1.93.1 is recent enough
[llvm-profdata]: found at .../lib/rustlib/x86_64-unknown-linux-gnu/bin/llvm-profdata
[llvm-bolt]: found at /usr/lib/llvm-21/bin/llvm-bolt
[merge-fdata]: found at /usr/lib/llvm-21/bin/merge-fdata
```

步骤 1–3：PGO。

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

步骤 4–6：PGO + BOLT。

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

步骤 7：验证。比较各版本在 `rg -w PM_RESUME` 上排序后输出的 sha256（前 16 位）：

```text
rg-base              69ac725be6017a0d
rg-cargo-pgo         69ac725be6017a0d
rg-cargo-pgo-bolt    69ac725be6017a0d
```

三者一致。本案例只验证 cargo-pgo 的流程和产物的正确性，未对产物进行性能评测。

### 7.6 优化效果

本节的结果来自 7.3 节、7.4 节两次独立运行，两次运行中 `rg-base`、`rg-pgo` 的数据略有差异。

PGO 案例中，`rg-pgo` 相对 `rg-base` 的用户态硬件计数器变化：

| 用例 | cycles | 指令数 | L1 i-cache miss | iTLB miss |
|:---|---:|---:|---:|---:|
| literal | −11.9% | −7.4% | −33.0% | −38.5% |
| literal_casei | −10.3% | −4.2% | −32.8% | −26.6% |
| word | −11.2% | −7.4% | −31.8% | −42.1% |
| unicode_word | −10.4% | −4.9% | −29.8% | −30.1% |
| re_literal_suffix | −9.8% | −7.3% | −30.6% | −36.1% |
| alternates | −12.5% | −4.2% | −34.1% | −35.8% |
| no_literal | −1.5% | +11.1% | −30.9% | −42.3% |

PGO 案例的墙钟时间：

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

no_literal 的 cycles 只减少 1.5%，指令数增加 11.1%。该用例的耗时集中在正则引擎的一个小循环内；指令数增加的原因本手册未分析。

墙钟时间的变化与标准差处于同一量级，不能据此判断端到端性能。以 literal 为例，`rg-base` 的 CPU 时间为 User 974 ms、System 1343 ms，约 58% 为内核态（读文件、遍历目录），PGO 只作用于用户态代码。

BOLT 案例中，各版本的用户态 cycles 相对 `rg-base` 的变化：

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

BOLT 案例的墙钟时间：

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

采样方式的 i-cache 未命中降幅与插桩方式接近，profile 采集不需要插桩版。no_literal 中采样版的指令数增加 2.9%，原因本手册未分析。

PGO + BOLT 在 6 个用例中 cycles 降幅最大，i-cache 未命中减少 44.4%–48.8%。no_literal 的耗时集中在正则引擎的一个小循环内，各版本的 cycles 变化均不超过 2%；PGO 版和 PGO + BOLT 版在该用例中的指令数增加 11.1%，原因本手册未分析。

墙钟时间的变化方向不一致，与 cycles 的变化也不对应（BOLT 插桩版在 word 中的标准差为 39.7 ms），不能据此判断端到端性能。原因与 PGO 案例相同：CPU 时间大部分为内核态，BOLT 只作用于用户态代码。

## 参考

- [The rustc book：Profile-guided Optimization](https://doc.rust-lang.org/rustc/profile-guided-optimization.html)
- [Clang：Profile Guided Optimization](https://clang.llvm.org/docs/UsersManual.html#profile-guided-optimization)
- [BOLT README](https://github.com/llvm/llvm-project/blob/main/bolt/README.md)
- Jakub Beránek，[Optimizing Rust programs with PGO and BOLT using cargo-pgo](https://kobzol.github.io/rust/cargo/2023/07/28/rust-cargo-pgo.html)
