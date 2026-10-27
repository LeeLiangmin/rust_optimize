# Rust 程序的 PGO 与 BOLT 优化

PGO 和 BOLT 依据程序运行时的 profile 进行优化，无需修改源码。PGO 在编译期调整内联、分支布局等编译决策，rustc 内置支持；BOLT 在链接之后重排机器码，需单独安装 BOLT 工具。两者可以单独使用，也可以叠加使用，叠加时先 PGO、后 BOLT。

## 文档

| 技术 | 文档 | 内容 | 示例 |
|:---|:---|:---|:---|
| PGO | [PGO.md](PGO.md) | 概述、原理、操作步骤、cargo-pgo 用法 | [examples/pgo.md](examples/pgo.md) |
| BOLT | [BOLT.md](BOLT.md) | 概述、原理、操作步骤、与 PGO 叠加、cargo-pgo 用法 | [examples/bolt.md](examples/bolt.md) |

BOLT.md 引用了 PGO.md 中的部分内容，建议先阅读 PGO.md。

## 示例

`examples/` 以 ripgrep 14.1.1（源码位于 `examples/ripgrep/`，未修改）为示例程序，按上述文档的步骤完成 PGO 和 BOLT 的完整流程。每个脚本的内容即文档中的操作步骤，运行时打印各步骤的标题和产出。

| 脚本 | 内容 | 测试环境下的耗时 |
|:---|:---|---:|
| [`pgo.sh`](examples/pgo.sh) | 构建普通版与 PGO 版，并评测 | 约 6 分钟（含语料下载） |
| [`bolt.sh`](examples/bolt.sh) | 构建 BOLT 版（插桩、采样）与 PGO + BOLT 版，并评测；PGO + BOLT 使用 `pgo.sh` 生成的 profile | 约 9.5 分钟 |
| [`cargo-pgo.sh`](examples/cargo-pgo.sh) | 用 cargo-pgo 完成 PGO 与 PGO + BOLT；输出对照使用 `pgo.sh` 生成的普通版 | 约 6 分钟 |

```bash
bash examples/pgo.sh
bash examples/bolt.sh
bash examples/cargo-pgo.sh
```

三个脚本以 Linux 6.6 内核源码为语料，首次运行时自动下载。profile 由 9 条搜索采集（[`workload.sh`](examples/workload.sh)），评测使用另外 7 条搜索（[`bench.sh`](examples/bench.sh)）：先确认各版本输出一致，再测量墙钟时间和用户态硬件计数器，结果写入 `examples/results/`。

运行环境为 Linux，需要 rustup 工具链（含 `llvm-tools-preview`）、`perf`、`hyperfine`；BOLT 示例另需 18 及以上版本的 BOLT 工具，cargo-pgo 示例另需 `cargo install cargo-pgo`。语料与构建产物存放在 `examples/work/`，约需 4 GB 磁盘空间，可通过环境变量 `WORK_DIR` 修改。在 WSL 中，仓库或 `WORK_DIR` 应位于 Linux 文件系统内，否则文件共享的 I/O 开销会影响测量结果。测试环境为 Intel Core i7-9750H、WSL2 Ubuntu 24.04、rustc 1.93.1、BOLT 21.1.8。

## 目录结构

```
├── README.md
├── PGO.md                PGO 文档
├── BOLT.md               BOLT 文档
├── assets/               文档中的流程图
└── examples/
    ├── pgo.sh   pgo.md   PGO 示例脚本与说明
    ├── bolt.sh  bolt.md  BOLT 示例脚本与说明
    ├── cargo-pgo.sh      cargo-pgo 示例
    ├── workload.sh       语料下载与训练负载
    ├── bench.sh          评测
    ├── results/          评测结果
    ├── ripgrep/          示例程序源码
    └── work/             运行时生成，不提交
```

## 参考

- [The rustc book：Profile-guided Optimization](https://doc.rust-lang.org/rustc/profile-guided-optimization.html)
- [BOLT README](https://github.com/llvm/llvm-project/blob/main/bolt/README.md)
- Jakub Beránek，[Optimizing Rust programs with PGO and BOLT using cargo-pgo](https://kobzol.github.io/rust/cargo/2023/07/28/rust-cargo-pgo.html)
