# 阶段 3 验证：staged 变异与精确重放

[English](../../phase3-validation.md) · [Русский](../ru/phase3-validation.md) · [Español](../es/phase3-validation.md) · **简体中文** · [所有语言](../README.md)

阶段 3 已完成所测本地契约：OTP 27.0、单 worker、单插桩目标执行进程、固定
所选 build、精确源码 clause/outcome 覆盖。Staged 显式启用。本阶段新增字节
变异和重放，不改覆盖实现或重启性能研究。以下数据是观察，不是验收常数。

## 基线与来源

改动前检查仓库配置、mutator/corpus/worker、崩溃存储、executor、prepared
验证及阶段 2/2.1 文档。无适用 `AGENTS.md`。工作树已有 tracked 改动和大量
未跟踪阶段 1–2.1 实现/证据，全部保留。无 reset、clean、暂存、commit、push、
remote 或身份变更。

基线通过 `rebar3 compile`、`rebar3 eunit`（38 项）、`rebar3 ct`（3 项）、
`rebar3 dialyzer`、`rebar3 xref`、`git diff --check`，无继承失败。
日志在 `_build/phase3-baseline`，完整输出也保留于下述持久证据。
最终 62 EUnit、同样 3 CT。

环境：Ubuntu 24.04.4 LTS、Linux 6.8.0-nyx+、x86_64-pc-linux-gnu、
Intel Core i7-1260P、OTP 27.0 / ERTS 15.0、Rebar3 3.25.0。项目/示例编译
`[debug_info,warnings_as_errors]`，facade 添加原严格 transform 和列位置选项。
不声称测其他 OTP，未加依赖。

适用 `file:consult/1` 的持久证据：

* [performance/phase3-mutations.term](../../performance/phase3-mutations.term)：每变异
  负载及活动模式五个原样本、规范化配置、输入/donor 哈希、环境、编译选项、
  artifact/build、当前源码 SHA-256、进程/VM 内存快照及 reductions。
* [performance/phase3-validation.term](../../performance/phase3-validation.term)：基线/
  最终输出、41 相关 source/config/test/script 哈希、前后文件身份、验收/示例
  报告、完整 manifest、精确 recipe、新 VM 重放输出。报告运行引用为诊断字符串；
  持久副本省略有界验收 trace，配方不依赖这些引用。
* [examples/staged-crash.recipe](../../examples/staged-crash.recipe) 与
  [examples/staged-crash.input](../../examples/staged-crash.input)：629 字节 EFZR 和
  已验证示例的六个权威字节。

导出时核对无 profiler benchmark 源哈希与最终 runtime/planner/benchmark。
测后最后代码变更是比较 logging level 的测试断言，随后完整 EUnit 再通过；其余
仅文档/证据。Compiler、hook、context 所有权、executor、feedback、validator
与基线相同。Transform 只加四个内部模块 denylist，探针算法/版本不变。

最终测量目录 `_build/phase3-performance-verified`。较早
`_build/phase3-performance`、`_build/phase3-performance-final` 保留但不计，
因早于最终来源或与其他本地示例重叠。验证运行退出 0，无 profiler，不与其他
助手启动 Erlang 任务重叠；无关主机活动未控。

## 公开兼容性与实现

默认仍 `mutation_mode => random`，既有 behaviour 和 selector。
Prepared 与原 ETS 仍默认；`coverage_backend => ets_member` 仍显式，活动/
重放可用。旧自动示例不变。旧 mutator 异常/非 binary 返回现在以基础设施停止，
不计目标 bug。

`mutation_mode => staged` 启用 `mutation` map，拒绝旧自定义回调和 random
误传选项。省略 `max_iterations` 为 1,000，最大 1,000,000；显式 infinity
拒绝。校准另计，其他限制/语义/顺序见 [mutations.md](mutations.md)。

原生操作：连续 1/2/4-bit 翻转、对齐 1/2/4-byte 反转、显式 wrapping/端序的
8/16/32 位算术、版本化整数边界、literal 覆盖/插入、非空删除/块复制、字典
覆盖/插入、内容身份 splice 和这些操作的有界 havoc 栈。

纯应用、选择、按内容阶段状态、donor/seed 选择和执行分离。确定阶段是惰性整数
游标。Corpus rounds/stage lanes 显式有界，增长不能无限推迟旧项。
Skip 推进 cursor 或 RNG；有限 attempt/idle 防无执行进展重试。字典/配置活动内
固定，`exsplus` 显式传状态，日志/目标随机性不消耗它。

保留把版本 recipe 附原元数据。默认拒绝处理不无限保留完整配方，trace 有界。
配方存实际 primary/donor/token 字节与有序操作，不仅 RNG。EFZR 导入先验证
有界纯数据再 ETF 解码。再生不需目标/plan。执行需调用者选目标/工件及兼容 build，
新建 plan，用原 executor。见 [replay.md](replay.md)。

## 具体覆盖与重放证据

普通 `examples/staged/efz_staged_parser.erl` 选定编译后有七函数 clause
探针，源码无 EFZ 调用。以下均用 build：

```text
4c53c8d203bf5fca774d78fee2122a75419b86ba8f807cc3ffbb5d96339e0a5e
```

确定性集成用真实生产阶段 `[dictionary_insert,boundary,arithmetic]`、seed
`{17,23,41}`、主种子 `<<0>>`、200 预算，不用旧 scripted mutator。
校准先观察 probe 5，不算变异发现。

| 保留字节 | 父节点 | 实际操作 | 新探针 / 源码 | 决定 |
|---|---:|---|---|---|
| `<<"TOKEN",0>>` | 条目 1，`<<0>>` | `{dictionary_insert,0,<<"TOKEN">>}` | 1，`run/1`，行 4 列 1 | `new_coverage` |
| `<<128>>` | 条目 1，`<<0>>` | `{set_integer,0,8,big,128}` | 3，`run/1`，行 6 列 1 | `new_coverage` |

集成报告：1 校准、200 变异、4 发现、191 等价拒绝、5 崩溃观察、1 签名组、
0 基础设施/超时。还断言首次人工崩溃后有发现，并从 retained recipe 再生精确
字节。Probe 数字来自 manifest 观察，核心不硬编码 fixture ID 或保留例外。

完整示例另启 havoc/splice，200 执行、5 发现、188 拒绝、7 崩溃观察、1 组、
0 基础设施/超时。区分 243 visits、233 mutation attempts、320 组成尝试、
72 skipped operations、43 无候选 visits、200 生成/执行候选。Skip reason
还含最终取消栈，不等于 skipped-operation。

保存的人工崩溃为 `<<"BOOM!",0>>`（hex `424f4f4d2100`），SHA-256：

```text
1732ef36d864988423a5275aec30b90b55e3405cc798c709e318c867797ad64b
```

新 VM 再生与 `cmp` 重建全部六字节。另一个 VM 编译显式目标、加载配方预期
build、执行 raw，返回 `{crash,error,artificial_staged_exception,Stack}`、
`coverage_status => ok`、probe 2，栈指行 5。证明字节与确定示例结果，不保证
时序敏感目标。

Probe 2 在目标终止后仍在 crash result。失败决定
`retention_reason => target_failure, new_probes => []`；成功覆盖不含 2。
这保留原策略：崩溃观察不抑制后续成功 novelty。签名组非已证明独立 bug。

旧自动示例 random 不改：500 执行、1 校准、5 发现、493 拒绝、2 崩溃、1 组、
0 基础设施/超时。这是本次观察；默认无 seed 的 corpus 选择可不同于旧报告。

## 有界变异成本

从根目录复现：

```sh
rebar3 compile
ERL_FLAGS='+S 4:4' escript bench/mutations.escript _build/phase3-performance-reproduce
```

验证运行 `+S 4:4`（四在线 schedulers）。每例完整 5,000 候选批预热并验证
每实际操作序列与输出。五计时批各从同配置新 plan 开始，对 warmup 核对候选数、
visit 数和 CRC32 流。配置/字典规范化、fixture 构建不计时；候选哈希、操作
规划/应用、来源构建、CRC 消费计入。EFZR 完整编码及目标执行不计。测试无机器
性能阈值。

每负载两个静态不同输入：按所列大小重复 `0,1,2,3`，donor 首字节反转。
输入上限 4,096，默认 block 128、depth 8、delta 8、TOKEN/BOOM!、seed
`{17,23,41}`。全部真生成 5,000 候选。短/中/近界用 bitflip/arithmetic/havoc；
字典用两字典 stage；splice、havoc 用各自单阶段。无目标/probe 观察或 manifest
扫描。

| 变异负载 | 输入字节 | 中位 µs / 5,000 | 最小–最大 µs | 候选/s |
|---|---:|---:|---:|---:|
| 短 | 4 | 37,396 | 36,364–39,283 | 133,704 |
| 中 | 1,024 | 32,538 | 30,792–34,778 | 153,667 |
| 接近配置最大 | 4,095 | 55,712 | 55,276–57,220 | 89,747 |
| 字典插入/覆盖 | 1,024 | 17,950 | 16,884–22,325 | 278,552 |
| Splicing | 1,024 | 25,986 | 25,224–27,787 | 192,411 |
| Havoc | 1,024 | 51,818 | 48,236–51,889 | 96,492 |

此样本短混合不比中更快：适用操作、重试和中间大小不同。这是负载结果，不是
纯大小 scaling 声明。原时间保留在 `.term`。

## 有界端到端比较

两模式同七探针普通示例、初始 `<<0>>`、timeout 100 ms、原 ETS、prepared、
**500 次变异目标执行**加一次校准。各丢弃 100 次 pilot，五轮交替顺序。
编译（一次 8,921 µs）与最终打印不计变异时间；这是启动观察，非重复估计。

旧 random `random_seed => {17,23,41}`、`selection_seed => {101,109,113}`。
Staged 同 seed、示例五阶段、输入64、block/token16、havoc4、两 token。
刻意不强迫旧模式采用新限制。

| 模式 | 原变异时间 µs | 中位 µs | 最小–最大 µs | 执行/s | 发现 | 成功探针 | 崩溃 / 组 |
|---|---|---:|---:|---:|---:|---:|---:|
| 既有 random | 9169, 9916, 7503, 7786, 7257 | 7,786 | 7,257–9,916 | 64,218 | 4 | 5 / 7 | 0 / 0 |
| Staged | 14965, 17455, 15749, 16198, 15339 | 15,749 | 14,965–17,455 | 31,748 | 5 | 6 / 7 | 14 / 1 |

各模式五样本计数稳定。Staged 额外到字典分支，crash probe 不入成功覆盖。
二者无基础设施/超时。校准中位 random55 µs、staged56 µs。
含准备/报告交付/清理的完整 start/await/stop API 中位分别 8,883、17,127 µs，
原样本和校准时长另存。

此小 fixture staged 变异阶段耗时是 random 的 **2.02 倍**（吞吐约 49.4%）。
包括不同候选流、更丰富来源操作、更多 visit、14 个崩溃及工件写入，不是同输入
executor/backend 对比。额外发现不证明普遍优势；无性能目标或覆盖收益保证。
不据此重新解释阶段2.1 hook/完整 executor 数字。

## 内存与清理观察

变异 benchmark 在批前、计时批后、显式 GC 后记进程/VM 内存，读取不计时。
还记 reductions，非分配字节。GC 后保留 driver、输入/配置和先前样本摘要，
完成 plan/候选不再持有。进程内存不含所有引用的 off-heap binary。

| 负载 | 批后进程字节范围 | GC 后进程字节范围 | 每批 reductions 中位 |
|---|---:|---:|---:|
| 短 | 29,552–42,416 | 8,816 | 3,935,059 |
| 中 | 47,184–68,056 | 13,704 | 5,853,867 |
| 近上限 | 47,184–62,992 | 13,704–21,608 | 16,006,728 |
| 字典 | 101,368–142,760 | 21,608 | 3,815,738 |
| Splicing | 89,720–123,048 | 21,608–34,400 | 5,981,997 |
| Havoc | 76,096–110,048 | 34,400 | 8,022,823 |

GC 后 VM 总量 51,106,240–51,261,888 字节，无须回到相同值。这些非绝对峰值
或完整活动 retained-memory 研究，不推断泄漏。生命周期测试另证正常、timeout、
取消、caller 死亡、应用关闭释放表/进程。完成活动仍拥有 plan、corpus、recipe、
decision、可选 trace 到 `efz:stop/0`；执行观察仍按阶段2.1 独立分配清理。

计划器调度复制最小 corpus 视图、哈希内容；splice 扫描排序不同 donor。
大 corpus/嵌入 donor 因此可能更耗时及配方存储。无未测优化或缓冲复用掩盖成本。

## 回归命令与结果

以下均在本树退出 0：

```sh
rebar3 compile
rebar3 eunit
rebar3 ct
rebar3 dialyzer
rebar3 xref
git diff --check
ERL_FLAGS='+S 4:4' escript examples/staged/run.escript
escript scripts/replay.escript _build/staged-example.recipe _build/staged-regenerated.input
cmp _build/staged-example.input _build/staged-regenerated.input
escript examples/automatic/run.escript
ERL_FLAGS='+S 4:4' escript bench/mutations.escript _build/phase3-performance-verified
escript scripts/replay.escript docs/examples/staged-crash.recipe _build/from-docs.input
cmp docs/examples/staged-crash.input _build/from-docs.input
```

* Compile：警告作错误，通过。
* EUnit：**62 项通过**，含15 mutation、3 recipe、6 分组阶段3验收。
  既有 transform 语义、精确 canonical backend differential、prepared-plan
  负例、error/throw/exit、同步 kill/timeout 覆盖保留、上下文、期限、caller
  死亡、取消/关闭及反复资源生命周期全部通过。
* CT：**3 项通过**。
* Dialyzer：通过，分析26项目模块、检查278 PLT文件。
* Xref/空白：通过。未配 formatter/linter。
* README 内联字典 campaign/save/regenerate/execute 片段也在新 VM 运行通过。
  文件字典脚本覆盖另一公开路径。

既有负例刻意打印畸形 plan 进程错误和不支持 AST 诊断；它们断言错误分类并通过，
不是新失败。最终 EUnit 在 logging-level 测试新增后复跑；其他检查后无相关
runtime 源改，仍适用。未以改变预期覆盖/结果集合掩盖基线失败。

在新 VM 独立执行持久保存的崩溃字节：

```sh
erl +S 4:4 -noshell -pa _build/default/lib/efz/ebin -eval '
{ok, A} = efz_instrument:compile("examples/staged/efz_staged_parser.erl",
    #{modules => [efz_staged_parser], source_root => ".", outdir => "_build/replay-target"}),
{ok, R} = efz_recipe:load("docs/examples/staged-crash.recipe"),
{ok, Result} = efz_recipe:execute_file("docs/examples/staged-crash.input",
    efz_staged_parser, [A], maps:get(target_builds,R), #{timeout => 100}),
{crash,error,artificial_staged_exception,_} = maps:get(outcome,Result),
ok = maps:get(coverage_status,Result),
io:format("~tp~n",[Result]),halt(0).'
```

上面无 `ERL_FLAGS` 的普通示例/再生命令用环境设置，不推断四 scheduler。
性能运行明确四个；新 VM EUnit replay 明确两个；全部吞吐测量无 profiler。

## 本阶段变更文件与限制

新增 runtime `efz_mutation`、`efz_mutation_plan`、`efz_dictionary`、
`efz_recipe`。集成 `efz_config`、`efz_corpus`、`efz_worker`、`efz_crash`；
扩展 transform 内部 denylist。新增 `efz_mutation_tests`、`efz_recipe_tests`、
`efz_phase3_tests`，普通 staged parser、字典/示例 runner、再生 CLI、有界
benchmark。更新 README/architecture，新增变异/重放/验证文档及紧凑证据。
无关 source/configuration 和阶段2.1 证据保留。

限制刻意保留：仅字节变异、单生产 worker、内存阶段状态、无整活动 checkpoint、
自适应 schedule、自动 token 提取、minimization 或 grammar/stateful fuzz。
输入/字典/栈/活动预算有限，但配置最大值仍可能很贵。Recipe 为有界数据，不认证。
活动须固定 build；仅再生不证明结果复现，重放不允许任意热替换。
任意子进程、共享 VM 状态、native/OS 效应仍在目标进程覆盖/清理契约外。
本环境无所需验证结果被阻或不可得。
