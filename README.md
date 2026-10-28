# Rust 程序的 PGO 与 BOLT 优化

PGO（Profile-Guided Optimization）和 BOLT（Binary Optimization and Layout Tool）依据程序运行时采集的 profile 进行优化，无需修改源码。PGO 在编译期调整内联、分支布局等编译决策；BOLT 在链接之后重排机器码，使热代码集中。两者可以单独使用，也可以叠加使用，叠加时先 PGO、后 BOLT。

本仓库说明两项技术在 Rust 程序上的原理和操作步骤，并以 ripgrep 为实验对象提供可复现的示例脚本和实测数据。

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

Rust 官方发布的工具链本身也使用这两项技术构建。以下摘自 [Rust 发布说明](https://github.com/rust-lang/rust/blob/master/RELEASES.md)：

| 版本 | 变更 |
|:---|:---|
| 1.56（2021-10） | x86_64-unknown-linux-gnu 发布版中的 LLVM 以 PGO 编译 |
| 1.64（2022-09） | Windows x64 发布版的 rustc 使用 PGO，发布说明给出的编译器性能提升为 10%–20% |
| 1.66（2022-12） | 构建 LLVM 时启用 BOLT |
| 1.75（2023-12） | 以 BOLT 优化 `librustc_driver.so` |
| 1.86（2025-04） | AArch64 Linux 上的 rustc 以 ThinLTO + PGO 构建，发布说明给出的提速最高为 30% |

## 文档

两篇文档的内容为通用说明，适用于任意 Rust 程序，不依赖本仓库的示例。BOLT.md 引用了 PGO.md 中的部分内容，建议先阅读 PGO.md。

| 文档 | 原理 | 操作步骤 | 其他内容 |
|:---|:---|:---|:---|
| [PGO.md](PGO.md) | 插桩、采集、优化构建三个阶段；LLVM 利用 profile 进行的内联、基本块布局、冷热分离、间接调用提升 | 准备环境、插桩构建、采集、合并、优化构建、验证，含命令、参数说明和各步骤的检查方法 | cargo-pgo 用法、注意事项 |
| [BOLT.md](BOLT.md) | 基本块重排、函数拆分、函数重排；重定位信息和 profile 两项输入 | 准备环境、带重定位构建、插桩采集或采样采集、优化、验证，含命令、参数说明和各步骤的检查方法 | 与 PGO 叠加、cargo-pgo 用法、注意事项 |

## 示例

`examples/` 以 ripgrep 14.1.1（源码未修改）为实验对象，按上述文档的步骤完成三个示例。每个示例目录包含说明文档（README.md）和脚本（run.sh）；脚本的内容即文档中的操作步骤，运行时打印各步骤的标题和产出，说明文档列出每一步的命令和实际输出。语料、训练负载、评测用例、评测方法和运行环境见 [examples/README.md](examples/README.md)。

| 示例 | 完成的工作 | 测试环境下的耗时 |
|:---|:---|---:|
| [PGO](examples/pgo/README.md) | 构建普通版与 PGO 版，以 7 条评测搜索对比 | 约 6 分钟（含语料下载） |
| [BOLT](examples/bolt/README.md) | 以插桩、采样两种方式构建 BOLT 版，在 PGO 版上叠加 BOLT，与普通版、PGO 版一起评测 | 约 9.5 分钟 |
| [cargo-pgo](examples/cargo-pgo/README.md) | 用 cargo-pgo 完成 PGO 与 PGO + BOLT，校验输出与普通版一致 | 约 6 分钟 |

BOLT 示例中各版本相对普通版的用户态硬件计数器变化：

| 版本 | cycles | L1 i-cache 未命中 |
|:---|---:|---:|
| PGO | −10.0% ~ −15.2% | −30.3% ~ −34.0% |
| BOLT（插桩） | −4.0% ~ −12.9% | −44.3% ~ −48.1% |
| BOLT（采样） | −7.6% ~ −11.4% | −43.7% ~ −47.3% |
| PGO + BOLT | −12.1% ~ −16.8% | −44.4% ~ −48.8% |

cycles 为 7 个用例中除 no_literal 外 6 个用例的范围，no_literal 中各版本的变化不超过 2%；L1 i-cache 未命中为全部 7 个用例的范围。墙钟时间的变化与测量波动处于同一量级，原因是该负载的 CPU 时间大部分为内核态（literal 用例中约 58%），而两项技术只作用于用户态代码。各指标的完整数据和分析见各示例文档。

运行环境为 Linux，需要 rustup 工具链、`perf`、`hyperfine`，BOLT 示例另需 18 及以上版本的 BOLT 工具，cargo-pgo 示例另需 cargo-pgo，详见 [examples/README.md](examples/README.md#运行环境)。BOLT 示例和 cargo-pgo 示例使用 PGO 示例的产物，需按以下顺序运行：

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
- [Rust 发布说明（RELEASES.md）](https://github.com/rust-lang/rust/blob/master/RELEASES.md)
- Jakub Beránek，[Optimizing Rust programs with PGO and BOLT using cargo-pgo](https://kobzol.github.io/rust/cargo/2023/07/28/rust-cargo-pgo.html)
