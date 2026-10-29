# Rust 程序的 PGO 与 BOLT 优化

PGO 和 BOLT 依据程序运行时的 profile 进行优化，无需修改源码。PGO 在编译期调整内联、分支布局等编译决策；BOLT 在链接之后重排机器码。两者可以单独使用，也可以叠加使用。

## Rust 的支持情况

rustc 自 1.37 起以稳定的编译选项 `-Cprofile-generate`、`-Cprofile-use` 支持 PGO，合并 profile 所需的 `llvm-profdata` 由 rustup 组件 `llvm-tools-preview` 提供。BOLT 不属于 Rust 工具链，需单独安装 LLVM 的 BOLT 工具，作用于 rustc 生成的 Linux ELF 二进制，构建时以 `-Clink-args=-Wl,-q` 保留重定位信息。华为毕昇编译器的 FGO 特性目前在 rustc 中没有对应的支持。此外，社区提供了工具 [cargo-pgo](https://crates.io/crates/cargo-pgo) 将 PGO 和 BOLT 的构建、采集和合并封装为 Cargo 子命令。

工具、profile 采集方式、平台和限制的完整对比见 [GUIDE.md 第 1 章](GUIDE.md#1-概述)。

## 文档与示例

针对这些技术，我们提供一本手册 [GUIDE.md](GUIDE.md) 和配套示例。手册说明各项技术的原理、使用方法和注意事项，内容通用，不依赖具体项目；最后一章以 ripgrep 为实践案例，按手册的步骤完成优化，给出每一步的命令、实际输出和评测数据。可先阅读技术章节了解流程，再通过实践案例查看各步骤在实际程序上的运行结果。

| 章 | 内容 |
|:---|:---|
| [1 概述](GUIDE.md#1-概述) | 三项技术的关系，Rust 的支持情况 |
| [2 PGO](GUIDE.md#2-pgo) | 简介、优化原理、使用方法、注意事项 |
| [3 FGO](GUIDE.md#3-fgo) | 毕昇编译器的 FGO 特性，与 PGO 的差别，Rust 中的现状 |
| [4 BOLT](GUIDE.md#4-bolt) | 简介、优化原理、输入二进制的要求、验证范围、使用方法、注意事项 |
| [5 PGO 与 BOLT 叠加](GUIDE.md#5-pgo-与-bolt-叠加) | 叠加的顺序和步骤 |
| [6 使用 cargo-pgo](GUIDE.md#6-使用-cargo-pgo) | 用 cargo-pgo 完成 PGO、BOLT 和两者叠加 |
| [7 实践案例：ripgrep](GUIDE.md#7-实践案例ripgrep) | 案例说明、负载与评测方法、各案例的操作记录、优化效果 |

实践案例的脚本位于 `examples/`，以 ripgrep 14.1.1（源码未修改）为实验对象。脚本按手册的步骤执行，运行时打印各步骤的标题和产出：

| 脚本 | 内容 | 测试环境下的耗时 |
|:---|:---|---:|
| [`examples/pgo/run.sh`](examples/pgo/run.sh) | 构建普通版与 PGO 版，并评测 | 约 6 分钟（含语料下载） |
| [`examples/bolt/run.sh`](examples/bolt/run.sh) | 构建 BOLT 版（插桩、采样）与 PGO + BOLT 版，并评测 | 约 9.5 分钟 |
| [`examples/cargo-pgo/run.sh`](examples/cargo-pgo/run.sh) | 用 cargo-pgo 完成 PGO 与 PGO + BOLT，并校验输出 | 约 6 分钟 |

BOLT 和 cargo-pgo 的脚本使用 PGO 脚本的产物，需按以下顺序运行。运行环境要求见 [GUIDE.md 7.1 节](GUIDE.md#71-案例说明)。

```bash
bash examples/pgo/run.sh
bash examples/bolt/run.sh
bash examples/cargo-pgo/run.sh
```

## 目录结构

```
├── README.md
├── GUIDE.md               手册：PGO、FGO、BOLT、cargo-pgo、实践案例
├── assets/                手册中的流程图
└── examples/
    ├── README.md          案例目录说明
    ├── pgo/               PGO 案例：README.md、run.sh、results.md
    ├── bolt/              BOLT 案例：README.md、run.sh、results.md
    ├── cargo-pgo/         cargo-pgo 案例：README.md、run.sh
    ├── common/            共用脚本：workload.sh（语料与训练负载）、bench.sh（评测）
    ├── subjects/ripgrep/  实验对象源码
    └── work/              运行时生成，不提交
```

## 参考

- [The rustc book：Profile-guided Optimization](https://doc.rust-lang.org/rustc/profile-guided-optimization.html)
- [BOLT README](https://github.com/llvm/llvm-project/blob/main/bolt/README.md)
- Jakub Beránek，[Optimizing Rust programs with PGO and BOLT using cargo-pgo](https://kobzol.github.io/rust/cargo/2023/07/28/rust-cargo-pgo.html)
