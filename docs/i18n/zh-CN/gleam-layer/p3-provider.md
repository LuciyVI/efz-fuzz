# P3 结构化提供器——PASS

[English](../../../gleam-layer/p3-provider.md) · [Русский](../../ru/gleam-layer/p3-provider.md) · [Español](../../es/gleam-layer/p3-provider.md) · **简体中文** · [所有语言](../../README.md)

当前 P5 验收记录于 [p5-validation.md](p5-validation.md)。
下文交接及待完成状态描述历史阶段运行。

需求 **2.0-native**；contract/model/codec/mutator/feature/property 向量
**{1,1,1,1,1,1}**。冷生成器 **2**，软件包 **1.1.0**。
新结构化配方模式 **3**，操作版本 **2**，EFZR 封装 **1**；旧配方模式 **1/2** 仍可读。
日期：2026-10-08。

证据：`artifacts/gleam-layer/20261008-p3-provider/`。
HEAD 仍为 `79d76221c6bc5df30b80e6b0de947f3860f4fa4b`。
`head.txt`、`status-before.txt`、`dirty-before.patch`、`dirty-index-before.patch`、
`inputs.json` 和 `before-files/` 保留起始工作副本。
本轮扩展 P2 已存在的提供器，不声称此前全部软件包阶段当时已验收。
编辑前已审阅 [P0](baseline.md)、[执行路径](execution-path.md)、[P1 契约](contracts.md)
和 [P2](p2-integration.md)。

## 实际执行与所有权

| 职责 | 实际 file:function |
| --- | --- |
| 既有循环与生命周期 | `src/efz_worker.erl:staged_iteration/1`、`src/efz_fuzzer.erl:handle_info/2` |
| 工作语料与父输入 | `src/efz_corpus.erl:mutation_entries/0`、`src/efz_mutation_plan.erl:next/2`、`visit/2` |
| 既有通道、预算、RNG 和家族分发 | `src/efz_mutation_plan.erl:attempts/6`、`structured/3`、`ordinary_attempts/6`、`uniform/2` |
| 原生边界 | `src/efz_gleam_adapter.erl:mutate/3`、`decode/2`、`encode/2` |
| 真实编译类型化核心 | `gleam/efz_semantic/src/efz_qs_model.gleam`；BEAM `efz_qs_model:decode/2`、`mutate/3`、`encode/2`、`generate/2` |
| 未修改真实目标 | `examples/query_string/efz_qs_target.erl:run/1` → 固定 `cow_qs:parse_qs/1` |
| 执行与目标快照 | `src/efz_executor.erl:run/4`、`src/efz_guardian.erl:finish/2`、`src/efz_cov_native_public.erl:collect/1` |
| 结构接纳与持久化 | `src/efz_feedback.erl:evaluate/3`、`src/efz_corpus.erl:add_checked/3`、`src/efz_corpus_store.erl:save/4` |
| 种子准备与普通导入 | `scripts/gleam_seeds.escript:main/1`、`src/efz_cli.erl:read_seeds/2`、`src/efz_corpus.erl:init/1` |
| 有界配方与原始再生 | `src/efz_recipe.erl:make/4`、`validate_structured/2`、`regenerate/1` |

EFZ 先访问语料父输入及既有阶段，再选择家族。普通路径调用既有变异函数。
结构化路径直接 BEAM 解码 → 变异 → 编码；纯回调既不执行目标，也不选择父输入。
不支持、达到限制或未改变时，仅一次调用 `ordinary_attempts/6`，不递归进行结构化选择。
层错误返回单独诊断，增加 `errors`，经 EFZ 基础设施通道停止活动。
控制器仍可报告或停止。不据此推断目标缺陷。

关闭或比例零跳过分支 RNG 及解码。
正比例消耗一次 `uniform_s(100)` 抽取，选中时再用 `uniform_s(6)` 选择操作。
成功返回 R2；回退从 R2 开始普通路径；错误记录 R2，不重试。
仅结构化来源信息记录抽取前后精确 exsplus 状态字、比例、操作、版本和限制。
普通候选和配方保持原形。原始二进制是规范持久输入；模型仅临时存在。

目标、执行器、语料、能量、接纳、覆盖、发现和重放所有者未被替换。
不增加外部引擎、fuzzer 回调、新 NIF/C 桥、传输、每变异 VM、缓存、异步学习器或新 worker。
既有无关原生启动器和后端保留。
模块范围 OTP 计数器保留 EFZ guardian 串行化；不受管理并行目标调用仍在隔离契约外。
P3 活动关闭语义反馈和判定器。

## 模型、限制、操作与种子

具体 ADT：`Query(List(Field),Canonical|BadEscape)` 和 `Field(BitArray,BitArray)`。
支持子集：非空二进制名称、显式 `=`、有序及重复字段、`&` 分隔符、百分号转义和加号表示空格。
值可为空、NUL、非 UTF8。仅名称字段、空名称、冗余分隔符和畸形转义不被模型支持；
仍可经原始路径调用目标。这是真实解析器可接受语言的一个子集。

限制：4096 wire 字节、32 字段、每组件 128 字节、固定嵌套 2、每候选一个操作。
容量保护在 prepend/append/目录分配前执行。
变异器以大小预检取代分配后丢弃的编码值；编码器独立检查输出大小。
归档 P2 BEAM 和当前 BEAM 在 **264** 个模型、操作、限制案例中结果相同。

| 操作 ID | 效果 |
| --- | --- |
| 0 | 在字段、组件和字节限制内前置字段 `x={0,255}` |
| 1 | 将首值置为零字节；空查询生成 `a=` |
| 2 | 删除首字段，包括转换为空查询 |
| 3 | 反转字段，保留键值对标识及重复名顺序语义 |
| 4 | 向首值追加字节 255，或创建 `a=%FF`；限制阻止溢出 |
| 5 | 有意无效百分号转义后缀 `&x=%`；编码器保留它 |

编解码测试覆盖规范受支持模型的 `decode(encode(M)) == normalize(M)`、
归一化幂等性、显式字段和值网格、全部六个预期 wire 样例及实际 Cowlib 结果。
无效 `BadEscape` 排除在合法模型往返定律之外。不声称任意原始字节保持一致的定律。

确定性目录现有 12 个不同槽位：空查询或值、二进制字节、重复和保留字节、
命名字段变体、无效转义、127/128 字节值、31/32 字段、恰好 4096 字节 wire 及最长键。
默认输出 **12 文件 / 5349 字节**，未修改解析器给出 **11 接受 / 1 预期拒绝**。
准备限制为 64 文件、总共 65536 字节，拒绝已有输出，
并在种子目录外以清单模式 2 记录目录索引、生成器和运行时版本、限制及各文件 SHA-256。
创建输出目录前检查冷生成器版本。

`seed-import-r2/proof.json` 验证清单哈希、普通 CLI 导入和工作语料中的原始标识。
无需编译器或软件包的构建完成 12 次校准，随后单独普通活动执行 50 次变异。
Gleam 保持未加载，无层计数。
十二次独立解析器探测明确属于活动覆盖区间之外的额外冷检查。
不原地修改原始种子语料。

## 命令与已执行检查

固定工具链：OTP **27.0**、ERTS **15.0**、Rebar3 **3.25.0**、Gleam **1.10.0**；`+S 2:2`。
普通依赖提交和锁不变。`runtime.json` 记录真实模块路径、导出及软件包 1.1.0；
可选应用未加载。
每条命令有相邻 `.json` 记录参数、cwd、所选工具设置、退出码、耗时，以及 `.log`。
运行器是运行目录中的 `run_command.py`。

| 门槛 | 命令或证据名称 | 退出码或结果 |
| --- | --- | --- |
| 真实开启构建 | `GLEAM_BIN=/tmp/efz-gleam-toolchain/gleam rebar3 as gleam compile` / `on-compile-final` | 0 |
| 专项回调、契约、配方、提供器套件 | `rebar3 as gleam eunit --module=efz_gleam_provider_tests,efz_gleam_layer_tests,efz_gleam_contract_tests,efz_gleam_beam_tests,efz_recipe_tests` / `focused-tests-r4` | 0 / 46 项通过 |
| 完整回归 | `rebar3 as gleam eunit` / `full-on-tests` | 0 / 302 项通过，含 term 目标及旧 staged 操作 |
| 最终全新样例名 | `rebar3 as gleam eunit --module=efz_gleam_provider_tests` / `provider-tests-final` | 0 / 10 项通过 |
| 仅源码关闭构建 | 在 `/tmp/efz-p3-off-0c0joh3_` 执行 `PATH=/home/fbogoslavskii/.asdf/installs/erlang/27.0/bin:/usr/bin:/bin GLEAM_BIN=/nonexistent/gleam rebar3 compile` / `clean-off-compile` | 0 |
| 关闭兼容 | 在该目录执行 `rebar3 eunit --module=efz_gleam_provider_tests,efz_gleam_layer_tests,efz_gleam_contract_tests,efz_gleam_beam_tests,efz_recipe_tests,efz_mutation_tests,efz_phase2_tests,efz_smoke_tests` / `clean-off-tests` | 0 / 57 项通过 |
| 覆盖回归 | `rebar3 as gleam ct` / `ct-regression` | 0 / 3 项通过 |
| 静态调用 | `rebar3 as gleam xref` / `on-xref` | 0 |
| 根目录普通构建 | `GLEAM_BIN=/nonexistent/gleam rebar3 compile` / `root-off-compile` | 0 |
| 种子准备与导入 | `escript scripts/gleam_seeds.escript RUN/generated-seeds`；`escript scripts/gleam_seed_import_check.escript OFF_BUILD RUN/generated-seeds RUN/seed-import-r2 ROOT` | 0 / 原始标识、12 校准、随后 50 变异 |
| 真实循环接线 | 最终提供器测试生成的 `real-loop/proof.term` | 200 变异 + 3 校准；EFZ worker 上真实 Gleam 调用；目标调用等于计数执行；无 observe/check 调用及语义状态 |
| 关闭或零比例序列 | `python3 RUN/run_campaigns.py` / `raw-{baseline,off,fraction0}-{17,43}` | 全部六次退出 0；每种子的 100 候选哈希、阶段和父输入轨迹匹配 P0 |
| 无 Gleam 重放 | `escript /tmp/efz-p3-off-0c0joh3_/scripts/replay.escript RUN/real-recipes/{current,old}.recipe RUN/replayed-{current,old}.input` | 均 0；模式 3/2 原始结果匹配预期字节 |
| 已记录状态复现 | `escript RUN/verify_recipe.escript BUILD RUN/real-recipes/current.recipe RUN/recipe-state-proof-result.json` | 0；原生回调及 EFZ 计划从已记录 R0 复现字节、操作和 R2；目标执行零 |
| 独立组件 | `escript scripts/gleam_provider_probe.escript BUILD RUN/p2-model-original.beam RUN/provider-samples.json` | 0 / 264 等价案例、40 批次、36 序数样本 |
| 关闭分发 | `escript scripts/gleam_dispatch_bench.escript RUN/dispatch-samples.json` | 0 / 每种分发 5 次试验 × 1M 调用 |

`RUN` 是证据目录简写，`BUILD` 为 `_build/gleam`，`OFF_BUILD` 为私有 `_build/default`，
`ROOT` 为本仓库。关闭副本包含普通固定依赖**源码**，初始 BEAM 为零，
没有 Gleam 目录，PATH 中无编译器。
`clean-off-final-isolation.json` 确认其生产源码匹配最终树，且无层 BEAM 或 app；
`off-runtime.json` 还证明 VM 路径中也找不到它们。
Rebar 只为 checkout 覆盖重写 scratch 锁。

已执行样例包括畸形边界、结果及版本不匹配，限制与不支持拒绝，成功/回退/错误下一状态，
重复确定性变异，关闭及零比例精确状态，操作及字节计数，配方篡改，旧模式 2，
常规语料持久化和重启，以及回调故障分离。
受控桩证明错误契约；真实循环、活动和编解码检查使用编译 Gleam 及未修改 Cowlib 解析器。
mock 不关闭集成门槛。

初始失败均保留：新测试比较配置映射而非运行时状态，写错一个样例长度，
假设 1% 概率在仅 100 次访问内一定尝试，使用错误追踪 API 元数，预期无拒绝计数，
比较重启顺序，以及超过屏障仍继续追踪。修正测试后通过。
首次种子导入诊断两次重载已加载测试驱动，返回 `not_purged`（退出 127）；
驱动去除不必要预加载，并在已停止活动之间 purge 旧版本后，重跑通过。
生产 CLI 不变。最终样例目录包含时间和唯一 ID，避免复用。

## 比例诊断与成本

每个比例使用两个显式种子（17 和 43）、同一引擎及后端、初始原始 `a=1`、
每种子 2000 次变异执行、一次校准，以及单独 20 次执行的预热活动。
轨迹关闭。不进行语义或判定器回调，也无额外目标执行。允许既有语料演化。

| 比例 | 尝试 | 成功 | 不支持 | 未改变 | 生成字节 | 回调 µs | 主执行墙钟 exec/s，种子 17 / 43 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1% | 41 | 11 | 29 | 1 | 335 | 607 | 229.9 / 231.5 |
| 5% | 224 | 80 | 130 | 14 | 4962 | 4357 | 173.5 / 183.0 |
| 10% | 391 | 168 | 194 | 29 | 7952 | 7345 | 199.3 / 179.7 |
| 20% | 794 | 324 | 415 | 55 | 15400 | 14568 | 177.5 / 198.1 |

计数为每行两个测量活动之和。本系列全部限制和错误为零；显式限制与错误样例另行覆盖。
操作 0..5 的计数位于各 `fractions/SEED/fractionN/summary.json`，总和等于尝试数。
所选百分比是分支概率，不是成功比例。
全部 16000 次测量变异完成，无层或基础设施故障。
结构单位单独报告，不引入语义覆盖总和。
一次 20% 运行结束时结构行数更少；不据这些样本推断引导收益。

独立五次试验的批量差值中位数，包含已验证边界工作：

| 输入与操作 | 解码 µs | 核心变异 µs | 编码 µs | 完整提供器 µs |
| --- | ---: | ---: | ---: | ---: |
| 8 字节 / 追加 255 | 1.310 | 0.380 | 0.512 | 2.322 |
| 4096 字节 / 清空首值 | 363.530 | 52.238 | 165.260 | 488.940 |

独立批次不能构成相加时间等式。
生产报告保留累计回调时间；诊断驱动提供有限单阶段及序数样本，不用 RNG 采样或执行目标。
相对诊断控制，关闭分发中位差值为计划器 **+0.941 ns**、worker **−0.657 ns**。
负差值是测量或代码布局噪声，不是优化结果。
临时 export_all 限于诊断 VM。
不声称零开销、加速、最优比例或最终 P5 性能结论。

## 修改文件、决策与交接

P3 专有 `p3-changes.patch` 和 `p3-changed-files.json` 与保存的 P3 起始树比较，
包括未跟踪源码。生产改动为类型化目录、大小预检及软件包版本，计划器来源信息和计数，
配方模式 3，种子生成器，以及一个零比例基准模式。
新文件为提供器测试、组件和导入证据驱动及本报告。契约、指南、所有权和决策文档已更新。
P3 不修改共享构建或配置、适配器、语料、执行器、目标或依赖锁。
`preserved-inputs.json` 记录这些文件、AGENTS.md 和用户提示目录及 zip 的检查；
不删除原始语料，不进行 Git 写入或发布。
审查由作者完成，不是独立审查者或委派子代理。

P4：使用不变的归一化结果及有限特征契约和现有串行语料接纳；
独立关闭引导工作语料选择、持久化失败重试、历史 seen/重启/模式策略以及判定器和发现隔离。
P3 证明反馈关闭时的变异接线，不是完整引导。

P5：验证完整重放和最小化谓词及代表保留，然后执行更长的同引擎受控种子、预算及后端比较，
包含持久化收尾和重复试验。
保留关闭与零比例轨迹和模式 1/2 样例。
当前 RNG 元数据复现具体变异；语料重启是复用和校准，不是活动 PRNG 检查点。
直接有界调用不保证任意挂起取消。现有测量不足以支持生产缓存。
