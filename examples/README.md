# 实践案例

本目录为 [GUIDE.md](../GUIDE.md) 第 7 章实践案例的脚本、评测结果和实验对象源码。案例说明、负载与评测方法、各步骤的命令和输出、优化效果均见第 7 章。

| 目录 | 内容 | 手册中的说明 |
|:---|:---|:---|
| [`pgo/`](pgo/) | `run.sh` 构建普通版与 PGO 版并评测，结果写入 `results.md` | [7.3 节](../GUIDE.md#73-pgo-优化方法) |
| [`bolt/`](bolt/) | `run.sh` 构建 BOLT 版（插桩、采样）与 PGO + BOLT 版并评测，结果写入 `results.md` | [7.4 节](../GUIDE.md#74-bolt-优化方法) |
| [`cargo-pgo/`](cargo-pgo/) | `run.sh` 用 cargo-pgo 完成 PGO 与 PGO + BOLT | [7.5 节](../GUIDE.md#75-cargo-pgo-优化方法) |
| [`common/`](common/) | `workload.sh`（语料下载、训练负载）、`bench.sh`（评测） | [7.2 节](../GUIDE.md#72-负载与评测方法) |
| [`subjects/`](subjects/) | 实验对象 ripgrep 14.1.1 的源码 | [subjects/README.md](subjects/README.md) |
| `work/` | 运行时生成的语料、构建缓存、可执行文件和 profile，不纳入版本控制 | — |

BOLT 和 cargo-pgo 案例使用 PGO 案例的产物，需按以下顺序运行：

```bash
bash examples/pgo/run.sh
bash examples/bolt/run.sh
bash examples/cargo-pgo/run.sh
```
