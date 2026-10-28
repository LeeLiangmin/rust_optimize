# Rust 程序的 PGO 与 BOLT 优化

PGO 和 BOLT 依据程序运行时的 profile 进行优化，无需修改源码。PGO 在编译期调整内联、分支布局等编译决策；BOLT 在链接之后重排机器码。两者可以单独使用，也可以叠加使用，叠加时先 PGO、后 BOLT。

## Rust 的支持情况

rustc 内置 PGO 支持；BOLT 不属于 Rust 工具链，作用于 rustc 生成的二进制。

| 项目 | PGO | BOLT |
|:---|:---|:---|
| 支持方式 | rustc 自 1.37 起提供稳定的编译选项 `-Cprofile-generate`、`-Cprofile-use` | 单独安装 LLVM 的 BOLT 工具（LLVM 14 起提供）；构建时以 `-Clink-args=-Wl,-q` 保留重定位信息 |
| 所需工具 | `llvm-profdata`，由 rustup 组件 `llvm-tools-preview` 提供 | `llvm-bolt`、`merge-fdata`；采样方式另需 `perf`、`perf2bolt` |
| profile 采集 | 插桩；采样式 PGO（`-Zprofile-sample-use`）仅在 nightly 中可用，稳定化变更已合并，里程碑为 1.100 | 插桩或 `perf` 采样 |
| 平台 | rustc 支持的主流平台（Linux、macOS、Windows） | Linux ELF（x86_64、AArch64）；macOS 仅有初步的 Mach-O 支持；Windows 不可用 |
| 主要限制 | rustup 分发的标准库为预编译，不参与优化 | 默认丢弃调试信息 |

社区工具 [cargo-pgo](https://crates.io/crates/cargo-pgo) 将两项技术的构建、采集和合并封装为 Cargo 子命令。

## 文档

| 技术 | 文档 | 内容 | 示例 |
|:---|:---|:---|:---|
| PGO | [PGO.md](PGO.md) | 概述、原理、操作步骤、cargo-pgo 用法 | [examples/pgo/](examples/pgo/README.md) |
| BOLT | [BOLT.md](BOLT.md) | 概述、原理、操作步骤、与 PGO 叠加、cargo-pgo 用法 | [examples/bolt/](examples/bolt/README.md) |

BOLT.md 引用了 PGO.md 中的部分内容，建议先阅读 PGO.md。

## 示例

`examples/` 以 ripgrep 14.1.1 为实验对象，按上述文档的步骤完成三个示例。每个示例目录包含说明（README.md）和脚本（run.sh），脚本的内容即文档中的操作步骤，运行时打印各步骤的标题和产出。语料、负载、评测方法和运行环境见 [examples/README.md](examples/README.md)。

| 示例 | 内容 | 测试环境下的耗时 |
|:---|:---|---:|
| [PGO](examples/pgo/README.md) | 构建普通版与 PGO 版，并评测 | 约 6 分钟（含语料下载） |
| [BOLT](examples/bolt/README.md) | 构建 BOLT 版（插桩、采样）与 PGO + BOLT 版，并评测 | 约 9.5 分钟 |
| [cargo-pgo](examples/cargo-pgo/README.md) | 用 cargo-pgo 完成 PGO 与 PGO + BOLT，并校验输出 | 约 6 分钟 |

BOLT 示例和 cargo-pgo 示例使用 PGO 示例的产物，需按以下顺序运行：

```bash
bash examples/pgo/run.sh
bash examples/bolt/run.sh
bash examples/cargo-pgo/run.sh
```

## 目录结构

```
├── README.md
├── PGO.md                 PGO 文档
├── BOLT.md                BOLT 文档
├── assets/                文档中的流程图
└── examples/
    ├── README.md          示例设计：实验对象、语料、负载、评测方法、运行环境
    ├── pgo/               PGO 示例：README.md、run.sh、results.md
    ├── bolt/              BOLT 示例：README.md、run.sh、results.md
    ├── cargo-pgo/         cargo-pgo 示例：README.md、run.sh
    ├── common/            共用脚本：workload.sh（语料与训练负载）、bench.sh（评测）
    ├── subjects/ripgrep/  实验对象源码
    └── work/              运行时生成，不提交
```

## 参考

- [The rustc book：Profile-guided Optimization](https://doc.rust-lang.org/rustc/profile-guided-optimization.html)
- [BOLT README](https://github.com/llvm/llvm-project/blob/main/bolt/README.md)
- Jakub Beránek，[Optimizing Rust programs with PGO and BOLT using cargo-pgo](https://kobzol.github.io/rust/cargo/2023/07/28/rust-cargo-pgo.html)
