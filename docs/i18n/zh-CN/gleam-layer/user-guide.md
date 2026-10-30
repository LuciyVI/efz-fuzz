> 本文描述历史 QS 兼容接口。当前公开插件和通用 API 指南为

[English](../../../gleam-layer/user-guide.md) · [Русский](../../ru/gleam-layer/user-guide.md) · [Español](../../es/gleam-layer/user-guide.md) · **简体中文** · [所有语言](../../README.md)
> [连接 Erlang 库](connecting-erlang-libraries.md)。

# 可选原生 Gleam 层

默认 `rebar3 compile` 和全部普通 EFZ 目标不需要 Gleam。

使用固定编译器构建（不会安装任何内容）：

```sh
GLEAM_BIN=/path/to/gleam-1.10.0 ERL_FLAGS='+S 2:2' rebar3 as gleam compile
escript scripts/gleam_seeds.escript /tmp/new-qs-seeds
```

[P2 集成证据](p2-integration.md)记录无需编译器的全新关闭构建、可复现开启构建、
运行时关闭、直接 BEAM 追踪及边界测试。
在独立 VM 中执行组件诊断：

```sh
escript scripts/gleam_beam_bench.escript "$PWD/_build/gleam" /tmp/gleam-beam-samples.json
escript scripts/gleam_dispatch_bench.escript /tmp/gleam-dispatch-samples.json
```

这些驱动收集有限计数和时间，不增加生产日志或遥测状态。
不要与活动基准同时运行。

种子清单位于原始种子目录之外，因此 EFZ 不会意外对清单做模糊测试。
仅种子模式随后可在关闭此层时运行。
默认生成 12 个不同种子，包括空值或空查询、重复名称、任意字节、畸形百分号转义、
31/32 个字段、127/128 字节值及 4096 字节 wire 输入。
命令拒绝已有输出目录或清单。索引目录确定；模式 2 记录生成器版本 2、运行时版本、
限制和各原始输入 SHA-256。
针对准备好的普通 ETS 产物，通过现有 CLI 导入：

```sh
escript scripts/fuzz.escript --target efz_qs_target --artifacts /tmp/qs-ets \
  --code-path _build/default/lib/efz/ebin --seeds /tmp/new-qs-seeds \
  --out /tmp/qs-seeds-only --max-iterations 100 --mutation staged
```

此命令没有运行时层启用标志。
独立目标验收和导入证据、结构化冒烟结果记录于 [p3-provider.md](p3-provider.md)。

首个目标是 `efz_qs_target:run/1`，包装固定的 `cow_qs:parse_qs/1`。
支持模型包括非空二进制名称、显式 `=`、有序二进制值、百分号和加号编码、`&` 分隔符。
不支持或畸形字节继续走普通路径。预期解析拒绝返回 `rejected`，不创建发现。

在 Erlang 中准备仅目标原生产物：

```erlang
{ok,A}=efz_cov_native_public:compile(
  "_build/default/lib/cowlib/src/cow_qs.erl", "/tmp/qs-native",
  ["_build/default/lib/cowlib/include"]).
{ok,_}=efz:start(#{target=>efz_qs_target, seeds=>[<<"a=1">>], artifacts=>[A],
  coverage_backend=>otp_native_public, mutation_mode=>staged,
  mutation=>#{seed=>{17,23,41},stages=>[havoc]},
  timeout=>1000, max_iterations=>1000, crash_dir=>"/tmp/qs-findings",
  gleam_layer=>#{structured_fraction=>10}}).
Report=efz:await(30000).
ok=efz:stop().
```

使用 `_build/gleam/lib/efz/ebin` 和 Cowlib 依赖代码路径。
比例 0 不进行结构化分支抽取或解码。
`gleam_layer=>false` 禁用全部回调和语义状态，包括开启构建中的情况。
缺少软件包或不支持的目标与配置会在启动时明确失败。
只有一个受支持适配器，不存在延迟判定器策略。默认执行隔离不变。

现有 CLI 配合普通 ETS 产物时，添加
`--code-path _build/gleam/lib/efz/ebin --gleam-layer --structured-fraction 10
--semantic-feedback guided --semantic-oracle inline --oracle-budget 64`。
上文 API 是原生覆盖准备流程；CLI 现有产物发现仍用于配对的源码插桩 ETS 产物。

检查：query_model_agreement v1 将受支持模型与已完成主解析器输出比较。
不支持输入、检查预算耗尽、超时或异常均为 Inconclusive，并附原因。
额外目标执行为零。观察器特征有精确 12-ID 命名空间，独立于结构覆盖。
纯语义发现使用常规 EFZ 语料和调度器。

[P4 反馈证据](p4-feedback.md)记录相等原生快照、实际纯语义父输入选择、写入重试、
重启和子集保留，以及发现重放。
`efz_corpus:semantic_representatives/0` 在引导模式返回冷路径只读的特征到工作条目索引；
关闭和仅观察模式返回 `disabled`。重启在变异前重新校准当前原始语料条目。
不支持延迟判定器及在线语料删除。

将有界回调组件测量与活动分开：

```sh
escript scripts/gleam_feedback_probe.escript "$PWD/_build/gleam" /tmp/feedback-costs.json
```

此有限诊断使用模型派生的结果样例，不执行目标。
它测量回调成本，不测量解析器正确性或活动性能。

判定器发现保留 `.input`、`.term`、`.replay`、可选 `.recipe` 以及带校验和的 `.semantic`。
属性重放需要 Gleam 和显式未改变的目标与原生产物；配方再生和普通原始重放则不需要。
重放并最小化测试使用的人工样例（不是实际 Cowlib 缺陷）：

下面的五位置参数命令是 QS 旧版辅助工具。
新适配器使用[库连接指南](connecting-erlang-libraries.md#8-检查持久化重放与最小化)
中的显式 `--config` 接口。

```sh
escript scripts/gleam_replay.escript ARTIFACT_PREFIX NATIVE_ARTIFACT_DIR \
  efz_qs_defect_target 64 /tmp/qs-minimized
```

输出写在不可变发现分组之外。最小化器统计全部目标执行、保持相同属性谓词，
在有限预算处停止，并报告单字节删除是否达到不动点。
不保证全局最小输入。属性重放前停止活动。

`efz_semantic:cover/1` 返回保留已记录探针、命中计数及语义并集的保守子集；
不会删除语料文件。初始或未校准条目继续受保护。
语料重启通过常规种子校准重建当前特征，与变异执行分开计数。

不声称性能优势或最优比例。
最终 P5 回归及有限活动验收记录于 [p5-validation.md](p5-validation.md)；
仅有 P2 组件样本无法关闭该门槛。
P3 报告尝试及成功、操作 ID、不支持/限制/未改变回退、层错误、生成字节数及回调累计微秒。
单独的有限组件样本（解码、核心变异、编码、完整提供器）：

```sh
escript scripts/gleam_provider_probe.escript "$PWD/_build/gleam" \
  artifacts/gleam-layer/20261008-p3-provider/p2-model-original.beam /tmp/provider.json
```

P2 模型 BEAM 是本地证据，不是随运行时发布的依赖。
结构化配方现使用模式 3 和精确 RNG 来源信息；旧模式 1/2 仍可不依赖 Gleam 重放。
配方与元数据都不改变规范语料中的原始输入。
