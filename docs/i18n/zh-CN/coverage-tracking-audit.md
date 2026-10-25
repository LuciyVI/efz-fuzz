# EFZ 覆盖跟踪：审计及与 AFL++ 的比较

[English](../../coverage-tracking-audit.md) · [Русский](../ru/coverage-tracking-audit.md) · [Español](../es/coverage-tracking-audit.md) · **简体中文** · [所有语言](../README.md)

日期：2026 年 9 月 15 日。审查生产快照：
[`205e18ba172d74bd6c652a68abfc73e02e4a1f86`](https://github.com/LuciyVI/efz-fuzz/commit/205e18ba172d74bd6c652a68abfc73e02e4a1f86)。
实验环境：OTP 27 / ERTS 15.0、Linux x86_64、`+S 4:4`。
未修改生产实现。新诊断目标与运行器位于
[coverage-audit-2026-09-15](../../coverage-audit-2026-09-15)。

本文描述该快照及默认 presence 语义。
后续可选计数器原型及独立测量见 [hit-count 实验](hit-count-experiment.md)；
下方历史结果不描述新模式。

## 1. 执行结论

**RESULT B——实现了类似 AFL++ 的反馈语义，但表示不同。**

两个不同问题的答案：

* **是否有覆盖反馈？有。**自动钩子记录具体执行覆盖；worker 与累计覆盖比较，
  将成功发现加入真正语料，供后续调度。
* **是否有 AFL++ 式位图或命中计数映射？没有。**无字节索引 trace bitmap、
  命中计数器、桶、`virgin_bits`、前一条边或调用上下文哈希。

当前结构正确名称是**执行覆盖集合 / 精确探针集合**。
若明确说明集合语义，也可称“稀疏探针 presence 映射”。
称为位图或边命中计数映射不正确。

EFZ 表示在反馈敏感性上不同于 AFL++：**检测新探针，不检测旧探针的新次数或旧探针新组合**。
标识指源码子句或结果点，不是 CFG 边。

证据：[钩子](../../../src/efz_cov_rt.erl#L43)、[快照](../../../src/efz_cov.erl#L31)、
[新颖性](../../../src/efz_feedback.erl#L16)、[保留](../../../src/efz_worker.erl#L122)、
[调度器](../../../src/efz_mutation_plan.erl#L54)、第 13 节独立运行时实验，
以及真实[父输入复用集成测试](../../../test/efz_feedback_loop_tests.erl)。

## 2. AFL++ 参考模型

参考固定于 AFL++ `stable` 提交
[`dbaf11913c1b2702dee5b4d3dcfffd52f1defe50`](https://github.com/AFLplusplus/AFLplusplus/commit/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50)，
提交日期 2026-09-02。
此处未构建或运行 AFL++；比较依据官方源码。
模型为普通覆盖引导模式；额外 value-profile/CmpLog/path/sanitizer 通道及 crash-only 模式不替代它。

```text
target execution
  → compiler/runtime instrumentation
  → edge/guard mapped to a numeric slot
  → byte hit counter in shared trace_bits
  → count classification
  → compare with virgin bits and clear newly observed feature bits
  → save_if_interesting / add_to_queue
  → clear current trace before next run
```

| 概念 | 参考模型中的含义 |
|---|---|
| 边覆盖 | 控制流转移信息；插桩布置取决于编译器和后端，不只是源码行集合。 |
| 位图槽位 | trace 缓冲中的数字位置；不一定对应唯一边。 |
| 命中计数器 | 通常为每次命中更新的字节，不是无界精确调用次数。 |
| 计数桶 | 计数值类别；已知槽位的新桶可能产生新颖性。 |
| 每执行 trace | `fsrv.trace_bits`，共享内存中的当前目标观察。 |
| Virgin 映射 | 尚未观察的桶特征位；累计逻辑上以反向形式保存。 |
| 新颖性 | 已分类当前位与 virgin 位交集；区分新槽位和旧槽位新桶。 |
| 重置 | 运行间清除当前 trace，保留 virgin 状态。 |
| 碰撞 | 哈希插桩中多个边可共用槽并混合计数；LTO 和 PCGUARD 可使用不重叠 ID。 |
| 上下文 | 普通边标识不含调用链；额外插桩模式可计入 caller/context，属独立设置。 |

历史 AFL 使用 `cur_location XOR prev_location` 索引，并根据当前点更新 `prev_location`。
这**不普遍描述全部现代 AFL++ 后端**。
PCGUARD 参考运行时更新 `__afl_area_ptr[*guard]`；
LTO 文档说明唯一 ID 及多插桩库时范围要求。
[历史模型](https://aflplus.plus/docs/technical_details/)、
[PCGUARD 运行时](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/instrumentation/afl-compiler-rt.o.c#L2692)、
[LTO](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/instrumentation/README.lto.md)。

**版本细节：**所选修订活跃 `count_class_lookup8` 使用下列类别；
为 3 单列类别的传统表仍以 `OLD` 注释保留在源码中：

| 原始字节计数 | 分类位 |
|---|---:|
| 0 | 0 |
| 1 | 1 |
| 2–3 | 2 |
| 4–7 | 4 |
| 8–15 | 8 |
| 16–31 | 16 |
| 32–63 | 32 |
| 64–127 | 64 |
| 128–255 | 128 |

`classify_counts` 转换字节计数；`discover_word` 检查 `current & virgin`，应用 `virgin &= ~current`。
`has_new_bits` 在无新颖性时返回 0、已知槽位新计数类时 1、新槽位时 2。
这不是保留每个唯一完整 trace 向量。
[表和 has_new_bits](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/src/afl-fuzz-bitmap.c#L46)、
[classify_counts/discover_word](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/include/coverage-64.h#L77)。

字节计数可溢出。所示 PCGUARD 使用 NeverZero，255 后是 1，**不是饱和**。
线程安全插桩是独立模式；普通增加本身不保证并发下精确计数。
插桩线程或 fork 后代可共享共享内存缓冲，但输入边界仍需协调目标生命周期。
[计数器与线程安全](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/instrumentation/README.llvm.md#L200)、
[映射运行时](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/instrumentation/afl-compiler-rt.o.c)。

特定映射使用时 trace 缓冲大小固定，但容量根据目标选择或协商。
不能认为全部 AFL++ 映射恒为 64 KiB。普通 forkserver 路径在执行前清零 `trace_bits`。
[扩容及运行重置](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/src/afl-forkserver.c#L2410)。

`save_if_interesting` 把候选加入队列。
崩溃或挂起去重先简化 trace 移除计数，再用独立 `virgin_crash`/`virgin_tmout`，
不同于普通成功队列新颖性。
[队列及崩溃挂起路径](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/src/afl-fuzz-bitmap.c)。

## 3. 实际 EFZ 覆盖架构

实际默认 staged/prepared 路径：

```text
efz_cli:launch/1 → efz:start/1
  → supervisor:start_child/2 (efz_sup) → efz_fuzzer:start_link/1
  → efz_config:prepare/1
  → efz_instrument:preflight/1 → efz_cov_integrity:pin/2
  → efz_fuzzer:init/1 → efz_corpus:start_link/4
  → efz_worker_sup:start_link/1 → efz_worker:start_link/1
  → efz_worker:init/1
       efz_cov_manifest:prepare/2       % campaign allowlist, not current coverage
       efz_feedback:new/1               % empty accumulated successful probe set
  → efz_worker:staged_iteration/1
  → efz_corpus:mutation_entries/0
  → efz_mutation_plan:next/2
       → attempts/6 → efz_mutation:apply_operation/3
  ← {candidate, Binary, Provenance, NextPlan}
  → efz_recipe:make/4
  → efz_worker:execute/4 → execute_checked/4
  → efz_executor:run/4 → run_checked/4 → run_pinned/4
  → spawn_monitor guardian → efz_guardian:run/6 → start/6
       efz_cov:open/1; efz_cov_integrity:open/2
       coordinator = efz_executor:coordinate/1
       root = efz_guardian:admit/2
  → root: efz_cov:attach/1 → efz_executor:invoke/4
  → HarnessModule:run(Binary) → selected instrumented functions
  → efz_cov_rt:hit({Module, BuildId, ProbeId})
       → publish/2 → insert/4 → ets:insert_new/2
  → guardian cleanup + process DOWN + trace barriers
  → efz_guardian:finish/2
       → efz_executor:coverage/3 → efz_cov:snapshot/1
       → efz_cov_manifest:validate_prepared/3
       → efz_cov:close/1
  ← execution result; efz_executor waits for guardian DOWN
  → efz_worker:execute_result/6 → efz_feedback:evaluate/3
  → efz_worker:retain/2 → efz_corpus:add/2
  → accepted/5; worker stores next feedback state; self() ! iterate
  → next efz_corpus:mutation_entries/0 includes the retained input
```

源码锚点：[worker](../../../src/efz_worker.erl#L47)、[计划器](../../../src/efz_mutation_plan.erl#L54)、
[执行器](../../../src/efz_executor.erl#L11)、[guardian](../../../src/efz_guardian.erl#L33)。
随机模式使用 `efz_corpus:select/0 → Mu:mutate/2`，之后执行、覆盖和反馈路径相同。
`coverage_validation => per_execution` 调用 `validate_observed/3` 而非 prepared 成员检查。
实验未创建新引擎。

关键进程消息：

| 消息 | 发送方 → 接收方 | 含义 |
|---|---|---|
| `{coordinate,Root,Context}` / `{coordinator_ready,Coordinator}` | guardian ↔ coordinator | 用户代码开始前安装根监视器 |
| `{start_owned,Capability}` | guardian/helper → target | 所有权注册后开门 |
| `{target_result,Ref,Root,Outcome}` | root → coordinator | 返回或异常分类 |
| `{coordinator_done,Coordinator,Outcome}` | coordinator → guardian | 进入清理 |
| `{efz_cov_observed,Ref,Identity}` | 首次插入钩子 → guardian | 首命中的独立证据 |
| `{efz_cov_failure,Ref,Reason}` | integrity/hook → guardian | 观察错误不能因异常被捕获而消失 |
| `DOWN`、`trace_delivered` | runtime → guardian | 确认终止及追踪处理 |
| `{Request,Guardian,Result}` | guardian → executor caller | 完成快照及生命周期状态 |
| `gen_server:call(...,{add,Binary,Meta},infinity)` | worker → corpus | 已确认条目插入 |

输入参数为 `binary()`。
`Provenance`/`Recipe` 包含 primary 字节与哈希、父 ID、操作和输出哈希。
`Result` 映射含 `outcome`、`coverage`（标识列表）、`coverage_status`、
`coverage_observation`、`builds`、`cleanup`。
全局集合接收覆盖列表；输入字节保留于 worker 和语料。

## 4. 覆盖数据结构

| 状态 | 物理表示 | 所有者与生命周期 |
|---|---|---|
| 每执行命中 | 未具名公开 ETS `set`，内部名 `efz_execution_coverage` | guardian；单执行至快照或关闭 |
| 目标上下文 | 进程字典键 `'$efz_execution_context'` → 上下文元组 | 根或受控子进程，直到死亡 |
| 独立观察证据 | guardian 状态 `observed_probes => sets:set()` | 同一执行；每标识首次命中 |
| 附加与完整性注册表 | 具名受保护 ETS `efz_coverage_observers`、`{Pid,Context}`、`{identities,Pins}` | guardian；同 VM 一次仅一个活动执行 |
| 允许覆盖标识 | 受保护 ETS `efz_coverage_plan` | worker；活动直到释放或所有者死亡 |
| 成功全局覆盖 | `S.feedback.global`，Erlang `sets:set()` | worker；活动 |
| 活动诊断 | `coverage_seen`，空、损坏、未开始计数 | worker；活动；**不是**新颖性状态 |
| Dirty 标志 | `persistent_term` `{efz_guardian,dirty_runner}` | VM；**不是**覆盖映射 |
| 持久化 | 源码清单；语料、崩溃及报告中历史元数据 | 文件系统；不是每执行 trace 缓冲 |

精确上下文和行格式：

```erlang
{efz_context, 1, ExecutionRef, Table, GuardianPid}
{efz_context, 1, ExecutionRef, {ets_member, Table}, GuardianPid}

%% Complete ETS object: one-element tuple.
{{probe, {Module, BuildId, ProbeId}}}
%% Its ETS key (default keypos = 1):
{probe, {Module, BuildId, ProbeId}}
```

一行代表一个精确探针存在。不存单独 value/counter 字段。
没有固定槽位空间、二进制位图、共享内存字节数组、`counters`/`atomics` 覆盖后端。
`ProbeId` 是元组键中的数字 ID，不是数组索引。
ETS 比较键解决内部哈希碰撞，不把不同标识合为同一覆盖位。
[open/attach/snapshot](../../../src/efz_cov.erl)、[insert](../../../src/efz_cov_rt.erl#L43)。

**已测 OTP 27** 的 `sets:new()` 返回带 hash segments 的版本 1 元组 `{set,...}`，不是原生 map。
EFZ 使用 `sets` API，不依赖私有布局。
`S.feedback` 中的 map 字样不证明存在 bitmap：它只是包含 set 的普通 Erlang map。

准备表含 `{Identity}` 及服务行 `{'$efz_plan',{Mode,Builds}}`、`{'$efz_identities',PinsResult}`。
它知道全部允许探针，包括从未执行者。
这是**验证允许列表**，不是累计覆盖。
[make_plan/2](../../../src/efz_cov_manifest.erl#L60)。

## 5. 探针标识

单位是**源码子句或结果探针**，清单指标 `clause_outcome_probe`。
`efz_instrument_pt:body/5` 在选中子句后于 body 开头放钩子。
实际种类：`function_clause`、`case_clause`、`if_clause`、`receive_clause`、
`receive_after`、`try_body`、`try_of_clause`、`catch_clause`、`try_after`、`fun_clause`、`named_fun_clause`。
不单独插桩 guard/pattern；短路运算数不自动获得独立 true/false 探针。
因此不是完整分支覆盖，也非全部 BEAM 基本块插桩。
[body/probe](../../../src/efz_instrument_pt.erl#L106)、[AST 遍历](../../../src/efz_instrument_pt.erl#L129)。

标识：`{Module :: atom(), BuildId :: binary(32), ProbeId :: pos_integer()}`。
transform 从 `next => 1` 开始，按 AST 遍历顺序分配，每点递增 `next`。
钩子将三元组存为编译时字面量。
清单映射 ID 至 module/function/arity、kind、source_file、line/column、structural_location。
行号只是元数据，**不是覆盖键**。

BuildId 为 `{1, OTPRelease, CompilerModuleMd5, CanonicalForms, IdentityOptions}` 的 SHA-256。
`source_root` 内路径相对 root 归一化。
其他模块及其他构建标识有独立命名空间。
清单验证拒绝重复 ID 和结构路径。
[构建计算](../../../src/efz_instrument_pt.erl#L36)、[验证](../../../src/efz_cov_manifest.erl#L4)。

稳定性：同构建执行使用同标识；已测环境相同规范源码、选项和工具链得到可复现 ID。
重排或增加 AST 点可移动数字 ID；源码、注解、选项或工具链变化可改 BuildId。
不保证任意编辑或 OTP 变化后 ID 稳定。
`determinism/1`、`build_options/0` 和全新重放检查特定边界。

标识契约限制：首常量 `1` 是模式版本；transform 自身内容不会自动哈希入 BuildId。
插桩语义改变需显式版本升级。
固定 BEAM、属性及测试驱动增加独立当前代码检查。
SHA-256 理论可碰撞，但不是哈希位图的常规槽位压缩。

**EFZ ProbeId 不是 AFL++ 边或槽索引。**它表示模块及构建命名空间中的 AST 点。
没有 `(previous,current)` 元组、XOR 槽映射或调用栈及 caller 贡献。
上下文 `ExecutionRef` 管生命周期，不是上下文敏感特征标识。

## 6. 每执行生命周期

1. `efz_executor:run_pinned/4` 创建独立受监视 guardian。
2. guardian 检查固定模块，经 `efz_cov:open/1` 创建新 ETS 和新执行引用。
   ETS 所有者为 guardian，不是根或协调器。
3. `admit/2` 开门前注册根与子进程；`attach/1` 把该案例共享表引用放进进程字典。
4. 钩子依外部注册表检查预期上下文，并执行 insert/member。
5. 根结果、超时或调用方/协调器 DOWN 后，guardian 终止根、后代和协调器，等待监视及追踪送达屏障。
6. `finish/2` 检查标识、快照及允许列表，核对独立观察探针与附加，然后关闭 ETS、注册表、追踪。
7. 结果发往 worker；调用方还等待 guardian DOWN。
   每执行表关闭后，反馈获得独立覆盖列表。
8. 下一案例新建表和引用；无显式 bitmap memset/reset。

[guardian start/admit/loop](../../../src/efz_guardian.erl#L33)、
[finish](../../../src/efz_guardian.erl#L163)、[执行器结果协议](../../../src/efz_executor.erl#L33)。

根崩溃不销毁覆盖表，所有者是 guardian。
超时保留 kill 前写入探针。
协调器故障产生基础设施结果；快照可含真实命中，但不进入全局覆盖。
调用方死亡仍触发清理，即便无接收结果者。
guardian 丢失不能视为确认清理：执行器标记 dirty 并禁用复用；
晚到 guardian 故障保留主要基础设施原因。

**受支持模型内，前一输入命中不进入下一输入。**
独立上下文、结果后 ETS 不存在和 A→B→A 提供确认。
关闭的旧上下文不会重定向到新表。
但目标改变 VM 全局状态可改变下一输入*行为*，这是另一不确定性来源，不是覆盖映射混合。
会诊断 persistent term 和 env 变化；对他人既有 ETS 的写入、外部服务、任意后台进程未完全隔离。
这是合作运行器，不是安全沙箱。参见[策略](execution-isolation.md)。

低层或手动 API 本身不具 guardian 全部保证。
`reset_local/0` 不清零复用全局位图：它创建上下文，或在已附加上下文时拒绝。
`snapshot/0` 和 `{manual,Id}` 为兼容接口；自动活动使用 `snapshot/1`，自动允许列表禁止手动标识。

## 7. 全局覆盖

权威状态：

```erlang
%% efz_worker state
#{feedback => #{builds => Builds, global => GlobalSet}}

%% efz_feedback:evaluate/3, valid successful outcome
New = lists:sort(sets:to_list(
    sets:subtract(sets:from_list(Observed), Global))),
NextGlobal = efz_cov:merge(Global, Observed).
%% efz_cov:merge/2 = sets:union(Global, sets:from_list(Observed))
```

即 `New = Current − Global`、`Global' = Global ∪ Current` **确实实现**，
针对精确标识且只用于合适结果。
[evaluate/3](../../../src/efz_feedback.erl#L16)。

| 执行 | 全局改变吗？ | 决策与保留 |
|---|---|---|
| 成功变异，覆盖合法 | 与当前取并集 | 非空增量为 `new_coverage`，否则 `equivalent_coverage` |
| 成功校准 | 与当前取并集 | 总为 `seed_calibration`；种子已在语料 |
| `error` / `throw` / `exit` / 外部杀根 | 否 | `target_failure`、`new_probes => []`，独立崩溃路径 |
| 超时 | 否 | `target_failure`，超时产物及计数 |
| 基础设施 / 无效覆盖 / 构建不匹配 | 否 | `{error,Reason}`，活动停止 |
| 合法零命中成功 | 与空集合取并集 | 非发现；观察区别于损坏覆盖 |

普通返回 `{error,invalid_input}` 仍属成功执行：执行器包装为 `{ok,Value}`。
异常和返回 term 不同。

`coverage_seen`/`coverage_diagnostics` 也包含失败观察信息，不能等同成功全局集合。
严格策略在完全未观察探针时拒绝活动，不是新新颖性条件。

全局属于一个 worker，重启不恢复。
持久语料恢复字节和历史，随后 worker 重新校准并建立新累计覆盖。
保留时文件系统故障停止活动；成功 retain 前 `accepted/5` 不确认新反馈状态。

## 8. 命中计数分析

`efz_cov_rt:insert/4` 调用 `ets:insert_new(Table,{{probe,Id}})`：
首次加行并发送 guardian 通知，重复返回 `false`，不改行。
`ets_member` 先查成员，但最终仍用原子 `insert_new`。
并发受控子进程可同时看见无行，但只有一次插入为新。

生产源码搜索：

```sh
rg -n 'counter|count_class|bucket|bitmap|update_counter|atomics|counters:|array:|prev_loc|edge' src
```

`counter` 匹配属于**崩溃出现存储**，不是探针命中。
生产路径未发现整数、饱和或 8 位命中计数器、桶查找表或频率感知覆盖特征。
transform 编译时 `next` 统计分配探针 ID，统计模块数执行和发现；这些是不同计数器。

| 同一 x/0 调用数 | EFZ 行数 | 快照 | 首命中后能带来仅计数新颖性吗？ |
|---:|---:|---|---|
| 1 | 1 | `{X}` | 首个 X 可产生新颖性 |
| 2 | 1 | `{X}` | 否 |
| 3 | 1 | `{X}` | 否 |
| 8 | 1 | `{X}` | 否 |
| 10 | 1 | `{X}` | 否 |
| 1000 | 1 | `{X}` | 否 |

这通过**自动钩子**检查，不是手动 `efz_cov:hit/1`。
目标在自身进程字典有独立诊断调用计数，确认循环实际调用 1000 次，不参与 EFZ 覆盖。
每执行覆盖计数器不会溢出，因为不存在。

## 9. 新颖性语义

下表针对覆盖合法的成功变异。
AFL++ 中 A/B/C 表示无碰撞槽或特征；未指定次数时假定桶不变。

| 场景 | EFZ `new_probes` | EFZ 结果 | AFL++ 仅覆盖参考 |
|---|---|---|---|
| A：current `{A,B}`，global `{}` | `{A,B}` | `new_coverage`，并集 `{A,B}`，保留 | 新槽，novelty class 2 |
| B：current `{A,B}`，global `{A,B}` | `{}` | `equivalent_coverage`，不保留 | 桶不变时 0 |
| C：current `{A,B,C}`，global `{A,B}` | `{C}` | `new_coverage`，保留，并集 `{A,B,C}` | 新槽 C，class 2 |
| D：已知 A 执行 100 次 | `{}` | 仅次数不算有趣 | 若对应桶未观察，可产生 class 1 |
| E：仅已知点的新组合 | `{}` | 非新覆盖 | 已知槽和桶组合自身不新颖；新边或计数可改变结果 |

集合也丢顺序：若插桩产生相同点，`AB` 和 `BA` 相等。
AFL++ 中*基本块*重排可意味着新**边**，不同于已有边特征重排。
不能仅因保存用于校准或调度的 trace 哈希，就称 AFL++ 具完整执行签名唯一性。

## 10. 语料反馈集成

`efz_worker:execute_result/6 → efz_feedback:evaluate/3 → retain/2`
**仅**对 `new_coverage` 调用 `efz_corpus:add(Input,Meta)`。
`efz_corpus:add_checked/3` 与条目比较字节，启用存储时保存持久记录，
再将 `#{id,input,metadata,added_at}` 加入条目。
下一 `mutation_entries/0` 也为新条目返回紧凑 `#{id,input}`。
计划器读取实际当前语料，维护按内容游标，语料增长时重置此前空闲观察。
供体候选也来自该语料。
[worker retain](../../../src/efz_worker.erl#L122)、[语料](../../../src/efz_corpus.erl#L36)、
[增长调度器](../../../src/efz_mutation_plan.erl#L54)。

这不是仅遥测流水线。`efz_feedback_loop_tests:feedback_loop/0`
以真实 staged 字典算子、仅 A/B/C token 运行活动：

```text
ID 1: <<>>
  → ID 2: <<"A">>,   parent 1
  → ID 3: <<"AB">>,  parent 2
  → ID 4: <<"ABC">>, parent 3
```

测试检查真实新探针、按执行 ref 的输入传递、配方 primary 字节和哈希、全新 VM 重放。
此运行有 **30 次变异执行、31 次测试驱动传递、3 次发现**。
无脚本式变异器。
额外审计实验也将保留 AB 交给真实计划器，检查 `parent => 2, primary => <<"AB">>`。

新条目不必恰为下一个：计划器先完成当前快照轮次。
这是调度公平性，不是反馈循环中断。

## 11. 跨进程限制

| 变体 | 覆盖 | 生命周期与接纳 |
|---|---|---|
| 根调用插桩函数 | 写执行 ETS | 支持 |
| `efz_target:spawn/1` | 用户代码前自动附加上下文，共享精确集合 | 支持；guardian 等待清理 |
| `efz_target:spawn_link/1` | 相同 | 支持；link 不定义覆盖标识 |
| 嵌套受控子进程 | 相同，经同一 guardian | 接纳上限内支持 |
| 普通 `erlang:spawn` | 不自动继承上下文 | 追踪发现不受控 spawn；基础设施或 dirty runner |
| 既有后台进程 | 通常未附加上下文，钩子不活动 | 支持执行范围外 |
| 任意子进程手动 `efz_cov:attach/1` | 本身不赋予生命周期所有权 | 不会使普通 spawn 受支持 |

因此，**受控 API 用户不需要手动附加**。
但覆盖不会自动扩展到每个 Erlang 进程。
普通进程字典不被 spawn 继承；已接纳进程外缺少上下文的原生插桩钩子不活动。
[目标 API](../../../src/efz_target.erl)、[接纳](../../../src/efz_guardian.erl#L51)、
[不受控检测](../../../src/efz_guardian.erl#L143)。

未链接子进程异常本身不决定根结果：测试驱动必须等待并表达其结果。
受控子探针在清理前进入快照；根结果决定是否允许快照进入成功反馈。
共享 ETS 不创建 caller-sensitive 或 PID-sensitive 覆盖特征。

## 12. EFZ 与 AFL++ 对比矩阵

`YES` 表示同一具体属性存在，不代表二进制兼容。
`FUNCTIONALLY SIMILAR` 表示角色相同、实现不同。

| 机制 | AFL++ | EFZ | 等价性 |
|---|---|---|---|
| 插桩 | 编译器或运行时钩子 | Erlang parse transform 加运行时钩子 | FUNCTIONALLY SIMILAR |
| 覆盖粒度 | 通常 CFG 边，取决于模式 | AST 子句或所选结果 | PARTIAL |
| 每执行覆盖 | 共享字节 trace 数组 | 全新公开 ETS 精确集合 | FUNCTIONALLY SIMILAR |
| 固定大小位图 | 分配数字槽缓冲 | 无 | NO |
| 覆盖槽 | 数字索引 | 精确元组 ETS 键 | NO |
| 边 ID | 依模式的边或 guard 标识 | 源码点，无 previous/current 边 | NO |
| 命中计数 | 字节增加，模式特定溢出策略 | 无 | NO |
| 计数桶 | 已分类计数器类别 | 无 | NO |
| 全局或 virgin 状态 | 尚未观察特征位 | 已观察成功探针标识 | FUNCTIONALLY SIMILAR |
| 新覆盖检测 | 新槽或桶 | 仅新探针标识 | PARTIAL |
| 执行间重置 | 清除或重建 trace | 销毁 ETS，创建新上下文与表 | FUNCTIONALLY SIMILAR |
| 碰撞行为 | 哈希模式碰撞；LTO/PCGUARD 可精确 | 无槽别名，精确键 | PARTIAL |
| 崩溃覆盖 | trace 加独立崩溃或挂起新颖性图 | 保留快照，按归一化崩溃签名去重 | PARTIAL |
| 语料反馈 | 新颖性 → 队列 → 后续变异 | 新颖性 → 语料 → 调度器 → 变异 | YES |
| 构建标识 | 槽绑定插桩二进制或映射；不是每字节含 BuildId | 每标识含 Module + BuildId，固定测试驱动及 BEAM | NO |
| 跨进程覆盖 | 参与插桩进程或线程共用映射 | 根与受控后代共用一个 ETS | PARTIAL |

矩阵使用第 2 节源码参考和第 3–11 节实际 EFZ 路径。
Build identity 的 `NO` 不表示 AFL++ 无目标检查，而特指每个覆盖元素中的内嵌命名空间。

## 13. 运行时实验

从 EFZ 根目录复现：

```sh
ERL_FLAGS='+S 4:4' rebar3 compile
escript docs/coverage-audit-2026-09-15/run.escript
ERL_FLAGS='+S 4:4' rebar3 eunit
ERL_FLAGS='+S 4:4' rebar3 ct
ERL_FLAGS='+S 4:4' rebar3 xref
ERL_FLAGS='+S 4:4' rebar3 dialyzer
```

[Sites](../../coverage-audit-2026-09-15/efz_cov_audit_sites.erl) 用真实 `efz_instrument:compile/2` 编译。
[测试驱动](../../coverage-audit-2026-09-15/efz_cov_audit_harness.erl)使用普通编译器。
刻意排除分发和循环控制探针：否则 LOOP1/LOOP10 可因另一个循环子句的新探针而不同，
错误地被当作计数敏感性证据。

[运行器](../../coverage-audit-2026-09-15/run.escript)使用真实执行器、prepared 验证、反馈和语料。
代数检查输入由诊断驱动提供，**不声称这些输入由变异器生成**。
`efz_feedback_loop_tests` 生产活动单独证明真实变异→执行→父输入复用。
没有 mock 覆盖或语料，也没有自定义变异器。

此目标标识映射：A=探针 1、B=2、C=3、X=4，全部同一模块及构建。
前两个诊断语料条目是初始空 ID 1 和保留 AB ID 2。

| 顺序输入 | 当前探针 | 新探针 | 保留原因 | 之后全局 | 语料大小 |
|---|---|---|---|---|---:|
| AB | A,B | A,B | new_coverage | A,B | 2 |
| AB 重复 | A,B | — | equivalent_coverage | A,B | 2 |
| ABC | A,B,C | C | new_coverage | A,B,C | 3 |
| BA | A,B | — | equivalent_coverage | A,B,C | 3 |
| AC | A,C | — | equivalent_coverage | A,B,C | 3 |
| LOOP1 | X | X | new_coverage | A,B,C,X | 4 |
| LOOP2 | X | — | equivalent_coverage | A,B,C,X | 4 |
| LOOP3 | X | — | equivalent_coverage | A,B,C,X | 4 |
| LOOP8 | X | — | equivalent_coverage | A,B,C,X | 4 |
| LOOP10 | X | — | equivalent_coverage | A,B,C,X | 4 |
| LOOP1000 | X | — | equivalent_coverage | A,B,C,X | 4 |

`ets` 和 `ets_member` 得到相同结果。
各 LOOP 原始 ETS 含**一个对象**，诊断 x-call 次数符合 1/2/3/8/10/1000，快照始终 `{X}`。
这些输入的 ETS 内存均 324 个机器字（wordsize 8 时 2592 字节），包含表开销，
不含 guardian、注册表、计划和结果堆。
2 与 3 探针分别观察到 343、362 字。
这是本地存储样本，不是吞吐基准或通用内存公式。

额外断言验证：

* 系列全部上下文不同，所有者为 guardian，结果后 ETS 已关闭；
* A→B→A：第一和第三运行精确覆盖匹配，B 不含 A；
* 真正零命中成功 → `valid_empty_coverage`；
* 校准 A 更新全局，原因仍为 `seed_calibration`；
* X 后崩溃和超时保留 `{X}`，反馈不改变空全局；
* 删除上下文加捕获钩子异常 → 基础设施，反馈拒绝；
* child/linked/nested：一个 C 探针、共享上下文，已知进程分别 2/2/3，结果到达时全已死亡；
* 独立 VM 中普通 spawn：覆盖空、基础设施或 dirty-runner，两个已知进程终止，不启动下一输入；
* 保留 AB 确实由 `efz_mutation_plan:next/2` 选择，父 ID 2。

原始运行记录和命令日志：`_build/coverage-audit-2026-09-15/`。
紧凑保留结果：[results.txt](../../coverage-audit-2026-09-15/results.txt)、
[validation.json](../../coverage-audit-2026-09-15/validation.json)。

验证：compile 退出 0；EUnit **186 passed**、退出 0；Common Test **3 passed**、退出 0；
xref 和 dialyzer 退出 0。
新增审计断言独立运行，不增加 EUnit 案例数。
全部生产源码 SHA-256 前后核对，无变化。

完整套件还覆盖未被新实验重复的路径：

| 测试 | 检查范围 |
|---|---|
| `efz_phase2_tests` | AST 语义、清单标识、重复性、独立上下文、异常或超时、编译器选项 |
| `efz_backend_tests` | 后端等价、prepared/per-execution 验证、生命周期及损坏观察 |
| `efz_integrity_tests` | 普通或不同构建热重载、固定测试驱动、上下文丢失或损坏、捕获异常、合法空覆盖 |
| `efz_isolation_tests` | 调用方或协调器死亡、超时后代、嵌套范围、dirty 状态及 guardian 故障 |
| `efz_crash_retention_tests` | 晚到 guardian 故障保留主要基础设施原因 |
| `efz_feedback_loop_tests` | 真实 staged 发现→保留→父复用及全新重放 |
| `efz_durable_tests` | 另一 VM 恢复发现、重新校准并成为父输入 |
| `efz_coverage_SUITE` | 自动活动、崩溃及超时观察 |

## 14. 最终分类

**RESULT B——实现了类似 AFL++ 的反馈语义，但表示不同。**

全部链路已证明：自动插桩 → 执行所属观察 → 已验证快照 → worker 全局集合 →
精确新颖性增量 → 真正语料插入 → 未来变异父输入。
因此结果 C/D 不描述当前 EFZ。

排除结果 A：物理 trace 结构是 ETS 集合，命中次数在 `insert_new/2` 已丢失。
在文档称作“位图”不改变这一点。
结果 B 描述整体反馈架构，**不表示与 AFL++ 的边、计数、上下文观察能力相等**。

## 15. 建议后续步骤

**不需要为模仿 AFL++ 重写当前系统。**
先分开三个独立变化：(1) 表示，(2) 计数敏感性，(3) 边及上下文粒度。
稠密缓冲本身既不创建边，也不创建桶。

| 方面 | 对 EFZ 的结论 |
|---|---|
| 查找及更新速度 | ETS 有哈希查找和原子插入，但每命中还检查注册表和上下文。基准应分别测钩子、完整性追踪和完整执行器。不能从位图名字假定加速。 |
| 内存使用 | 稀疏集合随命中数增长，有表及元组行开销和重复证据；稠密缓冲为整个槽范围分配，包括未执行探针。 |
| 探针数 | 总 N 大、命中 K 小时稀疏可能有利；稠密覆盖时紧凑数字表示可能更好。需要不同 N/K 工作负载。 |
| ETS 开销 | 可先评估紧凑精确键和查找映射，保留 presence 语义。当前快照 tab2list + sort 并复制 term 数据。 |
| 命中计数敏感性 | 对循环有用的独立选项；可用精确计数器原型实现，无哈希碰撞，无完整位图重写。 |
| 碰撞 | 无已证明需求引入 modulo/hash 别名会丢失当前精度；优先清单准备的无碰撞稠密索引。 |
| 确定性标识 | 保留公开 `{M,Build,Probe}`；数字槽只是所选构建集合的内部映射。 |
| 并行 worker | 当前 VM 仅允许一个执行。存储变化不能修复单例注册表和 guardian，也不改变共享状态隔离模型。 |
| 分布式模糊测试 | 先独立 VM、版本化标识和指标、交换原始输入并本地校准；不合并不同构建的任意槽图。 |
| 语料兼容 | 字节可复用；旧 `new_probes` 保持历史 presence 元数据。桶发现需独立指标或模式版本，不静默重解旧记录。 |
| 重放 | 配方重建字节与存储无关；保留固定构建和测试驱动检查，覆盖预期需知道指标及版本。 |
| 向后兼容 | presence 保持默认和参考；新模式显式启用。差分测试保留既有结果和标识。 |

需求被确认后，最小**建议而非已实现**架构：

```text
existing instrumentation → {Module,BuildId,ProbeId}
  → immutable prepared exact identity↔dense-slot mapping
  → execution-owned counter array / exact sparse counter backend
  → explicit saturating/overflow policy
  → versioned bucket classification
  → novelty of (ProbeIdentity,Bucket) against campaign global features
  → existing feedback retention path → existing corpus/scheduler
```

质量比较可保留兼容 `coverage => [Identity]`，增加独立 `coverage_features` / `new_features`；
仅计数发现不得虚报新源码探针。
新快照必须保留 guardian 生命周期、受控子原子更新、完整性检查、清理、构建验证和正确重置。
没有限定所有者的共享持久位图会破坏已证明保证。

`efz_mutation`、`efz_mutation_plan`、原始输入及配方再生、语料选择，
以及大部分 `efz_worker`、`efz_executor`、`efz_guardian`、`efz_instrument_pt` 无需重写。
变化集中于 `efz_cov`、`efz_cov_rt`、准备映射和验证、`efz_feedback`、配置，
以及语料、崩溃、重放中的版本化元数据。
覆盖完整性证据需适配计数器：当前首次观察集合不确认次数精确。

下一实验验收：presence 模式保持原结果；count 模式在新桶保留 LOOP1 后再保留 LOOP10；
相同桶重复不保留；A→B→A 干净；受控并发增加不丢失；
崩溃或超时清理不损坏快照；拒绝构建或指标不匹配。
生产位图决策应依据端到端成本和真实目标上的有用发现数，而非单独数组速度。
