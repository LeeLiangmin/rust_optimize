# Rust PGO 与 BOLT 优化

两种不改源码、只改构建流程的性能优化技术，以 [ripgrep](https://github.com/BurntSushi/ripgrep) 14.1.1 为例，给出原理、操作步骤和实测数据。

| 技术 | 通用文档（介绍、原理、操作步骤） | ripgrep 实践（复现脚本、实测数据） |
|:---|:---|:---|
| PGO | [pgo/README.md](pgo/README.md) | [pgo/PRACTICE.md](pgo/PRACTICE.md) |
| BOLT | [bolt/README.md](bolt/README.md) | [bolt/PRACTICE.md](bolt/PRACTICE.md) |

建议先读 PGO，BOLT 文档会用到 PGO 的部分概念，并介绍两者如何叠加。

## 两者的区别

| | PGO | BOLT |
|:---|:---|:---|
| 作用阶段 | 编译期 | 链接之后 |
| 改变什么 | 内联、分支布局、冷热分离等编译决策 | 基本块和函数在二进制中的位置 |
| 主要收益 | 指令数减少 | i-cache / iTLB 未命中减少 |
| 平台 | rustc 支持的主流平台 | 主要面向 Linux ELF；macOS 初步支持 Mach-O；Windows 不可用 |

## 实测结果

**实验做了什么**：以命令行搜索工具 ripgrep 为对象，分别构建普通版、PGO 版、BOLT 版和 PGO + BOLT 版。各版本先在 Linux 6.6 内核源码上执行 9 条典型搜索，采集 profile；再用另外 7 条搜索评测，确认输出完全一致后比较性能。详细设计见各实践文档的"实验概述"。

**看哪些指标**：除墙钟时间外，主要看 `perf` 读取的用户态硬件计数器，即 ripgrep 自身代码的开销：cycles（耗费的时钟周期）、指令数、L1 i-cache miss（取指令时缓存未命中的次数）。

**结果**：x86_64（i7-9750H）、WSL2 Ubuntu 24.04、rustc 1.93.1、BOLT 21.1.8。各指标相对普通版的变化如下，范围取自 7 个评测用例（数据来自 BOLT 实践中各版本同一轮的评测）：

| 指标 | PGO | BOLT | PGO + BOLT |
|:---|---:|---:|---:|
| cycles | −1.8% ~ −11.5% | +0.5% ~ −12.4% | −2.3% ~ −14.8% |
| 指令数 | −0.6% ~ −7.4% | −0.1% ~ −3.4% | −0.6% ~ −7.4% |
| L1 i-cache miss | −30.3% ~ −34.5% | −41.6% ~ −49.1% | −44.2% ~ −50.6% |

墙钟时间无法得出可靠结论：ripgrep 在这一负载中约 60% 的 CPU 时间花在内核态，用户态的提升被稀释。详见 [BOLT 实践](bolt/PRACTICE.md#6-结果)。

## 复现

每个实践都可以用一条命令完成环境检查、下载语料、构建、优化和评测：

```bash
bash pgo/practice/run.sh     # PGO，结果写入 pgo/practice/results.md
bash bolt/practice/run.sh    # BOLT 及 PGO + BOLT，结果写入 bolt/practice/results.md
```

产物、profile 和语料默认放在仓库根目录的 `work/` 下，不会被提交：语料两个实践共用一份，构建缓存和产物分别在 `work/pgo/`、`work/bolt/`。仓库位于 WSL 的 Windows 盘（`/mnt/*`）时，为避免文件共享的 I/O 开销掩盖优化效果，会自动改放到 `~/rust_optimize_work`。也可以用环境变量 `WORK_DIR` 指定。两个实践都运行时约需 4 GB 磁盘。环境要求和分步说明见各实践文档。

## 目录

```
├── ripgrep/              ripgrep 14.1.1 源码（未修改）
├── common/               两个实践共用的脚本
│   ├── env.sh            公共变量与构建函数
│   ├── corpus.sh         下载语料
│   ├── train.sh          训练负载
│   └── bench.sh          评测：输出一致性校验 + 计时 + 硬件计数器
├── work/                 运行时生成，不提交：linux-6.6/（语料，共用）、pgo/、bolt/（各自的构建缓存与产物）
├── pgo/
│   ├── README.md         PGO 通用文档：介绍、基本原理、操作步骤
│   ├── PRACTICE.md       PGO 实践文档：以 ripgrep 为例的实验设计、步骤说明、结果与分析
│   ├── assets/           流程图
│   └── practice/         实践脚本（run.sh、00–05）与实测结果 results.md
└── bolt/                 结构同 pgo/
    ├── README.md         BOLT 通用文档
    ├── PRACTICE.md       BOLT 实践文档（含 PGO + BOLT）
    ├── assets/
    └── practice/
```

## 参考

- Jakub Beránek，[Optimizing Rust programs with PGO and BOLT using cargo-pgo](https://kobzol.github.io/rust/cargo/2023/07/28/rust-cargo-pgo.html)
- [The rustc book：Profile-guided Optimization](https://doc.rust-lang.org/rustc/profile-guided-optimization.html)
- [BOLT README](https://github.com/llvm/llvm-project/blob/main/bolt/README.md)
