# 执行模型：带受控后代的同步二进制测试驱动

[English](../../execution-isolation.md) · [Русский](../ru/execution-isolation.md) · [Español](../es/execution-isolation.md) · **简体中文** · [所有语言](../README.md)

受支持后端在单一本地 Erlang VM 中运行，要求 OTP 27，并发执行数为一。
契约：**具有受控后代生命周期的同步二进制测试驱动**。
根进程实现 `Module:run(binary()) -> term()` 并调用普通插桩函数。
子进程使用生命周期 API：

```erlang
run(Input) ->
    Parent = self(),
    Child = efz_target:spawn(fun() ->
        Parent ! {parsed, self(), my_parser:parse(Input)}
    end),
    receive {parsed, Child, Value} -> Value end.
```

`efz_target:spawn_link/1` 创建同类所属子进程，并链接调用它的目标进程。
两函数接受 `fun(() -> term())`、返回 PID，仅在执行内部可用。
嵌套子进程使用相同 API。
guardian 创建开始门关闭的进程，安装监视和追踪，记录所有权，再向父进程返回 PID。
只有之后辅助代码才开门。覆盖上下文和生命周期 capability 传给子进程；
其余进程字典与邮箱均全新。

根返回值决定案例结果。
若未链接子进程的结果或异常重要，测试驱动必须等待，并在自身结果中反映。
EFZ 不替代此协议：根进程完成时强制停止活后代，已记录探针包含于该执行快照。

## 独立生命周期所有者

```text
worker / executor caller
  └─ monitor ─ guardian (efz_guardian)
                  ├─ monitor caller
                  ├─ monitor ─ coordinator (root result + DOWN classification)
                  ├─ owns ─ observation ETS and trace session
                  ├─ monitor ─ gated root
                  └─ monitor ─ all controlled descendants
```

guardian 不链接调用方或协调器，并使用稳定 `user` group leader。
这也为 `application:stop(efz)` 所需：应用 master 可能独立于链接关系终止其 I/O 组进程。
受支持环境存在本地 `user` 进程；目标 stdout 经它输出。

协调器安装根监视后报告 `coordinator_ready`。
此前根进程不执行用户代码。
协调器等待 `target_result` 和根 `DOWN`；超时独立由 guardian 管理。
协调器死亡产生基础设施结果并启动相同清理。

guardian 经历以下状态：

```text
running
  ├─ root completed/crashed
  ├─ timeout
  ├─ caller DOWN (including campaign cancellation)
  ├─ coordinator DOWN
  └─ unsupported spawn / exceeded admission bound
       ↓
cleaning: new admissions forbidden
       ↓
kill root + descendants + coordinator
       ↓
DOWN for every owned process + trace delivery barriers
       ↓
global loader trace barrier + pinned code/context integrity
       ↓
snapshot / validation / close ETS / destroy trace session
       ↓
check available evidence of VM contamination
       ↓
final result → caller also waits for guardian DOWN
```

`kill` 不受 `trap_exit` 影响。清理截止时间为 1000 ms；每案例最多接纳 4096 个受控进程，含根。
即使邮箱非空也检查时钟，因此连续 spawn 请求不能饿死超时。
这些是生命周期边界，不是新变异或活动配置。

trace session 使用 `procs` 和 `set_on_spawn`。
普通本地 `erlang:spawn` 被检测为**不受控 spawn**：
不会事后注入上下文，案例以 dirty-runner 结果停止。
guardian 跟踪并杀死发现的本地后代，包括嵌套后代。
`DOWN` 可能先于延迟 spawn trace 到达，因此每次 `DOWN` 后调用 `trace:delivered(Session,Pid)`。
全部存活监视器及送达屏障清空后才允许返回；晚发现子进程新增监视器和屏障。
不依赖简单遍历 links 或一次 PID 快照。

trace session 及送达屏障语义依据已安装 OTP 27.0、
[官方 trace 文档](https://www.erlang.org/docs/27/apps/kernel/trace.html)和
[trace_delivered 文档](https://www.erlang.org/docs/27/apps/erts/erlang.html#trace_delivered/1)核对。
主要控制路径使用真实监视器和开始门；追踪补充模型边界检查。

## 结果与禁止复用

在既有 `outcome`、`coverage`、`coverage_status` 和 `builds` 外增加：

```erlang
#{execution_model => controlled_descendants,
  cleanup => #{status => confirmed,
               processes => [RootPid, ChildPid],
               survivors => [], violations => []},
  runner_reusable => true}.
```

`confirmed` 确认已知进程终止及追踪关闭，不代表任意 OTP 应用完全清理。
检测到全局改变时，即使全部进程已终止，运行器也可能仍为 dirty。

清理截止时间耗尽或 guardian 自身死亡时，结果为
`{infrastructure, #{kind => dirty_runner, ...}}`、`runner_reusable => false`，
以及 `cleanup.status => unconfirmed`。
guardian 故障不声明为干净运行。
guardian 丢失后可能存活的进程要求销毁 VM。
调用方死亡时不向其投递结果，但 guardian 独立完成清理，必要时标记 VM dirty。

dirty 标志保存在 `persistent_term` 键 `{efz_guardian, dirty_runner}`。
`efz_executor:runner_status/0` 返回 `ready` 或 `{dirty, Reason}`。
标志在 `efz:stop/0` 后保留，没有公开重置方法；必须使用新 VM。
dirty VM 中后续 `run/4` 不创建新目标，直接返回带 `cleanup.status => not_started` 的基础设施结果。
第二个并发执行以 `runner_busy` 拒绝；案例并行时无法把共享 VM 状态当作隔离进行检查。

worker 停止活动，增加 `infrastructure_failures`，在 `failure_context` 保留精确输入、配方和执行结果。
此类观察不通过成功反馈，不扩展全局覆盖或语料。

## 共享状态策略

| 资源 | 支持策略 | EFZ 检查或动作 |
|---|---|---|
| 进程字典、邮箱 | 仅根或受控子进程自身状态 | 随进程销毁；下一案例获得全新状态。 |
| 覆盖 ETS | guardian 所有 | 仅清理后快照；结果前关闭表。 |
| 目标所有 ETS | 不得有 execution 外 heir 或所有权转移 | 随所有者消失；新存活表使运行器 dirty。 |
| 既有共享 ETS | 此模型禁止写入 | 不自动复制或回滚内容。已知需要该副作用时，测试驱动调用 `efz_target:dirty(Reason)`；要求一次性 VM。 |
| 注册名称 | 仅用于所属进程 | 所属名称在 `DOWN` 后释放。新建、改变且存活的注册使运行器 dirty；不任意杀外部进程。 |
| `persistent_term` | 目标不得改变 VM 全局值 | 比较前后键和值；变化设置 dirty 标志。不自动恢复。 |
| Application env | 目标不得改变共享 env | 比较已加载应用 env；变化产生 dirty。没有 env 的新应用本身不算 env 变化。 |
| 端口、远程 spawn、发往外部进程的定时器或消息、外部服务、文件 | 不在受支持共享 VM 范围 | 不保证清理、回滚或取消远程工作；要求下一后端。 |

快照诊断合作契约违规；**不是安全沙箱**。
无法检测全部既有 ETS 写入、修改后恢复的瞬时变化、删除他人注册、向外部服务发送消息，
或故意伪造追踪或协议数据。
[覆盖完整性](coverage-integrity.md)额外检查 EFZ 覆盖上下文损坏及热重载。
无关代码并发改变 VM 可能产生保守 dirty 结果。
用 `persistent_term` 或 env 快照覆盖他人变化并不安全，因此不执行恢复。

`A → dirty → A` 以两种方式检查。
对于进程本地字典和邮箱、所属 ETS 及注册，第三个 `A` 真正执行并返回相同结果和探针。
对于 VM 全局修改，第二次运行返回 dirty，第三个 `A` **不执行**。
故意不“修复”被污染值，而是退役 VM。
为隔离测试，这些案例在独立操作系统进程运行。

## 面向异步 OTP 范围的下一后端

任意 OTP 应用、后台服务器、NIF 或端口、远程调用和共享服务需要**一次性 Erlang VM**，
由外部所有者管理操作系统进程，并确认其终止。
此后端尚未实现。即便 VM 后端也必须单独规定文件系统或网络副作用及远程清理。
当前 guardian 不沿 links 跟踪其他进程，不会把这类隔离描述为已解决。

## 回归证据

[efz_isolation_tests](../../../test/efz_isolation_tests.erl)编译真实
[插桩目标](../../../fixtures/efz_isolation_target.erl)。
测试正常、崩溃、超时、trap_exit、链接或未链接及嵌套子进程、调用方或协调器死亡、
临近截止时间 spawn、注册和 ETS 清理，以及匹配子进程覆盖上下文。
受支持案例结束后，所有权报告中的全部 PID 必须已死，包括仍在开始门时死亡的进程。

独立全新 VM 检查 persistent_term、env、共享 ETS、逃逸 ETS 或名称、
普通或嵌套不受管理 spawn、guardian 丢失及活动 dirty 报告。
guardian 故障测试先证明 `unconfirmed` 和禁止复用，再自行终止剩余测试进程：
不把此操作表述为执行器清理。日志位于 `_build/isolation-test/`。
通用覆盖、崩溃及重放和 `A → AB → ABC` 回归继续验证现有流水线。

主要基础设施故障（例如 `coordinator_down`）与 dirty 清理同时出现时，`outcome` 保留首个原因。
`coverage_status`、`cleanup`、`runner_reusable => false` 记录 VM 不可复用；
下一输入被当作 dirty runner 拒绝。
`coordinator_dirty` 回归在独立 VM 检查此组合。

实际回复之后的晚到 guardian 丢失由 `efz_crash_retention_tests` 单独检查：
仅测试 AST 转换在私有 VM 中，在 guardian 发消息后加一道门。
协调器死亡后回复包含原错误；之后 guardian 异常终止。
报告和统计保留原始原因，`guardian_failure` 描述次要原因，
`execution_evidence` 保留原清理及覆盖。
运行器退役，下一目标不启动。生产不提供故障注入选项。

## 可选运行时观察

P0 仅采样 guardian 接纳的进程及其 ETS 所有者。
它给 guardian 增加有界采样器监视及生命周期；所有权、开始门、追踪屏障和 dirty-runner 规则仍具权威性。
采样器失败是部分诊断证据；guardian 故障或未确认生命周期故障仍使 VM 退役。
清理 kill 不构成进程泄漏。参见[运行时诊断](runtime-diagnostics.md)。

### 不同的外部 VM

持久 Erlamsa 提供者 VM 只负责变异，不执行目标代码；其生命周期不改变默认的 isolated 目标执行。参见 [worker 指南](erlamsa-performance.md)。
