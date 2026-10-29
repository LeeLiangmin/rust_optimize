# 实验对象

`ripgrep/` 为 [GUIDE.md](../../GUIDE.md) 第 7 章实践案例的实验对象，仅用于演示 PGO 和 BOLT 的流程。

| 项目 | 内容 |
|:---|:---|
| 程序 | ripgrep，用 Rust 编写的命令行文本搜索工具 |
| 版本 | 14.1.1 |
| 来源 | <https://github.com/BurntSushi/ripgrep>，tag `14.1.1`（commit `4649aa9700619f94cf9c66876e9549d83420e16c`） |
| 修改 | 无，与上述 tag 的源码一致 |
| 许可证 | Unlicense 或 MIT，见 `ripgrep/COPYING`、`ripgrep/UNLICENSE`、`ripgrep/LICENSE-MIT` |

案例脚本通过 `--manifest-path subjects/ripgrep/Cargo.toml` 或在该目录下执行 `cargo pgo` 构建 ripgrep，不修改其中的文件。替换为其他 Rust 程序时，需相应修改脚本中的源码路径和 `common/` 中的负载。
