# 位图覆盖后端实现计划

[English](../../../plans/coverage-bitmap-implementation-plan.md) · [Русский](../../ru/plans/coverage-bitmap-implementation-plan.md) · [Español](../../es/plans/coverage-bitmap-implementation-plan.md) · **简体中文** · [所有语言](../../README.md)

状态：P1–P7 于 2026 年 10 月 2 日实现并验证；P0 性能基线和 P8 推广尚未完成。
详细结果见[报告](../coverage-bitmap-implementation-report.md)。
依据为已与当前源码核对的[架构文档](../coverage-bitmap-architecture.md)。
首版：`automatic` + `presence`、单 EFZ worker、普通 OTP 构建、原有结构探针。
`ets` 保持默认和参考；`ets_member`、ETS `hit_count` 继续工作。
不包含 OTP/ERTS 补丁、DWARF、NIF、边覆盖、位图 hit-count 桶、测试驱动或变异引擎变化。

## 已验证起点与架构修正

| 契约 | 代码证据 |
| --- | --- |
| `efz_instrument:compile_target/2` 启用 `efz_instrument_pt`；`probe/4` 将 `efz_cov_rt:hit({Module,BuildId,ProbeId})` 插入子句或结果体。`ProbeId` 每模块构建从 1 开始。 | [`efz_instrument.erl`](../../../../src/efz_instrument.erl)、[`efz_instrument_pt.erl`](../../../../src/efz_instrument_pt.erl) |
| 当前命中入口检查 PID 和上下文并发送首命中事件；ETS 保存精确标识。`efz_cov` 提供公开兼容 API，`efz_coverage` 已是分发器，`efz_cov_ets` 实现存储及现有集合操作。 | [`efz_cov_rt:hit/1`](../../../../src/efz_cov_rt.erl)、[`efz_cov.erl`](../../../../src/efz_cov.erl)、[`efz_coverage.erl`](../../../../src/efz_coverage.erl)、[`efz_cov_ets.erl`](../../../../src/efz_cov_ets.erl) |
| guardian 每执行创建新上下文和表；根及 `efz_target:spawn[_link]/1` 经门接纳、显式附加。多个写入者共用执行表。超时或完成后 guardian 停止接纳、杀存活者、等 `DOWN` 与追踪屏障、取快照。未成功清理标记 dirty。 | [`efz_guardian:start/6`、`admit/2`、`cleanup/2`、`finish/2`](../../../../src/efz_guardian.erl)、[`efz_target.erl`](../../../../src/efz_target.erl)、[`efz_cov_integrity.erl`](../../../../src/efz_cov_integrity.erl) |
| `efz_feedback:evaluate/3` 比较 `Observed − Global`，**仅**合并 `coverage_status=ok`、`outcome={ok,_}`。校准更新全局，不重复加种子。崩溃、退出、超时不更新全局。worker 按 `retention_reason` 保留语料；崩溃产物单独路径。 | [`efz_feedback.erl`](../../../../src/efz_feedback.erl)、[`efz_worker:execute_result/6`、`retain/2`、`record_failure/4`](../../../../src/efz_worker.erl)、[`efz_corpus.erl`](../../../../src/efz_corpus.erl) |
| `rebar.config` 要求最低 OTP 27 和 `warnings_as_errors`；本地验证 OTP 27.0 / ERTS 15.0、x86_64、Rebar3 3.25.0。`atomics` 导出 `compare_exchange/4`，无 OR；无符号数组接受并返回 `1 bsl 63`、`2^64−1`。CAS 成功返回 `ok`，不匹配返回旧值。这是本地 API 检查，不是性能证明。 | [`rebar.config`](../../../../rebar.config)；下方命令 |
| 测试：`rebar3 eunit --module=efz_coverage_layer_tests,efz_backend_tests`、`rebar3 ct`、完整 `rebar3 eunit`、xref/dialyzer。集成：`efz_coverage_SUITE`、`efz_feedback_loop_tests`、`efz_isolation_tests`、`efz_backend_tests`。基准：`scripts/coverage_bench.escript`、`bench/run.escript`（`hooks`、`executor`、`campaign`、`memory`、`startup`）、`bench/profile.escript`。 | [`test/`](../../../../test)、[`bench/run.escript`](../../../../bench/run.escript)、[`bench/efz_perf.erl`](../../../../bench/efz_perf.erl)、[`scripts/coverage_bench.escript`](../../../../scripts/coverage_bench.escript) |

本会话检查：`ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_coverage_layer_tests,efz_backend_tests`
— **18/18 PASS**。这是现有 ETS 基线，不是位图验证。
源码树原本已脏；逻辑和计时基线需精确 commit/diff 及独立结果目录。

不修改文件即可在此 OTP 复现原语检查：

```sh
erl -noshell -eval 'A=atomics:new(1,[{signed,false}]), M=1 bsl 63, ok=atomics:compare_exchange(A,1,0,M), M=atomics:get(A,1), ok=atomics:compare_exchange(A,1,M,16#ffffffffffffffff), 16#ffffffffffffffff=atomics:get(A,1), io:format("~p~n",[atomics:module_info(exports)]), halt().'
```

原架构已修正：首版配置拒绝 bitmap + `hit_count`，明确已测 OTP 27.0 的符号和 CAS。
另一个重要实现细节：当前 `efz_coverage:unseen/2`、`merge/2` 使用 Erlang 集合和列表，
`Result.coverage` 是精确标识列表。
因此按位比较需在原公开列表之外增加**内部**快照，只替换 `hit/2` 不够。
当前 guardian 即便 dirty 清理仍可形成 Hits 列表，但把 `coverage_status` 标为错误；
位图同样不得把此列表视为稳定或可提交。

## 首版最终决策

### A. 模式与槽位

唯一键是来自已验证清单的 `{Module, BuildId, ProbeId}`。
活动准备时 [`efz_cov_manifest:prepare/2`](../../../../src/efz_cov_manifest.erl)
继续提供允许列表和构建固定标识；位图准备构建绑定该计划的独立**不可变模式描述符**。
按 UTF-8 模块名、全部 32 字节 BuildId、正 ProbeId 排序，检查唯一性，分配连续槽 `0..N−1`。
worker 拥有受保护 ETS `FullId → Slot`；反向数组或元组 `Slot → FullId` 只用于快照和报告。
查找保留完整标识：不同模块或构建相同 `ProbeId` 仍是不同槽。
构建映射及版本化规范序列 SHA-256 进入模式指纹。
模式或构建不匹配在比较前成为基础设施错误；不忽略新增或未知探针。

指纹来自显式格式版本、指标 `clause_outcome_probe`、清单和插桩版本、容量、规范标识序列，
不依赖未约定 ETF map 顺序。
`coverage_bitmap_bits` 默认 **65536 位**，为 64 的整数倍；
`N > capacity` 是含 `required_bits`、`configured_bits` 的明确准备错误。
活动中不自动扩容，用户可在启动**之前**选大图。
未用槽保持零。无 `rem MapSize`、截断或 BuildId 混合。
保存的语料输入字节可在新构建重新校准；覆盖位图不自动跨构建转移。
首版不增加全局位图磁盘保存格式。

### B. 可变映射与第 63 位

执行映射是 `atomics:new(Capacity div 64,[{signed,false}])`，无符号 64 位字。
`Slot ∈ [0,Capacity)` 时计算 `Word = Slot div 64 + 1`（atomics API 从 1 索引），
`Mask = 1 bsl (Slot rem 64)`。
槽 63 掩码 `2^63` 对无符号数组合法；槽 64 是字 2、掩码 1。
先检查边界及模式查找，再 CAS 循环：`Old=atomics:get`；若 `(Old band Mask) /= 0` 则完成；
否则 `compare_exchange(Ref,Word,Old,Old bor Mask)`，`ok` 为首次命中，返回当前值则重试。
`badarg` 时通知 guardian 后端故障。
成功 0→1 CAS **之后**发送 `efz_cov_observed`，每位恰好一次。
绝不以 `get` + `put` 替代 CAS。
读取及合并需考虑无符号掩码和最后字；`Slot >= N` 或模式之外的位不是探针。

### C. 隔离、快照与重置

guardian **每执行独立拥有映射**，外层 wire 结构保持 `{efz_context,1,Ref,Storage,Owner}`，
`Storage` 变为不透明带标签句柄。
上下文只经既有 `efz_guardian:admit/2` 和 `efz_coverage:attach/1` 传递。
不依赖进程字典继承。保留 PID 注册表及 `efz_cov_rt:hit/1` 检查。
超时后 guardian 关闭接纳，终止全部受控写入者（含后代），等 `DOWN` 和追踪屏障后取快照。
首命中及错误事件也必须排空并与快照核对。

标志或 epoch 可迅速拒绝晚到命中，但 CAS 前检查 `active` **不关闭**检查至写入窗口。
安全来源是独有执行映射、未证明静止前不复用，以及未确认清理时拒绝有效快照与提交。
关闭后晚到命中应产生可诊断基础设施错误；即使竞争允许 CAS 写入**旧**图，也不能进入下一迭代。
未确认清理时不清零或复用旧图，运行器退役，事件不成为成功覆盖。
首实现确认快照后释放映射，下一迭代新分配；这是安全生产重置。
**完整清零**（对所有字 `atomics:put(...,0)`）只为已证明静止图在测试或基准实现和测量；
只有生命周期证明独占所有权才可在生产启用复用。
Dirty-word 跟踪和 epochs 仅在 P8 后考虑。

### D. 全局与反馈

worker 仍是唯一策略所有者。
[`efz_feedback:evaluate/3`](../../../../src/efz_feedback.erl)在位图比较或合并**之前**检查状态和结果。
成功 presence 结果的 `Local & ~Global` 给出供既有 `new_probes`/`retention_reason` 使用的精确新标识，
决策后全局为 `Global | Local`。
首版全局是 worker 状态中的带指纹不可变二进制，新值**每迭代**创建，而非每命中，
只在成功决策后安装。
崩溃、退出、超时和基础设施结果不改全局。
不给后端独立决定语料保留的函数。
`efz_worker:retain/2`、`record_failure/4` 继续生效。
未来多 worker 需串行 compare-and-commit；当前 `workers=1`。

### E. API、元数据与兼容

保留 `efz_cov_rt:hit/1`、`efz_cov:open/0,/1,/2`、`attach/1`、`detach/0`、`snapshot/1`、
`close/1`、manual API、`efz_executor:run/4`、`Result.coverage`（排序精确 ID）、
`efz_feedback:evaluate/3` 和公开活动报告。
给**内部** `efz_coverage:open/3` 增加已验证模式参数，ETS 保留 `open/2`；
新增 `prepare_schema/2`、`snapshot_bits/1`、`new_global/1`、`unseen_bits/2`、`merge_bits/2`、
`decode_new/2`（P1 可调整精确名称，不改语义）。
新 `-opaque bitmap_schema()` / `bitmap_context()` / `bitmap_snapshot()`
隐藏 atomics 句柄及模式指纹，每个边界检查描述符版本。
位图成功结果向 worker 传带指纹的内部不可变 `coverage_bits`，普通 `coverage`
在执行完成时解码供验证及报告。
低层 `run/4` 额外字段不属于持久格式：worker 在写崩溃或运行时产物、故障上下文和活动报告前移除；
崩溃或超时结果不带它。
不要混淆现有 `coverage_observation`（分类映射）。
`unseen_bits/merge_bits` 必须比指纹。
诊断通过反向映射把置位转换为探针 ID 和清单源码位置；原报告及崩溃产物仍得到相同 ID 列表。

`efz_config:prepare/1` 及低层 `open/3` 在目标前拒绝 bitmap + `hit_count`、bitmap + `manual`。
`ets`/`ets_member` 继续支持现有两模式。
后端选择不改插桩清单，不把旧全局覆盖转入新活动。

## 阶段与验收条件

命令从 `efz` 根运行；测试和基准固定 `ERL_FLAGS='+S 4:4'`。
每阶段验证后只提交本阶段文件；回退是移除或禁用新增路径、恢复 `coverage_backend => ets`，不迁移持久覆盖。
下方新文件名是建议；既有模块按真实函数列出。

| 阶段 | 具体工作与 API | 依赖 | 检查、可观察结果、验收 | 回滚 |
| --- | --- | --- | --- | --- |
| **P0 Baseline** | 记录 commit/diff、OTP 和 `erl:system_info`、清单、精确历史和固定种子样例决策。在 `test/efz_backend_tests.erl` 及新 `test/efz_bitmap_contract_tests.erl` 加基线样例和事件记录，不含位图分支。原始基准存 `_build/bitmap-baseline/`，不放历史日志文档。不改 API。 | 无 | `rebar3 compile`；`ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_coverage_layer_tests,efz_backend_tests`；`ERL_FLAGS='+S 4:4' rebar3 ct`；`ERL_FLAGS='+S 4:4' escript bench/run.escript all _build/bitmap-baseline reference`。记录精确 ID、全局和决策、命令及原始样本，不声称加速。 | 仅移除新基线样例及产物，不触及生产代码。 |
| **P1 Backend boundary** | 细化 `src/efz_coverage.erl` 和旧适配器 `src/efz_cov_ets.erl` 分发；保留 `open/2`、`attach/1`、`hit/2`、`snapshot/1`、`close/1`、`unseen/2`、`merge/2` 委派。增加内部类型和 `open/3`，无模式时明确拒绝 `bitmap`。不改 `efz_cov_rt:hit/1`/`efz_cov` 行为。 | P0 | 专项 EUnit 加 `rebar3 xref`；旧上下文形状、事件、错误或状态及语料决策与 P0 字节或结构匹配。 | 恢复当前分发。 |
| **P2 Mapping** | `src/efz_cov_manifest.erl` 保留 `prepare/2`/`validate_prepared/3`；从已验证清单和计划准备新模式。必要时 `src/efz_cov_bitmap.erl` 放不可变映射；`src/efz_config.erl` 容量验证稍后做，最初用内部参数。实现 `FullId→Slot`、反向映射、指纹及溢出、未知、不匹配错误。 | P1 | `ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_bitmap_contract_tests,efz_backend_tests`；双射、跨模块相同本地 ID、BuildId、0/last/overflow。无碰撞。 | 移除映射模块或分支，不改 ETS plan。 |
| **P3 Storage** | `src/efz_cov_bitmap.erl`、`src/efz_coverage.erl`：无符号 atomics 图、有界槽查找、CAS 命中、首命中事件、`snapshot_bits/1`、静止后全清零。内部不透明句柄；`efz_cov_rt:hit/1` 不变。 | P2；下述有界 CAS 试验成功 | 专项 EUnit，同字两写入者同步、槽 0/63/64/last、重复命中、无符号最高位、畸形句柄。全部位及事件精确；不支持 OTP 停止准备。 | 移除位图分发，ETS 不动。 |
| **P4 Lifecycle** | `src/efz_guardian.erl:start/6,admit/2,cleanup/2,finish/2`、`src/efz_executor.erl:coverage/3`、`src/efz_worker.erl:executor_reference_options/1`、`src/efz_cov_integrity.erl`：`coverage_validation=per_execution` 也传模式给 `open/3`，快照前等静止，验证首命中证据，dirty 清理后禁复用，诊断晚到命中。不改 `efz_target` API。 | P3 | `ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_backend_tests,efz_isolation_tests,efz_bitmap_contract_tests`；hit-vs-timeout、子接纳、清理故障、A→B→A 屏障。只有确认结果有稳定快照；dirty 永不提交。 | 禁用位图选择；guardian ETS 分支不变。 |
| **P5 Comparison** | `src/efz_coverage.erl`：位图 `new_global/1`、`unseen_bits/2`、`merge_bits/2`、`global_snapshot/1`、指纹检查；`src/efz_feedback.erl:new/3,evaluate/3`：含模式内部初始化，保留 `new/1,/2`；presence 仅比较及合并成功不可变快照；`src/efz_worker.erl:init/1,execute_checked/4,execute_result/6,record_failure/4`：创建模式和全局，使用内部位，在持久化、报告、故障上下文元数据移除。外部 `Result.coverage`、`new_probes`、retention_reason 不变。 | P4 | 同一合成事件历史经 ETS/bitmap、`efz_feedback_loop_tests`；崩溃或超时后全局不变、校准和变异决策匹配、快照不匹配报错、崩溃或重放文件无内部位载荷。 | presence 返回 ETS 集合路径，不改语料 API。 |
| **P6 Config/integration** | `src/efz_config.erl:valid_field/2,prepare_coverage/1`、`src/efz_worker.erl:init/1,executor_reference_options/1`、`src/efz_guardian.erl:start/6`、`docs/cli.md`：接受 **API** 配置 `bitmap` 和 `coverage_bitmap_bits`，执行前拒绝 manual/hit_count 组合及超容量。活动 CLI 当前无后端标志，无需新增。默认 `ets`。`efz_recipe:execute/5`、`efz_replay_cli` 保留参考 ETS 输入重放，检查相同精确标识。测试驱动和变异器不变。 | P5 | `ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_config_tests,efz_backend_tests,efz_cli_tests,efz_phase3_tests`；`ERL_FLAGS='+S 4:4' rebar3 ct`。API 选位图，ETS CLI 和重放保留旧结果，无效组合稳定报错。 | 恢复配置允许列表 `ets,ets_member`，重放路径不变。 |
| **P7 Differential acceptance** | `test/efz_bitmap_contract_tests.erl`、`test/efz_backend_tests.erl`、`test/efz_coverage_SUITE.erl`、`test/efz_feedback_loop_tests.erl`：存储与反馈使用一条预定事件历史，再在两后端运行同样例与固定种子活动。比较精确覆盖、状态、新颖性、语料 ID 和内容、崩溃及超时证据。 | P6 | `ERL_FLAGS='+S 4:4' rebar3 eunit`；`ERL_FLAGS='+S 4:4' rebar3 ct`；`rebar3 xref`；`rebar3 dialyzer`。零契约差异；不确定真实测试驱动按不变量和重复比较，不逐字符要求 trace 相同。 | 默认切 ETS，关闭实验位图分支。 |
| **P8 Benchmark/rollout** | 扩展 `bench/efz_perf.erl`/`bench/run.escript` 加位图变体及独立 `hit/clear/snapshot/compare/merge/full-cycle` 工作负载；`bench/profile.escript` 做归因。依下述协议测量。只有收益已证明才单独决策研究 dirty words/epochs。更新 `README.md`、`docs/coverage.md` 和架构状态。 | P7 | 原始样本、环境、parser/sparse/dense/repeat/multiwriter；正确性门槛仍必需。性能门槛后单独决定默认，否则位图保持可选。 | 恢复 `coverage_backend => ets` 默认；保留位图可选，或因正确性缺陷移除。 |

各门槛命令（新 `efz_bitmap_contract_tests` 与位图变体在对应阶段出现）：

```sh
# P0
ERL_FLAGS='+S 4:4' rebar3 compile
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_coverage_layer_tests,efz_backend_tests
ERL_FLAGS='+S 4:4' rebar3 ct
ERL_FLAGS='+S 4:4' escript bench/run.escript all _build/bitmap-baseline reference
# P1
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_coverage_layer_tests,efz_backend_tests
ERL_FLAGS='+S 4:4' rebar3 xref
# P2, P3 and spike correctness
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_bitmap_contract_tests,efz_backend_tests
# P4
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_bitmap_contract_tests,efz_backend_tests,efz_isolation_tests,efz_integrity_tests
# P5
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_bitmap_contract_tests,efz_backend_tests,efz_feedback_loop_tests
# P6
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_config_tests,efz_backend_tests,efz_cli_tests,efz_phase3_tests
# P7
ERL_FLAGS='+S 4:4' rebar3 eunit
ERL_FLAGS='+S 4:4' rebar3 ct
ERL_FLAGS='+S 4:4' rebar3 xref
ERL_FLAGS='+S 4:4' rebar3 dialyzer
# P8 (after adding the bitmap variant to bench/run.escript)
ERL_FLAGS='+S 4:4' escript bench/run.escript all _build/bitmap-compare reference
ERL_FLAGS='+S 4:4' escript bench/run.escript all _build/bitmap-compare-bitmap bitmap
```

P8 还需运行单独 reset/snapshot/compare/merge 的新阶段，指定种子和写入者数；
首比较前在基准 README 固定阶段名及参数。
P0 不运行尚不存在的位图测试或变体。

### P3 前的有界技术试验

在 `bench/` 下独立测试文件或脚本比较无符号 `atomics` CAS 循环与串行 ETS/counter 所有者方案，
**仅**检查正确性及同字竞争成本。
检查 0、`2^63`、`2^64−1`、`compare_exchange` 成功和失败、一基边界；
通过屏障启动 1/2/4/8 写入者写相邻位，重复 10 次并核对最终字。
胜者应保留全部位且成本可测；正确性相同时保留更简单 CAS。
受支持 OTP 无符号 CAS 失败则 P3 阻塞，直到选择其他 BEAM 原语；不能改用 `get+put`。
技术试验不改变生产 API。

## 测试矩阵

`B` 为位图，`E` 为 ETS 参考。
存储和反馈测试向两后端输入**相同精确命中标识及迭代完成序列**。
集成固定二进制输入、种子及清单和构建；某些真实测试驱动可不确定，
应按允许结果、覆盖不变量及重复比较，而非要求相同调度顺序。

| 场景 | 方法与预期结果 |
| --- | --- |
| 空覆盖 | 确认附加执行：`[]`、`valid_empty_coverage`、`New=[]`；broken/unstarted 单列，不当作空。E=B。 |
| 重复命中 | 一槽保持 1、一个首命中事件、快照含一个 ID。E=B。 |
| 同字两个不同位 | 两写入者经 CAS 前测试屏障并发读取初始 0；放行后两位均在。含 CAS 重试再测。 |
| 槽 0、63、64、最后 | 检查地址 `(0→word1,bit0)`、`(63→word1,bit63)`、`(64→word2,bit0)`、`(capacity−1→last)`；无符号最高位不变负。 |
| 容量溢出 | `N=capacity+1` 准备时以 required/configured 拒绝；槽 `capacity` 命中拒绝而非回绕。 |
| 相同本地 ID | `{M1,B1,1}` 和 `{M2,B2,1}` 获得不同槽；同模块其他 BuildId 不合并。 |
| 模式或构建不匹配 | 替换 BuildId、fingerprint、plan 或加载代码：合并前报错；不使用其他构建保存位图。 |
| 无新颖性；一个或多个新位 | 历史 `[A]→[A]→[A,B]→[B,C,D]`；新列表 `A, [], B, C/D`；E/B 决策和 ID 顺序相同。 |
| 全局累计 | 成功 `A`、`B` 后 global=`{A,B}`；重复不改；校准更新全局而不重复加语料。 |
| A→B→A | 三执行独立映射；第三 local=`{A}`，global=`{A,B}`。仅静止后清零旧图，不清全局。 |
| 崩溃或超时 | 屏障保证此前命中；结果含 ID，成功全局或语料不变，崩溃产物和计数保持旧行为。 |
| 晚到命中和清理失败 | active 检查后延迟写入者，开始超时或关闭，再放行。不能写下迭代 B 图；A 未证明终止则无有效快照，运行器 dirty。用屏障检查顺序，不只 stress。 |
| 并发同字命中 | N 受控子获得同上下文，首 CAS 前屏障，并发设置相邻或同位；最终 popcount 精确、首命中证据完整。另做 10⁴ 周期 stress。 |
| 后端切换 | 独立 ETS→B→ETS 活动，相同模式和输入产生同决策；默认不转移全局。 |
| 语料决策 | 固定种子集成和重放候选流中，`retention_reason`、`new_probes`、添加或去重、崩溃及超时分类 E/B 相同。位图 `hit_count` 配置报错，不运行目标。 |

## 基准协议与性能门槛

1. 先 P0：`ERL_FLAGS='+S 4:4' rebar3 compile`，再
   `ERL_FLAGS='+S 4:4' escript bench/run.escript all _build/bitmap-baseline reference`
   和 `ERL_FLAGS='+S 4:4' escript scripts/coverage_bench.escript`。
   后者是历史钩子微基准，不是完整活动成本。
   保存原始 `.term`、源码和样例 SHA-256、`git rev-parse HEAD`、`git diff --stat`、
   OTP/ERTS、`system_architecture`、wordsize、`schedulers_online`、JIT/flags 和硬件。
   环境不相同，不与旧发布数字比较。
2. P7 后使用相同清单及固定种子事件流：稀疏或稠密集合、1/8/64/1024+ 不同探针、
   不同每执行命中数、90%+ 重复命中、1/2/4/8 受控写入者，有竞争及无竞争。
   映射准备与稳态分开测；内存包括 atomics、ETS 映射、反向映射、上下文、清单和计划、
   全局状态及进程堆。
3. 分别测 `hit`（首次和重复）、完整清零或重置、静止与快照、解码、比较、合并、
   完整 `reset→execute→collect→compare→commit`，及 parser/loop/sparse 和真实测试驱动端到端变异 exec/s。
   校准、启动、稳定变异时间分开。
   通过语料和结果检查进行归一化，不静默把错误或超时排除分母。
4. 相同调度器设置、预热、至少 10 次交替 E/B 顺序配对，必要时独立 VM 清理状态。
   发布全部样本、中位数、最小最大、配对比及 bootstrap 95% 区间，
   reductions、GC 次数、分配及进程内存，可用时的 `atomics:info(memory)` 和 ETS 内存。
   `bench/profile.escript` 用于解释成本，不作吞吐结果。
   邻近进程和温度漂移记录为限制。
5. **正确性门槛：**P7 全测试和矩阵通过，零丢位、零混模式、零语料决策改变。
   **可选性能门槛：**每个预选代表工作负载的端到端 exec/s 中位数无持续超过 5% 退化；
   否则保持实验并分析。
   **默认切换门槛：**除正确性，预选主工作负载 bitmap/ETS exec/s 配对 95% 区间下界大于 1.0，
   每个其他代表负载至少 0.95；完整内存占用及 p95 延迟已发布，并不超事前写明活动限制。
   这些是决策规则，不是预期结果。
   测量不稳定则默认 ETS。任何正确性回归立即恢复 ETS。
6. 初始重置是静止后全字清零。
   若时间分解证明 clear 显著影响全周期，再把 dirty words/epochs 放入新可选实验；
   修改后重跑并发和生命周期矩阵及基准。

## 完成定义与推广

实际阶段状态：P0 **部分完成**（226 基线 EUnit 和 3 CT 通过，
历史 `bench/run.escript all` 超过三分钟无结果后中断）；
P1–P7 **已实现**并通过串行检查；
P8 **部分完成**（用独立 `bench/bitmap_bench.escript` 完成配对微基准和活动基准，
解析器性能门槛未达成，默认未改）。
使用独立基准驱动而非 `bench/run.escript` 位图变体，是有意的窄范围偏离；
旧驱动基准仍需运行以比较历史工作负载。参见[报告](../coverage-bitmap-implementation-report.md)。

- [x] 精确插桩标识和源码映射不变；位图只用于 automatic/presence。
- [x] 单射映射、版本指纹和容量错误已检查；不混不兼容构建。
- [x] bit63、字边界和受控并发写入者 CAS 已测试；检查场景保留首命中完整性。
- [x] 只在确认静止后快照；受控后代晚到命中或 dirty 清理不产生有效提交及复用。
- [x] 实现矩阵中 `Result.coverage`、反馈、全局、语料、崩溃和超时决策与 ETS 相同。
- [x] 受支持 OTP 上 `rebar3 compile`、完整 `rebar3 eunit`、`rebar3 ct`、`rebar3 xref`、`rebar3 dialyzer` 通过。
- [ ] 完整 P8 协议：已发布原始样本，但历史基线、生产测试驱动、完整 RSS/p95、置信区间仍待完成。
- [x] 独立性能门槛决策前 ETS 保持默认；单配置选择器回滚，不迁移保存覆盖。

建议推广顺序：内部低层测试 → 自动 presence 活动可选 `coverage_backend => bitmap`
→ 两后端差分 CI → 真实测试驱动测量 → 单独默认决策。
遇差异立即恢复 `ets`，保存失败事件历史及映射和模式元数据以复现。
语料输入可重新校准后复用；保存覆盖位仅可在指纹完全匹配时使用，否则不导入。

## 实现代理的首要任务

1. **P0：**在 `test/efz_backend_tests.erl` 或新契约测试记录可复现事件历史及 ETS 基线，
   保存原始基准和环境，不改生产路径。
2. **P1：**建立内部 `efz_coverage` 分发和类型契约，保持 ETS 行为并运行专项 EUnit。
3. **P2：**实现模式映射、指纹和容量错误，以及双射与边界测试；暂不接命中路径。
4. **Spike/P3：**在 OTP 27 检查无符号 CAS，实现带受控并发测试的原子置位，再集成执行图。

每任务有独立可验证结果；上一门槛通过后才开始下一任务。
