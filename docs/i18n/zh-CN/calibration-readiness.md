# EFZ 对校准与 feature_stability 的就绪审计

[English](../../calibration-readiness.md) · [Русский](../ru/calibration-readiness.md) · [Español](../es/calibration-readiness.md) · **简体中文** · [所有语言](../README.md)

日期：2026-09-09。**结论：READY WITH PREREQUISITES。**

对于固定构建、配合执行的目标以及**单个目标进程**的范围，已经能够获得每次执行完整、精确的观测集合。无需第二个执行器、新后端、命中计数器或桶。可靠集成首先需要明确终止原因，以及完整性、清理和 runner 丢失处理契约；随后需要独立的重复执行收集器，不能在每次重复时调用新颖性判断。

对于任意进程树、有状态 OTP 应用、原生/NIF 覆盖，或整个 VM 崩溃后的恢复，当前实现为 **NOT READY**：不存在这些契约或 runner。这是范围限制，不能据此把其覆盖当作空集并得到 100%。

本任务**没有实现**校准机制。生产代码、API、依赖、默认值及搜索算法均未改变。唯一永久新增的文件是本报告。夹具、诊断脚本和日志位于 `/tmp/efz-calibration-audit.rIBEql/`；附录包含其源码，以便临时目录删除后仍可复现。

证据标记：**C**——在当前代码中发现；**E**——由新运行确认；**D**——文档中的声明；**P**——提议但尚未实现；**NV**——未验证。历史测量不作为本次审计结果。

## 1. 检出版本、工具与当前架构

**C/E。** 仓库为 `efz/`，分支 `main`，HEAD 为 `ac09c1f3e938c3a79b369fc6a87d61c1ae739db4`（`chore: initialize efz OTP project`）。该提交不能描述所审查实现的全部内容：初始树已经修改了 `README.md`、`rebar.config`、`src/efz.app.src`，并包含未跟踪目录 `bench/`、`docs/`、`examples/`、`fixtures/`、`scripts/`、`test/` 以及大部分 `src/efz_*.erl` 模块。完整初始状态与差异保存在 [status.txt](/tmp/efz-calibration-audit.rIBEql/status.txt) 和 [diff.txt](/tmp/efz-calibration-audit.rIBEql/diff.txt)。

运行前记录了 `git ls-files --cached --others --exclude-standard` 列出的全部 78 个现有文件的 SHA-256；实验后内容仍一致。加入报告前，这些文件均未改变。没有执行 reset/clean/stage/commit/push，也没有修改 Git 身份或远程配置。在仓库及检查过的上级目录中未找到适用的 `AGENTS.md`。

源码树列表的哈希（按 UTF-8 行排序，格式为 `path + NUL + file_sha256 + LF`）为 `24eafa7e45d6584b1ff2eb03021391c3e299b95df2a51ab7041726c9a612cf23`。完整列表见 [before-sha256.json](/tmp/efz-calibration-audit.rIBEql/before-sha256.json)。下列关键文件将结论绑定到这个有未提交修改的检出树：

| 文件 | SHA-256 |
|---|---|
| `src/efz_executor.erl` | `c4a7802a9ac299445b5b6b50fd1ded92ae09e814ad25f4f300054503e6745f47` |
| `src/efz_cov.erl` | `2d32b0aca9c1641e40ab111e844d020004fb5cb9b743d76c40a46385fa4489d0` |
| `src/efz_cov_rt.erl` | `47e84c8f84861ff7ec7817fa34b9b1234af571ce3bf316fe3d2867428dcfb466` |
| `src/efz_cov_manifest.erl` | `4951ecc1f7104fca08928ee7dfa669cfacc8b27cac856961db06f9ea14451544` |
| `src/efz_feedback.erl` | `0be0ecc64e967b776cc990259d569539e520ba7f603e838c444cdd44e2b30bb6` |
| `src/efz_worker.erl` | `3e4f4d383f86b0bfe9af2d6a366fda848818dcb33f85652efd69d325a9e3baa4` |
| `src/efz_instrument.erl` | `c4dfbe3b9caadfc4ed60153d1a6573b152f31fc5b95e34a168a6bea730695351` |
| `src/efz_instrument_pt.erl` | `b781f83981aef57f59a79c42c099a07076002434ceecd2ecef8feb05930766cd` |

**E。** `rebar3 version`：Rebar3 3.25.0，OTP 27 / ERTS 15.0。`releases/27/OTP_VERSION` 包含 `27.0`。架构为 `x86_64-pc-linux-gnu`，操作系统为 Linux。审计所用常规 VM 有 **16 个调度器，16 个在线**；未设置 `ERL_FLAGS`、`ERL_AFLAGS`、`ERL_COMPILER_OPTIONS`。主诊断脚本及其三个新 VM 也记录到 16 个在线。没有沿用 Phase 2.1 中的 4。现有新 VM EUnit 辅助程序明确使用两个调度器；这是独立测试设置，并非主测量配置。

**C。** [rebar.config](../../../rebar.config) 第 1–14 行：最低 OTP 27，`debug_info,warnings_as_errors`，`src_dirs = ["src","examples/simple_parser"]`，`deps = []`；`rebar.lock` 为空。没有命名项目配置。`compile` 使用 default，EUnit/CT 使用 Rebar3 标准 test 配置。当前树中没有 GitHub/GitLab CI 配置、独立 Makefile、Go 模块/控制器或 Python 控制层。README 列出本地 rebar 命令，但这不是 CI 已运行的证据。未配置格式化器或 lint 工具。

**C/E。** 这是单一的 Erlang 原生 OTP EFZ 实现：

```text
escript / Erlang caller
  efz:start/1 -> efz_sup -> efz_fuzzer
                              |-> efz_corpus (entries, selector RNG)
                              |-> efz_stats
                              `-> efz_worker_sup -> one efz_worker
                                       |-> prepared validation plan
                                       |-> random / staged mutation state
                                       `-> efz_executor:run/4
                                              -> coordinator -> target process
```

`src/efz.erl:start/1` 第 3–7 行；`efz_fuzzer:init/1` 第 17–25 行；`efz_worker_sup:init/1` 第 2 行。应用 `efz` 版本为 0.1.0，依赖 `kernel`、`stdlib`、`crypto`（`src/efz.app.src:1–18`）。使用 crypto 不意味着支持原生覆盖。

| 检索词 | 发现 |
|---|---|
| EFZ/ErlFuzz、Go controller、`input_coverage` | 当前运行时使用 EFZ 和 Erlang；未找到其他名称或该模式 |
| `efz_instrument`、`efz_cov`、`efz_feedback`、`efz_executor` | 存在 |
| `efz_cov_runtime`、`efz_run_context` | 实际是 `efz_cov_rt` 和 `efz_cov` 中的元组上下文；没有这些名称的模块 |
| `efz_value_runtime`、`efz_hook_runtime`、`efz_data` | 未找到；不存在值/转移反馈 |
| `execution_ref`、`builds`、`coverage_status`、`elapsed_us`、`target_outcome` | 在 `run/4` 结果中存在，但失败分支可能没有 `target_outcome` |
| `input_id` | worker/corpus 元数据中的输入 SHA-256，不是常规执行器结果字段 |
| `cleanup_status`、generation、layout digest、`feedback_epoch` | 不存在；不能归属于现有契约 |
| `RunRef` | 存在内部 `Request` 和独立上下文 `Ref`；二者都不能提供可移植输入 ID |

**C/E。** 默认值由 `efz_config:defaults/0` 第 4–6 行及运行时确认：`coverage => automatic`、`coverage_validation => prepared`、`coverage_backend => ets`、`workers => 1`、`mutation_mode => random`，超时 100 ms。明确允许 `ets_member`，`per_execution` 是另一验证模式。这是两个独立维度，不是四种特征空间。低层 `run/4` 不自行创建准备好的计划，调用方提供 `coverage_plan` 或 `manifests`。`run/3` 使用手动兼容模式，仅返回 outcome。

**C/E。** `seed_calibration` 是**每个初始种子执行一次**：`efz_worker:init/1` 第 20–24 行，`handle_info/2` 第 26–30 行；`efz_feedback:evaluate/3` 第 9–17 行。两个种子、零次变异的检查产生 `calibrations=2, executions=0, discoveries=0`，有两个 `seed_calibration` 原因。当前没有 R 次重复、交集/频率或稳定性指标。README 的 “calibrates” 指这种初始处理，不是重复稳定性评估。

## 2. 实际测试用例路径与状态所有权

主要代码链接：[执行器](../../../src/efz_executor.erl)、[覆盖上下文](../../../src/efz_cov.erl)、[hook](../../../src/efz_cov_rt.erl)、[worker](../../../src/efz_worker.erl)、[反馈](../../../src/efz_feedback.erl)。

```text
Before measurement:
  config + artifacts preflight; load selected BEAM; create plan once
  take seed unchanged OR corpus selection -> mutation -> binary/recipe

For one run/4:
  caller creates Request, spawn_monitor(coordinator)
    coordinator monitor(caller)
    open: new context Ref + new public ETS         [before Started]
    Started = monotonic_time(microsecond)
    spawn_monitor(target)
      attach(Context) -> M:run(Input)
      selected module bodies -> synchronous ETS membership publications
      outcome / caught error, throw, exit
      target_result{Ref, target PID, Outcome}
    wait: result + target DOWN, or DOWN/timeout/caller DOWN
    timeout/cancel -> kill(target) + confirmed DOWN
    ordinary branch: sticky failure -> snapshot -> identity validation -> result
    send result to caller                         [still before finally cleanup]
    after: repeat kill_and_drain -> close ETS -> demonitor caller
    coordinator terminates
  caller waits for coordinator DOWN before returning from run/4

After run/4:
  worker increments calibration OR mutation execution counter
  feedback(status, outcome, builds, Observed) -> novelty/merge decision
  corpus add for new successful input; crash storage separate
  decisions/statistics; next iteration
```

**C。** `elapsed_us` 从 `efz_cov:open/1` 之后开始，包含目标启动、attach、`M:run/1`、等待终止、读取和验证快照；在 `builds(Options)`、发送结果及 finally 清理之前结束（`efz_executor:coordinate/6:28–59`）。这既不是纯目标时间，也不是 `run/4` 完整墙钟时间。完整同步调用还包括上下文分配和清理。`wait_target/5:62–79` 的截止时间在创建目标后单独按毫秒计算；原生调用卡住时，它不保证墙钟时间上限。

**C。** 没有通用解码器、`before_input`、目标状态重置、`after_input` 或目标清理回调。种子为二进制，变异返回二进制；staged 配方在执行器之前组成（`efz_worker:staged_iteration/1:42–52`）。大小和字典检查不计覆盖。低层 `run/4` 允许任意 Erlang 项作为 `Input`，直接交给 `M:run/1`；含 PID 的诊断元组输入使用这一低层接入点，不是新活动 API。Replay 的文件读取、重建和预检均在执行前完成（`efz_recipe:execute/5`、`execute_file/5` 第 85–114 行）。

**C。** 特征范围是 attach 后该进程调用的已选模块函数体。因此，选中 `M:run/1` 内若有解码/setup，也会测量。目标 `try ... after` 测量到正常或异常终止；强制 kill 不保证执行目标清理。Transform 自身把 EFZ hook、执行器、统计收集器和 transform 排除在允许列表外（`efz_instrument_pt:parse_transform/2:26–33`）。attach 前的编译/加载和目标 DOWN 后的协调器清理不产生 EFZ 探针。用户选中的适配器也可能加入共享探针；应在允许列表中记录，不应计算百分比后再减去这些特征。

| 状态/资源 | 所有者与生命周期 | 保证 / 边界 |
|---|---|---|
| Corpus 和选择器 RNG | `efz_corpus` gen_server；整个活动期间 | 插入顺序；随机选择器或 staged 计划器；`src/efz_corpus.erl:5–14` |
| 变异 RNG/游标、全局新颖性、决策 | `efz_worker` | 不得因稳定性重复执行而改变；`worker:7–24,42–56,108–125` |
| 准备好的计划 | Worker；离线调用方 `prepare/2` | 无名受保护 ETS；直到释放或所有者死亡；不是观测缓冲区 |
| Request 与协调器监视器 | `run/4:7–24` 调用方 | 响应绑定 Request/PID；调用方等待协调器终止 |
| 上下文 Ref 和公共 ETS 集合 | 协调器 `coordinate/6:26–29`；`cov:open/0:11–13` | ETS 在目标死亡后仍存在，随所有者销毁；没有 heir |
| PD 中的上下文引用 | 仅 attach 后的目标 | 不是唯一命中存储；子进程不继承 |
| 调用方/目标监视器、截止时间 | 协调器，`wait_target/5`、`kill_and_drain/2` | 使用 `receive after`，不是计时器进程/端口；清理时有独立新监视器 |
| 快照列表 | 协调器，随后复制给调用方 | 不可变 Erlang 列表；删除 ETS 后仍存在；先有数据再判断新颖性 |
| 生产执行器中的端口 | 不存在 | 测试/审计中的新 VM 端口归外部诊断 escript 所有 |
| 子进程、OTP 服务、目标计时器、外部资源 | 执行器不管理 | 没有目标树列表、子进程 ACK 屏障或通用重置 |

### 什么真正证明静止状态

**C/E。** 同步 `ets:insert` 完成后，在 hook 返回前就发布存在信息。只有 `target_result` 不够，执行器还等待监视器 DOWN。超时/取消调用 `exit(Target,kill)`，不依赖 sleep，而等待新监视器 DOWN（`kill_and_drain/2:82–87`）。此后该目标 PID 不能继续写；每次执行创建全新 PID/Ref/Tid。快照列表在删除 ETS 前读取。协调器终止前，调用方不能得到 `run/4` 成功返回。

这证明的是**一个 PID**，不是进程树。子进程既无 ACK 协议，也不递归加入范围。新子进程不继承 PD，普通 hook 不活跃。手工传入上下文的子进程在旧表存在时仍可写，包括父进程终止后。对于这种不受支持的写入者，snapshot 与 close 之间没有屏障。close 后，过期 hook 得到表错误，而不是新上下文。诊断明确在根进程之后等待子进程，启动下一上下文，并确认下一上下文未受污染；这不证明子进程树覆盖完整。

**C/E。** 命中时**没有**代际验证。Ref 用于关联结果/失败消息，不存入 ETS 行，也不在命中时与表比较。`attach/1:24–29` 检查表所有权和引用/PID 类型，不检查 Ref–Tid 绑定。诊断中保留相同所有者/Tid、只替换 Ref 被接受。正常隔离来自不复用的新 Tid 和进程，而不是代际检查。`snapshot/1:31–34` 不检查写入者是否停止：直接读取活跃上下文先得到 `{a}`，同一写入者合法写入后得到 `{a,b}`。校准应消费 `run/4` 结果，不能任意读取 ETS。

### 终止分支：当前结果与指标资格

| 分支 | 实际数据与清理 | 对未来序列的决定 |
|---|---|---|
| 正常返回 | `outcome={ok,V}`，`target_outcome` 相同；状态 ok 时根快照完整；先 DOWN 后读取，先 close 后返回 | 满足根/reset/build 契约时可计入重复测量 |
| 目标返回 `{error,invalid_input}` | 得到 `{ok,{error,invalid_input}}`，不是执行器独立 invalid 分类；当前反馈视为成功返回 | 不按 Value 名字排除；单独记录 outcome；空 U 得到 N/A |
| 配置非法/staged 种子过大 | 目标前拒绝；不创建快照（`efz_config:prepare/1,prepare_mutation/1`） | 请求错误，不是空的可测重复 |
| 目标 `error`/`throw` | `{crash,Class,Reason,Stack}`；保留命中，正常目标 DOWN 与清理 | 终止异常的有效快照；不能仅按 outcome 把崩溃排除于稳定性 |
| 目标 `exit(Reason)` | `{exit,Reason}`，状态可能 ok | 语义上完整的异常可计入，但当前结果无法区分外部终止；需要来源 |
| 外部 kill 目标 | `{exit,killed}`，保留已发布前缀；证明根 DOWN | 已终止 PID 的完整前缀，**并非完整用例**；通常为不完整，而非空 F |
| 超时 | `{timeout,T}`，状态可能 ok；保留实际 kill/DOWN 前的 hook | 截止截断不能视为完整 x；单独保留诊断前缀，主序列标为不完整 |
| 完成/超时竞争 | Result + DOWN 及时到达则 Outcome；否则超时优先；迟到消息留在退出中的协调器 | 检查终止来源，不按时长或是否命中猜测 |
| 调用方死亡/活动取消 | 协调器杀死并排空目标、关闭表，不返回快照（`cancelled -> ok`，executor:44） | 缺失/取消槽位；不完整。调用方/worker DOWN 不能代替协调器 DOWN |
| `efz:await(Timeout)` 到期 | 这是 `gen_server:call` 超时；活动继续 | 不能当作目标取消；需要独立显式 cancel/stop |
| Worker 被杀 | Fuzzer 返回 `status={infrastructure_failure,{worker_down,killed}}`；报告无快照；协调器异步清理目标 | 不完整；不能从 infrastructure_failures 为零推断成功 |
| 协调器被杀 | `run/4` 返回基础设施 `coordinator_down`、`coverage=[]`、错误状态和空 builds；表消失，目标可能存活 | 缺失，VM 状态脏/未知；停止序列，未证明清理前不复用 VM |
| 后端/计划/验证失败 | 基础设施错误，有时有诊断命中；普通异常时协调器执行 finally | 不是空 F 或目标缺陷；带原因的不完整/不可比较序列 |
| 结果后协调器异常 DOWN | `cleanup_failed` 替换 outcome/status（`run/4:15–18`） | 清理确认前只作诊断，不自动接纳 |
| 节点/VM 崩溃 | 同一 VM 中的控制器也丢失；没有结果 | 丢失序列为不完整；单独记录外部退出状态；不能用缺失文件构造 U |

在**外部诊断 VM** 调用 `halt(23)`，已确认退出状态为 23，且无结果/快照文件。这是 VM 丢失对照，不是 NIF 段错误测试。EFZ 无分布式 runner，也无独立 `nodedown` 分支。

`kill_and_drain` 有意等待真实 DOWN，而非任意延时后宣告清理。但没有第二计时器限制该等待：永不返回的 NIF 可能要求从外部终止 VM。未测试这种 NIF。单个目标 PID 死亡不等于共享/应用状态已清理。没有可靠 reset/清理时，未来收集器必须以 `requires_fresh_vm` 停止序列，不能继续并宣称计数可靠。

## 3. 精确特征空间与可比性

**C/E。** 自动反馈单位：`{Module, BuildId_SHA256, ProbeId_integer}`——**源码级子句/结果探针是否存在**。两个后端的 ETS `set` 中行均为 `{{probe,Id}}`：

* `ets`：每次命中插入同一行（`efz_cov_rt:hit/1:20–26`）。
* `ets_member`：先检查成员，缺失时插入同一行（`hit/1:8–19`）。重复写不增加任何值。
* `manual`：通过 `efz_cov:hit/1:38–39` 使用独立 `{manual,Id}` 空间，共用两种 ETS 存储方式。这是兼容 API；调用方必须保证任意用户 ID 稳定。自动/手动空间不混合。

没有计数器、桶、CFG 边、值特征、转移序列或哈希位图。因为无计数器，所以不存在计数溢出。精确 ETS 键比较完整项，不是小哈希。Build 的 SHA-256 命名空间不从数学上保证绝无碰撞，但实现没有有意的位图/索引碰撞。没有本地缓存，因此不会因缓存丢失重复发布。实验中同一位置 1 次和 100 次命中在两个后端都得到相同单元素 F。因此这里 `feature_stability` 等于位置存在性的稳定度，无需重复指标或桶。

`efz_cov:snapshot/1` 返回**全部已出现 ID 的排序列表**，不是计数、哈希或差量。之后 `efz_feedback:evaluate/3:10–17` 才算 `Observed - Global`。`Result.coverage`、`Report.coverage`、`Decision.new_probes` 不同：最后一个是保留差量，报告覆盖为成功执行的并集。普通报告不保存成功/拒绝执行的完整快照；崩溃结果保留自己的完整覆盖。旧报告无法恢复缺失的 F_r。需要通过 `run/4` 重执行，或未来在反馈前观察；不能声称可从 SHA/count/new_probes 重建。

**C/E。** 每次输入变化都新建空表，而非清共享位图。相同探针 ID 下的重复/并发上下文隔离已验证。不可变上下文契约下，返回/异常保留根进程全部已完成发布。kill/timeout 时只包括进程终止前发布的命中，不包括未中断时可能执行的全部分支。kill 打断的插入不能算已观察到未完成命中。快照可完整保存，但用例完整性是另一问题。

**C。** 身份由 `efz_instrument_pt:parse_transform/2:35–53`、`probe/4:114–121` 定义：对 `{instrumentation_version, OTP release, compiler MD5, canonical preprocessed forms, relevant compiler options}` 求 SHA-256，再附确定性 AST 顺序索引。Manifest schema/instrumentation version = 1，metric = `clause_outcome_probe`。探针映射包含 M/F/arity/kind/path/file/line/column。相对根路径规范化；绝对路径敏感的字面量可改变 build。没有独立原生布局或 feedback_epoch。整个 ETF map 任意哈希未经规范化不能成为可移植 digest：map 序列化顺序不提供该契约。

`efz_instrument:preflight/1`、`load/1`、`loaded_manifest/2` 第 94–142 行检查 BEAM、解码 sidecar、manifest 和已加载模块属性。Sidecar 按项精确比较，不按字节（`matching_sidecar/2:111–113`）。现有逆序 map/新 VM 测试再次通过。三个新 VM 对同一产物返回**完全相同的完整 ID**、相同 build map，S=100%；验证比较 ID 列表，不仅计数或 digest。

预检后的热替换不受持续监控。诊断中，控制加载同模块的**普通**版本后，旧有效计划给出 `coverage_status=ok, coverage=[]` 和旧 build map。再次显式预检则拒绝 `loaded_module_identity_mismatch`。验证器能发现发布新 ID 的新插桩构建，却不能据此发现无探针代码替换。生命周期契约要求所选构建及 harness 不变。更换 build/manifest 必须新建计划和序列；不宣称支持任意热加载。

**C/E。** 准备好的计划为 `{efz_cov_plan,1,Tid,BuildMap}`。`prepare/2:51–68` 验证 manifest schema、插桩版本、唯一性、自动模式选择非空和模块不重复；创建受保护 ETS 标记 `{'$efz_plan',{Mode,Bs}}` 及精确允许身份。它**不能替代预检**，不含输入、execution Ref、RNG 或累计覆盖。Worker 持有到 stop，包括 `await` 完成后。所有者存活时，低层 API 允许其他调用方读取；禁止写别人的受保护计划。所有读者结束后由所有者释放，所有者死亡自动删表。

每次执行验证标记、模式、builds 及所有观测 ID；空 F 也检查标记（`validate_prepared/3:72–85`）。已释放计划、错误模式或替换 build map 不能成为成功空快照。其他元组版本还可能在 `builds/1:70` 失败，产生 coordinator_down 基础设施错误。现有负向/生命周期测试覆盖这些情况，包括执行中计划所有者死亡。计划与后端无关，但实验配置仍需记录存储后端及验证策略，因为时间开销不同。

## 4. feature_stability 的适用性与接纳规则

**P。** 这是 EFZ 自有指标，不是 libFuzzer 标准公式，也不等同 AFL++ 稳定性数值。规范化 v1 为**完整**探针身份的去重与规范排序；不屏蔽位置/计数器，也不排除仅崩溃出现的 ID。相同 x、固定状态契约、R >= 2 时：

```text
frequency_x(f) = number of measured repeats where f appeared at least once
U_x = union of all F_r(x)
I_x = { f in U_x | frequency_x(f) == R }
V_x = U_x \ I_x
S(x) = feature_stability = 100 * |I_x| / |U_x|
S_C = 100 * sum_x |I_x| / sum_x |U_x|
```

单个 F 内重复命中不增加频率。不需要参考运行。若要统计完全相同运行的比例，应另设指标并明确参考，不能替代 S。精确比较阈值时保留分子/分母，以整数乘积比较；仅显示时四舍五入。

**E。** 仅四个探针的诊断目标对一个输入产生：

```text
F1={a,b,c}; F2={a,b,d}; F3={a,b,c}
frequency={a:3,b:3,c:2,d:1}; I={a,b}; U={a,b,c,d}; V={c,d}; S=50%
```

所有集合大小均为三。第二个输入反向交替也有 S=50%；正确 corpus 汇总为 50%。若每轮先合并两个输入，就三次得到 `{a,b,c,d}`，虚假达到 100%。这由断言验证，并非看日志相似度推断。

**P。** 单输入结果状态机：

| 条件 | 状态 / 值 |
|---|---|
| 请求 R < 2 | N/A `insufficient_repeats`；不是 100 |
| 全部 R 可靠且可比，U 非空 | `complete`，有 S 和完整频率 |
| 全部 R 可靠，U 空 | N/A `empty_feature_union`；另行区分空字节和空快照 |
| 快照缺失、基础设施错误、静止/reset/清理未确认、取消、所有者/VM 丢失、用例中断 | `incomplete`，无主 S |
| Build/manifest/schema/范围改变或 ID 不可比 | `incomparable`，无主 S；不自动转到另一命名空间 |
| 只有 k<R 次可靠重复 | `incomplete`；实际 k>=2 时可另显示诊断 S，但不自动接纳 |
| 完整终止的 error/throw/捕获 exit 或正常 invalid 返回 | 可参与稳定性；单独记录 outcome，不仅按类别排除 |

可比性假设不干扰插桩拥有的状态。单凭状态 ok 不能对抗恶意目标证明这一点。若发现干扰或代码改变，无论是否剩余非空相同命中子集，序列均无效或不完整。

对固定 C，应预先冻结内容身份、顺序/排列和重复协议。汇总加权对象是**输入–特征对**，不是整个 corpus 的唯一特征。除 S_C，还需每个 x 的行、min S(x)、不稳定输入数（`|V_x|>0`）、`selected_entries`、`unique_inputs`、`measured`、`scored`、`empty`、`incomplete`、`incomparable` 及其输入 ID。该控制指标需把字节完全相同的重复项明确映射为同一 x；不能删除/改变原始种子、顺序/状态或正常校准计数。

Corpus 不完整时，主汇总应为 incomplete/incomparable，不能称“全部稳定”。允许独立 `complete_subset` 汇总，但需列出准确 x 和分母。完整空 x 对求和贡献为零，同时保留显式 N/A 行，不能变成“已验证 100%”。总分母为零则 S_C=N/A。不能静默排除失败或缺失重复、替为空集，或不断重试直到凑出合适 R。故障后的新一致运行是带新诊断任务 ID 的新序列。

主 outcome 比较另行提议：精确返回值或异常类/原因；目标 stack 作为证据，不作特征。易变 PID/ref/port/fun 值不能宣称跨 VM 可移植相同。单独记录 outcome 变化/不可比，不破坏原结果。F 完全相同不证明执行顺序相同、outcome 相同或没有缺陷。

若将来反馈变成 `{site,bucket}`，桶变化可为同一位置生成多个不稳定特征；这不同于稳定 AFL++ 单元数。当前无此后端。只有反馈确实变化时才引入第二 schema 和独立位置存在指标，本审计不需要。

拟议可配置内部参考：目标 **100%**，`S < 95%` 时警告，`S < 90%` 时深入调查；高于 95% 的可变 x 仍需可见。这是项目初始阈值，不是行业标准或正确性证明。不完整数据不能通过阈值。更大 R 增加发现变化的概率；比较百分比要求 R、C、特征 schema、builds/manifest 及执行/reset/warmup 模式固定。

## 5. BEAM 隔离与可重复协议

| 模式 | 已确认内容 / 未来运行必须记录的内容 |
|---|---|
| 通过普通 `run/4` 重复 x | 目标 PD/邮箱、上下文全新；主调度器 16；包含首调用。确定性夹具的完整 F 相同，S=100 |
| A→B→A、固定排列 | 独立 `only_a`/`only_b` 不相交，两次 A 相同；排列得到相同输入→F 映射 |
| 控制破坏独立性 | `state_b` 改变 `persistent_term`；前后 A 产生 c/d，S=0。夹具显式 reset 恢复 A。这是共享 VM 状态，不是 ETS 隔离故障 |
| 每个 x 一个新 VM | 三个独立 VM，同一产物/manifest/ID，S=100；常规 16 调度器。是控制模式，不是操作系统隔离保证 |
| 计划预热 | 本审计 W=0，未丢弃首调用。未来 W/预热序列是协议/键的明确部分；预热失败也计入 |

第一个 ETS 实验的 `elapsed_us=[919,10,7]`，随后 ets_member 从 `[15,12,11]` 开始；F 相同。第二组已在热 VM 中运行，所以**不是后端性能比较**。这些值说明不能静默排除首调用或混合冷/稳态模式。未在真实库上测量完整预热/稳定性。

**E。** 目标局部 `put`、邮箱消息和隐式 rand 状态不传到下一个新目标。但执行器不重置共享 ETS、注册服务、persistent_term 或应用状态。测试中，已运行的 gen_server、同步 OTP 回调、计时器消息都在无附加上下文时调用插桩位置：子进程/后台 hook 不活跃。根正常返回后，`spawn`、`spawn_link`、`spawn_monitor` 的子进程仍存活；父链接或监视器都不保证整树终止。子进程释放/ACK 均显式完成，不靠 sleep。计时器/消息不携带进程字典；接收者决定执行进程。现有 OTP 服务不自动获得上下文。

目标若有意带状态，x 必须包括初始状态、配置和动作序列。不同预期状态后的 `state_a` 不能表示为同一场景 x。当前 EFZ 接受 binary+`run/1`，无场景/reset API。首次最小集成必须明确限制在现有 `fresh_target_process / unreset_shared_vm / root_probe_scope` 及约定的 harness 独立性内，不能称为通用 OTP 应用重置。

未验证边界：他人所有的任意 ETS、注册表/全局状态、共享应用、文件/端口、非受控计时器/后台 actor、分布式节点状态和共享原生资源。新 VM 隔离自身进程状态，但不保证外部 OS 资源重置。上下文 Ref、公共 ETS、准备好的计划都不是安全边界。同 VM 目标可改变 runtime、杀协调器或破坏插桩状态。部分干扰已归基础设施失败；没有完整保护或脏 worker 检测器。

## 6. 运行与证据矩阵

所有命令在 `efz/` 运行。构建参数为当前 rebar.config；诊断模块使用 `debug_info,warnings_as_errors` 编译，无新依赖；只允许 `audit_sites`。其四个探针为 `a/0:3`、`b/0:4`、`c/0:5`、`d/0:6`（列 1），build 为 `68bd7a9201c0be5e43ed13f5850558fcefe6e07493252a66204f7fe36fc7e809`。适配器/后台夹具有意不插桩，避免共享控制分支污染指定 a/b/c/d 集合。也检查了正常生产示例，而非用特殊探针空间替代。

| 命令 | 新结果 | 日志 |
|---|---|---|
| `rebar3 compile` | exit 0 | [compile.log](/tmp/efz-calibration-audit.rIBEql/compile.log) |
| `rebar3 eunit` | exit 0，**62 项通过** | [eunit.log](/tmp/efz-calibration-audit.rIBEql/eunit.log) |
| `rebar3 ct` | exit 0，**3 项通过** | [ct.log](/tmp/efz-calibration-audit.rIBEql/ct.log) |
| `escript /tmp/efz-calibration-audit.rIBEql/audit.escript /tmp/efz-calibration-audit.rIBEql` | exit 0，**54 条证据记录**，全部断言通过 | [diagnostic.log](/tmp/efz-calibration-audit.rIBEql/diagnostic.log) |
| `escript /tmp/efz-calibration-audit.rIBEql/existing_example.escript /tmp/efz-calibration-audit.rIBEql` | exit 0；`efz_example_target` 使用 `<<0>>` 和 `<<255>>`，各 R=3，F 精确相同，S=100；未排除异常 | [existing-example.log](/tmp/efz-calibration-audit.rIBEql/existing-example.log) |

新颖性判断前的完整诊断结果（含精确 ID、元数据）位于 [events.term](/tmp/efz-calibration-audit.rIBEql/events.term)、[events.txt](/tmp/efz-calibration-audit.rIBEql/events.txt)。断言比较规范集合，不仅大小。日志/脚本是临时的；本表和嵌入源码是永久可复现记录。首个试验脚本曾因浮点模式 `0.0` 收到 OTP 警告，仅在临时脚本改为 `+0.0`，最终实验成功重跑。旧临时结果以 `first` 后缀保留；结论使用最终运行。

最终证据 SHA-256：`eunit.log`——`1aaf27c24e7f320e7b331d2f9e7f06dea647981627050cd53aba37c513fe8a3e`，`diagnostic.log`——`b4bc09d285bd1681b13ffbd7f4a61233ccef6ace37af8dfabf7dc32ddac3ba66`，`events.term`——`fc7773394e458dedd9f742b80c5b0d9f7c44913add1e48d79146d9e8a2ea37c9`。随后**使用附录自身命令**提取嵌入源码到 `/tmp/efz-calibration-reproduce.5h0yayqu`；两个诊断 escript 再次 exit 0。这验证命令可复现，不是可混入百分比/时间的新样本。见[复现检查](/tmp/efz-calibration-audit.rIBEql/report-reproduction.txt)。

| 要求 / 实验 | 当前实现与证据 | 缺口 / 最小改动 |
|---|---|---|
| 确定性 x，R=3 | 两后端均 abc 三次，S=100；`{B,deterministic}` | 公开指标需独立收集器 |
| 等大小不同集合 / 已知交替 | abc/abd/abc，频率 3/3/2/1，S=50；`{B,alternation}` | 按身份计算，不按 count/hash |
| Corpus 汇总 | 两个反向 x：正确 50，折叠后 100 | 分别保留 `(x,feature)` 频率 |
| 不同重数 | a 位置 1 和 100 次命中 → 单探针；`{B,multiplicity}` | 不引入计数器/桶 |
| A→B→A/排列 | a/b 不交，两次 A 相同；`{B,aba}` | 冻结顺序/reset 契约 |
| 共享状态 | persistent_term 改变 A；夹具 reset 可恢复 | 无通用目标 reset；进程不等于新 VM |
| 延迟子进程 | 三种 spawn 均不活跃，下一根集合干净；显式复制的子进程在 close 后遇无效表 | 不支持树静止/覆盖；明确仅根范围 |
| 已存在 OTP 服务/计时器 | 后台 hook 不活跃；根快照只有 a | OTP 应用范围需未来独立 runner，不属本集成 |
| 并发上下文、相同 ID | Ref/Tid 不同，均精确 `{a}`；返回后无表 | 不能由此推断生产多 worker 支持 |
| Error/throw/exit | 都保留 a，状态 ok；`{B,exceptions}` | 终止异常可计入；需 exit 来源 |
| 外部 kill / timeout | a 后 ACK，再 kill 或截止；保留 a，目标/所有者 DOWN | 只有前缀，缺完整用例 |
| 完成/截止竞争 | 现有 `efz_backend_tests:boundary/1:188–198` 和 Phase 2 测试通过 | 用终止来源元数据，不猜测 |
| 调用方/cancel/shutdown | 四组合的 `caller_death/1`、`cancel/1:179–210` 通过；新活动取消证明 await != cancel | 无取消快照；清理相对调用方死亡异步 |
| 空输入/快照 | `<<>>` 返回 invalid 与独立空路径可区分；两空序列均 N/A | 不把错误/缺失混为空有效 |
| Worker 崩溃 | 基础设施状态，报告无快照，stats infra=0；`worker_kill` | 观察者须读状态；需明确遥测 |
| 协调器崩溃 | kill 前的 a 随表丢失；根存活，由 harness 杀死 | 不完整 + 脏；清理保护或禁止复用/销毁 VM |
| Prepared 所有权/dispose/foreign | `efz_backend_tests:plan_lifetime/1:128–166` 通过；两后端释放计划 + 空都给基础设施失败 | 读者结束前所有者存活；执行中不可释放 |
| Manifest/sidecar 缺失或不符 | EUnit 预检负向测试、`efz_phase2_tests:sidecar_encoding/0:229–253` 通过 | 离线 API 须预检，原始 run/4 不做 |
| 同 build、新 VM | 三新 VM 接受同 sidecar，返回精确 abc 和相同 builds | 命名空间变更为不可比，不能合并 |
| VM 丢失 | 外部 helper 退出 23；无快照文件 | 无现成原生 runner；外部任务须标记缺失 |
| 活跃快照 / Ref | 静止前 a、后 ab；同 Tid 下改 Ref 被接受 | 不直接取快照；Ref 仅关联，不是代际/安全保护 |
| 活跃状态损坏 | 无效表被捕获仍有 sticky 基础设施失败；目标捕获畸形 PD 得到 ok+空 | 见 F4；不能只信状态 ok |
| 普通热替换 | 旧计划接受空；显式预检拒绝加载身份 | 固定 builds，并在支持的序列边界检查 |

现有 EUnit 覆盖 transform 语义、同一行/嵌套语法、异常类别/原因、尾位置、插桩身份、后端/验证器的规范 outcome/新颖性、cancel/shutdown 及重复资源释放。日志中预期的畸形计划错误是负向测试，不是构建失败。`efz_backend_tests:variants/0:21` 实际覆盖两存储实现与两验证器。旧报告 38/3 不作新结果；本次为 62/3。

**NV。** 本次未重跑 Dialyzer/xref：没有生产改动、要求该 gate 的适用指令，或必须以新静态分析而非已审运行时测试回答的问题。旧 PASS 不作本次结果。未测试 Phase 2.1 profiling/soak、Cowboy（缺依赖/harness）、任意外部目标、原生/NIF 覆盖 reset/静止、NIF 段错误、分布式 nodedown 或穷尽 OTP 资源隔离。a/b/c/d 测试不能解决这些边界。

## 7. 优先级发现

### F1 — P1：outcome/状态不能确定完整性或终止来源

**C/E。** `efz_executor:coordinate/6:35–38`、`wait_target/5:64–79`、`coverage/3:89–104`。捕获 `exit(killed)` 与外部 kill 的 outcome、target_outcome、coverage_status、coverage、builds **完全相同**，仅偶然 Ref/时间不同。Timeout 也可状态 ok 且 F 非空。把它当作完整重复的充分条件，会让中断执行虚假稳定。

**P。最低要求：**增加终止来源、范围、静止、快照、清理元数据，不重命名已有 outcome 元组。由执行器实际分支推导，不依赖 Reason 启发式。序列验证器接受被捕获的终止异常，不接受截止或 monitor-exit 中断用例。**验收：**相同公开 `{exit,killed}` 按来源可区分；指标中前缀/缺失绝不变成完整/空。

### F2 — P1：协调器不可捕获死亡会遗留不受支持的活目标

**C/E。** 目标由 `spawn_monitor` 创建，无可在所有者死亡后存活的清理保护（`coordinate/6:31–41`）。杀协调器跳过 `after:55–60`，`run/4:20–23` 返回基础设施错误，但测试目标仍活着。诊断 harness 监视并杀死这个确切目标，再等待 DOWN；不动无关进程。

**P。指标的最低要求：**中止序列、快照记缺失，清理未确认时 `requires_fresh_vm`；不在脏 VM 中运行后续 x。若要故障后复用，需独立存活的 guardian/受跟踪目标清理及真实 DOWN 的 ACK。目标有 `trap_exit` 时简单 link 不够，sleep 不是修复。不能为速度改 outcome 或加计数器。**验收：**强杀所有者绝不生成得分；仅证明受跟踪写入者停止或换新外部 VM 后才继续。

### F3 — P1：计划不能证明执行代码未改变

**C/E。** `efz_cov_manifest:validate_prepared/3:72–85` 将观测 ID 与标记比较，不与已加载代码比较。`efz_instrument:loaded_manifest/2:124–127` 仅预检时检查实际加载属性。普通热替换产生带旧 build map 的有效空快照。完整 result.builds 来自选项/计划，不来自跟踪。

**P。最低要求：**整个序列期间固定所选模块**和目标适配器**；入口预检，在约定边界记录/检查所选已加载身份，build/manifest/harness 变化即失效。这不防止执行中更改代码后又恢复；不能承诺任意热加载。**验收：**边界不兼容即拒绝；新 build 是新序列，不是子集合并；固定不变 build 可安全复用计划。

### F4 — P1（运行时契约违规）：被捕获的畸形上下文丢失

**C/E。** `efz_cov_rt:hit/1:16–27`：坏表发送 sticky 通知，最后无效上下文分支只抛异常。夹具替换 PD 上下文并捕获异常；执行器返回 `{ok,caught}`、状态 ok 和空覆盖。RunRef 不保护插桩状态免受目标更改。

**P。最低要求：**支持的 harness 明确禁止改插桩状态；完成前由 wrapper 检查原上下文，失败关闭并诊断。仅“退出时”检查不能防有意替换/恢复。敌对目标需要其他安全/隔离边界，不是校准承诺。**验收：**捕获错误后仍损坏/擦除的上下文应为基础设施/不完整；普通不测量子进程中无 attach 的 runtime 仍允许是不活跃 no-op。

### F5 — P1（集成）：不能把活动报告数据当作 F_r

**C。** `efz_worker:execute/4:60–82`、`finish/2:115–118`、`efz_feedback:evaluate/3:10–20`。成功快照进入全局合并，不作为每次运行报告保留。崩溃的 `new_probes=[]` 是保留策略，不是没有执行特征。

**P。最低要求：**收集器在新颖性前保存完整结果，或通过同一 run/4 独立重跑已选字节。不能每次重复都调用 `feedback:evaluate/3`。**验收：**相同重复序列不产生多个 NEW、不改 corpus/RNG/游标，也不把崩溃独有特征并入全局。

### F6 — P2：worker 丢失和源故障的遥测表述不够清晰

**C/E。** `efz_fuzzer:handle_info/2:34–39` 返回 worker_down 基础设施错误，却不增 infrastructure_failures；实际计数为 0。**C：**`efz_feedback:evaluate/3:6–7,22` 先要求 build 相同；builds=#{} 的 coordinator_down 可变成 `instrumentation_build_mismatch`，遮盖原始基础设施原因，尽管不归类目标缺陷。

**P。最低要求：**按结构化结果/状态判断稳定性，不看汇总计数。保留首因；未来统计改变应对 worker 失败恰计一次。**验收：**丢失运行仍缺失，校准行可见真实原因；不得将 infra=0 宣称完整性的证明。

### F7 — P2 / 范围：根隔离不等于用例独立

**C/E。** 执行器无 reset/子进程登记；persistent_term 与延迟子进程实验证明边界。直接 `snapshot/1` 和 Ref 替换不证明静止。**P：**记录仅根/未 reset VM 模式；做 A→B→A、固定排列诊断；不一致有状态场景是不支持，而非自动频率清零。**验收：**测量已知契约，不删不稳定种子或屏蔽探针以抬高百分比。

## 8. 最小集成设计——仅为提议

### API 边界与所有者

**P，并非已有 API：**

```erlang
%% Complete offline control corpus, without mutator or feedback side effects.
efz_calibration:run(Target, Entries, Artifacts, Options)
    -> {ok, CalibrationReport} | {error, ConfigurationReason}.
%% Pure aggregation, separate from storage/execution.
efz_stability:fold(Accumulator, ValidatedRun).
efz_stability:finalize(Accumulator, RequestedR).
```

建议选项：`repeats`（R>=2，初始受限 opt-in 示例 R=5）、timeout、后端/验证策略、`mode=fresh_target_process`、`scope=target_process`、`warmup=0`、协议/顺序/reset 契约身份、输入/R/总墙钟预算限制及输出轨迹/见证预算。超过特征上限必须将输入记为不完整，不可截断集合。启用功能不能引入无限重试。首版不把任意有状态场景当二进制输入；新 VM 为显式选择的独立辅助模式。

发起者接收固定字节/身份集和显式 Target/Artifacts，与当前 replay 相同。`efz_config`/`efz_instrument` 验证选择；不允许结果文件指定任意可调用目标。解码/配方重建在序列前仅一次；每次测量接收**相同字节**，不是另一次变异。不替换低层执行器。

建议所有权方案：

* 任务控制器/调用方拥有冻结 corpus、兼容键和聚合器；接收每个计划运行索引的受限进度。
* 单个校准收集器进程拥有准备计划，顺序调用 `efz_executor:run/4`，不并发生产 fuzz worker。计划在预检后创建，所有 run/4 完成前存活，由所有者在 `after` 释放。每次执行的上下文、ETS、监视器仍归已有协调器。父 JobRef/PID 只关联，不作持久缓存键。
* run/4 返回后，即协调器 DOWN/清理完成后，收集器发送不可变完整 RunResult 给控制器。控制器用完整快照而非决策差量，对槽位内每个特征频率恰增一次。
* 离线取消初期为 **run/4 调用之间协作取消**：等当前调用完成，不先释放计划，然后不启动下一槽。剩余槽取消/not_run，结果不完整。不承诺立即取消挂起 NIF。收集器监视发起者，下一次运行前检查 stop/死亡。
* 强制收集器/所有者死亡时，控制器保留已收槽位，其余缺失；遵守现有清理保证，静止未证实时必须换 VM。收集器 DOWN 不能当全部资源 ACK。若立即取消后仍在同 VM 继续，需要显式执行器清理观察者/guardian；这是已有协议的独立增量扩展，不是第二执行器。

**P：**扩展现有 `run/4` 元数据，保留 outcome/coverage 字段及旧 `run/3` wrapper。建议结构（名称尚未实现）：

```erlang
#{termination_origin => returned | caught_error | caught_throw | caught_exit |
                         monitor_exit | deadline | caller_cancel | coordinator_loss,
  coverage_scope => target_process,
  writers_stopped => confirmed | unknown,
  snapshot_status => full_scope | terminated_prefix | missing | invalid,
  cleanup_status => complete | failed | unknown}.
```

`full_scope` 仅限根及遵守插桩契约，不是“整个 OTP 应用”。字段由执行器分支填写；校准接纳另验 builds、范围、reset 契约、终止来源和 coverage_status。仅在当前调用方仍等待 DOWN 时允许 finally 前发结果；清理元数据要反映该屏障结果，不可提前设定。没有显式观察者前，未返回结果的取消仍算缺失。Epoch 不能替代静止。

### 结果 schema 与失效键

**P：**添加独立版本化 `calibration` 报告/索引；不重命名已有 corpus、配方、崩溃元组、决策或计数。每个 x 保存：

```erlang
#{schema_version => 1, compatibility_key => Key,
  input_id => SHA256, input_size => N, corpus_ids => [...],
  requested_repeats => R, attempted => A, trusted_repeats => K,
  status => complete | incomplete | incomparable | not_applicable,
  reason => Reason, union_size => UCount, intersection_size => ICount,
  variable_features => [...], frequencies => [{ExactFeature, PresenceFrequency}],
  feature_stability => NumberOrUndefined,
  outcomes => BoundedOutcomeSummaries, outcome_changes => Changes,
  runs => BoundedRunMetadata, witness_inputs => References,
  timing => #{startup_us => ..., repetitions_us => ..., aggregation_us => ...}}.
```

还包括 corpus 汇总、最小 S、不稳定数、selected/measured/incomplete 及精确 ID 列表。不能无限保留每个拒绝配方/快照。频率足以计算 I/U/V，原始快照/见证是受限可选项。输入字节必须仍能从 corpus 或打包副本通过 hash/长度验证；重复现成二进制不需 donor/RNG 状态。

**P。** `Key = SHA256(canonical versioned structure)`，必含以下成分；绝不能把非规范 map 序列化后称为“可移植键”：

| 成分 | 实际基础 / 规则 |
|---|---|
| 输入/场景 | **字节 + 长度**的 SHA-256，验证打包字节；未来场景需初始状态/config/动作 digest，不是单条消息 |
| 目标/harness | 显式 `{Module,run,1}`，实际加载适配器/普通 harness BEAM 身份（匹配代码 MD5/对象 digest），harness/reset 契约版本；单凭 selected BuildMap 不覆盖适配器 |
| 所选代码 | 排序的 `{module-name-binary, BuildId, canonical manifest digest}`；schema/插桩版本、限制、toolchain |
| 特征语义 | `clause_outcome_probe / exact_presence / normalization_v1 / target_process`；活跃 EFZ runtime/执行器/验证器版本/代码 digest；manual 独立 namespace 和显式 ID 契约 |
| 兼容 epoch | 所列 schema/语义的新可移植 digest 提议；**当前无 feedback_epoch**；策略/schema 变化要求新序列 |
| 执行设置 | Timeout、后端实现、验证策略、OTP/ERTS/架构、调度器、目标配置、协议/reset；即便特征可比也影响环境/负载 |
| 试验协议 | R、预热次数/输入、冷/稳态策略、连续/按 corpus 轮次/固定排列/新 VM；依赖顺序实验的控制 corpus/顺序 digest |
| Outcome 策略 | Outcome 规范化版本，不静默丢弃返回变化/易变值 |

`ets` 与 `ets_member` 特征语义相同且 F 可比，但结果缓存不能在不同计时/配置变体间静默复用。`execution_ref`、PID、Tid、单调时间和父队列索引不是可移植身份。重建冻结 x 不需选择/变异种子；若种子定义控制 corpus/顺序，则保留其身份及来源。准备描述符不能持久化为可复用产物；新 VM 创建新计划。

这是**实验兼容性**键，不证明未知共享 VM 内容相同。未 reset 模式下应禁止仅按此键跨任务自动缓存复用。相同兼容键下保存独立观测序列；不拼接重复形成新 R，也不以旧“100%”代替新运行。只有另行确认初始状态/reset 契约和新鲜度策略才可复用。任务 ID/时间区分记录，但不成为输入/特征身份。

当前格式为 Erlang 报告 map/`term_to_binary` 和 escript pretty-print；EFZR 是某个具体变异配方格式，不是校准数据库。最小新 CLI `scripts/calibrate.escript` 可调提议 API，保存独立版本化 `.term` 报告。项目没有 JSON API/编码器，不应为此加依赖。未来若需要 JSON，二进制 ID 输出 hex，未定义分数输出 null + 原因，省略 runtime handle；schema 与报告 map 等价。这是导出提议，不是现有功能。

### 发起方式、新颖性与恰好一次记录

**P。** 实施顺序：先离线冻结 corpus；再于活动启动、新 interesting 输入后和显式 corpus 快照检查时，提供 opt-in 仅报告发起点。build/manifest/schema 变化令结果**失效**并需重新准备；当前活动不支持在线热加载。

离线路径不调 `efz_feedback:evaluate/3`、`efz_corpus:add/2`、选择器/变异器，也不重置统计。活动内在 `efz_worker:execute/4` 第 60 行后立即捕获原完整 RunResult，作为 R 次中的首个，再观测重复同字节 R−1 次。独立队列不推进 staged 游标、RNG、变异迭代，也不改父/配方。原反馈/保留按原顺序**仅对原结果调用恰一次**；校准观测不并入 Global。

初始种子仍为基线条目，原 `seed_calibration` 首遍不变，不成为变异发现。功能禁用时历史 baseline/候选流保留契约。额外执行必然改变时间/VM 副作用；无 reset 的目标在插入后是否独立需检查，不能承诺相同活动流。

通过内容/键的独立 `Report.calibration` 索引附加重复结果。当前 `efz_corpus:add/2` 不更新已有输入元数据，不能滥用重插。首版无须新 corpus 更新 API。原输入/元数据/added_at/配方及发现数不变。没有独立 scorer 或最后新覆盖时间；不能意外引入，也不能为稳定性检查重置 `stats.started_at`。

以来源 `stability`、原始输入和实际结果保存 outcome 变化、新校准崩溃见证；不能因 S 低丢弃发现，也不算变异发现。可用现有崩溃存储保存见证字节/结果，加元数据和独立重复计数。崩溃独有探针仍不抑制未来成功新颖性。

将来若**另行**决定只用稳定反馈搜索，需要延迟单事务 `G_before + original result + series + compatibility epoch -> one commit`。R 次 evaluate 或 merge(U) 不能提供此保证，U 可能含崩溃独有/可变特征。这类保留和调度改变需独立 ADR/测试，不属仅报告阶段。不提议自动删不稳定种子、屏蔽探针、抑制崩溃或重评基线状态。

### 成本与独立统计

**P，复杂度估算而非新基准：**离线处理 N 个唯一输入需 `N*R` 次测量执行（另加显式预热）。若复用原种子/候选结果，第一次已完成，每输入追加 `R−1`。估算不需重测 Phase 2.1 后端吞吐。

设 P 为 manifest 探针数，H_r 为每次唯一命中数，T_r 为 hook 调用数。计划一次准备占 O(P)；发布依赖 T_r。`tab2list` 为 O(H_r)，排序 O(H_r log H_r)，prepared 验证对 H_r 查成员；per_execution 每次另建 O(P) 允许集合。哈希频率聚合期望 O(sum H_r)、内存 O(|U_x|)，最终排序输出。保留所有原始 F 需 O(sum H_r)，所以受限可选；频率不需每集合 R 份。快照/结果复制、ETF 序列化也与数据成比例，须与目标时间分测。

诊断中四探针计划占 5 行 ETS（4 + 标记），两后端均 3,128 字节。这仅为一个活计划，**不是峰值或活动总内存**。实验后无覆盖/计划表。故意杀协调器造成的孤儿目标由**诊断 harness** 清理，并非引擎自动；不能用最终“无泄漏”掩盖。生命周期测试另证 caller/cancel/shutdown 的正常清理。

建议新增计数：`stability_attempts`、`stability_completed`、`stability_missing`、`stability_target_failures`、`stability_infra_failures`。重复不增 `stats.executions`/`discoveries`/`rejections`；保留 `calibrations` 作为初始种子遍计数以兼容。墙钟新增 `stability_us`、`stability_in_mutation_us`、`mutation_active_us = existing mutation_us - stability_in_mutation_us`。原 `mutation_us` 可继续为原阶段墙钟；新吞吐使用**变异执行数 / mutation_active_us**，分子不计 R 次重复。启动/种子、聚合、序列化、新 VM 启动分报。功能禁用时原时间/计数/流不变。

## 9. 实施计划与验收标准

以下所有改动均为**提议**，当前代码尚无。

| 阶段 | 文件/依赖 | 就绪标准 | 禁用与兼容 |
|---|---|---|---|
| 1. 前置条件 | `src/efz_executor.erl`，保护 `src/efz_cov_rt.erl`；`test/efz_backend_tests.erl`、新定向案例 | 终止来源区分捕获 exit 与 kill；不承诺完整树；所有者丢失中止/脏；捕获坏上下文失败关闭；原 62/3 保留 | 保留 outcome 元组/run/3；不改默认后端/worker |
| 2. 快照接纳契约 | 执行器元数据 + 提议 `src/efz_stability.erl`；复用 manifest/预检 | 根 DOWN 后、存储毁前的完整不可变 F；验范围/build/清理；空 != 缺失，超时前缀 != 完整 | 不替换后端快照代码；原反馈不依赖新观察者 |
| 3. 离线收集器 | 提议 `src/efz_calibration.erl`、`scripts/calibrate.escript`、transform denylist 的内部模块 | 冻结字节、R/状态协议、活计划所有者、同 run/4；版本键；有界取消/限制；无新颖性副作用 | 仅显式独立调用；原活动不使用 |
| 4. 回归套件 | 提议 `test/efz_stability_tests.erl`、校准集成、现有后端/语义测试 | 50% 向量、等大集合、频率与重数、corpus 遮蔽陷阱、R<2/空/不完整/不可比；A→B→A、子范围、新 VM ID；异常/kill/timeout/owner/cancel；破坏/build 不符 | 不定性能阈值，不改旧预期探针/outcome 集 |
| 5. 活动仅报告集成 | `efz_config`、`efz_worker`、`efz_stats`、报告文档；可选索引不重插 corpus | 首结果 + R−1；原反馈恰一次；不推进 RNG/游标；独立时间/计数；不隐瞒见证失败 | **默认 `stability => disabled`**；显式启用，R/95/90 可配置；旧基线无新序列 |
| 6. 报告/测量 | CLI/README/覆盖文档、短固定预算开销实验 | 每输入行、加权 corpus/min/不稳定/子集成员；实际开销、冷暖区分；需要才加 JSON | 保留旧报告/EFZR/CLI；增量版本化章节 |

不能先通过每输入重复 `efz:start` 实现：这把种子初始化混成稳定性、建立独立反馈状态，也不重置整个 VM。不能为好看百分比更改调度计数或目标 rand 种子。主模式保持标准；改 runtime 属另行标注诊断实验。

外部未决问题仅限本 checkout 无法获知的内容：具体真实目标的 reset/warmup/初始状态契约，以及 R/95/90 是否合适。缺 Cowboy harness/依赖，未验证真实 Erlang 应用普遍独立。已明确根范围引擎的所有者、快照、失败路径、初始接入点，无须假定隐藏 Go/OTP 应用 runner。

## 10. 无永久夹具地复现诊断

以下源码仅供审计，不纳入应用或构建配置，也不实现生产校准 API。`audit_sites` 之一使用普通自动插桩编译，其余模块提供受控输入、状态和 ACK。Kill 实验先等已完成探针后的消息，不靠 sleep 证明发布。每个创建的子进程都显式终止，VM 丢失测试只杀自己的外部 helper。

从 `efz/` 根目录运行：

```sh
AUDIT_DIR=$(mktemp -d /tmp/efz-calibration-audit.XXXXXX)
python3 - "$AUDIT_DIR" <<'PY'
from pathlib import Path
import re,sys
text=Path('docs/calibration-readiness.md').read_text()
blocks=re.findall(r'<!-- audit-source: ([a-z_.]+) -->\n```erlang\n(.*?)\n```',text,re.S)
assert {name for name,_ in blocks} == {'audit_sites.erl','audit_target.erl','audit_background.erl','audit.escript','existing_example.escript'}
for name,source in blocks:
    Path(sys.argv[1],name).write_text(source+'\n')
PY
rebar3 compile > "$AUDIT_DIR/compile.log" 2>&1
rebar3 eunit > "$AUDIT_DIR/eunit.log" 2>&1
rebar3 ct > "$AUDIT_DIR/ct.log" 2>&1
escript "$AUDIT_DIR/audit.escript" "$AUDIT_DIR" > "$AUDIT_DIR/diagnostic.log" 2>&1
escript "$AUDIT_DIR/existing_example.escript" "$AUDIT_DIR" > "$AUDIT_DIR/existing-example.log" 2>&1
```

不要静默添加 `+S 4:4`：原主运行和新 VM 控制都用标准配置。检查每命令退出状态；有日志文件本身不证明成功。脚本有意以断言发现所述现有限制；未来修复后须重审预期审计结果，而非把旧脚本当策略测试。

<!-- audit-source: audit_sites.erl -->
```erlang
-module(audit_sites).
-export([a/0,b/0,c/0,d/0]).
a()->a.
b()->b.
c()->c.
d()->d.
```

<!-- audit-source: audit_target.erl -->
```erlang
-module(audit_target).
-export([run/1]).
run(<<"a">>)->audit_sites:a(),audit_sites:b(),audit_sites:c(),ok;
run(<<"b">>)->audit_sites:a(),audit_sites:b(),audit_sites:d(),ok;
run(<<"only_a">>)->audit_sites:a();
run(<<"only_b">>)->audit_sites:b();
run(<<"alternate">>)->
 N=persistent_term:get({?MODULE,alternate},0),persistent_term:put({?MODULE,alternate},N+1),
 case N rem 2 of 0->run(<<"a">>);1->run(<<"b">>) end;
run(<<"state_a">>)->case persistent_term:get({?MODULE,dirty},false) of false->audit_sites:c();true->audit_sites:d() end;
run(<<"state_b">>)->persistent_term:put({?MODULE,dirty},true),audit_sites:b();
run(<<>>)->{error,invalid_input};
run(<<"empty">>)->ok;
run(<<"halt">>)->audit_sites:a(),erlang:halt(23);
run(<<"hold">>)->run({hold,persistent_term:get({?MODULE,observer}),campaign});
run({repeat,N})->lists:foreach(fun(_)->audit_sites:a() end,lists:seq(1,N)),ok;
run({fail,Kind})->audit_sites:a(),case Kind of error->error(artificial);throw->throw(artificial);exit->exit(killed) end;
run({hold,P,Tag})->audit_sites:a(),P!{published,Tag,self(),get('$efz_execution_context')},receive finish->ok end;
run({local_state})->
 Before={get(audit_user_key),process_info(self(),messages),rand:export_seed()},
 put(audit_user_key,dirty),self()!audit_old_message,rand:seed(exsplus,{1,2,3}),audit_sites:a(),Before;
run({child,Kind,P,Copy})->
 audit_sites:a(),C=get('$efz_execution_context'),
 F=fun()->Before=get('$efz_execution_context'),
   case Copy of true->efz_cov:attach(C);false->ok end,
   P!{child_ready,self(),Before},receive go->ok end,
   Result=try audit_sites:c(),ok catch error:E->{error,E} end,
   P!{child_done,self(),Result}
 end,
 Child=case Kind of spawn->spawn(F);spawn_link->spawn_link(F);spawn_monitor->{CP,_}=spawn_monitor(F),CP end,
 {child,Child};
run({background,Bg})->audit_sites:a(),gen_server:call(Bg,work);
run({background_timer,Bg,P})->audit_sites:a(),erlang:send_after(0,Bg,{work,P}),ok;
run(<<"bad_context_caught">>)->put('$efz_execution_context',bad_context),try audit_sites:a() catch error:_->caught end;
run(<<"broken_table_caught">>)->C=get('$efz_execution_context'),put('$efz_execution_context',setelement(4,C,make_ref())),try audit_sites:a() catch error:_->caught end.
```

<!-- audit-source: audit_background.erl -->
```erlang
-module(audit_background).
-behaviour(gen_server).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2]).
init([])->{ok,#{}}.
handle_call(work,_,S)->audit_sites:c(),{reply,get('$efz_execution_context'),S}.
handle_cast(_,S)->{noreply,S}.
handle_info({work,P},S)->audit_sites:c(),P!{background_done,get('$efz_execution_context')},{noreply,S}.
```

<!-- audit-source: audit.escript -->
```erlang
#!/usr/bin/env escript
-mode(compile).
main([D,"fresh",Out])->
 paths(D),{ok,AB}=file:read_file(filename:join(D,"artifact.term")),A=binary_to_term(AB),
 {ok,Ms}=efz_instrument:preflight([A]),{ok,P}=efz_cov_manifest:prepare(automatic,Ms),
 R=run(<<"a">>,options(ets,P)),ok=efz_cov_manifest:release(P),
 ok=file:write_file(Out,term_to_binary(#{result=>R,online=>erlang:system_info(schedulers_online)}));
main([D,"halt",_Out])->
 paths(D),{ok,AB}=file:read_file(filename:join(D,"artifact.term")),{ok,Ms}=efz_instrument:preflight([binary_to_term(AB)]),
 {ok,P}=efz_cov_manifest:prepare(automatic,Ms),run(<<"halt">>,options(ets,P));
main([D])->
 paths(D),put(events,[]),
 lists:foreach(fun(M)->File=filename:join(D,atom_to_list(M)++".erl"),
   {ok,M}=compile:noenv_file(File,[debug_info,warnings_as_errors,{outdir,filename:join(D,"plain")}])
 end,[audit_target,audit_background]),
 {ok,A}=efz_instrument:compile(filename:join(D,"audit_sites.erl"),
   #{modules=>[audit_sites],source_root=>D,outdir=>filename:join(D,"targets")}),
 ok=file:write_file(filename:join(D,"artifact.term"),term_to_binary(A)),
 {ok,[M]}=efz_instrument:preflight([A]),
 put(identities,maps:from_list([{maps:get(function,X),{audit_sites,maps:get(build_id,M),maps:get(probe_id,X)}}||X<-maps:get(probes,M)])),
 OTPFile=filename:join([code:root_dir(),"releases",erlang:system_info(otp_release),"OTP_VERSION"]),
 emit(environment,#{otp_file=>file:read_file(OTPFile),otp=>erlang:system_info(otp_release),erts=>erlang:system_info(version),
  architecture=>erlang:system_info(system_architecture),schedulers=>erlang:system_info(schedulers),
  online=>erlang:system_info(schedulers_online),erl_flags=>os:getenv("ERL_FLAGS"),
  compiler=>compile:module_info(md5),manifest=>M,defaults=>efz_config:defaults()}),
 lists:foreach(fun(B)->suite(B,[M]) end,[ets,ets_member]),
 campaign_cases(A),fresh_vms(D),hot_code(D,A,[M]),
 []=tables(),emit(final_resources,#{coverage_and_plan_tables=>tables()}),
 Events=lists:reverse(get(events)),
 ok=file:write_file(filename:join(D,"events.term"),term_to_binary(Events)),
 ok=file:write_file(filename:join(D,"events.txt"),unicode:characters_to_binary(io_lib:format("~tp.~n",[Events]))),
 io:format("ALL DIAGNOSTIC ASSERTIONS PASSED (~B records)~n",[length(Events)]).
paths(D)->true=code:add_patha(filename:absname("_build/default/lib/efz/ebin")),
 ok=filelib:ensure_dir(filename:join([D,"plain","x"])),true=code:add_patha(filename:join(D,"plain")).
options(B,P)->#{coverage=>automatic,coverage_backend=>B,coverage_plan=>P}.
run(I,O)->efz_executor:run(audit_target,I,1000,O).
hits(R)->ok=maps:get(coverage_status,R),maps:get(coverage,R).
ids(Names)->lists:sort([maps:get(N,get(identities))||N<-Names]).
emit(K,V)->put(events,[{K,V}|get(events)]),io:format("PASS ~tp~n",[K]).
series(Sets)->
 R=length(Sets),U=lists:foldl(fun ordsets:union/2,[],Sets),
 F=lists:foldl(fun(S,M)->lists:foldl(fun(X,A)->A#{X=>maps:get(X,A,0)+1} end,M,ordsets:from_list(S)) end,#{},Sets),
 I=lists:sort([X||{X,N}<-maps:to_list(F),N=:=R]),
 Score=case R>=2 andalso U=/=[] of true->100*length(I)/length(U);false->not_applicable end,
 #{r=>R,union=>U,intersection=>I,variable=>ordsets:subtract(U,I),frequencies=>F,score=>Score}.
suite(B,Ms)->
 {ok,P}=efz_cov_manifest:prepare(automatic,Ms),O=options(B,P),
 First=[run(<<"a">>,O)||_<-lists:seq(1,3)],[H,H,H]=[hits(X)||X<-First],H=ids([a,b,c]),
 #{score:=100.0}=Stable=series([hits(X)||X<-First]),emit({B,deterministic},#{runs=>First,series=>Stable}),
 persistent_term:erase({audit_target,alternate}),
 Alt=[run(<<"alternate">>,O)||_<-lists:seq(1,3)],As=[hits(X)||X<-Alt],
 [3,3,3]=[length(X)||X<-As],#{score:=50.0}=S=series(As),
 [F1,F2,F3]=As,F1=F3,F2=ids([a,b,d]),
 50.0=maps:get(score,series([F2,F1,F2])),
 Collapsed=series([ordsets:union(X,Y)||{X,Y}<-lists:zip(As,[F2,F1,F2])]),100.0=maps:get(score,Collapsed),
 emit({B,alternation},#{runs=>Alt,series=>S,corpus_input_feature_score=>50.0,wrong_collapsed_score=>100.0}),
 R1=run({repeat,1},O),R100=run({repeat,100},O),H1=hits(R1),H1=hits(R100),H1=ids([a]),
 emit({B,multiplicity},#{once=>R1,hundred=>R100}),
 [AA,BB,AA]=[hits(run(X,O))||X<-[<<"only_a">>,<<"only_b">>,<<"only_a">>]],
 []=ordsets:intersection(AA,BB),
 Perms=[[<<"only_a">>,<<"only_b">>],[<<"only_b">>,<<"only_a">>]],
 Rows=[lists:sort([{X,hits(run(X,O))}||X<-Order])||Order<-Perms],[Row,Row]=Rows,
 emit({B,aba},#{a=>AA,b=>BB,permutations=>Rows}),
 persistent_term:erase({audit_target,dirty}),DA1=hits(run(<<"state_a">>,O)),_=run(<<"state_b">>,O),DA2=hits(run(<<"state_a">>,O)),
 #{score:=+0.0}=Dirty=series([DA1,DA2]),persistent_term:erase({audit_target,dirty}),DA1=hits(run(<<"state_a">>,O)),
 emit({B,shared_state},#{without_reset=>Dirty,after_explicit_fixture_reset=>DA1}),
 L1=run({local_state},O),L2=run({local_state},O),{ok,{undefined,{messages,[]},undefined}}=LO=maps:get(outcome,L1),LO=maps:get(outcome,L2),
 emit({B,local_state},#{runs=>[L1,L2]}),
 E=run(<<>>,O),E2=run(<<"empty">>,O),[]=hits(E),[]=hits(E2),{ok,{error,invalid_input}}=maps:get(outcome,E),
 #{score:=not_applicable}=EmptySeries=series([[],[]]),emit({B,empty},#{invalid_return=>E,empty_snapshot=>E2,series=>EmptySeries}),
 Failures=[run({fail,K},O)||K<-[error,throw,exit]],
 lists:foreach(fun(X)->H1=hits(X) end,Failures),emit({B,exceptions},Failures),
 concurrent(O),terminations(B,O),children(B,O),background(B,O),live_snapshot(B),
 Bad=run(<<"bad_context_caught">>,O),[]=hits(Bad),{ok,caught}=maps:get(outcome,Bad),
 Broken=run(<<"broken_table_caught">>,O),{error,_}=maps:get(coverage_status,Broken),{infrastructure,_}=maps:get(outcome,Broken),
 emit({B,context_interference},#{malformed_context_caught=>Bad,invalid_table_caught=>Broken}),
 {efz_cov_plan,1,PT,_}=P,emit({B,live_plan},#{owner=>ets:info(PT,owner),protection=>ets:info(PT,protection),rows=>ets:info(PT,size),bytes=>ets:info(PT,memory)*erlang:system_info(wordsize)}),
 ok=efz_cov_manifest:release(P),undefined=ets:info(PT),
 Disposed=run(<<"empty">>,O),{error,invalid_coverage_plan}=maps:get(coverage_status,Disposed),
 emit({B,disposed_empty},Disposed).
async(I,T,O)->Parent=self(),Tag=make_ref(),{C,M}=spawn_monitor(fun()->Parent!{done,Tag,efz_executor:run(audit_target,I,T,O)} end),{C,M,Tag}.
ready(Tag)->receive {published,Tag,T,C}->{T,C} after 3000->error(no_publication_ack) end.
finished({C,M,Tag})->R=receive {done,Tag,X}->X after 4000->error(no_result) end,
 down(M,C),R.
down(M,P)->receive {'DOWN',M,process,P,_}->ok after 3000->error(missing_down) end.
table({efz_context,1,_,{ets_member,T},_})->T;table({efz_context,1,_,T,_})->T.
concurrent(O)->
 Q1=make_ref(),Q2=make_ref(),C1=async({hold,self(),Q1},3000,O),C2=async({hold,self(),Q2},3000,O),
 {T1,X1}=ready(Q1),{T2,X2}=ready(Q2),false=element(3,X1)=:=element(3,X2),false=table(X1)=:=table(X2),
 T1!finish,T2!finish,R1=finished(C1),R2=finished(C2),A=ids([a]),A=hits(R1),A=hits(R2),
 undefined=ets:info(table(X1)),undefined=ets:info(table(X2)),
 emit({maps:get(coverage_backend,O),concurrent},#{first=>R1,second=>R2,separate_refs_and_tables=>true}).
terminations(B,O)->
 lists:foreach(fun(Kind)->Q=make_ref(),H={Caller,CM,_}=async({hold,self(),Q},case Kind of timeout->1000;_->3000 end,O),
 {T,C}=ready(Q),Owner=element(5,C),TM=monitor(process,T),OM=monitor(process,Owner),
 {ok,Before}=efz_cov:snapshot(C),Before=ids([a]),
 case Kind of
  kill->exit(T,kill),R=finished(H),{exit,killed}=maps:get(outcome,R),Before=hits(R),down(TM,T),down(OM,Owner),emit({B,kill},R),
    Caught=run({fail,exit},O),Keys=[outcome,target_outcome,coverage_status,coverage,builds],
    true=maps:with(Keys,R)=:=maps:with(Keys,Caught),emit({B,exit_origin_ambiguity},#{caught_exit=>Caught,external_kill=>R});
  timeout->R=finished(H),{timeout,1000}=maps:get(outcome,R),Before=hits(R),down(TM,T),down(OM,Owner),emit({B,timeout},R);
  caller_death->exit(Caller,kill),down(CM,Caller),down(TM,T),down(OM,Owner),emit({B,caller_death},#{snapshot_returned=>false});
  coordinator_kill->exit(Owner,kill),R=finished(H),down(OM,Owner),true=is_process_alive(T),
    {infrastructure,{coordinator_down,killed}}=maps:get(outcome,R),{error,coordinator_down}=maps:get(coverage_status,R),
    []=maps:get(coverage,R),exit(T,kill),down(TM,T),emit({B,coordinator_kill},#{result=>R,target_was_alive_after_result=>true,diagnostic_harness_killed_orphan=>true})
 end,undefined=ets:info(table(C))
 end,[kill,timeout,caller_death,coordinator_kill]).
children(B,O)->
 lists:foreach(fun({Kind,Copy})->R=run({child,Kind,self(),Copy},O),{ok,{child,CP}}=maps:get(outcome,R),
 receive {child_ready,CP,undefined}->ok after 3000->error(no_child_ready) end,
 true=is_process_alive(CP),CM=monitor(process,CP),Q=make_ref(),H=async({hold,self(),Q},3000,O),{T,_}=ready(Q),
 CP!go,CR=receive {child_done,CP,V}->V after 3000->error(child_not_done) end,down(CM,CP),
 case Copy of false->ok=CR;true->{error,{efz_infrastructure,invalid_coverage_table}}=CR end,
 T!finish,Next=finished(H),A=ids([a]),A=hits(R),A=hits(Next),
 emit({B,child,Kind,Copy},#{parent=>R,next_execution=>Next,child_result=>CR,child_context_before_attach=>undefined})
 end,[{spawn,false},{spawn_link,false},{spawn_monitor,false},{spawn,true}]).
background(B,O)->
 {ok,Bg}=gen_server:start(audit_background,[],[]),
 R=run({background,Bg},O),{ok,undefined}=maps:get(outcome,R),
 Timer=run({background_timer,Bg,self()},O),receive {background_done,undefined}->ok after 3000->error(no_timer_ack) end,
 A=ids([a]),A=hits(R),A=hits(Timer),ok=gen_server:stop(Bg),emit({B,background},#{otp_call=>R,timer=>Timer}).
live_snapshot(B)->
 C=efz_cov:open(B),FakeRef=make_ref(),Copied=setelement(3,C,FakeRef),Parent=self(),
 {Writer,Mon}=spawn_monitor(fun()->efz_cov:attach(Copied),audit_sites:a(),Parent!writer_ready,
   receive write_more->audit_sites:b() end,Parent!writer_finished end),
 receive writer_ready->ok after 3000->error(no_writer_ack) end,
 {ok,First}=efz_cov:snapshot(C),First=ids([a]),
 Writer!write_more,receive writer_finished->ok after 3000->error(no_second_ack) end,down(Mon,Writer),
 {ok,Second}=efz_cov:snapshot(C),Second=ids([a,b]),ok=efz_cov:close(C),
 emit({B,unguarded_snapshot_and_ref},#{before_quiescence=>First,after_quiescence=>Second,changed_reference_accepted=>true}).
campaign_cases(A)->
 lists:foreach(fun(Kind)->
  persistent_term:put({audit_target,observer},self()),
  {ok,_}=efz:start(#{target=>audit_target,artifacts=>[A],seeds=>[<<"hold">>],max_iterations=>0,timeout=>3000}),
  {T,C}=ready(campaign),Owner=element(5,C),TM=monitor(process,T),OM=monitor(process,Owner),
  [{efz_worker,W,worker,_}]=supervisor:which_children(efz_worker_sup),
  case Kind of
   cancel->Await=catch efz:await(0),{'EXIT',{timeout,_}}=Await,true=is_process_alive(T),
     ok=efz:stop(),emit(campaign_cancel,#{await_timeout_did_not_cancel=>true,result_snapshot=>unavailable});
   worker_kill->exit(W,kill),R=efz:await(3000),{infrastructure_failure,{worker_down,killed}}=maps:get(status,R),
     emit(worker_kill,R),ok=efz:stop()
  end,down(TM,T),down(OM,Owner),[]=tables()
 end,[cancel,worker_kill]),
 {ok,_}=efz:start(#{target=>audit_target,artifacts=>[A],seeds=>[<<"only_a">>,<<"only_b">>],max_iterations=>0}),
 R=efz:await(3000),#{calibrations:=2,executions:=0,discoveries:=0}=maps:get(stats,R),
 [seed_calibration,seed_calibration]=[maps:get(retention_reason,X)||X<-maps:get(decisions,R)],
 emit(seed_initialization,R),ok=efz:stop().
fresh_vms(D)->
 Samples=[begin Out=filename:join(D,"fresh-"++integer_to_list(N)++".term"),
   {0,Text}=child_vm(D,"fresh",Out),ok=file:write_file(Out++".log",Text),
   {ok,Bytes}=file:read_file(Out),binary_to_term(Bytes)
 end||N<-lists:seq(1,3)],
 [R1,R2,R3]=[maps:get(result,X)||X<-Samples],F=hits(R1),F=hits(R2),F=hits(R3),F=ids([a,b,c]),
 B=maps:get(builds,R1),B=maps:get(builds,R2),B=maps:get(builds,R3),
 emit(fresh_vm_same_build,#{samples=>Samples,series=>series([F,F,F])}),
 Out=filename:join(D,"halt-result.term"),{23,Text}=child_vm(D,"halt",Out),false=filelib:is_file(Out),
 ok=file:write_file(filename:join(D,"halt.log"),Text),emit(vm_halt,#{exit_status=>23,snapshot_file=>missing}).
child_vm(D,Mode,Out)->
 Port=open_port({spawn_executable,os:find_executable("escript")},[binary,exit_status,stderr_to_stdout,
   {args,[filename:join(D,"audit.escript"),D,Mode,Out]}]),port_result(Port,<<>>).
port_result(P,Acc)->receive {P,{data,B}}->port_result(P,<<Acc/binary,B/binary>>);{P,{exit_status,N}}->{N,Acc}
 after 10000->port_close(P),error(child_vm_deadline) end.
hot_code(D,A,Ms)->
 {ok,P}=efz_cov_manifest:prepare(automatic,Ms),O=options(ets,P),
 {ok,audit_sites,Plain}=compile:noenv_file(filename:join(D,"audit_sites.erl"),[binary,debug_info,warnings_as_errors]),
 code:purge(audit_sites),code:delete(audit_sites),{module,audit_sites}=code:load_binary(audit_sites,"diagnostic_plain",Plain),
 R=run(<<"a">>,O),[]=hits(R),{ok,ok}=maps:get(outcome,R),
 {error,{loaded_module_identity_mismatch,audit_sites}}=Preflight=efz_instrument:preflight([A]),
 emit(hot_plain_replacement,#{old_plan_result=>R,explicit_preflight=>Preflight}),
 ok=efz_cov_manifest:release(P),code:purge(audit_sites),code:delete(audit_sites),{ok,_}=efz_instrument:preflight([A]).
tables()->[T||T<-ets:all(),lists:member(ets:info(T,name),[efz_execution_coverage,efz_coverage_plan])].
```

<!-- audit-source: existing_example.escript -->
```erlang
#!/usr/bin/env escript
-mode(compile).
main([D])->
 true=code:add_patha(filename:absname("_build/default/lib/efz/ebin")),
 {ok,A}=efz_instrument:compile("examples/simple_parser/efz_example_parser.erl",
  #{modules=>[efz_example_parser],source_root=>".",outdir=>filename:join(D,"existing-target")}),
 {ok,Ms}=efz_instrument:preflight([A]),{ok,P}=efz_cov_manifest:prepare(automatic,Ms),
 Rows=[begin Rs=[efz_executor:run(efz_example_target,B,1000,#{coverage=>automatic,coverage_backend=>ets,coverage_plan=>P})||_<-lists:seq(1,3)],
  [H,H,H]=[maps:get(coverage,R)||R<-Rs],true=H=/=[],[ok,ok,ok]=[maps:get(coverage_status,R)||R<-Rs],
  #{input=>B,runs=>Rs,exact_sets_equal=>true,feature_stability=>100.0}
 end||B<-[<<0>>,<<255>>]],
 ok=efz_cov_manifest:release(P),
 ok=file:write_file(filename:join(D,"existing-example.term"),term_to_binary(Rows)),
 io:format("~tp~n",[Rows]).
```
