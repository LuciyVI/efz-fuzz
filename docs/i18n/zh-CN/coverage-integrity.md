# 自动覆盖完整性

[English](../../coverage-integrity.md) · [Русский](../ru/coverage-integrity.md) · [Español](../es/coverage-integrity.md) · **简体中文** · [所有语言](../README.md)

此契约适用于具有[受控后代生命周期](execution-isolation.md)的执行器。
仅凭空探针列表不能证明观察正常。
EFZ 独立于测试驱动成功返回值，检查加载代码、附加上下文、钩子错误和已发布探针的保留。

## 固定标识

`efz_config:prepare/1` 构造 `execution_identities`：

```erlang
#{harness => #{module => my_harness, beam_md5 => <<...>>,
               build_id => undefined, attributes_sha256 => <<...>>,
               compile => [...]},
  modules => #{my_parser => #{module => my_parser, beam_md5 => <<...>>,
                             build_id => <<...>>, attributes_sha256 => <<...>>,
                             compile => [...]}}}.
```

测试驱动单独固定，即便没有插桩且不在 `artifacts` 中。
普通测试驱动的 `build_id => undefined` 是正常情况。
标识通过 `erlang:get_module_info/1` 来自**已加载代码**，而不是代码路径中的文件。
`beam_md5` 是可执行代码的 OTP 校验和，不是整个 BEAM 文件的 SHA-256；
属性及编译元数据单独检查。
[OTP 说明代码校验和与编译属性的区别](https://www.erlang.org/doc/apps/stdlib/beam_lib#md5/1)。

预检比较旁文件清单与内嵌清单，再比较产物 BEAM 代码校验和及清单与已加载模块。
将旧清单复制到不同实现已无法通过验证。
`efz_cov_manifest:prepare/2` 在受保护验证计划中保存所选模块的加载标识。

worker 将活动固定标识传入两种验证模式：`prepared` 和 `per_execution`。
固定标识包含在执行结果、保留元数据和最终报告中。
`builds` 表示**预期所选构建**；标识检查失败时，不能把它解释为确认旧代码实际执行。

不带 `execution_identities` 的独立 `efz_executor:run/4` 为一次调用固定测试驱动；
计划跨调用保留所选模块标识。活动使用 `efz_config:prepare/1` 创建的固定标识。
重放比较显式提供的目标和产物与 `artifact.replay` 保存的构建 ID 及测试驱动标识，再创建执行固定标识。
低层 `efz_recipe:execute/5` 要求 `expected_harness`；仅变异配方不能证明旧测试驱动版本。
属性哈希使用确定性 ETF，以便跨 VM 匹配。详情见[重放](replay.md)。

## 替换检查

guardian 在目标启动前及终止后比较固定标识。
执行期间，独立 OTP trace session 观察经 `code_server` 加载或删除所选模块的请求，
包括使用执行前已准备代码的批量 `code:finish_loading/1`。
即使加载器之后恢复原 BEAM，尝试加载所选模块也会使结果不可信。
这是保守规则：重新加载相同字节或未成功替换所选模块同样被拒绝。
若普通新依赖不在固定标识中，则允许经 code server 加载。

同时追踪所选模块的 ERTS `delete_module/1`、`finish_after_on_load/2`，以及 code server 外的
`finish_loading/1`。
直接 ERTS 提交保守地产生 `unsupported_direct_code_loading`：
不透明已准备代码句柄无法可靠筛选所选模块。
这覆盖通过 ERTS 替换后再恢复原构建的情况。

最终结果前，guardian 等待全部所属进程的 DOWN 和追踪屏障，再等待加载器追踪的全局送达屏障，
检查快照和标识，并移除执行资源。
无效或已销毁的已准备计划也产生基础设施故障，包括快照为空时。

## 上下文与观察状态

`efz_coverage_observers` 是 guardian 拥有的具名**受保护 ETS** 表。
开始门打开前，写入 `PID → expected context`；执行固定标识也保存在其中。
表不保存全局覆盖，也不是全局“当前输入”：钩子仅查找自身 PID 的记录。
guardian 生命周期已将 VM 限为一个本地执行。

钩子比较进程字典与该记录。
因此 `erase()` 或畸形值不会把活动钩子变为不活动。
异常抛出前先将错误发送 guardian；目标无法用自己的 `catch` 隐藏。
对 `put/erase` 的追踪保留上下文修改证据，即便目标恢复该键或在退出检查前被杀。
错误具有粘性：后续合法命中不会清除它。
受控后代与根进程使用相同检查。

每个新探针先同步插入观察 ETS，再通知 guardian。
结束时每条此类消息必须匹配保留 ETS 行。
删除已发布观察且不重写会产生 `coverage_observations_lost`。
重复不会产生相同消息流。

| `coverage_observation.classification` | `state` | 含义 |
|---|---|---|
| `observed_coverage` | `observed` | 完整且包含探针的观察 |
| `valid_empty_coverage` | `attached` | 根附加已确认、无错误、无探针 |
| `broken_coverage_observation` | `failed`、`detached` 或 `invalid` | 钩子、上下文、标识或验证错误，或观察丢失 |
| `unstarted_coverage_observation` | `unattached` | 目标未及时附加，例如门打开前超时；不是成功空执行 |

映射包含 `attached_processes`、`probe_count`，发生错误时还有 `reason`。
禁止在未确认根附加时返回成功结果。
违规产生 `outcome = {infrastructure, Reason}` 和 `coverage_status = {error, Reason}`；
若取得目标独立结果，则由 `target_outcome` 保留。
worker 增加 `infrastructure_failures`，将精确输入及结果存入 `failure_context`，并停止活动。
部分记录探针可供诊断，但不参与成功反馈。

## 真实零命中与未连接活动

调用插桩函数可能在进入任何子句体前以 `function_clause` 结束。
普通测试驱动可捕获异常并返回 `zero`。这是真正的 `valid_empty_coverage`。
测试驱动对特定输入跳过目标，也可产生合法空结果。
仅一次这样的执行不能证明测试驱动连接错误。

活动跨**所有完整执行观察**统计观察模块，包括目标崩溃，独立于成功全局覆盖。
报告包含：

```erlang
#{coverage_diagnostics => #{policy => diagnostic,
    status => no_probes_observed, % 或 observed / manual
    observed_modules => [],
    unused_artifacts => [#{module => my_parser, build_id => <<...>>}],
    empty_executions => 1, unstarted_executions => 0, broken_observations => 0}}.
```

- 默认 `coverage_policy => diagnostic`：报告明确无探针，CLI 打印诊断；活动可正常结束。
- `coverage_policy => strict`：活动结束仍无可信插桩探针时，返回
  `{infrastructure_failure, #{kind => coverage_not_observed, ...}}`，增加基础设施故障计数，
  CLI 返回 **1**。不替换既有主要基础设施错误。
- 即使其他产物产生探针，也列出每个未使用产物。
  strict 要求总体至少一个探针，不要求所有所选产物都命中。
- 零命中校准触发警告但不停止变异：首个有用输入可能稍后出现。
  这也为无限活动提供早期诊断。
  活动运行时，可通过 `efz:stats/0` 查看 `coverage_*_executions` 和 `coverage_broken_observations` 计数。

```sh
escript scripts/fuzz.escript --target my_harness --code-path ./ebin \
  --seeds ./corpus --out ./findings --artifacts ./instrumented \
  --coverage-policy strict --max-iterations 1000
```

活动策略独立于插桩时检查 Erlang 语法支持的 `strict` parse transform。
两种检查都不改变新颖性：

```text
New = Current - Global
successful valid execution: Global := Global union Current
broken observation: error, no merge and no retain
```

## 边界与验证

这是可信共享 VM 中的正确性检查，不是防护任意恶意 Erlang 代码。
替换 EFZ 自身、关闭追踪、伪造协议消息或 ETS 行，以及远程执行都不在受支持模型内。
完整异步 OTP 范围要求独立一次性 VM 后端。
code-server 追踪适配器已在 OTP 27.0 验证；支持其他 OTP 版本时必须运行其回归测试。
标识与追踪检查会增加执行成本；完整性强化前的旧基准数值不能表征当前后端。

[efz_integrity_tests](../../../test/efz_integrity_tests.erl)覆盖正常和零命中、未连接或未使用产物、
严格策略、新颖性不变、字典删除/畸形/恢复、捕获钩子异常、ETS 行丢失、子进程上下文、
kill、执行前/执行中/瞬时重载、独立测试驱动固定标识、已准备计划、复制清单、公开原子加载及直接 ERTS 提交。
[efz_cli_tests](../../../test/efz_cli_tests.erl)在独立全新 Erlang VM 中检查 diagnostic、strict 和无效策略。
