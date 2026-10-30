# P1-01 外部 supervisor

[English](../../p1-01-external-supervisor.md) · [Русский](../ru/p1-01-external-supervisor.md) · [Español](../es/p1-01-external-supervisor.md) · **简体中文** · [所有语言](../README.md)

状态：Linux 上 **DONE**。验证日期：2026-09-21。实现基线：
`9303c6e0734cc135700e62b0774f4a0011e97d48`。

受监督 backend 为显式选项。原有执行模式及公开 harness 契约
`Module:run(binary())` 不变。

## 基线与实际架构

环境：Linux 6.8.0 x86_64、OTP 27、ERTS 15.0、rebar3 3.25.0。项目最低
OTP 27。旧模式在 OTP 27 和文件系统假设成立处可用；P1-01 生命周期保证
明确仅 Linux，因使用 `pidfd`、`PR_SET_PDEATHSIG`、subreaping、Unix 对端
凭据及 `/proc` 后代枚举。

开始前 checkout 已有修改。原有 hit-count/corpus 变更列于
`_build/p1-validation/before.status`，另行保留。无 reset、clean、checkout、
目标 harness 改动或删除。

真实旧调用路径：

```text
scripts/fuzz.escript
  -> efz_cli:main/1
  -> efz:start/1 -> efz_fuzzer:init/1
  -> efz_worker (种子校准 / 变异 / 反馈 / 语料 / P0 验证)
  -> efz_executor:run/4
  -> efz_guardian:run/6
  -> efz_executor:invoke/4 -> Harness:run(Binary)
  -> guardian 清理/覆盖/runtime 结果
  -> efz_feedback:evaluate/3 -> efz_corpus / 崩溃和 runtime 存储
```

`efz_guardian` 管理 worker VM 内目标根及受控后代、目标期限、清理和
污染 runner 判定。`efz_runtime` 采样这些所属进程。`efz_corpus_store`
负责成功语料持久化；`efz_runtime_store` 与 `efz_crash` 发布发现。
重放由 `efz_replay_cli`、`efz_replay`、`efz_runtime_replay` 实现。
该 checkout 会重新校准恢复语料，但无 minimizer。目标回调验证及 `on_load`
在活动 VM 内由 `efz_config`/`code:ensure_loaded` 执行；插桩 BEAM 通过
`efz_instrument` 加载。因此须把完整活动循环放进外部 worker，而非仅 `run/1`。

P1-01 前的正式基线：

| 命令（`ERL_FLAGS='+S 4:4'`） | 退出 | 结果 |
|---|---:|---|
| `rebar3 compile` | 0 | PASS |
| `rebar3 eunit` | 0 | 223 项 PASS |
| `rebar3 ct` | 0 | 3 项 PASS |
| `rebar3 dialyzer` | 0 | PASS |
| `rebar3 xref` | 0 | PASS |

原始日志为 `_build/p1-validation/baseline-*.log`。

## 已实现的进程边界

`--supervised` 在 `efz_cli:main/1` 内、目标查询、应用启动、重放或回调验证前
委派。原 CLI 以 `open_port({spawn_executable, Python}, ...)` 和明确参数向量
启动只处理文件的 Python 控制器。控制器绝不 import、加载或调用目标、harness
或 NIF 代码。它计算本地 EFZ、工件、辅助文件、harness、`.so` 以及有界命令
配置的哈希。

每代控制器以参数向量（无 shell）启动 `priv/efz_vm_launcher`。C launcher
fork 后 `execv` 启动 `erl`；新 BEAM 调用 `efz_external_worker:main/0`，
再运行普通 `efz_cli` 和真实活动。目标/harness/NIF 加载被限定在 worker 地址
空间。guardian 在 worker 内保持不变。

Launcher：

- 获取控制器 `pidfd`，安装 `PR_SET_PDEATHSIG` 并在安装后检查父进程；
- 让 BEAM 成为新 session/进程组 leader，设置自己的父进程死亡 SIGKILL 竞态检查；
- 作为 child subreaper，在报告 `cleanup_confirmed=true` 前杀死并回收收养后代；
- 返回原始 `waitpid` 状态、独立 signal/exit code 以及是否主动 kill；
- 持续排空 worker stdout/stderr，累计字节，仅保留 4096 字节尾部；禁用 worker
  crash dump/core；
- 只有确认旧 worker 清理后才启动替代。

控制器也持有调用 CLI 的 `pidfd`，并通过继承 port 做实时 ACK 挑战。因此 CLI
或控制器遭 SIGKILL 都会使 launcher 杀死并回收卡在 NIF 的 worker。
这是生命周期约束，不是安全沙箱：原生代码仍能以 worker 凭据访问文件系统、
网络和主机。

## 强制执行屏障

唯一集成 hook 是 `efz_executor:run/4` 的第一步：

```text
efz_worker 选择/生成 Input
  -> efz_executor:run/4
  -> efz_external_worker:execution/4
  -> PREPARE(Input, digest, phase, timeout, bounded recipe)
  -> 控制器验证固定模式
  -> fsync artifact.input, artifact.external.json, 可选 artifact.recipe,
     及 manifest.json，位于私有暂存目录
  -> fsync 暂存目录
  -> 整体重命名到 CAMPAIGN/RUN 并 fsync 活动目录
  -> 原子写入/fsync authorized.json 并 fsync run 目录
  -> COMMITTED/RUN(RunId, digest)
  -> worker 验证 generation、RunId 和摘要
  -> 既有 executor -> guardian -> Harness:run(Input)
  -> 有界 RESULT -> 原子带校验 result.json -> RESULT ACK
```

由于都用 `efz_executor:run/4`，屏障覆盖种子校准、恢复校准、变异及 P0
验证/再现。外部发现重放是单输入真实活动，通过同样屏障。此处无最小化实现。
旧模式的 gate 是直接调用，无 IPC 或文件操作。

写入/fsync/rename/授权失败后，不允许执行目标。日志只有一个进行中的 run，
输入最多 1 MiB，配方及元数据各 64 KiB，可配置总字节预算，最多扫描/记录
100000 条。原始输入是权威。可用且有效时包含原有 EFZR 配方；缺失或达到元数据
上限会明确记录。

发布让输入与元数据组在同一文件系统原子可见。文件和目录 fsync 提供 EFZ 其他
位置采用的最强实用本地保证；不承诺超越 OS fsync 成功的硬件行为。
`authorized.json` 区分已提交但未发执行许可的 PREPARED 与许可已持久记录的 run。
它不能证明 worker 已进入目标。因此：

- 未提交 staging 不归因于目标；
- PREPARED 未授权转为 `interrupted_prepared`；
- 已授权无 RESULT 转为 `interrupted_unknown`，除非活 launcher 提供更强终止证据；
- 不声称跨崩溃 exactly-once 执行。

最终提交按 campaign/RunId 原子、校验且幂等。启动验证所有有界 manifest/result，
完成不完整记录而不虚构原生崩溃。后续 result/index 发布失败时，已提交输入仍可重放。

## 协议与状态机

Unix-domain 控制 socket 与 stdout/stderr 分离。Linux `SO_PEERCRED`
须等于 launcher 报告的 worker PID 和当前 uid。帧为大端 `u32` 长度加固定
基本类型模式。先读四字节就拒绝非法长度，不累计载荷。最大帧为输入 + 64 KiB
配方 + 59 字节。每读 4096 字节，部分帧期限一秒，解码器支持多帧。

控制通道无 ETF/JSON/压缩。RESULT 四字节。可选配方仍是校验的 EFZR；
存前检查大小、ETF 版本及压缩标签，控制器从不解码。

协议 v1 消息为 HELLO、READY、PREPARE、RUN、RESULT、DONE/SHUTDOWN、ACK。
每帧验证类型、状态、generation、RunId、身份与精确长度。HELLO 包含协议标记、
组合文件身份、worker 配置身份、OS PID、OTP 和 ERTS。意外、过期、重复及
终态后的结果均为协议失败。

状态：STARTING、SETUP、READY、PREPARING、EXECUTING、FINALIZING、RECYCLING、
STOPPING。RESULT 在 ACK 前持久接受并清除进行中记录；随后退出不能把该 run
改判原生崩溃。绝对硬期限先到时，晚 RESULT 被忽略，launcher kill 是唯一
终结分类。EOF 与 wait status 独立处理，死亡分类前先排空最后完整帧。

分类依据原始证据：

| 观察 | 分类 |
|---|---|
| 已授权 run 进行中收到 signal，非控制器 kill | `native_vm_crash` |
| 无 signal 的退出码 | `worker_unexpected_exit` |
| 控制器绝对期限/kill | `worker_hard_timeout` |
| 非法 IPC | `worker_protocol_failure` |
| 最终确定不可复用 guardian 结果 | `dirty_recycle` |
| READY 前/空闲时死亡 | 启动/基础设施，无测试输入发现 |
| 用户/父进程停止 | 活动停止，绝非原生崩溃 |

Signal 证明 VM 终止，不证明目标责任或根因。`exit(139)` 记录 exit code 139、
signal 0。Launcher SIGKILL 记录 `launcher_kill=true`，绝不称原生崩溃。

## 期限、回收与恢复

每 run 的外部期限为单调绝对时间：

```text
目标 timeout + guardian 清理（1000 ms）
+ CLI P0 后置内存余量（启用时 100 ms）
+ 配置 IPC 宽限（默认 1000 ms）
```

流量和日志不延长期限。启动/空闲独立限时（默认 10000 ms），launcher 终止
最多五秒，收养子进程清理最多两秒。不确认清理则中止且不重启。

原生崩溃、硬超时和 dirty result 保存/结束当前 run，隔离摘要，等待旧进程
死亡，增加 generation，重新核对文件身份，恢复持久 corpus 并校准。
每次重新校准也过屏障。隔离输入被跳过，避免崩溃种子循环。控制器拥有重启预算
（8）、有界线性退避、活动期限、执行上限、变异剩余额度、P0 验证剩余额度及
日志字节。READY 前的启动/身份失败不会无限重启。

恢复的是持久语料和全局预算。worker 本地覆盖、feedback、RNG、staged 游标
重建；不宣称精确续跑。

## CLI 与工件

示例：

```sh
ERL_FLAGS='+S 4:4' rebar3 compile
ERL_FLAGS='+S 4:4' escript scripts/fuzz.escript \
  --supervised --target my_harness --code-path harness-ebin \
  --artifacts instrumented --seeds seeds --corpus-dir out/corpus \
  --out out --timeout 1000 --max-iterations 10000 \
  --restart-budget 8 --supervised-runs 20000 \
  --campaign-ms 3600000 --ipc-grace-ms 1000 --journal-bytes 268435456
```

`OUT/external-runs/CAMPAIGN/RUN/` 包含 `artifact.input`、
`artifact.external.json`、可选 `artifact.recipe`、`manifest.json`、
`authorized.json`、带校验 `result.json`。配置身份和精确文件列表存活动目录。
外部发现在 `OUT/crashes/external/` 原命名空间索引。worker 报告及普通崩溃/
runtime 发现在 `OUT/worker-GENERATION/`。

重放本地选择目标代码并验证文件/harness 身份：

```sh
escript scripts/replay.escript \
  --external-finding OUT/external-runs/CAMPAIGN/RUN \
  --target my_harness --code-path harness-ebin --artifacts instrumented \
  --out recheck --reproduce-runs 3
```

它执行有限个隔离 generation，报告 observed N/M，不是一次运行布尔值。

## 原生验收证据

最终命令：

```sh
python3 -m unittest discover -s test -p '*supervisor_test.py' -v
```

退出 0，13/13 项。原始日志 `_build/p1-validation/posthook-native.log`。
证据根 `_build/p1-native-68udkvqj`。

真实 CLI 的 SAFE -> SIGSEGV -> restart -> SAFE 活动记录：

- 活动 `119e4f3df348420e98488ed25bde3cc4`；
- supervisor PID 739219，CLI PID 738777；
- 第 1 代 worker PID 739271；RunId 1 SAFE 完成；
- RunId 2 原始 `SEGV`，SHA-256
  `8f243e33082126167daac18a24f576245ff332a18dc217093bc6cf9d6bbcdc1b`；
- 权威 `waitpid`：signal 11、exit code -1、原始状态 139、
  `launcher_kill=false`、`cleanup_confirmed=true`；
- 发现路径：
  `_build/p1-native-68udkvqj/SEGV-61938280703258/out/external-runs/119e4f3df348420e98488ed25bde3cc4/2`；
- 第 2 代 worker PID 740096；恢复语料报告 3 输入，重新校准 SAFE1，
  RunId 4 成功执行 SAFE2；
- 最终 completed，两代，四次有屏障执行。

SIGABRT 独立产生 signal 6、`launcher_kill=false`，重启并完成。
每个原生发现的两次隔离复核都为 `observed 2/2`。fixture NIF 只在子 worker VM
加载，core/crash dump 禁用。

其他最终验收：

- NIF 挂起：`worker_hard_timeout`、launcher signal 9、
  `launcher_kill=true`、清理确认，第 2 代到达 SAFE2；
- DIRTY：原结果存为 `dirty_recycle`，SAFE2 前换代，无原生发现；
- `exit(139)`：`worker_unexpected_exit`、exit 139、signal 0；
- 内部 WAIT/BUSY：保留 guardian 结果，分别 `timeout_waiting`、`timeout_busy`；
- 目标输出 8,389,639 字节被排空而不阻塞，尾部始终限于 4096 字节；
- READY 前启动 `on_load` SIGABRT：零执行、零发现；
- 持久写预算失败：非零退出，marker 证明未进入目标；
- 暂不发送 RUN：真实子 BEAM 发出 PREPARE，但日志提交和摘要绑定许可前不触碰目标；
- 拒绝 malformatted/超大/似压缩帧、部分/多帧、旧 generation、错误身份、重复 RESULT；
- 最终提交 EIO 保留已提交原始输入，恢复恰好一次；
- SIGKILL CLI：worker 744649、launcher 744647、controller 744618 均从 `/proc`
  消失；SIGKILL controller：worker 744920、launcher 744919、controller 744894
  均消失；恢复分类为不确定而非原生目标崩溃；
- 重启预算零：第一次崩溃后以 `restart_budget_exhausted` 停止；持续启动失败在 READY
  前停止。

## 回归与性能

最终正式结果（均 `ERL_FLAGS='+S 4:4'`）：

| 命令 | 退出 | 结果 |
|---|---:|---|
| `rebar3 compile` | 0 | PASS；pre-hook 编译 Linux helper |
| `rebar3 eunit` | 0 | 224 项 PASS（基线 223） |
| `rebar3 ct` | 0 | 3 项 PASS |
| `rebar3 dialyzer` | 0 | PASS，无警告 |
| `rebar3 xref` | 0 | PASS |

日志 `_build/p1-validation/release2-*.log`。第二次正式 EUnit 也 224 项全过。

只含已暂存 P1 的精确树还通过 `git checkout-index` 导出，独立于原 hit-count
工作验证：compile、211 EUnit、3 CT、Dialyzer、Xref 通过；13 项原生测试用
33.649 s。数量较少是预期，因为快照刻意排除无关未提交测试。

诊断 benchmark 对同一安全目标交替重复三次，300 次变异加一次校准。
启用 fsync：

| 中位数 | 旧模式 | 受监督 |
|---|---:|---:|
| 墙钟时间 | 2.246 s | 6.062 s |
| 变异吞吐量 | 133.6/s | 49.5/s |
| 总吞吐量 | 134.0/s | 49.7/s |
| 持久 prepare 总时间 | n/a | 2.441 s |

受监督墙钟为 2.70x，吞吐量降低 62.9%。持久发布/授权约 8.11 ms/输入。
余下成本含额外 VM、IPC、最终提交。原数据
`_build/p1-validation/benchmark-final.log`；每 run 工件位于
`_build/p1-bench-i_u4wnm7/`。

## 限制

- 完整保证仅 Linux。非 Linux 受监督启动明确失败；旧模式仍可用。
- 这是崩溃约束与恢复，不是对抗恶意原生代码的沙箱。
- 文件系统/网络/外部服务副作用无法回滚。
- 依赖 fsync/rename 成功；断电行为最终取决于本地文件系统和硬件是否履行这些操作。
- 日志证明准备和许可，不证明精确进入目标；不声明 exactly-once。
- 恢复并重新校准 corpus。刻意不声明 RNG、staged 游标和全局覆盖检查点精确恢复。
- 支持一个 worker、一个进行中测试；多 worker/分布式调度在 P1-01 外。
