# P0 验收修复 — 2026-09-21

[English](../../runtime-diagnostics-acceptance-fixes.md) · [Русский](../ru/runtime-diagnostics-acceptance-fixes.md) · [Español](../es/runtime-diagnostics-acceptance-fixes.md) · **简体中文** · [所有语言](../README.md)

## 结论：ACCEPT

P0-01、P0-02、P0-03、P0-04：PASS。正式 compile、两次 EUnit、CT、Dialyzer
和 xref 均退出 0。原有 harness 文件和所有权模型不变。无 P1/P2 功能、commit、
reset/clean/pull，也未删除已有更改。HEAD 仍为
`205e18ba172d74bd6c652a68abfc73e02e4a1f86`。
环境：OTP 27.0 / ERTS 15.0 / rebar3 3.25.0，`ERL_FLAGS='+S 4:4'`。

## 修复与根因

### P0-02：先验证，再进行昂贵工作

`efz_stability:bounded_return/1` 原先在检查预算前排序任意 map 键。现在使用
无序迭代器、逐元素元组访问和预算感知列表递归。独立限制：1024 个已访问节点、
1024 个二进制字节、1024 个容器元素、深度 64。遍历/访问内容前检查容器大小和
binary byte_size。不对未经验证的数据进行 map-to-list、排序、重建或序列化。
只有整个 term 通过后才执行确定性 ETF/哈希。不支持的 term 返回 not_comparable；
默认仍禁用比较。

测试覆盖小 map、插入顺序等价、ref/PID/函数、巨大二进制键值、公共前缀大键、
超大 map、聚合字节预算与深度。只追踪 arity 的调用跟踪限制验证访问次数，并证明
被拒绝 term 从不调用 term_to_binary/2、maps:to_list/1、lists:sort/1；大参数
不复制进 trace 消息。不作绝对实时断言。

### P0-01：独立的清理后内存观察

执行期间增长仍是单独的既有观察。新观察测量执行前及正常 guardian DOWN、
确认清理、有界静默等待之后的 VM 全局二进制内存。它在 guardian 外通过受监控、
有截止期限的 helper 运行。失败为 incomplete/unavailable；不改变目标结果。
清理失败仍为基础设施失败，跳过此观察。不修改目标/共享状态，不对其他进程 GC，
不改变所有权。

证据存 baseline_memory、采样 peak_memory、post_execution_memory、
residual_delta、单位、阈值、scope、完整性、cleanup_status、静默等待、期限及
明确的归因限制。所有者终止后，目标所属 post memory 为 not_applicable。
`vm_memory_growth_suspected` 在证据和工件/去重身份里均属 vm_global，绝非
已证明的目标泄漏。旧 schema-v1 策略加载时按新默认值规范化。

新 fixture 通过普通 run(binary()) 返回新 16 MiB 二进制。根进程清理后 EFZ
保留返回值：这是支持的剩余 VM 分配，归因有限。活动再现率 3/3。Replay 在
执行间丢弃原始返回值，旧二进制回收可能抵消新分配；它报告实际 M/N，而非强制
3/3 或泄漏判定。证据运行得到 1/3。临时 16 MiB 分配有峰值、无剩余发现
（专用运行 delta 40 字节，低于 fixture 的 8 MiB 阈值）。

另测暂停的 post-observation helper：目标 timeout 60 ms，guardian 在 66 ms
清理完，调用方在 167 ms 返回不完整内存证据，helper 已死，runner 可复用。
100 ms 观察期限在清理**之后**才超时，未推迟终止目标。

### P0-03：明确的未知超时

禁用 hangs 的分支原来不返回类别。现在启用 runtime diagnostics 而禁用 hangs
时，总将超时归为 unknown。原有无样本、过期和证据不足路径也返回 unknown。
Busy/waiting 不变，每次执行分类互斥。主结果 `{timeout, TimeoutMs}` 不变。

### P0-04：独立的测试基础设施修复

原 5s EUnit 超时包住两场 300 次执行的 limits 活动、四个独立 backend 变体
（约 400 次）或 512 次 scheduler 测试。活动本身已设置 10s await。
这让正确性测试意外成为主机整体吞吐量门槛。

修复前独立定向运行复现 limits 超时。新 clean-HEAD 普通运行也失败
（旧 exhaustion await 期限，完整运行中还有后续 smoke 失败），但不能稳定
复现三类短超时。因此另标注、限时的诊断竞争实验以相同 5s EUnit 期限在保存的
修复前树与 clean HEAD 上运行原三函数：六例全部取消。这些是诊断 FAIL，
不是正式 PASS，即使 driver 自身正常退出。

没有竞争负载时，断言不变，各自成功三次：limits 2.61–2.64s、scheduler
2.17–2.26s、backend 1.94–2.04s。每次回到 processes=41、ETS=19、
guardian=undefined、runner=ready。证据支持有限负载/受调度影响的聚合超时，
不是进程泄漏、清理丢失或无界 receive。

修复：把独立 limits 用例和 backend 变体拆成独立 EUnit 用例。外层 limits/
scheduler 期限改为 12s，与既有 10s await 加清理一致。保留迭代、变体、断言
和完整 256 父输入场景，无跳过、减负或兜底 catch。原有 75s exhaustion
测试 / 60s 活动期限保留。

该修复可在 [test-infrastructure.patch](../../runtime-fixes-validation/test-infrastructure.patch)
单独审查；相对初始脏 checkout，不含用户先前改动。

## 实现与测试文件变更

- `src/efz_stability.erl`：有界比较器。
- `src/efz_runtime.erl`：执行前/后观察、VM 样本上下文、timeout_unknown、
  更便宜的最终 ETS 存在性查询。
- `src/efz_runtime_config.erl`：剩余阈值/静默等待/期限验证。
- `src/efz_executor.erl`：执行前测量及正常 guardian DOWN 后集成。
- `src/efz_worker.erl`：新类别的 vm_global 工件 scope。
- `src/efz_runtime_store.erl`：带 scope 签名、类别验证、旧策略默认值。
- `src/efz_runtime_replay.erl`：复核中的剩余观察完整性。
- `fixtures/runtime/efz_runtime_memory_fixture.erl`：新 fixture，原 harness 未改。
- `test/efz_runtime_acceptance_tests.erl`：比较器/配置/内存/超时回归。
- `test/efz_limits_tests.erl`、`test/efz_backend_tests.erl`、`test/efz_phase3_tests.erl`：
  单独的测试基础设施变更。
- `docs/runtime-diagnostics.md`、本报告、`docs/runtime-fixes-validation/`：
  策略说明和新证据。

## 回归结果

以下命令均从项目 checkout 运行，使用 `ERL_FLAGS='+S 4:4'`。

| 命令 | 退出 | 通过 | 失败 / 跳过 | 秒 |
|---|---:|---:|---:|---:|
| rebar3 compile | 0 | — | — | 1 |
| rebar3 eunit，第 1 次 | 0 | 223 | 0 / 0 | 117 |
| rebar3 eunit，第 2 次 | 0 | 223 | 0 / 0 | 123 |
| rebar3 ct | 0 | 3 | 0 / 0 | 6 |
| rebar3 dialyzer | 0 | — | — | 8 |
| rebar3 xref | 0 | — | — | 1 |
| rebar3 eunit --module=efz_runtime_acceptance_tests,efz_runtime_tests | 0 | 20 | 0 / 0 | 8 |

先前组合定向运行（runtime + 三个原超时模块）通过 59 项；后来配置验证用例
包含在两次最终 223 项及最终 20 项 runtime 中。日志：
[第 1 次](../../runtime-fixes-validation/final-eunit-1.log)、
[第 2 次](../../runtime-fixes-validation/final-eunit-2.log)、
[命令状态](../../runtime-fixes-validation/results.txt)。

## 定向验收

| ID | 修复前 | 修复后 | 证据 |
|---|---|---|---|
| P0-01 | FAIL | PASS | 清理后 VM 测量；只有峰值的负例；活动 3/3；存储/重放实际 M/N；暂停 helper 期限 |
| P0-02 | FAIL | PASS | 遍历/序列化前检查预算；trace 证明昂贵调用前拒绝；大键预热 benchmark |
| P0-03 | FAIL | PASS | 禁用 sampler、间隔长于 timeout、零/旧/不完整样本、busy/waiting |
| P0-04 | FAIL | PASS | 两棵树上诊断原函数；正式完整 EUnit 两次，223/223 |

附加检查：启用 P0 的原 efz_example_target CLI 退出 0。示例与原 runtime
harness 和保存的修复前树逐字节一致。25 个 random/staged 变异在修复前/off/on
的输入、staged 轨迹/计数器、覆盖和 corpus 相同（排除易变元数据）。
既有 verification-isolation、verification-only-crash、dirty-runner、guardian
失败及暂停 sampler 测试通过。修复前保存的工件也在新 CLI VM 重放：兼容性确认，
child_abnormal_exit 观察到 3/3，退出 0
（[日志](../../runtime-fixes-validation/old-runtime-replay.log)）。

## 性能

每模式预热 50 次后运行三场 300 次变异活动，相同输入/种子，单 worker、
+S 4:4，VM 顺序运行。Before 是保存的**修复前脏树**，不是 clean HEAD
（无关 hit-count 变更保持一致）。按变异吞吐量选中位行；每行 calibration=1。

| 初始批次 | 变异 | 验证 | 墙钟秒 | 变异/s | 总执行/s |
|---|---:|---:|---:|---:|---:|
| 修复前，off | 300 | 0 | 1.749 | 171.52 | 172.09 |
| 修复后，off | 300 | 0 | 2.003 | 149.76 | 150.26 |
| 仅资源 | 300 | 0 | 2.005 | 149.60 | 150.10 |
| 完整 | 300 | 4 | 2.065 | 145.28 | 147.70 |

初始 off 差值 -12.7%，未隐藏。逆序对照得 before=202.48、after=206.45
变异/s（+2.0%）。另一 CPU/reductions 批次得 before=206.47、after=205.82
（-0.3%）。各三次的 CPU runtime 中位数：4358 -> 4333 ms（-0.6%）；
中位吞吐量运行的 reductions：27,963,230 -> 27,965,219（+0.007%）。
对照未复现明显 off 回退。主机调度/频率未固定，不保证普适吞吐量。
初始和对照数据保留于 [bench-summary.log](../../runtime-fixes-validation/bench-summary.log)。

预热比较器，100 次调用，map 含两个共享前缀二进制键（构建不计时），
所有结果为 not_comparable：

| 每键字节 | 修复前，us | 修复后，us |
|---:|---:|---:|
| 1025 | 46 | 31 |
| 1048577 | 6533 | 74 |
| 16777217 | 183717 | 44 |

这印证结构性边界，不是实时期限断言。compare_return=false 不增加比较器调用。

## ETS 说明与剩余限制

最终消失检查只查询 ets:info(Tab,owner)，避免分配完整 table-info 列表及无关
元数据。枚举和 owner 过滤不变。ets:all 仍先枚举所有 VM 表再限制检查数量：
文档明确 O(VM 表数)，位于 guardian 外。100 次枚举在额外 100 表时为
3210 us，额外 1000 表时 17313 us。未宣称所有权重设计或不支持的 VM 枚举上限。

VM 全局剩余指标刻意不作输入归因；旧返回回收可让重放 M/N 不同。
静默期是有界等待，不声称整个 VM 空闲。不宣称证实泄漏/死锁/活锁。
本修复集无剩余 MAJOR/BLOCKER 或已知正确性 MINOR。

## 其他已执行命令与原始证据

```sh
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_runtime_acceptance_tests,efz_runtime_tests,efz_limits_tests,efz_phase3_tests,efz_backend_tests
ERL_FLAGS='+S 4:4' escript /tmp/efz-p0-fixes/debt_probe.escript /home/anonymous_usr/erl:fuzz/efz
ERL_FLAGS='+S 4:4' timeout 50s escript /tmp/efz-p0-fixes/debt_contention.escript /tmp/efz-acceptance-20260921/baseline
ERL_FLAGS='+S 4:4' timeout 50s escript /tmp/efz-p0-fixes/debt_contention.escript /tmp/efz-p0-fixes/before-tree
ERL_FLAGS='+S 4:4' escript /tmp/efz-p0-fixes/short_bench.escript /tmp/efz-p0-fixes/before-tree before-off off
ERL_FLAGS='+S 4:4' escript /tmp/efz-p0-fixes/short_bench.escript /home/anonymous_usr/erl:fuzz/efz off off
ERL_FLAGS='+S 4:4' escript /tmp/efz-p0-fixes/short_bench.escript /home/anonymous_usr/erl:fuzz/efz resources resources
ERL_FLAGS='+S 4:4' escript /tmp/efz-p0-fixes/short_bench.escript /home/anonymous_usr/erl:fuzz/efz full full
ERL_FLAGS='+S 4:4' escript /tmp/efz-p0-fixes/post_bound.escript /home/anonymous_usr/erl:fuzz/efz
```

临时 driver/快照保留在 `/tmp/efz-p0-fixes/` 和
`/tmp/efz-acceptance-20260921/baseline/`。新日志位于
`docs/runtime-fixes-validation/`；没有把历史验收日志算作此次 PASS。
