# EFZ 文档

[English](../../README.md) · [Русский](../ru/index.md) · [Español](../es/index.md) · **简体中文** · [所有语言](../README.md)

英语是文档的标准语言。[语言索引](../README.md)提供 README、指南、审计和报告的完整俄语、西班牙语和简体中文版本。[项目 README](README.md)介绍各项功能。

## 从这里开始

- [准备并运行 EFZ](quickstart.md)
- [通用模糊测试启动器](cli.md)
- [EFZ 终端仪表盘](tui.md)
- [连续模糊测试](continuous.md)
- [根据 Erlang 类型规范生成连接器](gleam-layer/connector-generation.md)
- [将 Erlang 库连接到 Gleam Layer](gleam-layer/connecting-erlang-libraries.md)
- [EFZ 架构](architecture.md)
- [EFZ 仓库地图：目录与文件](repository-map.md)

## 完整参考

历史报告保留原始工作的日期、已验证环境、范围和限制。记录的结果描述的是当时的运行，并不代表之后每个修订版本都具有相同结果。原始日志、二进制产物和源代码标识符均作为证据保留。某些历史报告引用临时运行目录或未包含在新检出副本中的证据文件；这些原始路径作为来源信息予以保留。

### 引擎与运行指南

- [EFZ 架构](architecture.md)
- [EFZ 对校准与 feature_stability 的就绪审计](calibration-readiness.md)
- [通用模糊测试启动器](cli.md)
- [连续模糊测试](continuous.md)
- [可复用的持久化语料库](corpus.md)
- [EFZ 覆盖位图后端](coverage-bitmap-architecture.md)
- [EFZ 位图覆盖后端技术审计](coverage-bitmap-audit.md)
- [位图覆盖后端：实现报告](coverage-bitmap-implementation-report.md)
- [位图覆盖 v2：实现与测量结果](coverage-bitmap-v2-results.md)
- [自动覆盖完整性](coverage-integrity.md)
- [EFZ 覆盖跟踪：审计及与 AFL++ 的比较](coverage-tracking-audit.md)
- [自动覆盖契约](coverage.md)
- [长时间 Cowboy 基准：ETS、bitmap-v2 与 OTP-public](cowboy-long-benchmark.md)
- [Cowboy 数据流测试工具](cowboy-harness-suite.md)
- [XML-RPC 数据流测试工具](xmlrpc-harness-suite.md)
- [DWARF/原生覆盖率结果](dwarf-native-coverage-results.md)
- [DWARF/原生覆盖率：可行性检查点](dwarf-native-coverage.md)
- [EFZ：引擎性能剖析 v2（2026-10-04）](engine-performance-profile-v2.md)
- [EFZ：单次迭代成本分析](engine-performance-profile.md)
- [执行模型：带受控后代的同步二进制测试驱动](execution-isolation.md)
- [EFZ：实验性命中计数反馈](hit-count-experiment.md)
- [输入限制与存储故障](input-and-storage.md)
- [原生 staged 变异（引擎版本 1）](mutations.md)
- [实验性 OTP-public 行覆盖率（2026-10-03）](otp-native-public-results.md)
- [P1-01 外部 supervisor](p1-01-external-supervisor.md)
- [第 2 阶段验证记录](phase2-validation.md)
- [阶段 2.1 性能与收尾记录](phase2.1-performance.md)
- [阶段 3 验证：staged 变异与精确重放](phase3-validation.md)
- [准备并运行 EFZ](quickstart.md)
- [崩溃发生次数、签名与验证式重放](replay.md)
- [EFZ 仓库地图：目录与文件](repository-map.md)
- [P0 验收修复 — 2026-09-21](runtime-diagnostics-acceptance-fixes.md)
- [P0 验证——2026-09-16](runtime-diagnostics-validation.md)
- [自动运行时诊断（P0）](runtime-diagnostics.md)
- [EFZ 技术审计——2026 年 9 月 12 日](technical-audit-2026-09-12.md)
- [EFZ 终端仪表盘](tui.md)

### 语义 / Gleam 层

- [语义适配器 API 1](gleam-layer/adapter-contract.md)
- [所有权与门槛顺序](gleam-layer/agent-plan.md)
- [原生 Gleam 架构——契约 v1](gleam-layer/architecture.md)
- [P0 基线](gleam-layer/baseline.md)
- [将 Erlang 库连接到 Gleam Layer](gleam-layer/connecting-erlang-libraries.md)
- [根据 Erlang 类型规范生成连接器](gleam-layer/connector-generation.md)
- [原生 Erlang/Gleam 契约 v1](gleam-layer/contracts.md)
- [决策](gleam-layer/decision-log.md)
- [实际源码映射](gleam-layer/execution-path.md)
- [P1 契约验证与交接](gleam-layer/p1-validation.md)
- [P2 可选原生 BEAM 集成](gleam-layer/p2-integration.md)
- [P3 结构化提供器——PASS](gleam-layer/p3-provider.md)
- [P4 判定器与语料反馈——PASS](gleam-layer/p4-feedback.md)
- [P5：最终重放、回归与同引擎验收](gleam-layer/p5-validation.md)
- [Gleam Layer：实现与可验证结果](gleam-layer/universal-validation.md)
- [> 本文描述历史 QS 兼容接口。当前公开插件和通用 API 指南为](gleam-layer/user-guide.md)

### 架构决策

- [ADR 0002：使用执行实例拥有的 ETS 实现源代码子句/结果探针](adr/0002-automatic-coverage.md)

### 实施计划

- [位图覆盖后端实现计划](plans/coverage-bitmap-implementation-plan.md)

[UML 图的源文件和图像](diagrams/README.md)单独维护。
