# 自动覆盖契约

[English](../../coverage.md) · [Русский](../ru/coverage.md) · [Español](../es/coverage.md) · **简体中文** · [所有语言](../README.md)

## 支持环境与度量

实际测试：OTP 27.0 / ERTS 15.0、`x86_64-pc-linux-gnu`、Rebar3 3.25.0。
构建身份包含 compiler 模块 MD5。其他 OTP/架构需验证；最低 OTP 配置本身不是证据。

默认 ETS 和可选 bitmap 的度量为**单次执行范围内的源码 clause/outcome 探针覆盖**。
每次观察是精确 `{Module, BuildId, ProbeId}`。默认
`coverage_feedback => presence` 保留精确集合语义。实验性
`coverage_feedback => hit_count` 增加精确身份计数及计数桶；见
[契约与测量](hit-count-experiment.md)。两者都无哈希 bitmap、推断 CFG edge
或前探针转移状态。可选 bitmap 将这些精确结构探针存于无碰撞槽位。

[Bitmap 存储架构](coverage-bitmap-architecture.md)保留结构探针和精确身份。
自动 presence 活动可设 `coverage_backend => bitmap`，可选
`coverage_bitmap_bits => 65536`（位而非字节）。`ets` 仍为默认和回退。
Bitmap 配 manual 或 hit-count 在启动前拒绝。测试和实测取舍见
[v1 实现报告](coverage-bitmap-implementation-report.md)及
[v2 测量](coverage-bitmap-v2-results.md)。实验性
`coverage_backend => otp_native_public` 用 OTP 27+ `line_coverage` 与公开
reset/read API，其特征是可执行行，数量与 corpus 历史不可当作结构探针等价。
需另编译 native 工件和无无关调用者的专用 VM。见
[实现及短测](otp-native-public-results.md)。直接 DWARF 读取未实现。

## 语法与语义

| 构造 | 插桩 |
|---|---|
| 函数 clause，含 guard/二进制 pattern | body 入口 |
| `case`, `if` | 选中 clause 的 body 入口 |
| `receive` | 选中 clause 入口；`after` body 入口 |
| `try` | body 入口、选中的 `of`/catch clause、非空 `after` body |
| 匿名/具名 `fun` | 选中 fun clause 入口 |
| 嵌套表达式 | 遍历调用及 callee 表达式、元组、列表、map 键值/更新、record 值/更新/访问、binary 值/大小、块、match 的 RHS、运算符及旧 `catch` |
| Pattern 和 guard | 结构保持，不插探针 |
| `andalso`, `orelse` | 保持运算符/求值规则，遍历内嵌 clause body，不插运算结果探针 |
| 本地/远程 fun 引用 | 保留引用，遍历动态表达式组件 |
| list/binary/map comprehension | 整个表达式保留，诊断并记 manifest 限制；严格模式拒绝 |
| `maybe`，含 `else` | 整表达式保留、诊断并记限制；严格模式拒绝 |
| 非字面 record 默认值 | 保留但无内部探针，诊断并记限制；严格模式拒绝 |
| 未知可执行形式 | 明确诊断/限制并保留，或严格模式拒绝 |

默认 `strict => true`。`strict => false` 明确接受不完整插桩，在 stderr 输出
并记录 manifest。即使跳过表达式内有支持的 `case` 或 fun，也不声称其内部覆盖。
特性选择仍由 compiler 和源 `-feature` 属性控制。OTP 27 comprehension、
`maybe` fixture 在普通和插桩编译间比较。

EPP 在转换前处理 header/macro。manifest 保留 include 文件边界。
使用 `erl_anno` API，编译器提供时保留列。ID 区分同行 clause。转换生成抽象
forms，不用正则改源码。

探针前置于原 body，不引入变量、wrapper 或在尾调用后加代码。原表达式不重复
求值、不跨异常边界移动。receive timeout 表达式位置不变；选择匹配与 clause
顺序不变。测试比较受控 mailbox、side effect、返回、异常 class/reason 和
相关栈帧。AST 测试验证递归尾调用仍最后；20,000 步运行也完成。

这是所测构造的功能保持，不保证时间、reductions、内存、调度或检查全部字典键
等价。目标不得改 EFZ 上下文/ETS 行。ETS 为 public 以允许执行进程插入，
不是 VM 内安全边界。

## 编译与选择 API

```erlang
{ok, Artifact} = efz_instrument:compile("src/my_parser.erl", #{
    modules => [my_parser],             % 显式允许列表；绝不选全部依赖
    source_root => ".",                % 源码和本地头文件共同根
    outdir => "_build/efz-targets",      % 独立于普通构建
    erl_opts => [debug_info, warnings_as_errors,
                 {i, "include"}, {d, 'MY_FEATURE'}, {d, 'LIMIT', 256}],
    code_paths => ["_build/default/lib/my_dependency/ebin"],
    strict => true
}).
{ok, Manifests} = efz_instrument:preflight([Artifact]).
```

先 `rebar3 compile`，将 EFZ ebin 放入 compiler VM 代码路径。Facade 确保
transform 已加载。编译不启动 EFZ/活动，使用 `compile:noenv_file/2` 和显式
选项，刻意排除环境 `ERL_COMPILER_OPTIONS`。明确重现项目 include、macro、
feature、code-path。相对路径从调用 VM cwd 解析。临时代码路径返回时还原；
同 VM facade 调用须串行，并发编译器用不同输出目录。

拒绝其他 parse transform（包括源 `-compile` 属性）、输出模式选项和替代输出
目录，不允许 manifest 后偷偷再转换。其余 record/type/spec 属性保留。
输出目录不能是源码目录、活跃 code path 或含普通 BEAM。只有 facade 编译后写
文件，transform worker 不写。这是源编译路径，不是任意预编译 BEAM 插桩器或
Rebar3 插件。

拒绝 EFZ runtime/internal 模块与从已安装 OTP 树解析的模块。依赖仅显式编译并
允许时插桩。示例只插 `efz_example_parser`，适配器和 EFZ/OTP 仍普通。
不假设顶级 Rebar3 profile 自动插桩依赖项目。

Artifact 描述符有 `module`、`beam`、`manifest`、`build_id`、compiler
`warnings`。Preflight 要求 BEAM/sidecar，验证模式及唯一探针，安全解码
sidecar 并与 embedded manifest 精确 term 比较，再核对加载模块的
`efz_manifest` 属性和代码 checksum。已加载普通/其他构建模块拒绝，不自动
purge。切换用新 VM 或确保无用户的受控卸载。每迭代无编译/加载/purge。
准备时固定 harness/模块身份，executor 检查。case 中 hot replacement 使观察
无效，即使恢复旧 build。见[完整性契约](coverage-integrity.md)。

## Manifest 模式与可重现性

模式 1 / 插桩版本 1 将下列 map 嵌入 `-efz_manifest(...)`：

```erlang
#{schema_version => 1, instrumentation_version => 1,
  metric => clause_outcome_probe, module => my_parser, build_id => <<...>>,
  toolchain => #{otp => "27", compiler => <<...>>},
  probes => [#{probe_id => 1, function => parse, arity => 1,
               kind => function_clause,
               structural_location => [{function,parse,1},1],
               source_file => "src/my_parser.erl", line => 12, column => 1}],
  limitations => []}.
```

Sidecar `my_parser.efz-manifest` 是同一 map 的 Erlang external term 编码。
`efz_cov_manifest:from_beam/1` 取权威嵌入 map，`identities/1` 展开身份。
以模块、build、`probe_id` 匹配 `{M,B,Id}` 后读源码/结构位置。Manifest
验证每 ID 和每结构路径唯一。

Build ID 为插桩版本、OTP release、compiler 身份、规范化预处理 forms 和
相关选项的 SHA-256。ID 为局部有序 AST 遍历生成的确定整数，不脱离模块/build
解释。结构路径区分嵌套与同行 clause。无时间戳、随机编译 ID、全局计数器或
小哈希空间。

契约：相同预处理源、相关选项和支持工具链产生相同探针身份。输出目录、code
paths、仅 include 搜索路径、debug-info、warning 展示不改 ID；展开内容会改。
显式共同 `source_root` 下文件属性/注释路径相对规范化。已测相对布局相同的
根目录搬移。绝对外部 header 名和绝对 `?FILE` 等路径敏感字面仍可改 ID，
不伪装其值相同而重写。行/列变化也可改变 build。这是身份稳定，不声称 BEAM
元数据跨目录逐字节一致。

Build 包含每探针；pins 外观察拒绝，feedback 独立核对完整 build map。
新 build 要新活动/校准，不跨不兼容命名空间静默继承覆盖。双重插桩拒绝。

## 执行 API 与所有权

```erlang
Result = efz_executor:run(my_target_adapter, Input, 100, #{
    coverage => automatic, manifests => Manifests
}).
% #{execution_ref := Ref, outcome := Outcome, target_outcome := TargetOutcome,
%   elapsed_us := Us, coverage := ExactIdentities, coverage_status := ok,
%   builds := #{my_parser => BuildId}}
```

`Outcome` 为 `{ok, Value}`、`{crash, Class, Reason, Stack}`、
`{exit, Reason}` 或 `{timeout, Milliseconds}`。Error/throw 保留 class/
reason/stack，exit 异常保留阶段 1 元组。外部杀死为 `{exit, killed}`。
每种结果后覆盖可读。`{infrastructure, Reason}` 与
`coverage_status => {error, Reason}` 独立于目标缺陷；存在时 `target_outcome`
保存原结果。低层 `run/4` 需已 preflight 的 manifest；活动自动 preflight，
须 `artifacts`，自动模式不接受空/manual 回退。

`efz_cov:open/0` 创建 `{efz_context,1,ExecutionRef,Table,Owner}` 与无名 public
ETS set。`attach/1` 显式安装于执行进程 `'$efz_execution_context'`。
`snapshot/1`、`close/1` 属 owner；guardian 在根及全部受控后代终止后执行。
上下文各有 ref/table。`efz_cov_rt:hit/1` 还查 guardian 独立 PID/context
registry。缺字典上下文只有在 executor 外才 inactive。丢失/畸形上下文、非法表、
被 catch 的 hook 错误均为 sticky 基础设施错误。`coverage_observation` 区分
`valid_empty_coverage` 与损坏观察；`coverage_diagnostics` 报告未用工件。
可选 `coverage_policy => strict` 使无探针的完成活动失败。

范围为**一次执行的根及受控后代**。`efz_target:spawn/1`、`spawn_link/1`
先经独立 guardian admit，再装共享 context 并启动代码。guardian 等 process
DOWN 和 trace-delivery barriers 后捕获。普通 local spawn 被检测、以 dirty
拒绝，不假装覆盖完整。后台/远程 OTP 服务不在范围。
见[生命周期与污染 VM 策略](execution-isolation.md)。

手动兼容须显式 `coverage => manual`，`efz_cov:hit(Id)` 记 `{manual,Id}`。
`efz_executor:run/3` 用此模式，返回旧 outcome tuple。活动不可混合两命名空间。
旧 `reset_local/0`/`snapshot/0` 为进程局部；普通用户优先显式
open/attach/snapshot/close，不能 reset executor 所属 context。

## Feedback 与工件

仅一个 worker。初始种子同路径运行，在变异前初始化成功全局集。
`calibrations` 与变异 `executions`、`discoveries` 分开。

成功输入新颖性为 `Observed - Global`。新成功观察并入全局；非空 novelty
的新 binary 入 corpus。重复拒绝，不制造发现。崩溃/exit/timeout 独立保存，
**其覆盖不并入成功全局集**，使后续非崩溃输入仍可保留只在崩溃见过的探针。

每次保留含 SHA-256、corpus/父身份、执行引用、新身份、原因、phase 和 build
map。最终 `efz:await/1` 含 decisions、corpus、crash、stats、成功覆盖。
相同拒绝执行用计数汇总。崩溃发生是
`crash_dir/SIGNATURE/OCCURRENCE/artifact.input`、`.term`、`.replay`、可选
`.recipe` 原子目录，带 manifest。原 `.term` 保留结果元数据（含崩溃/超时覆盖）。
见[崩溃/重放/报告](replay.md)。这些 term 是本地诊断，不是安全导入格式。

## 可复现验证与开销

`rebar3 eunit --module=efz_phase2_tests` 覆盖语义比较、所有必要 probe kind、
不支持语法诊断、跨模块、上下文分离、同输入重复性、kill、timeout、owner 死亡、
取消、backend 失败、身份/搬移、preflight、feedback。终止测试等预期入口 hook
完成后发送的消息，不从 sleep 推测已命中。期限边界接受已文档化的完成或超时，
并查下一次隔离。普通/插桩比较只在先前目标进程终止后卸载同模块，不改 self-qualified
调用名称。

`rebar3 ct` 三项：确定自动活动、人工崩溃覆盖、同步超时覆盖。五输入 scripted
mutator 只在 `test/`，不是生产 mutator 或随机 fuzz 成功声明。
`examples/automatic/run.escript` 还用原阶段 1 random mutator 跑 500 次。
见[验证记录](phase2-validation.md)。

`rebar3 compile` 后运行 `escript scripts/coverage_bench.escript`。同 fixture
按受控顺序普通/插桩加载，各路预热后测七次 200,000 尾循环迭代。活跃测量复用
一个上下文以暴露 probe 成本，不是端到端 fuzz exec/s。输出时间、reductions、
进程内存快照、编译时间、精确 ETS 大小、探针数，无性能门槛。测 EFZ hooks，
非 OTP cover。OTP 27 / ERTS 15.0；x86_64-pc-linux-gnu。fixture
`efz_bench_fixture`，每样本 200000 次，7 重复，各模式预热 30,000 次。

| 模式 | 中位 us | 相对 | 样本 us | Reductions（末样本） |
|---|---:|---:|---|---:|
| ordinary | 518 | 1.00x | [619,517,517,517,530,518,518] | 200013 |
| instrumented_inactive | 5315 | 10.26x | [5315,4438,4260,4203,5532,5467,5581] | 1000017 |
| instrumented_active | 67209 | 129.75x | [71060,66993,67233,67125,67095,67232,67209] | 1401177 |

活跃表 419 words（8 字节/word），manifest 六探针全到达，测后删表。
编译普通 3387 us、插桩 62202 us（单次测量，含冷准备）。无正确性阈值。
内存快照在 `_build/coverage-benchmark.term`。

数据于 2026-09-08 本地测得。极小普通循环被高度优化，不到 1 ms，不应把比例
外推真实 parser。此运行活跃收集约为 inactive 路的 12.6 倍。ETS insert/copy
成本可测；reductions 从 200,013 增到 1,401,177。末样本进程内存普通
8,816 -> 8,816 字节、inactive 13,704 -> 13,704、active 21,696 -> 55,176；
只是快照，不是峰值估计。重复 hit 下表保持六条，完成删除。

下个优化候选是执行局部已记录 cache，先立即将首次 hit 写到 owner ETS 再 cache，
可减少重复写并保留突然终止覆盖；采用前须生命周期/backend 失败测试。当前刻意
让每 hit 同步访问外部存储。

限制仍为单 worker、一次带受控后代执行、测试工具链下源编译、显式模块、上述跳过
语法。其他 parse transform、只有预编译 binary、任意后台归因、有状态 OTP
活动、完整 CFG/分支/状态覆盖、所有共享 VM/OS 效应隔离均未实现。

## 阶段 2.1 运行选择与报告

默认 `ets` 现在用 `ets:insert_new` 并在首插入通知 guardian，可检测表中已发布
观察丢失。可选 `ets_member` 先 `ets:member`，不存在才写。**无进程局部 seen
cache**、压缩/哈希 ID、采样或延迟发布。每 hit 仍访问外表；首 hit 后删除
backend 不会让缓存后续 hit 假成功。首次观察多一次 lookup 可能更慢。
两 backend 不改插桩、manifest、build ID、源码映射。

活动默认一次准备精确 allowlist。worker 拥有无名 **protected**
`efz_coverage_plan` ETS，包含原验证器每次重建的相同身份，加 schema/mode/build
marker 及所选已加载模块身份。guardian 在根/后代结束后验证 marker 与每个
观察身份，只接收执行选项和 plan handle，不接收 worker corpus/decision 状态
与完整 manifest。这是共享不可变 allowlist，不是复用覆盖缓冲。观察表仍新建
public、执行所有。Plan 跨执行存在，随 worker 删除，不跨活动复用。非法/已删
plan 导致基础设施失败，即使快照本来为空。

```erlang
% 阶段 2.1 的默认活动设置：
#{coverage_backend => ets, coverage_validation => prepared}.
% 每次执行验证 manifest，保留供比较：
#{coverage_backend => ets, coverage_validation => per_execution}.
% 可选抑制重复写入（兼容两种验证器）：
#{coverage_backend => ets_member, coverage_validation => prepared}.
```

低层重复 `run/4`，在 artifact preflight 后显式准备：

```erlang
{ok, Manifests} = efz_instrument:preflight(Artifacts),
{ok, Plan} = efz_cov_manifest:prepare(automatic, Manifests),
try
    efz_executor:run(Target, Input, Timeout,
        #{coverage => automatic, coverage_backend => ets, coverage_plan => Plan})
after
    efz_cov_manifest:release(Plan)
end.
```

`prepare/2` 检查 manifest/schema 版本、probe 唯一、自动选择非空、模块无重复。
不加载/查看工件，先 `preflight/1`。Plan 是 `{efz_cov_plan,1,Table,BuildMap}`，
marker 绑定模式与 build。Backend 独立，两 ETS hook 发布同身份。
worker 启动前配置验证 backend。

Plan owner 须维持到其执行完成。低层它是只读 capability，可传其他调用者为
同选项/build 复用；其他调用者不能写 protected 表。不绑定执行 ref，只有观察
存储绑定。所有用户完后由 owner release，owner 死亡也自动删表。已销毁表、
改 build map、错 mode、描述符不兼容无法验证空快照。版本畸形是基础设施错误，
非目标崩溃。允许另一个 owner 的有效 plan。

活动完成后 worker/plan 为报告保留到 `efz:stop/0` 或应用关闭。新活动建新
plan。Plan 不是 hot-reload cache，代码整个期间须不变。Preflight 拒绝已加载
普通/其他 build；观察验证拒绝 pins 外身份。预检后换成不发探针代码不能由集合
验证检测。一次准备不保证任意热加载下正确。

只有 `manifests` 的 `run/4` 为兼容保留 per-execution validation。
`efz_cov:open/0` 保留参考 backend；`open(ets_member)` 选替代。
Context 仍 schema 1，替代存储槽为 `{ets_member, Table}`，内容仍属 EFZ。

报告区分四概念，不改 merge 策略：

* `Result.coverage`：本次精确观察，含异常、外部 kill、超时前观察。
* 活动 `coverage`：成功校准/执行观察的并集。
* 保存 crash `result.coverage`：该崩溃观察，可有活动全局不存在的探针。
* Decision `new_probes`：可让成功输入保留的新颖性。对于
  `retention_reason => target_failure` 刻意为 `[]`，即使 crash 首见 probe。
  崩溃独有观察不并入成功全局。

追加 `timing` map：`calibration_started_at`（单调微秒）、`calibration_us`、
`mutation_us`。后者不含校准和最终报告构建/打印，包含选择、变异、执行、验证、
反馈、统计与崩溃 I/O，不只是目标运行。Benchmark 启动/清理另报。

可选 `selection_seed` 初始化 corpus 选择 RNG；`random_seed` 仍初始化 worker
mutator RNG。无 `selection_seed` 保留旧选择行为；仅设 `random_seed` 不能
完全确定活动。可复现比较设二者或重放保存候选流。Benchmark replay 在 `bench/`，
不在生产 mutator。

见[阶段 2.1 剖析、测量、取舍及复现](phase2.1-performance.md)。上方阶段 2
表是历史数据，不是性能常数。

## 诊断重复执行

可选[runtime diagnostics](runtime-diagnostics.md)比较含 build 的精确执行探针
集合。Verification 覆盖从不并入活动反馈，不屏蔽易变探针。非法/未开始观察不是
空覆盖。有效空序列的可重复性与 stable-probe ratio 为 100%，带明确标记。
