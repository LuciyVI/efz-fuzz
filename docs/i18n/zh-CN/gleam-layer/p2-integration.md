# P2 可选原生 BEAM 集成

[English](../../../gleam-layer/p2-integration.md) · [Русский](../../ru/gleam-layer/p2-integration.md) · [Español](../../es/gleam-layer/p2-integration.md) · **简体中文** · [所有语言](../../README.md)

当前 P5 验收记录于 [p5-validation.md](p5-validation.md)。
下文交接及待完成状态描述历史阶段运行。

需求 **2.0-native**；契约 **v1**，向量 `{1,1,1,1,1,1}`。
**P2 功能门槛：PASS。** 证据位于 `artifacts/gleam-layer/20261008-p2-native/`；
`gates.json` 索引命令、退出码、源码哈希及保留失败。
这不关闭 P3/P4 阶段验收、独立审查或最终 P5 基准。

## 范围与所有权

已阅读公共上下文、实际 P0 基线和执行路径，以及 P1 契约。
HEAD 仍为 `79d76221c6bc5df30b80e6b0de947f3860f4fa4b`；编辑前记录脏状态。
单一负责人拥有软件包与 API、适配器与测试、共享构建和配置。
未使用子代理或独立审查者。

本轮开始时，可选 profile、软件包、EFZ 钩子及既有 P3/P4 代码已存在。
P2 增加完整启动导出验证、有界带标签错误诊断、真实 BEAM 可达性及生命周期样例、
有限诊断驱动和证据。不添加生产结构化策略或语义引导。
模型和核心、变异计划器、worker、语料、配置及构建钩子与 P2 输入快照相比不变。
用户提示、ZIP、AGENTS.md 和锁文件哈希不变。
未提交、推送、建 PR、删除语料或修改全局环境。

本轮文件：`src/efz_gleam_adapter.erl`、`test/efz_gleam_beam_tests.erl`、
`test/efz_gleam_layer_tests.erl`（故障桩导出）、`scripts/gleam_beam_bench.escript`、
本报告、`contracts.md`、`architecture.md`、`user-guide.md`、
`baseline.md`（工具链路径）、`agent-plan.md`、`decision-log.md`。
限定差异为 `p2-changes.patch`；生成产物不是源码变更。

## 工具链、profile 与产物

实际工具：**OTP 27.0 / ERTS 15.0**、**Rebar3 3.25.0**、**Gleam 1.10.0**、
Linux x86_64、`+S 2:2`。本地编译器 `/tmp/efz-gleam-toolchain/gleam`，SHA-256 为
`5d86c226aad4fb32e501bc1a6c5c90394e3bd3e462476b1552f4b734e74f7906`。
无需全局安装或更新。`gleam.toml` 固定 `== 1.10.0`，目标 `erlang`；
`manifest.toml` 中软件包数为零。
Rebar/Cowboy/Cowlib/Ranch 固定值不变，实际依赖 Git HEAD 已检查（`toolchain.json`）。
主要运行时根目录为 `/home/fbogoslavskii/.asdf/installs/erlang/27.0`。
初次最小 PATH 关闭构建选择了系统 OTP 27.3.4.13 / ERTS 15.2.7.9。
该额外成功构建与测试保留于 `system-otp-off/`；最终独立关闭门槛显式选择主要 OTP 27.0
bin 目录，PATH 中没有 Gleam（`toolchain-paths.json`）。

`rebar.config` 只在 `gleam` profile 启用 `scripts/build_gleam.sh`：

```sh
ERL_FLAGS='+S 2:2' rebar3 compile
GLEAM_BIN=/tmp/efz-gleam-toolchain/gleam ERL_FLAGS='+S 2:2' rebar3 as gleam compile
```

钩子调用 `gleam export erlang-shipment`，然后把 `efz_qs_model.beam` 和归一化
`efz_semantic.app` 复制到 `_build/gleam/lib/efz/ebin/`（EUnit 使用 `gleam+test`）。
运行时应用元数据只列出 `efz_qs_model`，无应用依赖。
未使用生成 CLI 启动器被排除。无需、也未观察到可选应用启动或加载。

固定版本 1.10.0 实际在构建树中生成三个 Erlang 源文件；Rebar 集成只使用 BEAM 和应用产物，
不编译或搜索生成 `.erl`。两次构建之间归档私有 Gleam 缓存后，模型及 `.app` SHA-256 相同
（`reproducibility.json`）。不声称不同绝对源码路径之间字节一致；
编译器和调试路径可能改变文件哈希。

已检查一手参考：[Gleam externals](https://gleam.run/documentation/externals/)、
[OTP 公开覆盖 API](https://www.erlang.org/doc/apps/kernel/code.html)、
[Gleam 1.19 编译器公告](https://gleam.run/news/gleam-doesnt-compile-to-erlang-source-anymore/)。
已安装 OTP 27 源码和实际固定编译器输出确立此门槛；
较新公告不能证明 1.10.0 产物，也不是升级指令。

## 实际运行路径与边界

追踪链为：

`efz_config:prepare/1 → efz_gleam_adapter:prepare/2 → existing EFZ lifecycle/worker`

`efz_qs_target:run/1 → efz_cov_native_public:collect/1 → efz_gleam_adapter:oracle/3`

`→ efz_gleam_adapter:decode/2 → efz_qs_model:decode/2 → efz_qs_model:check/2 → EFZ report`。

原生插件是 P1 固定适配器和分发，不是第二套插件平台。
实际编译核心导出为 `versions/0`、`decode/2`、`encode/2`、`normalize/1`、
`generate/2`、`mutate/3`、`observe/4` 和 `check/2`。
`prepare/2` 一次性加载并检查，先检查版本。
缺少导出返回 `{gleam_configuration,{gleam_callback_unavailable,Function,Arity}}`。
热回调使用普通 BEAM `apply(efz_qs_model,Function,Args)`，无模块查找、动态加载、
应用启动或传输序列化。

`hook_trace/0` 运行真实原生覆盖 EFZ 活动，比例零、反馈关闭、一次纯内联判定器检查、
无变异迭代。追踪确认目标 → 主快照 → 适配器 → 真实编译 Gleam；
数据回调运行在既有 EFZ worker。启动模型查找仅一次。
结果为一次 Pass、额外目标调用零，无结构化计数或语义状态。
`beam-proofs-complete/hook/trace.json` 直接记录检查过的调用顺序；
相邻 `proof.term` 保存报告但不保存追踪参数。
`runtime-root.json` 记录实际导出、导入和布局。
核心只导入 Erlang 内置函数；唯一声明 FFI 为 `erlang:bit_size/1`。

适配器验证对齐二进制与文本或 bitstring 的区别、元组标签及元数、正规列表、整数、
有界限制、模型、结果、特征及固定错误标签。
不存在不安全 Dynamic 或由输入产生的原子。
测试覆盖空输入、非 UTF8、恰好 4096 字节、超长输入、畸形结果、错误版本和缺少导出。
不支持或限制与层错误区分。诊断原因保持有界；目标发现先于后续层故障持久化。

## 已执行门槛

命令以 `ERL_FLAGS='+S 2:2'` 串行运行。
对应 `.json` 记录精确 argv、cwd、env、exit；日志保留完整测试结果。

| 命令或检查 | 退出码 | 结果或产物 |
| --- | --- | --- |
| 仅源码私有 `rebar3 compile`，主要 OTP bin + `/usr/bin:/bin`，不存在的 GLEAM_BIN | 0 | `pinned-off-build`：无 Gleam 目录、编译器或产物，构建前 BEAM 为零 |
| 私有关闭 EUnit：smoke、BEAM/contract/layer、phase2、mutation 模块 | 0 | **52 项通过**，`pinned-off-tests-final` |
| 根目录关闭 EUnit：BEAM/contract/layer 模块 | 0 | **9 项通过**，`off-focused-final` |
| 私有 `rebar3 as gleam compile` 两次 | 0 / 0 | `clean-on-first`、`clean-on-second`；软件包哈希相同 |
| 根目录 `rebar3 as gleam compile` | 0 | `on-build`；实际可选发布包 |
| 根目录开启 EUnit：BEAM/contract/layer 模块 | 0 | **32 项通过**，`on-focused-final` |
| 快照追踪及 JSON 改进后开启 EUnit BEAM 模块 | 0 | **7 项通过**，`beam-trace-json-corrected` |
| `rebar3 as gleam xref` | 0 | `on-xref-final`，无未定义运行时调用 |
| 全新 VM 导出与布局检查，私有两次及根目录 | 0 | `runtime-first`、`runtime-second`、`runtime-root` |
| 全新活动，baseline/off/on-runtime-off，种子 17 和 43 | 各 0 | 每模式每种子 100 变异候选；精确轨迹相等，`complete-raw-equivalence/` 与不可变 P0 轨迹比较 |
| 分发和 BEAM 诊断驱动 | 0 | `dispatch-overhead`、`beam-overhead-complete`；样本见下文 |

私有仅源码构建通过 Rebar `_checkouts` 使用固定**普通**依赖源码副本，而非缓存依赖 BEAM。
Rebar 只重写 scratch 锁；仓库锁不变。不声称进行了全新联网依赖获取。
`prepare_scratch.py` / `prepare_on.py` 和准备 JSON 记录路径及源码哈希。
全部检查后，关闭构建物理上仍不含软件包或产物（`clean-off-final-isolation.json`）。
既有无关 C 启动器正常构建，不是 Gleam 桥接器。

开启构建中的运行时关闭由契约样例单独追踪：数据回调和语义状态为零。
全新原始活动也没有模型或应用加载及层计数。
候选、阶段、父输入哈希匹配 P0 与全新关闭构建；
显式计划 RNG 等价仍由 `determinism/0` 和 `fallback_rng/0` 覆盖。
既有 term 执行器语义和普通原始变异测试通过。

`repeated_calls/0` 完成 1000 次解码编码配对而不改变进程字典，
随后运行两个独立活动，各有全新判定器预算和所有者清理。
故障样例验证畸形或抛异常回调在定义停止策略下使控制模糊测试器保持存活，
保留此前目标发现，并允许后续健康活动。
mock 仅关闭这些错误契约。

保留的中间失败：桩变量遮蔽警告（退出 1）、scratch 缺少 `fixtures/` 导致旧设置取消（退出 1），
以及非分析活动调用 `collect/1` 时追踪 `collect_profiled/1`（退出 1）。
测试桩和 trace-JSON 推导式最初都有变量遮蔽；warnings-as-errors 在测试前拒绝它们，
修正运行后通过。可选全新 VM 报告摘要工具在安全 ETF 解码时拒绝未知报告原子；
未改为不安全解码，而是放弃该工具，追踪样例现直接写 JSON。
`unused-proof-summary.json` 标记该工具不是门槛。
这些修正不会把失败命令改成成功；上列对应最终重跑通过。
取消测试和错误追踪断言不计为证据。

## 可观测性与测量成本

生产 EFZ 报告保留既有判定器、观察器、结构化及结果计数和累计时间。
细粒度调用、原因、字节计数及采样时间明确仅用于诊断，由 `gleam_beam_bench.escript`
采集，不引入生产状态或 PRNG 抽取。
48 次实际适配器调用得到 16 成功、8 不支持、8 限制、16 边界拒绝、零层异常；
32 次解码、16 次编码、32912 二进制输入字节、64 编码输出字节。
六个计时样本按序号每七次调用选择一次，最多六个。
不记录完整载荷；有界失败测试另行覆盖层异常。

五次串行交替试验：分发每次 1M 调用、小 BEAM 组件 20K、最大输入解码 500。
减去控制基线的样本中位数：

| 组件 | 中位数 | 五次试验范围 |
| --- | --- | --- |
| 关闭计划分发增量 | 0.546 ns | 0.189–0.622 ns |
| 关闭 worker 分发增量 | −0.282 ns | −1.958–−0.022 ns |
| 输入及模型边界验证，8 字节输入 | 26.7 ns | 25.85–27.05 ns |
| 真实核心解码 / 适配器解码 | 667.85 / 735.65 ns | 660.0–686.2 / 729.35–766.9 ns |
| 真实核心编码 / 适配器编码 | 193.6 / 236.5 ns | 184.85–196.65 / 235.8–248.0 ns |
| 适配器纯判定器 | 882.85 ns | 872.75–895.45 ns |
| 核心 / 适配器解码，4096 字节输入 | 171.974 / 173.088 μs | 170.902–173.252 / 172.176–174.044 μs |

负分发差值和极小直接检查差值不足以可靠解释增量成本，不是加速或零开销证明。
组件独立测量；中位数相减不能精确构成可相加成本分解。
诊断时钟样本包含时钟开销，并与批量测量分开运行。
临时 export_all 限于诊断 VM。不存在语义层 worker 或消息开销。
不声称活动性能优势。

## 限制与交接

生产回调仍为直接有界 BEAM 函数，无额外语义 worker、队列、缓存、ETS、新 NIF、端口、
socket/RPC、JSON/ETF 传输、外部引擎、JavaScript 目标或 OTP 补丁。
现有目标隔离和 VM 范围覆盖串行化不变；不受管理并发目标调用仍在契约外。
不使用异步响应协议。

挂起样例在 30 ms 后杀死受监视的**仅测试** Erlang worker，并确认 DOWN 和清理。
它既不证明可取消任意直接或原生回调，也不添加生产 worker 或截止时间机制。
未来昂贵判定器要求单独批准的有界 EFZ 监督和执行契约。

P3 应审计既有类型化提供器、种子准备、配方和 RNG 转换，不静默改变核心表示。
P4 应根据 P1 审计既有语义使用方、接纳及独立发现通道。
P5 必须关闭最终重放、最小化、回归和同引擎活动基准。
不声称全部软件包完成或独立审查。
