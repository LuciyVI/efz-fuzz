# 通用模糊测试启动器

[English](../../cli.md) · [Русский](../ru/cli.md) · [Español](../es/cli.md) · **简体中文** · [所有语言](../README.md)

`scripts/fuzz.escript` 相对于脚本位置加载已编译的 EFZ 应用，因此可从其他工作目录调用。
参数路径相对于调用方工作目录。请先执行 `rebar3 compile`。

`--coverage-feedback presence|hit_count` 选择覆盖反馈。默认是 `presence`；
`hit_count` 是[原型测量报告](hit-count-experiment.md)描述的实验性精确计数模式。
它改变哪些成功输入会被保留，使用的仍是同一个启动器和模糊测试引擎。

启动器调用一次 `efz:start/1`，通过 `efz:await/1` 等待，保存报告，最后在 `after` 块中停止 EFZ。
配置、插桩预检、校准、变异、调度、执行、覆盖、保留和崩溃分类全部使用现有核心。
`efz_instrument:discover/1` 从目录构建产物描述符；在执行任何输入之前，
`preflight/1` 验证内嵌清单、配对旁文件和已加载代码标识。

## 最小外部测试驱动

创建 `my_parser.erl`：

```erlang
-module(my_parser).
-export([parse/1]).
parse(<<128, Rest/binary>>) -> {high, Rest};
parse(Input) -> {low, Input}.
```

创建 `my_harness.erl`：

```erlang
-module(my_harness).
-export([run/1]).
run(Input) when is_binary(Input) -> my_parser:parse(Input).
```

从 EFZ 根目录准备并启动：

```sh
rebar3 compile
mkdir -p harness-ebin corpus
erlc -o harness-ebin my_harness.erl
printf '\000' > corpus/seed
erl -noshell -pa _build/default/lib/efz/ebin -eval '
  {ok, _} = efz_instrument:compile("my_parser.erl",
      #{modules => [my_parser], source_root => ".", outdir => "instrumented"}),
  halt().'

escript scripts/fuzz.escript \
  --target my_harness --code-path ./harness-ebin \
  --seeds ./corpus --out ./findings --artifacts ./instrumented \
  --mutation staged --timeout 1000 --max-input-bytes 4096 --max-iterations 100
```

把普通测试驱动及依赖 BEAM 与插桩产物分开保存。
`--artifacts` 中的全部 `.beam` 都会被选中，必须有合法匹配的 `.efz-manifest` 旁文件。
其中存在普通 BEAM 即为错误。通过重复的 `--code-path DIR` 添加普通依赖；
这些路径会追加到 VM 代码路径。加载及导出检查在插桩模块预检后执行，
因此 `--target` 也可指定插桩后的 `run/1` 模块。

种子按文件名排序，以非递归方式读取。目录被忽略；不可读文件或不支持的文件类型会使启动失败。
不会进行文本解码、换行裁剪、term 解析或截断。空文件产生 `<<>>`；无文件目录属于无效语料。

必要时会创建 `--out`，并在活动前通过临时写入进行检查。
崩溃分组在 `OUT/crashes/SIGNATURE_SHA256/OCCURRENCE_ID/` 下原子发布，包含
`artifact.input`、`artifact.term`、`artifact.replay`、可选 `artifact.recipe` 和完整性清单。
每个签名的 `summary` 保存持久化计数和代表索引；没有该文件的旧分组拒绝后续写入。
`OUT/report.term` 是包含完整核心最终报告的 Erlang 外部 term，含内存语料条目及其元数据；
它会替换该路径上之前的报告。添加 `--corpus-dir DIR` 可持久化并复用成功语料输入。
该存储非空时，下次调用可省略 `--seeds`。也可同时指定 `--seeds` 和 `--corpus-dir`；
重复内容会合并。默认构建不匹配策略是 `reject`；
`--corpus-build-policy recalibrate` 显式允许跨目标或构建标识变化复用。
两种策略都会重新校准全部加载输入，不会恢复活动检查点。
存储、完整性错误和诊断参见[持久化语料](corpus.md)。

CLI 默认为 staged 模式、100 ms 超时和 1,000 次变异执行。
校准执行单独计数。`--mutation random` 选择现有随机变异器。
两种模式都实施活动级 `--max-input-bytes`（默认 4096，含边界范围 0..1048576），
也包括有界原始种子摄取。CLI 不支持任意 MFA、手动覆盖或把配置文件当 Erlang 代码求值。
`--help` 列出全部可接受标志。未知或重复的单值标志，以及缺失或无效值都会明确报错。

`--coverage-policy diagnostic` 是默认值：`report.term` 明确列出未观察到的产物，
CLI 打印覆盖诊断。若活动结束时没有任何插桩探针，`--coverage-policy strict` 返回退出码 **1**。
单个合法空输入不会立即导致活动失败。此策略独立于插桩语法严格性。
参见[覆盖完整性](coverage-integrity.md)。

| 退出码 | 含义 |
|---|---|
| 0 | `completed`、真正的变异耗尽或空闲保护停止；目标崩溃和超时属于发现 |
| 2 | 无效参数、种子或输出路径不可访问、错误产物、模块或回调不可用、无效活动配置 |
| 1 | 活动基础设施故障、意外启动器或运行时异常，或最终报告存储失败 |

## 活动映射模式

`efz_config:prepare/1` 同样由 `efz:start/1` 使用，要求参数为映射，并在加载产物或目标**之前**
以 `{error,{unknown_campaign_keys,Keys}}` 拒绝未知顶层键。输入模式如下：

| 键 | 接受值 |
|---|---|
| `target` | 必填模块原子，导出 `run/1` |
| `seeds` | 必填二进制列表；若 `corpus_dir` 恢复非空语料，则可为空 |
| `timeout` | 非负整数毫秒，默认 100 |
| `workers` | `1` |
| `mutator` | 导出 `mutate/2` 的模块；默认 `efz_mutator_random`；自定义回调要求随机模式 |
| `mutation_mode` | `random`（API 默认）或 `staged` |
| `max_iterations` | 随机模式为非负整数或 `infinity`；staged 模式为 0..1,000,000；staged 未指定时为 1,000 |
| `max_input_bytes` | 活动二进制上限，含边界范围 0..1,048,576；默认 4,096；适用于两种模式、摄取、恢复及执行 |
| `mutation` | 仅 staged 使用的映射，由 `efz_mutation_plan:prepare/2` 验证；参见[变异限制](mutations.md) |
| `coverage` | `automatic`（默认）或显式仅 API 的 `manual` 兼容模式 |
| `coverage_backend` | `ets`（默认）、`ets_member`，或 `bitmap`（仅 automatic presence） |
| `coverage_bitmap_bits` | 位图容量，单位为位，默认 `65536`；64 的正整数倍 |
| `coverage_validation` | `prepared`（默认）或 `per_execution` |
| `coverage_policy` | `diagnostic`（默认）或 `strict`：没有观察到自动探针则活动失败 |
| `artifacts` | 产物描述符映射列表；自动模式要求非空合法产物 |
| `crash_policy` | 严格映射：`reason` = `category`（默认）、`exact` 或 `ignore`；`max_frames` = 1..32（默认 5）；`max_representatives` = 1..32（默认 3），对每个签名跨重启限制磁盘及报告内容。API 选项；参见[崩溃、重放与报告](replay.md) |
| `crash_dir` | 非空列表或二进制文件系统路径；默认 `_build/efz-crashes` |
| `random_seed` | 可选的三个非负整数组成的元组，用于旧 worker PRNG |
| `selection_seed` | 可选的三个非负整数元组或 `undefined`，用于旧语料选择 |
| `corpus_dir` | 可选非空文件系统路径；加载并持久化保存可复用语料输入 |
| `corpus_build_policy` | `reject`（默认）或 `recalibrate`；要求 `corpus_dir` |

staged 变异 RNG 设置位于 `mutation.seed` 内。
CLI 的 `--code-path`、种子目录及输出目录参数由启动器解析，不是额外活动映射键。
派生的 `manifests`、覆盖计划和协调器状态也不能作为用户活动选项。

即使 `function` 和 `arity` 设为 `run`、`1`，也会被拒绝：回调契约固定。
请在 `Module:run(Input)` 内完成适配。
`corpus_dir` 现在选择专用持久化格式；`--seeds` 目录仍包含普通原始种子文件。
`max_input_bytes => N` 是顶层活动选项；`mutation => #{max_input_bytes => N}` 会被
以 `{campaign_level_option,max_input_bytes}` 拒绝。CLI 将 `--max-input-bytes`
直接映射到活动选项。参见[输入与存储契约](input-and-storage.md)。

```sh
rebar3 eunit --module=efz_cli_tests,efz_config_tests
```

黑盒套件在全新 Erlang VM 中运行生产启动器，将当前构建打包以避免使用过时的默认 profile BEAM，
并使用外部普通测试驱动及自动插桩解析器。它验证原始输入传递、真正的覆盖保留、两种变异模式、
无效路径及产物、回调错误、崩溃与超时发现，以及失败退出码。

## 自动运行时诊断

`--runtime-diagnostics` 启用核心 `runtime_oracles` 策略（默认关闭）。
`--runtime-runs N` 设置种子、interesting、suspicious 和 failure 运行总数（含原始运行），范围 1..16；
`--verification-budget N` 限制活动中的额外执行数，范围 0..1000000；
`--sample-interval MS` 设置 1..10000 ms。这些值标志要求同时使用启用标志。
所有验证与核心共用。验证不消耗 `--max-iterations`。
更高级阈值和上限可通过 API 命名空间映射配置；未知嵌套键会被拒绝。

运行时观察独立于崩溃。使用 `scripts/replay.escript --runtime-finding DIRECTORY --target MODULE --artifacts DIR --runs 3`，
普通测试驱动需额外添加 `--code-path`。产物内容不能选择目标代码。
CLI 从可信本地 BEAM 解析模块名，不会把参数文本驻留为原子。
参见[完整模式与限制](runtime-diagnostics.md)。

## 外部 worker VM

在 Linux 上，可向普通模糊测试命令添加 `--supervised`。
CLI 在加载测试驱动或目标前就会委派。外部控制器根据本地文件计算标识，
并在单独的 BEAM 操作系统进程中启动真正的 CLI 与活动。
包括校准和 P0 验证在内的全部目标执行，都经过 `efz_executor` 中的持久化输入屏障。

额外有界选项包括 `--restart-budget`（默认 8）、`--supervised-runs`（10000）、
`--campaign-ms`（3600000）、`--startup-ms`（10000）、`--ipc-grace-ms`（1000）
及 `--journal-bytes`（268435456）。仅 supervised 模式接受这些选项。
输出包含 `external-report.json`、`external-runs/` 日志、worker 代际目录，
以及 `crashes/external/` 下的外部发现索引。复核发现：

```sh
escript scripts/replay.escript \
  --external-finding OUT/external-runs/CAMPAIGN/RUN \
  --target MODULE --artifacts ARTIFACTS --code-path HARNESS_EBIN \
  --out RECHECK_OUT --reproduce-runs 3
```

产物从不选择可执行代码。本地目标与产物标识必须匹配。
supervised 活动仅在正常完成或预算完成时返回 0（复核也会随明确复现结论返回 0），
参数错误返回 2，启动、协议、存储、无恢复的硬超时或重启预算故障返回 1。
控制器报告 `observed N/M`、`not_observed` 或 `inconclusive`；
绝不会把一次成功运行视为否定不稳定崩溃的证据。
参见 [P1-01 外部监督器](p1-01-external-supervisor.md)。
