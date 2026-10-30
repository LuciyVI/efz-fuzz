# 第 2 阶段验证记录

[English](../../phase2-validation.md) · [Русский](../ru/phase2-validation.md) · [Español](../es/phase2-validation.md) · **简体中文** · [所有语言](../README.md)

日期：2026-09-08。所有执行目标和语料都是本地人工 fixture。
环境：OTP 27.0、ERTS 15.0、x86_64-pc-linux-gnu；Rebar3 3.25.0。

## 基线与范围

仓库是所供工作区中的 `efz/` 子目录。开始时 README 与 app 元数据已修改，
大部分第 1 阶段代码、示例、测试和文档未跟踪。没有发现 AGENTS.md 或额外仓库
指令。工作与初始状态副本比较；无关 corpus、mutator、behaviour、应用回调及
根 supervisor 源码保留。没有改变 Git 身份、remote、commit、暂存或 push。

修改前：`rebar3 compile` 通过；`rebar3 eunit` 7 项全过；`rebar3 ct` 零用例
通过；`rebar3 dialyzer` 通过。无配置的格式化/linter 插件。既有 xref 在最终
验证执行。

基线 executor 可能在确认超时终止前返回，覆盖是共享 gen_server 集合。
初始校准、崩溃存储及可靠活动关闭缺失。这些基础在原 execution/worker/fuzzer
路径修复；保留原随机 mutator 和内存 corpus。

## 命令与最终结果

| 命令 | 结果 |
|---|---|
| `rebar3 compile` | 通过，警告作为错误 |
| `rebar3 eunit` | 24 项通过，含 17 个分组阶段 2 用例 |
| `rebar3 eunit --module=efz_phase2_tests` | 17 个专项全部通过 |
| `rebar3 ct` | 3 项集成测试通过 |
| `rebar3 dialyzer` | 通过；compiler 因编译 API 加入 PLT extra apps |
| `rebar3 xref` | 通过，执行配置的未定义/弃用检查 |
| 新 `mktemp` 目录下 `REBAR_BASE_DIR="$EFZ_CLEAN_BUILD" rebar3 compile` | 通过；普通 parser BEAM 无 EFZ manifest |
| `escript examples/automatic/run.escript` | 插桩构建及 500 次真实 mutator 迭代完成 |
| `escript scripts/coverage_bench.escript` | 每个预热模式测量七个样本；无阈值 |
| `git diff --check` | 通过 |

没有依赖阻止这些命令。预期负例诊断包括严格模式拒绝 comprehension、`maybe`、
非字面 record 默认值，工件缺失/改变及未选模块。开发中 relocation 测试暴露
source-root `.` 规范化问题并修复。编译器拒绝 record 声明中已绑定变量后，
修正了无效 record-default fixture。这些是开发失败，非基线失败；最终结果如上。

干净构建位于 `/tmp/efz-clean.cl22wE`，未清理或 reset 原工作树/构建。
以 `efz_cov_manifest:from_beam/1` 检查普通 parser，按预期得到
`{error,missing_instrumentation}`。生成输出仍在被忽略的 `_build` 或显式临时
构建目录。

## 具体保留与继续执行证据

确定性测试 mutator（仅 `test/efz_scripted_mutator.erl`）输出：

```erlang
[<<>>, <<>>, <<255>>, <<1,7>>, <<1,7>>]
```

校准唯一种子 `<<0>>` 后，`<<>>` 被保留为 corpus 条目 2，父条目 1，
`retention_reason => new_coverage`。它返回 `{ok,empty}` 并发现
`examples/simple_parser/efz_example_parser.erl:7:1` 的 `classify/1` 空输入
clause。在记录的构建中，其逻辑身份探针 ID 为 2，build SHA-256 为：

```text
5f11a3a9df248ba517a1ae78cfad9462d6c6453bc0565bfe27089fa4a8239b6a
```

此 ID 从生成 manifest/decision 读取，不硬编码到核心或验收测试。
元数据还含执行引用和输入 SHA-256。下一次相同变异被拒绝。
`<<255>>` 触发标注的人工异常，以带非空覆盖的崩溃保存。活动继续，保留
`<<1,7>>` 并拒绝重复。

最终确定性计数：1 次校准、5 次变异、2 次发现、2 次等价拒绝、1 次崩溃、
3 条 corpus。只在崩溃出现的覆盖不并入全局；另有断言证明其对后续成功结果
仍可为新覆盖。`_build/phase2-acceptance.term` 存完整报告。

生产 mutator 使用 `random_seed => {17,23,41}`、种子 `<<0>>`、500 次迭代。
实测：5 次发现、2 次人工崩溃（1 个唯一）、493 次等价拒绝、0 超时、
0 基础设施失败、6 条 corpus。两次崩溃后均继续。
`_build/example-report.term` 与 `_build/example-report.txt` 含报告；输入和
元数据位于 `_build/example-crashes`。随机 mutator 观察与脚本验收证明分开。

## 终止后覆盖与隔离

生命周期 fixture 仅在自动入口探针返回后发送 `{probe_recorded, self()}`。
测试等待消息，再请求外部 kill 或等待刻意阻塞执行超时。最终断言覆盖非空且
映射到该入口、`coverage_status => ok`，结果分别为 `{exit,killed}` 或
`{timeout,1000}`。返回最终超时覆盖前进程已死。Error、throw、exit 结果也
保留终止前覆盖。检查的快照中 error/throw/exit 各两探针，外部 kill/timeout
各一探针，均 `coverage_status => ok`。

EUnit 将可检查快照写入 `_build/phase2-kill.term`、
`_build/phase2-timeout.term`、`_build/phase2-error.term`、
`_build/phase2-throw.term`、`_build/phase2-exit.term`。

其他检查包含新空上下文、同输入探针集相等但引用不同、不同输入入口探针不交、
同时附着两个上下文、所选跨模块调用、重复期限边界执行和 ETS 表数不变。
在同步活跃目标期间 caller 死亡、公开活动取消、应用关闭均终止目标和上下文
所有者。被捕获的 invalid-table hook 异常仍成为基础设施结果，而非目标崩溃
或成功空反馈。

## Benchmark 观察

见[完整实测样本](coverage.md#可复现验证与开销)。
同一普通/插桩 fixture 每样本预热 30,000 次后运行 200,000 次尾循环迭代，
每模式重复七次：

| 模式 | 中位数 | 相对普通 |
|---|---:|---:|
| 普通 | 518 us | 1.00x |
| 插桩、无上下文 | 5,315 us | 10.26x |
| 插桩、活跃上下文 | 67,209 us | 129.75x |

活跃集合有六探针，用 419 ETS words（每 word 8 字节，共 3,352 字节），
随后删除。此合成循环显示 hook/ETS 开销，不代表端到端 parser 吞吐量。
未测 OTP cover。没有机器相关正确性阈值。

## 相对所供阶段 1 工作树的变更文件

* 编译/runtime 新增：`src/efz_instrument.erl`、
  `src/efz_instrument_pt.erl`、`src/efz_cov_rt.erl`、
  `src/efz_cov_manifest.erl`、`src/efz_feedback.erl`。
* 现有集成变更：`src/efz.erl`、`src/efz_config.erl`、
  `src/efz_cov.erl`、`src/efz_executor.erl`、`src/efz_worker.erl`、
  `src/efz_fuzzer.erl`、`src/efz_worker_sup.erl`、`src/efz_stats.erl`、
  `src/efz_crash.erl`、`src/efz.app.src`、`rebar.config`。
* 示例：修改 `examples/simple_parser/efz_example_parser.erl`；新增
  `examples/simple_parser/efz_example_target.erl` 和
  `examples/automatic/run.escript`。
* 测试：修改 `test/efz_smoke_tests.erl`；新增 `test/efz_phase2_tests.erl`、
  `test/efz_scripted_mutator.erl`、`test/efz_coverage_SUITE.erl`。
* Fixture/benchmark：`fixtures/efz_fixture.erl`、
  `fixtures/efz_fixture_helper.erl`、`fixtures/include/efz_fixture.hrl`、
  `fixtures/efz_skipped.erl`、`fixtures/efz_record_default.erl`、
  `fixtures/efz_bench_fixture.erl`、`scripts/coverage_bench.escript`。
* 文档：`README.md`、`docs/architecture.md`、`docs/coverage.md`、
  `docs/adr/0002-automatic-coverage.md` 和本记录。

剩余限制明确：只测 OTP 27.0；单 worker、单执行进程；不清理/归因任意子进程；
跳过语法需 permissive；无任意 BEAM 重写或其他 parse transform；hook 实测
开销显著；无完整分支/CFG/状态覆盖或 VM/OS 沙箱。
