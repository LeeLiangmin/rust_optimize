# Rust 程序的 PGO 与 BOLT 优化

PGO 和 BOLT 都依据程序运行时的 profile 进行优化，无需修改源码，可以单独使用，也可以叠加使用（先 PGO，后 BOLT）。本仓库提供两项技术的文档，以及在实际 Rust 程序上的配套示例。

## PGO

PGO（Profile-Guided Optimization）在编译期依据 profile 调整内联、分支布局等编译决策，rustc 内置支持。

- 文档：[PGO.md](PGO.md)，包括介绍、原理、Rust 中的支持情况和操作步骤
- 示例：[examples/pgo.md](examples/pgo.md)，脚本为 [examples/pgo.sh](examples/pgo.sh)

## BOLT

BOLT（Binary Optimization and Layout Tool）在链接之后依据 profile 重排机器码，需另行安装 BOLT 工具。

- 文档：[BOLT.md](BOLT.md)，包括介绍、原理、版本要求、操作步骤，以及与 PGO 叠加的方法
- 示例：[examples/bolt.md](examples/bolt.md)，脚本为 [examples/bolt.sh](examples/bolt.sh)

## 配套示例

示例以 ripgrep 14.1.1 为示例程序（源码位于 `examples/ripgrep/`，未修改），演示在实际 Rust 程序上完整应用 PGO 和 BOLT 的过程；相同的流程适用于其他 Rust 程序。每个脚本从上到下即为文档中的操作步骤，运行时逐步打印步骤标题和产出。

| 脚本 | 内容 | 耗时 |
|:---|:---|---:|
| `examples/pgo.sh` | 构建普通版与 PGO 版，并评测 | 约 6 分钟（含语料下载） |
| `examples/bolt.sh` | 构建 BOLT 版（插桩 / 采样）与 PGO + BOLT 版，并评测；PGO + BOLT 需要先运行 `pgo.sh` | 约 9.5 分钟 |
| `examples/cargo-pgo.sh` | 用 cargo-pgo 完成 PGO 与 PGO + BOLT | 约 6 分钟 |

```bash
bash examples/pgo.sh
bash examples/bolt.sh
bash examples/cargo-pgo.sh
```

两个示例使用相同的设定：以 Linux 6.6 内核源码为语料（首次运行时自动下载），用 9 条搜索采集 profile（`workload.sh`），用另外 7 条搜索评测（`bench.sh`）；评测先确认各版本输出一致，再测量墙钟时间和用户态硬件计数器，结果写入 `examples/results/`。

运行需要 Linux、rustup 工具链（含 `llvm-tools-preview`）、`perf`、`hyperfine`；BOLT 示例另需 18 及以上版本的 BOLT 工具，cargo-pgo 示例另需 `cargo install cargo-pgo`。语料与构建产物存放在 `examples/work/`，约需 4 GB 磁盘空间，可通过环境变量 `WORK_DIR` 修改。在 WSL 中应将仓库或 `WORK_DIR` 放在 Linux 文件系统内，否则文件共享的 I/O 开销会掩盖优化效果。

## 目录结构

```
├── README.md
├── PGO.md                PGO 文档
├── BOLT.md               BOLT 文档
├── assets/               文档中的流程图
└── examples/             配套示例
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
