# Rust 程序优化指导与实践

本仓库提供一本 Rust 程序反馈式优化（PGO、FGO、BOLT）的手册 [GUIDE.md](GUIDE.md) 和可在本地复现的实践案例。手册说明 Rust 对各项技术的支持情况、原理、使用方法和注意事项，并以 ripgrep 为实践案例给出各步骤的结果和实测数据。

## 手册

| 章 | 内容 |
|:---|:---|
| [1 概述](GUIDE.md#1-概述) | 技术概况、Rust 支持情况 |
| [2 PGO](GUIDE.md#2-pgo) | 简介、优化原理、使用方法、注意事项 |
| [3 FGO](GUIDE.md#3-fgo) | 简介，与 PGO 的差别，毕昇编译器中的使用方法，Rust 中的现状 |
| [4 BOLT](GUIDE.md#4-bolt) | 简介、优化原理、输入二进制的要求、使用方法、注意事项 |
| [5 PGO 与 BOLT 叠加](GUIDE.md#5-pgo-与-bolt-叠加) | 叠加的顺序和步骤 |
| [6 使用 cargo-pgo](GUIDE.md#6-使用-cargo-pgo) | 用 cargo-pgo 完成 PGO、BOLT 和两者叠加 |
| [7 实践案例：ripgrep](GUIDE.md#7-实践案例ripgrep) | 案例说明、优化效果 |

## 实践案例

案例以 ripgrep 为实验对象，按手册的步骤完成 PGO、BOLT 和 cargo-pgo 三个案例并统一评测。在仓库根目录执行：

```bash
bash examples/run.sh
```

各案例的步骤、结果和单独运行的方法见 [examples/README.md](examples/README.md)。

## 目录结构

```
├── README.md
├── GUIDE.md               手册
├── assets/                手册中的流程图
└── examples/
    ├── README.md          案例说明：一键运行、各案例的步骤与结果、评测方法
    ├── run.sh             统一入口
    ├── results.md         评测结果
    ├── pgo/ bolt/ cargo-pgo/  各案例的脚本 run.sh
    ├── common/            共用脚本：workload.sh（语料与训练负载）、bench.sh（评测）
    ├── subjects/ripgrep/  实验对象源码
    └── work/              运行时生成，不提交
```
