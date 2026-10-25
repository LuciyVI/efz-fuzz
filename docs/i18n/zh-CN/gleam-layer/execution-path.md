# 实际源码映射

[English](../../../gleam-layer/execution-path.md) · [Русский](../../ru/gleam-layer/execution-path.md) · [Español](../../es/gleam-layer/execution-path.md) · **简体中文** · [所有语言](../../README.md)

- efz_config:prepare/1 验证配置，efz_cov_native_public:preflight/1 或
  efz_instrument:preflight/1 验证所选目标产物。
- efz_fuzzer:init/1 启动现有语料、统计与 worker 监督器。
- efz_worker:handle_info/2 在变异前校准种子；staged_iteration/1 使用
  efz_corpus:mutation_entries/0 调用 efz_mutation_plan:next/2。
- efz_mutation_plan:visit/2 按插入顺序访问父输入和现有通道；
  attempts/6 在解码前分发可选结构化分支，否则 ordinary_attempts/6 保留确定性、havoc 和 splice 操作。
- efz_worker:execute_checked/4 调用 efz_executor:run/4。
  efz_guardian 管理超时、受管后代、清理与覆盖完成。
  execute_result/6 评估新颖性前，覆盖已经物化或封存。
- efz_worker:semantic_callbacks/4 位于目标快照之后。
  纯观察器使用归一化结果；纯模型一致性判定器有有限检查次数，
  目标调用为**零**。不增加队列、worker 或额外执行区间。
- efz_feedback:evaluate/3 仍是结构新颖性的权威。
- efz_corpus:semantic_admission/6 为引导模式扩展保留，
  在更新语料所属特征状态前提交持久化。
  efz_corpus:select/0 和 staged 计划使用相同条目，没有独立语义语料。
- efz_worker:record_failure/4 -> efz_crash:save/4 保留原始字节。
  目标故障先于语义回调；判定器故障在同一发现存储中使用独立指纹，不受新颖性影响。
- efz_recipe:regenerate/1 不依赖 Gleam 重建版本化 structured_replace 数据；
  efz_replay 和 efz_recipe:execute/5 使用现有固定执行器。
  efz_semantic_replay 单独检查属性并统计最小化器的每次执行。
  efz_semantic:cover/1 保守保留已记录特征。
