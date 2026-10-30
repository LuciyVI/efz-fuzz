# EFZ（Erlang 模糊测试器）

[English](../../../README.md) · [Русский](../ru/README.md) · [Español](../es/README.md) · **简体中文** · [所有语言](../README.md)

EFZ 是用 Erlang 实现的模糊测试器，具备语料管理、随机和可插拔分阶段二进制变异、
精确候选配方、受控目标执行、崩溃产物和自动源码插桩能力。EFZ 不依赖其他模糊测试引擎。

可选语义与 Gleam 层：[连接 Erlang 库](gleam-layer/connecting-erlang-libraries.md) ·
[P5 最终验证](gleam-layer/p5-validation.md) ·
[根据 `-spec` 自动生成连接器](gleam-layer/connector-generation.md)。

连续模式：[不限执行次数的 staged/Gleam](continuous.md)。

TUI：[活动终端仪表盘](tui.md) — `python3 scripts/tui.py --demo --out _build/tui-demo-1`。

文档：[架构与 UML](architecture.md) · [全部目录和文件地图](repository-map.md)。

[原始 presence 后端审计及与 AFL++ 的比较](coverage-tracking-audit.md)固定于提交 `205e18b`。
现也提供实验性 [hit-count 反馈](hit-count-experiment.md)：
`coverage_feedback => hit_count` 或 CLI `--coverage-feedback hit_count`。
默认仍为 `presence`。自动 presence 支持显式启用 `coverage_backend => bitmap`：
每个精确结构探针对应一位，不使用哈希或边覆盖。

使用预备测试语料快速开始：

```sh
# 从 efz/ 执行：检查 OTP/Rebar3，构建、插桩并准备初始语料文件。
escript scripts/prepare.escript
# 执行脚本打印出的命令。
```

[已验证的模糊测试命令、重放和后续开发阶段](quickstart.md)。
准备流程使用现有 staged 解析器；`BOOM!` 是演示崩溃。

阶段 2 收集**单次执行内函数子句及分支结果的源码覆盖**。
普通被测目标无需调用 EFZ。编译时对显式允许列表中的模块插桩，
BEAM 文件和源码清单保存在独立目录。单个活动 worker 校准初始输入，
随后保留到达此前未观察到覆盖点的成功变异。
异常、退出和超时保留覆盖并体现在结果中；基础设施故障会停止活动。

额外的 `hit_count` 模式保留使已有精确覆盖点达到新命中次数桶的成功输入。
探针新颖性和计数新颖性分别跟踪（`new_probe` / `new_hit_count`）；
使用相同的变异、执行、语料和重放机制。选择模式前请阅读[实验结果](hit-count-experiment.md)。

执行模型：同步二进制输入测试驱动，以及通过 `efz_target:spawn/1` 或 `spawn_link/1`
创建的受控子进程。独立 guardian 管理其生命周期与覆盖，在返回结果前等待清理，
并将受污染的 VM 退出使用。参见[执行隔离和共享状态规则](execution-isolation.md)。
任意异步 OTP 应用需要独立的一次性 VM 后端。

已验证环境：Erlang/OTP **27.0**、ERTS 15.0、x86_64 Linux、Rebar3 3.25.0。
配置最低要求 OTP 27；此处未验证其他版本。

```sh
rebar3 compile
rebar3 eunit
rebar3 ct
rebar3 dialyzer
rebar3 xref
```

通过通用 CLI 运行自己的 `my_harness:run(Input) when is_binary(Input)`：

```sh
escript scripts/fuzz.escript \
  --target my_harness \
  --code-path ./harness-ebin \
  --seeds ./corpus \
  --out ./findings \
  --artifacts ./instrumented \
  --mutation staged \
  --timeout 1000 \
  --max-input-bytes 4096 \
  --max-iterations 1000

escript scripts/fuzz.escript --help
```

把普通测试驱动编译到 `harness-ebin`；它调用解析器或其他被测代码。
通过 `efz_instrument:compile/2` 将所选目标模块构建到 `instrumented`
（BEAM 与 `.efz-manifest` 配对；下方有示例）。
重复使用 `--code-path` 指定依赖 BEAM 目录。若测试驱动导出 `run/1`，也可对其插桩。

运行器按文件名顺序将初始语料中的普通文件作为原始二进制数据读取。
允许空文件，不允许空目录。执行前检查产物、`run/1` 导出和输出目录可用性。
发现写入 `findings/crashes/`，`findings/report.term` 保存活动报告，包括活动语料。
复用输出目录会替换此报告。退出码：`0` 表示正常完成（包括目标崩溃），
`2` 表示无效参数或配置，`1` 表示执行基础设施或报告存储故障。
CLI 默认使用 staged 变异和 1000 次变异执行。除共享输入长度上限外，Erlang API 默认值不变。
`--max-input-bytes` 对 staged 和随机模式均生效（默认 4096，含边界范围 0..1048576）。

活动配置映射拒绝未知顶层键，包括 `function` 和 `arity`。
标准回调为 `run/1`；`max_input_bytes => N` 是活动级设置。
旧的嵌套设置 `mutation.max_input_bytes` 会被拒绝，并给出明确迁移提示。
超长输入直接拒绝，不会截断。参见[输入限制与存储故障](input-and-storage.md)
和 [CLI 配置与活动模式](cli.md)。

若要跨运行持久保存语料，设置 `--corpus-dir ./findings/corpus`
（Erlang API：`corpus_dir => "./findings/corpus"`）。
初始输入与成功的新覆盖发现会按 SHA-256 保存，然后才确认已接纳到语料。
下次使用相同目录即可省略 `--seeds`。额外提供的种子与恢复输入按内容去重。
每个恢复输入都会重新校准，并可能成为变异父输入。

恢复的是可复用输入，而非活动精确状态：计划器游标、RNG 状态、全局覆盖和旧整数队列 ID
均不恢复。默认遇到目标或构建不匹配会报错。
显式设置 `--corpus-build-policy recalibrate` 允许复用其他构建的输入，
并进行诊断和新覆盖收集。持久化条目损坏会导致恢复错误；不完整的中间写入会被排除并报告诊断。
参见[持久化语料格式、持久性保证与测试](corpus.md)。

从仓库根目录运行有界示例：

```sh
escript examples/automatic/run.escript
```

该示例只编译 `efz_example_parser`，使用独立的 `efz_example_target` 适配器，
校准 `<<0>>`，然后以固定 RNG 种子使用标准随机变异器执行 500 次变异。
报告写入 `_build/example-report.term`，插桩构建位于 `_build/instrumented-example`，
人工崩溃产物位于 `_build/example-crashes`。
解析器是普通 Erlang 源码；故意设置的 `artificial_example_exception` 演示目标故障。

编译后如需交互运行，打开新的 `rebar3 shell`：

```erlang
{ok, Artifact} = efz_instrument:compile(
    "examples/simple_parser/efz_example_parser.erl",
    #{modules => [efz_example_parser], source_root => ".",
      outdir => "_build/instrumented-shell"}).
{ok, _} = efz:start(#{target => efz_example_target, artifacts => [Artifact],
                     seeds => [<<0>>], max_iterations => 500,
                     timeout => 100, workers => 1, random_seed => {17,23,41}}).
Report = efz:await(30000).
efz:stats().
efz:stop().
```

目标仍实现 `run/1`；适配器可在同一进程内调用一个或多个所选模块。
`efz_executor:run/3` 在显式手动兼容模式下保留阶段 1 元组 API；
`run/4` 添加执行范围覆盖元数据。自动活动要求已验证产物，不回退到手动反馈。
不要预加载普通目标，也不要在活动期间替换目标代码；切换构建时使用新 VM。

```sh
# 确定性覆盖、语义、标识与生命周期检查：
rebar3 eunit --module=efz_phase2_tests
# 真正的覆盖循环：<<>> -> A -> AB -> ABC，保留父 ID，
# 精确向测试驱动传递输入，并在新 VM 中重建配方：
rebar3 eunit --module=efz_feedback_loop_tests
# 预热后可重复的本地性能测量：
escript scripts/coverage_bench.escript
# 全新普通构建，不删除既有结果：
EFZ_CLEAN_BUILD=$(mktemp -d /tmp/efz-clean.XXXXXX)
REBAR_BASE_DIR="$EFZ_CLEAN_BUILD" rebar3 compile
```

实现说明见[覆盖 API、支持语法、清单、测量与限制](coverage.md)、
[位图架构](coverage-bitmap-architecture.md)、
[实现与测量报告](coverage-bitmap-implementation-report.md)、
[覆盖完整性、固定标识与零覆盖策略](coverage-integrity.md)、
[EFZ 架构与 UML 图](architecture.md)、
[架构决策记录](adr/0002-automatic-coverage.md)及[验证结果](phase2-validation.md)。

覆盖与清理包括根进程和受控子进程。
任意生成的子进程、有状态 OTP 应用、共享 VM 状态、原生故障、分布式活动、
语法感知变异和语料最小化不属于此阶段。Erlang 进程不是 VM 或操作系统级沙箱。

精确覆盖标识每个活动验证一次。默认 `ets` 后端使用 `insert_new`，并独立向 guardian
报告首次观察；`coverage_backend => ets_member` 在插入前先检查条目。
可选 `coverage_backend => bitmap` 配合 `coverage_bitmap_bits => 65536`，
使用活动模式和执行范围原子位图表示自动探针 presence。
设置 `coverage_backend => ets` 即可返回参考实现。
位图复用、隔离与性能验证结果见[位图 v2 报告](coverage-bitmap-v2-results.md)。
实验性 `coverage_backend => otp_native_public` 使用公开 OTP 27+ 可执行行覆盖 API
和单独编译的目标产物。其覆盖语义不同；ETS 仍为默认。
参见[短期测量与限制](otp-native-public-results.md)。
ETS 和位图都保留执行范围观察以及崩溃或超时后的恢复能力。
测量取舍与源码产物见[性能报告](phase2.1-performance.md)。
设置 `random_seed` 及可选 `selection_seed` 可使变异和语料选择可复现。

测试驱动及所选插桩模块的标识在活动中固定。
热替换或执行上下文损坏会导致基础设施错误，即使目标捕获了覆盖钩子的异常也是如此。
合法但未观察到覆盖点的输入得到 `valid_empty_coverage`。
`coverage_diagnostics` 列出未使用产物；若整个活动从未观察到覆盖点，
`--coverage-policy strict`（API：`coverage_policy => strict`）会使活动失败。
默认策略为 `diagnostic`。零命中校准会警告，但允许变异寻找首个点。
历史性能数据早于这些完整性检查。

```sh
# 确定性重建大型稀疏测试样例：
escript bench/generate_sparse.escript
# 无 profiler 的全部吞吐测量层级（需数分钟）：
ERL_FLAGS='+S 4:4' escript bench/run.escript all _build/performance
escript bench/report.escript _build/performance
# 内存与吞吐分开测量：
ERL_FLAGS='+S 4:4' escript bench/run.escript memory _build/performance-memory prepared
# 后端、验证器及生命周期差分检查：
rebar3 eunit --module=efz_backend_tests
```

阶段 3 添加**可插拔 staged 变异**。现有配置保留此前的随机变异和覆盖默认值。
staged 计划器采用显式 `exsplus` 状态、按内容延迟维护的阶段游标、有界 havoc、
二进制字典和按内容标识的 splice 供体。
配方记录具体操作与字节；重建既不需要 RNG 状态，也不需要正在运行的活动。

```sh
rebar3 compile
# 普通解析器、字典文件、真正变异算子、崩溃持久化与重放：
ERL_FLAGS='+S 4:4' escript examples/staged/run.escript
# 在新 VM 中重建精确字节，不执行目标：
escript scripts/replay.escript _build/staged-example.recipe _build/regenerated.input
cmp _build/staged-example.input _build/regenerated.input
# 在另一 VM 中执行原始字节，检查保存的构建和测试驱动：
escript scripts/replay.escript --input _build/staged-example.input \
  --target efz_staged_parser --artifacts _build/staged-targets
# 从具体变异配方进行相同执行：
escript scripts/replay.escript --recipe _build/staged-example.recipe \
  --target efz_staged_parser --artifacts _build/staged-targets
```

在代码路径中有 EFZ 的全新 Erlang shell 中：

```erlang
{ok, A} = efz_instrument:compile("examples/staged/efz_staged_parser.erl",
    #{modules => [efz_staged_parser], source_root => ".",
      outdir => "_build/staged-shell"}).
{ok, _} = efz:start(#{target => efz_staged_parser, artifacts => [A],
    seeds => [<<0>>], mutation_mode => staged, max_iterations => 200,
    max_input_bytes => 64,
    mutation => #{seed => {17,23,41}, dictionary => [<<"TOKEN">>, <<"BOOM!">>],
        stages => [dictionary_insert,boundary,arithmetic,havoc,splice],
        max_block_bytes => 16, max_token_bytes => 16,
        max_tokens => 16, max_dictionary_bytes => 256,
        attempts_per_visit => 8, havoc_depth => 4, random_retries => 4,
        max_idle_visits => 256}}).
StagedReport = efz:await(30000).
ok = efz:stop().
[Crash | _] = maps:get(crashes, StagedReport).
Recipe = maps:get(mutation, maps:get(metadata, Crash)).
ok = efz_recipe:save("_build/saved.recipe", Recipe).
ok = file:write_file("_build/saved.input", maps:get(input, Crash)).
{ok, Regenerated} = efz_recipe:regenerate(Recipe).
{ok, Expected} = efz_replay:load(maps:get(path, Crash) ++ ".replay").
{ok, Replay} = efz_recipe:execute_file("_build/saved.input",
    efz_staged_parser, [A], maps:get(target_builds, Recipe),
    #{timeout => 100, expected_harness => maps:get(harness, Expected)}).
maps:get(outcome, Replay).
```

使用 **EFZ 十六进制字典**时，将 `dictionary => [...]` 替换为
`dictionary_file => "examples/staged/tokens.hex"`。
格式为每行一个由偶数个十六进制字符组成的 token；允许空行和以 `#` 开头的注释行。
空 token 被拒绝，重复项去除，token 排序。归一化字典在活动期间固定。
若未提供变异 RNG 种子，则只生成一次，并记录于 `StagedReport.mutation`。

原始 `.input` 文件仍是字节的权威来源。执行它们必须显式选择兼容本地目标；
配方文件不能选择可执行代码。重放使用保存的 `.replay` 标识记录，报告
`reproduced`（码 0）或 `not-reproduced`（码 3）。构建或测试驱动不匹配被拒绝（码 2）；
基础设施故障返回码 1。报告统计各归一化签名的出现次数。
默认 `crash_policy => #{reason => category, max_frames => 5, max_representatives => 3}`
会在**磁盘和报告中**保留最先的三个不同代表输入；`reason` 也接受 `exact` 和 `ignore`。
磁盘上的 `summary` 统计所有已记录出现，并跨 VM 重启保留上限。
所选产物保留精确原始字节和完整 `Reason`；其他输入只计数，不另建产物文件。
`storage` 区分 `saved`、`duplicate` 和 `limit_reached`；只有前两者提供精确输入产物的路径。
没有 `summary` 的旧分组仍可重放；使用代表上限存储时应选新输出目录。
中断或损坏的存储会报错，不会重置计数或绕过上限。
参见[算子语义、阶段顺序与全部限制](mutations.md)、
[配方格式与重放 API](replay.md)，以及[阶段 3 验证与测量成本](phase3-validation.md)。

```sh
# 有界纯变异运行与等预算活动，不启用 profiler：
ERL_FLAGS='+S 4:4' escript bench/mutations.escript _build/phase3-performance
```

## 与 Cowboy 一起运行

`efz_cowboy_target:run/1` 包装器把不带前导 `?` 的查询字符串字节传给 `cowboy_req:parse_qs/1`。
自动收集 `cowboy_req` 和 `cow_qs`（Cowlib）的覆盖。
不会启动 HTTP 监听器：测试的是目标进程中的同步查询字符串解析。

已验证组合：OTP 27.0、Rebar3 3.25.0、Cowboy 2.19.0 和 Cowlib 2.20.0。
构建还需要 Git、GNU Make 和 Cowboy 公共依赖的访问权限。
以下命令均需在同一个终端、**efz/** 根目录执行；Cowboy 源码必须位于同级 **../cowboy/** 目录。

构建 EFZ 和 Cowboy 的独立副本。当前 `erl:fuzz` 路径需要使用 `/tmp` 中的副本：
冒号会导致 `erlang.mk` 错误 `target pattern contains no '%'`。
原仓库副本保持不变。

```sh
rebar3 compile
COWBOY_BUILD=$(mktemp -d /tmp/efz-cowboy.XXXXXX)
cp -a ../cowboy "$COWBOY_BUILD/cowboy"
make -C "$COWBOY_BUILD/cowboy"
```

若下载依赖因 `Proxy CONNECT aborted` 停止，且可直接访问 GitHub，
可移除代理变量重试构建：

```sh
env -u HTTPS_PROXY -u HTTP_PROXY -u ALL_PROXY \
    -u https_proxy -u http_proxy -u all_proxy make -C "$COWBOY_BUILD/cowboy"
```

构建成功后检查包装器，并运行 500 次变异执行：

```sh
escript examples/cowboy/run.escript "$COWBOY_BUILD/cowboy" check
escript examples/cowboy/run.escript "$COWBOY_BUILD/cowboy" 500
```

`check` 针对所选 Cowboy 版本执行额外 14 项 EUnit 检查。
活动的最后一个参数设置执行次数：1–100000，默认 500。
示例采用 staged 变异、RNG 种子 `{17,23,41}`、小字典、初始语料 `[<<>>]`
和 1024 字节输入限制。EFZ 覆盖默认值保持不变：prepared 验证和 ETS。
每次 escript 调用都会启动新 VM。

最终打印状态和统计。完整报告保存到 `_build/cowboy-report.term`，
插桩 BEAM 和清单位于 `_build/cowboy-targets/`，意外崩溃产物位于 `_build/cowboy-crashes/`。
预期解析拒绝返回 `{invalid, Reason}`，不计为目标崩溃。

运行器会警告 `cowboy_req` 中两个列表推导式未添加内部覆盖探针；
它们不在 `parse_qs/1` 路径上。范围、错误语义与限制参见
[Cowboy 包装器 README](examples/cowboy/README.md)。

## 自动运行时诊断（可选启用）

P0 添加重复校准和验证、执行所属进程及 ETS 的有界采样、子进程退出观察和超时证据。
现有 `run/1` 测试驱动无需修改。通过 `runtime_oracles => #{enabled => true}`
或 CLI 标志 `--runtime-diagnostics --runtime-runs 3 --verification-budget 1000 --sample-interval 20`
启用。执行结果、覆盖保留和受控后代模型保持不变。
发现写入 `OUT/runtime-findings/`；重放使用
`replay.escript --runtime-finding DIRECTORY --target MODULE --artifacts DIR`。
参见[策略、类别、限制与示例](runtime-diagnostics.md)和
[验证与性能结果](runtime-diagnostics-validation.md)。

## 外部 worker VM（Linux，可选启用）

`--supervised` 在启动器拥有的 BEAM 操作系统进程中运行未修改的活动循环。
每次 executor 调用首先将精确输入发布到外部日志，并等待绑定摘要的 RUN 许可。
原生 VM 崩溃、硬超时或 dirty runner 会使该 VM 退出使用；控制器等待操作系统清理确认，
启动新代际，恢复持久化语料，重新校准，并在活动级预算内继续。
现有 `run(binary())` 测试驱动和旧模式保持不变。
先执行 `rebar3 compile`（会编译小型 Linux 生命周期辅助程序），再向普通命令添加 `--supervised`。

精确保证、日志格式、重放命令、恢复限制及已测试原生崩溃证据见
[P1-01 外部监督器](p1-01-external-supervisor.md)。

```sh
ERL_FLAGS='+S 4:4' escript scripts/fuzz.escript \
  --supervised --target my_harness --code-path harness-ebin \
  --artifacts instrumented --seeds corpus --corpus-dir out/corpus \
  --out out --timeout 1000 --max-iterations 10000
```

非 Linux 系统刻意不提供 supervised 模式，而非悄悄削弱 worker 清理与父进程死亡保证。
