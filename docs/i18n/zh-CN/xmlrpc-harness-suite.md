# XML-RPC 数据流测试桩

[English](../../xmlrpc-harness-suite.md) · [Русский](../ru/xmlrpc-harness-suite.md) · [Español](../es/xmlrpc-harness-suite.md) · **简体中文** · [All languages](../README.md)

本套件检查 [etnt/xmlrpc](https://github.com/etnt/xmlrpc) 中的六条本地功能数据流，
依赖固定于提交 `fb46463b2acadf164ec534d9e2033e194341c507`。每个输入面在可选
Gleam 层关闭、观察结果或引导变异和语料库保留的模式下，使用相同的目标、
初始语料库、RNG 种子和变异预算运行。

输入为载荷字节，限制为 512 字节。测试桩从这些字节派生出有界的 XML-RPC 值，
并使用固定的 XML 标签构造完整消息。有效流程使用固定的原子作为方法名称和
结构体成员名称；验证流程使用固定的格式错误替代值。字符串值是从载荷派生的
可打印 ASCII 字符。字节变异不会变成 XML 标记或新的原子。在类型化值流程中，
首字节对八取模后选择整数、布尔值、字符串、双精度浮点数、日期、base64 值、
数组或结构体；空输入会选择带空载荷的整数。容器最多包含四个子项，最多嵌套
两层。方法为 `echo` 和 `sum`；结构体成员名称为 `value`、`count`、`enabled`
和 `items`。独立的 XML 构建器会转义全部五个预定义 XML 实体。

## 输入面与已实现的路径

每个名称选择 `efz_xmlrpc_<name>_target:run/1`。这些轻量目标共用
[`efz_xmlrpc_flow.erl`](../../../examples/xmlrpc/efz_xmlrpc_flow.erl)；独立
入口点确保覆盖率、语料库和结果可归属于各自的流程。

| 名称 | 实际数据流 | 检查的契约 | 范围限制 |
| --- | --- | --- | --- |
| `call` | 载荷 → 手动构造的 `methodCall` XML → `xmlrpc_decode:payload/1` | 解码后的方法和参数等于构造的调用 | 固定的方法名称和有界的类型化值；不使用任意 XML 语法 |
| `response` | 载荷 → 手动构造的单参数 `methodResponse` XML → 解码器 | 解码后的响应值等于构造的值 | 成功响应恰好包含一个参数 |
| `fault` | 载荷 → 手动构造的故障 XML → 解码器 | 故障码和字符串等于构造的值 | 有界的整数故障码和可打印字符串 |
| `roundtrip` | 载荷 → `{call, echo, [TypedValue]}` → `xmlrpc_encode:payload/1` → 解码器 | 解码后的调用等于提供给编码器的值 | 一个参数，包含受支持的有界值 |
| `dispatch` | 载荷 → 编码后的调用 → 解码器 → 本地 echo/sum 测试夹具 → 编码后的响应 → 解码器 | 最终响应与测试夹具的预期结果匹配 | 进程内测试夹具；不使用外部 RPC 服务 |
| `encoder_validation` | 载荷 → 刻意使用的不受支持的 Erlang 值 → 编码器 | 将 `{error, Reason}` 记为拒绝，将编码器的任何成功结果记为接受 | 有限的验证用例；预期错误不属于缺陷 |

解码器会拒绝空成功响应（`{response, []}`）的 XML。本套件不将此情况断言为
成功的编码/解码往返。编码器验证错误是预期的 API 结果，记录为
`target_rejected`；它们不属于缺陷或崩溃。
验证用例涵盖无效载荷元组、不受支持的映射值、字符串成员名称、格式错误的成员、
不受支持的数组原子、非字符串故障文本、两个响应参数和列表方法名称。观测结果
记录返回值是否与预期错误匹配；异常会继续传播。

分派在载荷长度为偶数时选择 echo，为奇数时选择 sum。Sum 最多使用载荷的前
四个字节，从每个字节减去 128，并将测试夹具的响应与独立计算的总和比较。

分派测试夹具不调用任何 `xmlrpc_http`、服务器或 HTTP 代码，也不打开套接字。
它执行编码、解码和少量本地应用决策。本套件不对 HTTP 传输、监听器、回调
生命周期、并发请求、任意 XML 语法或完整 XML-RPC 合规性的行为作出结论。现有的
[原始 XML 解码器适配器](examples/xmlrpc/README.md) 仍是使用不同输入格式和
模型的独立示例。

## 准备依赖项

在仓库根目录中运行，需要 Erlang/OTP 27 或更新版本、Rebar3 和 OTP `xmerl`：

```sh
git clone --no-checkout https://github.com/etnt/xmlrpc.git _build/xmlrpc-dependency
git -C _build/xmlrpc-dependency checkout --detach fb46463b2acadf164ec534d9e2033e194341c507
export ERL_FLAGS='+S 2:2'
escript examples/xmlrpc/prepare_flows.escript
rebar3 compile
```

准备步骤将 `xmlrpc_encode`、`xmlrpc_decode` 和 `xmlrpc_util` 编译到
`_build/xmlrpc-example/dependency-ebin`。如果提交不同，或这三个源文件及
`src/log.hrl` 中任一文件有改动，准备步骤会拒绝执行。示例目标和辅助模块通过
现有的 Rebar3 `examples/xmlrpc` 源目录编译。普通构建不需要 Gleam 编译器或
生成的模型 BEAM 文件。

如果检出位置不同，请将该路径传给准备步骤，并在运行器的 `--source` 选项中
使用同一路径：

```sh
escript examples/xmlrpc/prepare_flows.escript /path/to/pinned-xmlrpc
```

## 不使用 Gleam 运行

```sh
ERL_FLAGS='+S 2:2' escript scripts/xmlrpc_suite.escript \
  --surface all --mode off --iterations 500 --seed 424242 \
  --source _build/xmlrpc-dependency --out _build/xmlrpc-flows-off
```

输出目录必须是新目录。每个输入面/模式组合在一个全新的 VM 中运行，并拥有
自己的语料库和覆盖率状态。种子语料库包括空输入、XML 特殊字符、二进制字节和
512 字节边界。例如，使用 `--surface dispatch` 可选择单条路径。运行器接受
`--surface all|NAME`、`--mode all|off|observation_only|guided`、
`--iterations N`、`--seed N`、`--profile default|gleam`、
`--source PINNED_CHECKOUT` 和 `--out NEW_DIR`。

## 运行全部三种模式

```sh
export ERL_FLAGS='+S 2:2'
export GLEAM_BIN=/path/to/gleam-1.10.0
rebar3 as gleam compile
escript scripts/xmlrpc_suite.escript --surface all --mode all --profile gleam \
  --iterations 500 --seed 424242 --source _build/xmlrpc-dependency \
  --out _build/xmlrpc-flows-three-modes
```

| 模式 | 结构化比例 | 纳入条件 | 可选模型 |
| --- | --- | --- | --- |
| `off` | 0% | 结构覆盖率 | 无 |
| `observation_only` | 0% | 结构覆盖率；记录观测结果 | 现有的 Gleam `efz_term_model` |
| `guided` | 30% | 结构覆盖率或新的语义特征 | 同一 term 模型及 `efz_xmlrpc_flow_adapter` |

仅观察模式保持基线变异流和 RNG 消耗不变。引导模式更改选定的变异，随后可能
改变语料库。适配器使用现有的通用 term 模型，以及结果类型、项数分桶、编码
大小分桶和预期编码器错误匹配情况等有限特征，观测结果。结构化操作会替换
选择器、追加一个字节或选择一个有界样本。适配器不会在 Gleam 中重新实现
XML 解析器或编码器。关闭模式不使用模型运行。

相同的测试桩契约在每种模式下都会执行。语义层判定器处于禁用状态：保留新的
语义特征不会产生属性问题发现。意外异常和超时需要进一步调查；它们不会自动
被确认为库缺陷。这是一个功能集成套件，并非对已知缺陷的搜索，也不能证明
某种模式能发现更多缺陷。

## 覆盖率与输出

原生覆盖率仅包含每个输入面使用的所选固定版本 XML-RPC 模块：
`xmlrpc_encode`、`xmlrpc_decode` 和 `xmlrpc_util`。OTP `xmerl` 解析器内部
实现、流程辅助模块、本地分派测试夹具、适配器、观察器和 EFZ 代码均不计入。
分母包含每个所选模块中的所有可执行行，包括从所选流程无法到达的路径。

每个 `<surface>/<mode>/` 目录包含：

- `initial-corpus/`、`config.term` 和 `identity.term`：确切的种子字节、测试
  活动设置、源代码和构建标识、OTP/ERTS 及辅助模块标识。
- `target-beams/` 和 `artifacts.term`：所选库模块的原生覆盖率构建。
- `report.term`、`snapshot.term` 和 `summary.term`：测试活动结果、覆盖率、
  语料库、耗时、语义和结构化统计，以及调用次数。
- `report.etf`：无损二进制报告。UTF-8 文本 term 对运行时标识使用显式
  `{efz_runtime_identity, Kind, Text}` 标签，以便 `file:consult/1` 可以读取
  报告，同时保持二进制载荷字节完整。
- `corpus/` 和 `crashes/`：用于常规重放的持久化 EFZ 产物。

输出根目录包含 `matrix.term`、汇总结果、`summary.csv` 和
`comparisons.csv`。比较会将匹配的输入面与关闭模式运行配对，并检查初始
语料库哈希、RNG 种子和请求的预算。

`target_invocations`、`target_accepted` 和 `target_rejected` 包含校准及
变异。调用次数统计会根据执行预算检查这些计数。对于 `encoder_validation`，
预期的 `{error, Reason}` 返回值计入 `target_rejected`。`discoveries` 和
`corpus_equivalent_rejections` 描述语料库纳入情况，与 API 接受或拒绝相互
独立。校准覆盖率与 `mutation_new_coverage_lines` 分开报告，因此种子覆盖率
不会被报告为变异带来的进展。

时间列描述每个组合中的一次测试活动。它们没有单独测量观察器或适配器的成本，
而且引导模式的输入工作负载不同。单次运行不足以支持速度、覆盖率或缺陷发现
能力更优的说法。

## 回归检查

必须准备好可选依赖项，并将其置于测试 VM 的代码路径中：

```sh
ERL_FLAGS='+S 2:2 -pa _build/xmlrpc-example/dependency-ebin' \
  rebar3 eunit --module=efz_xmlrpc_flow_tests
ERL_FLAGS='+S 2:2 -pa _build/xmlrpc-example/dependency-ebin' \
  GLEAM_BIN=/path/to/gleam-1.10.0 \
  rebar3 as gleam eunit --module=efz_xmlrpc_flow_tests
```

这些针对性检查覆盖共享契约、有界载荷处理、可重复的结构化操作、套件设置及
可选观测路径。测试活动输出仍是测量结果的来源。

本地验证完成了 18 次活动，每次 500 次变异：共 9,000 次变异和 270 次校准。
其中 7,725 次流程调用被接受，另有 1,545 次编码器预期拒绝，没有异常、超时或
基础设施故障。全部六类输入面在 off 和 observation-only 模式下保留的输入、
覆盖率及变异统计一致。所有已观察到的结构覆盖均在校准阶段达到；在本次有界
运行中，变异没有增加代码行覆盖。Guided 的 dispatch 语料条目为 17，off 为 15，
代码行覆盖未增加。这些结果确认功能执行，不能证明引导模式具有优势。

共享的 [CSV 结果](../../xmlrpc-harness-suite-validation/summary.csv)、
[构建标识](../../xmlrpc-harness-suite-validation/identities.term)和
[复现清单](../../xmlrpc-harness-suite-validation/manifest.json)记录了本次运行。
完整报告保留在本地 `_build` 树中；清单保存报告哈希及确切复现命令。其他本地
验证任务曾并行运行，因此这些耗时样本不能单独衡量该层的开销。
