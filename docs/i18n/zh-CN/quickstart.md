# 准备并运行 EFZ

[English](../../quickstart.md) · [Русский](../ru/quickstart.md) · [Español](../es/quickstart.md) · **简体中文** · [所有语言](../README.md)

状态于 2026 年 9 月 15 日验证，环境为 OTP 27.0 / ERTS 15.0、
Rebar3 3.25.0、Linux x86_64。主要覆盖引导循环已可运行：
变异 → 目标 → 新探针 → 保留 → 再次将该输入用作父输入。
[真正 staged 引擎的集成测试](../../../test/efz_feedback_loop_tests.erl)对此进行了确认。
当前范围是同步 `Module:run(binary())` 和受控后代进程；
任意 OTP 应用尚不是受支持的目标。

## 构建与准备

`PATH` 中必须有 Erlang/OTP **27 或更新版本**提供的 `erl`、`erlc`、`escript`，以及 `rebar3`。
构建设置了此最低版本；本次运行未验证其他 OTP 版本。没有外部 Rebar 依赖。
脚本不会安装系统软件包。

从 `efz/` 仓库根目录执行：

```sh
escript scripts/prepare.escript
```

[脚本](../../../scripts/prepare.escript)检查工具和 OTP，在默认 profile 下运行 `rebar3 compile`，
通过 `efz_instrument:compile/2` 编译现有
[efz_staged_parser](../../../examples/staged/efz_staged_parser.erl)，
检查 BEAM、清单和 `run/1`，然后复制原始种子。
最后会打印使用绝对路径并正确进行 shell 引用的完整启动命令。
活动由现有 `scripts/fuzz.escript` 执行；没有引入新的模糊测试引擎。

重复准备会保留内容相同的种子文件、语料及发现。
若同名种子的内容不同，脚本会报错并保留用户文件。
插桩目标会重新构建。准备与模糊测试必须顺序运行：活动期间重新构建会违反已固定的代码标识。
无效参数、构建失败和文件系统错误会产生非零退出码。

```sh
escript scripts/prepare.escript --help
# 自定义数据目录；相对路径以当前工作目录为基准：
escript scripts/prepare.escript --dir /tmp/my-efz-run
```

可从任意目录通过绝对路径调用脚本。默认输出为 `efz/_build/quickstart/`。
长期运行应把 `--dir` 设在 `_build` 之外，避免手动清理构建目录时删除语料或崩溃产物。
脚本自身不会删除它们。

## 测试语料

源文件位于 [examples/staged/corpus](../../../examples/staged/corpus)，工作副本位于
`_build/quickstart/seeds/`。全部五个输入都能成功完成校准。
源语料没有现成的崩溃输入。

| 文件 | 精确字节（十六进制） | 用途 |
|---|---|---|
| `00-empty.seed` | 空，0 字节 | 空输入子句及从空种子开始的变异 |
| `01-zero.seed` | `00` | 数值边界与算术路径，产生 `80` 和 `01` |
| `02-near-token.seed` | `55 4f 4b 45 4e` (`UOKEN`) | 首字节翻转一位得到 `TOKEN`，到达新的成功子句 |
| `03-near-crash.seed` | `43 4f 4f 4d 21` (`COOM!`) | 首字节翻转一位或算术 −1 得到 `BOOM!` |
| `04-binary.seed` | `00 ff 80 41 0d 0a` | 原样传递 NUL、非 UTF-8 和 CR/LF |

文本种子末尾没有换行。二进制种子的最后两个字节是有意设置的 CR/LF。
README 和字典文件不放在种子目录中：CLI 会把每个普通文件作为输入读取。
`tokens.hex` 单独保存，由字典式 [staged 示例](../../../examples/staged/run.escript)使用；
通用 CLI 尚无字典选项，因此这里使用标准默认阶段。

## 开始模糊测试

准备后，从 `efz/` 运行以下所有命令：

```sh
ERL_FLAGS='+S 4:4' escript scripts/fuzz.escript \
  --target efz_staged_parser \
  --seeds _build/quickstart/seeds \
  --out _build/quickstart/findings \
  --artifacts _build/quickstart/instrumented \
  --corpus-dir _build/quickstart/corpus \
  --mutation staged \
  --coverage-policy strict \
  --timeout 1000 \
  --max-input-bytes 4096 \
  --max-iterations 1000
```

这是有界活动：1000 次变异执行加上校准。`ERL_FLAGS` 中的四个 BEAM 调度器并不等于
四个 EFZ worker：实际只有一个 worker。
教程解析器中的 `BOOM!` 会故意触发 `error(artificial_staged_exception)`；
这是演示缺陷，不是发现的 Erlang/OTP 漏洞。单纯目标崩溃不会使退出码非零。
基础设施错误产生退出码 1，无效 CLI 或配置产生退出码 2。
达到执行预算停止时，状态为 `completed`。

| 路径 | 内容 |
|---|---|
| `_build/quickstart/instrumented/` | 所选解析器的 BEAM 和 `.efz-manifest` |
| `_build/quickstart/seeds/` | 五个初始原始输入 |
| `_build/quickstart/corpus/` | 初始种子和成功发现，采用 SHA-256 内容标识 |
| `_build/quickstart/findings/report.term` | 二进制 ETF 报告：统计、活动语料、配方、崩溃分组 |
| `_build/quickstart/findings/crashes/` | 有界代表产物：`.input`、`.term`、`.recipe`、`.replay`；持久化计数 |

在新 VM 中复用保存的语料：

```sh
ERL_FLAGS='+S 4:4' escript scripts/fuzz.escript \
  --target efz_staged_parser \
  --artifacts _build/quickstart/instrumented \
  --corpus-dir _build/quickstart/corpus \
  --out _build/quickstart/restored-findings \
  --mutation staged --coverage-policy strict \
  --timeout 1000 --max-input-bytes 4096 --max-iterations 1000
```

恢复的输入会再次校准。这是新活动，不是对 RNG、游标或全局覆盖的精确续接。
不兼容构建会被拒绝；`--corpus-build-policy recalibrate` 允许有意切换到新构建。
参见[持久化语料](corpus.md)。复用相同 `--out` 会覆盖已有 `report.term`；
使用不同输出目录可保留两份报告。

重放第一个保存的代表产物：

```sh
EFZ_CRASH_INPUT=$(find _build/quickstart/findings/crashes -name artifact.input -type f -print -quit)
test -n "$EFZ_CRASH_INPUT" && \
  ERL_FLAGS='+S 4:4' escript scripts/replay.escript \
    --input "$EFZ_CRASH_INPUT" --target efz_staged_parser \
    --artifacts _build/quickstart/instrumented --max-input-bytes 4096

test -n "$EFZ_CRASH_INPUT" && \
  ERL_FLAGS='+S 4:4' escript scripts/replay.escript \
    --recipe "${EFZ_CRASH_INPUT%.input}.recipe" --target efz_staged_parser \
    --artifacts _build/quickstart/instrumented --max-input-bytes 4096
```

两种方式都会检查保存的构建及测试驱动标识；成功判定为 `reproduced`，退出码 0。
原始 `.input` 始终是权威产物。对于自己的目标，参见[通用 CLI 与插桩规则](cli.md)。

## 扩大应用范围所需的后续工作

EFZ 已经能够对同步二进制目标进行覆盖引导模糊测试。
以下任务扩展其适用范围并提升长期活动可靠性，不代表主要反馈循环尚未实现。

| 优先级 | 工作 | 当前限制与就绪标准 |
|---|---|---|
| P1 | 一次性 Erlang VM 后端 | guardian 会清理受控后代，但不能清理任意 OTP 应用、NIF、端口或外部状态。父运行器必须在保留输入的情况下分类 VM halt 和原生崩溃；超时或取消必须销毁运行所拥有的整个 VM。参见[执行契约](execution-isolation.md)。 |
| P1 | 重复校准与特征稳定性 | 当前每个初始或恢复种子仅执行一次（`efz_worker:handle_info/2`）。需要重复精确覆盖和结果观察、不稳定性诊断，以及 A→dirty→A 和全新 VM 检查。配方确定性不保证目标确定性。[拟议模型](calibration-readiness.md)尚未实现。 |
| P1 | 扩展并验证 OTP 插桩 | 当前采用源码子句和结果探针。推导式、`maybe`、非字面量记录默认值会被严格转换拒绝，或带有限制。需要语义等价测试、真实解析器测试驱动及所声明 OTP 版本上的 CI；不得把部分探针描述为完整分支或边覆盖。参见[支持的语法](coverage.md)。 |
| P1 | 长期活动运维 | 没有精确检查点续跑；持久化语料只保存可复用输入。需要分别定义检查点、崩溃存储恢复与迁移、总磁盘配额契约。代表产物限制按签名生效；当前遗留写锁需要操作员调查。[崩溃存储](replay.md)。 |
| P2 | 语料与崩溃缩减 | 已有内容去重；尚无保覆盖语料最小化和崩溃输入缩减。验证标准：缩减输入在固定构建上保持签名；最小化语料保持探针并集。 |
| P2–P3 | CLI 变异配置及进一步调度 | 字典、阶段和 RNG 可通过 Erlang 配置使用；通用 CLI 尚未开放。接下来需要便捷的配置验证、优选输入队列及独立 VM worker。`efz_config` 当前仅允许 `workers => 1`；VM 内并行池会违反当前隔离模型。 |

为有状态 Erlang/OTP 集成所需的最小下一阶段，是一次性 VM 后端及其生命周期回归测试套件。
对当前同步解析器而言，重复校准和最小化是更有用的首要步骤。
分布式执行和 UI 不能替代这些正确性检查。

## 本准备流程的验证

全新 quickstart 存储产生：`completed`、5 次校准、1000 次执行、3 次发现、8 个活动输入、
同一签名下 2 次崩溃，以及 0 个基础设施故障。首次崩溃：`COOM! → BOOM!`，父 ID 4，
`stage = arithmetic`，`operations = [{add,0,8,big,-1}]`。
任意重复运行的计数可能不同：CLI 不固定 RNG，且已保存语料会改变初始状态。

原始输入、配方重放和恢复已在不同 Erlang VM 中检查。
不带 `--seeds` 的新活动加载了 8 个输入，完成 8 次校准和 100 次变异执行，无基础设施故障。
检查还覆盖重复准备不改变发现或语料、从其他工作目录调用、路径中的空格与单引号、
未知选项、缺少参数、种子冲突及输出不可用。本地结果：`_build/quickstart-checks/`。

完整检查集——`rebar3 compile`、`rebar3 eunit`（**186 项通过**）、`rebar3 ct`（**3 项通过**）、
`rebar3 xref`、`rebar3 dialyzer`——均以 0 退出。
另外执行了设置与 CLI 冒烟检查，未计入 EUnit 测试数量。
