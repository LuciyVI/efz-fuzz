# 原生 staged 变异（引擎版本 1）

[English](../../mutations.md) · [Русский](../ru/mutations.md) · [Español](../es/mutations.md) · **简体中文** · [所有语言](../README.md)

Staged 变异为显式选项。既有活动仍用 `efz_mutator_random` 和 `mutate/2`
behaviour。覆盖默认仍 prepared 验证与原 ETS hook；`coverage_backend => ets_member`
仍可用。变异模式不改变探针身份、异常处理、种子校准或仅合并成功覆盖的策略。

```erlang
{ok, Artifact} = efz_instrument:compile("examples/staged/efz_staged_parser.erl",
    #{modules => [efz_staged_parser], source_root => ".",
      outdir => "_build/my-staged-target"}),
{ok, _} = efz:start(#{target => efz_staged_parser, artifacts => [Artifact],
    seeds => [<<0>>], mutation_mode => staged, max_iterations => 200,
    max_input_bytes => 64,
    mutation => #{seed => {17,23,41},
        dictionary => [<<"TOKEN">>, <<"BOOM!">>],
        stages => [dictionary_insert,boundary,arithmetic,havoc,splice],
        max_block_bytes => 16, max_token_bytes => 16,
        attempts_per_visit => 8, havoc_depth => 4, random_retries => 4,
        max_idle_visits => 256, trace_limit => 0}}),
Report = efz:await(30000),
ok = efz:stop().
```

`rebar3 compile` 后运行 `escript examples/staged/run.escript`，可完成编译、
活动、保存 crash recipe 和执行重放。它从 `examples/staged/tokens.hex` 读字典，
而非以上内联选项。

## 职责与状态

* `efz_mutation:apply_operation/3` 应用具体操作，无随机选择、corpus 读取、时钟、
  覆盖或进程状态。`apply_operations/3` 顺序作用于中间 binary。
* `efz_dictionary` 在配置验证时解析/规范化一次 token。
* `efz_mutation_plan` 拥有显式 RNG、惰性确定性游标与调度。`prepare/2` 接收
  变异选项和初始 binary；`new/1` 接收规范化配置。返回状态视为不透明。
* `efz_corpus:mutation_entries/0` 按插入顺序提供 ID/字节。`efz_worker` 请求
  候选并调用**原有** executor/feedback。旧 random 保留原 selector。
* `efz_recipe` 封装操作和字节供独立再生，并为重放创建新验证上下文。
  见 [replay.md](replay.md)。

低层接口 `next(State, Entries)`，条目含 `id`、`input`。返回
`{candidate, Binary, Provenance, NextState}`、`{skip, Reason, NextState}`、
`{done, Reason, NextState}` 或 `{error, Reason, NextState}`。
输入/配置须已验证；无修改活状态配置的受支持 setter。计划/应用错误为基础设施
失败，不是目标崩溃。

配置和字典在 worker 中固定整个活动。每游标键为
`{SHA256(SeedBytes), ConfigurationId}`。初始内容重复时共享确定性工作，即使
数字 ID 不同。新内容有新游标。无整活动 checkpoint 格式。

## 默认值与上限

公开默认 `mutation_mode => random`。Staged 用新 `mutation` map，要求默认
`mutator`；自定义旧回调被拒绝，不静默忽略。Random 中提供 `mutation` 是错误。
Staged 省略 `max_iterations` 为 1,000，显式 `infinity` 拒绝。
Random 保留原预算语义，不隐式获得 staged 限制。

| 计划器设置（除活动 `max_input_bytes` 外均在 `mutation` 内） | 默认 | 可接受上限 |
|---|---:|---:|
| `max_input_bytes`（派生活动；直接 API 也接受） | 4,096 | 0–1,048,576 |
| `max_block_bytes` | 128 | 1–65,536 |
| `max_token_bytes` | 128 | 1–65,536；实际 token 也满足 block 上限 |
| `max_tokens` | 256 | 0–4,096 |
| `max_dictionary_bytes` | 16,384 | 0–1,048,576 |
| `max_delta` | 8 | 1–128 |
| `attempts_per_visit` | 8 | 1–1,024 |
| `havoc_depth` | 8 | 1–32 |
| `random_retries` | 4 | 1–128 |
| `max_idle_visits` | 256 | 1–100,000 |
| `trace_limit` | 0 | 0–10,000 个生成配方 |
| `prng` | `exsplus` | 引擎 v1 仅 `exsplus` |
| `seed` | 一次生成 | 三整数元组，每项 0–2^64−1 |
| `dictionary` | `[]` | 非空 binary token 列表 |

顶层 staged `max_iterations` 允许 0–1,000,000 次变异目标执行。初始种子
最多 4,096，每条须满足大小限制；超大验证失败，不截断。校准单独计数，总执行
上限为种子数加 `max_iterations`。错误限制、阶段名/重复名、未知选项或不支持
算法都在目标前失败。

一次 havoc 最多 `havoc_depth` 个组成操作。attempt 上限针对候选/操作栈尝试，
非栈中每步；每 visit 工作仍由两者乘积显式约束。生成 literal block 前检查
可用大小；primitive 在分配候选前检查拼接最终大小。字典解析/配置在循环前。

## EFZ 十六进制字典

内联 token 是 binary literal，如 `dictionary => [<<"TOKEN">>, <<0,255>>]`。
也可在 `mutation` 设置 `dictionary_file => "examples/staged/tokens.hex"`。
两者可共用，规范化后合并。路径只在配置时读一次，报告用规范化字节和身份替代，
之后改文件无影响。

**EFZ hex 字典格式**每行一个偶数长度十六进制 token：

```text
# TOKEN 和人工崩溃 token
544f4b454e
424f4f4d21

00ff
```

接受大小写 hex；去首尾空白与 CRLF；忽略空行和 trim 后 `#` 开头行。
内联注释、奇数 hex、非 hex 会带行号拒绝。不是 AFL 字典语法，不求值代码或
创建原子。

内联空 token 拒绝（文件空行仅忽略）。去重并按 binary term 排序。
各来源在去重前检查数量/总字节，合并规范化列表后最终去重前再查。
Token 须同时满足 token/block 限制。规范化列表编码 SHA-256 为身份，独立
原顺序/路径。读取器还有物理字节上限
`2*max_dictionary_bytes + 128*max_tokens + 4096`，含注释/空白。
无静默截断。空规范化字典合法；字典阶段结束或 havoc 报 `dictionary_unavailable`。

## 调度与惰性枚举

默认阶段顺序：

```erlang
[bitflip,byteflip,arithmetic,boundary,
 dictionary_insert,dictionary_overwrite,havoc,splice]
```

可显式选择任意非空、无重复子集和顺序。无自动 power schedule/学习。
每轮开始快照 corpus IDs，按插入顺序 visit。新条目下轮加入，持续增长不饿死旧
条目。每内容的 stage lane 轮转，**每 visit 最多执行一个候选**，长确定扫描
不会阻塞其他输入或 random 阶段。

确定性 visit 内 skip/no-change 推进游标，最多试 `attempts_per_visit`；
产出即结束。已完成阶段保持完成。每阶段只存整数游标，不物化候选列表。
Width/field/value 表是小有界列表。

稳定枚举顺序：

| 阶段 | 顺序 |
|---|---|
| `bitflip` | 宽度 1、2、4 bit，再按递增可容纳 bit offset |
| `byteflip` | 宽度 1、2、4 byte，再递增 byte offset |
| `arithmetic` | 字段 `(8,big)`、`(16,little)`、`(16,big)`、`(32,little)`、`(32,big)`；可容纳偏移；增量 `+1,-1,+2,-2,...,+max_delta,-max_delta` |
| `boundary` | 同字段/偏移，再下述九边界模式 |
| `dictionary_insert` | 插入边界递增，再规范化 token 顺序 |
| `dictionary_overwrite` | 规范化 token 顺序，再可容纳偏移递增 |

Progress 指产生候选或推进确定性操作游标（含 no-op、大小受限操作）。
二者重置 idle 与未进展 lane 记录。访问不可用/完成 lane 或用尽 random retry
增加 idle，返回 `skip`；worker 再安排 visit，不消耗目标执行预算。

当前 corpus 有任何确定性游标尚余操作时，idle guard 不能停。全部有限工作耗尽
后区分：

| 条件 | plan `done` 原因 | 活动 `status` |
|---|---|---|
| 所有确定游标完，无 random 阶段 | `mutation_exhausted` | `{mutation_exhausted, mutation_exhausted}` |
| 有 random；idle 预算到达**且**每内容自末次 progress 后访问全部 lane | `idle_budget_exhausted` | `{mutation_stopped, idle_budget_exhausted}` |
| 无 corpus（低层 API） | `empty_corpus` | `{mutation_exhausted, empty_corpus}` |

第二项是进展保护，不证明理论上无 random 候选。`max_idle_visits` 是停前最少
连续无进展次数，不硬限推进游标或完成 lane 扫描所需 visit。即使预算 1 仍可到
后续有效 lane。如 256 个单字节种子、`[dictionary_overwrite,bitflip]`、
`<<"AB">>` token，256 次不可用 overwrite 后产生 bitflip，而非过早耗尽。

固定 corpus 的有限游标在有限有界 visit 后完成；零数量空间立即停止。
剩余 random 无进展时，idle 阈值和完整 lane 扫描限制余下 visit。
Sweep 每内容/config 记一计数，沿既有循环顺序，不枚举变异。追加输入重置
idle/sweep，因新主输入/捐赠改变搜索空间；保留原游标、RNG 和进行中轮。
同 corpus 继续也保留 idle。计划器要求 `efz_corpus` 提供 append-only 条目。

worker 到 `max_iterations` 仍以 `completed` 停止。空 binary 是普通候选，
不是耗尽哨兵。

## 精确操作语义（操作版本 1）

所有 byte offset 从零开始。大小 `N` 的输入插入边界 `0..N`；合法范围
`0 <= Offset`、`Length >= 0`、`Offset + Length <= N`。Offset `N` 为追加；
删 `[0,N)` 得 `<<>>`。Primitive 接收规范化限制，只有字节改变才返回
`{ok, Candidate}`，否则 `{skip, Reason}` 或 `{error, Reason}`。

| 具体操作 | 含义与限制 |
|---|---|
| `{flip_bits, Offset, Width}` | bit 0 是 byte 0 最高位。异或连续 1、2、4 bit；须落于 `8*N`，支持跨字节 |
| `{invert_bytes, Offset, Length}` | 每 byte XOR 255；长度恰为 1、2、4，范围须合法 |
| `{add, Offset, Width, Endian, Delta}` | 读完整 8/16/32 位无符号字段，`little` 或 `big`；写 `(Old + Delta) band ((1 bsl Width)-1)`；`abs(Delta) <= max_delta`；零无变化 |
| `{set_integer, Offset, Width, Endian, Value}` | 将精确无符号位模式 `0..2^Width-1` 写合法 8/16/32 位字段。Planner 用版本化边界表，primitive 接受任意合法模式 |
| `{overwrite, Offset, Bytes}` | 替换恰 `byte_size(Bytes)` 个合法字节，不改大小；literal 长度满足 block 限制 |
| `{insert, Offset, Bytes}` | 在合法边界插完整字节，不截断；支持空原输入 |
| `{delete, Offset, Length}` | 删非空合法范围。Planner 最多选 block 范围，primitive 允许任意合法非空删除 |
| `{duplicate, Offset, Length, At}` | 复制非空合法源区间，再插入**原输入**边界；可重叠，长度受 block 限制 |
| `{dictionary_insert, Offset, Token}` | 插入完整非空 token，满足 token/block/结果大小限制 |
| `{dictionary_overwrite, Offset, Token}` | 替换合法 token 大小区间，不变大小；同限制 |
| `{splice, CutA, CutB, DonorBytes, DonorSHA256}` | `Primary[0:CutA] ++ Donor[CutB:DonorSize]`，两 cut 均边界；拼接前查 donor 哈希/大小，再查最终大小 |

宽度 `W`，令 `H = 2^(W-1)`、`U = 2^W-1`。版本 1 顺序：
`[0,1,2,H-2,H-1,H,H+1,U-1,U]`。8 位为
`[0,1,2,126,127,128,129,254,255]`。这些是位模式，含有符号解释边界周围值，
不借助意外有符号溢出。

不合适字段/范围以 `insufficient_length` skip，不读部分字段。过大结果/literal
以 `size_limit` skip。同输出或空普通 literal 为 `no_change`；空字典 token
在 primitive 不可用，在配置非法。畸形操作、donor 哈希无效、原输入过大及
delta 超限制是 error。一些 offset 不适合返回 skip 而非形状 error；配方再生
对**二者**都拒绝。需字节的操作遇空输入 skip；literal/字典插入和适当 splice
可从空生成候选。

Donor 来自现有 corpus 快照，排除与主种子内容相同者。不同内容去重、按 binary
term 排序后均匀选择，重复队列项不偏置。单内容 corpus 报
`donor_unavailable`。操作含 donor 字节/哈希，来源含 primary 字节/哈希/ID；
重放不查询队列索引。与当前中间 binary 相同的 donor 也 skip；cut 导致原输出
不变也 skip。不修改 corpus 条目。

## Havoc 与可重现性

Havoc 均匀选 `1..havoc_depth` 深度，再均匀选 11 类：bit flip、byte 取反、
算术、整数边界、overwrite、insert、delete、duplicate、字典插入、字典覆盖、
splice。不声称固定简单权重最优。参数基于前一步中间结果选。缺字典/donor 或
不适用选择消耗栈位置，不无限重选操作。

每栈尝试消耗深度 draw（独立 splice 固定深度 1）。Havoc 每位置消耗 family
draw，参数按代码顺序；前提失败立即返回，不抽不可用参数。所有 skip 消耗的
RNG 状态保留。每 visit 最多 `min(attempts_per_visit, random_retries)` 次
random 候选尝试。最终等于原 primary 即 no-op，即使中间曾变；可在同界内重试。
只有真正改变的组成操作进配方，skip 不改字节，无需重放。

所有新选择用 `rand:seed_s(exsplus, Seed)`、`rand:uniform_s/2`；staged 无
隐式 `rand:uniform()`。状态属于 worker 的 planner。目标随机性、旧 corpus
选择、日志、统计不消耗它。缺 `mutation.seed` 时初始化用 24 随机字节**一次**
生成三 seed 整数，算法/实际 seed 报于 `Report.mutation` 和配方。

测试 OTP 27.0 下重现选择需 engine version、规范化配置、算法/seed、初始
corpus 字节/顺序和字典，以及确定性结果/保留。`Report.mutation_initial_corpus`
记有序内容哈希，corpus 报告保留初始字节。配置身份为排序后规范化键值的 SHA-256，
含引擎版本、seed、字典 ID。`trace_limit` 因只观察而排除。改配置/字典需新
活动。含 handler 的内部 rand 状态不写配方。不承诺跨 OTP PRNG 兼容。

重现选择、再生具体 binary、重现目标结果是三种不同声明。配方无需 RNG/corpus
重建字节；时序敏感目标执行仍可不同。

## 来源与计数

保留条目的完整 recipe 位于 `Entry.metadata.mutation`；唯一 crash 记录用
`Crash.metadata.mutation`，磁盘在 `.input`/原 `.term` 旁写 `.recipe`。
Decisions 只留 stage/primary/config/candidate 哈希短摘要，不对每个失败决定
存完整 recipe。等价拒绝候选不保留。可选 `trace_limit` 只存前有限个生成配方，
包含之后被拒绝者，不消耗 RNG。

原 `Report.stats` 继续记录校准、变异、发现、拒绝、crash/timeout、唯一签名
和基础设施计数。`Report.mutation_stats` 新增：

* `visits`：调度 visit，含已完成/不适用 lane。
* `mutation_attempts`：确定性操作或 random 栈尝试。
* `operation_attempts`：组成操作尝试，含不可用选择。
* `skipped_operations`、`skip_reasons`：操作跳过；原因还计最终 no-op 栈，
  因此两总数不必相同。
* `skipped_candidates`：无候选结束的 visit。
* `generated_candidates`：正常运行真正交给执行的候选。

实时 `efz:stats/0` 保持原目标/活动计数；详细变异计数和有界 trace 在最终报告。
一栈是一个候选/保留决定，不证明每操作独立造成发现。签名组数不是已证明独立
缺陷数。Crash/timeout 保留观察，但崩溃独有覆盖不并入成功 novelty。
[coverage.md](coverage.md) 中单 worker、单目标进程、固定 build 的覆盖/隔离限制
仍适用。
