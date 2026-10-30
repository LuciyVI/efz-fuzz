# EFZ：引擎性能剖析 v2（2026-10-04）

[English](../../engine-performance-profile-v2.md) · [Русский](../ru/engine-performance-profile-v2.md) · [Español](../es/engine-performance-profile-v2.md) · **简体中文** · [所有语言](../README.md)

## 1. 执行摘要

保存的 900 秒 Cowboy 数据：`none` 269.54 exec/s、ETS 107.87、bitmap-v2
64.74、OTP public 103.36。因此覆盖本身不能解释与外部 `erlang_fuzzer`
（约 19k exec/s）的差距；后者进程内执行及 fuzz 策略不同。此处未新跑 900 秒。

两次反序短测**固定重放同一 1000 输入**：完整 no-op EFZ 490.69 exec/s
（2037.9 µs/输入），Cowboy/none 461.66–496.88（2166.1–2012.6 µs）。
ETS、bitmap、OTP public 范围分别 214.87–220.21、89.64–91.75、
364.67–416.51 exec/s。全部输入 SHA256 为
`16FD09EF19D76F70ECC4E2000038632E30186175A3A6CA85F9FDC7A107B5F814`。
顺序和主机负载改绝对时间；以下差值是两次范围，不是隔离 primitive 精确成本。

逆序 OTP：`code:get_coverage/2` 5.4 µs/输入（0.228%）、转换14.8（0.629%）、
reset+read+conversion+novelty+merge 共24.0（1.022%）。仅 trace setup 约
942 µs（40.1%）。让 OTP 覆盖紧凑/不透明的 API 在此管线理论上限约1.01×。
首个工程试验应查 trace 生命周期及保持隔离的替代，不是 OTP 内部。
ETS 仍默认，bitmap-v2 仍实验/参考。

## 2. 保存的 15 分钟结果

来源：`artifacts/cowboy-long-bench/engine-20261004T063922Z-{none,ets,bitmap,otp_native_public}/summary.csv`
及 `samples.csv`。Cowboy/种子 corpus 相同；独立演化历史**不是**相同输入比较。

| 模式 | 执行 | 平均 exec/s | 中位 | P10–P90 | 首/末60秒 | 最终 corpus | 覆盖单位 |
|---|---:|---:|---:|---:|---:|---:|---|
| none | 242589 | 269.54 | 276.10 | 222.10–287.90 | 315.73/220.78 | 12 | 禁用 |
| ETS | 97081 | 107.87 | 108.10 | 105.10–110.20 | 106.18/106.13 | 82 | 296 EFZ 探针 |
| bitmap-v2 | 58265 | 64.74 | 64.90 | 61.40–68.00 | 63.40/64.83 | 82 | 296 EFZ 探针 |
| OTP public | 93030 | 103.36 | 59.10 | 20.00–196.80 | 195.12/176.88 | 64 | 336 OTP 行 |

ETS/bitmap 最终覆盖数及 corpus 大小相同，不证明输入相同。OTP 行不能与结构
探针比数量。外部约19k exec/s 见[Cowboy 长测](cowboy-long-benchmark.md)，
衡量另一引擎和反馈策略。

## 3. No-op 引擎上限与无覆盖 Cowboy

真实 `efz_noop_target:run/1` 位于
[test/targets/engine/efz_noop_target.erl](../../../test/targets/engine/efz_noop_target.erl)。
`--target noop --backend none` 与 Cowboy 共用
[worker](../../../src/efz_worker.erl)、[executor](../../../src/efz_executor.erl)、
[guardian](../../../src/efz_guardian.erl)、corpus、清理。`none` 跳过覆盖存储/reset/
read/novelty，属 benchmark/debug。1000 输入固定重放、`+S 2:2`、profile：
no-op 490.69 exec/s、墙钟2037.9 µs/输入、**测量迭代均值1988.2 µs**。
分层完整活动 microbenchmark 300 重复得418.39 exec/s；短测调度波动使二者非
同一上限。Cowboy/none 不同瞬时条件甚至496.88。因此490.69是测量，不是严格上界。

同字节 forward Cowboy/none 496.88、2012.6 µs，reverse461.66、2166.1。
Reverse none 目标 body 约40 µs/迭代；no-op 几乎不工作。整周期差还含调度、
加载、输入特定工作，因此 Cowboy 减 no-op 仅近似目标成本。

## 4. 迭代数据流与进程生命周期

演化运行中 `efz_worker:handle_info/2` 选输入并变异。`execute_allowed/4`
哈希/检查，`execute_checked/4` 调 `efz_executor:run/4`。
`efz_executor:run_pinned/4` 每 case 创建 monitored guardian。`efz_guardian:start/6`
建 trace session、共享状态基线、monitored coordinator/root。
`efz_executor:invoke/4` 在 root 调目标，发结果给 coordinator。
`efz_guardian:cleanup/2` 杀受控树，`loop/1` 排空 DOWN/trace barriers，`efz_guardian:finish/2`
封覆盖、毁 trace、查共享状态。worker 再调用 `efz_feedback:evaluate/3`、`retain/3`，记录 decision。

```text
持久 EFZ worker
  -> spawn_monitor guardian -> trace session / coordinator / root
  -> root 调用目标 -> coordinator 分类 -> guardian 清理/排空
  -> guardian 结果 + DOWN -> worker 反馈/语料 -> 下一迭代
```

每普通 case 在 [executor](../../../src/efz_executor.erl) 与
[guardian](../../../src/efz_guardian.erl) 至少建 guardian/coordinator/root 三进程、
三次 spawn_monitor，另有 caller/guardian/root monitor。Worker 持久，应用/
supervisor links 属活动，不每 case 新建。至少发生 coordinate、ready、start、
target-result、coordinator-done、guardian-result、guardian-DOWN、next-iteration；
额外 DOWN、trace-delivered、execution-context、后代事件使固定消息数无效。
Guardian receive 检查执行与有界清理期限。每次分配 context/metadata、hash、
set、trace、monitor、三进程 heap。复用 worker/corpus/global 不免此成本。

## 5. 分阶段 profile 与计数

[efz_config:defaults/0](../../../src/efz_config.erl) 的 `performance_profile` 默认
false。`--profile` 时 [efz_perf_profile](../../../src/efz_perf_profile.erl) 记录调用、
总量、均值、中位、p90/p99；关闭路径不读时钟。worker、guardian、
[OTP collector](../../../src/efz_cov_native_public.erl) 发布独立嵌套时间。
`profile.term`、`scripts/print_engine_profile.escript` 展示。
表用**当前逆序固定 OTP**（`v2-current-reverse-otp_native_public`）：迭代均值
2351.0 µs；含启动/报告墙钟2400.9 µs/输入。

摘要存 [engine-otp-fixed-profile-v2-2026-10-04.term](../../performance/engine-otp-fixed-profile-v2-2026-10-04.term)。

900秒 none 269.54 exec/s 约3710 µs/执行，但未 profile。短测百分比**不能**套
到该长测：变异/corpus 演化、调度、采样不同。270 exec/s 的精确拆分需手动
profile 长活动。

| 阶段 | µs/迭代 | 迭代百分比 | 边界 |
|---|---:|---:|---|
| 变异 | 0 | 0 | 固定重放关闭；演化20秒约3.9 µs |
| 输入准备 | 1.4 | 0.06 | SHA256/检查/元数据 |
| Worker/executor 含内层 | 2162.0 | 91.96 | 含 guardian/目标 |
| Guardian 含内层 | ~1908 | ~81.2 | prepare+目标+清理+finish+间隙 |
| Guardian 内 trace setup | 942.3 | 40.08 | 每迭代 session |
| 覆盖 reset | 0.5 | 0.02 | 四模块 `code:reset_coverage/1` |
| 目标 body | 33.7 | 1.44 | Cowboy parser |
| `code:get_coverage/2` | 5.4 | 0.23 | 四模块 |
| 覆盖转换 | 14.8 | 0.63 | Erlang terms 到 bitset |
| 新颖性 | 3.1 | 0.13 | native bitset |
| Global merge | 0.28 摊销 | 0.012 | 34 次 merge |
| Feedback 含内层 | 129.0 | 5.49 | 含 novelty/merge、发现时 decode |
| Corpus 决定 | 0.1 | 0.005 | 固定重放禁止入库 |
| Corpus 存储 | 0 | 0 | 此处关闭，发现在别处测 |
| 等待清理 | 108.1 | 4.60 | 等写者静止 |
| Guardian finish 含内层 | 583.8 | 24.83 | trace destroy、共享检查、覆盖读取 |
| Worker 未计部分 | 58.4 | 2.49 | 消息/调度、未计时代码 |

**勿相加嵌套行。** Worker 顶层加 worker_unaccounted 按构造等于总时间。
Guardian 未计均值111.3 µs（约4.7%迭代）；`executor_outer_us`253.6
（约10.8%），含 preflight、交接、结果/DOWN 等待及 guardian 测量外调度。
已标识、不埋“其他”，但组成未逐个计时。顶层未计比例低于10%；各阶段墙钟仍含
调度暂停和 profile 开销。

## 6. Worker/guardian 合成分层

可复现[生命周期微基准](../../../bench/engine_lifecycle.escript)，OTP27、`+S 2:2`；
原结果 `docs/performance/engine-lifecycle-v2-2026-10-04.term`。

| 层 | 迭代 | µs/调用 | 说明 |
|---|---:|---:|---|
| 直接 no-op | 100000 | 0.006 | JIT/紧循环下界，可能有编译器效应 |
| 持久 actor 消息往返 | 10000 | 0.636 | 单 actor，无隔离 |
| Spawn+monitor no-op | 1000 | 1.195 | 单进程，无 guardian/trace |
| 真 `efz_executor:run/4` | 300 | 2456 | 完整 guardian，无 worker/corpus loop |
| 完整 EFZ 固定活动 | 300 | 2390 | 含 worker/feedback；调度波动不宜相减 |

消息/单 spawn 与完整 executor 差远大于目标调用。这些契约不同，不能机械相减
给单一保证定价。原 term 存 caller reductions、VM GC delta。全部 trace 消息、
heap 分配、monitor 的精确动态数量**未测**；上文静态界来自源码。

## 7. 变异与 corpus 成本

`bench/engine_mutation_micro.escript`、51字节固定输入、`+S 2:2`：1000 random
中位631 µs，10k6529，100k65605（约152万变异/s），100k平均输出约51.0字节。
单次低于1µs计时分辨率。Staged dictionary 1000 visit 中位601 µs，产398候选。
原重复、reductions、进程内存delta、输出字节在
`docs/performance/engine-mutation-v2-2026-10-04.term`；delta非精确分配数。
此负载仅变异无法解释引擎几百exec/s。

`bench/engine_corpus_micro.escript`、`+S 2:2`：选择/取输入1.21µs，SHA256
0.18，元数据编码0.25，内存去重1.03，插入2.74。30次带fsync初始
`efz_corpus_store:save/4` 平均2543µs，磁盘重复187。原数据
`docs/performance/engine-corpus-v2-2026-10-04.term`，I/O依赖/tmp文件系统/缓存。
普通无novelty的 [efz_worker:retain/3](../../../src/efz_worker.erl)**不**调用 `efz_corpus:add/2`；
固定重放还刻意禁止增长。新发现可能毫秒级持久化，但非每次落盘。

后续10秒演化OTP（`v2-current-otp-timeseries-10s`），4152执行，corpus12→45。
`corpus_store`新嵌套timer总155716µs，摊37.5µs/迭代（1.56%）；多数不保存，
中位/p90为0。`corpus_decision`包含该时间。短预热不是900秒无新颖性平台。

每秒阶段数据在 [engine-otp-stage-samples-v2-2026-10-04.csv](../../performance/engine-otp-stage-samples-v2-2026-10-04.csv)。

## 8. 固定重放：等输入与 backend 开销

[Cowboy runner](../../../scripts/cowboy_long_bench.escript) 的 `--fixed-replay N`
从同12种子与random seed确定性生成序列，保存精确 `replay-inputs.term` 和SHA256，
直接交持久worker。[efz_worker:handle_info/2](../../../src/efz_worker.erl)的benchmark
分支跳过校准/变异、顺序推进；[execute_result/6](../../../src/efz_worker.erl)仍算
feedback/global，但禁止入corpus，故feedback不选下一输入。结果验证恰N次、
completed、corpus12。仅benchmark，不改普通fuzz。测试覆盖重复输入、默认关闭
profile、开关profile决定相同。

两组1000输入均 `ERL_FLAGS='+S 2:2'`、`--profile`、同上SHA256。目录
`artifacts/cowboy-long-bench/v2-current-forward-*` 和 `v2-current-reverse-*`。
墙钟在efz:start/1前开始，含启动/报告；阶段比例用计时迭代。**组内及组间**输入
一致，BEAM因插桩不同；加载/顺序/外部负载仍影响。旧 `v2-fixed-*` 在start后才
计时；`v2-final-*` 早于单独corpus_store计时，两者不入表。

路径/哈希摘要：[engine-fixed-replay-v2-2026-10-04.term](../../performance/engine-fixed-replay-v2-2026-10-04.term)。

| 模式 | 正序exec/s | 正序µs/输入 | 逆序exec/s | 逆序µs/输入 |
|---|---:|---:|---:|---:|
| No-op + none（另跑） | — | — | 490.69 | 2037.9 |
| Cowboy + none | 496.88 | 2012.6 | 461.66 | 2166.1 |
| Cowboy + ETS | 220.21 | 4541.1 | 214.87 | 4654.1 |
| Cowboy + bitmap | 91.75 | 10899.1 | 89.64 | 11155.5 |
| Cowboy + OTP public | 364.67 | 2742.2 | 416.51 | 2400.9 |
| Cowboy + OTP native no read | 473.53 | 2111.8 | 448.82 | 2228.1 |

配对 mode-none：ETS约 **+2.53/+2.49 ms/输入**，bitmap **+8.89/+8.99 ms**，
OTP public **+0.73/+0.23 ms**（正/逆）。Native no-read +0.10/+0.06ms。
OTP差波动远大于get_coverage时间，来源未隔离。ETS约2.1–2.2×慢，bitmap
5.1–5.4×。这是总模式差，**非纯覆盖primitive开销**。特别是结构/native
build的trace setup不同，feedback/global也不同。

同输入bitmap仍慢于ETS，逆序目标body含数毫秒，而ETS约0.1ms，guardian finish
也更贵。未试bitmap-v3，v2仍实验/参考。

## 9. OTP native 分解与不读取对照

`otp_native_no_read` 是benchmark别名 `none_instrumented`：Cowboy以
`line_coverage` 编译，但迭代EFZ用 `coverage_backend => none`。Preflight可
准备时查看一次，迭代不reset/read/convert/compare/merge。目标及种子/变异
与OTP public匹配。近似分离有native插桩和提取/反馈，不改生产backend。

逆序public对no-read总差 **172.8µs/输入**，正序 **630.4µs**。逆序实测
reset+get+conversion+novelty+merge24.0µs，inclusive反馈129.0。
其余含schema、诊断/新行解码、context/result及调度差，不自动归get_coverage。
单独 `code:get_coverage/2` 为 5.4µs（0.228%），`get_coverage+conversion` 为 20.2µs（0.857%）。此波动限制端到端归因
精度。

## 10. OTP 吞吐波动与输入大小

旧900秒OTP早期180–200exec/s，约300–660秒降17–26，后恢复约180，未见
corpus/coverage相应回落。低谷多数时间corpus61–62、覆盖333–334，进程52，
run queue1，内存约46–48MB。关键是前中后reductions/执行均约83k，GC/执行
约3.1，削弱输入复杂、更多行/发现或GC频率解释。旧运行**未**记录输入大小、
阶段时间、CPU steal/throttle或每scheduler利用率。主机/VM调度变慢合理但
**未证实**；机制仍开放。

新20秒 `+S 2:2` OTP（`v2-otp-timeseries-20s`）7445执行，均372.18exec/s。
`samples.csv`、`stage-samples.csv`记每秒吞吐/corpus/coverage/发现/GC/runqueue/
平均输入字节/每执行阶段。预热吞吐约255→380–399，trace setup1518→975–1044µs，
get保持5.6–7.3，转换15–19。短测**未复现**长低谷。此窗相关性被并发发现及
变化的scheduler/trace成本混杂，不确定因果。若复发需手动长诊断
`--profile --sample-interval 10`：

```sh
./scripts/run_cowboy_long_bench.sh --backend otp_native_public \
  --duration 900 --seed 424242 --profile --sample-interval 10
```

仅准备**手动**命令，此处未执行。复发时对齐stage CSV与OS CPU节流/steal、
每scheduler利用率和GC暂停。现遥测不能区分这些原因。

只有profile时 [efz_worker:finish_iteration/1](../../../src/efz_worker.erl)采输入桶。
当前逆序固定OTP：

| 输入字节 | 数量 | 平均目标µs | 平均迭代µs |
|---|---:|---:|---:|
| 0–64 | 583 | 20.9 | 2344.9 |
| 65–256 | 334 | 57.8 | 2356.9 |
| 257–1024 | 83 | 27.2 | 2370.3 |
| 1025–4096 | 0 | 未测 | 未测 |
| >4096 | 0 | 活动限制拒绝 | 活动限制拒绝 |

虽目标时间不同，各桶迭代均值差小。旧长测输入大小相关性未知。

## 11. 插桩缺口

`v2-fixed-1000-ets/target-beams/*.efz-manifest` 对以下构造记
`preserved_without_internal_probes`。Native列加载固定运行精确OTP27
line_coverage BEAM，用 `code:get_coverage(line, Module)` 查询执行行。

| 模块/源行 | 构造 | EFZ内部探针 | OTP执行行 | 影响 |
|---|---|---|---|---|
| `cowboy_http:121` | record默认值 | 无 | 无 | 两者均无内部点，周围函数探针可能触发 |
| `cowboy_http:1499` | list comprehension | 无 | 有 | OTP观察行到达，未必捕捉每种comprehension结果 |
| `cowboy_req:488,1056` | list comprehension | 无 | 有 | EFZ可能错过内部行为差异 |
| `cowboy_router:66,90,328,330` | list comprehension | 无 | 有 | EFZ可能错过内部行为差异 |

这是语义缺口，不证明OTP全局更丰富：EFZ可区分同一行不同结果，而OTP行覆盖合并。
本任务未改插桩放置。

## 12. 外部 erlang_fuzzer 与持久执行

| 属性 | EFZ | 外部erlang_fuzzer | 成本与安全影响 |
|---|---|---|---|
| 执行/调用 | 新受控root内目标 | 持久进程内调用 | 外部setup少；EFZ隔离BEAM进程树 |
| 变异 | Erlang random/staged | libFuzzer | 序列/corpus压力不同 |
| Worker/guardian | 持久worker、新guardian/coordinator/root | 无EFZ guardian | EFZ支付trace/monitor/barrier |
| 覆盖/反馈 | EFZ结构或OTP行、EFZ novelty | native counters/features | 单位与接受策略不同 |
| Corpus调度 | EFZ队列/持久条目 | libFuzzer策略 | 增长/I/O不同 |
| 崩溃/超时 | 受控树和分类清理 | libFuzzer/NIF runtime | 安全契约不同 |
| IPC/进程生命周期 | 每case消息/监控进程 | 直接进程内循环 | 预期吞吐差大 |

完整no-op EFZ `+S 2:2`约2.1ms，外部约52µs/迭代，但**负载不匹配**。
Trace setup/destroy与受控进程/IPC是瓶颈；libFuzzer变异/反馈和目标调用也不同，
不支持对19k比270做因果数值拆分。

持久root需要单独安全设计：阻塞目标期限、崩溃重启、旧消息移除、字典/ETS/目标
状态reset、后代所有权、覆盖generation退役、验证所有写者真正静止。
Pool可保留退役污染worker的安全回退；进程内快模式隔离更弱须明确标注。
**未实现重设计。** 下一步是有界trace生命周期实验加确定crash/timeout/
late-writer测试，不因microbenchmark删除guardian检查。

## 13. Amdahl 分析与默认 backend 决策

当前逆序 OTP 中 `get_coverage+conversion` 占 0.857%，若二者完全免费，理论上限为
`1/(1-0.00857) ≈ 1.009×`；完整native管线1.022%，约1.010×；连inclusive
feedback5.49%全消也仅约1.058×。这些界特定于负载，不解释长测20–200波动。

测量潜力最大的下一步是剖析/原型化更便宜但**保持隔离的trace生命周期**，再以
同输入benchmark并验证crash/timeout/后代清理。减少共享检查或IPC须各自测量
与安全证明。OTP覆盖API优化/patch暂低优先；未恢复DWARF/原指针研究。
ETS保持结构语义保真故默认；otp_native_public为行语义不同、长波动未解决的
可选项。bitmap-v2长测及固定均慢ETS，继续实验/参考。

## 14. 复现与验证

短固定重放：

```sh
for backend in none ets bitmap otp_native_public otp_native_no_read; do
  ERL_FLAGS='+S 2:2' ./scripts/run_cowboy_long_bench.sh \
    --backend "$backend" --fixed-replay 1000 --seed 424242 --profile \
    --out "artifacts/cowboy-long-bench/my-fixed-$backend"
done
```

No-op及组件bench：

```sh
ERL_FLAGS='+S 2:2' ./scripts/run_cowboy_long_bench.sh --backend none \
  --target noop --fixed-replay 1000 --seed 424242 --profile \
  --out artifacts/cowboy-long-bench/my-fixed-noop
ERL_FLAGS='+S 2:2' escript bench/engine_lifecycle.escript /tmp/efz-engine-lifecycle.term
ERL_FLAGS='+S 2:2' escript bench/engine_mutation_micro.escript /tmp/efz-mutation.term
ERL_FLAGS='+S 2:2' escript bench/engine_corpus_micro.escript /tmp/efz-corpus.term
```

改后检查：`ERL_FLAGS='+S 1:1' rebar3 eunit` **260 PASS**，CT **3 PASS**，
xref/Dialyzer **PASS**。新EUnit检查固定重放、none、默认关闭profile、
profile行为和输入桶。none/OTP public/no-read固定均无crash/timeout；
`~w`写term即使任意变异binary也可consult。早期45秒telemetry目标执行完成，
但写样本时不等长zip失败；修复exporter后20秒通过。失败运行不算成功遥测。
长测泄漏行为和OTP中期变慢机制仍未验证。
