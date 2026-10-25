# EFZ 仓库地图：目录与文件

[English](../../repository-map.md) · [Русский](../ru/repository-map.md) · [Español](../es/repository-map.md) · **简体中文** · [所有语言](../README.md)

各文件的用途已根据 **2026 年 9 月 15 日**的工作树核对。
本文的根目录是 `efz/`；相邻的检出目录（如 `../cowboy/`）
不属于 EFZ。说明涵盖 **186 个项目文件**（包括本文）
和 **21 个子目录**，包含尚未加入 Git 的源文件、
测试、示例、文档以及保存的验证证据。

下文逐一说明文件的用途和实现的功能；对于数据文件，
则说明其内容和使用者。Git 内部文件以及不断变化的构建输出
按类别单独介绍：测试目录名、日志和 BEAM 文件
会重新生成，不计入这 186 个项目文件。

组件关系、状态归属和 UML 图见
[架构说明](architecture.md)。本地图回答“东西在哪里”，
架构说明回答“它们如何协作”。

## 导航

- [目录树与根目录文件](#root)
- [src — 运行时与插桩构建](#src)
- [scripts — 用户命令](#scripts)
- [test — 自动化检查](#test)
- [fixtures — 测试目标与数据](#fixtures)
- [examples — 演示集成](#examples)
- [bench — 性能测量](#bench)
- [docs — 文档、UML 与历史档案](#docs)
- [生成文件与内部文件](#generated)
- [如何定位功能修改位置](#changes)

<a id="root"></a>
## 目录树与根目录文件

```text
efz/
├── src/                      运行时、契约与插桩
├── c_src/                    外部工作进程的 Linux 生命周期辅助程序
├── priv/                     有界外部监督器/控制器
├── scripts/                  准备、活动/重放 CLI 与覆盖率基准
├── test/                     EUnit 与 Common Test
├── fixtures/                 人工测试目标
│   ├── include/              编译检查用 include 文件
│   ├── external/             独立 BEAM 与 P1-01 原生崩溃测试夹具
│   ├── hit_count/            计数反馈测试与基准目标
│   └── performance/          基准用解析器与稀疏目标
├── examples/                 独立使用示例
│   ├── automatic/            具有自动覆盖率的随机活动
│   ├── simple_parser/        普通解析器与最小 harness
│   ├── staged/               分阶段活动、字典与崩溃重放
│   │   └── corpus/           快速入门的五个原始种子
│   └── cowboy/               与外部 Cowboy/Cowlib 的集成
├── bench/                    测量、剖析与报告驱动程序
├── docs/                     架构与子系统契约
│   ├── adr/                  架构决策
│   ├── diagrams/             Mermaid UML 源文件与已渲染 SVG
│   ├── examples/             保存的崩溃输入与配方对
│   ├── performance/          已记录的测量结果
│   ├── coverage-audit-2026-09-15/  诊断目标与探针集合审计证据
│   └── audit-2026-09-12/     历史诊断与结果
├── _build/                   生成的构建、测试数据与日志
└── .git/                     Git 内部状态
```

| 文件 | 职责 | 内容与用法 |
|---|---|---|
| [.gitignore](../../../.gitignore) | Git 排除规则 | 排除 `_build`、BEAM、PLT、日志、崩溃转储、Erlang cookie 和编辑器文件。这些是文件跟踪规则，不是模糊测试活动配置。 |
| [LICENSE](../../../LICENSE) | 项目许可证 | Apache License 2.0 正文；与 `efz.app.src` 中的许可证标识一致。 |
| [README.md](README.md) | 文档主入口 | 构建、启动器、harness、插桩、分阶段变异、重放以及详细契约的链接。 |
| [rebar.config](../../../rebar.config) | Rebar3 构建与检查 | 要求 OTP 27 或更高版本，启用 `debug_info`、警告视为错误、EUnit、Xref 和 Dialyzer。`src_dirs` 包含 `src` 和 `examples/simple_parser`；Linux 前置钩子构建 `c_src/efz_vm_launcher`。没有外部 Erlang 依赖。 |
| [rebar.lock](../../../rebar.lock) | 依赖锁定 | 当前为 `[]`：没有固定的外部 Rebar 依赖。该文件由 Rebar3 管理。 |

<a id="src"></a>
## src — 运行时与插桩构建

[src/](../../../src) 目录包含主应用的 **35 个文件**。一个模块文件
不一定对应独立进程：下文明示 `gen_server` 模块；
变异器、反馈、配方和文件系统辅助模块作为普通函数调用。

### 启动、配置与活动控制

| 文件 | 职责 | 已实现功能与运行时角色 |
|---|---|---|
| [efz.app.src](../../../src/efz.app.src) | OTP 应用描述符 | 应用名称与版本、`efz_app` 回调、已注册服务以及 `kernel`、`stdlib`、`crypto` 依赖。Rebar3 据此生成 `efz.app`。 |
| [efz.erl](../../../src/efz.erl) | 公共 Erlang API | `start/1` 启动应用和活动；`await/1` 等待报告，`stats/0` 读取统计，`stop/0` 停止活动与应用。 |
| [efz_app.erl](../../../src/efz_app.erl) | OTP 应用生命周期 | `start/2` 回调创建 `efz_sup`；`stop/1` 完成应用回调。不包含变异循环。 |
| [efz_sup.erl](../../../src/efz_sup.erl) | 根监督器 | 初始子进程列表为空；`efz:start/1` 添加临时的 `efz_fuzzer`。重启强度为零的 `one_for_all` 策略不会恢复活动状态。 |
| [efz_cli.erl](../../../src/efz_cli.erl) | 通用启动器 | `main/1` 解析选项，有界读取原始种子，检查路径与产物，调用 `efz:start/1`，保存 `report.term` 并返回退出码。没有自己的模糊测试引擎。 |
| [efz_external.erl](../../../src/efz_external.erl) | 受监督 CLI 边界 | 查找目标前通过 `spawn_executable` 启动仅基于文件的控制器，传递显式 argv 并处理父进程死亡 ACK。在非 Linux 系统返回清晰错误。 |
| [efz_external_worker.erl](../../../src/efz_external_worker.erl) | 工作进程入口与必需屏障 | 仅在子 BEAM 中执行：验证身份、启动普通 CLI/活动，实现有界 HELLO/READY/PREPARE/RUN/RESULT 协议。旧执行器直接调用闭包。 |
| [efz_config.erl](../../../src/efz_config.erl) | 严格活动模式 | `prepare/1` 检查已知键、`run/1`、工作进程、限制、变异配置及覆盖率产物；恢复持久语料并生成规范化配置。不支持 `function` 和 `arity`。 |
| [efz_fuzzer.erl](../../../src/efz_fuzzer.erl) | 活动协调器，`gen_server` | 创建互相链接的语料、统计和工作进程监督器进程；监控工作进程、处理 `await`、汇总最终报告并停止服务。单个输入由执行器运行。 |
| [efz_worker_sup.erl](../../../src/efz_worker_sup.erl) | 工作进程监督 | 创建一个临时 `efz_worker`，由 `one_for_one` 监督。名称不表示已实现并行进程池：活动模式仅允许 `workers => 1`。 |
| [efz_worker.erl](../../../src/efz_worker.erl) | 主模糊测试循环，`gen_server` | 校准所有种子 → 调度 → 变异 → 执行器 → 反馈 → 语料/崩溃存储。拥有全局覆盖率、分阶段游标/RNG、崩溃组/计数及有界代表输入、变异轨迹与决策；处理基础设施故障。 |
| [efz_stats.erl](../../../src/efz_stats.erl) | 计数器，`gen_server` | `inc/1`、`failure/1` 与 `get/0` 管理执行、校准、发现、拒绝、崩溃次数/组、超时与基础设施故障；首个基础设施原因单独保存。变异专用计数归计划器/工作进程所有。 |

### Harness、输入与执行

| 文件 | 职责 | 已实现功能与运行时角色 |
|---|---|---|
| [efz_target.erl](../../../src/efz_target.erl) | Harness 契约 | behaviour 提供 `run(binary()) -> term()` 回调。用户模块实现回调，配置检查导出。还提供 `spawn/1`、`spawn_link/1` 创建受控后代，以及 `dirty/1` 声明外部副作用。 |
| [efz_input.erl](../../../src/efz_input.erl) | 统一输入大小上限 | `check/3` 检查二进制与包含端点的限制；`read_file/3` 有界读取文件。默认 4096，允许 0..1048576；不截断字节。用于摄取、语料、执行器、变异、重放和崩溃存储。 |
| [efz_executor.erl](../../../src/efz_executor.erl) | 单输入执行 | 注册了受监督 broker 时，`run/4` 先经过外部屏障，再创建原有 guardian。最终清理结果和 guardian DOWN 后才返回；丢失 guardian 会将 VM 标记为污染。`run/3` 为兼容包装器。 |
| [efz_guardian.erl](../../../src/efz_guardian.erl) | 生命周期所有权 | 拥有根/受控后代、启动门、监控器、观测 ETS 与跟踪屏障。独立于调用者/协调器清理，检查共享状态违规，并禁止复用污染 VM。 |

### 覆盖率：编译、运行时钩子与反馈

| 文件 | 职责 | 已实现功能与运行时角色 |
|---|---|---|
| [efz_instrument.erl](../../../src/efz_instrument.erl) | 构建与加载插桩产物 | `compile/2` 将所选源文件编译到独立 outdir；`discover/1`、`load/1`、`preflight/1` 查找并验证 BEAM/sidecar、构建身份及加载的代码。在活动前运行，不在每次变异时运行。 |
| [efz_instrument_pt.erl](../../../src/efz_instrument_pt.erl) | 编译器 `parse_transform` | 遍历 Erlang AST，插入子句/结果探针，创建构建 ID 和源清单。检查允许列表、重复插桩及不支持语法；严格模式拒绝不完整覆盖。 |
| [efz_cov_manifest.erl](../../../src/efz_cov_manifest.erl) | 清单与允许的覆盖率空间 | 验证模式和探针身份，提取嵌入清单，将观测探针与构建匹配。`prepare/2` 创建带保护 ETS 的可复用验证计划；`release/1` 释放该计划。 |
| [efz_cov_integrity.erl](../../../src/efz_cov_integrity.erl) | 覆盖率观测完整性 | 固定所加载 harness/构建身份，维护独立受保护的 PID/上下文注册表及上下文/代码加载跟踪，区分有效空观测与损坏观测。 |
| [efz_cov_rt.erl](../../../src/efz_cov_rt.erl) | 已插入探针的运行时钩子 | `hit/1` 根据 PID 注册表验证上下文。presence 使用 ETS 集合；可选 hit-count 按精确身份使用原子 ETS 计数。上下文/表错误和首次命中会通知 guardian。 |
| [efz_cov_count.erl](../../../src/efz_cov_count.erl) | 实验性计数特征 | 验证计数快照并检查其键与精确覆盖率一致；将计数分为八个桶。不拥有进程/表，也不替代 presence 后端。 |
| [efz_cov.erl](../../../src/efz_cov.erl) | 执行覆盖率上下文 | `open`、`attach`、`snapshot`、`detach`、`close` 管理单次执行的表。还包含集合合并和手动兼容辅助函数 `hit/1`、`reset_local/0`、`snapshot/0`、`interesting/2`；运行时决策由 `efz_feedback` 作出。 |
| [efz_feedback.erl](../../../src/efz_feedback.erl) | 覆盖率新颖性 | `evaluate/3` 验证 builds/status 并计算 `Observed − Global`。可选 hit-count 还比较精确桶特征，区分 `new_probe`/`new_hit_count`。目标故障不会扩大全局状态。 |

### 语料与持久存储

| 文件 | 职责 | 已实现功能与运行时角色 |
|---|---|---|
| [efz_corpus.erl](../../../src/efz_corpus.erl) | 活跃语料，`gen_server` | 拥有二进制条目、整数 ID 与元数据。`add/2` 对发现去重，启用存储时先持久化再确认加入；`select/0` 随机选择父输入，`mutation_entries/0` 将条目交给分阶段调度器。 |
| [efz_corpus_store.erl](../../../src/efz_corpus_store.erl) | 持久可复用语料 | `save/4` 按 SHA-256 内容哈希保存精确输入和带校验和的元数据。`restore/3,4` 验证模式、完整性、输入上限与构建策略；返回输入用于重新校准。不恢复旧游标、RNG、覆盖率或整数 ID。 |
| [efz_crash.erl](../../../src/efz_crash.erl) | 崩溃身份与产物 | `identify/3` 区分随机发生 ID、内容哈希与规范化签名 v2；`remember/3` 维护次数及有界代表输入。`save/4` 保存所选代表的原始输入/Reason/配方/预期；每次已提交发生都计入持久摘要。配方错误不会阻止保存选定原始输入。返回带身份和首要原因的结构化错误。 |
| [efz_crash_store.erl](../../../src/efz_crash_store.erl) | 有界磁盘崩溃存储 | 每个签名前 N 个不同输入、不可变产物及含持久计数的 EFZG 摘要。独占目录锁防止不同 VM 同时写入；上限跨重启保留。损坏/未索引/中断状态产生显式错误。 |
| [efz_fs.erl](../../../src/efz_fs.erl) | 通用文件系统原语 | 有界读取、创建目录、write/sync/close、`atomic_file/2` 和 `atomic_group/3`。临时暂存加重命名发布数据；组清单验证完整性。错误包含操作/路径/原因；次要清理不会替换首要故障。 |

### 变异与重放

| 文件 | 职责 | 已实现功能与运行时角色 |
|---|---|---|
| [efz_mutator.erl](../../../src/efz_mutator.erl) | 变异器回调契约 | 随机/回调路径的 behaviour `mutate(binary(), map()) -> binary()`。工作进程通过独立计划器 API 调用分阶段引擎。 |
| [efz_mutator_random.erl](../../../src/efz_mutator_random.erl) | 内置随机变异器 | 有大小限制的翻转、覆盖、插入和删除；支持带种子的 RNG。这是正在使用的默认 Erlang API，不是死代码。输入已满时选择合法操作，不生成超限字节。 |
| [efz_mutation_plan.erl](../../../src/efz_mutation_plan.erl) | 惰性分阶段调度器 | `prepare/2`、`new/1`、`next/2` 维护父输入/阶段游标、RNG、供体、跳过与进度保护；每次生成一个候选。接纳增长的语料，区分真正耗尽与空闲停止；不物化整个变异空间。 |
| [efz_mutation.erl](../../../src/efz_mutation.erl) | 确定性字节操作 | 应用具体 flip/integer/block/dictionary/splice 操作，检查偏移与上限，返回字节、skip 或 error。由计划器和配方重放共用；本身不作随机决策。 |
| [efz_dictionary.erl](../../../src/efz_dictionary.erl) | 字典摄取 | `normalize/2` 验证、排序和去重二进制 token，并计算身份；`load/2` 有界读取带注释的十六进制文件。这是 EFZ 自有格式，不是 Erlang 表达式或 AFL 字典解析器。 |
| [efz_recipe.erl](../../../src/efz_recipe.erl) | 精确变异来源与重放 | `make/4` 记录主/供体字节和哈希、父输入、操作、限制及构建。Encode/decode/load/save 管理 EFZR 封装；regenerate 重建字节，execute/execute_file 用显式目标/构建和必需的预期 harness 身份通过执行器运行。 |
| [efz_replay.erl](../../../src/efz_replay.erl) | 已验证执行重放 | EFZX 预期编解码、可移植 harness 身份、输入哈希及完整构建集和 harness 验证；原始输入/配方通过既有执行器运行，签名决定 reproduced/not-reproduced。 |
| [efz_replay_cli.erl](../../../src/efz_replay_cli.erl) | 重放 CLI | 解析 `--input/--recipe`、显式目标/产物/代码路径/预期；输出结论，区分退出码 0/3/2/1。保留旧的仅字节再生模式。 |

<a id="scripts"></a>
## scripts — 用户命令

[scripts/](../../../scripts) 目录包含 **4 个 escript**。启动器与重放程序根据自身路径
定位已编译 EFZ；覆盖率基准应从仓库根目录
运行。`prepare.escript` 自行构建；其他
脚本要求事先完成构建。

| 文件 | 职责 | 运行时行为 |
|---|---|---|
| [fuzz.escript](../../../scripts/fuzz.escript) | 通用模糊测试命令 | 查找应用 ebin，加载 `efz_cli`，向 `main/1` 传递参数，并用其退出码终止 VM。未构建时输出清晰错误。 |
| [prepare.escript](../../../scripts/prepare.escript) | 构建与首次运行准备 | 检查 OTP/Rebar3，构建 EFZ，为分阶段解析器插桩，复制原始语料而不覆盖不同种子；输出通用 CLI 命令。不自行启动活动。 |
| [replay.escript](../../../scripts/replay.escript) | 重放 CLI 薄包装器 | 根据脚本位置加入已编译 EFZ ebin，调用 `efz_replay_cli:main/1`；不从配方或诊断产物选择目标。 |
| [coverage_bench.escript](../../../scripts/coverage_bench.escript) | 原始覆盖率微基准 | 在 `efz_bench_fixture` 比较普通目标、已插桩未激活钩子与激活 ETS 钩子；将样本、内存与编译时间保存到 `_build/coverage-benchmark.*`。它不是启动器。 |

<a id="test"></a>
## test — 自动化检查

[test/](../../../test) 目录包含 **21 个文件**。`*_tests.erl` 通过
`rebar3 eunit` 运行，`efz_coverage_SUITE.erl` 通过 `rebar3 ct` 运行。测试内带 `run/1`
的辅助模块作为测试 harness；导出它们并不使其成为运行时服务。

| 文件 | 测试功能 | 关键区别 / 场景 |
|---|---|---|
| [efz_config_tests.erl](../../../test/efz_config_tests.erl) | 严格模式与目标契约 | 未知键、无效值、缺少 `run/1`、空语料及从持久输入启动的能力。 |
| [efz_cli_tests.erl](../../../test/efz_cli_tests.erl) | 新 Erlang VM 中的启动器 | 外部 harness、原始种子、分阶段/随机、持久语料、帮助、无效模块/路径/产物/选项、输入边界、崩溃、超时与基础设施故障退出码。 |
| [efz_crash_tests.erl](../../../test/efz_crash_tests.erl) | 发生次数、签名与已验证重放 | 同签名不同输入、Reason 策略、重定位、有界报告中的 1000 次发生、新 VM 中的原始输入/配方、构建/harness 不匹配、损坏/不可读产物、首要协调器/工作进程故障及统计。 |
| [efz_crash_retention_tests.erl](../../../test/efz_crash_retention_tests.erl) | 磁盘保留与 guardian 延迟故障 | 检查磁盘上限/重复/原始 Reason、不同 VM 中的两次活动、保留输入重放、损坏摘要、提交失败、并发/中断写入。在真实 guardian 回复后的测试专用 AST 门证明报告/统计保留首要故障且禁止复用。 |
| [efz_integrity_tests.erl](../../../test/efz_integrity_tests.erl) | 覆盖率完整性 | 22 个回归场景：零命中/断开/未使用、严格策略、字典/ETS 损坏、捕获钩子异常、子进程、重载/恢复、harness 固定、预备计划与直接 ERTS 加载。 |
| [efz_isolation_tests.erl](../../../test/efz_isolation_tests.erl) | Guardian 与受控后代 | 根/子/嵌套生命周期、timeout/trap_exit、调用者/协调器死亡、注册/ETS、新 VM 污染策略、guardian 丢失与禁止复用。 |
| [efz_executor_tests.erl](../../../test/efz_executor_tests.erl) | 基础执行契约 | 简短的 `run/3` 检查：返回、error、exit 与 timeout。这是兼容路径；自动覆盖率由其他测试集更详细验证。 |
| [efz_phase2_tests.erl](../../../test/efz_phase2_tests.erl) | 自动插桩与执行器 | 比较普通/插桩语义、探针种类、清单/构建 ID、includes/选项、尾调用、严格语法、上下文、崩溃/kill/超时覆盖率与活动取消。 |
| [efz_backend_tests.erl](../../../test/efz_backend_tests.erl) | 覆盖率变体等价性 | 比较 `ets`/`ets_member` 和预备/逐次执行验证：精确探针、结果、新颖性、验证计划寿命、后端故障、调用者死亡与清理。 |
| [efz_hit_count_tests.erl](../../../test/efz_hit_count_tests.erl) | 计数反馈集成 | 所有桶、重数/命名空间、多探针增量、受控子进程、崩溃/超时/损坏计数器、变异独立性、真实分阶段父输入复用、持久恢复与新 VM 崩溃重放。 |
| [efz_coverage_SUITE.erl](../../../test/efz_coverage_SUITE.erl) | Common Test 集成 | 三种场景：自动活动、崩溃覆盖率和超时覆盖率。活动使用脚本化夹具；真实多步父输入复用的证据在单独反馈循环测试中。 |
| [efz_mutator_tests.erl](../../../test/efz_mutator_tests.erl) | 基础随机变异器 | 验证非空/空主输入的返回二进制。统一活动上限由 `efz_limits_tests` 检查。 |
| [efz_mutation_tests.erl](../../../test/efz_mutation_tests.erl) | 字节操作与分阶段计划器 | 操作模型、字典、限制、枚举、公平性、有限耗尽、RNG、增长语料、供体及进度保护。包含 256 个种子且首字典通道不可用的回归。 |
| [efz_phase3_tests.erl](../../../test/efz_phase3_tests.erl) | 分阶段运行与崩溃重放 | 真实操作发现、配方保存、崩溃后继续、轨迹独立、新 VM 重放与构建不匹配。活动回归证明跳过字典通道后仍执行并区分停止原因。 |
| [efz_feedback_loop_tests.erl](../../../test/efz_feedback_loop_tests.erl) | 闭合反馈循环 | 真实字典变异 `<<>> → A → AB → ABC`；检查语料 ID/父输入、按执行引用精确送达 harness、主输入哈希/字节和新 VM 重放。不使用脚本化变异器。 |
| [efz_recipe_tests.erl](../../../test/efz_recipe_tests.erl) | EFZR 与确定性重建 | 全部操作、配方损坏、模式/哈希/上限验证、新 VM 再生及调用重放脚本时的大小限制。 |
| [efz_corpus_store_tests.erl](../../../test/efz_corpus_store_tests.erl) | 持久存储与完整性 | 往返、重复、元数据形状/哈希/模式、缺失/截断文件、构建策略及中断写入。验证持久化失败不会将未确认条目加入活跃队列。 |
| [efz_durable_tests.erl](../../../test/efz_durable_tests.erl) | VM 重启后语料复用 | 多个独立 VM：发现 `A` 后保存，再恢复、校准并成为 `AB` 的父输入，获得新队列 ID。还检查重复、构建不匹配与输入上限。 |
| [efz_limits_tests.erl](../../../test/efz_limits_tests.erl) | 统一输入限制与存储故障 | 0/max/max+1 边界、随机/分阶段/恢复/重放/执行器/崩溃；拒绝超限回调结果；文件系统错误、回滚、损坏组与中断暂存。写入失败时检查报告中的精确输入与首要原因。 |
| [efz_smoke_tests.erl](../../../test/efz_smoke_tests.erl) | 最小活动生命周期 | 显式手动模式下十次随机执行和正确停止。不证明自动覆盖或实际语料扩展。 |
| [efz_scripted_mutator.erl](../../../test/efz_scripted_mutator.erl) | 固定序列夹具 | 回调按迭代返回预定字节，用于 Phase 2/backend/CT 验收。仅由测试使用；不是生产变异器，也不是分阶段调度证明。 |
| [efz_external_tests.erl](../../../test/efz_external_tests.erl) | 旧版兼容门 | 证明没有外部 broker 不改变执行器返回路径、隔离或就绪状态。 |
| [external_supervisor_test.py](../../../test/external_supervisor_test.py) | 原生 P1-01 验收 | 真实第二 BEAM VM 与 NIF：持久门、SIGSEGV/SIGABRT 恢复/重放、硬超时、污染回收、协议损坏、存储故障、重启预算及父进程死亡清理。 |
| [external_bench.py](../../../test/external_bench.py) | 旧模式/受监督模式比较 | 同一安全目标交替运行三次；分别测量变异/总吞吐和持久准备时间，不禁用 fsync。 |

<a id="fixtures"></a>
## fixtures — 测试目标与数据

[fixtures/](../../../fixtures) 目录包含 **23 个文件（含子目录）**。
这些人工目标由 tests/bench 使用普通编译器或
`efz_instrument` 编译。不纳入应用主 `src_dirs`。

| 文件 | 职责 | 功能与使用者 |
|---|---|---|
| [efz_fixture.erl](../../../fixtures/efz_fixture.erl) | 插桩所需广泛 Erlang 语法 | 子句/守卫、case/if、fun、try/catch/after、receive、二进制、record、宏与尾递归。与观察者同步可在真实探针后测试 kill/超时。底层测试传入 Erlang 项。 |
| [efz_fixture_helper.erl](../../../fixtures/efz_fixture_helper.erl) | 跨模块目标调用 | `classify/1` 区分 zero/other；由 `efz_fixture` 调用，以检查多个所选模块的插桩。 |
| [efz_skipped.erl](../../../fixtures/efz_skipped.erl) | 支持语法限制 | 列表/二进制/映射推导和 `maybe` 表达式验证严格模式拒绝，以及 `strict => false` 下保留语义并报告限制。 |
| [efz_record_default.erl](../../../fixtures/efz_record_default.erl) | Record 默认值中的表达式 | 默认值通过 `case` 依赖进程字典；Phase 2 检查不支持表达式位置的诊断及非严格模式下普通/插桩等价性。 |
| [efz_bench_fixture.erl](../../../fixtures/efz_bench_fixture.erl) | 高频重复探针 | 带 `N band 3` 小分支的数值尾递归循环。覆盖率/性能基准测量反复命中的开销。 |
| [efz_cli_harness.erl](../../../fixtures/efz_cli_harness.erl) | 最小外部 harness | `run/1` 接受二进制并调用 `efz_cli_parser:parse/1`；CLI 测试将 harness 与插桩解析器分开编译。 |
| [efz_cli_parser.erl](../../../fixtures/efz_cli_parser.erl) | CLI 测试目标 | 区分首字节 128 与其他二进制；翻转首位可到达新覆盖。导出 `parse/1`，因此也检查缺少 `run/1` 错误。 |
| [efz_lineage_parser.erl](../../../fixtures/efz_lineage_parser.erl) | 父输入复用回归目标 | 普通 `parse/1` 对 `A`、`AB`、`ABC` 和回退使用不同子句。编译器添加钩子；用于反馈循环和持久测试。 |
| [efz_durable_harness.erl](../../../fixtures/efz_durable_harness.erl) | 多 VM harness | 稳定的 `run(binary())` 调用谱系解析器；独立于前一 VM 测试进程证明恢复与变异父输入复用。 |
| [efz_integrity_target.erl](../../../fixtures/efz_integrity_target.erl) | 插桩完整性测试目标 | 真实 A/B 子句及替代构建；不匹配二进制不进入探针体。 |
| [efz_integrity_harness.erl](../../../fixtures/efz_integrity_harness.erl) | 普通完整性测试 harness | 二进制场景涵盖断开/零命中、上下文损坏、捕获钩子异常、子上下文、同步热重载与单独替代 harness 构建。 |
| [efz_isolation_target.erl](../../../fixtures/efz_isolation_target.erl) | 执行隔离目标 | 真实链接/不链接/嵌套子进程、超时、注册/ETS 与 VM 全局变更的二进制场景。为隔离测试集自动插桩编译。 |
| [efz_limits_target.erl](../../../fixtures/efz_limits_target.erl) | 精确交付与人工崩溃 | 将收到二进制发给注册观察者，返回它或对 `CRASH` 抛错。用于限制与 IO 失败时保留触发输入。 |
| [efz_crash_target.erl](../../../fixtures/efz_crash_target.erl) | 插桩解析器崩溃夹具 | 对 `OK` 返回 ok，对 `WAIT` 等待，其余以数据相关 Reason 崩溃。编译宏生成不兼容构建；源重定位验证签名规范化。 |
| [efz_crash_harness.erl](../../../fixtures/efz_crash_harness.erl) | 普通外部二进制 harness | 调用真实解析器。编译宏改变 harness 身份；测试专用环境在新重放 VM 中选择正常返回、另一错误或基础设施故障。 |

### fixtures/external

`efz_external_target` 和 `efz_external_startup` 定义 SAFE、污染、超时、
普通退出和启动路径。`efz_native_fixture` 是测试专用 NIF，具有受控的
SIGSEGV、SIGABRT 和挂起行为；仅在子验收 VM 中加载。

### fixtures/include

[fixtures/include/](../../../fixtures/include) 用于检查编译插桩目标时
include 路径解析与预处理。

| 文件 | 用途与功能 |
|---|---|
| [efz_fixture.hrl](../../../fixtures/include/efz_fixture.hrl) | `INCLUDED` 宏，含 `case` 和 record `item`。宏使用由编译选项提供的 `MAGIC`；验证源位置保留与展开代码行为。 |

### fixtures/hit_count

五个普通目标/辅助模块用于调用重数检查及受控
反馈比较。测试/基准显式选择插桩范围。

| 文件 | 用途 |
|---|---|
| [efz_count_sites.erl](../../../fixtures/hit_count/efz_count_sites.erl) | 三个函数 x/a/b；编译器各加一个探针。区分命中重数与调度/循环控制探针。 |
| [efz_count_harness.erl](../../../fixtures/hit_count/efz_count_harness.erl) | 未插桩二进制适配器，用于 L 计数、探针对、受控子进程、崩溃/超时及测试计数器损坏。 |
| [efz_count_repeat.erl](../../../fixtures/hit_count/efz_count_repeat.erl) | 相同字节前缀；16 次重复时的独立深层子句。 |
| [efz_count_records.erl](../../../fixtures/hit_count/efz_count_records.erl) | 完整短 record 解析器；八个 record 时的深层子句。 |
| [efz_count_machine.erl](../../../fixtures/hit_count/efz_count_machine.erl) | 重复 tick/ack，八次转换后提交的状态机。 |

### fixtures/performance

[fixtures/performance/](../../../fixtures/performance) 包含不依赖第三方应用的
可复现基准负载。

| 文件 | 用途与功能 |
|---|---|
| [efz_perf_parser.erl](../../../fixtures/performance/efz_perf_parser.erl) | 人工二进制 record 解析器：数值字段、标志、变长载荷、截断/无效 record 及人工错误。为执行器/活动基准提供混合负载。 |
| [efz_perf_sparse.erl](../../../fixtures/performance/efz_perf_sparse.erl) | 已生成但保留在项目中的源：2048 个 `choose/1` 子句加回退。大清单与少量命中测量稀疏覆盖/验证成本；生成器在 `bench`。 |

<a id="examples"></a>
## examples — 演示集成

[examples/](../../../examples) 目录包含 **15 个文件**。示例活动选择
具体目标/种子/选项用于演示；通用用户启动入口是
`scripts/fuzz.escript`。

### examples/simple_parser

[examples/simple_parser/](../../../examples/simple_parser) 是最小组合：
普通目标加 harness。这是唯一纳入 Rebar3 `src_dirs` 的示例，
因此普通 EFZ 构建后两个模块均可用。

| 文件 | 用途与功能 |
|---|---|
| [efz_example_parser.erl](../../../examples/simple_parser/efz_example_parser.erl) | 分类空输入、二进制前缀和文本；对前缀 `255` 故意崩溃。不含 EFZ 调用。`run/1` 保持兼容；主入口为 `classify/1`。 |
| [efz_example_target.erl](../../../examples/simple_parser/efz_example_target.erl) | `efz_target` behaviour harness：`run/1` 将输入交给 `efz_example_parser:classify/1`。用于 shell 示例、冒烟测试和自动覆盖率验收。 |

### examples/automatic

[examples/automatic/](../../../examples/automatic) 展示使用既有随机变异路径的
自动覆盖率。

| 文件 | 用途与功能 |
|---|---|
| [run.escript](../../../examples/automatic/run.escript) | 给简单解析器插桩，从 `<<0>>` 开始执行 500 次随机变异，保存 `_build/example-report.term` 和崩溃，再停止 EFZ。构建后从根目录运行。 |

### examples/staged

[examples/staged/](../../../examples/staged) 展示分阶段操作、
字典发现及实际崩溃复现。

| 文件 | 用途与功能 |
|---|---|
| [efz_staged_parser.erl](../../../examples/staged/efz_staged_parser.erl) | 区分 `TOKEN`、边界/算术值和空输入；前缀 `BOOM!` 触发人工错误。无手动覆盖率钩子的普通目标。 |
| [run.escript](../../../examples/staged/run.escript) | 插桩解析器，执行 200 次分阶段变异，提取崩溃配方，验证精确再生及执行器再次崩溃；在 `_build` 下保存报告/输入/配方/重放预期。 |
| [tokens.hex](../../../examples/staged/tokens.hex) | 二进制 token `TOKEN` 和 `BOOM!` 的两行十六进制加注释。由标准 `efz_dictionary` 读取；它们是变异阶段数据。 |

### examples/staged/corpus

供 `scripts/prepare.escript` 和通用启动器使用的五个原始种子文件。
文档放在目录外，避免 CLI 将其当作种子。

| 文件 | 用途与精确内容 |
|---|---|
| [00-empty.seed](../../../examples/staged/corpus/00-empty.seed) | 空二进制，0 字节；检查空输入路径。 |
| [01-zero.seed](../../../examples/staged/corpus/01-zero.seed) | 一个零字节，边界/算术发现的初始父输入。 |
| [02-near-token.seed](../../../examples/staged/corpus/02-near-token.seed) | 无换行的 `UOKEN`；变异首字节可发现 `TOKEN` 子句。 |
| [03-near-crash.seed](../../../examples/staged/corpus/03-near-crash.seed) | 无换行的 `COOM!`；首字节 bitflip/算术产生人工崩溃 `BOOM!`。 |
| [04-binary.seed](../../../examples/staged/corpus/04-binary.seed) | 十六进制 `00 ff 80 41 0d 0a`；包含 NUL、非 UTF-8 和 CR/LF 的二进制摄取。 |

### examples/cowboy

[examples/cowboy/](../../../examples/cowboy) 适配外部
Cowboy/Cowlib 检出目录。不将库加入 EFZ 依赖，也不启动 HTTP
监听器：目标同步解析查询字符串。

| 文件 | 用途与功能 |
|---|---|
| [README.md](examples/cowboy/README.md) | 外部 Cowboy 准备、检查和启动命令；说明 `parse_qs` 范围、插桩限制及特定构建的历史结果。 |
| [efz_cowboy_target.erl](../../../examples/cowboy/efz_cowboy_target.erl) | 通过最小 Req map 将原始查询字节交给 `cowboy_req:parse_qs/1`。将预期 `request_error`（针对 `qs`/`limit_reached`）转为返回；意外异常仍算崩溃。 |
| [efz_cowboy_checks.erl](../../../examples/cowboy/efz_cowboy_checks.erl) | 百分号解码、二进制字节、重复项和键数的额外 EUnit 检查；比较覆盖率后端，证明真实字典变异发现。由示例 runner 的 `check` 模式调用。 |
| [run.escript](../../../examples/cowboy/run.escript) | 检查外部 BEAM、编译 harness、插桩 `cowboy_req` 和 `cow_qs`，运行检查或分阶段活动。对 Cowboy 使用显式非严格插桩并输出限制。 |

<a id="bench"></a>
## bench — 性能测量

[bench/](../../../bench) 包含测量辅助设施的 **13 个文件**。
普通 EFZ 启动不会运行它们。结果保存在
`_build`；已记录历史样本位于 `docs/performance`。

| 文件 | 职责 | 已实现功能 |
|---|---|---|
| [run.escript](../../../bench/run.escript) | 基准启动器 | 编译本地 `efz_perf*` 辅助模块，选择 `hooks/executor/campaign/memory/startup` 或 `all` 负载以及后端/验证变体。支持 `EFZ_PERF_EBIN` 路径。 |
| [efz_perf.erl](../../../bench/efz_perf.erl) | 主测量驱动 | 构建夹具、检查语义、测量钩子/执行器/活动/启动/内存，保存环境与样本。`canonical/1` 规范化结果用于比较变体。 |
| [efz_perf_loop_target.erl](../../../bench/efz_perf_loop_target.erl) | 数值循环二进制适配器 | 将首字节转为 `efz_bench_fixture` 重复次数，用公式校验结果。为活动基准的二进制契约所需。 |
| [efz_perf_replay.erl](../../../bench/efz_perf_replay.erl) | 固定基准候选流 | `install/1` 将 tuple 输入放入 `persistent_term`，`mutate/2` 按迭代选择，`clear/0` 清理。隔离测量中的变异成本；不是 EFZR 重放或生产调度器。 |
| [generate_sparse.escript](../../../bench/generate_sparse.escript) | 稀疏夹具生成器 | 可复现地写入含 2048 个数值子句的 `fixtures/performance/efz_perf_sparse.erl`。会修改源文件；不必每次模糊测试前运行。 |
| [profile.escript](../../../bench/profile.escript) | `eprof` 剖析 | 编译循环/解析器/稀疏目标，预加载执行路径，剖析钩子或执行器；支持预备验证。剖析结果不是吞吐样本。 |
| [report.escript](../../../bench/report.escript) | 读取基准结果 | 读取本地钩子/执行器/活动的二进制 `.term` 行，输出中位数、原始样本、每操作成本与吞吐。不重新运行负载。 |
| [archive.escript](../../../bench/archive.escript) | Phase 2.1 证据档案 | 检查样本数、规范比较、源/BEAM/构建哈希、内存/剖析；生成供文档使用的紧凑文本 Erlang 项。适用于特定历史产物布局。 |
| [mutations.escript](../../../bench/mutations.escript) | 分阶段变异基准 | 测量短/中/最大输入、字典、splice 和 havoc；检查操作应用。比较有限随机/分阶段活动，记录内存、reductions、环境与哈希。 |
| [hit_count.escript](../../../bench/hit_count.escript) | 新实验启动器 | 运行存储/执行器/活动/随机/大循环测量，将样本导出 JSON。 |
| [efz_hit_count_micro.erl](../../../bench/efz_hit_count_micro.erl) | 存储微基准 | ETS 集合/计数器、精确映射的稠密 counters/atomics；100–100000 个探针、命中/快照/重置/内存/生命周期以及并发写者。 |
| [efz_hit_count_experiment.erl](../../../bench/efz_hit_count_experiment.erl) | 受控端到端比较 | 等预算/RNG 的真实分阶段/随机活动、首次深层输入、语料/纯计数增长、固定输入执行器开销及饱和。 |
| [efz_count_bench_harness.erl](../../../bench/efz_count_bench_harness.erl) | 观测深层结果 | 调用所选插桩目标，将 `deep` 时间发给观察者。不选择变异，也不自行收集覆盖率。 |

<a id="docs"></a>
## docs — 文档、UML 与历史档案

[docs/](../..) 包含 **70 个文件（含子目录）**。契约
说明当前子系统用法。审计/验证/性能记录
反映记录日期的状态与结果；其中旧故障、计数和
命令不是对当前检出状态的声明。

### 主要文档

| 文件 | 用途与内容 |
|---|---|
| [architecture.md](architecture.md) | 当前架构：模块、进程、状态归属、启动、反馈、执行、覆盖率、语料、变异、故障及 OTP 集成边界。含四张 UML SVG。 |
| [repository-map.md](repository-map.md) | 本逐文件地图：全部项目目录/文件用途、运行时/测试/示例边界、生成产物及功能修改位置。 |
| [cli.md](cli.md) | 通用启动器、最小外部 harness、编译产物、参数和活动 map 模式。 |
| [execution-isolation.md](execution-isolation.md) | 支持的二进制 harness 契约、guardian 协议、受控 spawn API、污染 VM 策略、共享状态边界及未来一次性 VM 后端。 |
| [coverage-integrity.md](coverage-integrity.md) | Harness/构建固定、独立观测证据、上下文状态、代码替换、活动诊断/严格策略与支持边界。 |
| [coverage.md](coverage.md) | 自动源覆盖率契约：支持语法、粒度、清单/构建身份、编译与执行 API、后端/验证变体和限制。 |
| [coverage-tracking-audit.md](coverage-tracking-audit.md) | 精确探针集合表示审计、运行时寿命/全局反馈、与固定 AFL++ bitmap/计数器的比较、15 节内容及真实实验结果。 |
| [hit-count-experiment.md](hit-count-experiment.md) | 可选计数反馈契约、基准后选择 ETS 计数器、成对模糊测试结果、开销、语料增长、兼容性与复现命令。 |
| [quickstart.md](quickstart.md) | 构建和测试语料准备、精确模糊测试/重放/恢复命令、当前限制以及广泛使用前的优先工作。 |
| [mutations.md](mutations.md) | 分阶段引擎：默认值、字典格式、惰性枚举、进度/耗尽、字节操作、havoc、来源及计数。 |
| [replay.md](replay.md) | 崩溃发生/签名/组契约、有界报告、Reason 策略、EFZR/EFZX 模式、原始输入权威性、已验证重放 CLI/API、兼容与回归证据。 |
| [corpus.md](corpus.md) | 持久语料记录 v1/v2：内容寻址布局、原子发布、探针/计数来源、恢复、重复/构建策略及损坏/部分诊断。可复用语料，不是精确恢复。 |
| [input-and-storage.md](input-and-storage.md) | 统一 `max_input_bytes`、重放/崩溃边界、原子产物组、结构化 IO 故障及运行时上下文保留触发输入。 |
| [calibration-readiness.md](calibration-readiness.md) | 9 月 9 日关于重复校准/特征稳定性前提的审计。分析快照完整性、终止、跨用例状态，包含诊断脚本；所提模型不表示已实现特征稳定性。 |
| [phase2-validation.md](phase2-validation.md) | 自动插桩历史验收：命令、保留/继续、终止后覆盖率、基线和 Phase 2 限制。 |
| [phase2.1-performance.md](phase2.1-performance.md) | 性能工作方法与结果：ETS 变体、预备验证、执行器/活动成本、内存、剖析和默认值选择。 |
| [phase3-validation.md](phase3-validation.md) | 分阶段变异和重放历史验证：发现、崩溃、实测成本、内存、命令和 Phase 3 边界。 |
| [technical-audit-2026-09-12.md](technical-audit-2026-09-12.md) | 9 月 12 日完整审计：组件清单、真实调用路径、集成矩阵、实验、缺陷、成熟度与计划。当时调度器/CLI/持久化/IO 缺口应与当前代码及新回归测试对照。 |
| [p1-01-external-supervisor.md](p1-01-external-supervisor.md) | P1-01 契约与证据 | 进程边界、协议/状态机、执行前持久日志、超时/污染/原生恢复、重放、Linux 限制及回归和基准证据。 |

### docs/coverage-audit-2026-09-15

可复现诊断夹具与覆盖率跟踪审计证据。
它们不是生产插桩或新模糊测试引擎。

| 文件 | 用途与内容 |
|---|---|
| [efz_cov_audit_sites.erl](../../coverage-audit-2026-09-15/efz_cov_audit_sites.erl) | 自动插桩用四个普通函数 a/b/c/x。x 中目标局部诊断计数确认真实调用次数，不参与覆盖率。 |
| [efz_cov_audit_harness.erl](../../coverage-audit-2026-09-15/efz_cov_audit_harness.erl) | 未插桩二进制分派器：A/B/AB/ABC、LOOP1…1000、崩溃/超时/上下文擦除及受控/原生子进程。避免额外分派/循环探针扭曲计数语义比较。 |
| [run.escript](../../coverage-audit-2026-09-15/run.escript) | 编译夹具，运行两个真实 ETS 后端及反馈/语料/计划器，检查行/清理/新颖性；原生子进程在独立 VM 验证。原始记录保存到 `_build`。 |
| [results.txt](../../coverage-audit-2026-09-15/results.txt) | 保存的真实快照/新颖性/语料大小、调用重数、子进程结果及生产分阶段活动谱系。 |
| [validation.json](../../coverage-audit-2026-09-15/validation.json) | EFZ/AFL++ 修订、命令与退出码、EUnit/CT 计数和未变生产源 SHA-256。 |

### docs/adr

[docs/adr/](../../adr) 保存架构决策：选用何种方案
及其原因。每个基线对应作出决策之时。

| 文件 | 用途与内容 |
|---|---|
| [0002-automatic-coverage.md](adr/0002-automatic-coverage.md) | 选择源子句/结果探针及执行所属 ETS 的 ADR。比较 parse transform、OTP 覆盖率与底层重写；记录隔离/反馈契约和替代方案。 |

### docs/diagrams

[docs/diagrams/](../../diagrams) 包含 **10 个 UML 文件**。`.mmd` 是
可编辑 Mermaid 源，`.svg` 是保存的图像，可在没有
Mermaid 渲染器时查看。这些 SVG 包含于架构文档。

| 文件 | 用途与内容 |
|---|---|
| [README.md](diagrams/README.md) | 解释 Erlang UML 构造型、箭头含义及本地渲染四张图的命令。 |
| [mermaid-config.json](../../diagrams/mermaid-config.json) | Mermaid 共用主题、字体和安全/布局设置；为可移植 SVG 禁用 HTML 标签。与活动配置无关。 |
| [modules.mmd](diagrams/modules.mmd) | 结构 UML 源：主要运行时模块与分阶段路径依赖。 |
| [modules.svg](diagrams/modules.svg) | 从 `modules.mmd` 生成的模块依赖图。 |
| [processes.mmd](diagrams/processes.mmd) | 结构 UML 源：监督器子进程、链接、监控、worker/guardian/协调器/目标/后代和 ETS 归属。 |
| [processes.svg](diagrams/processes.svg) | 从 `processes.mmd` 生成的进程与资源图。 |
| [feedback-loop.mmd](diagrams/feedback-loop.mmd) | 时序 UML 源：获取语料条目、惰性变异、执行、反馈及保留，使发现可用于后续变异。 |
| [feedback-loop.svg](diagrams/feedback-loop.svg) | 完整分阶段反馈循环的渲染图。 |
| [executor.mmd](diagrams/executor.mmd) | 单输入时序 UML 源：调用者/guardian/协调器/根/后代、门、钩子、DOWN/屏障、超时与污染运行器清理。 |
| [executor.svg](diagrams/executor.svg) | 执行协议及替代结果的渲染图。 |

### docs/examples

[docs/examples/](../../examples) 保存文档用的小型真实产物对，
用于说明重放。这些文件是数据，不是目标源。

| 文件 | 用途与内容 |
|---|---|
| [staged-crash.input](../../examples/staged-crash.input) | 分阶段示例的精确二进制：六个字节 `<<"BOOM!", 0>>`。可与配方重建比较；是故意崩溃的人工解析器输入。 |
| [staged-crash.recipe](../../examples/staged-crash.recipe) | 同输入的 EFZR v1 配方：历史执行的主输入、操作、哈希、限制及构建来源。字节再生无需目标；执行需显式兼容构建。 |

### docs/performance

[docs/performance/](../../performance) 保存含历史测量的 **文本 Erlang 项**
以及新计数实验的 JSON 样本。
虽然扩展名为 `.term`，此处项不是二进制 ETF：
内容用于查看或 `file:consult/1`。

| 文件 | 用途与内容 |
|---|---|
| [phase2.1-samples.term](../../performance/phase2.1-samples.term) | Phase 2.1 报告的环境、样本行、规范活动检查、内存、剖析及源/BEAM 哈希档案。 |
| [phase3-mutations.term](../../performance/phase3-mutations.term) | 变异负载与随机/分阶段活动测量、环境、编译器/构建身份、内存/reductions 和源哈希。是 Phase 3 性能表依据。 |
| [phase3-validation.term](../../performance/phase3-validation.term) | Phase 3 验收证据档案：源哈希、活动/检查结果及测量环境链接。记录当次执行，不是自动更新测试报告。 |
| [hit-count-samples.json](../../performance/hit-count-samples.json) | 原始存储/执行器样本、配置/构建、配对活动结果、随机控制、大循环、环境及新原型验证。 |

### docs/audit-2026-09-12

[docs/audit-2026-09-12/](../../audit-2026-09-12) 包含旧审计诊断
和证据的 **30 个文件**。脚本保留旧 API/布局与
所发现缺陷的断言，例如嵌套变异上限、过早
`mutation_exhausted` 和平面崩溃文件。它们 **不是当前回归
测试集**；修复后部分断言/路径自然不兼容。
当前回归测试位于 `test/`。

| 文件 | 用途与记录内容 |
|---|---|
| [audit_target.erl](../../audit-2026-09-12/audit_target.erl) | 含 `A`、`AB`、`ABC` 路径、`CRASH` 错误及回退的人工解析器；审计自动插桩源。 |
| [audit_harness.erl](../../audit-2026-09-12/audit_harness.erl) | 真实二进制 harness：将精确送达字节发给观察者并调用 `audit_target:parse/1`。 |
| [audit_faults.erl](../../audit-2026-09-12/audit_faults.erl) | `persistent_term`、spawn/链接子进程、超时、协调器 kill、上下文损坏和异常类别的诊断目标。生成受控故障场景。 |
| [run.escript](../../audit-2026-09-12/run.escript) | 历史驱动：构建目标，运行谱系活动和故障诊断，将报告和快照写入指定工作目录。需将旧配置适配当前 API。 |
| [edge-cases.escript](../../audit-2026-09-12/edge-cases.escript) | 256 种子过早耗尽、静默忽略配置键和崩溃存储故障的复现程序。断言描述旧缺陷；修复的调度器应不满足这些断言。 |
| [fresh-replay.escript](../../audit-2026-09-12/fresh-replay.escript) | 历史 `CRASH` 重建及新 VM 执行检查。查找旧的平面 `crashes/*.recipe`，而当前产物按组存储。 |
| [before-sha256.json](../../audit-2026-09-12/before-sha256.json) | 审计前文件哈希基线，用于证明调查期间源未改变。 |
| [status-before.txt](../../audit-2026-09-12/status-before.txt) | 审计前 `git status` 快照：已跟踪修改与未跟踪实现。不描述今天的 Git 状态。 |
| [verification.json](../../audit-2026-09-12/verification.json) | 原始文件完整性及最终审计报告结构/链接检查。 |
| [e2e-report.term](../../audit-2026-09-12/e2e-report.term) | 完整 **二进制 ETF** 审计活动报告：语料、覆盖率、配方/轨迹、决策与崩溃证据。与 `docs/performance/*.term` 不同，不是 `file:consult/1` 可读文本。 |
| [e2e.txt](../../audit-2026-09-12/e2e.txt) | 可读谱系摘录：语料 ID、祖先关系、送达/再生次数和崩溃路径。缺少持久恢复属于旧实现。 |
| [child.txt](../../audit-2026-09-12/child.txt) | 普通 spawn 子进程快照：根已结束，子仍活着，没有自动上下文。 |
| [linked_child.txt](../../audit-2026-09-12/linked_child.txt) | 根正常返回后的链接子进程快照；说明仅有链接不能保证子进程终止。 |
| [child_timeout.txt](../../audit-2026-09-12/child_timeout.txt) | 根超时后快照：独立未链接子进程仍存活，不自动接收覆盖率上下文。 |
| [coordinator_kill.txt](../../audit-2026-09-12/coordinator_kill.txt) | 强制协调器死亡：目标仍存活时得到基础设施结果。故障隔离边界的证据。 |
| [cross_case_state.txt](../../audit-2026-09-12/cross_case_state.txt) | 同逻辑场景在写入 `persistent_term` 前后运行两次；全局状态改变目标结果和覆盖率。 |
| [caught_malformed_context.txt](../../audit-2026-09-12/caught_malformed_context.txt) | 目标替换进程字典上下文后捕获异常；快照表明丢失 malformed-context 诊断。 |
| [hot_reload.txt](../../audit-2026-09-12/hot_reload.txt) | 预检后用普通构建替换插桩代码的结果：成功返回但覆盖率为空。证明依赖稳定加载代码。 |
| [disconnected_artifacts.txt](../../audit-2026-09-12/disconnected_artifacts.txt) | 产物不提供所需目标路径的活动：有执行/崩溃，无发现/覆盖率。产物有效本身不证明命中插桩代码。 |
| [exception_classes.txt](../../audit-2026-09-12/exception_classes.txt) | 将 function_clause、badarg、throw 和 exit 等类别/原因与实际执行器结果及堆栈比较。 |
| [duplicate_initial_seeds.txt](../../audit-2026-09-12/duplicate_initial_seeds.txt) | 两个相同初始种子的历史内存执行，整数 ID 不同，校准两次。不是持久内容去重测试。 |
| [random-example-summary.txt](../../audit-2026-09-12/random-example-summary.txt) | 随机示例摘要：执行/发现/崩溃次数及增长语料中的父链接。 |
| [edge-cases.log](../../audit-2026-09-12/edge-cases.log) | 复现程序输出：当时检出中 256 次空闲访问产生 0 候选/执行；还记录旧配置/存储诊断。 |
| [fresh-replay.log](../../audit-2026-09-12/fresh-replay.log) | 该次历史新 VM 重放确认：`CRASH`、5 字节、存在覆盖率。 |
| [staged-example.log](../../audit-2026-09-12/staged-example.log) | 审计时独立分阶段示例的计数与重放结果。 |
| [cowboy-check.log](../../audit-2026-09-12/cowboy-check.log) | 记录的 **启动失败**：缺少外部 `cowboy_req.beam`。不是成功 Cowboy 测试结果。 |
| [eunit.log](../../audit-2026-09-12/eunit.log) | 历史检出中的 `rebar3 eunit` 输出；测试列表与该次运行结果。 |
| [ct.log](../../audit-2026-09-12/ct.log) | Common Test 输出：审计时三个自动覆盖率场景通过。 |
| [xref.log](../../audit-2026-09-12/xref.log) | 旧检出的交叉引用分析输出。 |
| [dialyzer.log](../../audit-2026-09-12/dialyzer.log) | Dialyzer 输出以及当时 PLT/项目文件计数。 |

<a id="generated"></a>
## 生成文件与内部文件

### _build

`_build/` 不纳入 Git。包含 Rebar3 输出、插桩目标、
崩溃/语料产物及本地验证证据。与源文件不同，
内容取决于运行过的命令。例如，新 VM 测试创建
带随机后缀的目录；部分测试结束后会删除。

| 目录 / 路径族 | 用途与内容 |
|---|---|
| `_build/default/lib/efz/` | 普通配置构建：`ebin/*.beam`、`ebin/efz.app`、编译器缓存与源链接。启动器使用此 ebin。 |
| `_build/test/lib/efz/` | 测试配置构建与已编译测试模块；不替代通用 CLI 的 default ebin。 |
| `_build/test/logs/` | Common Test 运行：HTML 报告、测试集日志、摘要和本地查看所需 CSS/JS。 |
| `_build/plt/`、`_build/default/*plt`、`*.dialyzer_warnings` | Dialyzer 基础/项目 PLT 与分析诊断输出。这是类型分析缓存，不是模糊测试语料。 |
| `_build/*targets/`、`*-target/`、`instrumented-example/` | 编译门面为测试、示例和基准创建的 BEAM/清单对。嵌套 `target/`、`instrumented/` 作用相同。 |
| `_build/*crashes/`、嵌套 `crashes/` | 对应运行的崩溃产物。旧实验可能使用平面文件；当前 `efz_crash` 发布下述分组。 |
| `_build/feedback-loop-test/` | `report.term`、`lineage.txt`、保留条目配方及实际链 `A → AB → ABC` 的新重放证据；`target/` 保存插桩解析器。额外 `checks/` 和负例父日志是本地回归检查。 |
| `_build/durable-e2e-*/` | 独立 VM 阶段：描述符、普通/插桩/v2 目标、持久 `corpus/`、阶段报告/日志与 `lineage.txt`。`durable-e2e-latest.txt` 指向最近目录。 |
| `_build/cli-test-*/`、`cli-acceptance/`、`cli-checks/` | 临时夹具/启动器副本、新 VM 结果和本地 CLI 证据。测试清理通常删除 `*-test-*`。 |
| `_build/quickstart/`、`quickstart-checks/` | 准备好的种子、插桩解析器、可复用语料/发现及准备脚本、通用 CLI、恢复和重放验证日志。 |
| `_build/coverage-audit-2026-09-15/` | 已编译诊断目标、完整实验记录、验证日志和下载的固定 AFL++ 参考源。 |
| `_build/limits-test-*/`、`limits-checks/`、`limits-storage-failure.term` | 限制测试输入/目标与故障注入产物、命令日志，以及存储故障时保留触发输入的报告。 |
| `_build/scheduler-checks/`、`scheduler-progress.term` | 修复分阶段进度/耗尽的本地证据，含 256 个种子的活动。 |
| `_build/isolation-test/`、`isolation-checks/` | 插桩生命周期夹具、新 VM 污染策略日志和 guardian 回归集验证结果。 |
| `_build/architecture-checks/` | 本地 Markdown/UML 检查、PNG 预览和验证报告。UML 源与发布 SVG 位于 `docs/diagrams`。 |
| `_build/performance*/`、`perf-*/`、`phase21-*/`、`phase3-performance*/` | 性能实验变体：编译夹具、原始样本、内存/剖析输出及比较。保存结论发布于 `docs/performance`。 |
| `_build/phase2-*/`、`phase3-*/`、`backend-test-*/`、`fixture-check/`、`relocated/` | 验收工作目录：重新/重定位构建、清单损坏、严格语法、重放与终止诊断。可在 tests/bench 按路径查找具体生成者。 |
| `_build/*report.term`、`*.term`、`*.txt`、`*.log`、`*.json` | 报告和本地证据。`.term` 扩展名本身不决定编码：生成者写入二进制 ETF 或文本 Erlang 项。 |
| `_build/*.input`、`*.recipe`、`*.hex` | 重放字节与配方、损坏负例夹具和字典测试文件。含义由生成它们的测试/脚本决定，不仅由扩展名决定。 |

### 运行时产物格式

这些路径由活动/CLI 设定。可位于 `_build/` 外；用户选择持久目录时，
会跨运行保留。

| 路径 / 文件 | 职责 | 创建者 / 读取者 |
|---|---|---|
| `ARTIFACTS/Module.beam` | 含嵌入清单的可加载插桩 Erlang 代码 | `efz_instrument:compile/2`；通过 `efz_instrument` 加载/预检。 |
| `ARTIFACTS/Module.efz-manifest` | Sidecar 元数据：构建、探针与源位置；必须匹配 BEAM | 编译门面及预检/清单验证。 |
| `OUT/report.term` | 最终二进制 ETF 活动报告，包含统计/语料/决策/崩溃 | `efz_cli` 通过原子文件辅助函数创建。本身不是活动检查点。 |
| `CORPUS/<sha256>/input` | 精确二进制可复用语料条目 | `efz_corpus_store`；SHA-256 内容身份独立于旧队列 ID。 |
| `CORPUS/<sha256>/metadata` | EFZC v1 元数据封装：内容/父/构建/发现与可用变异配方 | `efz_corpus_store:save/4` 及恢复；验证完整性/兼容。 |
| `CRASHES/<signature>/<occurrence>/artifact.input` | 所选不可变代表的精确触发输入 | `efz_crash` 通过 `efz_fs:atomic_group/3` 写入；执行重放读取字节。 |
| `CRASHES/<signature>/<occurrence>/artifact.term` | 二进制 ETF 模式 v2：完整原始 Reason/栈、结果/元数据、身份及活动输入限制 | 崩溃存储；用于原因与来源分析。 |
| `CRASHES/<signature>/<occurrence>/artifact.replay` | EFZX v1：预期构建/harness、输入哈希、签名、策略及限制 | `efz_crash` 创建，`efz_replay` 安全加载并在执行前验证。 |
| `CRASHES/<signature>/<occurrence>/artifact.recipe` | 有分阶段来源时的 EFZR 配方；随机路径可能没有 | `efz_crash` 检查输入对应；配方格式错误产生错误和仅原始输入发布；`efz_recipe` 重建字节。 |
| `CRASHES/<signature>/<occurrence>/manifest` | 验证完整发布组的组模式及文件身份 | `efz_fs:validate_group/1` 验证全组；原始重放有意不依赖诊断与可选配方。 |
| `CRASHES/<signature>/summary` | EFZG v1 持久发生次数与有界代表 ID/哈希对 | `efz_crash_store`：有界安全 ETF 解码、组验证、原子替换加 fsync。计数跨 VM 保留；调度状态不保留。 |
| `CRASHES/<signature>/.lock/` | 独占写锁 | 存储器更改前创建，写入后删除并同步目录。竞争写者或遗留锁产生 `writer_active_or_interrupted`；不自动猜测旧所有者是否死亡。 |
| 存储目录中的 `.tmp-*` | 原子重命名前未完成的暂存写入；不是已提交语料/崩溃条目 | 存储/文件系统辅助函数。普通错误触发清理；VM 中断后可能遗留，语料恢复会诊断。 |

### .git 与崩溃转储

`.git/` 由 Git 管理，不参与模糊测试。其文件都不是
EFZ 源代码或活动配置。

| 文件 / 目录 | 用途 |
|---|---|
| `.git/HEAD`、`refs/`、`objects/`、`index` | 当前引用、分支/标签引用、历史对象和暂存索引。 |
| `.git/config`、`description`、`info/` | 本地配置与仓库内部描述。 |
| `.git/logs/`、`ORIG_HEAD`、`FETCH_HEAD`、`AUTO_MERGE`、`COMMIT_EDITMSG` | Reflog 与 Git 操作临时状态。存在性/值独立于 EFZ 变化。 |
| `.git/hooks/`、`branches/`、`worktrees/`、`gk/` | 钩子、Git/worktree 内部目录及本地 Git 客户端数据；不是 EFZ 运行时。 |
| 根目录 `erl_crash.dump` | VM 崩溃时 ERTS 创建的转储。不是目标崩溃 `.input` 或配方；此检出中存在且被 Git 忽略。 |
| `rebar3.crashdump`、`.rebar3/`、`.eunit/`、`_checkouts/` 和其他 `.gitignore` 排除项 | 忽略规则所列可能生成/工具文件。规则本身不表示文件或目录当前存在。 |

<a id="changes"></a>
## 如何定位功能修改位置

| 任务 | 主要代码 | 行为验证位置 |
|---|---|---|
| 添加 CLI 选项 / 活动字段 | `efz_cli`、`efz_config` | `efz_cli_tests`、`efz_config_tests`；然后更新 `docs/cli.md`。 |
| 修改 harness 调用 / 超时 | `efz_target`、`efz_executor`、`efz_guardian`、`efz_worker` | 执行器、Phase 2/后端测试与执行 UML。 |
| 修改覆盖语法 / 探针身份 | `efz_instrument_pt`、`efz_instrument`、`efz_cov_manifest` | Phase 2 测试、`fixtures/efz_fixture`、严格夹具和覆盖率契约。 |
| 修改钩子或快照验证 | `efz_cov_rt`、`efz_cov`、`efz_cov_manifest` | 后端差分测试与 Phase 2 终止/隔离场景。 |
| 修改新颖性 / 保留 | `efz_feedback`、`efz_worker`、`efz_corpus` | `efz_feedback_loop_tests`：发现输入必须实际成为父输入。 |
| 修改调度 / 进度保护 | `efz_mutation_plan` | 含 256 个种子、增长语料及完整反馈循环的变异/Phase 3 回归。 |
| 添加字节操作 | `efz_mutation_plan`、`efz_mutation`、`efz_recipe` | 变异模型测试、配方往返/新 VM 测试及分阶段运行。 |
| 修改持久模式 / 恢复 | `efz_corpus_store`、`efz_corpus`、`efz_config` | 存储损坏/重复测试及新 VM 持久集成。 |
| 修改输入边界 / IO 契约 | `efz_input`、`efz_fs`、`efz_crash` 与调用边界 | `efz_limits_tests`、CLI 摄取及配方测试。 |
| 修改架构说明 | `docs/architecture.md`、`docs/diagrams/*.mmd` | 对照源检查调用路径、重生成 SVG，新增文件时更新本地图。 |

新增或移动文件时，应更新对应表格和文件
数量。保留历史诊断作为当时证据；当前
正确性由现行测试和新运行验证，而非旧日志。

## 运行时诊断新增项

| 路径 | 用途 |
|---|---|
| `src/efz_runtime_config.erl` | 通用嵌套策略验证器与限制 |
| `src/efz_stability.erl` | 有界返回比较、可重复性指标及重放重复执行 |
| `src/efz_runtime.erl` | Guardian 所属采样器、子进程/超时观测 |
| `src/efz_runtime_store.erl` | 有界独立运行时产物及带校验和索引 |
| `src/efz_runtime_replay.erl` | 显式目标的兼容运行时复查 |
| `fixtures/runtime/`、`test/efz_runtime_tests.erl` | 已插桩资源/生命周期/验证回归 |
| `bench/efz_runtime_bench.erl` | 同驱动下的基线/关闭/稳定性/资源/完整测量 |
| `docs/runtime-diagnostics.md`、`docs/runtime-diagnostics-validation.md` | 契约及实际验证 |

## P1-01 外部监督器新增项

| 路径 | 用途 |
|---|---|
| `c_src/efz_vm_launcher.c`、`c_src/Makefile` | Linux pidfd/PDEATHSIG/session/subreaper 生命周期及权威 wait 状态 |
| `priv/efz_external.py` | 有界协议、持久日志、状态机、重启策略和外部重放 |
| `src/efz_external.erl`、`src/efz_external_worker.erl` | 加载前 CLI 委托及工作进程侧执行门 |
| `fixtures/external/` | 仅由集成工作进程加载的安全/原生崩溃/挂起/污染/启动夹具 |
| `test/efz_external_tests.erl`、`test/external_supervisor_test.py` | 旧版门及真实操作系统进程验收 |
| `test/external_bench.py` | 同目标下旧模式/受监督模式的持久化成本测量 |
| `docs/p1-01-external-supervisor.md` | 契约、命令、证据与限制 |
