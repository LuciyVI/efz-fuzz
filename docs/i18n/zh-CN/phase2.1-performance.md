# 阶段 2.1 性能与收尾记录

[English](../../phase2.1-performance.md) · [Русский](../ru/phase2.1-performance.md) · [Español](../es/phase2.1-performance.md) · **简体中文** · [所有语言](../README.md)

于2026-09-09本地关闭。默认**prepared验证加原精确ETS hook**。Membership仍
可选。Preparation改善所测完整parser及稀疏执行/活动；membership有利重复hit，
但惩罚首观察，在稀疏活动无可靠优势。未为这些结果改变探针、timeout、身份或保留
规则。

## 环境、基线与来源

仓库为所供工作区下`efz/`。无适用AGENTS.md或formatter/linter配置。树已脏，
大部分阶段1/2源码未跟踪。与保存的阶段2快照`/tmp/efz-phase21-baseline`比较
确定本阶段变更，单看Git status不能区分。无clean/reset、暂存、commit、身份、
remote或push。

进入2.1时compile、24 EUnit、3 CT、Dialyzer/xref通过。中断实现随后通过
36 EUnit及其余相同检查。收尾加两专项并修一工件加载bug，最终**38 EUnit通过**。
无环境阻塞。历史阶段2见[phase2-validation.md](phase2-validation.md)，为观察
非测试常数。

最终无profile吞吐及所有内存VM记录：

* OTP27.0、ERTS15.0、Rebar3 3.25.0、JIT、8字节word。
* Ubuntu24.04.4 LTS、Linux、x86_64-pc-linux-gnu、Intel Core i7-1260P。
* `ERL_FLAGS='+S 4:4'`：4 scheduler、4在线、4 dirty CPU scheduler。
* `compile:noenv_file/2`、debug_info、warnings_as_errors，严格插桩、显式模块
  allowlist、`source_root => "."`、独立目录。吞吐无profile，无自定义NIF、
  port runner或外部引擎。

进入2.1时真实重跑原紧循环：200,000次、七预热样本，普通/inactive/active中位
**766 / 2,218 / 33,407 us**，不同于早先518/5,315/67,209，不独立复现精确
旧数。原样本存档，但该工件未记录scheduler，不与四scheduler比较混合。
原示例也完成500变异、1校准、4发现、494拒绝、2崩溃/1唯一。

权威完整工件：

| 组 | 内容与完成证据 | 适用 |
|---|---|---|
| `_build/performance-final/{environment,hooks,executor,campaign}.term`和`.txt`、`summary.txt` | 36 hook、12 executor、24 campaign行，各五样本。完整命令退出0，进度日志以保存六campaign结束。Audit重算每中位/min/max，压缩前比完整canonical对象 | 当前hook/executor/feedback/变异时间；旧startup下文替代 |
| `_build/performance-final/*-candidates.term` | 完整预录loop/parser/sparse序列 | 各变体同输入顺序；持久证据也含 |
| `_build/performance-memory-{reference,member,prepared,prepared_member}/` | 四独立VM，均完整保存环境和内存；循环命令退出0 | 收尾preflight修复前观察 |
| `_build/performance-final/profile-sparse-prepared.txt` | 完整eprof表及`Total: 6331`，命令退出0 | 仅专项诊断，prepare/load不在profile |
| `_build/performance-final/automatic-example.{term,txt}` | 完成报告，有发现/崩溃，无基础设施；命令序列0 | 先前示例，命令**未**设ERL_FLAGS，未记录scheduler，不假定4 |
| `_build/phase21-closeout-startup/` | 每fixture/变体五个预热零变异样本，退出0 | 当前preflight启动/校准 |
| `_build/phase21-closeout-memory-*/` | 四新独立VM，完整有界内存，退出0 | 修复后观察 |
| `_build/phase21-closeout-fixed/` | 最终日志、更新示例、工件audit | 当前源验证；示例明确+S4:4 |

恢复工作时没有中断会话残留benchmark进程。不以文件存在/修改时间证明完成。

[持久证据](../../performance/phase2.1-samples.term)含原样本与范围、startup、两套
内存（含/proc/self/status）、紧凑环境、完整build/source/input身份、工件 SHA-256 哈希、
profile表、验证日志、示例/终止结果及候选。运行ref/PID明确替为
`runtime_reference_omitted`/`runtime_pid_omitted`，使副本可consult。
重复campaign对象**精确比较后**才换digest，原完整check留忽略的原文件。
Digest只是归档辅助，不是differential oracle。

来源限制明确：旧harness记fixture哈希、编译选项、build和环境，无测量时整树
哈希。收尾回溯记录source哈希，以记录选项重编当前22个应用BEAM，比MD5/抽象
forms，重建三fixture身份，核对各组保存BEAM/sidecar term和源哈希。
原成功记录与热路径源不变证明连续性，不声称原签名Git版本或同时整树快照。

Audit发现阶段2预检缺陷：等价ETF map跨VM可序列化为不同键序，逐字节比较误拒
有效sidecar。`efz_instrument`现在安全解码并和已验证embedded manifest精确
term比较，仍拒绝坏编码/变化。确定逆键编码和新VM regression覆盖。
变化只在加载，不在probe/execution/mutation。只重测启动/校准、内存、示例，
无需重跑吞吐/profile。

## 变体与公开默认

名称由`bench/efz_perf.erl`的backend/1、prepared/1及活动选项定义：

| 变体 | 验证策略 | 覆盖存储/hook |
|---|---|---|
| `reference` | `per_execution`：每次从manifest重建精确allowlist | `ets`：每hit原始插入 |
| `member` | `per_execution` | `ets_member`：先查成员，只在缺时插 |
| `prepared` | `prepared`：一个protected allowlist、紧凑executor选项 | 原`ets` |
| `prepared_member` | `prepared` | `ets_member` |

`efz_config:defaults/0`及`efz:start/1`、普通自动示例选择prepared+ets。
旧配置无这些选项也得新验证默认，feedback不改。可选hook：

```erlang
coverage_backend => ets_member
```

完整参考配置：

```erlang
coverage_backend => ets, coverage_validation => per_execution
```

`efz_cov:open/0`仍原ETS。只有manifest的低层run/4仍每次验证，不隐式建共享
plan。run/3保留manual。二hook保持schema1与精确身份。

评估两专项：插前membership、prepare验证/避免复制完整worker状态。
未引入atomics、压缩/哈希ID、进程局部cache、异步发布或目标final flush。
Membership每hit仍查外表，删表不会被cache隐藏。

## Prepared-validation 边界

公开preflight验证工件、embedded模式/版本、sidecar等价、描述符build、已载
模块身份。Target adapter无需插桩，显式选模块必须。配置拒错backend/validation
和多worker。

`efz_cov_manifest:prepare(Mode, Manifests)`独立验证格式、唯一ID/结构路径、
自动选择非空、模块无重复，建`{efz_cov_plan,1,Table,BuildMap}`。
无名**protected**ETS含全部精确身份和`'$efz_plan'`mode/build marker。
Prepare不加载，低层先preflight。两hook格式一致故plan通用。

Worker拥有plan，每coordinator只传coverage/backend/plan，去掉重复集合构建
及完整manifest/worker复制。低层caller可在owner存活时共享plan：只读能力，非
campaign ID/context，外进程不能写。用户全停后owner释放，owner死自动删。
活动完成仍保留worker/plan/corpus/report 到 `efz:stop/0` 或应用关闭；另活动另plan。

每执行仍新ref、target和coordinator所拥有public ETS观察集。Attach检查owner，
每hit访表。目标终止后即使空快照仍查marker，并对**每观察身份**查allowlist；
feedback也核对build。已销毁/不符plan、坏表为基础设施结果，非bug/有效空。
畸形版本可能返回coordinator_down而非更精确invalid_coverage_plan，均非成功。
描述符形状仍有效时过期plan可保留观察但附错误状态。

新生命周期测试覆盖外写保护、共享读/重复用、错schema/mode/build、同步执行中
owner死及**零观察**释放后拒绝。既有测试覆变build、坏manifest、删表、caught
hook错误。

所选build须整个plan/活动不变。预检拒已载普通/异build；观察拒意外新probe。
两者不证明任意之后代码替换安全，尤其换成无hook代码。Hotcode管理/reload安全
cache不属契约。

## 方法与负载

每例丢pilot或完整warmup后五样本，各轮交替逆变体顺序。Executor pilot按近
180ms选批（128–20,000），数量可能不同，下文归一。活动每样本2,048变异加
单独计时种子。此界让慢reference可行，快批仍几十毫秒非亚毫秒。
不声称机器阈值/置信区间，范围为观察min–max。

| Fixture | Manifest探针 | Executor观察 | 输入/工作及核对结果 |
|---|---:|---:|---|
| `efz_bench_fixture` | 6 | 6 | `run(1024) = 2304`；尾循环20,000,000次，校验45,000,000 |
| `efz_perf_parser` | 20 | 10 | 32份`<<0,0,7,1,35,2,2,97,98,3,2>>`；352字节，`{ok,128,1888}` |
| `efz_perf_sparse` | 2,051 | 2 | `<<0,7>>`，结果22；生成2,048显式choice，加fallback/入口 |

收尾后不变的build：

```text
loop    943bea4cf9695048788654bbe520185c78611ad26733a1066989d28e4b0fd80d
parser  c966463003a8d5244d58710e533634f4003faeece71c7a9d61fdfa2559df2351
sparse  bf27f5190ec9b6744e8d20179a0c9110ae265238ac22fe4d70b2add7645f5534
```

普通/插桩fixture在无活目标时受控加载比较，不重命名近似。
完整executor计run/4到coordinator结束清理，含context、进程/monitor、目标、
快照、验证、删除。每结果/status/canonical probes都比reference。
Plan准备在计时外另记（sparse603µs prepared、431 prepared-member，单次非
稳定setup benchmark）。

活动mutation时钟含选择、真变异、executor、反馈、保留、stats、crash I/O；
排编译、校准、最终报告。API-start/stop另记。设置变异seed{17,23,41}与选择
{101,109,113}；后者为新可选配置，默认无seed选择不变。

Replay循环保存序列，仅benchmark；real用efz_mutator_random。
四变体、每模式负载五重复的sanitized覆盖、corpus字节、decision/newprobes、
crash结果、stats精确相同。Loop校准六probe无新增；parser replay/real总corpus
5/10、成功probe15/19；sparse9/538、10/540。包含不同保留/元数据工作，不只重复写。

## A. Hook 成本

以下重复观察用2,000,000次直接hook、2051探针sparse manifest真实完整身份与
预发布集。单位**每批ms**，中位[min–max]；inactive也同调用循环。

| 不同探针 | Inactive | ETS reference | Membership | Reference/member耗时比 |
|---:|---:|---:|---:|---:|
| 1 | 15.208 [14.648–17.336] | 182.385 [179.183–185.007] | 118.594 [114.060–123.957] | 1.54x |
| 8 | 9.673 [8.811–10.222] | 176.121 [174.143–179.749] | 111.413 [110.601–115.619] | 1.58x |
| 64 | 8.670 [8.553–8.829] | 177.991 [176.712–180.876] | 112.828 [112.526–113.132] | 1.58x |
| 1,024 | 8.595 [8.534–8.792] | 189.348 [186.503–194.945] | 125.183 [124.630–128.117] | 1.51x |

调用循环/list遍历也计入，故inactive随distinct batching变化。
500,000次结果也全留。测真实 `efz_cov_rt:hit/1`，不把全部归因process-dictionary lookup。

首观察用新预分配context，计attach/首次发布，不计分配/快照/删除，之后核对
全部集。刻意多活context以隔离写；生产仍单worker单执行。

| Hook次数 | 每context探针 | Context数 | ETS ms[范围] | Member ms[范围] | Member增时 |
|---:|---:|---:|---:|---:|---:|
| 131,072 | 64 | 2,048 | 15.168 [14.983–16.831] | 20.565 [20.091–22.281] | 35.6% |
| 524,288 | 64 | 8,192 | 87.746 [87.056–92.194] | 112.473 [110.292–121.294] | 28.2% |
| 131,072 | 1,024 | 128 | 20.230 [19.191–20.427] | 25.031 [24.558–25.196] | 23.7% |
| 524,288 | 1,024 | 512 | 91.261 [90.249–91.978] | 113.625 [111.488–115.044] | 24.5% |

原loop fixture，20,000,000迭代：

| 模式 | 中位ms[min–max] | 相对普通 |
|---|---:|---:|
| 普通 | 35.087 [32.072–35.191] | 1.00x耗时 |
| 插桩inactive | 227.358 [220.167–229.080] | 6.48x耗时 |
| 插桩ETS | 4,046.383 [3,962.962–4,088.383] | 115.32x耗时 |
| 插桩membership | 2,593.771 [2,503.256–2,614.029] | 73.93x耗时 |

六probe全触发，共40,000,002 hook。此合成loop membership比ETS快1.56x，仍有
大量插桩成本。无preparation参与，不把hook比例当活动吞吐。

## B. 完整 executor

**us/执行**，中位[min–max]。N按reference/member/prepared/prepared-member
列批量。同一行fixture输入、精确结果/probe集相同。

| Fixture；N | Reference | Member | Prepared（默认） | Prepared-member |
|---|---:|---:|---:|---:|
| Loop；808/1,260/860/1,335 | 230.853 [221.092–235.197] | 149.522 [142.960–157.459] | 221.483 [213.171–231.353] | 142.897 [138.843–144.178] |
| Parser；4,105/4,974/4,975/6,386 | 50.392 [48.179–50.662] | 40.454 [37.910–41.297] | 37.471 [37.168–39.381] | 27.998 [27.633–29.012] |
| Sparse；132/129/17,311/20,000 | 1,331.235 [1,241.583–1,623.515] | 1,624.434 [1,409.581–1,770.605] | 7.405 [7.234–7.943] | 7.582 [7.034–7.607] |

Reference/default中位比1.04x/1.34x/179.76x。Loop小改范围重叠，证据弱。
巨大sparse收益移除了每次两hit执行按2051manifest增长的工作，不是一般Erlang
加速。Membership sparse reference中位**慢22%**且范围宽重叠；prepared下
慢2.4%，也不能精细定论。

## C. 完整活动

每样本**2,048变异加一次独立校准**。变异**ms/批**，中位[min–max]。
Manifest/成功probe见方法；不同模式不可混均值。

| Fixture/模式 | Reference | Member | Prepared（默认） | Prepared-member |
|---|---:|---:|---:|---:|
| Loop/replay | 140.439 [130.715–150.496] | 114.871 [104.974–124.499] | 124.164 [121.846–134.971] | 94.616 [87.827–102.950] |
| Loop/real | 157.566 [149.826–177.073] | 120.003 [112.035–142.344] | 139.574 [128.366–141.977] | 106.589 [99.934–111.639] |
| Parser/replay | 162.143 [147.937–163.049] | 138.111 [133.298–174.021] | 111.907 [109.947–115.914] | 99.370 [85.961–111.084] |
| Parser/real | 122.444 [115.189–129.781] | 111.796 [107.400–115.664] | 95.287 [91.475–99.000] | 85.973 [81.385–91.675] |
| Sparse/replay | 2,842.573 [2,738.130–2,892.657] | 2,910.044 [2,882.867–3,023.839] | 33.266 [31.554–33.738] | 34.619 [31.641–40.462] |
| Sparse/real | 3,939.023 [3,409.309–4,382.920] | 3,750.131 [3,152.201–4,191.928] | 49.230 [46.300–78.594] | 47.972 [39.963–75.125] |

| Fixture/模式 | Reference变异/s | 默认变异/s | 默认速度比 |
|---|---:|---:|---:|
| Loop/replay | 14,583 | 16,494 | 1.13x |
| Loop/real | 12,998 | 14,673 | 1.13x |
| Parser/replay | 12,631 | 18,301 | 1.45x |
| Parser/real | 16,726 | 21,493 | 1.29x |
| Sparse/replay | 720 | 61,564 | 85.45x |
| Sparse/real | 520 | 41,601 | 80.01x |

Prepared再加membership使loop中位改善1.31x，parser replay1.13x/real1.11x。
Sparse replay慢4.1%，real快2.6%，范围重叠且大离群。这支持可选重复hit优化，
非普遍换backend。无未解释整体加速；reference含原每次集合构建/复制，仍用于
差分。

当前**startup**为sidecar修复后零变异活动，完整预热加五次交替。该VM三fixture
普通/插桩编译共1,174,788us（单冷构建）；原final为575,889。含编译器启动/
加载，不是编译速度比较。校准前startup / calibration / stop中位us：

| Fixture | Reference | Member | Prepared | Prepared-member |
|---|---:|---:|---:|---:|
| Loop | 220 / 148 / 650 | 210 / 132 / 640 | 215 / 125 / 640 | 232 / 115 / 653 |
| Parser | 349 / 178 / 646 | 366 / 162 / 651 | 344 / 156 / 655 | 357 / 139 / 643 |
| Sparse | 19,318 / 3,392 / 1,378 | 20,327 / 4,129 / 1,629 | 22,710 / 156 / 1,765 | 21,215 / 152 / 2,685 |

短startup仅诊断，非主吞吐。Sparse startup范围18,864–20,533 /
19,100–22,979 /20,341–24,678 /19,610–27,023us。全部原startup/calibration/
API-start/cleanup样本范围归档。`api_start_us`重叠worker初始化/校准，不可再加
`startup_us + calibration_us`。旧值保留，但当前测量由本次替代。

## 内存与清理

内存采样和吞吐分开。每变体新VM：编译/load、GC后快照、可选2051ID plan、
attach context、八ID共80,000hit、活态快照、close/release/GC，再带sampler跑
有界5000变异sparse replay并全停。名义2ms间隔采VM/ETS/process峰，读取自身
耗时使实际间距更长。这是**采样峰**，非绝对峰或无profile吞吐。

原观察（VM总量十进制MB）：

| 变体 | 之前 | 带plan | 活context | 清context/plan后 | 活动清理后 | VM采样峰/样本 |
|---|---:|---:|---:|---:|---:|---:|
| Reference | 57.143 | 56.191 | 61.645 | 56.205 | 54.809 | 81.542 / 2,315 |
| Member | 57.124 | 56.169 | 56.202 | 56.165 | 54.775 | 87.575 / 2,367 |
| Prepared | 59.509 | 58.720 | 64.187 | 58.448 | 57.104 | 77.915 / 34 |
| Prepared-member | 59.335 | 58.680 | 64.137 | 56.810 | 56.963 | 76.673 / 34 |

收尾preflight修复后同有界协议：

| 变体 | 之前 | 带plan | 活context | 清context/plan后 | 活动清理后 | VM采样峰/样本 |
|---|---:|---:|---:|---:|---:|---:|
| Reference | 56.129 | 56.154 | 61.597 | 56.135 | 54.749 | 84.452 / 4,534 |
| Member | 57.339 | 57.356 | 57.389 | 57.387 | 55.924 | 91.795 / 4,429 |
| Prepared | 58.326 | 58.640 | 64.107 | 58.371 | 57.007 | 84.378 / 76 |
| Prepared-member | 56.274 | 56.579 | 62.062 | 54.741 | 54.926 | 79.588 / 71 |

更新后每次清理都回**41进程、零观察表、零plan表**。活观察仍3656字节；plan
使ETS增300,072–300,096。ETS采样峰517,624/517,912/820,288/818,016字节，
进程峰仍52。最终ETS515,976/515,872/515,968/516,264。这些是观察非后机阈值。

如prepared的VmRSS带plan125,952kB，清活动后125,476；VmHWM保持早先240,416。
Prepared-member RSS反升133,776→137,428kB，但EFZ表全释放。因此RSS/VM总量
不能单独证泄漏或无泄漏。新运行含改变的启动分配，采样峰不同不归因backend优化。

原各变体活时一表，**八探针3656字节**，后零。Prepared另持plan，2051身份和
marker使总ETS增300,072。它是term精确key set，非packed bitmap。整VM活内存
含heap/allocator/compiler预热，列相减不能隔离plan。旧六hit表3352字节，
与不同观察集一致。

原总ETS峰517,424/517,624/817,464/817,752。四VM两清理边界均41进程、零覆盖/
plan表，进程峰52。最终ETS比早快照多约18KB来自其他VM/app状态，不证明执行表
泄漏。

before到with_plan即使未分配plan也已大幅波动，属于冷启/预热和GC/allocator
观察。Prepared活动更短、样本少，小采样峰不证明绝对峰小。归档单列RSS及生命
VmHWM，均不同于erlang:memory(total)或ETS words。

明确资源释放比相似VM总量证据更强：等monitored目标/coordinator死、查精确表
清单，各变体50组期限/下一执行，kill持续发布目标，测caller/plan-owner死亡、
取消、应用关闭/重启。完成活动刻意保留corpus、成功覆盖、decision、唯一crash、
plan 直到 `efz:stop/0`，不是执行局部泄漏。有界证据支持所述生命周期清理，非无限浸泡或
任意VM状态无泄漏保证。

## 剖析发现与决定

原loop eprof把样本函数时间47.97%归100,002次ETS insert，30.38% 归 `efz_cov_rt:hit/1`，
21.52%归loop。Parser为insert26.52%、hook17.76%，因此试membership；首hit
测显示额外lookup成本。Profile输入32份`<<0,0,7,1,35,3,2>>`，观察七probe，
不同于吞吐十probe输入，不可直接比elapsed。

原sparse profile100完整执行、两观察、2051manifest，共205,100 allow-set
insert和3,591,131 traced calls。Set bucket update/add/rehash/hash主导；
spawn_opt另7.51%，符合把完整options/manifests复制给每coordinator。
源码确认传完整增长worker state作选项。Preparation去重复建集并传紧凑options。
未分摊两种改善，并不存在每hit扫描完整manifest可去除。

后续`sparse prepared`完成：**6,331 traced calls**、100执行、200hook
hits/inserts、200prepared member检查，不再重建manifest。最大归因spawn_opt
14.71%、ETS快照match_object13.68%、coordinator13.42%、run/4 12.71%、
ETS info7.87%、wait7.74%。1550us profile总是函数归因诊断，**非**无profile
executor批时长。

Context分配/删除、进程/monitor、快照仍固定成本。完整身份仍构建/保存，global
novelty及元数据也工作。不声称每项在所有负载都是瓶颈。未来可测snapshot/setup或
更轻精确身份，收尾未尝试。保留正确终止语义、不要求目标flush。

因此最简单受支持决定不变：**默认prepared，默认原ETS，membership可选**。
稀疏大收益来自validation/copying，单membership无可靠稀疏executor/campaign收益。

## 正确性与实际命令结果

Sidecar修复后最终序列退出0：

```sh
rebar3 compile
rebar3 eunit
rebar3 ct
rebar3 dialyzer
rebar3 xref
```

| 检查 | 实际结果 |
|---|---|
| Compile | 通过，配置warnings-as-errors |
| EUnit | 38通过：原语义/生命周期、13backend组和新VM sidecar |
| Common Test | 3集成全过 |
| Dialyzer | 22项目文件、278PLT，无警告 |
| xref | 配置未定义/弃用检查通过 |
| 工件audit | 原360计时样本自洽，canonical精确比较相同，fixture身份和当前BEAM/源码验证 |
| 自动示例，+S4:4 | 500变异、1校准、4发现、494拒绝、2crash/1唯一、0timeout/基础设施 |
| `git diff --check` | 通过 |

负例预期含严格语法诊断和故意错plan版本coordinator错误，断言基础设施/清理，
不是未知回归。首收尾37测试在跨VM缺陷发现前已通过。Audit先拒非canonical
sidecar字节，该失败促成窄修复，不是基线失败。

精确差分测return、嵌套clause、跨模块、重复hit、error/throw/exit、同步kill/
timeout、完成/期限、隔离context、坏存储、缺/错build、确定corpus/crash决定。
原plain/instrumented语义及尾位置测试不改且通过，不弱化预期迁就backend。

当前具体证据：种子<<0>>后真实mutator保留`<<>>`为条目3、父2、new_coverage、
probe2；映射`efz_example_parser:classify/1`、
`examples/simple_parser/efz_example_parser.erl:7`，build
`5f11a3a9df248ba517a1ae78cfad9462d6c6453bc0565bfe27089fa4a8239b6a`。
五候选确定测试另证重复拒绝和人工crash后保留，输入/ID非核心硬编码。

`<<255,0>>` 人工 crash 保存 probe 7 和 `coverage_status => ok`，而 decision 为 `target_failure`、
`new_probes => []`；成功全局为{2,3,4,5,8,9}。字段不同：执行观察含crash hit，corpus
novelty/成功全局排除crash-only。首人工crash后仍继续保留<<0,0>>，无须改变
报告策略。

最终终止快照error精确{30,66}、throw{30,65}、exit{30,67}、外kill/timeout{58}，
build `19b2e8635273c78d98eb79d7bb4c2b11d1b94e4da9608e217d5636864fd80096`。
全部为 `coverage_status => ok`。差分比较完整模块/build/probe。Kill/timeout等明确
发布后消息，timeout只在目标终止后返回。

## 复现

从efz根执行。新测用**新输出目录**，保留归档。下列用不同reproduce-*目录和
当前保留reference：

```sh
rebar3 compile
rebar3 eunit
rebar3 ct
rebar3 dialyzer
rebar3 xref

ERL_FLAGS='+S 4:4' escript bench/run.escript all _build/reproduce-performance
escript bench/report.escript _build/reproduce-performance

for EFZ_VARIANT in reference member prepared prepared_member; do
  ERL_FLAGS='+S 4:4' escript bench/run.escript memory \
    "_build/reproduce-memory-$EFZ_VARIANT" "$EFZ_VARIANT" || exit
done

ERL_FLAGS='+S 4:4' escript bench/run.escript startup _build/reproduce-startup
ERL_FLAGS='+S 4:4' escript bench/profile.escript sparse
ERL_FLAGS='+S 4:4' escript bench/profile.escript sparse prepared
ERL_FLAGS='+S 4:4' escript bench/profile.escript parser
ERL_FLAGS='+S 4:4' escript bench/profile.escript loop
ERL_FLAGS='+S 4:4' escript examples/automatic/run.escript
```

all跑hooks、executor、real/replay活动；单stage和可选variant可选有界子集。
startup明确零变异，不是吞吐benchmark。Profile与最终计时分开。
`escript scripts/coverage_bench.escript`复现较旧小七样本loop，普通批低于1ms。

收尾专用归档命令读指定原/新组，验证后写可consult新证据：

```sh
ERL_FLAGS='+S 4:4' escript bench/archive.escript \
  _build/performance-final _build/phase21-closeout-evidence.term
```

需这些保存组目录，只为本记录audit，非portable benchmark。交付物在
`docs/performance/`含结果，读者无需被忽略_build也可看样本/元数据。
无build目录加入Git。

## 变更文件与剩余限制

相对阶段2快照，runtime/集成改`efz_cov`、`efz_cov_rt`、`efz_cov_manifest`、
`efz_executor`、`efz_worker`、`efz_config`、`efz_corpus`、`efz_fuzzer`，
另有收尾`efz_instrument`。新增 `test/efz_backend_tests.erl`，并在 `test/efz_phase2_tests.erl` 中加入 sidecar
回归。Benchmark/replay/profile/archive在bench/，普通parser/sparse fixture
在fixtures/performance/。文档README/architecture/coverage/此报告和紧凑持久
证据。Rebar配置、transform、变异、feedback规则、普通示例在2.1保留。

所测本地契约验收完成，无所需结果被阻。仍限OTP27.0、单生产worker、覆盖显式
附着目标、每活动固定build、源码clause/outcome和已述跳过语法。插桩改变时间/
分配。任意spawn、hot reload、stateful OTP和完整VM/OS隔离不支持。
非专用单机五样本不证普遍加速/绝对峰。Prepared内存随manifest增长，membership
保留首hit成本和负载依赖。
