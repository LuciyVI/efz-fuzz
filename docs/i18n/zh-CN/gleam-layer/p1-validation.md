# P1 契约验证与交接

[English](../../../gleam-layer/p1-validation.md) · [Русский](../../ru/gleam-layer/p1-validation.md) · [Español](../../es/gleam-layer/p1-validation.md) · **简体中文** · [所有语言](../../README.md)

当前 P5 验收记录于 [p5-validation.md](p5-validation.md)。
下文交接和待完成状态描述历史阶段运行。

需求 **2.0-native**，契约 **v1**，向量 `{1,1,1,1,1,1}`。
运行产物：`artifacts/gleam-layer/20261008-p1-contract/`（仓库根目录）。
P1 契约和可执行验收检查已实现并测试。
下文一致性审查是作者自审；**未**进行独立审查。
这不关闭整个编排软件包或 P5。

## 输入与修改文件

已阅读 `efz_gleam_native_subagent_prompts/01_COMMON_CONTEXT.txt`、实际 P0
[baseline.md](baseline.md)、原始源码快照及当前源码和测试。
HEAD 仍是 `79d76221c6bc5df30b80e6b0de947f3860f4fa4b`。
本轮在改动前记录既有脏差异，没有覆盖前期工作。
九个用户提示文件、ZIP 和 `AGENTS.md` 哈希均保持不变。

P1 修改：

- `docs/gleam-layer/architecture.md`：EFZ 所有权、实际扩展点、控制/数据/冷路径、覆盖边界。
- `docs/gleam-layer/contracts.md`：版本化表示、配置、显式 RNG 转换、限制、错误、接纳/重启/裁剪契约。
- `docs/gleam-layer/p1-validation.md`、`agent-plan.md`、`decision-log.md`：证据、所有权、决策与交接。
- `test/efz_gleam_contract_tests.erl`：额外可执行契约样例。
- `src/efz_gleam_adapter.erl`：针对不兼容选项、模式、目标和限制提供有界可操作启动错误，保留成功与关闭分发。
- `gleam/efz_semantic/src/efz_qs_model.gleam`：在 prepend/append 分配前检查容量；支持输出与拒绝语义不变。
- `scripts/build_gleam.sh`：只发布可调用模型，从运行时应用元数据移除未使用的生成 CLI 启动器，
  将其此前生成 BEAM 归档到活动 ebin 之外。不添加 stdlib 软件包。

现有 EFZ 所有权、behaviour 和契约向量不变。
不引入新 C ABI、NIF、插件注册表、引擎或目标重写。

## 已执行命令与结果

全部命令从仓库根目录，以 `ERL_FLAGS='+S 2:2'` 串行运行。
下面 `contract_test_modules` 是逗号分隔的 EUnit 模块参数：

```sh
contract_test_modules=efz_gleam_contract_tests,efz_gleam_layer_tests,efz_config_tests,efz_corpus_store_tests,efz_recipe_tests,efz_mutator_tests,efz_native_public_tests
```

| 检查或命令 | 退出码 | 结果 | 运行目录中的产物 |
| --- | --- | --- | --- |
| `GLEAM_BIN=/no/compiler rebar3 eunit --module="$contract_test_modules"` | 0 | 34 项通过；关闭构建不选择可选集成 | `p1-off-eunit.log` / `.json` |
| `GLEAM_BIN=/tmp/efz-gleam-toolchain/gleam rebar3 as gleam eunit --module="$contract_test_modules"` | 0 | 51 项通过，真实 Gleam BEAM 和 EFZ 原生集成 | `p1-on-eunit.log` / `.json` |
| `GLEAM_BIN=/tmp/efz-gleam-toolchain/gleam rebar3 as gleam compile` | 0 | 使用固定 Gleam 1.10.0 构建运行时发布包 | `p1-on-build.log` / `.json` |
| 相同环境，`rebar3 as gleam xref` | 0 | 没有未定义运行时引用 | `p1-xref.log` / `.json` |
| `escript artifacts/gleam-layer/20261008-p1-contract/check_source_refs.escript "$PWD" "$PWD/_build/gleam"` | 0 | 对编译抽象 forms 检查了 26 个显式 `file:function/arity` 引用 | `source-references.log` / `.json` |
| `GLEAM_BIN=/no/compiler rebar3 eunit --module=efz_phase2_tests,efz_mutation_tests` | 0 | 42 项旧 term/执行器和 staged 计划测试通过 | `legacy-compatibility.log` / `.json` |
| `git diff --check` | 0 | 已跟踪文件无空白错误 | `diff-check.log` |

首次 Gleam profile xref 退出 **1**：生成的 `efz_semantic@@main:print_term/1`
引用缺失 `gleam@string:inspect/1`。`xref.log` / `.json` 保留该失败。
最终运行时发布包排除未使用启动器及其应用模块声明；最终 xref 通过。
初期中间 EUnit 运行（34/50）也被保留。
源码引用检查器最初拒绝没有显式路径引用的文档（退出 127）；修正后最终引用验证通过。

精确命令、环境、退出码和源码哈希位于 `gates.json` 及各检查 JSON；
不保存完整环境或秘密。`preserved-inputs.json` 验证用户文件不变。
`acceptance-proofs-final/` 从最终测试复制实际引导、重启、覆盖归属及人工发现产物；
来源路径记录于 `acceptance-proofs-final.json`。

## 验收样例映射

| 需求 | 已执行样例或证据 |
| --- | --- |
| 合法 ADT、编解码定律、任意字节 | `efz_gleam_layer_tests:codec/0`：规范空、二进制、重复模型；字节词汇与固定真实 Cowlib 差分 |
| 畸形 term、对齐、深度/字节/元素 | `boundary_test/0`、`limits_and_failures/0`；`efz_gleam_contract_tests:malformed_model_and_limits_test/0`、`outcome_verdicts/0` |
| 缺少软件包、版本、目标/模式/配置 | `invalid_capabilities_test/0`、`package_capabilities/0`；版本桩明确是契约故障样例 |
| 确定性变异、关闭/比例零 RNG、原始回退 | `determinism/0`、`fallback_rng/0`；相同候选与最终显式 RNG 状态 |
| 运行时关闭无回调或状态 | `off_preserves_configuration_test/0`、`runtime_off_callbacks/0`：实际活动调用追踪；无语义状态或报告字段 |
| 相同结构单位、不同语义事实 | `coverage_attribution/0`、`guidance/0`：真实原生快照；纯语义工作条目随后被普通父输入选择 |
| 仅观察不改接纳 | `observer_only/0`，与运行时关闭的工作输入比较 |
| 接纳失败、重试、重复特征 | `persistence_retry/0`：写失败不改变 seen；重试成功，重复保留接纳原因 |
| 代表保留与重启 | `reduction/0`、`restart/0`：已记录结构与语义并集和纯语义标志保留；缩减只读 |
| Pass/Fail/Inconclusive、零预算 | `limits_and_failures/0`、`outcome_verdicts/0`、`zero_budget_random_mode/0`；额外目标调用为零 |
| 发现独立于新颖性，属性重放及最小化 | `finding_replay/0`：人工样例，一个工作输入产生三次失败；相同属性重放和有界字节删除 |
| 层错误是诊断，不是回退 | `fault_injection/0`：显式故障桩；活动在变异目标执行前停止 |
| 模式不匹配及旧产物 | `semantic_schema_restore_test/0`、语料存储 v1/v2 测试、配方 v1/负向/全新 VM 测试、属性版本不匹配测试 |
| 现有 term 输入及普通调度 | `efz_phase2_tests` 推导式样例包含 list/map/tuple term；`efz_mutation_tests` 保留普通操作、公平性、限制及选择 |
| 发布包不需要可选 CLI/stdlib | `runtime_shipment/0`：仅模型模块列表，无可选应用启动 |

mock 和 stub 只关闭错误契约。
真实模型及 EFZ 原生覆盖测试提供集成证据；不把 mock 计为引导。
已知人工发现是接线与重放样例，不是独立缺陷发现。

## 源码一致性审查

负责人根据 [architecture.md](architecture.md)核对 P0 与当前所有者：
父输入选择先于结构化解码；普通重试保留既有预算和游标；关闭不增加抽取；
目标执行及快照先于纯回调；只接受 cow_qs 清单；guardian 串行 EFZ 区间；
发现先于观察器失败；语料在插入后提交语义 seen；重启拒绝模式不匹配并校准原始字节；
缩减不会静默删除代表。
本轮发现的提前分配、不透明启动诊断和未使用启动器问题已修复，并重跑受影响检查。

审查限制：作者自审，无独立审查者或子代理；同 VM 内不受管理目标调用仍在隔离范围外。
不声称并行、延迟或可原生中断判定器。
此前运行的关闭等价性与性能系列不会在源码修改后被改称最终 P5 测量。
完整全新关闭打包和最终同引擎基准系列仍是 P5 工作。
完整提示词软件包**尚未完成**。

## P2/P3/P4 交接与所有权

负责人拥有共享架构与契约、构建与配置、循环和语料；没有并发写入 worker。
任何后续委派必须显式分配文件，并传递公共上下文、P0 证据、本 v1 契约和 `gates.json`。

- **P2：**保持固定 Gleam 1.10.0 和真实 BEAM 调用，验证外部 term，
  只打包可调用运行时模块，保留无需编译器的关闭构建。
  生成的 Erlang 源码不是必需构建产物。当前发布包及缺失或不兼容能力检查已有真实测试证据。
- **P3：**保留 EFZ 管理的操作派生、RNG 转换与现有计划；
  在字段、字节、输出分配前实施限制，保留有意无效表示，持久化原始字节和纯数据配方 v2。
  此契约不授权调度器、缓存或提示策略。
- **P4：**有限特征只经串行 EFZ 接纳使用，保留仅观察中立性及持久化重试与重启行为，
  主覆盖独立，任何额外目标执行都计数并受预算约束。
  延迟支持要求修订能力契约；v1 拒绝它。

这些是交接不变量，不代表全部下游阶段门槛或独立编排审查完成。
