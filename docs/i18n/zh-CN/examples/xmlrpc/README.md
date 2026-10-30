# XML-RPC 解码器插件

[English](../../../../../examples/xmlrpc/README.md) · [Русский](../../../ru/examples/xmlrpc/README.md) · [Español](../../../es/examples/xmlrpc/README.md) · **简体中文** · [所有语言](../../../README.md)

此测试示例使用 [etnt/xmlrpc](https://github.com/etnt/xmlrpc) 的提交
`fb46463b2acadf164ec534d9e2033e194341c507`。它在普通 EFZ 执行中仅调用一次
`xmlrpc_decode:payload(binary_to_list(Input))`，不涉及网络服务器、RPC 回调、
编码器或第二次目标执行。解码器的 `{error, Reason}` 被转换为
`{rejected, Reason}`；接受的值仍是真实的 Erlang XML-RPC 项。

从 EFZ 根目录准备隔离的依赖和仅针对目标的覆盖率产物：

```sh
git clone --no-checkout https://github.com/etnt/xmlrpc.git _build/xmlrpc-dependency
git -C _build/xmlrpc-dependency checkout --detach fb46463b2acadf164ec534d9e2033e194341c507
ERL_FLAGS='+S 2:2' rebar3 compile
ERL_FLAGS='+S 2:2' escript examples/xmlrpc/prepare.escript
GLEAM_BIN=/path/to/gleam-1.10.0 ERL_FLAGS='+S 2:2' rebar3 as gleam compile
```

准备步骤会拒绝其他提交或被修改的解码器源码。生成的数据保存在
`_build/xmlrpc-example/`：`dependency-ebin`、`harness-ebin`、`instrumented`、
`seeds` 和 `dependency-identity.term`。请将依赖和测试包装器的 ebin 目录
添加到代码路径。选定的插桩模块是 `xmlrpc_decode` 和 `xmlrpc_util`；模型、
适配器和测试包装器不计入目标覆盖率。需要 OTP 的 `xmerl`，但此处不测量其解析器内部。
`strict => false` 保留 `xmerl.hrl` 记录中非字面量的默认值，同时为解码器的可执行代码插入探针。

```erlang
#{target => efz_xmlrpc_target,
  gleam_layer => #{adapter => efz_xmlrpc_adapter,
    adapter_options => #{string_bytes => 128,
                         methods => [<<"echo">>, <<"efz_missing_name">>]},
    structured_fraction => 10, feedback => guided, oracle => inline,
    oracle_budget => 64,
    limits => #{bytes => 4096, depth => 8, nodes => 128,
                collection => 16, operations => 1}}}.
```

EFZ 的标准输入仍是原始 XML 字节。独立的 Gleam 模型支持 `methodCall`、
可选且精确的 `<?xml version="1.0"?>` 声明、非空的方法名/成员名、显式的
`int`、`boolean`（`0`/`1`）、`string` 和嵌套的 `array`/`struct`。
文本为可打印 ASCII（U+0020..U+007E），支持五个预定义 XML 实体。
仅在这个范围内，字节与码点才一一对应。字符串和名称共用 `string_bytes` 限制；
整数是有符号 32 位。集合限制适用于参数、数组和结构成员；节点计数包含调用、值和成员；
值的嵌套深度从一开始。

解析器刻意只识别较小的语法：不支持标签间空白、属性、自闭合标签、数字实体、DTD、
CDATA 或命名空间。目标仍可能接受这些输入，但模型返回 `skip` 或 oracle 返回
`inconclusive`；普通 EFZ 字节变异仍然可用。响应/fault、`i4`、双精度数、日期、
base64、nil、隐式字符串、非 ASCII UTF-8 文本和编码器性质均不属于模型版本 1。
受支持的生成和变异产生可被接受的 methodCall 输入。操作 ID 稳定：
0 替换第一个标量，1 在前面插入标量，2 删除第一个参数，3 将参数包裹为数组，
4 将参数替换为单个结构，5 反转参数。

`xmlrpc_model_agreement` 版本 1 将独立解析出的期望值与已提供的主解码结果比较，
把现有的原子或字符列表名称规范化为 ASCII 二进制。模型和适配器都不从输入创建原子。
不支持的输入及目标预期的拒绝不会产生性质发现。支持范围内的模型调用必须被接受，且返回值匹配。
观察使用固定、有限的词汇表来表示是否接受、值类型、空值、深度及容器大小区间。
方法名称、字符串内容和 AST 哈希永远不成为特征 ID。

依赖和模型的路径可用后，运行可选集成测试：

```sh
ERL_FLAGS='+S 2:2 -pa _build/xmlrpc-example/dependency-ebin -pa _build/xmlrpc-example/harness-ebin' \
  GLEAM_BIN=/path/to/gleam-1.10.0 rebar3 as gleam eunit --module=efz_xmlrpc_adapter_tests
```

测试会明确报告缺失的可选依赖；默认构建会执行描述符/选项检查，不要求安装这些依赖。
原始重放仅需要普通的测试包装器/解码器产物。性质重放还需要匹配的插件/模型及显式的受信任配置；
EFZ 通用的身份信息与判定谓词检查保持适用。

`escript examples/xmlrpc/benchmark_callbacks.escript` 在 100 次预热调用后，
为每个回调和直接运行的未插桩解码器记录三次有限重复，每次 10,000 次调用，结果保存在
`_build/xmlrpc-example/callback-measurements.term`。报告固定了 268 字节的嵌套输入、
限制、BEAM 哈希、编译选项、OTP/ERTS 和调度器数量。这些测量不包含 EFZ 执行包装器、
分发器、覆盖率、语料库和测试活动循环，必须与完整测试活动的测量分别报告。
观察与 oracle 使用已经获得的同一个结果，测量中的额外目标执行次数为零。
