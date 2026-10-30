# EFZ 技术审计——2026 年 9 月 12 日

[English](../../technical-audit-2026-09-12.md) · [Русский](../ru/technical-audit-2026-09-12.md) · [Español](../es/technical-audit-2026-09-12.md) · **简体中文** · [所有语言](../README.md)

## 1. 执行摘要

**EFZ 已是可用的覆盖引导模糊测试器，支持单 Erlang 进程中的同步二进制目标。变异 → 执行 → 覆盖 → 活跃 corpus → 下一次变异的闭环已打通。这由实际运行证明，而非仅有 API。**

一个独立实验使用标准 efz_mutation_plan、efz_worker、efz_executor、自动插桩及 efz_corpus，构建了以下链：

~~~text
corpus id=1: <<>>          initial seed from file
    dictionary_insert "A"
corpus id=2: <<"A">>       new coverage; parent=1
    dictionary_insert "B" at position 1
corpus id=3: <<"AB">>      new coverage; parent=2
    dictionary_insert "C" at position 2
corpus id=4: <<"ABC">>     new coverage; parent=3
~~~

执行了 40 次真实变异，41 个输入逐字节准确送达独立 harness，40 个配方还原原始字节。得到三项发现和一次崩溃。保存的 CRASH 输入复现 error(test_crash)，包括在新 VM 中。证据：[e2e.txt](../../audit-2026-09-12/e2e.txt)、[实验源码](../../audit-2026-09-12/run.escript)、[完整 ETF 报告](../../audit-2026-09-12/e2e-report.term)、[新 VM replay](../../audit-2026-09-12/fresh-replay.log)。

**可用性边界：**成功 corpus 只在单活动内存中。没有内置种子目录读取、成功新输入持久化、队列恢复或通用 fuzz CLI。实验 stop/start 后只剩原始一个种子。现有 escript 自行保存最终报告，不等于 corpus 服务持久化。

**Staged 变异器确已集成。** 默认仍为 random，也使用持续增长的 corpus。“新变异器独立存在”或“调度器只看到初始种子”等说法不符合现有代码。

三个主要问题：

1. 用户活动生命周期未完成：通用启动器、种子文件、持久 corpus 和重启。
2. 隔离仅限根目标进程；子执行不自动测量，子进程可能存活，全局状态影响后续用例。Manifest 验证成功不证明目标实际运行了插桩代码。
3. Staged 调度器可能在可用变异前停止：256 个有效种子、dictionary_overwrite/bitflip 阶段、不匹配字典和默认 max_idle_visits 会产生零变异执行。标准测试未覆盖，也未明确断言复用由覆盖发现的父输入。

下一阶段应把现有单 worker 循环完善为可复现工具：端到端测试锁定祖先关系、修复过早停止、添加 corpus 输入/输出及恢复、明确执行/覆盖边界与存储错误。无需新变异引擎、另一覆盖后端、分布式调度或 UI。

## 2. 当前架构

### 审计检出版本与范围

主仓库：/home/anonymous_usr/erl:fuzz/efz，分支 main，HEAD ac09c1f3e938c3a79b369fc6a87d61c1ae739db4，“chore: initialize efz OTP project”。上层 workspace 不是工作 Git 仓库。

HEAD 未完整描述受审实现：大多数 src/*.erl、test/、docs/、examples/、fixtures/、bench/、scripts/ 已是未跟踪文件；README.md、rebar.config、src/efz.app.src 已修改。已记录[初始状态](../../audit-2026-09-12/status-before.txt)及[全部 83 个原始文件 SHA-256](../../audit-2026-09-12/before-sha256.json)。相邻 efz.worktrees/agents-condemned-silverfish 含相同 83 文件且字节一致：这是另一检出副本，不是运行时第二引擎。

审计后这 83 个 SHA-256 均相同。仅添加本报告及含证据/诊断源码的 audit-2026-09-12/；未改生产代码、标准测试，未 commit/push。保存套件在全新临时目录重跑，诊断断言和新 VM replay 均通过。[报告完整性与结构检查](../../audit-2026-09-12/verification.json)。

审查了全部 src 模块、测试组件、启动/replay 脚本、示例、夹具、基准驱动用途，以及架构、覆盖、变异、replay 和前期文档。未重算历史性能值，也不作为新证据。calibration-readiness.md 包含审计与建议，其计划中的生产校准/稳定性收集器未实现。

环境：OTP 27.0 / ERTS 15.0，Rebar3 3.25.0，Linux。rebar.config 设置 minimum_otp_vsn=27、debug_info、warnings_as_errors、src_dirs=[src,examples/simple_parser]、deps=[]。主应用依赖 kernel、stdlib、crypto。未发现 Go/Python 运行时代码、NIF 覆盖、fuzz CLI 的 rebar provider、CI workflow 或额外项目 profiles。

### 目录图

| 目录 / 文件 | 实际作用 |
|---|---|
| src/——24 个 Erlang 模块与 efz.app.src | 唯一生产实现 |
| examples/simple_parser/ | 两模块，普通 parser 与适配器；纳入常规构建 |
| examples/automatic/run.escript | 特定 random 活动，目标/种子写死在脚本 |
| examples/staged/ | Staged parser、hex 字典和带 replay 的特定活动 |
| examples/cowboy/ | 独立同步 parse_qs harness、启动器、14 项额外检查；外部依赖 |
| test/ | EUnit、Common Test、脚本化测试变异器 |
| fixtures/ | 插桩语义、不支持 AST、include/record/tail 用例、性能目标 |
| scripts/replay.escript | 仅支持配方 → 字节的 CLI |
| scripts/coverage_bench.escript、bench/ | 基准、剖析、报告、归档；不是活动服务 |
| docs/ | 契约、历史验证、计划；本身不是实现 |
| _build/ | 已编译 BEAM、生成 manifests/报告/崩溃产物；不是事实来源 |

### 实际进程树

~~~text
application controller
└── efz_sup                    supervisor: one_for_all, intensity=0, period=1
    └── efz_fuzzer             temporary dynamic child, gen_server
        ├── efz_corpus         start_link; linked child, NOT a separate efz_sup child spec
        ├── efz_stats          start_link; linked child
        └── efz_worker_sup     linked supervisor: one_for_one, 5/10
            └── efz_worker     one temporary child
                └·· coordinator  spawn_monitor per input; not a supervised child
                    └·· target   spawn_monitor per input; M:run(Input)
~~~

虚线表示创建/监视，不是链接。efz_fuzzer 额外监视 worker。实现：[efz_fuzzer:init/1](../../../src/efz_fuzzer.erl) 第 17–25 行；[efz_worker_sup:init/1](../../../src/efz_worker_sup.erl) 第 2 行；[efz_executor:coordinate/6](../../../src/efz_executor.erl) 第 25–60 行。

普通目标异常后 worker 继续活动。Worker 不重启：fuzzer 返回 infrastructure_failure/worker_down。Corpus/stats/worker supervisor 故障通过捕获 EXIT 停止 fuzzer；terminate/2 先停 worker supervisor，再 stats、corpus。Worker 死亡不恢复全局覆盖或游标。活动结束后 worker 仍活着但不再 iterate；释放 corpus、准备 ETS 计划及活动服务需要 efz:stop/0。

### 状态所有权

| 状态 | 所有者 / 机制 | 生命周期 |
|---|---|---|
| 活跃 corpus、下一整数 ID、随机选择 PRNG | efz_corpus gen_server 状态；PRNG 在其进程字典 | 一个活动 |
| 全局成功覆盖、builds | efz_worker.feedback：map + sets | 一个活动 |
| 变异计划、显式 RNG、游标、待处理 ID | efz_worker.mutation_state | 一个活动 |
| 准备好的允许探针集合 | 无名受保护 ETS efz_coverage_plan；worker 所有 | 至 worker 死亡 |
| 当前执行覆盖 | 无名公共 ETS efz_execution_coverage；协调器所有 | 一个输入 |
| 当前覆盖指针 | 目标进程字典 '$efz_execution_context' | 一个目标进程 |
| 决策、崩溃 ID、有界配方轨迹 | Worker 状态 | 一个活动 |
| 计数器 | efz_stats gen_server | 一个活动 |
| 最终报告、await 等待者 | efz_fuzzer 状态 | 至 stop |
| 插桩 BEAM + manifest sidecar | 文件系统；加载模块使用共享 code server | 超出单输入生命周期 |
| Crash .input/.term/.recipe | 文件系统，efz_crash:save/4 | 跨运行 |

生产 src 没有 persistent_term。仅基准用 efz_perf_replay 使用它，目标也可能使用，但执行器不清理。

## 3. 组件清单

状态评估组件声明的功能，不仅编译。PARTIAL 也表示用户流程缺失部分，并明确注明相关模块不存在。STUB 应指现有占位实现，主路径未发现。UNUSED 表示主运行时无调用，不授权立即删除。

表中“实现 / 用途”合并 Purpose 和 Current implementation；I/O 为输入输出。模块 X 位于 src/X.erl，除非明确给出其他路径。

| 组件 | 相关模块/文件；实现 / 用途 | 输入 → 输出 | 状态所有者 | 调用者 → 调用 | 状态 |
|---|---|---|---|---|---|
| 公开入口 | efz:start/1、stop/0、stats/0、await/1；OTP API | Config map → {ok,Pid} / error；await → 报告 map | App / fuzzer | Erlang 调用方、示例 → application、supervisor、fuzzer | IMPLEMENTED |
| 通用 CLI | 无独立 efz_cli 或通用 run TARGET CORPUS；examples/*/run.escript 含具体活动 | 示例参数 → API config | Escript 主程序 | shell → efz:start | PARTIAL——无通用启动器 |
| 配置 | efz_config:prepare/1；默认、回调、覆盖预检；变异 schema 独立 | map → {ok,prepared map}/{error,...} | 调用方，再 worker | fuzzer → instrument、mutation_plan、code | PARTIAL——顶层宽松 |
| Harness 契约 | efz_target；-callback run(binary()) -> term()；runtime 不强制 behavior | binary → 任意项 / 异常 | 目标进程 | executor → M:run/1 | IMPLEMENTED |
| Harness / 目标选择 | config target atom；固定 run/1；检查导出 | target atom、artifacts → 已加载回调 | Code server | config → ensure_loaded/function_exported | PARTIAL——通用 API 无 MFA/arity/源码加载 |
| 目标调用 | efz_executor:run/4、coordinate/6 | Module、Input、timeout、options → 结果 map | 每例协调器 | worker、recipe → M:run/1 | IMPLEMENTED，单进程范围 |
| 输入交付 | worker execute/4 → executor；不解码 binary | binary + parent → harness 中相同 binary | Worker/协调器/目标 | corpus/planner → executor/harness | IMPLEMENTED |
| Worker | efz_worker gen_server，iterate 消息 | 准备配置/corpus → 执行/报告 | Worker | worker_sup → mutator、executor、feedback、corpus、crash、stats | IMPLEMENTED |
| 超时处理 | executor wait_target/5、kill_and_drain/2；截止 + DOWN | 整数毫秒 → {timeout,T} | 协调器 | executor → monitor/exit/receive | PARTIAL——仅根清理；无后代跟踪 |
| 异常处理 | executor try/catch；基础设施与目标失败分离 | Exception/exit → outcome 元组；error/throw 有 stack | 协调器 + worker | target → feedback/crash | IMPLEMENTED，但来源有限制 |
| 覆盖编译门面 | efz_instrument:compile/2、preflight/1、load/1 | .erl、allowlist、选项 → BEAM/manifest/产物 map | 文件系统/code server | Caller/config/replay → compiler/PT/manifest | IMPLEMENTED |
| 覆盖插桩 | efz_instrument_pt:parse_transform/2 | 抽象形式 → 带 hook 形式、manifest 属性 | 局部编译状态 | compile → 生成代码 efz_cov_rt:hit/1 | PARTIAL——有限 AST，默认 strict |
| 覆盖 hook | efz_cov_rt:hit/1；ETS insert / member+insert | Probe 身份 → ok 或带标签错误 | 通过 PD 上下文访问每例 ETS | 插桩目标 → ETS | IMPLEMENTED，已 attach 进程 |
| 覆盖上下文/收集 | efz_cov:open/attach/snapshot/close | Backend/context → 精确排序身份 | 协调器拥有 ETS | executor → ETS/runtime | IMPLEMENTED |
| 覆盖身份/验证 | efz_cov_manifest；源码映射、精确 allowlist、准备计划 | manifest/hits → ok/error、builds map | Worker ETS / 不可变 map | config/executor/recipe → ETS/sets/beam_lib | PARTIAL——验已观测 ID，不持续验加载代码 |
| 覆盖状态/反馈 | efz_feedback:new/1,evaluate/3 | 旧集合 + result + phase → 新集合 + 决策 | Worker | worker → efz_cov:merge/2 | IMPLEMENTED |
| Corpus | efz_corpus；条目列表、添加去重、ID | [binary]、add(binary,meta) → entry/list/{ok,id}/{existing,binary} | Corpus gen_server | fuzzer/worker → rand | PARTIAL——仅 RAM，初始重复保留 |
| 队列 | 同一 entries；无独立队列服务 | 顺序条目 → 可选条目 | Corpus | worker/planner → corpus API | IMPLEMENTED 基本队列 |
| 种子选择 | corpus:select/0 random；mutation_plan:visit/2 staged 轮询 | Entries → 父条目 | Corpus RNG / worker 计划 | worker → rand 或游标 | PARTIAL——idle 截断可能早于有效阶段 |
| Random 变异器 | efz_mutator 回调；efz_mutator_random:mutate/2，四操作 | binary、#{iteration=>N} → binary | Worker 进程 PRNG | worker random → rand/list 操作 | IMPLEMENTED，旧/默认路径 |
| Staged 变异 | efz_mutation_plan:new/1,next/2 | Plan + 当前条目 → candidate/skip/done/error | Worker | staged → efz_mutation、dictionary、rand:*_s | PARTIAL——已集成，过早耗尽 |
| 确定性阶段 | mutation_plan:deterministic/4、det_op/4 | 阶段、binary、索引、config → operation/done | 内容/config 游标 | Planner → 变异原语 | IMPLEMENTED |
| 变异原语 | efz_mutation:apply_operation/3,apply_operations/3 | binary + 具体操作 + 限制 → ok/skip/error | 无可变状态 | Planner/recipe/tests → binary/crypto | IMPLEMENTED |
| Havoc | mutation_plan:random_attempts/5,stack/7 | Primary、活跃条目、显式 RNG → 实现操作栈 | Worker 计划 | Planner → primitives/random_operation | IMPLEMENTED |
| 字典 | efz_dictionary:normalize/2,load/2；EFZ hex 格式 | 二进制 token 或 hex 文件 → 规范 token + hash | 准备变异 config | mutation_plan:prepare → 有界读 | IMPLEMENTED |
| 拼接 | mutation_plan:random_operation/6；splice 操作 | Primary + 全条目 donor → 前后缀 binary、donor 字节/hash | Worker 计划 | Havoc/splice → mutation:apply_operation | IMPLEMENTED |
| 配方 | efz_recipe:make/4、encode/decode、regenerate | Primary + 已定操作 → EFZR / 精确输出 | Corpus/crash 元数据；可选有界轨迹 | worker/replay → mutation、hash | IMPLEMENTED，staged |
| Replay | recipe:execute/5、execute_file/5；scripts/replay.escript | 显式 target/builds + input → 执行结果；CLI 配方 → 文件 | 新准备计划 | Caller/scripts → preflight/executor | PARTIAL——无通用执行 CLI，harness 未固定 |
| 崩溃存储 | efz_crash:fingerprint/3,save/4 | Input/result/meta/dir → .input/.term/[.recipe]、记录 | 文件 + worker crash_ids | worker → file/crypto/recipe | PARTIAL——非原子写，错误杀 worker |
| 统计 | efz_stats:inc/get；worker 时间/计数 | 计数键 → 新计数/map | Stats gen_server | Worker/fuzzer/API → gen_server | PARTIAL——worker_down 不增基础设施计数 |
| 监督 | efz_app、efz_sup、efz_fuzzer、efz_worker_sup | 启动/停止/死亡 → 生命周期/报告 | OTP 进程 | efz/application → links/monitors/supervisors | PARTIAL——每例协调器不受监督 |
| 并行 worker | config valid 只接受 workers=1 | workers>1 → 无效配置 | 无 | config 拒绝 | PARTIAL——功能不存在，不是闲置池 |
| 持久活动状态 | Corpus/全局覆盖/队列游标/RNG 恢复未实现 | — | 无 | — | PARTIAL——仅崩溃产物和外部报告 |
| 手动兼容 | efz_cov:hit/1、executor:run/3；共享执行器 | 手动 ID → {manual,Id}；run/3 → outcome | 同执行上下文 | 旧调用方/测试 → runtime | LEGACY，显式可用 |
| 旧辅助 API | cov:interesting/2、reset_local/0、snapshot/0 | 手动直接 helper | PD/context | 当前 src/test/examples 无调用 | 主路径 UNUSED |
| 测试预录变异器 | test/efz_scripted_mutator | iteration → 预录 binary；忽略 parent | 无 | Phase2/CT/backend → lists:nth | 生产 UNUSED |
| 基准 replay / 测量 | bench/efz_perf*、*.escript、scripts/coverage_bench | 输入/工作负载 → 时间/ETF/文本 | 基准 VM；replay 用 persistent_term | 显式脚本 → EFZ 公共 API | 生产 UNUSED |

## 4. 实际端到端执行流程

### 通用启动

~~~text
Erlang caller / examples/.../run.escript:main
  -> efz_instrument:compile(SourceFile, CompilerConfig)           % explicit preliminary step
  -> efz:start(ConfigMap)
  -> application:ensure_all_started(efz)
  -> supervisor:start_child(efz_sup, efz_fuzzer child spec)
  -> efz_fuzzer:start_link(ConfigMap)
  -> efz_config:prepare(ConfigMap)
       -> efz_mutation_plan:prepare(MutationOptions, Seeds)       % staged only
            -> efz_dictionary:normalize/2, load/2
       -> efz_instrument:preflight(Artifacts)                    % automatic
            -> load/1 -> loaded_manifest/2
       -> code:ensure_loaded(Target), function_exported(Target,run,1)
  -> efz_fuzzer:init(PreparedConfig)
       -> efz_corpus:start_link([binary()], SelectionSeed)
       -> efz_stats:start_link()
       -> efz_worker_sup:start_link(Config#{coordinator=>FuzzerPid})
            -> efz_worker:init(Config)
                 -> efz_cov_manifest:prepare(Mode, Manifests)     % default
                 -> efz_feedback:new(Builds)
                 -> efz_mutation_plan:new(MutationConfig)        % staged
                 -> self() ! iterate
~~~

产物描述符含模块 atom、绝对 beam 路径、manifest 路径、二进制 SHA-256 build_id、warnings。准备配置是普通 map，不是 application env 或 persistent_term。创建 worker 前加载产物。加载器不按路径编译独立非插桩 harness；harness 须对 code server 可用。

### 校准与两条变异路径

Worker 先将 efz_corpus:all() 复制到 pending_seeds。每个初始条目以 Phase=calibration 执行一次，这是 GlobalCoverage 初始化，不是重复稳定性校准。

~~~text
random:
  efz_worker:handle_info(iterate, State)
    -> efz_corpus:select()
       gen_server:call(efz_corpus, select)
       <- #{id:=integer(), input:=binary(), metadata:=map(), added_at:=integer()}
    -> MutatorModule:mutate(Input, #{iteration => N+1})
       <- binary()

staged:
  efz_worker:staged_iteration(State)
    -> efz_corpus:mutation_entries()
       gen_server:call(efz_corpus, mutation_entries)
       <- [#{id:=integer(), input:=binary()}]                     % entire current corpus
    -> efz_mutation_plan:next(PlanMap, Entries)
       <- {candidate, Binary, ProvenanceMap, NextPlan}
        | {skip, Reason, NextPlan}
        | {done, Reason, NextPlan}
        | {error, Reason, NextPlan}
    -> efz_recipe:make(Provenance, Binary, MutationConfig, Builds)
       <- RecipeMap
    -> efz_worker:execute(Binary, #{id=>ParentId}, mutation, State)
~~~

skip 仅调度下一个 iterate。iteration/max_iterations 计已生成且执行的候选；不含 skips 或初始校准。

### 执行、消息与返回

~~~text
efz_worker:execute(Input, ParentEntry, Phase, State)
  -> efz_executor:run(TargetModule, Input, TimeoutMs, ExecutorOptions)
       Request = make_ref()
       spawn_monitor(coordinate(Caller, Request, ...))
         monitor(Caller)
         efz_cov:open(Backend)
           <- {efz_context,1,Ref,TableOrBackendTable,OwnerPid}
         spawn_monitor(target fun)
           efz_cov:attach(Context)
             put('$efz_execution_context', Context)
           TargetModule:run(Input)
             -> synchronous target calls
             -> instrumented clause: efz_cov_rt:hit({Module,BuildId,ProbeId})
                  ets:insert(Table, {{probe, Identity}})
           Parent ! {target_result, Ref, self(), Outcome}
         receive target_result / DOWN / caller DOWN / timeout
         wait for target DOWN; on timeout kill_and_drain/2
         efz_cov:snapshot(Context) -> {ok,SortedHits} / {error,...}
         efz_cov_manifest:validate_prepared(...) -> ok / error
         Caller ! {Request, CoordinatorPid, ResultMap}
         after: kill_and_drain(Target), close(Context), demonitor(Caller)
       caller waits for coordinator DOWN, then returns ResultMap
~~~

ResultMap 包含 execution_ref、outcome、target_outcome、coverage、coverage_status、elapsed_us、builds。Coordinator_down fallback 无 target_outcome，coverage=[]、builds=#{}，且是基础设施错误；不是常规成功空快照。

其他消息：标准 {'DOWN',Monitor,process,Pid,Reason}；ETS 错误时 hook 向所有者发 {efz_cov_failure,Ref,Why}。活动结束 worker 发 {campaign_done,WorkerPid,Report}，fuzzer 回复已保存 await 的 gen_server 调用方。目标输入不经文件描述符、stdin、端口、socket 或共享 worker 邮箱，而由 spawn_monitor 闭包捕获。

### 反馈与下一代

~~~text
ResultMap
  -> efz_feedback:evaluate(FeedbackState, ResultMap, Phase)
       successful: New = Observed \ Global
                   Global1 = Global union Observed
       <- {ok,NewFeedback,#{new_probes=>New,retention_reason=>Reason}}
  -> efz_worker:retain(Input, Metadata)
       if Reason = new_coverage:
         efz_corpus:add(Input, Metadata)
           gen_server:call(efz_corpus,{add,Input,Metadata})
           entries := entries ++ [NewEntry]
           next := next + 1
           <- {ok,Id} / {existing,Input}
  -> efz_worker:record_failure(...)                              % separate artifact branch
  -> self() ! iterate
  -> corpus:select() or corpus:mutation_entries()              % see NewEntry
  -> next mutation, where NewEntry can be Parent
~~~

具体闭环：worker 第 42–49、58–90 行；corpus 第 12–14 行；mutation_plan 第 63–76 行。成功保留到下一 select 间没有断层，也没有文件操作。

## 5. Harness 与输入交付

### 用户如何选择目标

**今天无需改 EFZ 内部模块就能运行最小 run(Input) when is_binary(Input)。** 导出 run/1，常规 Erlang 编译/加载，将 target => Module 传给 efz:start/1 即可。现有目标不匹配 run/1 或需控制错误分类时才要独立适配器。正式 efz_target behavior 已存在，runtime 验函数但不要求 -behaviour 属性。

Automatic 模式还需实际调用模块的插桩产物。可像 staged 示例插桩 run/1 所在模块，或像 automatic/Cowboy/审计示例只插桩 parser、harness 保持普通。

| 问题 | 实际答案 / 证据 |
|---|---|
| 目标模块 | Config target atom；config:valid/1 第 29–33 行 |
| 函数与 arity | 固定 run/1；function/arity 未实现，任意顶层键可能静默保留 |
| 契约 | efz_target: -callback run(binary()) -> term() |
| 加载 | 先产物预检，再 ensure_loaded(Target)；无独立 compile_harness API |
| 导出检查 | erlang:function_exported(M,run,1)，config 第 42–48 行 |
| 进程 | 每输入新目标进程；同 BEAM VM |
| 调用 | M:run(Input)，executor 第 34 行；无显式 apply/3 |
| 成功 | 任意正常返回，包括 {error,...}、false、{invalid,...}，均包装 {ok,ReturnValue} |
| Error/throw | {crash,Class,Reason,Stack} |
| exit/1 | {exit,Reason}，不保留 stack |
| 链接异常退出 | 可终止根 → monitor DOWN → {exit,Reason}；根若 trap_exit 并处理信号，正常返回仍成功 |
| 超时 | 只杀并等待根 DOWN；不登记子进程 |
| 清理回调 | before_input/reset/after_input/cleanup 不存在 |
| 应用生命周期 | EFZ 不管理目标应用初始化/停止 |

现有目标若需要 list、iolist、任意项或 MFA，由用户写转换/适配器。Audit_harness 将输入原样交 audit_target:parse/1。Cowboy harness 将字节置于 #{qs=>Input}；正常 request_error qs/limit_reached 转 {invalid,...}，非预期异常外抛。

### 单种子从文件到目标

生产 API 接收已准备的非空二进制列表；config 和 corpus 都不读种子文件。现有路径：

~~~erlang
{ok, Seed} = file:read_file(SeedPath),       % caller, not an EFZ function
efz:start(#{target => Harness, seeds => [Seed], artifacts => Artifacts, ...}).
~~~

随后 binary 存于 entry.input，直接选择或交 planner；生成 binary 经 execute → run/4 → M:run/1 → parser。审计脚本即如此，file:read_file 和 fixture 写入在覆盖外。这些准备不以 mock 替代核心。

| 类型 / 限制 | Random 运行时 | Staged 运行时 |
|---|---|---|
| 初始输入 | 仅 binary()；列表非空 | 同左，最多 4096 初始条目 |
| 输入上限 | Config/worker/executor 无统一上限 | max_input_bytes 默认 4096，允许 0…1048576 |
| 生成类型 | Worker 检查 is_binary | 原语返回 binary；planner 处理 error/skip |
| 空 binary | 允许，delete 可得 <<>>，mutate(<<>>) 得 <<0>> | 允许，delete/splice 可得 <<>> |
| 过大种子 | 内存足够即接受 | prepare 拒绝 oversized_initial_seed |
| 过大候选 | 无统一检查 | 操作内验大小；skip(size_limit)/error |
| 字节转换 | 非空输入完整 binary_to_list 和 list_to_binary | Binary 操作；仅生成字面字节用列表 |
| 精确配方 | 无 | Primary 字节 + 具体操作 + 字面 token/donor + hash |
| 成功输入持久化 | 仅 RAM 条目 | 仅带配方 RAM 条目 |

输入以 Erlang 项跨 corpus、worker、协调器和目标传递。这不是零复制 API：map/list 和堆数据跨进程复制；引用计数 binary 可共享底层存储。不改变 binary 语义。Staged 的 mutation_entries/0 每次传整个 corpus 列表，快照/报告也复制结构。这是后续性能问题，不是反馈闭环断层。

低层 efz_executor:run/4 不验 is_binary(Input)，测试可传 tuple/atom。便于执行器测试，但不扩展主 fuzz loop 的 binary 契约。Replay execute/execute_file 限原始输入一 MiB；random 无相同统一限制。

### 用例隔离与前一输入影响

| 资源 | 实际清理 / 潜在影响 |
|---|---|
| 根进程字典 | 随根消失；下一个根是新进程。EFZ 加一个内部上下文键 |
| 根邮箱 | 消失；结果/monitor 消息在独立协调器，不进入下一例 |
| 覆盖 ETS | 每例新表，协调器删除；根正常退出不销毁它 |
| 目标所有 ETS | 普通 owner 表随根消失；EFZ 不清 heir 转移、他人/子进程表 |
| 根注册名 | 根死亡释放；活子进程名字仍保留 |
| 创建的子进程 | 无登记/kill-tree；有/无链接子进程都可在根正常返回后活着 |
| 定时器 | 无通用 cancel/reset；发往存活进程的消息/动作可稍后运行 |
| 根 monitors/links | 根终止；EFZ 排空自身监视器，不遍历别的进程/关系 |
| Application env、persistent_term、code server | 不清理，在用例间共享 |
| 文件、外部服务、socket、NIF 状态 | 无通用 reset/隔离 |

确认的 A→B→A：输入 state 调 path_a，dirty 写 persistent_term，同一 state 再运行调 path_ab，探针集合不同。见 [cross_case_state.txt](../../audit-2026-09-12/cross_case_state.txt)。

已确认有链接及无链接子进程执行插桩 path_abc，但执行上下文 undefined，根覆盖为空，子在返回后活着。另一子进程在根超时后仍存活。诊断脚本记录后自行杀其子进程；**该清理不能归功于 EFZ**。

因此根 ETS/PD 隔离成功不保证任意 OTP 应用可复现。erlang:halt、VM/NIF 崩溃或共享内存无界消耗也不被单独进程隔离。

## 6. 覆盖流水线

### 机制与粒度

EFZ 使用自有源码 parse_transform 和精确 ETS set。主实现无 OTP native coverage、cover、计数器、hit-count 桶或位图。插桩在 compile:noenv_file/2 预先完成，不在每轮做。

Manifest metric 为 clause_outcome_probe。Hook 加在所选 clause/outcome 函数体开头。实际 kinds：

~~~text
function_clause
case_clause
if_clause
receive_clause
receive_after
try_body
try_of_clause
catch_clause
try_after
fun_clause
named_fun_clause
~~~

这不是 edge、完整 branch 或 line coverage。同一行两个 outcome 有不同探针 ID，行仅作源码映射。进入子句体不说明每次子句转移或 guard 结果。andalso/orelse 当普通 op 节点遍历，不建独立 true/false 探针。Patterns、guards 保持无 hook。

List/binary/map comprehensions、maybe、未知 AST、可执行 record 默认值无内部探针。strict=true 拒绝不完整插桩，strict=false 保留结构、记录限制并警告。语义验证见 phase2_tests:semantics/1、manifest/1、tail/1、skipped/0。原生/NIF 及未选模块不测量。

### 身份与源码映射

完整身份：

~~~erlang
{ModuleAtom, BuildIdSHA256, ProbeIdInteger}
~~~

ProbeId 每模块从 1 起，按确定 AST 遍历递增。BuildId 为含插桩版本、OTP release、compiler MD5、规范预处理 forms、相关编译选项的元组 SHA-256。[efz_instrument_pt:parse_transform/2](../../../src/efz_instrument_pt.erl) 第 35–55 行，probe/4 第 109–118 行。

| 属性 | 结论 |
|---|---|
| 相同源码/选项/toolchain 重编译 | 身份稳定；phase2 determinism 已验证 |
| 不同模块编译顺序 | 不影响局部编号；无共享可变分配器 |
| AST 节点重排/新增 | 可重新编号探针；build 命名空间变化 |
| 不同构建 | 旧 ID 不能机械迁移到新覆盖 epoch |
| 碰撞 | 合法 manifest 拒绝重复整数/结构路径；无跨模块位图别名。SHA-256 是密码哈希，不是数学唯一保证 |
| 搬迁路径 | source_root 内路径规范化，relocated-build 测试通过；外部绝对 include/toolchain 改变可改变 hash |
| 映射 | 每探针含 function、arity、kind、structural_location、source_file、line、column |

BEAM 含 efz_manifest 属性，sidecar 含同一项。加载器比较 sidecar/BEAM manifest，以及已加载模块/预期 manifest。禁止其他 parse transforms、模块 allowlist、排除 EFZ/OTP 内部模块、独立 outdir，共同保护常规构建一致性。

### Local → snapshot → global

~~~text
local coverage:
    fresh public unnamed ETS set, execution coordinator owner
    row = {{probe, {Module,BuildId,ProbeId}}}
    duplicate hit overwrites the same key

local context:
    {efz_context,1,FreshRef,TableOr{ets_member,Table},Owner}
    target PD '$efz_execution_context'

snapshot:
    ets:tab2list → sorted list of full probe identities
    after root DOWN; observations survive crash/kill/timeout

validation:
    allowed exact identities in protected worker-owned ETS plan
    alternative per_execution: build allowed set from manifests

global coverage:
    worker.feedback.global, Erlang sets
    only successful input coverage is unioned

reset:
    next execution receives a different table, reference and root process
    previous table is deleted; global set is not reset until campaign ends
~~~

ets_member 先 ets:member，不存在才 insert。只是同 set 重复命中优化，不是独立 metric。Prepared/per_execution 是两验证策略，不是不同 collector。差分套件验证四组合。

### interesting 的精确语义

[efz_feedback:evaluate/3](../../../src/efz_feedback.erl) 第 5–22 行：

~~~text
require Result.builds == Feedback.builds
require coverage_status == ok

if outcome == {ok, _}:
    New = set(Observed) - Global
    Global := Global union Observed
    calibration -> retention_reason = seed_calibration
    mutation and New == [] -> equivalent_coverage
    mutation and New != [] -> new_coverage
else if infrastructure/coverage error:
    stop campaign as infrastructure failure
else:
    target_failure; Global unchanged; new_probes=[]
~~~

**新覆盖 = 成功执行中此前未见的完整探针身份。** 不是新计数、旧探针新组合、hash signature 或新位图位。相同集合不同执行次数不 interesting。另一个集合若是 Global 子集也不 interesting。

C_new = C_current − C_global 公式已实现，但有成功和 phase 条件。Crashes/throws/exits/timeouts 可有非空执行覆盖，却不扩展成功 global/corpus。明确策略避免崩溃独有探针抑制未来有用成功变异。

校准合并成功初始种子，不重插、不增 discoveries。Evaluate 后成功完整快照不保存在 corpus 元数据；保留 new_probes、builds、outcome、输入身份和来源。Report.coverage 是整活动并集，不是具体输入覆盖。

### 反馈可靠性边界

1. **未使用产物。** 合法 audit_target 产物配不调用它的 harness，活动 completed、coverage=[]、infrastructure_failures=0。验证只验已见 ID，空列表合法。成功预检不证明 harness 接到了目标。[证据](../../audit-2026-09-12/disconnected_artifacts.txt)。
2. **热加载。** 预检后模块替成普通未插桩构建，下一例 path_a、coverage=[]、coverage_status=ok，仍旧 build map。准备计划是固定 allowlist，不是每例验执行代码。[证据](../../audit-2026-09-12/hot_reload.txt)。README 禁止，但 runtime 不发现违规。
3. **子进程。** Spawn 不继承 PD 上下文；无 attach 的插桩子 hook 为 no-op。API 可手动传上下文，但不带来树静止/清理。
4. **上下文破坏。** ETS 错误发 sticky 通知，但 cov_rt 畸形分支只 raises。目标换上下文并捕获异常，返回成功空覆盖。[证据](../../audit-2026-09-12/caught_malformed_context.txt)。普通代码擦整个 PD 也会关闭 hook。
5. **协调器丢失。** 目标仍活，fallback builds=#{}；evaluate 可能把原 coordinator_down 替换为 instrumentation_build_mismatch。这非目标 crash，但报告失去首因。

这些并不否定新根进程、固定插桩构建范围内覆盖可用；它们限制对有状态/异步目标的适用性，并要求明确诊断。

## 7. Corpus 与队列流水线

**Corpus 反馈闭环：单活动内 WORKING。持久化/重启：PARTIAL，未实现。**

关键模块 [efz_corpus.erl](../../../src/efz_corpus.erl) 仅 15 行；短小掩盖的是明显限制，不是队列不存在。

| 概念 | 实际内容 |
|---|---|
| 初始 corpus | Config.seeds = [binary()]；每元素建一条目，不做初始去重 |
| 活跃队列 | State.entries；先种子，后全部成功新覆盖输入 |
| Interesting 输入 | Outcome {ok,_} 且 NewProbes ≠ [] 的变异 |
| 已存输入 | 成功路径 RAM entry.input；崩溃路径 .input 文件 |
| Favored 输入 | 无概念、得分或标志 |
| Donor 输入 | 活跃 corpus 内与 Primary 内容不同的任意 entry.input |
| 队列 ID | 连续整数 1…N，由串行 corpus gen_server 分配 |
| 内容 ID | Worker 元数据、planner/recipe 中 SHA-256；初始元数据为空 |

### 插入与复用

retain/2 在 new_coverage 时调用 add/2。Corpus 在线性条目列表检查 binary 相等，无匹配则尾加并增 next ID。已有 binary 返回 {existing,Binary}，不是 ID；worker 将 retention_reason 改为 existing_input。

Random select/0 在**整个当前列表**上 rand:uniform(length(Entries))。新条目有非零选中概率；有限预算结束前不提供确定性必选保证。

Staged 每次 next 都取当前 mutation_entries/0；每轮 ID 快照按插入顺序。新条目下一轮可 primary。Random_operation(splice,...) 的 donor 取所有当前 Entries，即使待处理 primary ID 是轮初快照。因此新输入可在首次 primary 之前当 donor。

实验确认 AB.parent=2、ABC.parent=3。标准 random 示例另产 <<>>，parent=2；条目 2 是此前发现的 <<"@">> 变异。默认 random 也能复用新发现父输入；不设 selection_seed 不保证该例特定序列重复。

### 元数据、去重与调度

| 属性 | 状态 |
|---|---|
| 成功重复变异 | 完整 binary 相等，线性查找；SHA 不作去重索引 |
| 初始重复种子 | 不同整数 ID 保留；两 <<"noop">> 测试得到 corpus size=2、calibrations=2 |
| Parent | 保留变异有整数父 ID |
| 变异深度/代际 | 无显式字段；祖先保留时可循 parent 计算 |
| 插入顺序 | 列表尾加 |
| 覆盖签名 | 无独立签名/完整成功快照；只有发现差量与 build namespace |
| 每条目种子状态 | 无 crash/timeout/不稳定种子隔离；初始失败仍在活跃 corpus |
| Favored/power/energy | 未实现 |
| 全局 corpus 大小/内存限额 | 无统一限额；staged 限初始数及输入大小，不限积累条目数 |
| Random 饥饿 | 有限活动中可能；均匀概率不是服务保证 |
| Staged 公平性 | 轮快照保护旧条目不被持续增长挤走，直到 idle cutoff 停止 |
| 同内容 staged 状态 | 游标按内容 hash + config ID；初始重复队列 ID 共享进度 |

### 磁盘与重启

Corpus 不调 file、DETS、disk_log、Mnesia、persistent_term；无 load/save/resume API。Config corpus_dir 不解释。成功发现不在磁盘获得 input/sidecar。

示例在 await 后写完整 report.term。用户可自行提取 binary 作为新活动 seeds，但 EFZ 不导入，也不恢复 ID、游标、PRNG、全局覆盖、crash 索引。再做种子校准不等于继续中断活动。

实验用同 Config 重新 start，corpus 从 4 变 1。因此 retain→select 间闭环未断，但**进度不跨 stop/restart 保存**。

## 8. 变异流水线

### 可用操作符

“确定性阶段”意为不随机选择的枚举。每个具体 efz_mutation 操作均确定。“可重放”指标准 staged 配方，旧 random 自身不生成配方。

| 变异 | 实现 | 确定阶段 | 可重放 | 运行时使用 |
|---|---|---|---|---|
| 位翻转 | flip_bits：连续 1/2/4 位，MSB-first；旧 random 一位 | 是，全部合法 offset | 是，staged | Random；staged bitflip/havoc |
| 字节翻转 | invert_bytes：1/2/4 bytes | 是 | 是 | Staged byteflip/havoc |
| 算术 | add：8/16/32 位，有符号 delta，模 2^W；多字节 big/little endian | 是，±1…±max_delta | 是 | Staged arithmetic/havoc |
| Interesting 整数 | set_integer：0,1,2,half−2,half−1,half,half+1,max−1,max | 是，boundary | 是 | Staged boundary/havoc |
| 插入 | 具体二进制块，含尾部边界 | 无独立字面阶段 | 是 | Havoc；旧 random 插一随机字节 |
| 删除 | 删非空块，可得空输出 | 无独立阶段 | 是 | Havoc；旧 random 一字节 |
| 覆盖写 | 保持大小的字面块 | 无独立字面阶段 | 是 | Havoc；旧 random 一随机字节 |
| 复制 | 把块复制到插入位置 | 无独立阶段 | 是 | Havoc |
| 字典插入 | 每字节边界插 token | 是 | 是，配方含 token 字节 | dictionary_insert/havoc |
| 字典覆盖 | 每可容纳 offset 放 token | 是 | 是 | dictionary_overwrite/havoc |
| Splice | prefix(Current,CutA) ++ suffix(Donor,CutB) | 否，随机切点/donor | 是，操作含 donor 字节/hash | Splice 阶段与 havoc |
| Havoc | 深 1…havoc_depth 的已实现操作栈 | 否，显式 RNG | 是 | Staged havoc lane |

所有操作在 [efz_mutation:operation/3](../../../src/efz_mutation.erl)，选择/枚举在 [efz_mutation_plan](../../../src/efz_mutation_plan.erl) 第 81–187 行。宽度顺序及 offset 由独立位/块模型、枚举测试检查。

### 实际 staged 执行顺序

默认阶段：

~~~text
bitflip, byteflip, arithmetic, boundary,
dictionary_insert, dictionary_overwrite, havoc, splice
~~~

实际是**交错轮询 lanes**，不是“每种子做完全部确定阶段，再 havoc，再 splice”。

每 visit 取下一个 corpus ID。其 content/config key 的 lane 对 length(Stages) 取模选阶段。Lane 增加，每阶段最多 attempts_per_visit 次尝试，至多给一个候选。此内容下次 visit 用下一 lane，即使本 sweep 未完。因此 havoc 可早于 bitflip sweep 完成很久。

每阶段游标记下一整数变异索引。skip/no_change 推进确定索引。耗尽阶段保持完成，不提前物化候选。返回 Plan 可交下次 next/2，内存内可续且有测试。没有游标/RNG 计划持久化 API。

### 限制与资源

| 参数 | 默认 | 允许范围 / 意义 |
|---|---:|---|
| max_input_bytes | 4096 | 0…1048576 |
| max_block_bytes | 128 | 1…65536 |
| max_token_bytes | 128 | 1…65536；token 另受 max_block_bytes 限制 |
| max_tokens | 256 | 0…4096 |
| max_dictionary_bytes | 16384 | 0…1048576 |
| max_delta | 8 | 1…128 |
| attempts_per_visit | 8 | 1…1024；最大尝试数，不是输出数 |
| havoc_depth | 8 | 1…32 |
| random_retries | 4 | 1…128，另受尝试预算限制 |
| max_idle_visits | 256 | 整个活动连续空 visit 1…100000 |
| trace_limit | 0 | 0…10000 配方 |
| Staged max_iterations | 未给时 1000 | 0…1000000；禁止 infinity |

无独立每种子最大变异数。总限制来自执行预算、有限确定搜索或 idle cutoff。Seeds ≤4096 只在 staged prepare 检查。变异选项严格拒绝未知键，顶层活动 config 则不同。

字典只加载一次、有界读，格式每行偶数长度 hex token、整行 # 注释、空行。不是 AFL dictionary parser。禁止空 token，重复排序/usort；数量/总字节限制先于去重检查。Tokens、dictionary_id 在活动期间固定。

No-change 原语跳过；havoc 栈回到原 Primary 也跳过且可重试。但不同阶段/父输入生成的相同 binary 不在执行前过滤。Corpus 只去重保留字节；等价覆盖执行仍有正确性价值，但消耗预算。

### Donor

random_operation(splice,...) 直接从 efz_corpus:mutation_entries() 取 Entries。Donor 为与 Primary 不同的所有 input binaries 的 lists:usort；不局限初始 seeds。来源记录 donor hash 及 donor 本体，操作验 hash。Splice 可空输出；相同 donor、no-change 输出按 skip。

### 过早耗尽——已复现缺陷

next/2 条件：

~~~erlang
Idle >= maps:get(max_idle_visits,C) orelse complete(State,Entries)
~~~

两个原因返回同样 done mutation_exhausted。256 个唯一单字节 seed、stages=[dictionary_overwrite,bitflip]、dictionary=[<<"AB">>] 时，第一 lane 对任何 seed 都无 fitting overwrite。256 visits 后**首次 bitflip 前就停止**，但初始种子已有 5120 bitflip candidates。

真实运行给出 calibrations=256、executions=0、generated_candidates=0、infrastructure_failures=0、status={mutation_exhausted,mutation_exhausted}。[edge-cases.log](../../audit-2026-09-12/edge-cases.log)、[复现器](../../audit-2026-09-12/edge-cases.escript)，mutation_plan 第 51–77 行。

Mutations.md 提醒 idle cutoff 不证明数学上耗尽所有变异。因此并非隐藏的未实现阶段，而是实际调度策略缺陷：正常配置可一次可用变异都不执行。应区分停止原因，并在相关 lanes 完整遍历上判断进展。

### 配方确定性

Seed + Recipe → 精确 mutated Input 对已实现 staged 候选**可用**。配方含 Primary 字节/hash、父队列 ID、stage、具体 operations、limits、output size/hash、config/dictionary ID、target_builds、schema/engine/operation versions、原 RNG seed。

随机决策已具体化为 offsets、widths、deltas、字面 tokens、donor bytes。Regenerate/1 不做随机选、查 corpus 或运行 target；验 Primary hash、limits、operations、输出大小/hash。EFZR 包有 magic/version、payload length、SHA-256、有界 ETF scanner、binary_to_term(...,[safe])；拒绝压缩 ETF 和运行时对象。

这是单候选精确重放，不是重启活动日程。配方不含整个 corpus、别的 seed 位置或停止时完整 PRNG/游标。Config hash 是来源，不是完整 config 序列化。旧 random 可在同环境固定变异和选择 RNG seeds 后复现，但无个体 random 配方路径。

## 9. 崩溃与超时处理

### 分类

| 目标事件 | Outcome | Worker 行为 |
|---|---|---|
| 任意项正常返回 | {ok,Term} | 可合并覆盖、保留输入 |
| error(Reason) | {crash,error,Reason,Stack} | 存精确输入/元数据并继续 |
| throw(Reason) | {crash,throw,Reason,Stack} | 同上 |
| exit(Reason)，含 normal/kill | {exit,Reason} | 保存，计目标失败；无 stack |
| 未捕获链接 exit / 外部 kill | 从 DOWN 得 {exit,Reason} | 保存；不区分捕获 exit 与终止源 |
| function_clause/case_clause/badmatch/badarg/badarith/undef | Error 类 → 对应 Reason 的 crash | 无专用异常白名单 |
| 作为 Erlang error 的 system_limit | Error 类 → crash | 真耗尽共享 VM 内存可终止整 VM；未隔离 |
| 截止时间 | {timeout,TimeoutMs} | 存输入/部分观测覆盖；timeouts++，global 不变 |
| 标记 efz_infrastructure 错误 / 无效覆盖 | {infrastructure,...} 或覆盖失败 | 停活动；非目标 bug |
| 用户变异器错误/非 binary 输出 | 执行前基础设施失败 | 不作为目标崩溃存 |

见 executor 第 32–39、62–85 行；worker 第 58–107 行。[异常诊断](../../audit-2026-09-12/exception_classes.txt) 明确检查手动抛出的 error reason 分类，不是 system_limit 真实资源耗尽实验。自然 pattern/guard/try 语义另由夹具测试验证。

Deadline 等 target_result 和根 DOWN。根已发结果未退出，剩余 timeout 仍作用。Timeout 分支胜出后即使消息竞态到达也保留 timeout。Kill_and_drain 创建新 monitor 等真 DOWN，再 flush 原 monitor，正确隔开不同 cases 的迟到消息。

但原生代码阻塞时，deadline 不保证 run/4 全墙钟上限；清理 receive 无独立外部 watchdog。任意子进程不在范围内。

### 指纹、去重与文件

[efz_crash:save/4](../../../src/efz_crash.erl) 第 6–25 行：

~~~text
crash ID = SHA256(term_to_binary({Class,Reason,first_3_stack_frames}))
exit ID  = fingerprint(exit,Reason,[])
timeout ID = fingerprint(timeout,deadline,[])

base = crash_dir / hex(crash ID) + "-" + hex(SHA256(Input))
base.input   = exact input bytes
base.term    = ETF #{result=>Result, metadata=>Metadata}
base.recipe  = EFZR, only if metadata contains a staged mutation
~~~

Crash-only coverage 保存在 result；crash 元数据 new_probes=[] 是保留策略，不是无覆盖。初始校准 crash 常无配方，因为还没变异。

去重层次不同：全部 encounters 增 crashes/timeouts，unique_crashes 由 worker signature set 定。Save 在 signature 查重**之前**，所以同签名不同 inputs 有不同文件，report.crashes 只含各签名首条。重复相同 input/signature 覆盖同路径。不同 input 的 timeout 同签名，但输入分别存。

Signature 不规范化文件路径、行、Reason terms、stack frame 参数。PID/ref 或数据相关 Reason 可把同 bug 分多签名。源码目录移动改变 stack path，可能改变同逻辑错误 crash ID。Build identity 非独立签名部分。

### 存储错误与可复现性

.input、.term、.recipe 顺序写，无 temporary+rename/transaction。中途崩溃留下部分集。Filelib:ensure_dir/file:write_file/recipe:save 的错误以 ok=... 处理，导致 worker 崩溃。

Crash_dir=/dev/null/efz-audit 诊断产生 worker_down，含 {{badmatch,{error,enotdir}},...efz_crash:save/4 line 17...}。最终 infrastructure_failures 仍 0；原触发输入未保存，紧急报告只有 status/stats/corpus。[日志](../../audit-2026-09-12/edge-cases.log)。

原始已存输入可用 recipe:execute_file/5，在显式 target、artifacts、expected builds 下执行。Scripts/replay.escript CLI 只重建字节，不运行目标。真实审计 CRASH 和标准 staged 异常的新 VM replay 均通过。

精确输入不保证有状态目标同样崩溃。Replay 验 selected builds，不验独立非插桩 harness 指纹、其环境/依赖或外部状态。未实现整活动连续 replay。

### 故障隔离与并发

突然杀**调用方/worker**时，协调器通常收 DOWN 后清 root/ETS；phase2/backend 测试覆盖。“Owner death cleans target and table” 杀的是 caller，不是拥有 ETS 的协调器，不能混淆。

杀**协调器自身**不会运行 after。审计 run/4 返回 {infrastructure,{coordinator_down,killed}}，目标却活着；诊断脚本自行停止。[证据](../../audit-2026-09-12/coordinator_kill.txt)。

当前不可能多 worker：config 要 workers=1，一个 child spec，服务单例命名。支持活动内无“两者都看到新 probe 都 retain”的 A/B race。Compare/merge 和插入同 worker 串行，corpus add/整数 ID 分配是串行 gen_server。Crash ID 为 hash，无分配器。

不证明 workers>1 就绪。每 worker 会持有独立 GlobalCoverage，compare/merge 不与 corpus 构成共享事务，crash 写无同步。Prepared plan、每执行上下文可并发读/独立运行且已测试，但活动共享调度/反馈并发未实现。

## 10. 组件集成矩阵

“可用”指具体连接；两端存在但无 runtime 调用不算集成。

| 生产者 | 输出 | 消费者 | 连接 | 可用 | 证据 |
|---|---|---|---|---|---|
| CLI / caller | Config map | efz_config | Escript → efz:start → fuzzer:start_link → config:prepare | PARTIAL：示例/API 有，通用 CLI 无 | efz.erl:3–7；fuzzer:6–10；examples/* |
| Config | Target atom、artifacts | Harness loader / executor | preflight + ensure_loaded + 验 run/1 export | 固定契约内 YES | config:35–48 |
| Seed file | Binary | 初始 corpus | Caller file:read_file → seeds | PARTIAL：外部 glue，无内置导入 | audit run.escript:e2e/2；corpus:init/1 |
| Corpus | 完整 entry / id,input entries | Mutator | select/0 random；mutation_entries/0 staged | YES | worker:33–49 |
| Mutator | Binary + staged 来源 | Worker | Mu:mutate/2 / mutation_plan:next/2 | YES | worker:35–52；EUnit phase3 |
| Worker | Binary、module、timeout、options | Executor | 同步 efz_executor:run/4 | YES | worker:58–60 |
| Executor / worker | 精确 binary | Harness | 全新受监视根 → M:run(Input) | YES | executor:31–40；41 次精确交付 |
| Harness | Binary / 特定参数 | Target | 普通同步 Erlang 调用 | 正确 harness 下 YES；config 不验证连接 | audit_harness:run/1；Cowboy adapter |
| Target execution | Probe 身份 | Coverage | 生成 efz_cov_rt:hit/1 → attached ETS | YES，根范围 | PT:probe/4；cov_rt:hit/1 |
| 子进程执行 | Probe 事件 | 父输入覆盖 | 上下文不自动继承 | NO | child/linked_child 诊断 |
| Coverage | 精确 snapshot + status/builds | Feedback | executor result → evaluate/3 | YES | worker:60–65；差分测试 |
| Feedback | new_coverage + delta | Corpus | worker retain → corpus:add | YES，RAM | worker:87–91；e2e A/AB/ABC |
| Corpus | 新插入条目 | Scheduler | 当前条目供 select/下轮使用 | YES，至 idle cutoff / stop | corpus:12–14；plan:63–76；祖先证据 |
| Scheduler | Parent + lane/index/donor 集 | Mutator | plan visit/attempts 或 random select | PARTIAL：可用，但过早 idle 耗尽 | edge-cases.log |
| 累积 corpus | Donor binary/hash | Splice | entries → 排除 Primary 的 usort donor | YES | mutation_plan:152–157 |
| 成功 interesting input | Binary/meta/recipe | 磁盘 corpus | 不存在 | NO | corpus:13 仅状态 append |
| 磁盘 corpus | Seeds/queue/state | Restart | 不存在 | NO | corpus:init/1；restart size=1 |
| Exception/timeout | Outcome、stack、input | Crash storage | worker:record_failure → crash:save | 存储正常时 YES | crash 文件/replay；存储失败为独立缺陷 |
| Recipe | Primary + 具体操作 | Replay | recipe:regenerate → mutation:apply_operations | YES | 40/40 审计配方；recipe 测试 |
| 原 crash + 兼容 artifacts | Binary/build 集 | 执行 replay | recipe:execute_file → executor:run/4 | 固定构建范围 YES | fresh-replay.log |
| Worker report | Map | API caller | campaign_done → gen_server:reply await | YES | fuzzer:26–39 |

矩阵显示一套工作系统，缺持久生命周期且隔离有限。支持模式下未发现 mutator → executor → coverage → active corpus 的独立断层。

## 11. 端到端验证结果

### 已运行命令

所有命令从 efz/ 运行。标准检查针对当前有修改源码，生产代码未改变。

| 命令 | 本次结果 | 证据 |
|---|---|---|
| erl -noshell 配 system_info；rebar3 version | OTP 27、ERTS 15.0；Rebar3 3.25.0 | 环境诊断输出 |
| rebar3 compile | PASS | 应用编译成功，exit 0 |
| rebar3 eunit | PASS：62 tests | [eunit.log](../../audit-2026-09-12/eunit.log) |
| rebar3 ct | PASS：3 tests | [ct.log](../../audit-2026-09-12/ct.log) |
| rebar3 xref | PASS，exit 0 | [xref.log](../../audit-2026-09-12/xref.log) |
| rebar3 dialyzer | PASS，exit 0；分析 26 文件 | [dialyzer.log](../../audit-2026-09-12/dialyzer.log) |
| escript examples/automatic/run.escript | PASS：completed，500 次执行、4 发现、2 crashes、1 unique、0 infra/timeouts | [存档汇总与父链接](../../audit-2026-09-12/random-example-summary.txt)；_build/example-report.term |
| escript examples/staged/run.escript | PASS：completed，200 次执行、5 发现、7 crashes、1 unique；实际 replay | [staged-example.log](../../audit-2026-09-12/staged-example.log) |
| escript /tmp/efz-audit-20260912/run.escript /tmp/efz-audit-20260912 | 诊断断言 PASS，包括确认已有缺陷 | e2e.txt 及相邻 *.txt |
| escript /tmp/efz-audit-20260912/fresh-replay.escript /tmp/efz-audit-20260912 | PASS，新 VM，精确 CRASH，一个 automatic probe | [fresh-replay.log](../../audit-2026-09-12/fresh-replay.log) |
| escript /tmp/efz-audit-20260912/edge-cases.escript /tmp/efz-audit-20260912 | 复现过早耗尽、忽略配置、存储失败；诊断 exit 0 | [edge-cases.log](../../audit-2026-09-12/edge-cases.log) |
| escript examples/cowboy/run.escript ../cowboy check | 前置条件 BLOCKED，exit 1；14 目标检查未执行 | [cowboy-check.log](../../audit-2026-09-12/cowboy-check.log) |

Cowboy launcher 的精确错误：

~~~text
Missing build artifact: /home/anonymous_usr/erl:fuzz/efz/../cowboy/ebin/cowboy_req.beam
Run make in COWBOY_DIR first.
~~~

本审计未构建外部 Cowboy 或下载其依赖。证明 EFZ 自身循环无需它：真实普通 audit target 已编译、插桩并经独立 harness 执行。历史 14 项 Cowboy 检查和文档性能值不作本次结果。

### 逐项检查要求的实验

| 步骤 | 状态 | 观察 |
|---|---|---|
| 1. EFZ 启动 | PASS | efz:start/1 接受 audit_harness 与 automatic artifacts |
| 2. 初始 corpus 加载 | 经现有 API PASS | Caller 读 seed.input；corpus id=1、input=<<>> |
| 3. Mutator 改 seed | PASS | 标准 dictionary_insert；未用自定义测试 mutator |
| 4. 输入到 harness | PASS | 观察者收 41 delivered 事件；seed + 40 重建候选逐字节相等 |
| 5. Harness 调 target | PASS | audit_harness:run/1 → 普通 audit_target:parse/1 |
| 6. 覆盖变化 | PASS | unknown/A/AB/ABC/CRASH 的 function_clause probes 不同 |
| 7. 检测新覆盖 | PASS | 三成功 discoveries |
| 8. 输入加入 corpus | RAM 内 PASS，磁盘缺失 | ID 2,3,4 带 new_coverage 元数据；核心不写成功 corpus 文件 |
| 9. 新输入被选作 seed | PASS，直接证据 | AB.parent=2 (A)、ABC.parent=3 (AB)，配方确认 |
| 10. Crash 保存 | PASS | 精确五字节 CRASH、.term、.recipe |
| 11. Crash replay | PASS | regenerate + execute_file；独立新 VM 返回 error(test_crash) |
| 12. Restart 后 corpus | 所需持久功能 FAIL | 新活动只保留初始 seed：size=1 |

未用 mock saver 或手工把 discovery 入队来替代缺失磁盘路径。活动内循环单验，因为其存在不依赖持久存储。写最终审计报告不算 corpus 持久化实现。

自定义活动以 {mutation_exhausted,mutation_exhausted}、executions=40 结束；**本实验**确实耗尽四条目全部 dictionary_insert 候选（4+8+12+16）。这是正常结束，不同于另一案例仍有 bitflip 未执行却同样状态。

### 逐组件测试

| 组件 | 现有测试 | 已证明 / 缺失 |
|---|---|---|
| 旧 mutator | efz_mutator_tests | Binary 输出/空 seed；检查很浅 |
| 变异原语 | efz_mutation_tests:operators、limits、bit_model、block_model、boundaries | 具体向量、独立模型、endian/overflow/大小边界 |
| Staged plan | enumeration、fairness、finite、random_state、noop_stack、growing_corpus、duplicate_donors | Lazy 游标、确定顺序、PRNG 独立、手动增长条目 |
| 配方 replay | efz_recipe_tests、phase3 fresh_replay/replay_boundaries | 操作往返、无效数据、新 VM、真实 crash |
| Corpus | Phase2/phase3、smoke、backend 变体 | Discovery 插入和报告；无独立 corpus 单元/persistence 测试 |
| 覆盖 compiler / 语义 | efz_phase2_tests | Clause kinds、源码映射、同行不同 probe、strict AST、普通/插桩 outcomes、builds |
| 覆盖 runtime | efz_backend_tests、phase2 lifecycle、CT | ETS 变体、prepared/reference、并行 context、target/caller kill、timeout |
| Worker / mutator 错误 | phase3:mutator_failure、exhaustion；smoke | 基础设施分类、budget/skip 计数 |
| Harness | 示例适配器/活动；efz_config 目标验证 | 真实 run/1；无通用 CLI/源码 loader |
| Timeout | executor_tests、phase2、backend、CT | 根 DOWN、覆盖保留、表清理；无树清理 |
| Crashes | Phase2 活动、phase3 活动/replay、CT | 原始存储、异常、继续、crash-only 覆盖策略 |
| 全闭环 | Phase3 真 staged，phase2/CT scripted | 真循环存在，但标准 EUnit/CT 无明确“发现条目随后当父”断言 |

关键区别：phase2/CT 用 efz_scripted_mutator，忽略所选 parent，按 iteration 给预录候选；验证反馈/插入但非祖先关系。Phase3 用真 planner 验 discovery/recipe/replay，growing_corpus_test 无 target/feedback 手加入条目。**标准套件没有同时证明 discovery 及后续用同一条目的独立测试。** 审计复现器已加入，但不在 rebar3 eunit/ct 中。

### 复现审计诊断

诊断 target/script 源码保存在 docs/audit-2026-09-12。不入 src_dirs、不改 EFZ，也非新功能。run.escript 有意检查现有限制，并清其泄漏测试进程。

~~~sh
rebar3 compile
EFZ_AUDIT_DIR=$(mktemp -d /tmp/efz-full-audit.XXXXXX)
cp docs/audit-2026-09-12/audit_*.erl "$EFZ_AUDIT_DIR/"
cp docs/audit-2026-09-12/*.escript "$EFZ_AUDIT_DIR/"
escript "$EFZ_AUDIT_DIR/run.escript" "$EFZ_AUDIT_DIR"
escript "$EFZ_AUDIT_DIR/fresh-replay.escript" "$EFZ_AUDIT_DIR"
escript "$EFZ_AUDIT_DIR/edge-cases.escript" "$EFZ_AUDIT_DIR"
~~~

每个 escript 独立 VM。修缺陷后要更新负向审计断言；当前诊断 PASS 不表示“无 bug”。

## 12. 死代码 / 并行实现

| 同概念的实现 | Runtime 联系 | 审计后建议 |
|---|---|---|
| efz_mutator_random / efz_mutation_plan + efz_mutation | 两者都用，默认 random、可选 staged | 目前 KEEP 两者；P0 后 MIGRATE 用户推荐到验证 staged；不突然删兼容 |
| efz_executor:run/3 / run/4 | run/3 是 manual run/4 wrapper，不是第二 runner | KEEP；文档说明 wrapper 丢元数据 |
| Manual efz_cov:hit / 自动 PT hooks | 共 runtime/ETS，manual 身份空间不同 | KEEP 明确兼容；DEPRECATE 新 automatic 活动用 manual |
| ETS insert / ets_member | 同 cov_rt/context/executor 的后端开关 | KEEP；已有差分测试 |
| 每例验证 / 准备验证 | 同 whitelist 契约，默认 prepared | KEEP 参考路径做差分正确性 |
| efz_cov:interesting/2 / efz_feedback:evaluate/3 | 首 helper runtime 不用，权威决策在第二 | DEPRECATE 闲置 helper；查外部 callers 后才 DELETE |
| efz_cov:reset_local/0、snapshot/0 | 旧独立 helper，当前活动/测试不用 | DEPRECATE；reset_local 不清已附 context，再调用 raises context_already_attached |
| efz_stats:handle_cast({inc,...}) / 公开 call inc | 有 cast handler，但公开同步 call | 查使用者后 DELETE 或说明；不影响现闭环 |
| efz_scripted_mutator / bench:efz_perf_replay / 生产 mutators | Scripted/预录仅 test/bench | KEEP 测量与精确夹具；不作真实变异搜索证据 |
| bench/efz_perf*、报告/剖析脚本 | Escripts 显式加载，非 OTP 服务 | KEEP 与 core 分开 |
| 文档中 calibration/stability collector 建议 | 无对应生产模块 | KEEP 为设计，不算已实现组件 |
| efz.worktrees/agents-condemned-silverfish | 相同快照复制，不是另一 runtime | 由所有者决定 KEEP；审计不删除 |

未找到多份 corpus 实现、隐藏旧 worker pool、第二覆盖 collector 或别的编排语言。UNUSED 检索只限本仓库；export 意味理论上可有外部 caller。

## 13. 缺陷与架构缺口

### 三个主要架构缺口

**G1. 可用活动生命周期不全。** 核心 API 收 bytes，成功进度仅 RAM；通用目标/config + 种子目录 → 持久 corpus → restart 路径未实现。但运行时 retain→reuse 已可用。相关：efz.erl、efz_config.erl、efz_corpus.erl、示例启动器。

**G2. 执行/覆盖完整性契约不全。** 普通路径根隔离正确，但异步子进程、协调器丢失、共享状态及断开/替换插桩妨碍对输入可靠归因。Erlang/OTP 有用工作常在其他进程，因此尤重要。相关：executor、cov_rt、cov_manifest、instrument、harness 契约。

**G3. 调度进度及回归证明。** Staged 已集成且可重放，但全局 idle cutoff 可早于有效 lane 停止。标准测试未断言 discovered seed → next mutation 祖先关系，遗漏该缺陷。相关：mutation_plan:next/visit、worker staged、phase3/mutation 测试。

### 具体发现

| ID / 优先级 | 发现与后果 | 证据 / 可信度 |
|---|---|---|
| F01 / P0 | 成功 corpus 不跨重启；无外部报告/export 就丢搜索主成果 | corpus:9–14；运行时 restart size 4→1 |
| F02 / P0 | 全局 idle cutoff 停可用阶段；256 合法 seeds 得 0 mutations | mutation_plan:51–77；真实 edge-cases 活动 |
| F03 / P1 | 杀协调器已返回基础设施结果，根却活着 | executor:9–23,31–60；coordinator_kill.txt |
| F04 / P1 | 无子覆盖/清理；子超时后存活 | executor:31–85；child_timeout.txt、linked_child.txt |
| F05 / P1 | 共享 VM 状态改变同输入复跑覆盖 | Executor 无 reset；cross_case_state.txt |
| F06 / P1 | 有效未调用产物 completed/empty，却无断开目标诊断 | config:35–48；manifest 验证；disconnected_artifacts.txt |
| F07 / P1 | 普通模块热替换不使准备 builds 失效；独立 harness 未固定 | instrument:115–127；manifest:72–85；recipe:97–108；hot_reload.txt |
| F08 / P1 | 捕获 malformed context 可变成成功空覆盖 | cov_rt:26–27；caught_malformed_context.txt |
| F09 / P1 | 存储错杀 worker；无原子产物组；触发输入可丢 | crash:17–23；edge-cases enotdir |
| F10 / P1 | 顶层 function/arity/max_input_bytes/corpus_dir 接受却忽略 | config:7–15,29–33；edge-cases IGNORED_CONFIG |
| F11 / P1 | Random 输入无统一契约上限；存 >1MiB 输入不通过 execute_file replay | config:29–33、worker:37 对比 recipe:87,113–114；仅代码 |
| F12 / P2 | Worker_down 报告 infra counter=0；coordinator_down 可被 build mismatch 掩盖 | fuzzer:34–39；feedback:5–7,22；enotdir 证据 / 代码 |
| F13 / P2 | 无初始 seed 去重；重复 ID 共 staged 内容游标 | corpus:9–14；plan:68；duplicate_initial_seeds.txt |
| F14 / P2 | 单一 crash signature 反复也无限增长决策；random 默认预算 infinity | worker:75–79,94–105；config 默认；仅代码 |
| F15 / P2 | Signature 含易变 stack path/reason，完全相同 bug 可不同 ID | crash:fingerprint/3；仅代码 |
| F16 / P1 测试缺口 | 无标准直接祖先 E2E、corpus 持久/重启、树清理/owner-kill 回归 | 全测试模块审查；新 audit 复现器 |

并非以上限制都违背文档：根范围、固定构建、手工 launcher、有界 idle 策略均有说明。但相对于要求的完整 fuzz 流水线，它们确为限制。结论来自调用链和当前真实运行。

仓库没有当前树的 CI 执行证据；本地 62+3 通过不等于远程 CI 通过，也不保证任意 OTP 目标适用。

## 14. 成熟度评估

等级：0——无；1——最小片段；2——部分可用；3——有重要限制的可用 MVP；4——声明范围内工作良好且验证的子系统；5——完整要求契约、回归覆盖、稳健生命周期。评分不是性能基准。

| 组件 | 评分 0–5 | 原因 |
|---|---:|---|
| Harness API | 3 | 真 run/1 behavior、验证、适配器；无通用 launcher/源码 loader/reset，选择仅模块 |
| 输入交付 | 4 | 41 次交付确认精确 binary；无统一 size/replay 上限、种子文件导入 |
| 执行隔离 | 1 | 仅新 root/coordinator；无 children/shared state/VM 隔离，杀 owner 遗 root |
| 覆盖收集 | 4 | 精确每例源码探针、manifest 映射、backend/lifecycle 测试；仅 root、有限 AST |
| 覆盖反馈 | 4 | 精确差并及失败策略可用；无稳定性验证/断开代码检测 |
| Corpus 管理 | 2 | 内存 append/dedup/select/metadata；无 persistence、restart、初始 dedup、生命周期元数据 |
| Corpus 反馈环 | 4 | 直接证明 A→AB→ABC；仅 active RAM，不是持久工作流；scheduler cutoff 限其他活动 |
| 变异引擎 | 3 | 丰富 primitives/stages/havoc/splice/recipes 与模型；调度耗尽缺陷显著 |
| 崩溃处理 | 3 | Error/throw/exit/timeout 存储和继续可用；写不原子、故障路径弱、VM 崩溃未涵盖 |
| 可重放性 | 4 | 精确 staged 变异、新 VM crash replay；无 random recipes/campaign resume/harness pin |
| 并发安全 | 3 | 单 worker 串行及 scoped ETS 已测；多 worker 拒绝，树生命周期未解决 |
| 端到端集成 | 3 | Core 闭环已实通；包装、持久、大范围 OTP 隔离未完 |

当前为有界同步目标的集成研究 MVP。称 EFZ 仅是松散原型不对；称为已就绪的通用 OTP 应用 fuzzer 也过早。

## 15. 建议开发方向

**下一阶段：基于已有引擎的可靠、可持久、可验证单 worker 活动。**

P0 应锁定工作闭环，消除合法配置令其无法工作的情形：祖先 E2E、过早耗尽、真实种子导入、持久保留、重启复用。同时需在现有 run/1 上的最小通用 launcher，不是新 harness framework。

P1 重边界正确性：统一字节限制、原子且错误感知存储、root/后代清理、插桩违规、固定 target/harness builds、可复现 replay。首个支持模型应明确为同步 binary harness，不应通过无上下文 spawn 暗中扩展到任意 OTP 应用。

重复稳定性校准可作后续正确性功能，但完成现闭环不需大新 collector。应先保证 source identity、每输入范围、清理可靠。现 calibration-readiness.md 是需求资料，不是已实现稳定功能的证据。

P2 性能工作——corpus 索引、mutation_entries/0 开销、binary 转换、ETS hook 调优——在正确性 gate 后。P3 高级调度、P4 distributed/UI 不在本阶段提案。

## 16. 按优先级实施计划

以下仅下一阶段建议，本审计未改生产实现。

| 任务 | 解决问题 | 受影响文件/模块 | 预期行为 | 测试/证据 | 优先级 |
|---|---|---|---|---|---|
| T1. 标准祖先端到端 gate | 测试未证明发现输入复用 | test/efz_phase3_tests.erl 或新集成套件；简单 fixture/harness | 真 staged 得 A、保留，由该确切 A 产 AB，AB 可产 ABC；精确交付与真覆盖 | Assert 父 ID + primary 字节/hash + recipe 输出；禁 scripted；独立新 replay | P0 |
| T2. 修无进展标准 | max_idle_visits 早于有效 lane 停止 | src/efz_mutation_plan.erl；test/efz_mutation_tests.erl；集成 | 无效阶段不妨碍访问有效阶段；真耗尽与 idle-budget 原因区分；有限空搜索有界 | 256-seed 必须做 bitflip；空 corpus/字典、无 donor、真正穷尽 sweep | P0 |
| T3. 最小通用 launcher + 严格 schema | 用户无法常规指定 harness source/code path、seeds/outdir；未知键忽略 | 新 scripts/fuzz.escript 或 efz_cli；src/efz_config.erl、README、示例 | CLI/config 指定 run/1 模块、路径/产物、种子目录、模式、限制、timeout、输出；原字节读取，拒未知 | 外部最小 run/1 黑盒新 VM；缺 module/export/file、非法 config、无 artifacts | P0 |
| T4. 持久 corpus 保留/恢复 | Stop/restart 丢发现 | src/efz_corpus.erl、src/efz_worker.erl、config；必要时新 corpus store | 内容寻址精确 .input + 版本 metadata，在 durable ACK 前保存；加活跃队列；重启无重复加载发现 | A 发现后 kill/restart，A 加载并当父；检测 corrupt/partial；明确 build 策略 | P0 |
| T5. 统一输入/存储故障契约 | Random 无上限、crash 写错丢 context、产物部分 | config、worker、crash、recipe、corpus store | Seeds/mutations/replay 同上限；单记录原子；结构错误含 trigger input/hash、操作/路径；不能 infra=0 假成功 | 0/max/max+1；enotdir/只读/存储失败；可用存储保 exact crash；中断恢复 | P1 |
| T6. 证明执行清理 | 协调器丢失/timeout 遗根/子 | executor、target contract；lifecycle 测试；必要独立 runner/guardian | 清理所有权超越 coordinator；确认根及支持后代 DOWN。不安全则不复用脏 runner；泛 async 需失控时销毁独立 VM | Owner kill、root trap_exit、有/无链接子、timeout/cancel；完成/中止无目标活着；定义状态 A→B→A | P1 |
| T7. 明确覆盖/harness 有效性 | 空反馈遮盖断接；热加载/PD 破坏不可见 | config、instrument、cov_manifest、cov_rt、executor；tests/docs | 固定 harness identity/builds；检违规；全无反馈明确诊断；真空与 missing/broken 区分；scope/termination/cleanup 元数据 | 未用 artifact、普通替换、擦除/畸形 context、真有效空；插桩非法失败关闭 | P1 |
| T8. 完善 crash/replay/report 契约 | 动态签名、无界重复决策、多种失败来源 | crash、worker、fuzzer、stats、recipe、scripts/replay.escript | 原输入权威；签名与 occurrence/provenance 分离；重复有界/聚合；留基础设施首因/计数；显式 CLI replay 验 target+harness | 同签名不同输入；同 build replay 与拒 mismatch；worker_down 计数/原因；长运行报告有界 | P1 |
| T9. 可复现 release gate | 本地检查不自动运行，缺口可复发 | 平台 CI、必要 rebar.config、docs | 指定 OTP 上 compile/EUnit/CT/xref/Dialyzer + T1/T2/storage/restart/lifecycle；Cowboy 独立辅助套件 | CI 日志/产物带 source/build 身份、精确命令、祖先见证、新 replay | P1 |

T4 最小正确恢复是加载已持久输入并新活动校准。在全局覆盖、ID、游标、RNG 分别序列化/versioned 前，不能称“精确续原 schedule”。完整 checkpoint 可在可复用磁盘 corpus 证明后独立进行。

T6 不能以“子进程不在范围内”充当树清理验收。通用 async runner 前可显式限目标、拒契约违规；若下版声称 async timeout 后同 VM 继续，就必须实现并验证相应清理。

## 17. 下一阶段验收条件

下列清单是下版 release gate。部分已在现同步内存范围成立，但最终实现须全部自动测试确认。

- [ ] EFZ 通过通用 CLI/config 接 target/harness；支持回调契约明确，module/export、产物可用性验证。
- [ ] 初始种子文件按 binary 读取并入活 corpus；重复、非法路径行为确定。
- [ ] Corpus 种子确实交标准变异引擎。
- [ ] 变异 binary 与 harness 所收逐字节相同。
- [ ] Harness 调用真插桩 target；完全断开反馈有诊断。
- [ ] 每具体输入独立收覆盖，验证 build/source identity。
- [ ] 一输入覆盖不污染另一输入；验 scope/shared-state policy；missing/broken 不当真空。
- [ ] 成功 outcome 的新覆盖是 CurrentCoverage − GlobalCoverage；全局更新确定。
- [ ] 新覆盖输入落盘并入活 corpus，含 parent/content/build 元数据。
- [ ] **这个新生成、由覆盖发现的输入随后真的被选择成为下一变异父；测试验父 ID、精确 primary 字节和结果。**
- [ ] 重启加载已存发现输入，可作未来 parent；恢复与精确活动续跑区分。
- [ ] Scheduler 不在访问尚可用有效阶段前宣告耗尽；256-seed 回归执行真变异。
- [ ] Crash 保 exact 触发输入；存储失败明确基础设施结果并保原因。
- [ ] 已存 crash 在兼容 target/harness builds 的新 VM 重放成功。
- [ ] 配方无 live corpus/RNG 仍确定重建，拒 mismatch/corruption。
- [ ] Timeout/cancel/coordinator loss 在支持模型及后代范围内不遗活 target；无清理证明禁止 reuse。
- [ ] 报告/计数区分 invalid instrumentation、变异失败、目标失败、基础设施失败。
- [ ] 端到端验证全循环、落盘、重启复用、新 VM crash replay，不 mock target/mutator/coverage/corpus。

**阶段完成标准：**一个可复现测试跑通种子文件 → 真变异 → 真 harness/target → 每输入覆盖 → 成功发现 → 持久 + 活跃 corpus → 从发现父输入变异；第二次运行复用同一持久输入。本审计已证明内部链路，下一阶段应保留它并消除已确认缺口。
