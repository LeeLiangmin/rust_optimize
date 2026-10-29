# BOLT 案例

对 ripgrep 以插桩、采样两种方式应用 BOLT，并在 PGO 版上叠加 BOLT，以 7 条评测搜索对比各版本与普通版，结果写入 [`results.md`](results.md)。需先运行 PGO 案例。步骤、实际输出和说明见 [GUIDE.md 7.3 节](../../GUIDE.md#73-bolt-优化方法)，结果分析见 [7.5 节](../../GUIDE.md#75-优化效果)。

```bash
bash examples/bolt/run.sh
```
