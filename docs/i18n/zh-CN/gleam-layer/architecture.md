# 原生 Gleam 架构——契约 v1

[English](../../../gleam-layer/architecture.md) · [Русский](../../ru/gleam-layer/architecture.md) · [Español](../../es/gleam-layer/architecture.md) · **简体中文** · [所有语言](../../README.md)

需求：**2.0-native**。契约：**1**。基础修订：
`79d76221c6bc5df30b80e6b0de947f3860f4fa4b`。
本文描述当前工作副本，包括 P1 审计前已存在的集成代码。
实际 P0 结果及源码目录绕行方案见 [baseline.md](baseline.md)。

## EFZ 所有权与扩展点

路径相对于仓库；函数元数是源码映射的一部分。

| 职责 | 实际 EFZ 所有者 |
| --- | --- |
| 活动生命周期与报告 | `src/efz_fuzzer.erl:init/1`、`handle_info/2`、`terminate/2` |
| 校准与主循环 | `src/efz_worker.erl:handle_info/2`、`staged_iteration/1` |
| 父输入与调度器 | `src/efz_corpus.erl:select/0`、`mutation_entries/0`；`src/efz_mutation_plan.erl:next/2`、`visit/2` |
| 变异分发与操作 | `src/efz_mutation_plan.erl:attempts/6`、`structured/3`、`ordinary_attempts/6`；`src/efz_mutation.erl:apply_operation/3` |
| PRNG | staged：`src/efz_mutation_plan.erl:new/1`、`uniform/2`；旧随机路径：`src/efz_worker.erl:init/1`、`src/efz_mutator_random.erl:mutate/2`；选择：`src/efz_corpus.erl:init/1`、`handle_call/3` |
| 目标、超时、重置与清理 | `src/efz_executor.erl:run/4`、`invoke/4`；`src/efz_guardian.erl:run/6`、`start/6`、`cleanup/2`、`finish/2` |
| 覆盖快照 | `src/efz_guardian.erl:finish/2`；现有 `src/efz_cov_native_public.erl:collect/1`、`collect_profiled/1` 及 `src/efz_coverage.erl` 后端 |
| 结构新颖性 | `src/efz_feedback.erl:evaluate/3` |
| 语料、接纳与持久化 | `src/efz_worker.erl:retain_layer/4`；`src/efz_corpus.erl:admit_semantic/4`、`semantic_admission/6`、`add_checked/3`；`src/efz_corpus_store.erl:save/4` |
| 发现与指纹 | `src/efz_worker.erl:record_failure/4`；`src/efz_crash.erl:signature/2`、`save/4`；`src/efz_crash_store.erl` |
| 配方、原始与属性重放 | `src/efz_recipe.erl:make/4`、`regenerate/1`、`execute/5`；`src/efz_replay.erl:run/6`；`src/efz_semantic_replay.erl:run/5`、`minimize/6` |
| 保守语料缩减 | `src/efz_semantic.erl:cover/1`，只读建议子集；不在线删除 |

现有 behaviour 是 `src/efz_mutator.erl:mutate/2` 和 `src/efz_target.erl:run/1`。
变异器 behaviour 服务于普通随机变异，不携带 staged 计划的 RNG 状态或语义判定。
此层通过一个固定且经检查的 `efz_gleam_adapter` 扩展该计划的分发。
不需要第二套 behaviour 平台或插件注册表。`efz_` 前缀沿用现有模块命名。
Gleam 返回数据；全部调度决策仍归 EFZ。

## 控制、数据与冷路径

**控制：**`efz_config:prepare/1` 验证现有覆盖及目标能力，然后
`efz_gleam_adapter:prepare/2` 检查选项、软件包、限制和版本。
启动时还会一次性验证每个必需核心导出。[p2-integration.md](p2-integration.md)
记录实际编译器产物、全新构建和已追踪的回调可达性。
`efz_fuzzer:init/1` 启动现有所有者。
`scripts/gleam_seeds.escript` 在循环前单独准备原始种子文件；运行时启用独立于种子准备。

**数据：**EFZ 选择父输入和通道，选择可选结构化家族，然后只在该分支执行解码、变异、编码。
普通变异留在同一计划中。相同目标入口在 EFZ 执行器下运行。
完成的快照先于观察器、判定器及串行 EFZ 接纳。
关闭或比例为零的分发不增加 RNG 抽取；不支持或畸形输入保留普通路径。

**冷路径：**EFZ 保存有界声明式配方和不可变发现旁文件。
重放及最小化显式使用其执行器。当前内联判定器是纯函数且有预算，不额外调用目标。
延迟或昂贵的在线判定器不是 v1 支持能力，会在启动时失败。
未来支持必须沿用既有监督及执行边界和有限预算。

## 覆盖隔离与兼容性

P0 已在 OTP 27.0 确认公开原生行覆盖。计数器以模块为范围，而非进程本地。
`efz_guardian:run/6` 注册 `efz_execution_guardian`；另一次 EFZ 执行得到 `runner_busy`。
`loop/1` 在 `finish/2` 进行覆盖快照前排空后代和追踪屏障；
`efz_executor:run_pinned/4` 也等待 guardian 终止。区间为：

`reset/open → target → completion/cleanup barrier → snapshot → callbacks → admission`。

启用适配器的清单可仅选择 `cow_qs`，排除 EFZ、Gleam、测试驱动、适配器和判定器。
同一 VM 内不受管理的所选模块调用不属于此隔离契约。
没有异步语义观察器或晚到响应队列。
未来任何需要重复目标的判定器都必须在主快照后使用单独串行 EFZ 区间，
携带执行和活动 ID，并使用独立执行计数。

其他现有覆盖后端保留；显式选择不会静默回退。
低层执行器保留 term 输入。活动在 P0 已要求二进制；
第一个适配器没有对其他 API 施加新限制。
未添加 C ABI、NIF、端口、额外 VM、外部引擎或 OTP 补丁。

## 所有权与审查

负责人拥有此轮 P1 文档、测试，以及共享配置、循环和语料。
没有活动 worker；不声称委派或独立审查。
[p1-validation.md](p1-validation.md)记录源码检查、测试、限制和 P2/P3/P4 交接。
现有用户需求和 `AGENTS.md` 保持不变。
