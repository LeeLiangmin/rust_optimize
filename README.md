# Rust PGO 与 BOLT 优化

两种不改源码、只改构建流程的性能优化技术，以 [ripgrep](https://github.com/BurntSushi/ripgrep) 14.1.1 为例，给出原理、操作步骤和实测数据。

| 技术 | 通用文档（介绍、原理、操作步骤） | ripgrep 实践（复现脚本、实测数据） |
|:---|:---|:---|
| PGO | [pgo/README.md](pgo/README.md) | [pgo/practice](pgo/practice/README.md) |
| BOLT | [bolt/README.md](bolt/README.md) | [bolt/practice](bolt/practice/README.md) |

建议先读 PGO，BOLT 文档会用到 PGO 的部分概念，并介绍两者如何叠加。

## 两者的区别

| | PGO | BOLT |
|:---|:---|:---|
| 作用阶段 | 编译期 | 链接之后 |
| 改变什么 | 内联、分支布局、冷热分离等编译决策 | 基本块和函数在二进制中的位置 |
| 主要收益 | 指令数减少 | i-cache / iTLB 未命中减少 |
| 平台 | rustc 支持的主流平台 | 主要面向 Linux ELF；macOS 初步支持 Mach-O；Windows 不可用 |
| 组合 | 先做 | 后做，叠加在 PGO 结果之上 |

## 实测结果

x86_64（i7-9750H）、WSL2 Ubuntu 24.04、rustc 1.93.1、BOLT 21.1.8。在 Linux 6.6 源码上执行 7 个与训练负载不同的搜索，用户态硬件计数器相对基线的变化如下（取自 BOLT 实践中各版本同一轮的评测）：

| 指标 | PGO | BOLT | PGO + BOLT |
|:---|---:|---:|---:|
| cycles | −1.8% ~ −11.5% | +0.5% ~ −12.4% | −2.3% ~ −14.8% |
| 指令数 | −0.6% ~ −7.4% | −0.1% ~ −3.4% | −0.6% ~ −7.4% |
| L1 i-cache miss | −30.3% ~ −34.5% | −41.6% ~ −49.1% | −44.2% ~ −50.6% |

墙钟时间无法得出可靠结论：ripgrep 在这一负载中约 60% 的 CPU 时间花在内核态，用户态的提升被稀释。详见 [BOLT 实践](bolt/practice/README.md#5-结果)。

## 复现

每个实践都可以用一条命令完成环境检查、下载语料、构建、优化和评测：

```bash
bash pgo/practice/run.sh     # PGO，结果写入 pgo/practice/results.md
bash bolt/practice/run.sh    # BOLT 及 PGO + BOLT，结果写入 bolt/practice/results.md
```

产物、profile 和语料默认放在 `~/rust_optimize_work`，可用环境变量 `WORK_DIR` 修改。WSL 下请放在 Linux 文件系统内，不要放在 `/mnt/c` 等 Windows 盘上。环境要求和分步说明见各实践文档。

## 目录

```
├── ripgrep/            ripgrep 14.1.1 源码（未修改）
├── common/             两个实践共用的脚本
│   ├── env.sh          公共变量与构建函数
│   ├── corpus.sh       下载语料
│   ├── train.sh        训练负载
│   └── bench.sh        评测：输出一致性校验 + 计时 + 硬件计数器
├── pgo/
│   ├── README.md       PGO 通用文档
│   └── practice/       PGO 实践：文档、分步脚本、run.sh、实测结果
└── bolt/
    ├── README.md       BOLT 通用文档
    └── practice/       BOLT 实践：文档、分步脚本、run.sh、实测结果
```

## 参考

- Jakub Beránek，[Optimizing Rust programs with PGO and BOLT using cargo-pgo](https://kobzol.github.io/rust/cargo/2023/07/28/rust-cargo-pgo.html)
- [The rustc book：Profile-guided Optimization](https://doc.rust-lang.org/rustc/profile-guided-optimization.html)
- [BOLT README](https://github.com/llvm/llvm-project/blob/main/bolt/README.md)
