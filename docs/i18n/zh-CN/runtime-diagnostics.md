# 自动运行时诊断（P0）

[English](../../runtime-diagnostics.md) · [Русский](../ru/runtime-diagnostics.md) · [Español](../es/runtime-diagnostics.md) · **简体中文** · [所有语言](../README.md)

P0 通过 EFZ 设置启用。现有 `Target:run(Input) when is_binary(Input)` 和插桩目标无需修改。
默认 `enabled=false`。`run/3` 保留此前元组 API；`run/4` 额外获得模式 v1 的 `runtime_observations`。
活动 worker 组织重复运行；独立 `run/4` 执行一个输入。

支持模型仍是**带受控后代的同步二进制测试驱动**。
监控不会使任意 `spawn`、后台 OTP 应用、外部消息、共享状态修改或 I/O 变为受支持。
[guardian 与隔离](execution-isolation.md)规则继续生效。
此处没有生产一次性 VM 后端。

## 配置

完整默认值如下（只需提供覆盖字段）：

```erlang
runtime_oracles => #{
  enabled => false,
  stability => #{enabled => true, seed_runs => 3, interesting_runs => 3,
    suspicious_runs => 3, failure_runs => 3, compare_return => false,
    max_extra_executions => 1000},
  resources => #{enabled => true, sample_interval_ms => 20, max_samples => 64,
    max_sampled_processes => 128, ets_interval_ms => 100, max_ets_tables => 256,
    memory_bytes => 67108864, mailbox_messages => 1000,
    ets_memory_bytes => 16777216, residual_memory_bytes => 67108864,
    quiescence_ms => 1, memory_observation_timeout_ms => 50},
  hangs => #{enabled => true, max_stack_frames => 8,
    busy_reductions => 1000, max_sample_age_ms => 100},
  storage => #{max_groups => 128, max_representatives => 3,
    max_metadata_bytes => 1048576, max_total_metadata_bytes => 16777216}}
```

`efz_runtime_config:prepare/1` 是 API、执行器、CLI 和重放共用验证器。
全部未知字段和无效类型都被拒绝，包括关闭的配置部分。

| 字段 | 范围或单位 |
|---|---|
| `*_runs` | 1..16，**包括初始运行** |
| `max_extra_executions` | 整个活动 0..1 000 000，含种子验证 |
| `sample_interval_ms` | 1..10 000 ms；前一次轮询结束后间隔 |
| `max_samples` | 2..256，保留最新样本，不是最早样本 |
| `max_sampled_processes` | 1..256；与 `max_samples` 乘积 ≤32768 |
| `ets_interval_ms` | 10..60 000 ms；首次 ETS 扫描仅在该间隔后发生 |
| `max_ets_tables` | 每扫描检查 1..4096 个 VM 表 ID |
| 资源阈值 | 1..2^40；进程或 ETS 内存按字节，邮箱按消息 |
| `residual_memory_bytes` | 1..2^40 字节，清理后 VM 全局二进制内存增量阈值 |
| `quiescence_ms` | 0..100 ms，guardian DOWN 后固定等待 |
| `memory_observation_timeout_ms` | 1..1000 ms，大于 quiescence；包含等待的单次测量总截止时间 |
| `max_stack_frames` | 0..32，仅 MFA，不含参数或局部变量 |
| `busy_reductions` | 最新区间 1..10^9，不是 CPU 使用率 |
| `max_sample_age_ms` | 1..60 000；开启 hangs 时至少等于采样间隔 |
| `max_groups` / `max_representatives` | 1..1024 / 1..16 |
| `max_metadata_bytes` | 每发现载荷 4096..4 MiB |
| `max_total_metadata_bytes` | 4096..64 MiB，至少等于单项配额 |

`resources.enabled=false` 时，hangs 部分仍可收集进程样本，
但基于阈值的资源发现关闭。两部分均关闭时无资源样本，生命周期证据仍可用。

CLI：

```sh
escript scripts/fuzz.escript \
  --target my_harness --code-path ./harness-ebin --artifacts ./instrumented \
  --seeds ./corpus --out ./findings --max-iterations 1000 --timeout 1000 \
  --runtime-diagnostics --runtime-runs 3 --verification-budget 1000 \
  --sample-interval 20
```

`--runtime-runs` 同时设置四个重复次数。其他运行时标志要求 `--runtime-diagnostics`。
核心验证数值限制；CLI 不从模块名文本创建原子：目标仅从所选产物或代码路径本地 BEAM 解析。
CLI 仍不会执行参数中的 Erlang 表达式。

## 校准与验证

种子、新成功覆盖或计数发现、目标故障和可疑运行时输入会重复运行。
仅 `descendant_activity` 不触发额外检查。
每次重复是**全新标准执行器、guardian、根进程**，并完整清理。
不递归验证。重复不调用变异器、语料选择、staged 计划器、反馈或保留。
初始结果仍经现有反馈，作为该候选唯一保留依据。

若执行 `M` 次变异和 `S` 次种子，总执行最多 `M + S + max_extra_executions`。
额外运行更严格上界为 `min(budget, sum(requested_runs_for_selected_input - 1))`。
`max_iterations` 不包括验证。超时及清理边界分别约束每次运行；
这限制执行次数，不限制活动墙钟时间。

任何基础设施故障立即停止重复和活动。原始原因保留在故障上下文，包括 dirty runner 和 guardian 故障。
首次在重复中发现的崩溃、退出或超时经常规崩溃存储保存，
带 `metadata.origin=verification` 及新的 occurrence。
每次执行恰好计数一次。运行时类别不增加崩溃计数。

结果签名比较 `ok`、异常类和有界原因类别、退出类别或超时。
**不比较**任意成功返回值。
可选返回比较器接受原子、有符号 64 位整数、二进制、列表、元组或映射，
分别限制 1024 节点、1024 二进制字节、1024 容器元素和深度 64。
映射用无序迭代器遍历，不排序或复制键；读取二进制内容前先检查 byte_size。
只有完整验证通过的 term 才确定性 ETF 序列化。
PID、ref、port、函数、浮点和大型或深层 term 得到 `not_comparable`。
它不推断整数时间戳语义：显式启用 compare_return 后，这些值可能不同。

EFZ 自身指标，**不等同于 AFL++ stability**：

- 结果可重复率 = `100 * max_frequency(normalized_outcome) / completed`。
- 覆盖可重复率 = `100 * max_frequency({builds, exact_probe_set}) / valid`。
  完全可用系列中 `valid=completed`。无效或未开始快照排除，不替换为空集合。
- 稳定探针 = 合法集合交集。可变探针 = 并集 − 交集。
- 稳定探针比例 = `100 * |intersection| / |union|`。
- 多个合法空集合：两项覆盖指标均为 100%，`valid_empty_coverage=true`。
- 少于两个可用运行：`insufficient_samples`，即使唯一运行成功。

`requested` 包含初始运行；`attempted=completed+failed`；
`completed` 表示无基础设施故障的运行；`valid` 还排除未开始覆盖；
`failed` 表示基础设施故障；`skipped=requested-attempted`。
每行包含时长、覆盖与构建标识、清理状态及运行时摘要。
验证独立统计 requested/executions/completed/valid/failed/skipped。
覆盖完整性错误绝不变为 `unstable_coverage`。

## 观察与范围

| 类别 | 测量或推断内容 | 不能证明 |
|---|---|---|
| `unstable_outcome` | 系列归一化结果不同 | 安全漏洞 |
| `unstable_coverage` | 精确合法覆盖集合或构建不同 | 目标缺陷或不稳定原因 |
| `unstable_return` | 仅可选模式下，可比较成功值不同 | 语义缺陷 |
| `memory_pressure` | 已观察进程内存总和 ≥ 字节阈值 | 泄漏；总 VM 或二进制资源内存 |
| `memory_growth_suspected` | 首末保留样本之间增长 ≥ 阈值 | 跨输入残余增长或内存泄漏 |
| `vm_memory_growth_suspected` | 清理及静止后 VM 全局二进制内存减基线 ≥ 残余阈值 | 目标归属或已确认泄漏 |
| `mailbox_pressure` | 已观察 message_queue_len 总和 ≥ 阈值 | 消息丢失 |
| `ets_growth_suspected` | 所属 ETS 观察内存峰值 ≥ 阈值 | 清理后表泄漏 |
| `descendant_activity` | guardian 接纳数及已观察活进程峰值 | 进程泄漏 |
| `child_abnormal_exit` | guardian 在运行阶段收到异常子进程 DOWN | 必然缺陷或改变根结果 |
| `timeout_busy` | 匹配所属 PID 的显著 reductions 增量 | CPU 使用率、活锁或没有进展 |
| `timeout_waiting` | 完整新鲜样本：waiting 且增量小 | 死锁 |
| `timeout_unknown` | 数据不足、过时、不完整或含糊 | 超时原因 |

全部资源阈值仅用于诊断：堆限制不变，不增加杀进程原因。
`thresholds` 保存基线、观察、阈值、解释和 `defect=unproven`。
`reproductions` 显示包含该类别的运行次数。首次失败不会隐藏为预热。
不强制 GC 其他进程，不回滚 persistent_term、env 或共享 ETS。

采样器只经独立有界表接收 guardian 已接纳 PID，不用 `processes()` 判断所有权。
guardian、协调器、采样器及覆盖、语料、报告 ETS 排除在外。
执行中可获取内存、邮箱长度、reductions、状态、current_function 和有界堆栈。
不读取邮箱、ETS 或进程字典内容。
持久化摘要中的进程 ID 换成可移植占位符；`process_id`/`owner_id` 是接纳序号。

基线在**接纳前**采集：目标所属进程和 ETS 为零；VM 计数器带 `scope=vm_global`。
这不是已运行目标的内存快照。

独立执行后路径在执行前、确认清理**及正常 guardian DOWN** 后，通过有界静止等待测量
`erlang:memory(binary)`。
测量在有自身截止时间的短生命周期受监视 helper 中执行，不在 guardian 内运行，
不延迟 kill 或清理。测量失败产生 `incomplete`，不是零。
清理失败保留基础设施故障，不继续残余观察。
P0 关闭或 resources 关闭时不调用该路径。

`post_execution_memory` 包含 scope=vm_global、metric=binary_memory、units=bytes、
baseline_memory、采样 peak_memory（或 not_sampled）、post_execution_memory、
residual_delta、threshold、completeness、cleanup_status、quiescence 和 deadline。
`owned_memory` 单独保留目标所属峰值；所有者销毁后，post memory 和 residual 标记 not_applicable，
而不虚构精确测量。不使用其他进程 GC、共享状态写入或所有权变化。

明确限制归属判断：VM 增量包含 EFZ 保留返回值及其他 VM 活动。
普通返回大型引用计数二进制，是根清理后 VM 残余分配的受支持样例，不是目标泄漏。
验证保存实际 M/N；重放可能得到不同 M/N，因为释放此前 EFZ 持有返回值或其他 VM 活动会抵消新增增长。
临时分配不产生残余发现的情况独立于峰值检查。
此类发现产物与签名也带 scope=vm_global；旧模式 v1 产物仍可读，缺失策略字段获得默认值。
执行中快照测量观察峰值；最新可用样本独立于清理后生命周期证据保存。
没有轮询到活 PID 时，结果是 `not_sampled`，不是零消耗。

OTP 27 的 ETS `memory` 以字为单位，乘以 `erlang:system_info(wordsize)`：
[官方 ETS info 文档](https://www.erlang.org/docs/27/apps/stdlib/ets.html#info/2)。
ETS 扫描在采样器中按独立频率和上限运行。
通过 `ets:all()` 列出 VM 表 ID，但只检查前 `max_ets_tables` 个并按所有者过滤。
显示已知 VM 表数、已扫描 VM 表数和观察到的所属表数；遍历不完整或资源消失时 `partial=true`。
扫描截断时，所属表总数未知。不会声称部分总和等于目标消耗。
消失检查只请求 `ets:info(Tab, owner)`，不构造完整表元数据列表。
`ets:all()` 本身仍是 O(VM 表数)；上限约束后续检查，不限制该枚举。
guardian 既有共享状态快照（案例前后 `ets:all()`）仍属于清理契约；
新采样器不会给每个快速迭代增加 ETS 扫描。

采样器环形保存最新 `max_samples`；峰值独立于环保留。
它监视 guardian，guardian 也监视采样器。
清理先销毁目标进程，再销毁采样器。
guardian 不在杀进程前请求最后一次 `process_info`，也不等待“理想”快照。
采样器 DOWN 属于有界清理生命周期。
采样器独立死亡被标为 failed/partial，不替换结果。
guardian 自身丢失保留 dirty-runner 策略。

运行中子进程 DOWN 记录原因类别和阶段；发起者通常未知：监视器不能证明是父进程停止子进程。
清理标记 kill_requested；清理阶段收到 DOWN 时 classification=unknown，
因为与自然死亡存在竞争。清理 kill 不创建 child_abnormal_exit。
`after_cleanup` 报告确认的所有者终止及已知存活者；逃逸 ETS 或共享状态仍产生现有基础设施故障，
不是资源发现。

超时保留原结果和截止时间。
分类使用最后两个样本，匹配 PID，记录年龄、区间、匹配及观察进程数、reductions 增量、
状态、邮箱和有界堆栈。
部分活动可以证明观察到繁忙活动；waiting 要求完整样本。
无法重建采样间隙中已完成的所有进程信息。

## 存储、报告与重放

存储位于 `crash_dir` 旁：`dirname(crash_dir)/runtime-findings/`；
CLI 对应 `OUT/runtime-findings/`。独立于崩溃分组。

```text
runtime-findings/
  index                       checksummed EFZO v1 index
  SIGNATURE_HASH-INPUT_HASH/
    artifact.input            exact raw bytes
    artifact.term             bounded ETF schema v1
    manifest                  hashes and sizes of both files
```

记录包含输入 SHA-256、category/scope/origin、可移植测试驱动和构建标识、归一化原始结果、
策略与阈值、有界证据及全部检查，并在存在时保留**原始精确变异配方**。
无论配方是否可用，所选代表始终保留原始输入。

签名 = version/category/scope/harness/builds 的 SHA-256。
PID、ref、时间戳和具体内存增量不参与。
此分组可能合并不同原因。
`max_representatives` 限制每组不同输入，`max_groups` 限制存储分组数；
抑制和丢弃分别计数。
元数据配额包括载荷、清单和索引；原始字节还受
`max_groups * max_representatives * max_input_bytes` 限制。
超长载荷导致代表丢弃，不是无界序列化或写入。
报告检查固定上限 128，另有字节配额；`checks_dropped` 记录截断。
存储跨活动保留计数和上限。

分组通过 fsync 与清单原子发布，再原子更新索引。
中断区间、损坏已提交条目、过期写入者或索引、残留 `.writer-lock`
均为显式存储故障，停止活动。
不自动删除或“修复”；调查错误后使用新输出目录。
单写入者锁不允许不同活动持过期内存索引并发运行。

报告片段示例（是模式，不保证特定测量值）：

```erlang
#{runtime_diagnostics => #{
    verification_executions => 2,
    checks => [#{requested => 3, completed => 3, valid => 3, failed => 0,
                 skipped => 0, origin => calibration,
                 outcome_repeatability => 100.0,
                 reproductions => #{timeout_waiting => 3}}],
    findings => #{groups => #{}, suppressed => 0, dropped => 0}},
  stats => #{executions => 0, calibrations => 1, verification_executions => 2}}.
```

检查所选代表目录，**显式指定本地目标**：

```sh
escript scripts/replay.escript \
  --runtime-finding ./findings/runtime-findings/SIGNATURE_HASH-INPUT_HASH \
  --target my_harness --code-path ./harness-ebin --artifacts ./instrumented --runs 3
```

API：`efz_replay:runtime(Directory, LocalTarget, Artifacts, #{runs=>3})`。
策略、超时和输入限制来自发现；`runs` 为 1..16，默认保存的 interesting_runs。
目标和产物仅来自调用方。
执行前检查原始 SHA-256、清单、构建和测试驱动。
安全 ETF 解码不创建目标派生原子。
`observed` 退出 0；`not_observed` 或 `inconclusive` 退出 3；
不兼容或无效调用退出 2；基础设施故障退出 1。
旧崩溃 `.replay`、配方和原始输入 CLI 继续支持。

不稳定类别只运行一次会得到 inconclusive；报告显示样本数量、可重复率和可变比例。
即使 `not_observed` 也只描述有限样本结果。
资源缺少完整样本时为 inconclusive，不证明不存在问题。
重复使用相同执行器，遇基础设施故障停止。
重放不写新活动崩溃分组：重复期间发现的故障包含在返回摘要中。
活动验证会将其保存到磁盘。

## 成本与限制

`stats` 区分变异执行、校准与验证。
独立测量验证耗时、执行后 `runtime_diagnostic_us`
（worker 墙钟，包括验证和存储，排除初始执行器）、采样器工作时间、已采样或遗漏执行，
以及运行完成时测得 ETS 诊断缓冲最大字节数。
最后一项**不包括采样器、guardian 或报告堆**；样本槽、子记录、报告及磁盘元数据有各自上限。
快照复制、worker 比较及存储也耗时；`sampling_us` 不是 P0 总成本。
这是合作式 BEAM 诊断，不是实时调度保证。

P0 不证明内存安全、任意资源泄漏、竞态条件、死锁或活锁原因、原生故障、语义正确性或外部副作用。
没有 FD 或套接字泄漏检测器、NIF/ASan/UBSan/LSan、调度器扰动、有状态或序列模糊测试、
分布式、能量调度或不稳定探针屏蔽。
未测量完整堆外二进制占用。
样本会遗漏快速峰值及迅速终止子进程或表。
依赖状态的增长可能需要输入历史或全新 VM；不保证单个原始输入能复现这种增长。

实际命令、结果及测量限制见[验证报告](runtime-diagnostics-validation.md)。
