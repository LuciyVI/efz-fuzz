# 根据 Erlang 类型规范生成连接器

[English](../../../gleam-layer/connector-generation.md) · [Русский](../../ru/gleam-layer/connector-generation.md) · [Español](../../es/gleam-layer/connector-generation.md) · **简体中文** · [所有语言](../../README.md)

现有的通用适配器无需新增 Gleam 模型或库专用适配器即可连接 API。
脚手架会读取可信本地 BEAM 中的 `-spec` 和本地 `-type` 声明，生成参数模式：

```sh
ERL_FLAGS='+S 2:2' rebar3 compile
mkdir -p _build/my_library
ERL_FLAGS='+S 2:2' erlc +debug_info -o _build/my_library path/to/my_library.erl
ERL_FLAGS='+S 2:2' escript scripts/semantic_scaffold.escript from-beam \
  _build/my_connector efz_my_target \
  _build/my_library/my_library.beam function_name 2
```

`from-beam OUTDIR HARNESS_MODULE BEAM FUNCTION ARITY` 要求只有一个不带约束的函数规范，
且存在匹配的导出函数。读取元数据时不会加载库或执行其 `on_load` 回调。
仅使用可信 BEAM：这是本地开发工具，不是接收不可信产物的上传服务。

输出包括一个精简的 `run/1` 测试驱动、`campaign.term`、编码后的种子、
编译与运行说明，以及 `inference.term`。推导记录包含输入 BEAM 的 SHA-256、
入口点、推导出的模式、通用边界和限制。现有输出文件绝不会被替换。
运行生成的测试活动时，除生成的测试驱动目录外，还需通过 `--code-path`
添加库的 ebin 目录。通用适配器的语义回调需要可选 Gleam 构建；生成的原始输入
测试驱动只依赖不含模型的编解码器。

支持的参数类型包括有界整数和整数区间、有限浮点数、布尔值、二进制、字符串、
带类型的正规列表、固定元组、单一原子、有限原子联合，以及非递归本地类型别名
（含类型参数）。容器长度默认最多为 32，整数与浮点数默认限制在编解码器的
±1,000,000 范围内。显式整数区间会在编解码器的有符号 64 位范围内保留其边界。
完整参数树还必须满足编解码器的深度、节点数和字节数限制。因此，大型或深度嵌套的
合法规范可能被拒绝，而不会被悄悄放宽。

类型规范**不能**识别二进制数据的格式、参数间关系、合法状态转换或返回值的含义。
在认定输入符合库契约之前，应检查生成的模式。特别是，生成的有界域只是测试范围，
并非该类型的完整枚举，也不确定语义前置条件。`binary()` 可能是 JSON、UTF-8、
摘要或任意字节。

重载或带约束的规范、递归类型、远程或不透明类型、异构联合、宽泛的 `term()`/`any()`、
无界原子、映射、资源及不支持的表达式会使生成过程停止，并返回明确错误。
此时应使用显式选项文件，而不是猜测：

```sh
ERL_FLAGS='+S 2:2' escript scripts/semantic_scaffold.escript generic \
  _build/my_connector efz_my_target reviewed-options.term
```

不会推导正确性判定器或异常白名单。生成的活动保持判定器关闭。
在分类库故障之前，应添加经过审查的行为谓词，并记录预期拒绝行为。
有状态 API 仍需显式的设置、重置、清理和命令契约。

同一份生成的测试驱动适用于 `gleam_layer => false`、
`feedback => observation_only` 或 `feedback => guided`；模式由活动配置控制。
因此三个模式无需各自实现测试驱动。但回调的运行时成本仍然存在，必须测量。

## 使用内置 Cowlib 依赖的示例

执行 `rebar3 compile` 后，以下命令无需编辑模式或测试驱动即可生成可运行的连接器
（请使用新输出目录）：

```sh
escript scripts/semantic_scaffold.escript from-beam \
  _build/auto-cow-qs efz_auto_cow_qs \
  _build/default/lib/cowlib/ebin/cow_qs.beam urlencode 1
```

按照生成的 README 编译测试驱动及可选 Gleam 层。
在活动命令中添加 `--code-path _build/default/lib/cowlib/ebin`。
API 的 `binary()` 参数会转换为长度最多 32 字节的二进制模式。
切换模式时，只修改 `campaign.term` 中的 `gleam_layer`/`feedback`，不修改生成的源码。
测试驱动模块名必须与库模块名不同。

在 OTP 27.3.4.1 上的验证：未修改的生成版 Cowlib 测试驱动分别在关闭、仅观察和引导模式
完成了 100 次变异执行，没有目标崩溃或基础设施故障。这是连接器集成检查，
不是实际缺陷的证据，也不是性能或发现能力比较。回归测试还会编译并执行生成的源码，
检查种子解码、本地别名和来源信息，并验证不支持的类型、缺少调试信息、已有输出、
模块名冲突都被拒绝。通过 `on_load` 测试样例确认提取过程不会加载 API 模块。
