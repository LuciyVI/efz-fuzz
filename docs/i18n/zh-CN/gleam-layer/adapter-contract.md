# 语义适配器 API 1

[English](../../../gleam-layer/adapter-contract.md) · [Русский](../../ru/gleam-layer/adapter-contract.md) · [Español](../../es/gleam-layer/adapter-contract.md) · **简体中文** · [所有语言](../../README.md)

此契约在实现前冻结。EFZ 管理执行、RNG、调度、覆盖、语料和重放。
每个活动只准备一个显式适配器。回调在 EFZ VM 中内联运行，必须采用有限算法。
捕获异常无法抢占循环；可信插件代码必须实施其文档规定的边界。

必需回调：

```erlang
descriptor() -> #{id := binary(), api_version := 1, model_version := pos_integer(),
    observer_version := pos_integer(), recipe_version := pos_integer(),
    operations_version := pos_integer(), capabilities := [capability()],
    operations := [non_neg_integer()], model_modules := [module()],
    properties := [{atom() | binary(), pos_integer()}]}.
prepare(Target :: module(), Options :: map(), Limits :: map()) ->
    {ok, ImmutableContext :: term()} | {error, Reason :: term()}.
```

能力包括 `generation`、`mutation`、`observation`、`oracle`、`shrink`。
只有声明的能力才要求对应回调。最小仅观察或仅生成插件不需要解析器、变异器或判定器。
描述符 ID 最多 64 字节；版本为正整数。操作 ID 为 0..65535 的唯一整数。
模型模块和适配器模块排除在目标覆盖之外。测试驱动可导出 `semantic_contract/0`；
插件在 prepare/3 验证该元数据，不依靠中心化目标名允许列表。运行时关闭的目标无需此元数据。

可选操作回调（声明能力后必需）：

```erlang
generate(Index :: non_neg_integer(), Context) ->
    {ok, binary()} | {skip, atom()} | {error, term()}.
mutate(Raw :: binary(), Operation :: non_neg_integer(), Params :: map(), Context) ->
    {ok, binary(), RecipeData :: map()} | {skip, atom()} | {error, term()}.
observe(Raw :: binary(), PrimaryOutcome :: term(), Context) ->
    {ok, [LocalFeatureId :: 0..255]} | {skip, atom()} | {error, term()}.
oracle(Raw :: binary(), PrimaryOutcome :: term(), Context) ->
    {pass, Property} | {fail, Property} | {inconclusive, atom()} | {error, term()}.
shrink(Raw :: binary(), Context) ->
    {ok, [binary()]} | {skip, atom()} | {error, term()}.
```

Property 必须恰为 `{Id, Version}`，并出现在描述符 `properties` 中。
观察器返回最多 64 个本地 ID 的列表；允许重复，由分发器去重。
分发器加上 `{AdapterId, ObserverVersion, LocalId}`；命名空间不含输入相关字符串。
`PrimaryOutcome` 是现有 EFZ 执行器结果（`{ok, Value}`、超时、崩溃或退出）。
适配器在调用 Gleam 前验证并摘要其支持的子集。API 1 的观察与判定器绝不再次执行目标。

Mutation Params 必须恰为 `#{choice => Integer}`（0..65535），由 EFZ RNG 抽取并记录；
额外键属于边界错误。shrink 最多返回 64 个二进制候选，各自遵守生效字节上限。
门面接受生成索引 0..4095。版本整数范围 1..65535；操作目录最多 256 项，
model_modules/properties 各最多 32 项。描述符键必须与上文完全一致，能力和操作 ID 唯一，
声明变异或判定器能力要求非空目录或属性列表。
默认限制为 bytes 4096、depth 8、nodes 128、collection 32、operations 1；
公共可接受范围为 bytes 0..1048576、depth 1..16、nodes 1..4096、collection 1..256，
operations 必须为 1。生效字节上限还遵守活动 max_input_bytes。
适配器没有独立 RNG。RecipeData 是有界数据，不是可执行代码。
新配方记录 API、模型、操作目录标识，选项与限制，操作、参数和 EFZ RNG 状态。
普通原始重放使用保存字节，绝不加载插件。配方重新生成是独立的可选操作。

`skip` 表示格式、大小或限制不支持；变异使用常规字节回退；未改变的变异同样回退。
`inconclusive` 表示无充分依据作出判定器判断。
`error` 或捕获的回调异常属于层错误，绝不是目标发现。
预期解析拒绝是目标结果，不会自动成为判定器失败。
只有显式且受支持的属性失败才创建发现。
分发器验证所有输出类型和大小。公共限制为 `bytes`、`depth`、`nodes`、`collection`、
`operations`（API 1 为一个）；插件专有限制在 adapter_options 中验证。
回调上下文不可变，只准备一次。
可移植 options/context/RecipeData 接受有限原子、有界整数和有限浮点数、二进制、
正规列表、元组和映射；拒绝运行时 PID/ref/port/fun 值。
边界遍历最多深度 24、8192 数据节点、元组或映射大小 256，单个二进制最多 1 MiB。
编码后的选项最多 65536 字节、上下文最多 1 MiB、RecipeData 最多 4096 字节、
错误详情最多 1024 字节。这些冷路径或边界数据限制不同于插件对输入表示实施的限制。

语义属性产物固定描述符、适配器与模型 BEAM 标识、生效配置、目标与测试驱动构建及属性版本。
重放必须接收显式可信适配器配置；产物数据绝不选择代码。不匹配会拒绝重放。
语料重启使用当前回调重新校准保存的原始字节；不信任持久化语义命名空间作为校准结果。
缩减必须使用相同属性谓词并统计每次目标执行；原始输入和原发现分组保持不变。

历史 QS 门面签名和模式 1 QS 产物保留为隔离的兼容接口。
仅旧 QS shim 接受没有 `adapter` 的配置。新集成必须显式选择适配器。

冷路径可选回调 `code_dependencies(Context) -> #{semantic := [module()], target :=
[module()]}` 每类可声明最多 32 个模块。
EFZ 使用现有 BEAM 标识机制固定其代码。
语义辅助函数和属性排除在目标覆盖之外；声明的目标依赖可选择收集覆盖。
此回调使动态配置属性和 API 可复现标识，而无需分发器了解选项名。
缺少该回调表示没有额外模块。
持久化标识把生效适配器选项保存为不透明未压缩 ETF 字节；
原始重放绝不解码选项或驻留插件专有原子。
描述符模块和属性名是可移植二进制。
语义重放与新准备的可信调用方配置比较。
同一标识还固定确定性可移植准备上下文的 SHA-256（编码上下文最多 1 MiB）。
改变冷上下文不能静默改变已记录重放谓词。
prepare/3 必须可从声明的目标、选项和环境复现；
不可复现环境配置会产生明确标识不匹配。

新结构化来源信息把回调 RecipeData 保存为不透明确定性 ETF 字节（最多 4096），
避免原始配方解码时引入适配器专用原子。
模式 4 配方再生使用保存的替换字节；单独的显式再生 API 则要求兼容可信适配器配置。
