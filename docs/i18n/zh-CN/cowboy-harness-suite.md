# Cowboy 数据流测试桩

[English](../../cowboy-harness-suite.md) · [Русский](../ru/cowboy-harness-suite.md) · [Español](../es/cowboy-harness-suite.md) · **简体中文** · [All languages](../README.md)

本套件使用固定版本的 Cowboy 2.19.0 和 Cowlib 2.20.0 依赖项检查 EFZ。
十一个独立目标沿着真实的库数据流运行。在可选 Gleam Layer 关闭、观察结果或
引导变异和保留输入的模式下，运行相同的目标代码、初始语料库、RNG 种子和变异预算。

输入为**载荷字节**，最多 1024 字节。这些测试桩围绕每个载荷构造有效消息，
并检查库返回的结果。在适用时，由一个选择器字节选择文档中说明的变体。
每个未超出预算的输入都会到达库代码；没有需要先通过校验的 term 编解码封装。
本套件执行成功的解析和交付路径，不将普通的输入拒绝视为缺陷。

## 输入面与已实现的路径

每个名称选择 `efz_cowboy_<name>_target:run/1`。这些实现共用
[`efz_cowboy_flow.erl`](../../../examples/cowboy/targets/efz_cowboy_flow.erl)；独立
入口点支持分别统计覆盖率和语料库。

| 名称 | 输入面与实际数据流 | 检查的契约 | 范围限制 |
| --- | --- | --- | --- |
| `qs` | 载荷 → `cow_qs:urlencode/1` → `cowboy_req:parse_qs/1` → `match_qs/2` | 解码后的键值对和匹配的字段等于原始字节，包括零字节和非 UTF-8 字节 | 一个命名字段；构造有效的转义序列 |
| `headers` | 选择器/载荷 → 有效值 → `cowboy_req:header/2`、`parse_header/2` → Cowlib 解析器 | 查找保留原值；内容长度等于载荷长度 | 六类标头：内容长度、内容类型、范围、Basic 授权、可接受的编码、连接 |
| `cookies` | 载荷 → 十六进制 cookie 值 → `parse_cookies/1` → `match_cookies/2` → `filter_cookies/2` → 重新解析 | 值在匹配后保持不变；过滤移除另一个 cookie | 两个有效 cookie；不使用任意 cookie 语法 |
| `router` | 选择器/载荷 → 请求路径 → `cowboy_router:execute/2` → 约束转换 → `cowboy_req:binding/2` 或 `path_info/1` | 所选路由、整数绑定和路径尾部与构造内容一致 | 受信任的固定分派：根路径、带约束的条目 ID、通配符文件路径；不执行处理器 |
| `http1` | 构造的请求 → 真实的 `cowboy_http:init/6` → 现有的内存 Ranch 传输 → 流处理器 → 路由器、QS、请求体交付 | 对于 content-length/chunked 分帧，交付的请求体长度等于原始长度；无请求体变体的长度为零 | 每个连接包含一个完整请求；使用现有的同步流接收端，不使用套接字 |
| `http2` | 载荷 → `cow_http2:data/3` → `cow_http2:parse/1` | DATA 流 ID、FIN 标志和载荷均匹配，剩余数据为空 | Cowlib 帧往返，不是 Cowboy HTTP/2 连接 |
| `http3` | 载荷 → `cow_http3:data/1` → `cow_http3:parse/1` | DATA 载荷匹配，剩余数据为空 | Cowlib 帧往返，不是 QUIC 或 Cowboy HTTP/3 连接 |
| `websocket` | 选择器/载荷 → 文本/二进制/ping 帧 → `cow_ws:frame/2` → `parse_header/3` → `parse_payload/9` | 解码后的载荷匹配，剩余数据为空 | 完整的无掩码帧，不使用分片或压缩；ping 限制为 125 字节 |
| `multipart` | 载荷 → 使用固定边界的十六进制表单字段 → `cow_multipart:parse_headers/2` → `parse_body/2` → 最终边界与 content-disposition 解析 | 正文、字段名称和最终边界均匹配 | 一个完整分段；不涵盖 Cowboy 流式 `read_part` 生命周期 |
| `hpack` | 载荷 → 标头列表 → `cow_hpack:encode/3` → `decode/3` → 使用同一本地表的第二个块 | 两个解码后的标头列表均等于原始列表 | 每次执行使用新的 512 字节表，两个块，最多 16 个解码后的标头 |
| `qpack` | 载荷 → 标头列表 → `cow_qpack:encode_field_section/4` → `decode_field_section/3` | 标头列表匹配；表容量为零时没有编码器指令 | 静态/字面量字段段；不使用动态表、阻塞或 QUIC 控制流 |

这份清单区分了已实现的库路径与更广泛的部署面。TLS/Ranch 套接字、连接调度、
HTTP/2 和 HTTP/3 连接状态机、QUIC/WebTransport、压缩 WebSocket 消息、流式
multipart，以及应用专用的 REST/静态资源/处理器行为，都需要各自的生命周期
测试夹具。本套件不宣称覆盖这些路径。

现有的原始 HTTP/1 基准测试仍单独记录在
[`cowboy-long-benchmark.md`](cowboy-long-benchmark.md) 中。它的线路输入语料库
与此处使用的载荷语料库不同。

## 不使用 Gleam 运行

在仓库根目录中，使用 Erlang/OTP 27 或更新版本：

```sh
export ERL_FLAGS='+S 2:2'
rebar3 compile
escript scripts/cowboy_suite.escript --surface all --mode off \
  --iterations 500 --seed 424242 --out _build/cowboy-flows-off
```

普通配置不需要 Gleam 编译器或生成的模型 BEAM 文件。输出目录必须是新目录。
每个输入面在一个全新的 VM 中运行，并拥有自己的语料库和仅针对目标的原生行覆盖率产物。

## 运行全部三种模式

```sh
export ERL_FLAGS='+S 2:2'
export GLEAM_BIN=/path/to/gleam-1.10.0
rebar3 as gleam compile
escript scripts/cowboy_suite.escript --surface all --mode all --profile gleam \
  --iterations 500 --seed 424242 --out _build/cowboy-flows-three-modes
```

例如，使用 `--surface http1` 可运行单条路径。各模式如下：

| 模式 | 结构化比例 | 纳入条件 | 可选模型 |
| --- | --- | --- | --- |
| `off` | 0% | 结构覆盖率 | 无 |
| `observation_only` | 0% | 结构覆盖率；记录观测结果 | 编译后的 Gleam `efz_term_model` |
| `guided` | 30% | 结构覆盖率或新的语义特征 | 同一模型及 `efz_cowboy_flow_adapter` |

仅观察模式保持基线变异流和 RNG 消耗不变。引导模式有意改变选定的变异，随后
也会改变语料库。共享适配器使用现有的 Gleam term 模型观测实际结果，并补充
有限的领域特征，例如交付的请求体大小、路由、标头类别和值长度分桶。结构化操作
会更改选择器、扩展载荷，或生成大小受限、尺寸取边界值的载荷。不存在单独用
Gleam 重新实现的 Cowboy 解析器。

测试桩中的断言在**每种**模式下都会执行。它们检查往返/数据交付的一致性，
不检查完整的 RFC 合规性。语义层判定器处于禁用状态，因此新的语义特征不属于
语义问题发现。意外异常会传播到 EFZ，需要进一步调查；它们不会自动被确认为
库缺陷。本套件不使用已知缺陷或漏洞利用。

## 读取输出

每个 `<surface>/<mode>/` 目录包含：

- `initial-corpus/`、`config.term` 和 `identity.term`：确切的输入、RNG 设置、
  应用版本和目标构建标识。
- `target-beams/` 和 `artifacts.term`：仅针对目标的原生覆盖率构建。测试桩、
  适配器、观察器和 EFZ 代码不在被测模块列表中。
- `report.term`、`snapshot.term`、`summary.term`：测试活动结果、覆盖率、
  语料库、耗时、语义/结构化统计和库调用次数。
- `corpus/` 和 `crashes/`：用于常规重放流程的持久化 EFZ 产物。

根目录中的 `summary.csv` 比较各输入面和模式。`comparisons.csv` 记录相对于
匹配的 `off` 运行的时间开销。单次配对测试活动只是一次冒烟测量，不能证明速度
或缺陷发现方面的优势。引导模式的耗时包含不同的输入工作负载。

`target_invocations` 和 `target_accepted` 包含校准及变异。运行器根据执行预算
检查调用次数统计。对于正常运行，每次调用都应完成库契约。`discoveries` 和
`corpus_equivalent_rejections` 描述语料库纳入情况，而非 API 成功或拒绝情况。
校准期间获得的覆盖率与 `mutation_new_coverage_lines` 分开报告，因此初始
语料库不会被误认为变异带来的进展。覆盖率的分母包含所选模块的全部内容，
包括从所选流程无法到达的函数；它不是可达路径的最大值。

`report.etf` 保存完整的二进制报告。文本报告对运行时标识使用带标签的值，
使 `file:consult/1` 能够读取报告并保留二进制输入字节。

## 回归检查

```sh
rebar3 eunit --module=efz_cowboy_flow_tests,efz_cowboy_long_tests
GLEAM_BIN=/path/to/gleam-1.10.0 rebar3 as gleam eunit --module=efz_cowboy_flow_tests
```

本地验证完成了 33 次活动，每次 500 次变异：共 16,500 次变异和 264 次校准，
全部 16,764 次库调用均被接受，没有异常、超时或基础设施故障。全部十一类输入面
在 off 和 observation-only 模式下保留的输入、覆盖率及变异统计一致。
HTTP/1 在关闭层时达到 313 行、26 个语料条目，在 guided 模式下为 312 行、
32 个条目；保留更多条目不能证明覆盖率改善。参见共享的
[CSV 结果](../../cowboy-harness-suite-validation/summary.csv)、
[构建标识](../../cowboy-harness-suite-validation/identities.term)及
[复现清单](../../cowboy-harness-suite-validation/manifest.json)。
其他本地验证任务曾并行运行，因此这些耗时样本不能单独衡量该层的开销。
完整活动报告保留在本地 `_build` 树中；清单记录其哈希及确切复现命令。

这些测试涵盖全部十一条路径的空输入、二进制输入和最大尺寸输入、可重复的
结构化变异和缩减、一致的测试活动设置、请求体交付，以及内存 HTTP/1 传输的清理。
可选构建还会检查不同的库结果是否产生不同的语义特征。
