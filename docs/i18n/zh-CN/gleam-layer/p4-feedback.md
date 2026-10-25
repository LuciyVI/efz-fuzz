# P4 判定器与语料反馈——PASS

[English](../../../gleam-layer/p4-feedback.md) · [Русский](../../ru/gleam-layer/p4-feedback.md) · [Español](../../es/gleam-layer/p4-feedback.md) · **简体中文** · [所有语言](../../README.md)

当前 P5 验收记录于 [p5-validation.md](p5-validation.md)。
下文交接及待完成状态描述历史阶段运行。

需求 **2.0-native**；contract/model/codec/mutator/feature/property 向量
**{1,1,1,1,1,1}**。软件包 **1.1.0**、冷生成器 **2**、配方模式 **1/2/3** 均不变。
日期：2026-10-08。工具链：OTP **27.0** / ERTS **15.0**、Rebar3 **3.25.0**、Gleam **1.10.0**。
依赖锁不变。

证据：`artifacts/gleam-layer/20261008-p4-feedback/`；参见 `gates.json`、
`proofs-complete/proofs.json`、九份对应原始 `.term` 证明及 `p4-changes.patch`。
HEAD 仍为 `79d76221c6bc5df30b80e6b0de947f3860f4fa4b`。
起始 HEAD、脏差异和暂存区补丁以及 65 个文件指纹均保留。
修改前已读[公共需求](../../../../efz_gleam_native_subagent_prompts/01_COMMON_CONTEXT.txt)、
[P0 执行路径](execution-path.md)、[P1 契约](contracts.md)、[P2](p2-integration.md)、[P3](p3-provider.md)。

起始工作副本已包含纯观察器、判定器及引导 worker/语料分发。
本轮验证完整路径，收紧精确元数据边界，并增加语料拥有的只读代表查询。
负责人拥有这些修改及样例；不声称子代理或独立审查。
没有新调度器、语料、引擎、原生桥或插桩。

## 实际源码映射

| 职责 | 实际 file:function |
| --- | --- |
| 完成执行与不可变快照 | `src/efz_guardian.erl:finish/2`、`src/efz_executor.erl:run_pinned/4` |
| 既有结构谓词 | `src/efz_feedback.erl:evaluate/3`、`native_success/5` |
| 完成结果 → 回调 | `src/efz_worker.erl:execute_result/6`、`semantic_callbacks/4`、`semantic_observe/5`、`semantic_oracle/5` |
| 经检查直接 BEAM 边界 | `src/efz_gleam_adapter.erl:observe/3`、`summary/1`、`oracle/3`、`oracle_model/3` |
| 真实编译类型化回调 | `gleam/efz_semantic/src/efz_qs_model.gleam`；BEAM `efz_qs_model:observe/4`、`check/2` |
| 当前接纳与串行所有者 | `src/efz_worker.erl:retain_layer/4`、`src/efz_corpus.erl:semantic_admission/6`、`add_checked/3` |
| 持久化与兼容恢复 | `src/efz_corpus_store.erl:save/4`、`restore/3`；`src/efz_corpus.erl:init/1` 及 worker 校准 |
| 活动代表与保守缩减 | `src/efz_corpus.erl:semantic_representatives/0`；`src/efz_semantic.erl:representatives/1`、`cover/1` |
| 既有父输入选择 | `src/efz_corpus.erl:select/0`、`mutation_entries/0`；`src/efz_mutation_plan.erl:next/2`、`visit/2` |
| 发现与指纹 | `src/efz_worker.erl:record_failure/4`、`src/efz_crash.erl:signature/2`、`save/4` |
| 原始属性重放与最小化 | `src/efz_semantic_replay.erl:run/5`、`minimize/6`，既有 `src/efz_recipe.erl:execute/5` |
| 未修改真实解析器 | `examples/query_string/efz_qs_target.erl:run/1` → 固定 `cow_qs:parse_qs/1` |

## 属性与结果契约

**query_model_agreement / 1** 将已完成真实解析器的有序字段与单独实现的受支持查询解码器比较。
前提：二进制 ≤4096 字节、规范受支持形式、≤32 个显式非空名字段、每个名称和值 ≤128 字节；
不含有意错误转义。任意字节按字节接受。
这是预期结果属性，不是独立差分判定器，也不是 `decode(encode(model))`。

| 结果 | 谓词或策略 |
| --- | --- |
| Pass | 已完成 `{ok,{accepted,Pairs}}` 与受支持有序二进制字段匹配 |
| Fail | 接受结果不同，或解析器拒绝受支持规范查询 |
| Inconclusive | 不支持查询、模型或字节限制、目标异常或超时、检查预算耗尽；保留原因 |
| expected_rejection | 枚举的测试驱动解析错误返回 `rejected`；本身不是发现 |
| target_exception / target_timeout | 现有目标发现分类与生命周期清理 |
| semantic_layer_error | 有界诊断和计数；通过基础设施故障停止，绝不普通回退或当作目标缺陷 |
| infrastructure_error | 现有覆盖、生命周期、配置和存储故障策略 |

可最小化谓词仍是未修改目标及构建下返回 **Fail** 的同一版本化属性。
不支持、超时和 Inconclusive 不保持失败。
指纹使用 EFZ 现有 class/category/frame 策略；属性 ID、版本、目标构建及原始结果保留在语义旁文件。
目标发现先于观察器调用保存，因此后续层故障不能擦除它们。
判定器失败独立进入相同发现流水线。
EFZ 当前策略在发现后继续、在基础设施故障时停止；
`crash_policy` 控制指纹及代表，不是新的停止选项。

## 有限语义词汇

特征 = `{<<"cow_qs">>,1,Id}`。ID 是精确排序元组，无哈希、概率碰撞、动态原子、
无界字符串或运行时标识。结构单位在既有模式中仍是原生模块、构建和行单位。

| ID | 含义 |
| --- | --- |
| 0 / 1 / 2 / 3 | 接受 / 预期拒绝 / 目标超时 / 目标异常 |
| 4 / 5 / 6 / 7 | 接受键值对数：0 / 1 / 2 / ≥3 |
| 8 / 9 | 存在 / 不存在空二进制值 |
| 10 / 11 | 返回名称或值中存在 / 不存在 ≥128 的字节 |

接受执行发出四个特征，其他结果发出一个。
观察器摘要已完成结果，不解码输入或执行目标。
边界验证接受最多 100 对的正规列表、≤4096 字节二进制组件，以及 Cowlib 仅名称的 `true` 表示。
固定 Cowlib 自身把查询键限制为 100。畸形输出属于层错误。
超长输入计为观察跳过，不推导特征。

CurrentFeatures 是全新本地列表；SeenSemantic 属于语料所有者。
seen 及各合并条目集合最多 12 个 ID。
此 64 位 VM 测得 flat size：四个特征 288 字节，全部 12 个 864 字节，
派生 12 键代表映射 896 字节。这些是保守 term 大小，不是总 VM 内存或语料大小。
不分配缓存、队列、语义 ETS 或持久活动索引。
条目元数据随 EFZ 现有语料增长；不引入新的全局语料容量上限。

## 接纳、持久化与保留

对于成功主结果（含 `{ok,rejected}`），保留 EFZ 结构原因，并增加：

```text
SemanticNew = CurrentFeatures minus corpus.semantic_seen
KeepNewInput = ExistingStructuralKeep OR nonempty(SemanticNew)
```

初始种子、校准和其他现有原因保持完整。
异常和超时使用既有发现通道；按 P1 约定，其观察 ID 不接纳失败执行。
关闭和仅观察执行常规接纳路径。
仅观察不保存历史 seen 状态；引导模式在活动启动时新建或重建语料拥有的历史。

既有 gen_server 将新颖性、持久化和提交串行化。
在添加条目或 seen 前先保存新原始输入及元数据。
失败或拒绝不改变 seen；关闭存储时，内存插入即提交。
既有输入注释合并证据，不重复原始语料条目，也不丢失原始接纳原因。
纯语义条目使用普通存储、`select/0` 和 staged `mutation_entries/0`；能量策略不变。

重启验证 EFZC、记录和命名空间版本，然后在变异前显式校准当前原始语料条目，重建注释和 seen。
这些执行报告为校准，与变异执行分开。
旧 EFZC 记录 1/2 和当前语义记录 3 继续支持。
不兼容特征模式恢复失败。
不存在跨活动手动删除后仍残留的持久化全局 seen 索引；重新校准反映剩余代表。

在线语料只追加。冷路径 `cover/1` 保留已记录结构探针和计数并集及全部语义代表，
保护初始或未校准条目。
测试把其子集应用到**新**存储并重启；原语料保留。
没有在线删除或引用计数事务，也没有全局最优缩减器。
不支持活动期间编辑语料文件。
只读代表查询为每个特征派生一个工作 ID，并检查全部 seen 特征仍有代表。

## 覆盖与判定器区间

`reset → target → controlled-tree completion/cleanup barriers → sealed snapshot
→ observer/pure oracle → admission/finding handling`。

原生计数器以模块为范围。既有 guardian 以 `runner_busy` 拒绝并发本地目标执行，
回收受控后代，排空追踪屏障，只在清理后发布；调用方等待 guardian DOWN。
测试确认延迟子进程已死、其截止时间之后原生计数器不再变化，且下一迭代恢复基线覆盖。
只选择 `cow_qs`；辅助代码、Gleam 和判定器不贡献目标单位。
同 VM 内不受管理的所选模块调用仍在此契约外。

生产判定器是直接、有界纯函数，增加**零**目标执行。
预算默认 64，最大 10000，包含校准。
每次执行都检查直到预算耗尽，与结构新颖性无关；剩余检查明确为 Inconclusive/budget 并计为跳过。
此确定性前缀不声称验证全部输入或统计采样。
不支持昂贵或延迟判定器、worker 协议、队列或并行重放；延迟模式启动失败。
显式冷重放和最小化使用单独串行 EFZ 区间，并报告其目标执行次数。
不声称原生取消能力。

## 已执行验收证据

| 检查 | 命令或结果（所列退出码均为 0） |
| --- | --- |
| 完整开启回归 | `rebar3 as gleam eunit`：**313** 项；`full-on-tests.json` |
| 最终专项原生证明 | `rebar3 as gleam eunit --module=efz_gleam_feedback_tests`：**11** 项；`snapshot-test-build.json` |
| 导出最终原始证明 | `export_proofs.escript`：在其 VM 中重跑 **11** 项，安全解码并复制 **9** 份证明；`export-proofs-final.json` |
| 无编译器全新关闭构建 | 私有仅源码 `/tmp/efz-p4-off-vg8psokv`，起初无软件包、编译器或 BEAM；`rebar3 compile` 和专项 EUnit **55** 项；`clean-off-compile.json`、`clean-off-tests-r2.json` |
| 关闭运行时与 term 兼容 | `off_check.escript`：无 Gleam、辅助模块、应用或状态，普通活动及既有 term 目标通过；`off-runtime-check-r2.json` |
| 其他后端及静态调用 | `rebar3 ct`：**3** 项；`rebar3 as gleam xref`；`ct-regression.json`、`on-xref.json` |
| 观察中立性 | 两个真实 staged 活动，种子 17，比例 0，**200** 次变异：全部候选哈希、阶段和父输入匹配，语料和覆盖相同；`observation-sequence-proof.json` |
| 发现 CLI | `scripts/gleam_replay.escript … efz_qs_defect_target 64 …`：**1** 次执行复现，**34** 次最小化为 `bug=`；`finding-cli-replay.json` |

A 中，输入 `613d31`（`a=1`）和 `613dff`（`a=` 加字节 255）具有完全相同的 **14** 个原生单位。
全部 **9** 个追踪主执行封存位快照为 `67041a2c00000300000000`，解码单位相同。
特征分别为 `[0,5,9,11]` 和 `[0,5,9,10]`。
引导模式以 `new_semantic` 接纳第二个原始输入，`new_probes` 为空，语料大小 2。
实际既有调度器父 ID 为 `[1,2,1,1,2,1,1,1]`。
关闭及仅观察保持大小 1。重复不增加记账。
追踪确认九次编译 Gleam observe 调用、零 decode 调用；受控原始变异器只在测试样例中使用。

B 测试写失败与重试、1000 次重复重试、两个同时语料 API 调用方恰好获得一次记账、
启动重建及模式不匹配、保守子集重启、活动间删除后恢复。
独立契约样例执行 10000 次接纳尝试，达到 12 个 seen ID、仅八个条目；
它不执行目标，不是活动或发现证明。

C 测试仅目标覆盖、后续区间不变及延迟子进程清理。
显式独立目标重放不能改变已返回的主快照。
不声称并行原生覆盖 PASS。

D 使用明确人工的 `efz_qs_defect_target`：向 `bug` 值追加 NUL。
一次校准加两次重复普通变异产生三次判定器失败，一个发现分组、零语料发现、特征不变。
原始 `bug=11&x=2` 字节、属性及版本和构建元数据被保存。
本轮复制的发现及原生产物支持真实 CLI 成功重放。
这测试接线，不声称实际 Cowlib 缺陷或独立发现。

## 计数与成本样本

`gleam_stats` 报告观察器调用、跳过、微秒，判定器检查、通过、失败、无结论、跳过、微秒，
预期拒绝、超时、异常及层错误。
纯判定器报告额外执行零。
预算样例：七次主执行、七次观察、两次 Pass 检查（含结构等价输入）、五次显式跳过。
发现处理不依赖接纳。EFZ 没有语料容量选项，因此独立满容量条件不适用。

有限组件探针：10000 次重复、模型派生结果、无目标执行、无生产追踪。
均值单位微秒（`component-costs.json`）：

| 输入字节 / 字段 | 观察器 | 纯判定器 | 精确集合差 | 冷路径 12 特征索引 |
| --- | ---: | ---: | ---: | ---: |
| 3 / 1 | 0.28 | 1.34 | 0.46 | 3.31 |
| 4096 / 16 | 14.71 | 304.70 | 0.50 | 3.44 |

四个真实同引擎冒烟活动使用种子 17、比例 10%、六个类型化种子，
各运行 500 次变异，关闭追踪：

| 模式 | 主调用 | 观察器调用 | 判定器检查 / 跳过 | 语料 / 纯语义 | 结构单位 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 结构化，反馈关闭 | 506 | 0 | 0 / 0 | 14 / 0 | 48 |
| 仅观察 | 506 | 506 | 0 / 0 | 14 / 0 | 48 |
| 引导 | 506 | 506 | 0 / 0 | 15 / 1 | 48 |
| 引导 + 内联判定器 | 506 | 506 | 64 / 442 | 15 / 1 | 48 |

判定器检查为 19 Pass、45 Inconclusive，无失败。
全部活动完成，无基础设施错误；目标拒绝单独计数。
单次墙钟速率（177–226 次执行/秒）是冒烟样本，不是性能优势或最优选择。
直接回调不存在 worker 或消息开销；既有目标执行开销不在组件样本中。

## 差异、审查限制与 P5 交接

生产修改为 `src/efz_semantic.erl` 和 `src/efz_corpus.erl`：
精确元数据验证及冷代表派生和查询。
新文件为三个反馈测试或样例模块、`scripts/gleam_feedback_probe.escript` 和本报告。
两个显式模式扩展既有基准驱动；契约、指南、所有权和决策文档已更新。
`p4-changed-files.json` 和 `p4-changes.patch` 将这些变更与此前脏工作树区分。
本轮 AGENTS、用户提示归档及文本、目标、模型、软件包、锁、覆盖、变异、worker、
发现及重放代码保持不变。

失败尝试继续归档：依赖时间戳的统计断言、不存在测试模块名、运行时原子尚未加载时安全导出证明、
无效 none/manual 诊断配置。
首次追踪证明比较空诊断列表；修正验收使用封存原生位及非空单位。
仅源码准备命令最初与其证明文件名冲突；重复准备保留独立命令和源码证明文件。
这些早期尝试都不作为最终门槛证据。

P5 应独立审查本契约和代码，执行最终跨阶段回归及实际发现实验，
并运行可复现多种子同引擎基准，包含最终持久化成本。
保留保守默认值和原始代表。
精确活动检查点、在线裁剪、延迟判定器和不受管理并行目标执行仍不支持。
未进行 push、PR 或 commit；P4 PASS 不关闭 P5 或全部编排提示词。
