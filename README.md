# Rust 程序的 PGO 与 BOLT 优化

PGO 和 BOLT 都依据程序运行时的 profile 进行优化，无需修改源码，可以单独使用，也可以叠加使用（先 PGO，后 BOLT）。本仓库提供两项技术的文档，以及在实际 Rust 程序上的配套示例。

## PGO

PGO（Profile-Guided Optimization）在编译期依据 profile 调整内联、分支布局等编译决策，rustc 内置支持。

- 文档：[PGO.md](PGO.md)，包括介绍、原理、Rust 中的支持情况和操作步骤
- 示例：[experiments/pgo/](experiments/pgo/)，说明见 [PRACTICE.md](experiments/pgo/PRACTICE.md)

## BOLT

BOLT（Binary Optimization and Layout Tool）在链接之后依据 profile 重排机器码，需另行安装 BOLT 工具。

- 文档：[BOLT.md](BOLT.md)，包括介绍、原理、版本要求、操作步骤，以及与 PGO 叠加的方法
- 示例：[experiments/bolt/](experiments/bolt/)，说明见 [PRACTICE.md](experiments/bolt/PRACTICE.md)

## 配套示例

两个示例以 ripgrep 14.1.1 为示例程序（源码位于 `experiments/subjects/ripgrep/`，未修改），演示在实际 Rust 程序上完整应用 PGO 和 BOLT 的过程；相同的流程适用于其他 Rust 程序。

| | PGO 示例 | BOLT 示例 |
|:---|:---|:---|
| 构建的版本 | 普通版、PGO 版 | 普通版、PGO 版、BOLT 版（插桩 / 采样）、PGO + BOLT 版 |
| 运行 | `bash experiments/pgo/practice/run.sh` | `bash experiments/bolt/practice/run.sh` |
| 耗时 | 约 7.5 分钟 | 约 14 分钟 |
| 结果 | [results.md](experiments/pgo/practice/results.md) | [results.md](experiments/bolt/practice/results.md) |

两个示例使用相同的设定：以 Linux 6.6 内核源码为语料，用 9 条搜索采集 profile，用另外 7 条搜索评测；评测时先确认各版本输出一致，再测量墙钟时间和用户态硬件计数器。

运行需要 Linux、rustup 工具链（含 `llvm-tools-preview`）、`perf`、`hyperfine`，BOLT 示例另需 18 及以上版本的 BOLT 工具；`run.sh` 会先检查依赖。语料与构建产物存放在 `experiments/work/`，约需 4 GB 磁盘空间。

## 参考

- [The rustc book：Profile-guided Optimization](https://doc.rust-lang.org/rustc/profile-guided-optimization.html)
- [BOLT README](https://github.com/llvm/llvm-project/blob/main/bolt/README.md)
- Jakub Beránek，[Optimizing Rust programs with PGO and BOLT using cargo-pgo](https://kobzol.github.io/rust/cargo/2023/07/28/rust-cargo-pgo.html)
