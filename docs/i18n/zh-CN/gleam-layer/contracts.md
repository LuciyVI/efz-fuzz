# 原生 Erlang/Gleam 契约 v1

[English](../../../gleam-layer/contracts.md) · [Русский](../../ru/gleam-layer/contracts.md) · [Español](../../es/gleam-layer/contracts.md) · **简体中文** · [所有语言](../../README.md)

需求：**2.0-native**。契约：**1**。
`efz_gleam_adapter:versions/0` 和编译后的 `efz_qs_model:versions/0` 均返回
`{Contract,Model,Codec,Mutator,FeatureSchema,Property} = {1,1,1,1,1,1}`。
启动要求精确一致；属性重放检查该向量和 `{query_model_agreement,1}`。
不兼容产物不会静默强制转换。
[architecture.md](architecture.md)标明实际 EFZ 所有者及 P0 隔离。

## 类型化核心与 Erlang 边界

首个解析器：固定 Cowlib `cow_qs:parse_qs/1`，提交
`c768a804565ff5b8178ed968a5921e469d6bd7b2`。
测试驱动为 `examples/query_string/efz_qs_target.erl:run/1`。
独立 `efz_qs_defect_target` 是人工验收样例，不是生产缺陷。
`<<"cow_qs">>` 标识目标家族；产物还固定测试驱动。

具体 Gleam ADT 位于 `gleam/efz_semantic/src/efz_qs_model.gleam`。
以下真实编译表示均通过 BEAM 调用测试：

| 类型 | Erlang 表示与检查边界 |
| --- | --- |
| Bytes / `BitArray` | 仅 `binary()`；拒绝非字节对齐 bitstring 和文本列表；不假设 UTF-8 |
| `Field` | `{field,KeyBinary,ValueBinary}`，非空键、有界组件 |
| `Query` | `{query,ProperFieldList,canonical | bad_escape}`，精确元组与标签形状 |
| `Limits` | `{limits,Bytes,Fields,Component,1}`，有界整数 |
| Gleam 结果 | `{ok,Value}` / `{error,unsupported | limit}` |
| 观察事实 | 适配器检查主结果后构造的整数和 `true | false` |
| 版本 | 上述固定六整数元组 |

记录是带标签元组；外层 EFZ 配置和元数据为映射。
适配器在调用核心前验证正规列表、标签、二进制、对齐、整数和限制。
没有 Dynamic、不安全转换或从模糊测试字节创建原子。
调用是直接模块调用，不进行每次调用 JSON/ETF/IPC。
ETF 仅用于既有版本化产物编解码。

实际窄接口，而非拟议 behaviour：

```erlang
prepare(false | OptionsMap, PreparedEFZConfig) -> {ok,Config} | {error,Reason}.
decode(Binary, Limits) -> {ok,Query} | {skip,unsupported | limit} | {error,Reason}.
encode(Query, Limits) -> {ok,Binary} | {skip,limit} | {error,Reason}.
normalize(Query, Limits) -> {ok,Query} | {error,Reason}.
generate(Index, Limits) -> {ok,Binary} | {skip,limit} | {error,Reason}.
mutate(Binary, OperationId, Limits) -> {ok,Binary,RecipeData}
                                      | {skip,unsupported | limit} | {error,Reason}.
observe(Binary, PrimaryOutcome, Limits) -> {ok,SemanticSet}
                                          | {skip,limit} | {error,Reason}.
oracle(Binary, PrimaryOutcome, Limits) -> {pass,query_model_agreement}
  | {fail,query_model_agreement} | {inconclusive,Reason} | {error,Reason}.
```

纯核心外围的显式 RNG 选择归 EFZ：mutate 接收操作 ID，而非隐藏 RNG。
Generate 使用确定性目录索引 0..4095；准备脚本使用连续索引，输出最多 64 文件。
两类回调都不消耗调用方 RNG 状态。生成是离线操作，不是在线家族。
种子目录单独检查 `generator_version/0 = 2`，有 12 槽位（索引对 12 取模重复）；
软件包版本为 1.1.0。
种子保存为原始文件及模式 2 清单，记录索引范围、版本、限制、哈希及总字节数，
最多 64 种子 / 65536 字节。
运行时启动仍检查八个 v1 回调；生成器版本是准备命令检查的冷路径能力。
因此，语义 Model-and-next-RNG 操作由 EFZ 结合纯模型回调组成；实际状态转换见下文。

EFZ 候选为 `{candidate,Binary,PlanMetadata,NextPlanState}`；
语料 `input` 保持实际原始二进制。解码模型是临时值，绝不是持久输入。
既有执行器和目标 term 契约不变。

## 编解码定律、操作与限制

受支持规范模型保留字段顺序和重复名。
解码支持非空名称、显式 `=`、`&`、百分号转义、加号表示空格，
以及含 NUL 和非 ASCII 的任意字节。
仅名称字段、空名称、冗余分隔符和错误转义返回 unsupported，仍保留原始可达性。

对于规范模型，`decode(encode(M)) == normalize(M)`，且
`normalize(normalize(M)) == normalize(M)`；归一化是恒等操作。
不保证原始字节一致。
有意的 `bad_escape` 追加 `&x=%` 而不修复，排除在合法模型编解码定律外。

| 边界 | v1 值或可配置范围 |
| --- | --- |
| 结构化输入及输出字节 | 0..4096；受现有 EFZ `max_input_bytes` 限制 |
| 字段数 / 组件最大字节 | 1..32 / 1..128；允许空查询和值 |
| 嵌套 | 固定 Query → Field 深度 2，无递归变体 |
| 每候选结构化操作 | 恰好 1 |
| 观察器主解析器结果 | ≤100 对，每组件 ≤4096 字节 |
| 每执行特征 / 活动词汇 | ≤4 / 12 个允许 ID |
| 判定器检查 | 每活动 0..10000，默认 64，包含校准 |
| 语义缓存、队列、额外 worker | 无（大小 0） |

字节边界先于解码递归；字段及组件边界阻止继续遍历。
编码器在分配编码字节前计算输出大小。
变异器在 prepend/append 分配前检查字段和组件容量，计算 wire 大小而不分配随后丢弃的编码。
编码器独立地在编码字节分配前检查大小。
大型目录组件和列表有分配保护。
回调是纯有界 BEAM 调用。耗时记账不会中断挂起回调。

固定操作：0 前置 `x={0,255}`；1 清空首值；2 删除首字段；3 反转字段；
4 向首值追加字节 255；5 选择 `bad_escape`。
0..4 在限制内保留合法性；5 有意违反转义语法。
不支持、限制或未改变结果使用受控普通回退。

## PRNG 与配方

`efz_mutation_plan:new/1` 使用显式 `rand:seed_s(exsplus,mutation.seed)`。
缺少种子时保留既有一次性加密派生。
复现要求父输入字节、种子或状态、计划配置、版本和限制。
旧随机变异与选择的进程本地 rand 策略保留；此层绝不隐式使用它。
当前 EFZ 有一个 worker，因此完成顺序不是随机性来源。
既有父输入和通道选择之后：

| 情况 | 状态转换 |
| --- | --- |
| 关闭 / 比例零 | 不增加抽取；普通路径从 R0 开始 |
| 比例 >0 | `{Branch,R1}=rand:uniform_s(100,R0)` |
| 分支值超过比例 | 普通路径从 R1 开始 |
| 选中结构化 | `{OpPlusOne,R2}=rand:uniform_s(6,R1)`，Op=OpPlusOne−1 |
| 成功 | 候选和下一计划使用 R2；纯核心不抽取 |
| 不支持 / 限制 / 未改变 | 普通路径从 R2 开始，再沿其常规状态推进 |
| 层错误 | 用 R2 返回诊断并停止；无回滚、重试或回退 |

配方操作是纯数据：
`{structured_replace,1,{1,1,1,1,1,1},OperationId,OutputBinary}`，输出 ≤4096 字节。
使用既有 `efz_recipe:make/4` / `efz_mutation:apply_operation/3`。
EFZR 封装仍是 v1；新结构化配方模式为 3，操作版本 2。
旧结构化模式 2 / 操作 2、普通模式 1 / 操作 1 仍可读。
仅结构化计划元数据增加 `source_kind=>structured` 和
`structured=>#{schema_version=>1,versions=>V,operation=>Op,limits=>Limits,
fraction=>F,rng_before=>[A,B],rng_after=>[NextA,NextB]}`。
这些是分支选择前和操作选择后精确的两个 58 位 exsplus 状态字，以正规列表表示；
产物不含运行时函数。
冷配方验证通过 `rand:seed_s({exsplus,[A|B]})` 重建状态，
检查分支、操作、下一状态、限制和精确元数据形状。
再生应用保存字节，不重跑类型化变异。
允许操作不能分发模块、函数或可执行 term。
替换再生不需要 Gleam；属性重放需要。
记录原 primary 字节、种子及配置标识、输出哈希和构建 ID。
不增加自适应提示、缓存或能量变化。

## 配置与能力

既有 `efz_config` / `efz_cli` 管理解析。默认 `gleam_layer=>false`；
映射启用一个固定适配器，因此没有适配器注册表或并行 CLI。
既有顶层 `target` 选择受支持测试驱动或带标识测试样例。

| 层字段 | 值 / 默认 |
| --- | --- |
| `structured_fraction` | 整数 0..100 / 10；正值要求 staged 模式 |
| `feedback` | disabled、observation_only、guided / disabled |
| `oracle` | disabled、inline / disabled；拒绝 deferred |
| `oracle_budget` | 整数 0..10000 / 64 |
| `limits` | bytes、fields、component、operations / 4096,32,128,1 |

现有 `mutation.seed`、`random_seed`、`selection_seed` 保留各自职责；
`artifacts`、`corpus_dir`、`crash_dir` 保留位置。
CLI 新增 `--gleam-layer`、`--structured-fraction`、`--semantic-feedback`、
`--semantic-oracle`、`--oracle-budget`；嵌套限制使用 Erlang API。
原生覆盖使用现有原生准备和 API，不是新 CLI 后端。
仅种子准备不会启用运行时回调。

启动检查已知键、类型及范围、目标与模式、仅目标清单、软件包可用性、精确版本，
以及 [p2-integration.md](p2-integration.md)列出的全部八函数核心 API。
数据路径不重复导出或模块检查。
缺少导出返回 `{gleam_configuration,{gleam_callback_unavailable,Function,Arity}}`；
先检查版本再检查其余回调。
缺少软件包返回 `{error,{gleam_configuration,{gleam_package_unavailable,Reason}}}`。
其他启动原因包括 `unsupported_gleam_oracle_policy`、`structured_requires_staged_mode`、
`unsupported_gleam_target`、`invalid_gleam_limits`、`incompatible_gleam_versions`；
它们是固定有界原子，不是不透明 badmatch 诊断。
显式选择覆盖绝不静默回退。不检查外部 fuzzer 能力。
关闭准备返回原配置，不加载可选模块或应用，不增加语义状态、worker、载荷或 RNG 抽取。
关闭构建绝不调用 Gleam。

## 反馈与串行接纳

StructuralFeedback 保持现有 EFZ 收集器单位：presence 探针 `{Module,BuildId,ProbeId}`、
固定模式下原生模块和行单位，或既有计数桶。
不要把它们与语义特征相加称为“覆盖”。

SemanticFeature 恰为 `{<<"cow_qs">>,1,Id}`，Id 0..11。
SemanticSet 是每次执行的排序唯一正规列表。
元数据为 `#{schema_version=>1,namespace=><<"cow_qs">>,feature_version=>1,features=>Fs}`。
精确元组和列表没有哈希或位图表示碰撞。
ID：0 接受、1 拒绝、2 超时、3 异常；4..7 为数量 0、1、2、≥3；
8/9 存在或不存在空值；10/11 存在或不存在 ≥128 字节。
这些是有界事实，不是 UTF-8 验证。

CampaignSemanticState 是语料拥有的 `semantic_seen`：历史成功接纳或注释的精确集合，
≤12 个特征。不是活动引用计数索引。
只追加语料为全部已提交特征保留代表。单次执行重置不清除活动历史。

对于成功主结果 `{ok,_}`（含预期拒绝）：

```text
structural_keep = existing reason in {new_coverage,new_probe,new_hit_count}
semantic_new = execution_features minus corpus.semantic_seen
keep_new_input = structural_keep OR semantic_new is nonempty
```

校准为保留种子加注释；初始及其他既有保留原因不变。
失败结果使用现有发现通道；所观察的超时和异常 ID 不通过此谓词接纳失败。
发现独立于新颖性和语料保留。

`efz_corpus:admit_semantic/4` 在其 gen_server 内串行决策。
新颖性计算不修改 seen。
新原始输入和元数据先经 `add_checked/3` 持久化，再提交 entries/seen。
持久化失败或拒绝不改变 seen，可供重试。无存储时，内存插入即提交。
现有存储同步与重命名持久性策略保留；P1 不新增 fsync 规则。
既有输入注释合并特征和结构证据，保留原接纳原因，不建立重复条目。

纯语义条目工作元数据含 `retention_reason=>new_semantic`，
可供普通 `mutation_entries/0` / `select/0` 使用，不获得新能量策略。
仅观察产生元数据和计数，不改变接纳。独立观察日志不能证明引导。

不存在在线裁剪或引用计数更新。
`efz_semantic:cover/1` 建议保留已记录结构探针、计数及语义并集的子集，
保护初始或未校准条目，不执行删除。
未来合并或裁剪必须保留所需代表，在恢复选择前原子重建 seen/active 索引，
避免历史 seen 抑制已删除代表的替代条目。

`efz_corpus:semantic_representatives/0` 是串行只读冷查询。
返回 `{ok,#{Feature=>ExistingEntryId}}`，最多 12 键；seen 特征无活动代表时拒绝。
关闭或仅观察返回 `disabled`。
索引从实际条目派生，不存储引用计数、缓存，不抽取 RNG。
语义元数据要求精确四键模式和规范有界特征集；超大、不正规或未知 ID 元数据在排序前拒绝。
[P4 证明](p4-feedback.md)把保守子集应用到新存储、重启并验证结构与语义保留。
在线存储编辑不支持；活动间编辑会在显式校准时从当前原始语料重建 seen，
不会使用过时持久化全局索引。

重启验证元数据，再校准全部原始条目，在变异前重建兼容注释和 seen。
EFZC 封装 v1、旧记录 v1/v2 仍接受；语义发现使用记录 v3。
命名空间、模式或特征不匹配导致恢复失败；构建不匹配遵循既有 reject/recalibrate 策略。
恢复的是可复用语料，不是精确活动 PRNG 检查点。

## 观察器、判定器、错误与重放

区间和模块范围隔离在 architecture.md 中固定。
观察器使用主结果的有界、已检查摘要，不解码或执行目标。
启用且有预算的判定器比较受支持规范有序模型字段与已完成解析器结果。
匹配为 Pass；不匹配或拒绝受支持规范模型为 Fail。
普通解析拒绝本身不是缺陷。
不支持、限制、超时、异常或预算耗尽为带原因的 Inconclusive，绝不为 Pass。
纯判定器额外目标调用为零。不实现异步或延迟模式。
未来重复目标执行必须使用独立 EFZ 控制区间、ID、有限预算和调用计数。

| 分类 | 实际策略 |
| --- | --- |
| expected_rejection | 测试驱动枚举解析错误返回 rejected；普通目标结果 |
| target_exception / target_timeout | 现有异常、退出和超时发现及清理 |
| oracle_failure | 独立既有发现存储；原始字节、结果和属性版本旁文件 |
| semantic_layer_error | 独立计数与诊断，以 infrastructure_failure 停止；绝不作为目标缺陷或回退 |
| infrastructure_error | 现有生命周期、覆盖、持久化和配置错误策略 |
| VM/native crash | 仅现有适用外部目标结果；不新增原生捕获器 |

畸形编解码器、变异器或生成器边界返回 `{error,boundary}`。
预期不支持或限制返回 skip；观察器边界故障及抛异常或意外回调结果变为
`{error,{semantic_layer_error,Class,BoundedReason}}`。
目标故障先于语义回调保存；观察器失败不能擦除它们。
耗时检查不是取消，杀死 Erlang 不保证原生执行被中断。

`efz_crash:signature/2` 保留指纹版本、类和原因策略。
判定器发现使用类 oracle_failure、原因 `{query_model_agreement,1}`、空堆栈。
默认 category 指纹按属性标签分类；完整属性、版本和原输入仍在产物中。
重放要求 EFZS v1、兼容向量与属性、原始 SHA256、调用方所选固定测试驱动及目标构建。
产物 term 不能选择可执行回调。
最小化保留相同 v1 属性失败；其他异常、超时或不支持输入不满足它。
有限预算 1..10000 统计目标调用，包括初始复现；原始发现不可变。
结果只声称单字节删除最小性或预算耗尽，不声称全局最小。

样例、退出码、审查限制和交接见 [p1-validation.md](p1-validation.md)。
