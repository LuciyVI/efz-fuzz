# 连续模糊测试

[English](../../continuous.md) · [Русский](../ru/continuous.md) · [Español](../es/continuous.md) · **简体中文** · [所有语言](../README.md)

常规单 VM EFZ 循环通过 `max_iterations => infinity` 支持不限次数的随机和
staged/Gleam 测试活动。有限活动保留现有默认值、执行限制及耗尽或空闲停止行为。

```erlang
{ok, _} = efz:start(#{target => my_harness, seeds => [<<0>>],
    artifacts => Artifacts, mutation_mode => staged,
    max_iterations => infinity, corpus_dir => "out/corpus"}).
%% 稍后，在控制 VM 中：
ok = efz:request_stop().
Report = efz:await(infinity).
stopped_by_user = maps:get(status, Report).
ok = efz:stop().
```

`request_stop/0` 是异步且幂等的。它在当前目标调用或迭代完成后停止调度，并遵守其超时
和清理规则。`await/1` 返回最终报告；`stop/0` 仍用于关闭应用，应在取得报告后调用。
已经结束的活动保留原始状态和报告。

对于 CLI 活动：

```sh
escript scripts/fuzz.escript --config campaign.term --out out \
  --max-iterations infinity
# 在另一个终端中：
touch out/stop.request
```

CLI 保存 out/report.term；请求停止时返回 0，除非既有故障或严格覆盖策略违规导致报告失败。
重新使用输出目录前，请删除遗留的 stop.request。CLI 的有限模式保持不变。
Ctrl-C/SIGTERM 会终止进程，不属于这种有序保存报告的协议。
外部 `--supervised` 启动器保留独立的有限运行、重启和截止时间策略；
此次修改不会移除这些保护措施。

连续 staged 模式在所选阶段缺少 havoc 时会追加它，并根据生效的计划计算常规配置及配方标识。
确定性游标不会重置。空闲耗尽时，会使用同一个显式传递状态的 PRNG 回退为真正的字节变异，
采用标准可重放操作，并累计 `continuous_fallbacks` 计数。非空输入翻转一位；空输入插入一个字节。
staged 无限模式要求 max_input_bytes > 0。

语料接纳与持久化、语义反馈、主目标执行、清理和重放仍由 EFZ 管理。
Gleam 提供器回退和有限判定器预算保持不变。变异扫描空闲时，不会重启或重新校准整个活动。
基础设施故障仍会停止活动。

连续模式将解释性决策列表限制在 1,024 条，并统计被丢弃的决策；
有界配方轨迹和运行时检查报告保留原有上限。工作语料和真正不同的发现分组不会自动裁剪，
所以仍需规划内存和磁盘容量。

连续运行演示及 `s` 停止并保存按键见 [TUI 控制](tui.md#连续模式)。

## 验证

- 默认 EUnit：319 项通过；启用 Gleam 的连续模式专项测试：9 项通过。
- Common Test：3 项通过；xref 和 Dialyzer 通过；Python TUI 检查：2 项通过。
- 专项测试覆盖无限配置、空与非空父输入的可重放回退、无需重置游标的空闲耗尽、
  持续进展、可重复停止请求，以及最终报告之后没有继续执行。
- 真正的 Gleam term/API 提供器在引导反馈和有界判定器预算下连续运行；
  CLI 测试通过 stop.request 请求停止，验证退出码 0 和保存的报告。
- 伪终端演示超过 11,000 次变异（最终停止时为 11,183），随后 `s` 键保存 report.term，
  最终执行计数保持不变。另一次持久化演示保存了语料输入及元数据记录，并在 761 次变异后正常停止。

通过移除执行上限并测试进展与停止边界来确认连续运行能力；这些有限验收运行并不声称
已经测试过无限时长或无限存储。

## 长期运行的客户端生命周期

超时的 `efz:await/1` 调用会释放协调器中的待处理条目。
等待期间死亡的调用方同样受到监视并被移除；成功完成时，会向剩余调用方回复，
并释放其监视器。

目标执行期间，停止请求仍可及时响应；重复请求只会排入一个 worker 停止操作。
优雅停止会等待当前执行返回或达到配置的超时。停止请求待处理时发生的 worker 故障，
在最终报告中仍被保留为基础设施故障。

已停止的连续活动可使用相同 `corpus_dir` 和 `seeds => []` 重新启动：
已保存输入会在恢复变异前加载并重新校准。恢复的是语料，而不是之前的随机数生成器位置。
