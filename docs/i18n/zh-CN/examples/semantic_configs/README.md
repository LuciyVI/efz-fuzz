# 测试活动配置示例

[English](../../../../../examples/semantic_configs/README.md) · [Русский](../../../ru/examples/semantic_configs/README.md) · [Español](../../../es/examples/semantic_configs/README.md) · **简体中文** · [所有语言](../../../README.md)

每个 term 文件包含一个受信任的测试活动映射，可由 efz:start/1 和
CLI 的 --config 选项接受。种子是原始二进制数据，不是路径。通用输入包
使用测试包装器真实的参数规格进行编码。

| 文件 | 目标/API | 适配器 | 性质 |
| --- | --- | --- | --- |
| lists_reverse.term | lists:reverse/1，列表参数 | efz_term_api_adapter | 已禁用 |
| maps_find.term | maps:find/2，有限原子及以元组为值的映射 | 同一通用适配器 | 已禁用 |
| tuple_api.term | efz_term_tuple_library:combine/2，映射与元组 | 同一通用适配器 | 已禁用 |
| stateful.term | 新建 gen_server 的有界命令场景 | 同一通用适配器 | 显式的独立轨迹回调 |
| xmlrpc.term | 固定版本 xmlrpc_decode:payload/1 的字符列表入口 | efz_xmlrpc_adapter | xmlrpc_model_agreement v1 |
| cow_qs.term | cow_qs:parse_qs/1 的二进制入口 | 显式 efz_qs_adapter | query_model_agreement v1 |
| cow_qs_legacy.term | 历史 QS 配置 | 隔离的隐式 QS 兼容层 | 同一 QS 性质 |

所有示例都使用 coverage_backend=none：它们运行真实 API 和语义反馈，
不声称测量了库的结构覆盖率。请单独准备仅针对目标的产物，再选择相应的
后端和产物。不要将适配器、模型或性质辅助模块作为目标覆盖率进行插桩。

构建可选 Gleam 配置后，从 EFZ 根目录运行：

    ERL_FLAGS='+S 2:2' escript scripts/fuzz.escript --config examples/semantic_configs/maps_find.term --code-path _build/gleam/lib/efz/ebin --out /tmp/maps-campaign

XML-RPC 还需要由 examples/xmlrpc/prepare.escript 准备的固定版本依赖，以及代码路径
_build/xmlrpc-example/dependency-ebin 和 _build/xmlrpc-example/harness-ebin。
QS 需要 _build/default/lib/cowlib/ebin。--out 由调用方提供；显式 CLI 覆盖选项
可以调整配置，无须编辑配置文件。

参数约束、生命周期、插件模板、身份信息和重放方法请参阅
[完整集成指南](../../gleam-layer/connecting-erlang-libraries.md)。
