# Rust 程序的 PGO 与 BOLT 优化

PGO（Profile-Guided Optimization）和 BOLT（Binary Optimization and Layout Tool）是两种依据程序运行时 profile 进行优化的技术，无需修改源码，只需调整构建流程。本仓库说明二者的原理、在 Rust 中的支持情况和操作步骤，并以 ripgrep 为例，演示如何在一个实际的 Rust 程序上完整应用这两项优化。

## 1. PGO

PGO 是一种编译期优化。先以插桩版程序运行典型负载，记录各分支、各函数的执行次数；编译器再依据这些数据重新编译，调整内联、基本块布局、冷热代码分离等决策。其收益主要体现为执行的指令数减少。

在 Rust 中：

- rustc 内置支持，`-Cprofile-generate`、`-Cprofile-use` 自 Rust 1.37 起稳定；
- 合并 profile 所需的 `llvm-profdata` 随 rustup 组件 `llvm-tools-preview` 分发；
- 可用于 Linux、macOS、Windows 等 rustc 支持的主流平台；
- 预编译的标准库不参与优化；采样式 PGO 目前仅在 nightly 中可用。

文档：[PGO.md](PGO.md)，包括介绍、基本原理、操作步骤（准备环境 → 插桩构建 → 采集 → 合并 → 优化构建 → 验证），以及 cargo-pgo 的用法。

示例：[experiments/pgo/](experiments/pgo/)，以 ripgrep 为例演示 PGO 的完整应用过程，说明见 [experiments/pgo/PRACTICE.md](experiments/pgo/PRACTICE.md)。

## 2. BOLT

BOLT 是 LLVM 项目中的链接后优化器。它读取已链接的二进制，依据运行时 profile 重排基本块和函数，使热代码集中，从而减少指令缓存（i-cache）和 iTLB 未命中。它基本不改变执行的指令，只改变指令的位置。

在 Rust 中：

- BOLT 不属于 Rust 工具链，需另行安装 BOLT 工具 `llvm-bolt`、`merge-fdata`（采样方式另需 `perf2bolt`），例如 apt.llvm.org 的 `bolt-N` 包；本仓库的命令要求 18 及以上版本；
- rustc 只需通过 `-Clink-args=-Wl,-q` 保留重定位信息，并保留符号表；
- 主要面向 Linux ELF（x86_64、AArch64），macOS 仅有初步支持，Windows 不可用；
- profile 可通过插桩或 `perf` 采样获得。

文档：[BOLT.md](BOLT.md)，包括介绍、基本原理、操作步骤（准备环境 → 带重定位构建 → 插桩或采样采集 → 优化 → 验证）、与 PGO 叠加的方法，以及 cargo-pgo 的用法。

示例：[experiments/bolt/](experiments/bolt/)，以 ripgrep 为例演示 BOLT 的完整应用过程（插桩与采样两种方式），以及与 PGO 的叠加，说明见 [experiments/bolt/PRACTICE.md](experiments/bolt/PRACTICE.md)。

## 3. PGO 与 BOLT 的关系

| | PGO | BOLT |
|:---|:---|:---|
| 作用阶段 | 编译期 | 链接之后 |
| 改变内容 | 内联、分支布局等编译决策 | 基本块和函数在二进制中的位置 |
| 主要收益 | 指令数减少 | i-cache / iTLB 未命中减少 |
| Rust 支持 | rustc 内置 | 外部工具 |

两者作用于不同层面，可以叠加，顺序为先 PGO、后 BOLT。Rust 官方发布的 rustc 本身即同时使用了这两项技术。建议先阅读 PGO.md，BOLT.md 引用了其中的部分概念。

## 4. 应用示例

`experiments/` 以 ripgrep 为例，演示如何在一个实际的 Rust 程序上完整应用 PGO 和 BOLT：环境准备、构建、采集 profile、优化，以及验证优化效果。ripgrep 只是示例对象，所用的流程和脚本结构同样适用于其他 Rust 程序。

### 4.1 示例内容

示例程序为 [ripgrep](https://github.com/BurntSushi/ripgrep) 14.1.1，一个用 Rust 编写的命令行文本搜索工具，源码未做修改。语料为 Linux 6.6 内核源码（81,703 个文件，1.5 GB）。profile 由 9 条典型搜索（训练负载）采集，性能由另外 7 条取自 ripgrep 作者基准集的搜索（评测负载）测量。评测前先确认各版本输出一致，再测量墙钟时间和用户态硬件计数器（cycles、指令数、L1 i-cache 和 iTLB 未命中）。

| 示例 | 目录 | 构建的版本 | 演示内容 | 文档 | 运行 |
|:---|:---|:---|:---|:---|:---|
| PGO | `experiments/pgo/` | 普通版、PGO 版 | PGO 的完整流程及效果验证 | [PRACTICE.md](experiments/pgo/PRACTICE.md) | `bash experiments/pgo/practice/run.sh` |
| BOLT | `experiments/bolt/` | 普通版、PGO 版、BOLT 版（插桩 / 采样）、PGO + BOLT 版 | BOLT 的完整流程（插桩、采样两种方式）、与 PGO 叠加，及效果验证 | [PRACTICE.md](experiments/bolt/PRACTICE.md) | `bash experiments/bolt/practice/run.sh` |

每个示例目录中，`PRACTICE.md` 逐步说明每一步的命令、实际输出及其含义，并给出测量结果与分析；`practice/` 下是运行脚本（`run.sh`、分步脚本 00–05）和实测结果 `results.md`。两个示例共用的脚本在 `experiments/common/`，示例程序的源码在 `experiments/subjects/ripgrep/`。

### 4.2 运行

环境要求：Linux、rustup 工具链（含 `llvm-tools-preview`）、`perf`、`hyperfine`；BOLT 示例另需 18 及以上版本的 BOLT 工具（`llvm-bolt`、`merge-fdata`、`perf2bolt`）。每个示例的第一步会检查依赖，缺失时给出安装方法。

```bash
bash experiments/pgo/practice/run.sh     # 约 7.5 分钟
bash experiments/bolt/practice/run.sh    # 约 14 分钟
```

脚本依次完成环境检查、语料下载、构建、profile 采集、优化和评测，结果写入各示例目录下的 `practice/results.md`。语料、构建产物和 profile 默认存放在 `experiments/work/`（不纳入版本控制），两个示例共约需 4 GB 磁盘空间；仓库位于 WSL 的 Windows 盘时自动改用 `~/rust_optimize_work`，也可通过环境变量 `WORK_DIR` 指定。

### 4.3 示例中的测量结果

以下数据仅反映 ripgrep 在该负载下的表现，用于验证优化是否按原理生效；其他程序的收益需在各自的负载上测量。测试环境：x86_64（Intel i7-9750H）、WSL2 Ubuntu 24.04、rustc 1.93.1、BOLT 21.1.8。下表为各版本相对普通版的变化，范围取自 7 个评测用例（数据来自 BOLT 示例中同一轮的评测）：

| 用户态指标 | PGO | BOLT（插桩） | PGO + BOLT |
|:---|---:|---:|---:|
| cycles | −1.8% ~ −11.5% | +0.5% ~ −12.4% | −2.3% ~ −14.8% |
| 指令数 | −0.6% ~ −7.4% | −0.1% ~ −3.4% | −0.6% ~ −7.4% |
| L1 i-cache miss | −30.3% ~ −34.5% | −41.6% ~ −49.1% | −44.2% ~ −50.6% |

结果与原理一致：PGO 主要减少指令数，BOLT 在指令数基本不变的情况下明显减少 i-cache 未命中，两者叠加效果最好。墙钟时间没有可测的差异：在该负载下，ripgrep 约 60% 的 CPU 时间花在内核态（读文件、遍历目录），用户态的优化收益被稀释。

## 5. 目录结构

```
├── README.md              总览
├── PGO.md                 PGO 文档
├── BOLT.md                BOLT 文档
├── assets/                文档中的流程图
└── experiments/           应用示例
    ├── pgo/               PGO 示例：PRACTICE.md、practice/（脚本与结果）
    ├── bolt/              BOLT 示例：PRACTICE.md、practice/（脚本与结果）
    ├── common/            两个示例共用的脚本
    ├── subjects/ripgrep/  示例程序
    └── work/              运行时生成，不提交
```

## 参考

- [The rustc book：Profile-guided Optimization](https://doc.rust-lang.org/rustc/profile-guided-optimization.html)
- [BOLT README](https://github.com/llvm/llvm-project/blob/main/bolt/README.md)
- [Rust 发行说明（RELEASES.md）](https://github.com/rust-lang/rust/blob/master/RELEASES.md)
- [LLVM 14.0.0 Release Notes](https://releases.llvm.org/14.0.0/docs/ReleaseNotes.html)
- Jakub Beránek，[Optimizing Rust programs with PGO and BOLT using cargo-pgo](https://kobzol.github.io/rust/cargo/2023/07/28/rust-cargo-pgo.html)
