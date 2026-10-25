# Gleam Layer：实现与可验证结果

[English](../../../gleam-layer/universal-validation.md) · [Русский](../../ru/gleam-layer/universal-validation.md) · [Español](../../es/gleam-layer/universal-validation.md) · **简体中文** · [所有语言](../../README.md)

**截至 2026 年 10 月 13 日的当前状态：在所述契约内 P5 PASS。**
按用户要求，检查已恢复并完成，参见 [p5-validation.md](p5-validation.md)。
下方历史 10 月 10 日报告保留当时状态和限制。

截至 2026 年 10 月 10 日：公共契约、term/API 适配器、QS 与 XML-RPC 插件、
有状态测试驱动及持久化和重放集成已实现。
实际调用和主要检查在用户最新“不要运行测试”指令之前进行。
之后只做静态审查、重放脚本及文档修改、查看既有产物。

完整验收仍开放：新通用重放 CLI 尚未运行，比较测量对应较早快照。
遵循用户指令，没有针对最终源码运行新的隔离系列。
下方保存测量既不是性能验收，也不是加速或发现能力改进证据。

## 初始状态与工作保留

基线：`e4c0244c403d74b041df7e0e2f0dd4465a977453`，分支 `feat/gleam-layer`。
HEAD 未变。编辑前保存了
[baseline.json](../../../../artifacts/gleam-layer/20261010-universal/baseline.json)、
[user-before.status](../../../../artifacts/gleam-layer/20261010-universal/user-before.status)
和 `user-before.patch`。
用户未跟踪 `artifacts/`、`efz_socket_regression_pack/`、`fuzz/` 原本已存在；
未执行 reset/clean/stash，未替换用户语料及发现。
本次结果添加到 `artifacts/gleam-layer/20261010-universal/`。

旧层使用 `git archive HEAD` 在 `/tmp/efz-universal-baseline-e4c0244` 创建独立源码副本，
不改主工作副本。这是独立 checkout，不是 Git worktree。
设置：OTP 27.0 / ERTS 15.0、Rebar3 3.25.0、`ERL_FLAGS='+S 2:2'`、
来自 `/tmp/efz-gleam-toolchain/gleam` 的 Gleam 1.10.0。
通过网络获取基线依赖未完成；使用既有本地固定依赖缓存。
基线普通及可选编译通过。基线完整 EUnit 未通过：269 通过、1 失败并有取消测试；
日志保存为 [baseline-eunit-prior.log](../../../../artifacts/gleam-layer/20261010-universal/baseline-eunit-prior.log)。
失败包括旧 corruption/scheduler 测试的墙钟等待。
当前测试包装增加等待超时，保留执行预算和所检查断言。这不是基线性能修复。

## 架构与公开契约

[efz_semantic_adapter.erl](../../../../src/efz_semantic_adapter.erl) 是公开 behaviour；
[efz_gleam_adapter.erl](../../../../src/efz_gleam_adapter.erl)提供冷预检、分发和共享结果验证。
不存在中心化新库或目标列表。
适配器在自己的 `prepare/3` 检查与测试驱动元数据兼容性。
每个活动显式选择一个适配器。

精确签名和边界记录于 [adapter-contract.md](adapter-contract.md)：

```erlang
descriptor() -> DescriptorMap.
prepare(Target, Options, Limits) -> {ok, ImmutableContext} | {error, Reason}.
code_dependencies(Context) -> #{semantic => [Module], target => [Module]}.
generate(Index, Context) -> {ok, Raw} | {skip, Atom} | {error, Reason}.
mutate(Raw, OperationId, #{choice => Integer}, Context) ->
    {ok, Raw, RecipeDataMap} | {skip, Atom} | {error, Reason}.
observe(Raw, PrimaryOutcome, Context) ->
    {ok, LocalFeatureIds} | {skip, Atom} | {error, Reason}.
oracle(Raw, PrimaryOutcome, Context) ->
    {pass, {PropertyId, Version}} | {fail, {PropertyId, Version}} |
    {inconclusive, Atom} | {error, Reason}.
shrink(Raw, Context) -> {ok, [RawCandidate]} | {skip, Atom} | {error, Reason}.
```

只有 `descriptor/0` 和 `prepare/3` 必需；`code_dependencies/1` 可选。
声明对应能力后，操作回调才必需。
描述符包含稳定二进制 ID、API 版本 1、模型/观察器/配方/操作目录版本、能力、
操作 ID 目录、模型模块及属性 ID 和版本。
生成索引 0..4095；唯一变异参数 `choice` 为 0..65535；目录最多 256 个唯一 ID，范围 0..65535。
观察器最多返回 64 个本地 ID，范围 0..255。
分发器创建命名空间 `{AdapterId, ObserverVersion, LocalId}` 并去重。
Shrink 最多返回 64 个有界二进制候选。全部版本范围 1..65535。

EFZ 保留自己的循环、RNG、调度器、变异计划、反馈和语料。
回调在 BEAM 内联运行，上下文不可变。
没有新引擎、NIF、模型服务、必需 worker 或每回调独立进程。
API 1 传入唯一主执行的已完成结果；观察和判定器不重跑目标。
catch 处理异常，但不停止无限回调：插件必须实现有限算法及预算。

变异中的 `skip`、未改变和限制使用既有字节回退。
`inconclusive` 不创建发现。
无效回调或异常是导致活动结束的基础设施层错误，不是库缺陷。
只有在受支持子集中显式违反声明属性才创建发现。
此类谓词之外的预期解析拒绝不会成为语义发现。

`gleam_layer => false` 不进行语义分发、模型解码或额外 RNG 抽取。
比例 0 不选择结构化分支或解码变异；单独启用的观察器和判定器仍正常工作。
`observation_only` 不引导语料或调度器。
`guided` 把纯语义输入接纳到普通语料，参与标准父输入选择。

## Term/API、领域与有状态集成

[efz_term_codec.erl](../../../../src/efz_term_codec.erl)用自定义确定性 `EFZT` 二进制编解码器模式 1
保存参数列表，不改变原始 XML/QS 输入。
支持有符号 64 位整数、有限浮点、布尔、二进制、Unicode 标量 charlist、正规列表、元组、
映射和有界嵌套组合。
原子仅来自可信配置中有限既有原子集合；模糊字节不创建原子。返回类型不定义参数。
通用观察器有界分类结果及结果树，不证明任意 API 正确。

[efz_term_api_adapter.erl](../../../../src/efz_term_api_adapter.erl)使用共享 Gleam 原语 `efz_term_model`，
每个库不需要新软件包。通用判定器默认关闭。
自定义属性单独指定回调 `(DecodedArgs, PrimaryOutcome) -> true | false | inconclusive`，
ID 为 `generic_custom_property`、版本 1，有独立代码标识。
五种结构操作在约束内修改标量、插入或删除元素、替换子树、转换有界容器。
EFZ 决定 RNG 并记录来源信息。

同一适配器验证过的集成：

| API | 测试驱动或配置 | 参数和结果 |
| --- | --- | --- |
| `lists:reverse/1` | `efz_term_reverse_target`、[lists_reverse.term](../../../../examples/semantic_configs/lists_reverse.term) | 整数列表 → 列表 |
| `maps:find/2` | `efz_term_maps_target`、[maps_find.term](../../../../examples/semantic_configs/maps_find.term) | 键和映射 → `{ok, Value}` 或 `error` |
| `efz_term_tuple_library:combine/2` | `efz_term_tuple_target`、[tuple_api.term](../../../../examples/semantic_configs/tuple_api.term) | 映射和元组 → Erlang term |
| 有状态计数器 | `efz_stateful_target`、[stateful.term](../../../../examples/semantic_configs/stateful.term) | 命令列表和资源句柄 → 有界轨迹 |
| XML-RPC | `efz_xmlrpc_target`、[xmlrpc.term](../../../../examples/semantic_configs/xmlrpc.term) | 原始 XML 字节 → 解码器 term |
| cow_qs | `efz_qs_target`、[cow_qs.term](../../../../examples/semantic_configs/cow_qs.term) | 原始 QS 字节 → 解析器键值对或拒绝 |

假设的 `example_library` 标准路径：添加带 `run/1` 和 `semantic_contract/0` 的测试驱动，
配置 `{Module, Function, Arity}` 和参数，选择 `efz_term_api_adapter`。
特殊 wire 约束可使用相同 behaviour 增加领域适配器和模型。
worker、配置、语料、调度器和重放不变。
独立长度前缀插件样例仅通过目标、适配器、配置实现；仅观察和仅生成样例无需 XML/QS 模型、
变异或判定器。两个适配器的本地特征 ID 1 获得不同命名空间。

默认：bytes 4096、depth 8、nodes 128、collection 32、operations 1；
最大：1 MiB、深度 16、节点 4096、collection 256。
默认二进制或 charlist 参数还受 collection 32 限制，不是完整 4096 字节。
charlist 编解码器把码点存为带标签整数；测试驱动转换为所需 API 编码。
支持元数 0..min(collection,255)。
活动解码范围不能超过测试驱动声明的 `semantic_contract.input_limits`。
单独样例用长度超过 32 的列表检查 collection 64。

PID/ref/port/fun 不能作为可移植字面输入保存。
符号 `{'$efz_resource', Handle}` 通过有限枚举编码；测试驱动为执行或重放重建资源并在 `after` 清理。
有状态计数器允许最多 16 条 get/put/add/reset 命令，每输入重置状态为零并创建新未注册 gen_server。
EFZ guardian 要求已接纳子进程生成；样例使用 `efz_target:spawn_link/1`、
OTP 27 proc_lib 元数据及公开 `gen_server:enter_loop/3`。
与 OTP 27 的绑定有文档记录；不会自动支持任意不受管理 OTP spawn 或资源。
轨迹分别记录 `scenario_executions => 1` 和 `library_operations => N`；设置和清理不计入 N。
已检查独立结果、无状态跨输入传递、异常和超时清理。

## 持久化、标识与兼容

使用既有 BEAM 和执行标识机制，而非第二套存储。
语义标识包括描述符、适配器、模型、辅助及目标代码标识、不透明确定性选项、
生效限制，以及可移植准备上下文 SHA-256。
属性 ID 和版本、观察器和目录版本、RNG 来源信息保存在元数据。

新配方模式 4、操作版本 3 包含有界原始替换及不透明 RecipeData。
原始加载、再生和重放不需要适配器或模型；
通用测试驱动仍需普通编解码器 BEAM 作为执行依赖。
`regenerate_semantic/2` 是单独可选变异回调检查，要求精确标识。
语义属性产物模式 2 要求显式可信配置及匹配的目标、测试驱动、适配器、模型和属性标识。
产物不选择代码。重启保留规范原始字节，经标准校准重新计算反馈；
不匹配遵循 `reject | recalibrate`，不静默复用外来特征。

最小化保留相同属性 ID、版本、上下文和谓词，并计入初始复现、全部候选及最终验证。
结构化 shrink 只向既有谓词提供候选，之后进行字节缩减。
不覆盖规范语料和原发现分组。
明确报告预算或截止时间耗尽；不保证全局最小。

QS 模型 `efz_qs_model` 保留。特定操作、限制、结果、特征及 `query_model_agreement`
移入 `efz_qs_adapter`。
`efz_qs_legacy` 仅包含两个历史 QS 目标的旧隐式配置，不是新库集成路径。
旧直接门面签名、配方模式 1/2/3 和 QS 发现模式 1 保留此前保证。
旧变异保留此前 RNG 抽取；新显式适配器还记录 `choice`，
因此新旧配置活动轨迹不必匹配。

固定前后探针比较了 24 个生成案例、11 个样例、66 个操作，以及解码、结果、特征和判定器。
结果相同，SHA-256：
`daa8274871c75cc0a611e9509b5154b9d1a335d6ac986694f103ada30cd6c87e`。
参见 [qs-compatibility.json](../../../../artifacts/gleam-layer/20261010-universal/qs-compatibility.json)。
此样例证据补充真实回归测试，不代替其差异。

通用 `scripts/gleam_replay.escript` 现接受 `--config`、`--finding`、`--budget`、`--out`
和重复 `--code-path`。
冷预检在执行前比较生效可信限制和标识；工作流程预算包括重放及最小化器。
复现后才创建输出；已有目录或符号链接被拒绝。
五参数 QS 主体移至独立 `gleam_replay_legacy.escript`。
**在禁止运行测试的指令之后，新包装及转发只经静态审查，尚未通过执行验证。**
主要 Erlang 重放和最小化 API 此前已检查。

## XML-RPC：实际范围

使用 etnt/xmlrpc 提交 `fb46463b2acadf164ec534d9e2033e194341c507`，
标识和产物准备位于 `_build/xmlrpc-example/`。
`efz_xmlrpc_target:run/1` 把原始二进制转换为 charlist，调用真实 `xmlrpc_decode:payload/1` 一次。
不使用 HTTP/TCP、应用方法或编码器。

独立 Gleam 模型 v1 支持 methodCall、参数、显式 int32、boolean 0/1、string、嵌套 array/struct。
支持可打印 ASCII U+0020..U+007E 和五个预定义 XML 实体，使用有限精确 XML 语法。
示例限制：4096 字节、深度 8、节点 128、collection 16、字符串或名称 128 字节。
方法和成员名从现有原子或 charlist 归一化为二进制，不创建原子。
比较独立模型语义值与实际解码器语义值，不比较 XML 字节。

判定器、生成和变异不支持 response/fault、i4、double、date、base64、nil、隐式字符串、
非 ASCII UTF-8、更广 XML 语法、标签间空白、属性、自闭合标签、数字实体、DTD、CDATA 或命名空间。
观察器可分类 response/fault，不是其正确性判定器。
编码器属性和语义往返也未实现。
其原子名称要求或 iolist 输出不会扩展解码器谓词。

目标覆盖只含准备好的 `xmlrpc_decode`/`xmlrpc_util`。
`xmerl_scan` 参与执行标识，但内部覆盖未测量。
xmerl.hrl 记录默认值要求 `strict => false`；可执行解码器子句有探针。
适配器、模型、观察器、判定器和核心辅助代码不在目标覆盖内。
无准备产物的 stdlib API 使用 `none`。

## 已执行检查

下方命令记录已完成运行。用户禁止后未重复运行。
日志位于 `artifacts/gleam-layer/20261010-universal/`。

| 命令或检查 | 保存结果 | 日志或产物 |
| --- | --- | --- |
| `ERL_FLAGS='+S 2:2' rebar3 compile` | PASS；默认构建无 Gleam 或模型 | `compile-final.log` |
| `ERL_FLAGS='+S 2:2' rebar3 eunit` | 添加 CLI 测试前 300/300 PASS | `eunit-off-final.log` |
| `ERL_FLAGS='+S 2:2' rebar3 eunit --module=efz_semantic_cli_tests` | 3/3 PASS | `semantic-cli-off-final.log` |
| `ERL_FLAGS='+S 2:2' rebar3 ct` | 3/3 PASS | `ct-final.log` |
| `ERL_FLAGS='+S 2:2' rebar3 xref` | 退出 0，无警告 | `xref-final.log` |
| `ERL_FLAGS='+S 2:2' rebar3 dialyzer` | 退出 0，无警告 | `dialyzer-final.log` |
| `ERL_FLAGS='+S 2:2' GLEAM_BIN=/tmp/efz-gleam-toolchain/gleam rebar3 as gleam compile` | PASS | `optional-compile-final.log` |
| `ERL_FLAGS='+S 2:2 -pa /home/fbogoslavskii/efz-fuzz/_build/xmlrpc-example/dependency-ebin' GLEAM_BIN=/tmp/efz-gleam-toolchain/gleam rebar3 as gleam eunit` | 368/368 PASS，退出 0 | `eunit-optional-final.log` |
| 全部 7 示例配置通过 `scripts/fuzz.escript --config … --max-iterations 2` | 退出 0；未知适配器退出 2 | `cli-final/results.json` |
| 通用与领域脚手架，`-Werror` 编译、种子调用、CLI；重复创建 | PASS；重复退出 2，原始哈希不变 | `scaffold-final.json` |
| QS 前后样例探针 | 精确相等 | `qs-compatibility.json` |

行为检查覆盖直接 BEAM 分发、不同 API 及元数、嵌套编解码和变异边界、有限原子和资源、
状态重置及清理、缺少或可选回调、未知适配器与选项或能力、模型 ABI、层错误、
畸形与拒绝或回退、确定性 RNG 来源信息、纯语义语料接纳及父选择、重启与重新校准、
在无适配器或模型 BEAM 的独立 VM 中原始重放、语义标识不匹配、原始及语义再生、
保留谓词的最小化，以及预算或截止时间。
XML 集成检查 18 次实际生成调用、216 次变异和独立模型一致性。
旧 QS 集成样例也保留。

早期失败日志保留，包括错误专项测试选择、过时测试输出目录，以及随后修复的
新 XML 原始重放测试缺少 expected_harness。
它们不表示为 PASS；修复后最终可选完整套件通过。
默认完整套件 300 与专项 CLI 3 不会被表述为单次完整 303 项运行。

## 保存的比较测量：初步结果

在同一 Intel i7-1260P 主机，CPU 亲和性 0/1、OTP 27 和 `+S 2:2`：

* QS old/new/off：3 次重复，相同六个种子，RNG `{17,18,19}`，
  每样本 300 变异 + 6 校准 = 306 主执行及总执行。
  单独 20 变异预热不计入 306。后端 `otp_native_public`，共享目标 BEAM SHA-256 为
  `c407d6be5bb023b5ea907ff2bfc69820fe90dc9f39932caf688bcba7ea07464f`，
  目标超时 1000 ms、活动截止时间 120000 ms、驱动超时 135 s。
* Generic/XML/stateful off/on：3 次重复，各 API 一个相同种子，RNG `{17,23,41}`，
  100 变异 + 1 校准 = 101 主执行及总执行，额外执行 0；
  仅目标 ETS、超时 1000 ms、活动截止时间 30000 ms、驱动超时 45 s、活动预热 0。
  Generic 指元组库的 combine/2。

保存的 QS 9/9 和其他 18/18 样本全部完成执行预算，退出 0，无驱动超时。
这些是已完成快照，不是将提前超时称作完成。
墙钟中位数包含活动设置和校准；含 VM 启动的驱动墙钟时间单独保存在 runs.json。

| 快照与模式 | 墙钟中位数，ms | 墙钟范围，ms | 主执行/秒 | 覆盖 | 纯语义新颖性 | 提供器成功 / 回退 |
| --- | ---: | --- | ---: | ---: | ---: | --- |
| QS old | 739.309 | 713.198..753.390 | 413.900 | 47 | 1 | 11 / 16* |
| QS new explicit | 723.828 | 722.336..729.559 | 422.752 | 48 | 1 | 9 / 22 |
| QS off | 756.010 | 742.380..771.641 | 404.757 | 46 | 0 | 0 / 0 |
| Generic off | 1332.773 | 495.633..1693.731 | 75.782 | 1 | 0 | 0 / 0 |
| Generic on | 314.443 | 307.972..370.118 | 321.203 | 1 | 1 | 7 / 4 |
| XML-RPC off | 1740.152 | 461.274..1854.316 | 58.041 | 26 | 0 | 0 / 0 |
| XML-RPC on | 1923.890 | 1865.013..2250.691 | 52.498 | 37 | 1 | 5 / 5 |
| Stateful off | 524.489 | 327.623..1620.321 | 192.568 | 6 | 0 | 0 / 0 |
| Stateful on | 337.611 | 334.484..389.764 | 299.161 | 6 | 1 | 3 / 5 |

这里回退取自原始计数，而非先前错误汇总。
`*` 旧 QS 没有公共回退计数：27 尝试 − 11 成功 = 16，也等于 3 限制 + 11 不支持 + 2 未改变。
旧 XML、有状态和新 QS 摘要把已计入回退的 unchanged 再加一次，
因此摘要写成 6/6/26，而非 5/5/22。
原产物未重写；驱动已修复，供未来系列使用。

本系列有状态成本是全部输入执行成本，包含编解码拒绝，不是已接受场景的隔离成本。
从规范包重建：off 为 1 合法场景、3 命令、100 拒绝包；on 为 5 合法场景、14 命令、96 拒绝包。
这重建计划操作，不是已完成 gen_server 调用的运行时汇总。
旧摘要字段 `primary_scenarios=101` 错把 101 次主输入执行称为场景。
结果样例区分 1 场景和 N 操作；已接受场景与实际操作总数的独立完整测量仍待完成。

独立回调微基准：每路径 3×1000 调用、100 次预热，计时外一次设置目标执行，
测量目标执行 0。直接适配器 / 已验证门面中位数，µs：

| 回调 | Generic | QS | XML-RPC |
| --- | --- | --- | --- |
| 生成 | 0.943 / 1.003 | 0.211 / 0.270 | 0.499 / 0.560 |
| 变异 | 1.935 / 2.394 | 2.539 / 3.552 | 1.494 / 1.890 |
| 观察 | 0.479 / 1.251 | 0.250 / 0.491 | 0.187 / 0.490 |
| 判定器 | 0.024 / 0.060 | 1.531 / 1.672 | 0.581 / 0.669 |

这里通用判定器为 `inconclusive,no_property`，不是检查 API 的成本。
这是固定输入回调成本，不涵盖全部可能大小或格式。
不同适配器特征不作为共同量尺比较。

证据：
[performance-final 清单](../../../../artifacts/gleam-layer/20261010-universal/performance-final/manifest.json)、
[runs](../../../../artifacts/gleam-layer/20261010-universal/performance-final/runs.json)、
[QS 清单](../../../../artifacts/gleam-layer/20261010-universal/qs-performance-final/manifest.json)、
[QS runs](../../../../artifacts/gleam-layer/20261010-universal/qs-performance-final/runs.json)、
各 summary.json 和 *-callbacks.json。

初步状态原因：performance-final 源码哈希已与当前核心、编解码器、worker 和驱动不同；
QS 清单记录共享目标和有限部分引擎标识，未覆盖整个最终插件或分发器。
较早系列还有产物准备与其他测量重叠。
在 n=3、相同 RNG 轨迹和已观察墙钟波动下，不能声称加速、更好发现或性能验收。
首个 QS 系列准备失败（缺少 `cow_inline.hrl`）单独保留，没有产生伪造结果。

## 修改文件与待完成验证

| 分组 | 文件或目录 | 用途 |
| --- | --- | --- |
| 公开边界和插件 | `src/efz_semantic_adapter.erl`、`efz_gleam_adapter.erl`、`efz_term_api_adapter.erl`、`efz_term_codec.erl`、`efz_qs_adapter.erl`、`efz_qs_legacy.erl`、`efz_xmlrpc_adapter.erl` | 契约、通用编解码、预检、有界分发及私有语义 |
| 核心集成 | `efz_mutation_plan.erl`、`efz_mutation.erl`、`efz_worker.erl`、`efz_semantic.erl` | 适配器目录、RNG 来源、单结果回调和语义接纳 |
| 持久化 API | `efz_recipe.erl`、`efz_replay.erl`、`efz_semantic_replay.erl`、`efz_corpus_store.erl`、`efz_semantic_corpus.erl` | 版本化标识、重启、重放、缩减与最小化 |
| CLI 与构建 | `efz_cli.erl`、`rebar.config`、`scripts/build_gleam.sh`、`gleam_replay*.escript`、`semantic_scaffold.escript` | 可信配置路径、可选模型和可复用脚手架 |
| 模型与示例 | `gleam/efz_semantic/src/efz_term_model.gleam`、`efz_xmlrpc_model.gleam`、`examples/{term_api,stateful,xmlrpc,semantic_configs}`、QS 元数据 | 真实可复用集成；保留原 QS 模型 |
| 行为证据 | `test/efz_{plugin_*,semantic_api,semantic_cli,semantic_portability,term_api,xmlrpc_adapter}*`、回归测试 | 边界、生命周期、标识、持久化和兼容 |
| 比较证据 | `scripts/{run_semantic_bench.py,run_qs_semantic_bench.py,semantic_bench.escript,gleam_bench.escript,qs_compatibility_probe.escript}` | 有限串行驱动、清单和前后探针 |
| 文档 | `adapter-contract.md`、`connecting-erlang-libraries.md`、`user-guide.md`、本报告、XML README | 公开契约、八步指南、配置和限制及验证状态 |

重放 CLI 审查和保存结果记账已完成，没有新增运行。
新重放 CLI 及旧转发的运行时和语法验证、最终隔离比较系列、实际接纳有状态场景及操作成本测量仍待完成。
未来运行预备命令，**此处未执行**：

```sh
python3 scripts/run_semantic_bench.py --out /tmp/efz-semantic-verified
python3 scripts/run_qs_semantic_bench.py \
  --baseline /tmp/efz-universal-baseline-e4c0244/_build/gleam \
  --out /tmp/efz-qs-verified
```

实践指南、模板和配置：[将 Erlang 库连接到 Gleam Layer](connecting-erlang-libraries.md)。
执行范围受可用代码路径、允许的 EFZ 生命周期、可复现测试驱动及实际准备目标覆盖限制。
外部服务、设备、自定义端口或 NIF、不受管理进程和其他资源，需要单独适配器、测试驱动及环境检查。
公共契约不会自动推导任意库语义。
