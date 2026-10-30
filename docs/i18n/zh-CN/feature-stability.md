# 覆盖特征稳定性

本页是简明指南。[完整定义、配置和状态](../../feature-stability.md)以英语发布。

对一个被审核的输入，EFZ 使用每次执行的完整特征集合：`U = union(F₁…Fᵣ)`，`I = intersection(F₁…Fᵣ)`，`feature_stability = 100 × |I| / |U|`。活动指标先按**各输入组**分别计算 `|I|` 和 `|U|`，再对两者求和并相除。至少需要两个有效观测和非空 `U`，否则百分比为 null。有效的空 trace 与缺失 trace 不同。

在 isolated 模式中，20 次观测通常需要 19 次额外目标执行。诊断执行不计入 primary exec/s，也不改变变异 RNG。TUI 显示百分比、状态、已审核组数和上次测量距今时间。`100%` 只表示已完成观测中没有发现差异。

## Persistent target / same-sequence

持久目标审核比较不同 epoch 中同一完整 prefix 后的同一步。Scope 为 `audited_sequence_steps`；不同 prefix 是不同组。若 primary sample 可用，长度为 `k` 的 prefix 后对某一步收集 20 个观测，额外代价可能是 `19 × (k + 1)` 次诊断输入执行。不同 prefix 下行为变化是 history sensitivity，不是非确定性的证明。
