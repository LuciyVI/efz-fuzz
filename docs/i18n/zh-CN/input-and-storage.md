# 输入限制与存储故障

[English](../../input-and-storage.md) · [Русский](../ru/input-and-storage.md) · [Español](../es/input-and-storage.md) · **简体中文** · [所有语言](../README.md)

`max_input_bytes` 是单个活动选项，默认 **4096**，含边界范围 **0..1048576**。
零只允许 `<<>>`。最大值本身合法；最大值加一被拒绝。
任何层都不会截断或转换输入字节。

```erlang
{ok, _} = efz:start(#{target => my_harness, artifacts => Artifacts,
    seeds => [<<>>], mutation_mode => staged, max_iterations => 100,
    max_input_bytes => 4096,
    mutation => #{stages => [dictionary_insert, bitflip], dictionary => [<<"A">>]}}).
```

旧的嵌套活动选项 `mutation.max_input_bytes` 现在返回
`{error,{campaign_level_option,max_input_bytes}}`。
归一化内部变异计划和保存配方仍包含派生上限，以确保确定性重放。
独立计划器 API 保留自己的显式选项映射。

| 边界 | 行为 |
|---|---|
| 初始种子 | 两种模式都在校准前由配置验证全部二进制长度 |
| CLI 种子 | 最多原始读取上限 + 1 字节；超长文件以路径和大小下界报错 |
| 恢复语料 | 校准前按当前活动上限有界读取输入；不会静默跳过 |
| 活动语料插入 | 插入及持久化前检查相同上限 |
| 随机变异 | 回调选项接收上限；内置变异器达到容量时以覆盖替代插入；上限为零时返回空输入 |
| worker 与执行器 | 调用测试驱动前验证；自定义随机回调违规属于基础设施故障，保留其精确候选 |
| staged 变异 | 所有操作、中间值及供体使用派生上限 |
| 崩溃输入 | `save/4` 在文件系统操作前按活动上限验证 |
| 重放 | 低层原始执行使用 `Opts.max_input_bytes`，默认 4096；已验证重放 CLI 默认使用记录的活动上限 |

若未提供字节上限选项，历史低层执行器 API 仍支持基于 term 的插桩实验。
活动与重放执行始终显式传入上限，并要求二进制输入。

## 重放

`efz_recipe:regenerate(Recipe)` 按配方中记录的活动上限验证。
`regenerate(Recipe, #{max_input_bytes => Max})` 还会对 primary、供体、全部中间值和输出
实施当前活动边界；不会放宽记录边界。`regenerate(Recipe, #{})` 使用默认 4096。

```erlang
{ok, Input} = efz_recipe:regenerate(Recipe, #{max_input_bytes => 4096}),
{ok, Expected} = efz_replay:load(ExpectationPath),
{ok, Result} = efz_recipe:execute_file(InputPath, my_harness, Artifacts, Builds,
    #{timeout => 1000, max_input_bytes => 4096,
      expected_harness => maps:get(harness, Expected)}).
```

```sh
escript scripts/replay.escript finding.recipe exact.input --max-input-bytes 4096
```

配方和语料元数据封装保留独立的*元数据*大小上限；这些上限不允许更大的模糊测试输入。
超长内存二进制报告 SHA-256 和精确大小。
有界文件读取器报告大小下界及路径，不会把前缀哈希冒充完整输入标识。

## 崩溃事务与错误

`efz_crash:save(Input, Result, Metadata, #{crash_dir => Dir, max_input_bytes => Max})`
返回 `{ok, Crash}` 或 `{error, ErrorMap}`。第四参数仅为目录时使用默认 4096。
文件系统错误映射包括：

```erlang
#{kind => filesystem, operation => open, path => Path, reason => eacces,
  input_hash => InputSHA256, signature_id => Signature, group_id => Signature,
  occurrence_id => Occurrence, crash_fingerprint => Signature,
  artifact_group => Group, staging_path => Staging}
```

`operation`、`path` 和 `reason` 描述主要故障。
可选 `close_error` / `cleanup_error` 保留次要故障，不替换主要故障。

发布布局：

```text
crash_dir/
  SIGNATURE_SHA256/
    summary                  (有界持久化计数 / 代表索引)
    .lock/                   (独占写入者；保存间隙不存在)
    OCCURRENCE_ID/            (仅所选代表)
      artifact.input
      artifact.term          (完整原始 Reason/stack 和元数据)
      artifact.replay        (预期构建/测试驱动/输入/签名)
      artifact.recipe        (有合法 staged 来源信息时)
      manifest               (版本、文件大小和 SHA-256 哈希)
    .tmp-RANDOM/              (写入者被杀后未提交的暂存)
```

每个文件都在临时目录中独占写入、fsync 并关闭。
对该目录 fsync 后，单次重命名发布整个分组，再 fsync 父目录。
缺失父目录会创建并同步。普通失败会移除未发布暂存；清理失败则报告其路径。
被中断写入者可能留下可识别的 `.tmp-*` 目录；它没有已提交分组标识，不能用作发现。
使用 glob 搜索 `.input` 时必须排除暂存。
若重命名后被杀，发布分组是完整的。重命名后的父目录 fsync 错误仍报告失败，
即便完整分组可能已存在。产物发布与 summary 更新是独立提交：中断后的孤立产物会被诊断，
不会静默丢弃或当作空存储。

`efz_crash_store` 跨活动及 VM 重启实施 `crash_policy.max_representatives`。
它保留最先 N 个不同输入哈希，在同步的原子 `summary` 中统计每次已提交出现，
并通过目录锁排除并发写入者。保存前验证 summary 和代表清单。
仅最后已提交的 occurrence ID 可幂等重试。
被杀写入者可能遗留 `.lock`、`.tmp-*` 或无索引产物；检查之前都以结构化错误阻止后续写入。
这不是精确活动续跑。

`storage => saved` 指向新不可变产物；`duplicate` 复用精确输入代表，
其标识为 `representative_occurrence_id`。原始 Reason 和配方属于该保存出现。
`limit_reached` 不提供路径，也不为该输入写单独产物。
报告携带当前活动计数及 `durable_occurrences`、`disk_representatives`。
这些是每个签名的数量上限，不是全局字节配额。
所选代表保留完整原始 Reason。

缺失、截断或不匹配代表文件会导致验证失败。
没有 `summary` 的旧分组在写入时明确被拒绝，但仍可重放；
要启用有界存储，请使用新输出目录并保留原始归档。
将上限调低到已保存代表数以下也会拒绝，不删除发现。
存在 `Crash.path` 时，它仍是以 `artifact` 结尾的前缀。

畸形或不匹配配方不阻止保存所选原始输入：产物会不带配方发布，保留完整诊断和 `recipe_error`。
随后 `save/4` 返回主要配方错误、保留处置，并在存在精确输入代表时返回 `saved_artifact`。
即使达到上限，错误仍在运行时上下文保留触发字节；不会声称已存盘。
原始重放只需 `.input` 和可信 `.replay`，独立于可选配方及原始诊断。
参见[崩溃、重放与报告](replay.md)。

存储失败以 `{infrastructure_failure, ErrorMap}` 停止活动，使 `infrastructure_failures`
增加一次，并保留目标崩溃计数。`unique_crashes` 统计已检测签名，包括未保存的签名。
`crash_occurrences` 统计全部目标故障，包括重复和超时。
报告在 `crashes` 和 `failure_context` 保留崩溃结果、堆栈、精确字节，以及配方、哈希和主要存储原因。
无需 worker 崩溃即可传达故障。
重复指纹故障始终在 `failure_context` 中可用，即使 `crashes` 已含较早代表。

最终 CLI 报告及独立配方或输出写入也通过临时文件写入、fsync、关闭、重命名发布。
若报告存储自身失败，CLI 增加基础设施计数，并在错误诊断中包含内存报告，
保留此前主要活动故障。worker 死亡也会增加 `infrastructure_failures`；
模糊测试器保留最后收到的精确输入上下文。
统计中的 `primary_infrastructure_failure` 仅由第一个故障设置。

此协议假设文件系统支持同目录原子重命名及文件和目录 fsync。
不支持的操作返回基础设施错误。

## 验证

`test/efz_limits_tests.erl` 测试真实插桩执行、随机及 staged 上限、保留与恢复语料、
重放和原始崩溃边界。它检查普通文件祖先（类似 `/dev/null/invalid-dir`）、
真实 Unix `eacces`、缺失父目录、第一个产物同步后第二个产物失败、
已提交数据损坏，以及暂存写入者被杀。
权限案例要求非特权测试进程，才能实际触发 Unix 模式拒绝。
现有全新 VM CLI、配方重放、持久化语料和 staged 血缘测试继续验证集成。
