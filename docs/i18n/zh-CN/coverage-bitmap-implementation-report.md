# 位图覆盖后端：实现报告

[English](../../coverage-bitmap-implementation-report.md) · [Русский](../ru/coverage-bitmap-implementation-report.md) · [Español](../es/coverage-bitmap-implementation-report.md) · **简体中文** · [所有语言](../README.md)

历史 bitmap-v1 基线。当前活动路径会复用已封存的映射；
参见 [bitmap-v2 后续报告](coverage-bitmap-v2-results.md)。下文的测量及不复用说明描述报告当时的 v1。

日期：2026-10-02。工作副本：`8b5cb05b5b57231b9133be13c883f25863e05d11`，加上已有未提交修改。
此工作未覆盖无关的脏文件，也未改变默认后端。[架构](coverage-bitmap-architecture.md)和
[计划](plans/coverage-bitmap-implementation-plan.md)定义了预期契约。

## 已实现内容

| 边界 | 文件和 API |
| --- | --- |
| 映射与存储 | [`efz_cov_bitmap.erl`](../../../src/efz_cov_bitmap.erl)：`prepare/2`、`open/1`、`hit/2`、`snapshot_bits/1`、`reset/1`、`close/1`、`release/1`、`unseen_bits/2`、`merge_bits/2`、`decode/2`。 |
| 分发 | [`efz_coverage.erl`](../../../src/efz_coverage.erl)：内部 `open/3`、`prepare_schema/2`、`new_global/1`、`snapshot_bits/1`、按位比较与合并、诊断解码。现有 ETS API 保留。 |
| 选择与生命周期 | [`efz_config.erl`](../../../src/efz_config.erl)仅允许自动 presence 使用位图，并在活动前验证容量；[`efz_worker.erl`](../../../src/efz_worker.erl)拥有模式和全局状态，并从持久化结果移除内部位；[`efz_guardian.erl`](../../../src/efz_guardian.erl)在清理受控写入者后收集位；[`efz_executor.erl`](../../../src/efz_executor.erl)验证模式及构建固定标识；[`efz_feedback.erl`](../../../src/efz_feedback.erl)使用现有的仅成功才提交策略。[`efz_instrument_pt.erl`](../../../src/efz_instrument_pt.erl)将新增内部模块排除在目标插桩之外。 |
| 测试与测量 | [`efz_bitmap_contract_tests.erl`](../../../test/efz_bitmap_contract_tests.erl)、[`efz_isolation_tests.erl`](../../../test/efz_isolation_tests.erl)中的位图案例、配对 [`bitmap_bench.escript`](../../../bench/bitmap_bench.escript)、[原始样本](../../performance/bitmap-2026-10-02-samples.txt)。 |

插桩仍生成 `efz_cov_rt:hit({Module,BuildId,ProbeId})`；测试驱动和变异算子不接触后端。
worker 根据已验证清单准备受保护的 `FullId → Slot` ETS 表，按 UTF-8 模块名、
完整 32 字节 BuildId 和 ProbeId 对完整标识排序。重复项和 `N > coverage_bitmap_bits` 会被拒绝。
版本化 SHA-256 指纹包含指标、模式及插桩版本、容量和规范化标识。
未知命中和不兼容指纹会明确失败。默认 **65,536 位**需要 **8 KiB 有效载荷**，
另外还有 atomics、映射、反向元组、上下文及分配器开销。
没有取模、哈希或跨构建位图导入。

每次受控执行都会获得独有的无符号 `atomics` 字数组和活动标志。
接纳进程通过现有 guardian 门控显式获得上下文。
槽位 `s` 使用 atomics 索引 `s div 64 + 1` 和掩码 `1 bsl (s rem 64)`；
`compare_exchange/4` 对过期读取进行重试，包括第 63 位。
guardian 在快照前已会停止接纳、终止受控后代并等待 `DOWN` 与追踪屏障。
单次活动标志检查无法关闭检查到 CAS 之间的竞争窗口，因此生产路径从不复用旧可变映射。
已确认结果获得不可变 8 KiB 快照；未确认清理属于基础设施故障，不能提交。
`reset/1` 分配新映射。`clear_quiescent/1` 只是供已独立证明所有写入者停止的调用方使用的测量原语。
worker 拥有不可变全局快照及串行比较与提交。只有合法 `{ok,_}` 结果改变全局状态；
崩溃、退出、超时保留原有分类及产物行为，不进行全局合并。
公开观察与报告保留精确 ID；诊断解码不在命中热路径内。

## 验证

实现前：`ERL_FLAGS='+S 4:4' rebar3 compile`、完整 `eunit`（**226 项通过**）、
`ct`（**3 项通过**）、`xref`、`dialyzer` 全部通过。
旧 `bench/run.escript all _build/bitmap-baseline reference` 在耗时较长的 `hooks` 阶段运行超过三分钟后被中断；
**没有完整基线结果**。历史 `ERL_FLAGS='+S 4:4' escript scripts/coverage_bench.escript`
在实现后运行并通过，但它是插桩钩子微基准，不是端到端位图比较。
变更后早期并行 Rebar3 运行时，多条命令编译到同一构建树，导致 20 个全新 VM EUnit 案例出现 `undef`；
Dialyzer 也报告显式异常规范警告。改为串行执行并加入 `no_return()` 规范后，结果如下：

| 命令 | 结果 |
| --- | --- |
| `ERL_FLAGS='+S 4:4' rebar3 compile` | PASS |
| `ERL_FLAGS='+S 4:4' rebar3 eunit` | PASS，238 项测试 |
| `ERL_FLAGS='+S 4:4' rebar3 ct` | PASS，3 项测试 |
| `ERL_FLAGS='+S 4:4' rebar3 xref` | PASS |
| `ERL_FLAGS='+S 4:4' rebar3 dialyzer` | PASS |

契约测试覆盖空观察与重复观察、槽位 0/63/64/最后一位、溢出、两个模块中相同本地 ID、
不兼容构建与快照、一个或多个或没有新位、A→B→A、全局隔离、成功/崩溃/超时反馈、
确定性过期读取 CAS 重试、共享写入者和过期上下文。
受控后代与超时测试使用消息和屏障，而非仅靠睡眠。
固定种子的 ETS→bitmap→ETS 活动比较语料和精确覆盖决策；低层执行器测试比较相同事件历史。
这些测试并未证明任意原始 `spawn` 或远程进程的隔离，因为现有 EFZ guardian 不拥有它们。

## 基准测试

命令：`ERL_FLAGS='+S 4:4' escript bench/bitmap_bench.escript _build/bitmap-benchmark`。
各样本时间、reductions 与 minor GC 原始数据：
[bitmap-2026-10-02-samples.txt](../../performance/bitmap-2026-10-02-samples.txt)。
驱动预热两次，每个阶段采集 10 组交替配对样本，并在
`_build/bitmap-benchmark/bitmap-benchmark.term` 保存二进制 term。
环境：OTP 27.0、ERTS 15.0、Rebar3 3.25.0、Linux x86_64、Intel i7-1260P、`+S 4:4`；
65,536 位位图、1,024 个合成清单探针。
脚本 SHA-256 为 `975240e42d32a96228d7c177f33053492904c2c9a3aaca1a71d766168e95266b`；
位图模块 SHA-256 为 `e1e5d44bc248c031b8724bb99c1d8bd34109cb1a3a048989e8e2b31398b1fa99`；
解析器样例 SHA-256 为 `c834f09eb2bbeabf54c2948ad849ab0f9294e2e455f35ead54d75f589be35747`。

| 阶段（中位数微秒） | ETS | Bitmap |
| --- | ---: | ---: |
| 5,000 次重复命中 | 825 | 1,401 |
| 64 次稀疏命中 | 18 | 23 |
| 1,024 次不同命中 | 650 | 775 |
| 64 次命中快照 | 15 | 37 |
| 1,024 次命中快照 | 284 | 41 |
| 解码 1,024 个 ID | 324 | 85 |
| 静止后完整清零 | 1* | 18 |
| 比较 256 位或 ID | 84 | 29 |
| 合并 256 位或 ID | 58 | 28 |
| 十次稀疏完整周期 | 124 | 6,826 |
| 五次稠密完整周期 | 23,418 | 11,310 |
| 同一字内 1/2/4/8 个写入者 | 3,925 / 7,758 / 16,061 / 28,523 | 4,499 / 7,825 / 16,324 / 29,044 |
| 50 次执行的解析器活动墙钟时间 | 116,580 | 129,445 |

`*` ETS 比较测量新表创建而非清零；0–1 µs 低于计时器有效分辨率。
解析器工作负载使用 `efz_example_target`、固定种子的随机变异器、固定 50 次执行；
每个样本的语料大小均为 4，报告覆盖均为 5。
由墙钟中位数计算的 bitmap/ETS exec/s 比约为 **0.90**；
10 组配对 exec/s 比的中位数为 **0.887**，百分位 bootstrap 95% 区间为 **[0.825, 0.985]**
（10,000 次重采样，种子 `20261002`）。
解析器墙钟时间 p95（10 个样本的最近秩）为 **145,333 µs ETS**、**144,728 µs bitmap**。
稀疏完整周期显著更差；稠密位图比较及快照更好。不能据此得出通用加速结论。
`atomics:info(memory)` 报告字数组 8,232 字节，活动标志 48 字节；
映射 ETS 报告 20,084 个 VM 字，反向元组 external size 为 58,633 字节。
ETS 的 1,024 命中执行表报告 22,071 个 VM 字。
这些只是部分组件大小，不是完整活动 RSS 比较。
活动基准未隔离外部调度和温度噪声，也未运行第二个生产测试驱动。
因此，计划的可选启用性能门槛在此解析器工作负载上未通过，默认切换门槛**未满足**。
位图继续作为实验性可选模式；测量之后未增加重置或热路径优化。

## 选择、回滚及后续工作

在 API 活动配置中使用
`#{coverage => automatic, coverage_feedback => presence, coverage_backend => bitmap, coverage_bitmap_bits => 65536, ...}`；
照常传入插桩产物。回滚时设为 `coverage_backend => ets`，或移除该键。
`ets_member` 和 ETS `hit_count` 仍可用。CLI 尚未开放活动后端选择；无需改变测试驱动 API。
重新编译或加载要求新活动并重新验证清单。
语料输入字节可重新校准；保存的覆盖位要求指纹精确相同，不会在不同构建间导入。

仍待完成：不中断地完成历史 P0 基准；在代表性生产测试驱动上重复性能测试，
提供配对置信区间、p95 及完整内存/RSS；判断稀疏映射成本是否值得采用其他存储布局。
生产默认仍为 ETS。OTP 原生覆盖、边覆盖、桶、NIF 和 OTP 补丁不属于此次实现。
