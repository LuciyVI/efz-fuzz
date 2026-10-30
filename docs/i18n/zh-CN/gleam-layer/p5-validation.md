# P5：最终重放、回归与同引擎验收

[English](../../../gleam-layer/p5-validation.md) · [Русский](../../ru/gleam-layer/p5-validation.md) · [Español](../../es/gleam-layer/p5-validation.md) · **简体中文** · [所有语言](../../README.md)

本报告取代 P1–P4 的历史 P5 交接说明及 10 月 10 日 universal-validation 报告。
门槛涵盖受支持的有界同步 Linux 工作流程。
性能优势及发现独立漏洞属于其他问题，不是完成实现门槛的条件。

## 最终验收期间的修改

- 安全加载模式 1 现会在 ETF 解码前注册固定旧版词汇。
  保持启用 `[safe]`；产物不能引入原子或选择可执行模块。
- 旧版重放必需输入为原始 `.input` 和带校验和的 `.semantic`。
  VM 本地诊断 `.term` 是可选路径，而非前提。
- 通用重放 CLI 的 escript 不可用诊断使用正确格式调用。
  子进程测试覆盖通用重放、最小化、精确执行预算、无效参数、损坏输入、
  拒绝替换已有输出、转发，以及无需诊断 `.term` 的成功原生旧版重放。
- 比较驱动接受多个 RNG 种子和重复次数，测量持久化语料接纳，记录源码、运行时和目标标识。
- 有状态计数通过实际受保护目标结果，在独立全新 VM 中、活动计时之外验证。
  完成操作数等于返回轨迹长度。数据包拒绝与已接纳场景分开；
  一次主输入执行不标作一次库操作。

## 复现

使用 OTP 27、Rebar3 3.25.0、Gleam 1.10.0 和 `ERL_FLAGS='+S 2:2'`。
测量前执行默认及可选编译、测试、CT、xref、Dialyzer。
按照 `examples/xmlrpc/README.md` 准备固定 XML-RPC 依赖。
可选完整 EUnit 运行要求其依赖 ebin 目录位于代码路径。

在不修改活动工作副本的前提下准备两个源码归档：
main 的 `79d76221c6bc5df30b80e6b0de947f3860f4fa4b`（默认构建）及历史 QS 层
`e4c0244c403d74b041df7e0e2f0dd4465a977453`（Gleam 构建）。
用相同工具链和锁定依赖提交构建。每个云任务已经有隔离工作副本，无需 Git worktree。

```sh
python3 scripts/run_semantic_bench.py --out /workspace/scratch/p5-semantic-verified
python3 scripts/run_qs_semantic_bench.py \
  --baseline /workspace/scratch/p5-legacy-baseline/_build/gleam \
  --raw-baseline /workspace/scratch/p5-main-baseline/_build/default \
  --out /workspace/scratch/p5-qs-verified
python3 scripts/verify_p5_evidence.py \
  /workspace/scratch/p5-semantic-verified /workspace/scratch/p5-qs-verified
```

各输出目录必须全新。准备、活动和回调及有状态诊断串行运行。
测试套件或编译不与测量系列重叠。规范门槛使用三个种子（17、29、43）、两次重复、
500 次变异、全新 VM 与语料、两个 CPU 调度器及固定目标超时。
QS 在所有引擎和模式间使用同一原生目标产物。
其测量活动在单独 20 次变异预热后开始，并使用全新测量语料。
API、XML、有状态系列没有活动预热。

活动墙钟时间包含设置、校准及持久化接纳写入；VM 和驱动墙钟时间单独记录。
冷路径有状态诊断包含执行器和场景设置及清理，不声称隔离的单操作延迟。

最终状态：**P5 PASS，2026 年 10 月 13 日。**
初步尝试保留在工作副本之外，不作为最终 PASS 证据。

## 验收范围与审查

最终审查重新检查回调边界、权威原始输入、显式适配器及目标选择、有限预算、
关闭路径 RNG 中立、观察器中立、持久化标识和重新校准、语义谓词保留。
新增测试复现两个冷路径旧版故障，不依赖此前作者的 PASS 说明。
未使用单独审查者或子代理，不声称独立外部审计。

任意原生回调取消、不受管理的并行目标调用、无专用测试驱动的外部资源、全局最小输入、
精确活动 PRNG 检查点及延迟判定器仍不属于 v1 契约。
这些是有文档的范围排除，不是未执行 P5 检查。

## 已执行最终门槛

| 检查 | 结果 |
| --- | --- |
| 默认编译 / EUnit | PASS / 308 项通过 |
| Gleam 编译 / 含固定 XML-RPC 的完整 EUnit | PASS / 374 项通过 |
| Common Test | 3 项通过 |
| 默认和 Gleam xref / Dialyzer | 两种构建均 PASS |
| 全新 VM 通用及原生旧版重放 CLI | 可选套件 2 项通过；通用路径也在默认套件通过 |
| 串行 API/XML/有状态关闭与开启活动 | 36/36 完成，各 500 次变异 |
| 串行 QS main / legacy / disabled / seeds / structured / observation / explicit guided / oracle | 48/48 完成，各 500 次变异 |
| 原始关闭轨迹与 main 结构覆盖等价 | 6/6 种子和重复配对 |
| 仅观察变异轨迹中立 | 6/6 种子和重复配对 |
| 实际有状态工作负载诊断 | 12/12 完成，各 501 次受保护输入执行 |
| 源码哈希 / 活动预算 / 无基础设施错误 / 存在持久化语料 | PASS |

比较系列进行了 42,000 次测量变异。每个测量活动使用新持久化语料。
既有完整回归测试单独验证恢复和重新校准、标识不匹配拒绝、纯语义接纳及代表保留。
语料持久化是输入复用，不是 PRNG 检查点。

### 测量摘要

每行六个样本（三个 RNG 种子、两次重复）。速率包含测量中的校准和接纳成本。
它们是有限测量，不是显著性声明，也不是性能优势验收阈值。

| 系列和模式 | 主执行次数/秒中位数 | 纯语义条目，样本范围 |
| --- | ---: | ---: |
| QS baseline | 398.4 | 0–0 |
| QS old | 388.7 | 0–1 |
| QS new | 380.3 | 1–1 |
| QS off | 405.0 | 0–0 |
| QS seeds | 412.3 | 0–0 |
| QS structured | 385.9 | 0–0 |
| QS observation | 374.8 | 0–0 |
| QS oracle | 377.9 | 0–1 |
| API generic-off | 388.7 | 0–0 |
| API generic-on | 390.3 | 1–1 |
| API xmlrpc-off | 320.0 | 0–0 |
| API xmlrpc-on | 303.0 | 3–4 |
| API stateful-off | 382.7 | 0–0 |
| API stateful-on | 390.8 | 1–1 |

关闭路径保留确定性原始行为，不加载 Gleam 模型。
开启模式实际接纳纯语义条目；这确认集成，不是独立缺陷发现。
这些样本没有证明加速、最优结构化比例或零开销。

### 实际有状态操作

计数来自独立诊断 VM 中对记录数据包工作负载的已完成受保护执行，
与规范数据包重建一致。场景墙钟时间包括执行器及子进程设置和清理；
不是隔离的 gen_server 调用延迟基准。

| 模式 | 六个工作负载的已接纳场景 | 完成库操作 | 拒绝数据包 |
| --- | ---: | ---: | ---: |
| off | 12 | 36 | 2994 |
| on | 178 | 562 | 2828 |

### 受控发现试验

额外三个全新 VM 的 1,000 次变异运行使用明确人工的 `efz_qs_defect_target`，
相同初始字节 `abc=1`、现有 `bug` 字典和种子 17、29、43。
种子 17 和 29 找到注入属性失败；种子 43 完成但未发现（在执行预算处删失）。
全部完成且无基础设施错误。
单独旧版 CLI 测试在新 VM 中复现并最小化该属性。
任何结果都不作为新漏洞，或真实库上更强发现能力的证据。

## 证据与结论

[validation.json](../../../gleam-layer/p5-evidence/validation.json)记录工具链、源码和日志哈希、原始产物哈希及发现结果。
[gates.json](../../../gleam-layer/p5-evidence/gates.json)记录预算、轨迹、有状态检查和最终测量摘要。
两个系列的清单均与其一同保留。
完整日志、输入、配方、报告和持久化语料位于 validation.json 列出的原始证据根目录；
生成的 BEAM 不提交。

在所述契约内，所有之前待完成的可执行 P5 项目现已关闭。
没有未执行的必需 P5 命令。
合并审查可使用保留检查及复现说明；仍不声称性能优势。
