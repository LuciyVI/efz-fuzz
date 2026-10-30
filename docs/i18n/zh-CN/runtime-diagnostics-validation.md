# P0 验证——2026-09-16

[English](../../runtime-diagnostics-validation.md) · [Русский](../ru/runtime-diagnostics-validation.md) · [Español](../es/runtime-diagnostics-validation.md) · **简体中文** · [所有语言](../README.md)

## 工作副本与环境

- 初始提交：`205e18ba172d74bd6c652a68abfc73e02e4a1f86`。
- Ubuntu 24.04.4 LTS，x86_64，内核 `6.8.0-nyx+`。
- Erlang/OTP 27.0，ERTS 15.0，Rebar3 3.25.0。
- Rebar3 和基准使用 `ERL_FLAGS='+S 4:4'`；外部危险生命周期样例在 `timeout 10s` 下使用 `erl +S 2:2`。
- 工作副本和父目录未发现适用 AGENTS.md。
- 初始工作副本含覆盖及 hit-count、语料、CLI 和文档修改：
  [完整初始状态](../../runtime-validation/preexisting-status.txt)。
  初始差异保存到 `/tmp/efz-p0-baseline/preexisting.diff`。
  未执行 reset/clean、分支更新、commit/push。
- 未编辑现有测试驱动和目标文件。新目标仅位于 `fixtures/runtime/`。
  P0 未触及的 11 个无关修改文件与保存初态逐字节匹配。
- [本任务专有修改文件](../../runtime-validation/changed-files.txt)。

实现前已存在 guardian 所有权、开始门、监视器、追踪屏障、执行范围覆盖和完整性、
dirty-runner 退役、崩溃分组、原始及配方重放和单次校准。
重复验证、采样器和运行时存储与重放原先不存在。
根据实际工作副本检查了现有反馈循环；新增重复不调用反馈、保留或计划器。

## 命令与结果

每条命令从工作副本根目录执行：

```sh
ERL_FLAGS='+S 4:4' rebar3 compile
ERL_FLAGS='+S 4:4' rebar3 eunit
ERL_FLAGS='+S 4:4' rebar3 ct
ERL_FLAGS='+S 4:4' rebar3 dialyzer
ERL_FLAGS='+S 4:4' rebar3 xref
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_runtime_tests
```

| 检查 | 初始工作副本 | 实现后 |
|---|---:|---:|
| compile | PASS | PASS |
| EUnit | 199 项通过 | 214 项通过 |
| Common Test | 3 项通过 | 3 项通过 |
| Dialyzer | PASS，无警告 | PASS，无警告 |
| xref | PASS | PASS |
| 新 P0 EUnit 案例 | — | 15 项通过，案例内含多个场景 |

完整日志：[基线 EUnit](../../runtime-validation/baseline-eunit.log)、
[最终 EUnit](../../runtime-validation/eunit.log)、[CT](../../runtime-validation/ct.log)、
[compile](../../runtime-validation/compile.log)、[Dialyzer](../../runtime-validation/dialyzer.log)、
[xref](../../runtime-validation/xref.log)。基线 compile/ct/dialyzer/xref 也保存在该目录。
初始回归发现 CLI 消息“could not be loaded”改变；修正消息后最终套件通过。

已验证：

| 领域 | 实际检查 |
|---|---|
| 稳定性 | 归一化结果及覆盖频率、稳定与可变探针、合法空、排除无效快照、样本不足 |
| 返回值 | 新引用默认稳定；显式比较器返回 not_comparable；有界大 term 拒绝及标量 unstable_return |
| 执行器 | 真实插桩目标及不变二进制测试驱动 API |
| 验证崩溃 | 首次成功，第二次确定性崩溃；origin=verification，一次崩溃出现；全局覆盖等于原运行 |
| 变异状态 | 关闭与开启的完整随机变异字节序列及 staged 配方和计数匹配 |
| 资源 | 临时内存、100 条邮箱消息、1000 个有界 ETS 行；清理后保留峰值 |
| 所有权 | 4 个受控子进程加根；上限 2 得到 known=5、observed=2、partial=true；排除基础设施 |
| 子生命周期 | 异常子进程不改成功根结果；普通子清理不产生异常发现 |
| 超时 | 真实 busy/waiting 目标；年龄与证据；max_samples=2 环保留最新观察 |
| 数据缺失 | 死 PID、消失 ETS、缺少样本、采样器失败 |
| 采样器停滞 | 独立 VM 中强制暂停采样器；timeout=150 ms，清理 confirmed，总时长 <1000 ms |
| 基础设施 | 验证前 dirty：0 重复；首次重复 dirty：跳过后续重复；guardian 故障保留 dirty-runner 状态 |
| 限制 | 无效嵌套键、类型、范围；样本槽上限；requested=16、extra budget=1 得到 completed=2、skipped=14 |
| 存储 | 代表、分组、载荷上限，suppressed/dropped 计数，过时索引、损坏、中断目录、写入文件路径失败 |
| 重放 | 运行时往返、单次不稳定 inconclusive、测试驱动或构建不匹配、全新 CLI VM；旧产物在此前套件 |
| 回归 | 全部旧手动与自动覆盖、随机及 staged、精确配方、持久化语料、反馈及隔离测试 |

`vary` 样例的交替响应来源是**仅测试同步进程**，不是随机调度器。
不意味着生产测试驱动支持外部交互。
dirty、guardian 和停滞采样器样例通过操作系统进程 watchdog 隔离；
没有原子炸弹或无界内存、进程分配。
测试未模拟实际掉电或磁盘耗尽；中断及损坏存储通过构造不完整或损坏状态检查。

## 实际 CLI 往返

准备有界人工超时样例：

```sh
rebar3 compile
mkdir -p _build/runtime-demo-final/harness _build/runtime-demo-final/seeds
ERL_FLAGS='+S 4:4' erlc +debug_info -o _build/runtime-demo-final/harness \
  fixtures/runtime/efz_runtime_harness.erl
ERL_FLAGS='+S 4:4' erl -noshell -pa _build/default/lib/efz/ebin -eval '
  {ok,_}=efz_instrument:compile("fixtures/runtime/efz_runtime_sites.erl",
    #{modules=>[efz_runtime_sites],source_root=>".",outdir=>"_build/runtime-demo-final/targets"}),
  ok=file:write_file("_build/runtime-demo-final/seeds/waiting",<<"waiting">>),halt().'

ERL_FLAGS='+S 4:4' escript scripts/fuzz.escript \
  --target efz_runtime_harness --code-path _build/runtime-demo-final/harness \
  --artifacts _build/runtime-demo-final/targets --seeds _build/runtime-demo-final/seeds \
  --out _build/runtime-demo-final/out --max-iterations 0 --timeout 100 \
  --runtime-diagnostics --runtime-runs 3 --verification-budget 10 --sample-interval 5

EFZ_RUNTIME_FINDING=$(dirname "$(rg --files _build/runtime-demo-final/out/runtime-findings | rg '/artifact.input$' | head -n 1)")
ERL_FLAGS='+S 4:4' escript scripts/replay.escript \
  --runtime-finding "$EFZ_RUNTIME_FINDING" --target efz_runtime_harness \
  --code-path _build/runtime-demo-final/harness --artifacts _build/runtime-demo-final/targets --runs 3
```

观察结果：活动 `completed`，1 次校准 + 2 次验证执行，3 次超时出现（三次真实执行失败），
一个崩溃分组。
另一 VM 中运行时重放：**observed timeout_waiting，3/3**，兼容已验证。
日志：[活动](../../runtime-validation/cli-fuzz.log)、[重放](../../runtime-validation/cli-replay.log)。
本地改变样例或构建时使用新 `--out`；旧存储不迁移。

还检查了**现有且未修改**的 `efz_example_target`：

```sh
mkdir -p _build/runtime-existing/seeds
ERL_FLAGS='+S 4:4' erl -noshell -pa _build/default/lib/efz/ebin -eval '
  {ok,_}=efz_instrument:compile("examples/simple_parser/efz_example_parser.erl",
    #{modules=>[efz_example_parser],source_root=>".",outdir=>"_build/runtime-existing/targets"}),
  ok=file:write_file("_build/runtime-existing/seeds/seed",<<0>>),halt().'
ERL_FLAGS='+S 4:4' escript scripts/fuzz.escript \
  --target efz_example_target --artifacts _build/runtime-existing/targets \
  --seeds _build/runtime-existing/seeds --out _build/runtime-existing/out \
  --mutation random --max-iterations 10 --timeout 100 \
  --runtime-diagnostics --runtime-runs 3 --verification-budget 20 --sample-interval 20
```

观察：`completed`、10 变异执行、6 验证执行、0 基础设施故障。
这是短冒烟活动，不是长期模糊测试审计；CLI 未固定 RNG 种子时发现与重复数量可能不同。
[实际日志](../../runtime-validation/existing-harness.log)。

## 基准——实际测量

驱动：`bench/efz_runtime_bench.erl`，启动器 `scripts/runtime_bench.escript`。
单 worker、prepared 自动覆盖、presence 反馈、未修改插桩样例和二进制测试驱动。
每模式在独立 VM 使用 `+S 4:4`、100 变异预热、五个各 1000 随机变异 + 1 种子的活动，
固定变异及选择种子。
stability/full 各进行 4 次额外执行（种子和发现）；此数实测而非假设。
快速活动后，`mailbox_ets`（约 160 ms）单独执行。

基线在 `/tmp/efz-p0-baseline/checkout` 单独构建，来自 `git archive HEAD`、
保存原差异和原未跟踪 `src/efz_cov_count.erl`。
因此比较包括用户此前修改，不是仅干净 HEAD。
主要模式顺序测量，未并行运行测试套件或其他基准。
主机非专用，CPU 频率及负载未固定。

```sh
# 每个模式：预热加五次运行。先准备好普通 EFZ 构建。
ERL_FLAGS='+S 4:4' escript scripts/runtime_bench.escript baseline /tmp/efz-p0-bench/release/baseline /tmp/efz-p0-baseline/checkout/_build/default/lib/efz/ebin
ERL_FLAGS='+S 4:4' escript scripts/runtime_bench.escript off /tmp/efz-p0-bench/release/off
ERL_FLAGS='+S 4:4' escript scripts/runtime_bench.escript stability /tmp/efz-p0-bench/release/stability
ERL_FLAGS='+S 4:4' escript scripts/runtime_bench.escript resources /tmp/efz-p0-bench/release/resources
ERL_FLAGS='+S 4:4' escript scripts/runtime_bench.escript full /tmp/efz-p0-bench/release/full
ERL_FLAGS='+S 4:4' escript scripts/runtime_bench_report.escript /tmp/efz-p0-bench/release summary.csv
```

| 模式 | 变异 exec/s 中位数 | 最小–最大 | 变异 / 验证 | 中位运行墙钟，ms | 执行后诊断，ms | 验证耗时，ms |
|---|---:|---:|---:|---:|---:|---:|
| baseline | 279.5 | 236.1–372.7 | 1000 / 0 | 3577.3 | 0.00 | 0.00 |
| off | 217.6 | 182.7–227.4 | 1000 / 0 | 4596.3 | 0.00 | 0.00 |
| stability | 219.6 | 212.1–224.0 | 1000 / 4 | 4553.4 | 52.37 | 4.35 |
| resources | 205.4 | 179.1–225.5 | 1000 / 0 | 4868.1 | 38.26 | 0.00 |
| full | 194.9 | 176.8–216.9 | 1000 / 4 | 5131.5 | 52.60 | 3.97 |

`runtime_diagnostic_us` 是初始执行器后的 worker 墙钟时间：
**包括**比较、摘要、存储及验证，不能再加 `verification_elapsed_us`。
采样器工作时间是另一进程中的另一指标。
这些行对应吞吐中位数的运行，不是独立选取不同计数器中位数。

快速活动没有运行时样本：resources 的 sampled/missed 为 0/1001，full 为 0/1005；
stability 关闭采样器。
baseline/off 的零表示测量关闭，不表示没有消耗。
因此快速循环减速**不测量真正执行过的单个采样钩子成本**。

| 长输入模式 | 墙钟，ms | 样本 | 采样器工作，ms | 结束时 ETS 诊断缓冲，字节 |
|---|---:|---:|---:|---:|
| baseline | 166.52 | 0 | 0.000 | 0 |
| off | 164.70 | 0 | 0.000 | 0 |
| stability | 166.50 | 0 | 0.000 | 2648 |
| resources | 167.44 | 7 | 1.004 | 7008 |
| full | 166.11 | 7 | 0.534 | 7008 |

快速活动中 P0 启用时已完成 ETS 缓冲最大 2648 字节。
这**不是全部诊断内存**：排除采样器、guardian 堆及保留报告映射。
常驻槽、子进程、报告字节和磁盘元数据受不同上限约束。
对 process_info 或 ETS 昂贵的任意目标，需单独分析。

[CSV 摘要](../../runtime-validation/bench/summary.csv)及五模式原始 `.term` 文件和日志
保存在 `docs/runtime-validation/bench/`。
同一报告脚本可从原始文件重算摘要。

### 检查意外 P0=off 结果

主要顺序批次中，off 的墙钟吞吐中位数为 **−22.2%**。
不能把该结果称作没有回归。
另运行反向顺序控制（先 off、后 baseline），使用相同驱动、样例、预热和五个活动；
`/usr/bin/time` 还测量整个 escript 进程 CPU，包含编译、预热及长样例，
所以这些 CPU 秒**不是单次变异 CPU 成本**：

```sh
/usr/bin/time -f 'wall_s=%e user_s=%U system_s=%S' \
  env ERL_FLAGS='+S 4:4' escript scripts/runtime_bench.escript off /tmp/efz-p0-bench/reverse/off
/usr/bin/time -f 'wall_s=%e user_s=%U system_s=%S' \
  env ERL_FLAGS='+S 4:4' escript scripts/runtime_bench.escript baseline /tmp/efz-p0-bench/reverse/baseline \
  /tmp/efz-p0-baseline/checkout/_build/default/lib/efz/ebin
```

| 反向顺序控制 | 变异 exec/s 中位数 | 最小–最大 | 全进程墙钟，s | 用户 CPU，s | 系统 CPU，s |
|---|---:|---:|---:|---:|---:|
| off | 253.0 | 248.0–258.6 | 20.78 | 57.28 | 4.30 |
| baseline | 251.6 | 223.5–259.1 | 21.59 | 59.80 | 4.66 |

这里 off 相对 baseline 为 **+0.54%**，没有显示 CPU 时间增加。
多调度线程 VM 的 CPU 秒多于墙钟秒是正常的。
两个相反结果都保留：`bench/reverse/{off,baseline}/` 含原始 `.term`、stdout 及时间日志。
这说明测量对条件和顺序敏感，但未确立具体外部原因。
没有证据证明在专用主机上统计显著地无回归。

## 结论与剩余边界

- **此环境功能检查 PASS：**生产执行器和 guardian 路径、重复校准、资源、子进程、超时、
  独立发现及报告和重放、限制及列出的回归；214 EUnit + 3 CT，以及 compile/Dialyzer/xref。
- **性能验收 PARTIAL：**全部五个模式实际测量；反向控制中 off 无一致退化，
  但显著波动使“无实质回归”无法获得整体 PASS。
  作出此声明前，需在稳定专用主机上独立控制实验。
- 样本不保证发现快速峰值。达到上限时 ETS 枚举部分完成；内存指标不含完整堆外占用。
  未单独测量采样器或报告堆峰值；报告给出实际 ETS 缓冲字节及限制。
- 子进程退出发起者通常为 `unknown`：DOWN 不能证明谁发送退出信号。
  清理记录自身 kill_requested，不会把含糊竞争变成精确原因或进程泄漏断言。
- 单次运行资源增长只是诊断疑点。不证明任意泄漏、内存安全、语义正确性、竞态、死锁或活锁、
  原生故障或外部副作用。有状态复现器可能要求输入历史或全新 VM。这些扩展刻意未实现。
- 完整掉电及 ENOSPC 故障注入、其他 OTP 或操作系统版本、长期生产活动均**未运行**。
  所列最终编译、测试、基准命令均未被缺少依赖或权限阻塞。

本报告描述真正运行的本地检查，不声称生产就绪，也不声称全部运维属性整体完整 PASS。
