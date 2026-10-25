# EFZ：单次迭代成本分析

[English](../../engine-performance-profile.md) · [Русский](../ru/engine-performance-profile.md) · [Español](../es/engine-performance-profile.md) · **简体中文** · [所有语言](../README.md)

含 15 分钟结果、固定重放及 OTP 非平稳性分析的下一阶段见
[engine-performance-profile-v2.md](engine-performance-profile-v2.md)。

## 1. 执行摘要

实验性 `coverage_backend => none` 保留 EFZ 常规变异、语料、worker、guardian、超时与清理，
但不收集覆盖。此主机上的短 30 秒 Cowboy 运行在无插桩时达 **60.70 exec/s**；
no-op 目标开启分析达 **63.13 exec/s**，关闭分析达 **63.70 exec/s**。
16 调度器下 no-op 平均迭代成本 **15.82 ms**。
这是*此配置和主机负载*的上限，不是 EFZ 架构极限：`+S 1:1` 下独立 10 秒 no-op 运行
达 **163.88 exec/s**，平均迭代 **6.09 ms**。
未将单次最短迭代测量为可靠特性。

`otp_native_public` 分析中，`code:get_coverage/2` 占 **15.25 µs/迭代（0.081%）**。
reset、get、转换、新颖性和合并总和 **74.77 µs（0.398%）**。
主要实测成本是 guardian 生命周期：追踪设置、追踪销毁及共享状态检查。
目前没有依据将 compact/opaque OTP coverage API 补丁作为 EFZ 下一加速步骤。
这是本地阶段分析；稳定吞吐结论需要配对重复运行。

## 2. 背景与复现

用户 15 分钟结果：ETS 54.66、bitmap-v2 27.56、`otp_native_public` 96.59、
外部 `erlang_fuzzer` 19019.08 exec/s。
原始运行依次保存在 `artifacts/cowboy-long-bench/20261003T065733Z-ets/`、
`20261003T065741Z-bitmap/`、`20261003T065750Z-otp_native_public/`、
`20261004T053054Z-erlang_fuzzer/`。
最后一个使用 libFuzzer 变异、进程内循环及自身反馈与语料特征。
它与 OTP public 之间约 197 的比值**不是**覆盖成本估计。

下方短运行使用 OTP 27.0、ERTS 15.0、x86_64 Linux、16 在线调度器、Cowboy 2.19.0、
相同 12 种子、种子 424242、时长 30 s，除非另注均启用 `--profile`。
主机有负载（load average 约 18–22）。
首次 no-op/none 仅 17.60/19.57 exec/s，trace setup 为 35.4/31.1 ms；
重复达到 63.13/60.70。因此单个配对及绝对百分比不能推广到不同调度器或主机负载。
本阶段未启动任何 900 秒运行。

| 短工作负载 | 运行 | 执行数 | exec/s | 平均迭代 |
|---|---|---:|---:|---:|
| No-op、none、profile | `20261004T061445Z-noop-none` | 1895 | 63.13 | 15,819 µs |
| No-op、none、无 profile | `20261004T061406Z-noop-none` | 1912 | 63.70 | — |
| Cowboy、none | `20261004T061152Z-none` | 1822 | 60.70 | 16,455 µs |
| Cowboy、none_instrumented | `20261004T061050Z-none_instrumented` | 1799 | 59.93 | 16,676 µs |
| Cowboy、ETS | `20261004T061244Z-ets` | 1172 | 39.03 | 25,606 µs |
| Cowboy、bitmap-v2 | `20261004T061324Z-bitmap` | 734 | 24.43 | 40,916 µs |
| Cowboy、OTP public | `20261004T061001Z-otp_native_public` | 1598 | 53.23 | 18,768 µs |

`none_instrumented` 用 `line_coverage` 编译 Cowboy，但不调用 reset/get/feedback。
一组短配对与原始 `none` 差异很小，未与噪声分离。
不应把这些运行当作相同模糊历史，按语料或覆盖数直接比较。

## 3. 迭代架构与 IPC

`efz_worker:handle_info/2` 选择并变异语料输入；`execute_allowed/4` 计算哈希并验证输入；
`execute_checked/4` 调用 `efz_executor:run/4`。
`efz_executor:run_pinned/4` **每迭代**创建并监视 guardian，等待结果及 `DOWN`。
`efz_guardian:start/6` 创建 trace session、采集共享状态基线、创建受监视协调器和根进程、安装上下文；
`efz_executor:invoke/4` 在根进程执行目标。
协调器分类结果，guardian 终止树并等待 `DOWN`/追踪屏障，
随后 `efz_guardian:finish/2` 收集覆盖、销毁 trace session、检查共享状态。
worker 调用 `efz_feedback:evaluate/3`，再 `retain/2` 和 `accepted/5`。
活动 worker 跨迭代持久存在；guardian、协调器和根进程每次重建。
目标可按需创建额外后代。

最小正常路径含 3 次 `spawn_monitor`（guardian、协调器、根），
额外 `monitor` 调用（caller/root/guardian）、通过 spawn 闭包传递的 worker→guardian 消息、
`coordinate`、`coordinator_ready`、`start_owned`、`target_result`、`coordinator_done`、
guardian→worker 结果，以及相应 `DOWN` 和追踪屏障事件。
精确消息数依运行时采样器、追踪及后代而变；**未证明**每案例固定 IPC 数。
即便 no-op，`efz_guardian:cleanup/2` 也终止接纳树；这是安全模型，不是覆盖开销。
`efz_cov_integrity:trace_setup/3` 和 `efz_cov_integrity:close/0` 在 `none` 仍检查生命周期。

## 4. 无覆盖上限与 no-op 测试驱动

`none` 要求 `automatic + presence`，不加载覆盖模式、不开存储，
不调用 `code:reset_coverage/1` 或 `code:get_coverage/2`。
`efz_feedback:evaluate/3` 返回无新点，但保留校准及目标故障保留原因。
语料选择、变异和保留决策仍走普通路径。
`none` 是性能和调试基线，不是生产覆盖引导模式。
`none_instrumented` 可近似估计 OTP 行插桩成本。
no-op `test/targets/engine/efz_noop_target.erl` 经真实 EFZ 引擎执行 `run(_Input) -> ok`。

16 调度器 no-op：开启分析为 63.13 exec/s、15,819 µs/迭代。
`ERL_FLAGS='+S 1:1'` 下 10 秒运行 `20261004T062318Z-noop-none`
达到 163.88 exec/s、6093 µs/迭代，trace setup 2479 µs。
这显示 trace setup 对调度器设置和负载敏感。
`none` 中 Cowboy 目标在 guardian 内平均 104 µs，no-op 2.25 µs；
因运行未配对，不能把完整周期差异仅视为目标成本。

短复现命令：

```sh
./scripts/run_cowboy_long_bench.sh --backend none --target noop --duration 30 --seed 424242 --profile
./scripts/run_cowboy_long_bench.sh --backend none --duration 30 --seed 424242 --profile
./scripts/run_cowboy_long_bench.sh --backend none_instrumented --duration 30 --seed 424242 --profile
./scripts/run_cowboy_long_bench.sh --backend otp_native_public --duration 30 --seed 424242 --profile
escript scripts/print_engine_profile.escript artifacts/cowboy-long-bench/RUN_DIR
```

## 5. 阶段时间与记账

只有 `performance_profile => true`/`--profile` 启用分析。
标志关闭时 `efz_perf_profile:measure/2` 不调用时钟；摘要每阶段最多存 20,000 样本，
总时间和调用数继续累计。
median/p90/p99 位于 `profile.term`，通过 `scripts/print_engine_profile.escript` 查看。
下方为 30 秒运行均值及其占 `iteration_total` 比例。
嵌套阶段**不能相加**。

| 阶段 | No-op none µs | OTP public Cowboy µs | OTP % |
|---|---:|---:|---:|
| 语料选择 | 32.6 | 见 `profile.term` | — |
| 变异 | 12.8 | 见 `profile.term` | — |
| 整个执行器 | 15,472 | 17,909 | 95.4% |
| 整个 guardian | 15,074 | 16,753 | 89.3% |
| guardian 准备 | 9,416 | 见 `profile.term` | — |
| Trace setup（prepare 内） | 8,924 | 8,507 | 45.3% |
| guardian 完成 | 见 `profile.term` | 5,677 | 30.2% |
| Trace destroy（finish 内） | 3,039 | 见 `profile.term` | — |
| 共享状态检查（finish 内） | 1,736 | 见 `profile.term` | — |
| 清理等待 | 595 | 1,152 | 6.1% |
| 目标体 | 2.25 | 92.9 | 0.50% |
| 整个反馈 | 见 `profile.term` | 389.7 | 2.1% |
| 语料决策与保存 | 见 `profile.term` | 86.1 | 0.46% |

worker 记账将 `iteration_total` 分为语料选择、变异、输入准备、执行器、反馈、
语料决策和 `worker_unaccounted`；guardian 类似分为 prepare、target、cleanup wait、finish 和 unaccounted。
两者**按计算定义**合计 100%，不证明没有隐藏成本。
no-op 中 `worker_unaccounted` 为 293 µs，`guardian_unaccounted` 122 µs。
包括测量间隙、IPC 和调度、元数据创建、消息及没有独立计时的代码。
`executor_outer` 是执行器调用时间与 guardian total 差值，OTP 运行约 1156 µs/迭代。
进一步分析应分别测量等待 `DOWN`、调度器等待、reductions 和 GC，而非把全部称为“other”。

离散性示例：no-op `executor` median/p90/p99 = 15,112/21,497/27,289 µs，
`trace_setup` = 8,598/13,546/18,487 µs。
OTP 中 `get_coverage` = 14/17/44 µs、conversion = 38/51/79 µs、`feedback` = 324/540/1645 µs。
这些分位数属于单独阶段，不是同一迭代同步百分位。

## 6. OTP 原生细分

`20261004T061001Z-otp_native_public` 的 1599 次原生 read/reset 含校准。
每次均值：reset 1.82 µs，四模块 `code:get_coverage(line, M)` 15.25 µs，
转换 41.26 µs，新颖性 15.88 µs。
合并执行 34 次，每次 26.4 µs，摊销约 0.56 µs/迭代。
五阶段总和 74.77 µs/迭代，占墙钟 0.398%。
`native_read` 20.5 µs 已含 get 和模式检查，不能与 `get_coverage` 相加。
`feedback` 389.7 µs 含新颖性、新行解码、模式检查及决策形成，不能整体与其嵌套阶段相加。
即使消除全部实测公开覆盖流水线，本分析中加速也不超过约 0.4%。
这是此运行 Amdahl 上界，不是新 OTP API 预测。

## 7. 变异与语料

`bench/engine_mutation_micro.escript` 使用固定 51 字节输入：
一次随机变异中位数 1 µs（100 样本，分辨率 1 µs）；
1000 次随机变异每批中位数 879 µs（10 批，865–918），约 1.14 百万变异/秒；
1000 次 staged 字典计划访问中位数 654 µs（10 批，每批 398 候选），**不是**1000 个现成变异输入。
原始结果：`docs/performance/engine-mutation-2026-10-04.term`。
这是本地变异估计，不是与 libFuzzer 内部实现比较。
随机变异不是当前 no-op 上限的主要限制。
分析开启时，staged worker 的 `mutation` 阶段还测量 `efz_mutation_plan:next/2`。

每次随机迭代执行 `efz_corpus:select/0`；`efz_worker:execute_allowed/4` 计算输入 SHA256；
`efz_worker:retain/3` 决定保留。
无新颖性时反馈返回 `equivalent_coverage`，不写新语料条目。
OTP 运行的 `corpus_decision` 86.1 µs/迭代**包含**偶发发现及文件系统写入，
不是纯无新颖性路径成本。
选择、哈希及保留需用固定历史的独立受控基准估计 I/O；
现有数据不能可靠估计最大磁盘写入成本。

## 8. Worker/guardian 成本与主要瓶颈

no-op 运行中主要实测、不重叠子阶段：

| 阶段 | µs/迭代 | 比例 | 候选与风险 | 完全消除时上限 |
|---|---:|---:|---|---:|
| Trace setup | 8924 | 56.4% | 技术试验：复用 trace session；对后代控制风险高 | 2.29× |
| Trace destroy | 3039 | 19.2% | 与 setup 联合试验；过期事件风险高 | 1.24× |
| 共享状态检查 | 1736 | 11.0% | 测量组件后寻找等价实现；漏掉污染风险高 | 1.12× |
| 清理等待 | 595 | 3.8% | 仅证明静止后才缩减；晚到写入者风险高 | 1.04× |
| Executor outer/IPC | ~398 | ~2.5% | 单独测量结果与 `DOWN` 等待；中风险 | ~1.03× |

上限分别用 Amdahl 为各阶段计算，**不是**可达加速预测。
setup+destroy 合计约 11.96 ms（约 75.6%）；若不付替代成本地消除两者，理论上限约 4.1×。
**不替换保证就移除它们**不可接受。
实际第一步是有限研究 trace session 创建和复用，并证明边界；第二步分析 `shared_state/0`。
这是研究任务，不是现成修改。

短 bitmap 运行 24.43 exec/s，`target_us` 15.24 ms，对比 ETS 0.32 ms、OTP public 0.093 ms。
变异历史不同，不构成因果证明，但位图下次优化前需要相同输入的独立源码命中路径分析。
本阶段未改 bitmap/ETS 实现。

## 9. EFZ 与外部 erlang_fuzzer

| 属性 | EFZ | 外部 `erlang_fuzzer` | 影响与可迁移性 |
|---|---|---|---|
| 变异 | Erlang random/staged | libFuzzer | 输入历史不同；替换可改变语料演化 |
| 执行 | 每案例 guardian/root | 进程内循环 | EFZ 成本更高，但隔离 BEAM 进程树 |
| 进程模型 | 持久 worker，新 guardian/协调器/根 | 持久驱动 | 引入持久根改变崩溃和超时隔离 |
| 覆盖 | EFZ 探针或 OTP 行 | 原生覆盖特征 | 语义不同，计数不等价 |
| 语料与反馈 | EFZ 新颖性和保留 | libFuzzer 策略 | 不能直接比较接纳 |
| 清理 | kill、DOWN、追踪屏障、共享检查 | 进程重置或复用 | EFZ 为静止和诊断付费；无契约不可移除 |
| IPC | 多条消息和监视器 | 直接调用 | 预期存在开销差异 |
| 持久性 | 新执行树 | 重复使用进程内目标 | 在不同安全模型下复用可能加速 |
| 崩溃和超时 | 受控树内 EFZ 分类 | libFuzzer/NIF 运行时 | 保证及故障类型不同 |

197× 差距不能主要归给单个组件。
最明显的 2–3 来源是每案例 guardian/trace 生命周期、带 IPC 和清理的受控进程树，
以及完全不同的进程内变异、反馈、语料模型。
测量确认第一项在 EFZ 内部很大，但**未测量**相同输入历史下它占与 `erlang_fuzzer` 差距的份额。

## 10. 持久执行设计说明

worker 已持久，但 guardian、协调器和根不是。
持久根可减少 spawn/monitor，可能减少 trace setup，
但超时或崩溃可能遗留旧后代、邮箱消息、原生覆盖写入和共享状态。
安全池需要每执行 capability、接纳门、覆盖上下文代际、已证明静止、污染进程退役、
崩溃与超时重启及确定性屏障测试。
这些机制的成本必须测量。这是独立设计试验，不是此次补丁内容。

## 11. OTP API 决策与后续步骤

实测 `get_coverage` 占 0.081%，完整实测覆盖流水线占 0.398%，
即使包含式整体反馈也只占迭代 2.1%。
因此，**优化 OTP 覆盖 API 目前不是 EFZ 潜在加速的主要来源**。
compact binary 和 opaque check-and-advance 应延后。
下一步是在受控主机使用 `+S` 扫描，做配对可重复 trace 生命周期基准，
再做保持安全保证的小范围 setup/destroy 缩减原型。
第二候选是单独分析之后优化共享状态检查。
不决定把 `otp_native_public` 设为默认：OTP 行覆盖不等于 EFZ 结构探针，
现有 30 秒运行未证明策略或质量等价。ETS 仍为默认。

## 12. 检查与限制

`rebar3 compile`、3 项专项 EUnit、CT（3）、xref、Dialyzer 通过。
默认 16 调度器完整 EUnit：257 PASS、既有 staged 测试 2 次超时（`efz:await(10000/60000)`）；
`ERL_FLAGS='+S 1:1'` 下完整 EUnit 259 PASS，staged 模块 8 PASS。
超时与高负载主机上测试墙钟预算有关；未修改测试等待。
新测试中，开启分析与普通短 no-op 活动产生相同输入 ID 和保留原因。
none 及 OTP 运行的 `cleanup.term` 显示停止后 `efz_fuzzer`、`efz_corpus`、`efz_stats` 均为 `undefined`；
未做长期泄漏检查。
`profile.term` 每阶段上限 20k 样本，时间精确至微秒并包含分析自身扰动；
`--profile` 只应用于诊断。
外部 fuzzer 比较未控制相同输入、目标调用及安全策略。
