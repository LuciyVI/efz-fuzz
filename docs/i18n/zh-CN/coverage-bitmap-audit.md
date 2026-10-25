# EFZ 位图覆盖后端技术审计

[English](../../coverage-bitmap-audit.md) · [Русский](../ru/coverage-bitmap-audit.md) · [Español](../es/coverage-bitmap-audit.md) · **简体中文** · [所有语言](../README.md)

这是原始 bitmap-v1 审计。修复和新测量见 [bitmap-v2 报告](coverage-bitmap-v2-results.md)；
下方原始结果保留。

日期：2026-10-02。范围：`8b5cb05b5b57231b9133be13c883f25863e05d11` 当前工作副本及既有未提交修改。
未修复后端代码。已阅读[架构](coverage-bitmap-architecture.md)、
[计划](plans/coverage-bitmap-implementation-plan.md)、[实现报告](coverage-bitmap-implementation-report.md)、
源码及测试。新增测试和独立审计基准见下文。

## 1. 结论

受支持 `automatic` + `presence` 模式中，位图无损表示与 ETS **相同结构点**：
键为完整 `{Module,BuildId,ProbeId}`，槽位唯一，相同事件历史和固定种子活动中 ETS 与位图结果匹配。
多个已接纳进程并发时，CAS 循环保留同一字中的不同位。
生产为每个执行分配新映射；晚到写入者不能写入下一映射。
这些证据属于 EFZ *受控后代*模型，不保证任意远程或外部进程隔离。

**未确认加速。**真实示例解析器活动的重复配对运行中，位图 exec/s 更低：
bitmap/ETS 比中位数 `0.893`，bootstrap 95% 区间 `[0.851,0.949]`。
稀疏完整存储及反馈周期尤其昂贵。
不得改变默认 `ets`；`bitmap` 只适合作为分析与差分测试的实验性可选模式。
已检查路径未发现正确性 P0 阻塞；尚未进行位图专有 dirty-cleanup 故障注入。

## 2. 实际架构与测试案例路径

| 步骤 | 函数与数据 | 状态、所有者及并发 |
| --- | --- | --- |
| 活动准备 | [`efz_config:prepare_coverage/1`](../../../src/efz_config.erl#L85)预检清单及容量；[`efz_worker:init/1`](../../../src/efz_worker.erl#L7)调用 `efz_coverage:prepare_schema/2`，创建反馈和全局状态。 | worker 拥有受保护 ETS `FullId→Slot`、反向元组及不可变全局二进制。仅一个 worker（`workers=1`），提交串行。 |
| 输入与迭代 | [`efz_worker:execute_checked/4`](../../../src/efz_worker.erl#L93)向 [`efz_executor:run/4`](../../../src/efz_executor.erl#L11)传入二进制输入、后端和模式、固定计划。 | worker 可变状态、语料与变异选择；后端不选择输入。 |
| 执行上下文 | [`efz_guardian:start/6`](../../../src/efz_guardian.erl#L33)经 `efz_coverage:open/3` 打开 `{efz_context,1,Ref,{bitmap,Schema,Words,Active},Owner}`。 | guardian 每执行拥有独立无符号 atomics 数组和活动标志。 |
| 进程附加 | [`efz_guardian:admit/2`](../../../src/efz_guardian.erl#L53)和 [`efz_target:spawn_owned/2`](../../../src/efz_target.erl#L9)经门控启动根和子进程；[`efz_cov_bitmap:attach/1`](../../../src/efz_cov_bitmap.erl#L84)显式保存上下文到进程字典。 | 多个受控写入者共享映射。普通 `spawn` 不继承上下文；追踪检测后将运行器标为 dirty。 |
| 插桩目标与命中 | [`efz_instrument_pt:body/5`、`probe/4`](../../../src/efz_instrument_pt.erl#L112)插入 `efz_cov_rt:hit({M,B,Id})`；[`efz_cov_rt:hit/1`](../../../src/efz_cov_rt.erl#L6)检查 PID 与上下文，将完整键交给 `efz_coverage:hit/2` → `efz_cov_bitmap:hit/2`。 | 热路径通过 CAS 修改一个 64 位字；首次命中发送 guardian 事件。允许并发写入者。 |
| 完成 | [`efz_guardian:cleanup/2`、`loop/1`](../../../src/efz_guardian.erl#L72)关闭接纳，杀死剩余受控写入者，等待 `DOWN` 及追踪屏障；到期产生 unconfirmed/dirty。 | 单一根 `DOWN` 不足；稳定性依靠全部注册进程终止及追踪排空。 |
| 观察 | [`efz_guardian:finish/2`](../../../src/efz_guardian.erl#L172)调用 [`efz_executor:coverage/3`](../../../src/efz_executor.erl#L123)获取精确 ID 列表并验证；确认成功结果另取不可变 `snapshot_bits/1`，再关闭映射。 | 只有静止后才允许两次快照。公开 `Result.coverage` 仍为列表；`coverage_bits` 是内部结果字段。 |
| 新颖性与全局 | [`efz_feedback:evaluate/3`、`bitmap_success/5`](../../../src/efz_feedback.erl#L21)检查状态和结果，计算 `Local & ~Global`、解码新 ID、构建 `Global | Local`。 | 全局是 worker 内不可变 8 KiB 二进制；比较及提交顺序执行。崩溃或超时不合并。 |
| 语料与故障 | [`efz_worker:execute_result/6`、`retain/2`、`record_failure/4`](../../../src/efz_worker.erl#L101)使用既有 `retention_reason`；成功新覆盖经 `efz_corpus:add/2` 加入输入，故障单独保存。 | 同 ETS，反馈在写语料**之前**更新全局。写错误停止活动；这是既有顺序，不是位图新行为。 |
| 重置与释放 | 下一 `efz_guardian:start/6` 创建新映射；[`efz_cov_bitmap:close/1`、`reset/1`](../../../src/efz_cov_bitmap.erl#L151)不清零全局。[`efz_worker:terminate/2`](../../../src/efz_worker.erl#L345)删除模式 ETS。 | 生产不复用旧可变映射。上下文引用消失后，atomics 由 GC 回收。 |

旧版经过相同执行器、guardian、反馈和 worker 策略阶段。
差别是 [`efz_cov_ets:open/2`、`hit/2`、`snapshot/1`](../../../src/efz_cov_ets.erl#L7)
使用全新公开 ETS 表及 `insert_new`；
[`efz_coverage:unseen/2`、`merge/2`](../../../src/efz_coverage.erl#L40)使用精确 Erlang 集合或列表。
位图改变存储和比较，保留公开标识与 worker 决策。

## 3. 标识、槽位与插桩

[`efz_instrument_pt:parse_transform/2`、`probe/4`](../../../src/efz_instrument_pt.erl#L7)
从 1 开始分配本地 `ProbeId`，插入带 `{Module,BuildId,ProbeId}` 的调用；
BuildId 依赖规范 forms、OTP/编译器及标识选项（37–55 行）。
[`efz_cov_manifest:identities/1`、`validate/1`](../../../src/efz_cov_manifest.erl#L4)
保留完整标识，拒绝非正或重复本地 ID。
function/case/if/receive/try/fun 布置见 [`body/5`、`expr/3`](../../../src/efz_instrument_pt.erl#L107)，
由 [`efz_phase2_tests:manifest/1`](../../../test/efz_phase2_tests.erl#L70)检查；位图未改变此遍历。
[`efz_phase2_tests:determinism/1`](../../../test/efz_phase2_tests.erl#L195)检查等价构建 BuildId 相同、宏改变时不同。

[`efz_cov_bitmap:validate_manifests/1`、`prepare/2`](../../../src/efz_cov_bitmap.erl#L23)
验证清单，拒绝重复所选模块和 ID，对*完整*标识排序，分配连续槽 `0..N−1`。
受保护 ETS 存 `FullId→Slot`，元组存 `Slot→FullId`。
没有 `ProbeId rem MapSize`、哈希掩码或截断。
不同模块相同本地 ID 得到不同槽位。
同一活动**不允许同时使用**同模块两个构建；指纹含完整 ID 序列和容量。
相同规范构建产生相同槽位；新 BuildId 或模式要求新活动并拒绝旧位图快照
（`unseen_bits/2`、`merge_bits/2`，177–191 行）。
语料**输入字节**可在重建后重跑并重新校准；旧覆盖位不会自动导入。

容量：`N > Bits` 在活动前返回 `{bitmap_capacity_exceeded,#{required_bits,configured_bits}}`
（[`check_capacity/2`](../../../src/efz_cov_bitmap.erl#L14)、
[`efz_config:prepare_coverage/1`](../../../src/efz_config.erl#L90)）。
合法模式不能出现槽 `MapSize`；未知 ID、负或巨大 ID、外来 BuildId
在 [`hit/2`](../../../src/efz_cov_bitmap.erl#L93)明确报 `unexpected_probe_or_build`。
损坏清单被拒绝。专项测试：
[`mapping_and_capacity_test/0`、`boundary_test/0`、`default_last_slot_test_/0`](../../../test/efz_bitmap_contract_tests.erl#L4)、
[`invalid_identity_test/0`](../../../test/efz_bitmap_audit_tests.erl#L7)、
[`wide_differential/0`](../../../test/efz_bitmap_audit_tests.erl#L39)。

## 4. 表示、热路径与并发

默认 `coverage_bitmap_bits=65536`：65,536 **位**、8,192 有效载荷字节、1,024 个 64 位字。
[`efz_cov_bitmap:open/1`](../../../src/efz_cov_bitmap.erl#L74)分配
`atomics:new(Bits div 64,[{signed,false}])` 及单独活动标志。
槽 `s` 地址为 `Word=s div 64+1`（atomics 从 1 索引）、`Mask=1 bsl (s rem 64)`。
槽 `0,1,63,64,65,65535` 对应 `word/bit` 为 `1/0,1/1,1/63,2/0,2/1,1024/63`。
槽 `65536` 未分配。最高位为无符号；[`cas_word/4`](../../../src/efz_cov_bitmap.erl#L119)
在过时读取后重试 CAS，保留相邻位。
确定性 [`cas_stale_read_test/0`](../../../test/efz_bitmap_contract_tests.erl#L95)
延迟读取相同 `Old=0` 后的多个写入者，再检查位 0、1、63；
[`shared_writers_and_late_context_test/0`](../../../test/efz_bitmap_contract_tests.erl#L107)检查共享上下文。
没有简单不安全 `get→OR→put`。

一次探针命中：[`efz_cov_rt:hit/1`](../../../src/efz_cov_rt.erl#L6)
通过 [`efz_cov_integrity:expected/0`](../../../src/efz_cov_integrity.erl#L70)查询 PID 注册表成员资格，
检查进程字典，再由 [`efz_coverage:hit/2`](../../../src/efz_coverage.erl#L20)
调用 [`efz_cov_bitmap:hit/2`](../../../src/efz_cov_bitmap.erl#L93)。
后者读活动标志两次，精确 ETS 查找，计算字及掩码，调用 CAS 循环；首次 0→1 通知 guardian。
不读配置，每次命中不创建位图 binary/list/set/map，不做诊断或源码解码。
但完整性注册表和槽表中的 `ets:lookup` 返回 Erlang term；**热路径并非零分配**。
重复命中基准比 `ets:insert_new` 耗时更高。

生产快照仅在 [`efz_guardian:loop/1`](../../../src/efz_guardian.erl#L72)
的 alive/barriers 为空且协调器停止，再经 [`finish/2`](../../../src/efz_guardian.erl#L172)后稳定。
`snapshot_bits/1` 自身逐字读取，写入者仍存活时不是原子快照
（[`efz_cov_bitmap:snapshot_bits/1`](../../../src/efz_cov_bitmap.erl#L139)）。
`Active=0` 也不能关闭检查至 CAS 竞争。
生产通过新映射避免写入下一迭代；dirty 清理令运行器不可复用。
[`efz_isolation_tests`](../../../test/efz_isolation_tests.erl#L17)检查受控后代与超时，
[`shared_writers_and_late_context_test/0`](../../../test/efz_bitmap_contract_tests.erl#L107)
检查 close/reset 后向旧上下文的晚到命中。
新旧邮箱消息都带 `Ref`；guardian 只接受自己的 `Ref`
（[`loop_event/2`](../../../src/efz_guardian.erl#L138)）；完成后所有者不把消息转给其他映射。

`reset/1` 分配全新数组，没有 dirty-word 列表或 epoch。
完整清零 [`clear_quiescent/1`](../../../src/efz_cov_bitmap.erl#L163)只用于基准。
其 `Active=0` 检查**不能证明**写入者未通过此前检查并等待 CAS：
[`closed_clear_stale_cas_test/0`](../../../test/efz_bitmap_audit_tests.erl#L28)复现清零后写入。
这不是生产泄漏，因为生产不复用数组。
名称和 API 需显式 join 前置条件，或从可访问接口移除。

## 5. 新颖性、全局与模糊测试反馈

[`efz_cov_bitmap:wordwise/4`](../../../src/efz_cov_bitmap.erl#L193)按 64 位字计算
`Local band bnot Global` 和 `Local bor Global`，不转成集合。
[`efz_feedback:bitmap_success/5`](../../../src/efz_feedback.erl#L42)
为 `new_probes` 和 `retention_reason` 解码**新**位，再得到新全局。
比较不修改旧全局。没有首个新字就*提前退出*：总构建完整差异二进制；当前 API 要全部精确新探针列表。
即便无新颖性，也完整扫描、新建二进制并遍历全部清单 ID 解码。
这是下文可测固定成本。

历史 `{} → {1,2} → {1,2} → {1,2,3} → {3} → {64,65} → {65}`
应给 `new, none, new, none, new, none`；实际按位操作正是此结果。
[`wide_differential/0`](../../../test/efz_bitmap_audit_tests.erl#L39)按同规则比较另一预设历史，
含空结果、63/64/65/65535、重复命中、双模块、崩溃和超时。
[`efz_feedback:evaluate/3`](../../../src/efz_feedback.erl#L13)
仅 `coverage_status=ok` 且 `{ok,_}` 才允许合并；crash/exit/timeout 给 `target_failure`，全局不变。
成功种子校准更新全局，不重复加语料。
[`efz_worker:retain/2`](../../../src/efz_worker.erl#L245)在反馈后决定保留，
[`record_failure/4`](../../../src/efz_worker.erl#L256)单独分类和保存故障。
ETS 分支同样边界（`efz_feedback:evaluate/3`，30–39 行）。
外部 `Result.coverage` 仍是精确 ID 列表；
[`public_result/1`](../../../src/efz_worker.erl#L352)从报告及故障上下文移除 `coverage_bits`。

## 6. 检查与基准

命令**串行**运行，避免 Rebar3 同时编译同一 `_build`：

| 命令 | 结果 |
| --- | --- |
| `ERL_FLAGS='+S 4:4' rebar3 eunit` | PASS，加入审计测试后 **241** 项（日志 `_build/bitmap-audit-eunit-final.log`） |
| `ERL_FLAGS='+S 4:4' rebar3 ct` | PASS，3 项 |
| `ERL_FLAGS='+S 4:4' rebar3 xref` | PASS |
| `ERL_FLAGS='+S 4:4' rebar3 dialyzer` | PASS |
| `ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_bitmap_audit_tests` | PASS，3 项审计测试 |
| `ERL_FLAGS='+S 4:4' escript bench/bitmap_bench.escript _build/bitmap-audit-benchmark` | PASS；[原始样本](../../performance/bitmap-audit-2026-10-02-existing-bench.txt) |
| `ERL_FLAGS='+S 4:4' escript bench/bitmap_audit_bench.escript docs/performance/bitmap-audit-2026-10-02-samples.term` | PASS；[原始样本](../../performance/bitmap-audit-2026-10-02-samples.term) |

OTP 27.0 / ERTS 15.0，Linux x86_64，i7-1260P，`+S 4:4`，Rebar3 3.25.0。
两个基准均预热 2 对，之后 10 次配对交替 ETS/bitmap 顺序。
合成清单 1,024 探针、容量 65,536 位；解析器活动为固定种子 `efz_example_target`、
50 次执行，各样本语料 4、覆盖 5。
下方是微秒中位数，原始产物含最小和最大值。
内置基准及配对审计脚本都单独收集 reductions 和 minor GC。
脚本 SHA-256：`bench/bitmap_bench.escript` 为
`975240e42d32a96228d7c177f33053492904c2c9a3aaca1a71d766168e95266b`，
`bench/bitmap_audit_bench.escript` 为
`fdde7eea1345717f69e41863458b5f68f9970c06e41a35db19fb0c3511def29e`。
测量仅一台机器，不能证明其他测试驱动或 OTP 版本结果。

| 既有基准阶段 | ETS | Bitmap |
| --- | ---: | ---: |
| 5,000 次重复命中 | 824 | 1 413 |
| 64 次稀疏命中 | 18 | 23 |
| 1,024 次不同命中 | 629 | 768 |
| 快照 64 / 1,024 | 13 / 293 | 39 / 38 |
| 解码 1,024 个 ID | 312 | 88 |
| 比较 / 合并 256 | 84 / 58 | 30 / 28 |
| 关闭后完整清零 | 0* | 19 |
| 10 次稀疏完整周期 | 135 | 7 451 |
| 5 次稠密完整周期 | 34 379 | 13 013 |
| 同一字内 1 / 2 / 4 / 8 写入者 | 4 367 / 8 345 / 12 169 / 26 675 | 4 377 / 8 656 / 11 904 / 32 422 |
| 解析器活动，50 次执行墙钟时间 | 116 842 | 125 835 |

`*` ETS 阶段是创建新表，不是清零；0 µs 低于有效计时分辨率。
50 次执行墙钟中位数约对应 **428 exec/s ETS**、**397 exec/s bitmap**。
配对 exec/s 比中位数 `0.893`；bootstrap 百分位 95% `[0.851,0.949]`，
10,000 重采样、种子 `20261002`。
这是示例解析器测量，不是生产测试驱动。
独立审计脚本完整周期包含全新上下文、命中、精确公开观察、位图快照、新颖性与合并：

| 每执行命中数 | ETS 中位数（最小–最大），µs | Bitmap 中位数（最小–最大），µs |
| --- | ---: | ---: |
| 1 | 4 (3–4) | 402 (347–452) |
| 100 | 97 (92–227) | 400 (286–546) |
| 1 000 | 3 054 (2 115–3 948) | 1 546 (725–2 125) |
| 10 000，在 1 024 个 ID 上循环 | 8 509 (6 471–9 730) | 7 374 (6 338–9 449) |
| 同一 ID 命中 10 000 次 | 6 045 (4 951–6 885) | 7 796 (7 309–8 219) |

审计周期刻意排除真实 guardian 进程清理、变异和语料 I/O；解析器活动包含它们。
稀疏覆盖时，开映射、两次快照和解码、全映射及清单遍历的固定成本主导，`hit/1` 不是唯一瓶颈。
大量重复命中时，命中路径成本明显：5,000 次命中微基准位图比 ETS 慢 1.7×。
稠密唯一工作负载中，位图凭便宜的逐字比较合并更好。
成本依密度而变；在解决固定执行成本和测量生产测试驱动前，这些数据不足以支持 OTP-native/JIT 覆盖研究。

1,024 探针时 `efz_cov_bitmap:memory/1` 实际组件：
atomics 字 **8,232 B**，active **48 B**，映射 ETS **20,084 VM 字**
（此 VM 每字 8 B，约160,672 B），反向元组 `external_size` **58,633 B**。
全局二进制和一个不可变快照各 **8,192 B**；另加清单、计划、上下文及分配器。
1,024 次命中后 ETS 执行表 **22,071 VM 字**。
`external_size` 不是 RSS，不能直接把组件之和当活动总内存。
多次活动后的 RSS 和内存保留在此**未测试**。

## 7. 发现的问题与评估

| 类别 | 状态 | 证据与限制 |
| --- | --- | --- |
| 正确性 | **PASS** | 无碰撞映射、边界、最高位及不同构建有代码与测试验证；检查范围内无静默覆盖丢失。 |
| 并发安全 | **PARTIAL** | **Medium：**生产 CAS 保留相邻位，但导出 [`clear_quiescent/1`](../../../src/efz_cov_bitmap.erl#L163)只检查 `Active=0`；审计测试复现关闭及清零后过期写入。无 join 不得复用该 helper。 |
| 执行隔离 | **PARTIAL** | **Medium：**已检查新映射、Ref 和受控后代超时，但未在新 VM 运行位图专有未确认清理或 guardian 死亡。[`efz_guardian:finish/2`](../../../src/efz_guardian.erl#L172)与 ETS 共用生命周期，但仍需位图版 [`efz_isolation_tests:fresh_vm/2`](../../../test/efz_isolation_tests.erl#L27)，强制清理截止时间或 guardian kill，并验证无提交和复用。 |
| 语义兼容 | **PASS** | 测试中相同事件历史和种子活动给出相同 observed/new/global/corpus/crash/timeout 决策。 |
| 性能 | **FAIL** | **High：**解析器 exec/s 比 `0.893`；1 命中完整周期 `402` 对 `4` µs。来源：[`efz_guardian:finish/2`](../../../src/efz_guardian.erl#L172)精确解码和第二次位图快照；[`efz_cov_bitmap:wordwise/4`、`decode/2`](../../../src/efz_cov_bitmap.erl#L193)扫描全映射和模式；[`efz_feedback:bitmap_success/5`](../../../src/efz_feedback.erl#L42)无新颖性仍如此。成为默认前分析并简化固定工作。 |
| 内存效率 | **PARTIAL** | **Medium：**有效载荷 8 KiB，但仅1,024探针的映射 ETS 约160 KiB VM字、反向 external size 约58 KiB；[`prepare/2`、`memory/1`](../../../src/efz_cov_bitmap.erl#L23)。未测完整 RSS 与保留。推广前测重复活动峰值和 RSS。 |
| 可维护性 | **PARTIAL** | **Medium：**[`snapshot_bits/1`](../../../src/efz_cov_bitmap.erl#L139)可在写入者存活时调用；自身 `Active=1` 保护不使结果稳定。生产 guardian 满足条件，但 API 应显式要求静止，或仅生命周期所有者可取快照。 |
| 可观测与调试 | **PARTIAL** | **Low：**[`efz_worker:finish/2`](../../../src/efz_worker.erl#L306)发布精确 ID，但无映射与打开、快照与解码、比较与合并的分阶段时间和完整 RSS。优化前复现解析器基准并增加成本计数。 |

额外健壮性缺口（**medium**）：[`efz_config:valid_field/2`](../../../src/efz_config.erl#L69)
接受任意大正 `coverage_bitmap_bits`，而
[`efz_cov_bitmap:check_capacity/2`](../../../src/efz_cov_bitmap.erl#L14)只检查探针数 `<= Bits`。
例如 `1 bsl 60` 可通过，但
[`efz_cov_bitmap:new_global/1`、`open/1`](../../../src/efz_cov_bitmap.erl#L74)
会在 worker 或执行启动时尝试分配巨型 binary/atomics。
这是显式资源故障，不是静默碰撞；应限制支持最大值，或活动前试分配并释放资源，给出明确错误。

## 8. 改进优先级

**P0 正确性阻塞：**已检查 automatic/presence 场景未发现。
扩大可选使用前需位图专有未确认清理故障注入。
事件历史分歧或 dirty 清理未产生基础设施结果时，立即回滚 `coverage_backend => ets`。

**P1 性能与架构：**(1) 给 [`efz_guardian:finish/2`](../../../src/efz_guardian.erl#L172)
和 [`efz_feedback:bitmap_success/5`](../../../src/efz_feedback.erl#L42)加阶段计时，分析稀疏解析器和生产测试驱动；
(2) 若固定扫描确认，在一次稳定遍历得到精确 ID 列表与字节，
证明无新颖性时避免完整 `NewBits` 解码，保留 `new_probes` 和提交顺序；
(3) 再单独评估重复命中的两次 ETS 查找、活动检查及 CAS。
测量及新并发门槛前不添加 dirty words 或 epochs。

**P2 健壮性与可观测：**(1) 明确契约或删除仅基准用 `clear_quiescent/1`；
(2) 在 API 中明确稳定快照边界；(3) 分配前检查容量上界并处理分配错误；
(4) 执行位图专有 dirty 清理故障注入；
(5) 发布重复活动的峰值 RSS、活动映射和模式 ETS 数。
这些任务不改变插桩或测试驱动 API。

## 9. 主要问题解答

- **旧 EFZ 语义保留吗？**在已测 automatic/presence 模式内是，包括仅成功全局合并及语料与故障策略。
- **有静默覆盖丢失吗？**未发现：完整标识精确查找，溢出或未知 BuildId 报错，CAS 保留相邻位。
- **多进程安全吗？**受控后代及生产新映射生命周期内安全；仅 `clear_quiescent/1` 不足以复用。
- **迭代隔离吗？**检查的受控超时场景内是：A、B 有不同 atomics 数组，A 晚到命中无法进入 B。
  位图专有未确认清理故障注入仍待执行。
- **位图更快吗？**实测解析器活动及稀疏周期不是；稠密唯一阶段有时获益。
- **新瓶颈是什么？**稀疏输入是每执行固定快照、解码和全映射工作；
  极频繁重复命中还包括 Erlang `hit/1` 自身检查和 ETS 查找。尚无所有测试驱动通用瓶颈。
- **能设为默认吗？**不能。继续实验性可选；ETS 保持默认、参考、回滚路径。
