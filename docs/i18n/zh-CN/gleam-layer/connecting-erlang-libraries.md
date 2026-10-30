# 将 Erlang 库连接到 Gleam Layer

[English](../../../gleam-layer/connecting-erlang-libraries.md) · [Русский](../../ru/gleam-layer/connecting-erlang-libraries.md) · [Español](../../es/gleam-layer/connecting-erlang-libraries.md) · **简体中文** · [所有语言](../../README.md)

集成使用既有 EFZ 执行、语料、调度器、覆盖、RNG 和重放。
每个活动选择一个适配器。测试驱动保留公开契约 `run(binary()) -> term()`；
实际库函数可具有不同元数并接收 Erlang term。
通用适配器不要求为每个 API 单独建立 Gleam 模型。
协议插件保留原始 wire 字节，不必使用通用 term 编解码器。

[实现结果与验证限制](universal-validation.md)包含保存命令和日志、兼容证据及初步测量。
新通用重放 CLI 已通过静态审查，但尚未执行，也未进行最终隔离比较系列。
用户最近指令禁止新增测试或测量运行。

## 1. 选择 API 与集成层级

| 方法 | 适用情况 | 实际示例 |
| --- | --- | --- |
| 通用 term/API | 参数可用有界 Erlang term 描述 | `lists:reverse/1`、`maps:find/2`、`efz_term_tuple_library:combine/2` |
| 领域或协议 | 需要 wire 语法、相关字段或独立模型 | `efz_xmlrpc_adapter`、`efz_qs_adapter` |
| 有状态测试驱动 | 需要设置、重置、清理及命令列表 | `efz_stateful_target`、`efz_stateful_counter` |

已验证范围：模块位于代码路径，调用通过可复现测试驱动在本地 BEAM 执行，
由 EFZ 管理执行超时和清理。测试驱动提供所需资源。
`-spec` 或模块名不能证明任意结果正确。
套接字、驱动、外部服务、硬件资源及特殊操作系统依赖要求专用测试驱动及独立执行环境验证。

## 2. 创建测试驱动

若 API 有 `-spec` 且 BEAM 带 `debug_info`，可通过
`semantic_scaffold.escript from-beam OUT HARNESS LIBRARY.beam FUNCTION ARITY`
[自动生成](connector-generation.md)测试驱动、配置与种子。
受支持类型会转换成共享适配器模式，无需手写参数描述。


可直接使用的通用示例：

```erlang
-module(example_library_target).
-export([run/1, options/0, semantic_contract/0]).
options() -> #{entrypoint => {lists, reverse, 1},
              arguments => [#{kind => list, item => #{kind => integer}}]}.
semantic_contract() -> (options())#{kind => term_api}.
run(Raw) -> efz_term_codec:execute(Raw, options()).
```

连接自己的 `example_library` 时，修改 `entrypoint`、`arguments` 和测试驱动，不改 EFZ 核心。
`prepare/3` 检查函数可用性、元数，以及测试驱动元数据与适配器选项一致性。
此类库无需新专用软件包。
支持导出元数 0 到 `min(collection, 255)`：默认 `collection => 32` 允许最多 32 参数，
255 是 BEAM 元数上限。零元数使用 `arguments => []`。
结果描述独立于参数约束。

`efz_term_codec:execute/2` 解码规范数据包，并调用 `apply(Module, Function, Args)`，
不进行语义分发或依赖模型。
旧 `efz_term_api_adapter:execute/2` 保留为兼容委派。
不支持或畸形数据包返回 `{efz_term_input_rejected, Reason}`。
库普通 `{error, Reason}` 值仍为普通结果。
测试驱动定义哪些 API 异常属于预期拒绝，并在所选 API 契约要求时显式转换。

测试驱动拥有固定解码范围。未声明 `semantic_contract().input_limits` 时使用编解码器默认值。
活动的 `bytes`、`depth`、`nodes`、`collection` 限制不能超过该范围；
超出时在启动前以 `term_api_input_limits_mismatch` 拒绝。
只要参数约束合法，允许更严格活动限制作为测试驱动结构支持的子集。
原始变异仍可到达测试驱动更宽输入域。

扩展范围时，测试驱动向编解码器传入相同限制并在元数据声明，例如：

```erlang
input_limits() -> #{bytes => 4096, depth => 8, nodes => 256,
                    collection => 64, operations => 1}.
semantic_contract() -> (options())#{kind => term_api,
                                   input_limits => input_limits()}.
run(Raw) -> efz_term_codec:execute(Raw, (options())#{limits => input_limits()}).
```

适配器选项仍为 `entrypoint`、`arguments` 和可选 `property`；
`input_limits` 属于测试驱动契约。
元数据仅接受文档有限范围内的公共限制键；无效元数据产生 `invalid_term_api_input_limits`。
重放时，相同测试驱动及代码标识保留解码范围，语义标识还检查生效活动限制。
独立 `efz_term_custom_limits_target` 样例使用长度超过 32 的列表，验证 collection 边界 64。

脚手架创建可编译源码、配置和种子，不覆盖已有文件：

```sh
ERL_FLAGS='+S 2:2' rebar3 compile
escript scripts/semantic_scaffold.escript generic /tmp/new-api efz_example_target
escript scripts/semantic_scaffold.escript domain /tmp/new-domain efz_protocol_target
```

通用默认使用真实 `lists:reverse/1`。
其他库可在第四参数提供可信 `options.term`，恰好包含
`#{entrypoint => {Module, Function, Arity}, arguments => Specs}`。
脚手架对资源规范返回 `resource_harness_required`：资源生命周期必须显式编写。
领域骨架实现独立长度前缀消息及仅观察插件；模型缺失不产生通过判定器。
编译及 CLI 说明位于生成的 `README.md`。

## 3. 描述参数、场景与能力

通用编解码器模式 1 使用自定义二进制封装，而非 ETF：
`<<"EFZT", 1, ArgumentCount:16, TaggedArguments/binary>>`。
整数字段使用大端序。保留参数列表、类型标签、有界大小和确定性映射键顺序。
原子及资源标签是可信配置中排序有限集合的索引。
模糊测试输入不创建原子。

| `kind` | 额外字段与边界 |
| --- | --- |
| `integer` | 有符号 64 位，`min`/`max`；默认 −1000000..1000000 |
| `float` | 有限 64 位浮点数，有限浮点 `min`/`max`；默认 −1000000.0..1000000.0 |
| `boolean` | `true`/`false` |
| `binary` | 任意字节，`min_length`/`max_length` |
| `charlist` | Unicode 标量整数正规列表，不含代理项；编码由 API 定义 |
| `atom` | 必填有限非空 `values => [existing_atom, ...]` |
| `list` | `item => Spec`、`min_length`/`max_length`、正规列表 |
| `tuple` | `items => [Spec, ...]`，固定元组元数 |
| `map` | `key => Spec`、`value => Spec`，有界大小，编解码器拒绝重复键 |
| `term` | 支持嵌套标量、列表、元组和映射组合；原子仅来自 `atoms => [...]` |
| `resource` | `values => [handle_name, ...]`，保存为 `{'$efz_resource', Handle}` |

`min_length` 默认 0，`max_length` 默认 `collection`（默认 32，最大 256），包括 binary/charlist。
这些默认值下，即使完整数据包允许 4096 字节，二进制参数也只允许 32 字节。
charlist 长度按 Unicode 码点计数：编解码器把每个码点存为带标签有符号 64 位整数，而非 UTF-8 字节。
测试驱动把 charlist 转成具体 API 要求的文本编码。
每个规范中的 atom/resource 枚举最多含 256 个既有原子。

公共默认限制：`bytes => 4096`、`depth => 8`、`nodes => 128`、
`collection => 32`、`operations => 1`；预检最多允许 1 MiB、深度 16、节点 4096、collection 256。
`bytes` 包括头和类型标签。参数根深度为 1；每个列表或元组元素、映射键和值、charlist 码点
都消耗节点预算。参数列表封装自身不单算节点。
参数配置与数据分别验证。PID/ref/port/fun 不是可移植字面输入。
观察器可报告其有限结果类别，不保存值本身。

有状态示例编码一个参数：最多 16 个元组 `{ResourceHandle, Command, Integer}` 的列表。
命令 `get`、`put`、`add`、`reset` 从有限集合选择。
`semantic_contract/0` 声明 `resource_lifetime => execution, resource_handles => [counter]`。
`efz_stateful_target:scenario/1` 通过允许的 EFZ 子进程生成 `efz_target:spawn_link/1`
创建新未注册 gen_server，设置 OTP 27 `proc_lib` 元数据（`'$ancestors'`、`'$initial_call'`），
并进入公开 `gen_server:enter_loop/3`。
测试驱动不调用内部 `proc_lib` 函数，但这些进程字典键绑定已验证 OTP 27 生命周期。
这是已验证 OTP 27 启动样例，不保证任意 OTP 生命周期支持：
EFZ 执行内普通不受管理 `gen_server:start_link/3` 会被拒绝。
在 EFZ 外直接运行时，测试驱动使用普通 `start_link`。
测试驱动将符号句柄解析为 PID、执行命令并在 `after` 停止进程；
`semantic_contract/0` 声明 `execution_modules => [efz_stateful_counter]`。
每次执行或重放从零状态开始。
一个输入是一主执行；有界结果单独包含 `scenario_executions => 1`、`library_operations => N`、
`trace => [...]`。`N` 只计场景命令，不计设置及进程关闭。
其他资源由用户扩展测试驱动，不修改调度器或 worker。

## 4. 选择标准适配器或自定义插件

精确公开接口见 [adapter-contract.md](adapter-contract.md)。
`descriptor/0` 和冷路径 `prepare/3` 必需；准备上下文不可变。
描述符固定适配器 ID、API、模型、观察器、配方及操作版本、能力、操作 ID、模型模块和属性。
可选冷回调 `code_dependencies(Context) -> #{semantic => [module()], target => [module()]}`
把额外辅助或属性代码和目标依赖 BEAM 绑定现有标识机制。
描述符已绑定适配器自身和其模型模块。标识依赖本身不增加覆盖。
通用适配器还把 `efz_term_codec` 绑定为语义依赖：
修改解码或归一化辅助函数会像修改模型一样拒绝旧语义重放。
冷通用准备检查真实 Gleam 导出 `scalar/4` 和 `observe/6`；
模型模块缺失或 ABI 不兼容会在活动前拒绝。
不依赖模型的测试驱动执行及编解码器种子创建无需该检查。

只有声明对应能力，操作回调才必需：

```erlang
generate(Index, Context) -> {ok, Raw} | {skip, Reason} | {error, Reason}.
mutate(Raw, Operation, #{choice := Choice}, Context) ->
    {ok, Raw, RecipeData} | {skip, Reason} | {error, Reason}.
observe(Raw, PrimaryOutcome, Context) ->
    {ok, LocalFeatureIds} | {skip, Reason} | {error, Reason}.
oracle(Raw, PrimaryOutcome, Context) ->
    {pass, Property} | {fail, Property} | {inconclusive, Reason} | {error, Reason}.
shrink(Raw, Context) -> {ok, Candidates} | {skip, Reason} | {error, Reason}.
```

skip/inconclusive 的 `Reason` 为原子；`Property` 恰为描述符中的 `{Id, Version}`。
特征最多 64 个本地 ID，范围 0..255。
分发器添加 `{AdapterId, ObserverVersion, LocalId}`；不同适配器相同本地 ID
不会彼此混淆，也不与结构覆盖混合。
生成和变异是确定性的；`choice` 0..65535 来自 EFZ RNG，并记录于配方。
适配器不为每个回调创建自身 RNG、注册表、worker 或进程。

若 `example_library` 有特殊 wire 格式，使用领域骨架：替换目标调用、元数据和观察器；
必要时增加自定义 Gleam 模型，在 `model_modules` 声明名称、实现有界生成与变异及独立属性。
中心分发没有依据该库名的分支。
仅观察描述符可设置 `model_modules => []`、`operations => []`、`properties => []`；
相应配置使用 `structured_fraction => 0`、`oracle => disabled`。
也允许没有观察器或判定器的仅生成插件，反馈关闭、比例 0。

Gleam 模型可作为单独 Erlang/rebar3 依赖提供：预先编译并导出 BEAM，
把依赖的 `ebin` 和所需运行时依赖添加到可选活动代码路径，并在描述符声明模型模块。
普通 EFZ 构建不得下载或编译该软件包。
仓库可选构建使用固定 Gleam 1.10.0；运行时关闭和普通构建不调用模型。

## 5. 配置种子、变异、观察器与判定器

可运行活动映射位于 [examples/semantic_configs](../../../../examples/semantic_configs)：
`lists_reverse.term`、`maps_find.term`、`tuple_api.term`、`stateful.term`、
`xmlrpc.term`、`cow_qs.term`、`cow_qs_legacy.term`。
种子使用真实编解码器及各测试驱动参数规范创建；XML/QS 种子保持原 wire 二进制。
这些配置以 `coverage_backend => none` 进行执行及语义冒烟测试，
不声称测量了 stdlib API 的结构覆盖。

```erlang
gleam_layer => #{adapter => efz_term_api_adapter,
    adapter_options => #{entrypoint => {lists, reverse, 1},
        arguments => [#{kind => list, item => #{kind => integer}}]},
    structured_fraction => 10, feedback => guided, oracle => disabled,
    oracle_budget => 64,
    limits => #{bytes => 4096, depth => 8, nodes => 128,
                collection => 32, operations => 1}}
```

通用观察器分类结果及有界结果树，不证明库正确性。
通用判定器保持关闭，直到用户设置
`adapter_options.property => #{callback => {Module, Function}}` 和 `oracle => inline`。
回调接收 `(DecodedArgs, PrimaryOutcome)`，返回 `true`、`false` 或 `inconclusive`；
谓词 ID 为 `{generic_custom_property, 1}`，单独记录回调代码标识。
`stateful.term` 显式选择独立计数器轨迹属性。

`guided` 将语义新颖性接纳至普通语料及父输入选择。
`observation_only` 报告特征，但不引导语料或调度器。
`disabled` 关闭观察器。
`structured_fraction => 0` 不进行分支 RNG 抽取或变异解码；已启用观察器和判定器继续工作。
`gleam_layer => false` 关闭全部分发，保留普通 RNG 路径。

变异中的 `skip`、未改变和限制使用普通字节回退。
层异常或无效结果会将活动作为适配器自身基础设施错误结束；既不是库发现，也不是成功回退。
`inconclusive` 表示没有合理判定。
预期解析拒绝若未违反显式指定且受支持的属性，不会成为发现。
回调内联运行；异常会被捕获，但不能因此停止无限回调。
插件必须使用有限算法，并在昂贵分配或递归前检查预算。

QS 不带 `adapter` 的旧配置仅经针对历史 `efz_qs_target`/`efz_qs_defect_target` 的隔离旧 shim 工作。
该规则不参与新目标连接。
显式 `efz_qs_adapter` 检查测试驱动元数据 `#{kind => query_string, outcome => accepted_pairs}`。
QS 专用 `fields` 和 `component` 属于 `adapter_options`，不属于公共限制。

XML-RPC 使用[固定 etnt/xmlrpc 准备流程](../examples/xmlrpc/README.md)。
`efz_xmlrpc_target` 对 charlist 调用 `xmlrpc_decode:payload/1`。
独立模型 v1 检查可打印 ASCII methodCall、int/boolean/string 及嵌套 array/struct，
带 bytes/depth/nodes/collection/string 限制。
名称从现有原子或 charlist 归一化为二进制，不创建原子。
判定器 v1 不支持 response/fault 正确性、i4/double/date/base64/nil、隐式字符串、
非 ASCII UTF-8 或更广泛 XML 语法。
观察可分类 response/fault，不证明其正确性。

## 6. 准备仅目标覆盖产物

使用既有 `efz_instrument:compile/2` 或 `efz_cov_native_public:compile/3`，
再执行标准产物预检。选择库自身模块，排除适配器、模型和属性辅助代码。
测试驱动及基础设施编解码器不能替代库覆盖。
没有准备好覆盖后端的内置 OTP API，应如实使用 `none`/diagnostic 并单独记录限制。

XML-RPC 准备对 `xmlrpc_decode` 和 `xmlrpc_util` 插桩。
OTP xmerl 仍是依赖，不测量其内部覆盖。
`xmerl.hrl` 记录默认值要求文档指定的 `strict => false`；可执行解码器子句仍有探针。
例如计数器样例：

```erlang
{ok, A} = efz_instrument:compile("examples/stateful/efz_stateful_counter.erl",
    #{modules => [efz_stateful_counter], outdir => "/tmp/counter-artifacts",
      source_root => ".", erl_opts => [debug_info, warnings_as_errors]}).
```

准备后将配置改为 `coverage_backend => ets, artifacts => [A]`，
或向 CLI 传入 `--artifacts /tmp/counter-artifacts`。
仅在代码路径中存在依赖，不足以声称已测量它的覆盖。
计数器样例另行检查了已接纳子进程内 ETS 探针及没有残留进程的清理。
覆盖对象是 `efz_stateful_counter` 自身，不含 OTP 内部 `gen_server`/`proc_lib` 模块。

## 7. 运行验证与活动

从 EFZ 根目录执行：

```sh
ERL_FLAGS='+S 2:2' rebar3 compile
GLEAM_BIN=/path/to/gleam-1.10.0 ERL_FLAGS='+S 2:2' rebar3 as gleam compile
ERL_FLAGS='+S 2:2' rebar3 eunit --module=efz_term_api_tests
ERL_FLAGS='+S 2:2' escript scripts/fuzz.escript \
  --config examples/semantic_configs/lists_reverse.term \
  --code-path _build/gleam/lib/efz/ebin --out /tmp/reverse-run
ERL_FLAGS='+S 2:2' escript scripts/fuzz.escript \
  --config examples/semantic_configs/stateful.term \
  --code-path _build/gleam/lib/efz/ebin --out /tmp/counter-run
```

`--config` 经 `file:consult` 读取恰好一个可信 Erlang 活动映射。
代码路径在 consult 和预检前加载。
显式提供的既有 CLI 标志覆盖配置；`--seeds DIR` 导入原始文件，`--artifacts DIR` 覆盖产物。
`--out` 仍必需。配置不保存可执行闭包、资源 PID 或秘密。
可信配置可指定原子；这是与不可信模糊测试字节分开的边界。
旧 CLI 标志没有改名。

启动检测未知适配器、缺少必需回调或模型、不兼容元数据与选项、不支持能力及覆盖选择。
未显式给适配器的 `--gleam-layer` 保持历史 QS CLI 兼容路径；
新集成使用含 `adapter` 的配置。

XML-RPC 先运行 `examples/xmlrpc/prepare.escript`，再通过 `--code-path`
添加 `_build/xmlrpc-example/dependency-ebin` 和 `_build/xmlrpc-example/harness-ebin`。
QS 添加 `_build/default/lib/cowlib/ebin`。
完整变更验证包括普通和可选构建、运行时关闭、相关 EUnit/CT、xref/Dialyzer，
以及带报告和产物证据的有限活动。
比较结果必须分别报告墙钟时间、执行预算、校准/变异/额外执行、提供器结果、覆盖及适配器本地语义新颖性。
不同适配器的特征数量不是共同量尺。
回调微基准不能替代活动吞吐或发现证据。

## 8. 检查持久化、重放与最小化

规范语料保存原始二进制。
重启使用当前适配器重新校准输入，不信任其他模型保存的语义特征。
既有 `corpus_build_policy => reject | recalibrate` 定义不匹配策略。
适配器、模型、选项、限制、观察器、属性及操作目录版本、代码和执行标识、RNG 来源信息
均包含于现有元数据。
标识还记录确定性可移植准备上下文的 SHA-256；冷上下文必须可复现，否则重放不匹配。

重建原始输入和执行它是独立操作。
模式 4 的 `efz_recipe:load/1` 和 `efz_recipe:regenerate/1` 重建保存的原始替换字节，
经 EFZ 核心验证配方及 RNG 来源信息。
不加载适配器或模型、不执行目标、不解码不透明适配器选项或 RecipeData。
历史 QS 配方模式保留此前原始重放保证。

执行重建输入要求目标、测试驱动及依赖产物，不进行语义回调分发，也不需要适配器或模型 BEAM。
本指南通用测试驱动使用不依赖模型的 `efz_term_codec:execute/2`：
编解码器 BEAM 仍是普通执行依赖。wire 格式测试驱动直接调用库。
自定义测试驱动也应将执行依赖与可选语义回调分开。

`efz_recipe:regenerate_semantic(Recipe, PreparedLayer)` 使用保存操作及参数重跑结构化变异，
检查原始字节和 RecipeData 是否匹配。
此可选检查要求从可信配置新准备上下文、精确适配器标识、可用适配器及模型 BEAM。
它同样不执行目标。
下方语义属性重放检查实际目标执行结果，要求独立属性契约。

```erlang
{ok, Expected} = efz_semantic_replay:load("finding.semantic"),
ReplayOptions = #{timeout => 1000, coverage_backend => none,
                  gleam_layer => TrustedLayerConfig},
efz_semantic_replay:run(Raw, Target, TargetArtifacts, Expected, ReplayOptions),
efz_semantic_replay:minimize(Raw, Target, TargetArtifacts, Expected,
    ReplayOptions#{minimization_timeout_ms => 30000}, 64).
```

`none` 匹配上述冒烟配置。
对于保存的 ETS 或原生产物，选择原始 `coverage_backend` 并提供相同精确产物。

通用 CLI 提供相同契约，不含库专用分支：

```sh
ERL_FLAGS='+S 2:2' escript scripts/gleam_replay.escript \
  --config trusted-campaign.term --finding /path/to/finding-prefix \
  --budget 64 --out /tmp/new-replay-result \
  --code-path _build/gleam/lib/efz/ebin --code-path /path/to/harness/ebin
```

可信配置指定 `target`、`artifacts`、`coverage_backend`、`gleam_layer`、`timeout`
及可选 `max_input_bytes`；此 CLI 不执行种子或语料。
重放支持 `ets`、`ets_member`、`otp_native_public` 和 `none`；
活动后端 `bitmap` 尚不受此重放执行 API 支持，会在目标执行前被拒绝。
选项或配置错误退出码 2。
CLI 先用可信配置生效限制做冷验证，并比较完整适配器标识。
相对发现增加或减少这些限制都会在目标执行前不匹配；
发现中记录的字节上限不会替换显式选择的更大配置限制。
冷验证及读取发现都不调用目标。
发现不选择可执行代码：只读取 `.input` 和 `.semantic`，无需诊断 `.term`。
输出目录必须不存在，包括符号链接；只有实际复现后才创建结果。
`not_reproduced` 和 `inconclusive` 在最小化前以码 1 退出，不产生输出。
预算 1..10000 包含初始重放及全部最小化器目标执行：
预算 1 只保存 `replay.*`；更大预算还保存 `minimized.input`、`minimized.semantic` 和 `minimization.term`。
结果保存实际截止时间或预算状态及总执行数。
最小化器截止时间为 30000 ms：之后不安排新候选执行；
已开始执行受独立目标 `timeout` 限制。
若因预算或截止时间跳过最终验证，明确记录 `{skipped,budget}` 或 `{skipped,deadline}`。
保存输入在最后一次候选检查时复现了谓词（若输入未变则为初始复现）；
这种情况下不声称额外最终检查。

旧五参数命令继续作为明确受限的 QS 旧版辅助工具，委派给 `scripts/gleam_replay_legacy.escript`。
历史目标名、原生 `cow_qs` 产物和诊断 JSON 仅保留在该工具；新集成使用 `--config`。

语义属性重放要求显式可信调用方配置、匹配的适配器/模型/属性/目标标识及代码路径。
产物自身不选择适配器或回调模块。不兼容被拒绝，不静默替换谓词。
最小化使用相同属性 ID、版本和谓词，计入每次目标执行、初始复现及最终验证。
不保证全局最小，并报告截止时间或预算耗尽。
结果单独保存，不覆盖规范语料和原始发现分组。
