# 可复用的持久化语料库

[English](../../corpus.md) · [Русский](../ru/corpus.md) · [Español](../es/corpus.md) · **简体中文** · [所有语言](../README.md)

通过活动配置的 `corpus_dir` 或启动器的 `--corpus-dir` 显式启用持久化。
未启用时继续使用原有内存活动流程。存储保留初始输入和成功发现新覆盖的输入，
跨越 `efz:stop/0`、进程结束和 VM 重启。变异产生的崩溃与超时仍只进入原有崩溃
存储。初始种子在校准前保存，包括之后被发现会崩溃的种子。

```erlang
{ok, _} = efz:start(#{target => my_harness, artifacts => Artifacts,
    seeds => [<<>>], corpus_dir => "findings/corpus",
    mutation_mode => staged, max_iterations => 1000}).
First = efz:await(infinity),
ok = efz:stop().

%% 后续 VM 加载相同的兼容 harness 和工件。
{ok, _} = efz:start(#{target => my_harness, artifacts => Artifacts,
    seeds => [], corpus_dir => "findings/corpus",
    mutation_mode => staged, max_iterations => 1000}).
Second = efz:await(infinity).
```

首次从 CLI 启动时加入 `--corpus-dir ./findings/corpus`。后续启动：

```sh
escript scripts/fuzz.escript \
  --target my_harness --code-path ./harness-ebin \
  --artifacts ./instrumented --out ./findings \
  --corpus-dir ./findings/corpus --mutation staged --max-iterations 1000
```

## 存储与发布

```text
CORPUS_DIR/
  <输入 SHA-256 的 64 位小写十六进制>/
    input       精确原始二进制，包括零长度输入
    metadata    带校验和、含版本化元数据的 EFZC 封装
  .tmp-<随机事务后缀>/   中断时留下的未发布事务
```

内容哈希就是身份。已提交条目不可变；重复输入保留首次记录的来源。
保存时先验证已有条目再去重，绝不静默修复或覆盖已提交的损坏数据。
新的整数语料 ID 属于当前活动。元数据中的历史 ID 只表示来源，不是重建队列的指令。

元数据包含：

| 字段 | 含义 |
|---|---|
| `schema_version` | 初始/存在性条目为 `1`；命中计数发现为 `2` |
| `content_hash`, `input_size` | SHA-256 与精确字节长度 |
| `queue_id` | 来源活动的历史队列 ID |
| `origin` | `initial` 或成功发现新覆盖的 `discovery` |
| `parent` | 初始种子为 `none`；发现条目为父内容 SHA-256 和历史队列 ID |
| `discovery` | 阶段和新观察的探针身份；v2 还存 `coverage_feedback`、`retention_reason`、`new_count_features` |
| `identity` | harness 模块名、固定 `run/1`、已加载 harness 代码 MD5、覆盖模式及所选模块/构建 SHA-256 身份 |
| `recipe` | 可用时为编码后的 EFZR 配方，否则 `none` |

自动探针及构建模块名存为二进制，加载元数据不会创建任意原子。
手动覆盖 ID 是供历史查看的不透明 ETF 二进制，恢复期间绝不解码。
运行时执行引用、目标返回值、PID、ETS 句柄与进程字典不属于持久元数据。
配方 RNG 种子与探针增量只记录历史来源，不初始化新调度器或全局覆盖。

可选[命中计数模式](hit-count-experiment.md)为发现写记录 v2：
`retention_reason` 为 `new_probe` 或 `new_hit_count`，`new_count_features`
包含 `{PortableProbeIdentity, BucketLowerBound}` 对。仅计数发现的
`new_probes` 为空而特征增量非空。EFZC 封装版本仍为 1；读取器验证记录版本
及其特定形状。原 v1 记录仍原样加载。旧程序明确拒绝 v2；如需旧 EFZ 读取，
请使用不同语料目录。

反馈模式不属于目标/构建兼容性：原始输入可在两种模式复用，每个恢复输入都重新
校准。历史计数桶增量不导入新活动的全局特征集。

EFZC 文件包含魔数 `EFZC`、封装版本 1、32 位载荷长度、32 字节载荷 SHA-256
和未压缩 ETF 元数据。加载检查大小/校验和、有界纯数据 ETF 语法、模式、必需
字段、输入大小/哈希、目录内容身份及配方与输入、父节点和构建的一致性。
原始输入每条最多 1 MiB，元数据每条最多 64 MiB。不支持的模式版本是错误，
不会尝试迁移。

发布顺序：

1. 在语料目录内创建唯一暂存目录。
2. 以独占创建方式写原始输入；fsync 并关闭。
3. 写完整元数据；fsync 并关闭。
4. fsync 暂存目录，随后原子重命名为内容哈希。
5. 确认保存前 fsync 语料目录。

新建祖先目录也通过父目录同步。文件与暂存目录处于同一文件系统，读者在发布时
看到完整条目。同内容的第二个发布者验证已发布条目而非替换。原生 Erlang 实现
使用 `file:sync/1`，包括以 `[read,raw,directory]` 打开的目录句柄。
这已在当前 Linux 文件系统/OTP 27 环境测试。不支持目录 fsync 的文件系统明确
失败，不静默降低持久性保证。这里没有测试真实断电恢复。

语料 gen_server 串行处理持久化与插入。成功发现先提交，再进入活动队列或增加
`discoveries`。write/fsync 出错时不插入输入，worker 报告语料持久化基础设施
失败。若 rename 成功而最终 fsync 失败，条目可能已可见；活动仍报告失败，
后续恢复会验证该条目。同步完成前不确认成功。

## 恢复与构建策略

`efz_config` 先验证当前目标/工件，再恢复条目。它将提供的种子（插入顺序）与
持久输入（哈希顺序）合并，按 SHA-256 去重。语料所有者分配新 ID，并通过
普通 `mutation_entries/0`、`select/0` 提供恢复条目。历史元数据位于每条的
`metadata.persistence`；恢复条目还包含 `metadata.restored => true`。

原 worker 校准**每个**初始输入，包括恢复输入。它创建全新全局覆盖集、RNG 和
惰性变异计划。不恢复调度游标、PRNG 状态、旧全局覆盖、精确队列 ID 或顺序。
这是输入复用，不是活动精确续跑或检查点。

恢复输入必须满足当前 `max_input_bytes`（两种变异模式）；超大条目使配置失败，
报告内容寻址路径、大小下界和有效限制。不会截断或静默排除。
持久模式去重后仍适用原有 4,096 个提供种子的上限；恢复活动队列可更大，因其
可能在早先活动中增长。存储立即全部加载，所有输入/元数据须能放入 VM 内存。

| `corpus_build_policy` | 行为 |
|---|---|
| `reject`（默认） | harness 名称/代码、回调、覆盖模式或所选构建身份不同则恢复失败 |
| `recalibrate` | 身份改变时复用精确输入；保留历史来源，输出诊断并用当前构建校准 |

两种模式都不把旧覆盖增量并入新活动。即使用 `recalibrate`，模式、校验和、输入
及配方错误仍然致命。

## 不完整条目与诊断

已提交条目损坏、缺 `input`/`metadata`、截断、哈希/目录名不符或模式不兼容
会使恢复失败并提供路径和原因。不静默接受部分子集。不符合专用存储格式的
文件系统条目同样报错。

`.tmp-*` 是未发布写入，绝不作为输入加载，保留原处供检查。恢复在加载有效
条目的同时逐一报告 `{interrupted_corpus_write,Path}`。此诊断与允许的构建
不一致出现在启动警告及最终 `corpus_restore.diagnostics`。
`corpus_restore` 还报告目录、策略和恢复数量。只有确认无写者使用后才删除
废弃暂存条目。

## 证据

```sh
rebar3 eunit --module=efz_corpus_store_tests,efz_durable_tests,efz_cli_tests
```

集成测试在不同 Erlang VM 中执行真实 staged 字典变异与自动插桩：

- VM 1：初始 `<<>>` ID 1 产生 `<<"A">>` ID 2，打开新覆盖并提交。
- VM 1 退出。独立调用验证初始/持久内容去重。
- VM 2：`seeds => []` 恢复并校准两条输入。`<<"A">>` 现在为 ID 1，
  成为产生 `<<"AB">>` 变异的真实主输入/父节点。
- 更多新 VM 验证默认拒绝构建、显式跨构建重新校准、输入限制及变异崩溃不进入存储。

测试检查父 ID/哈希、精确配方再生成、目标结果、新探针和来源。日志与报告保留于
`_build/durable-e2e-latest.txt` 所记路径。单元测试覆盖重复发布、损坏/缺失/
截断文件、模式、内容名称、构建策略及写失败不入队。中断写测试在写入/fsync
暂存输入后、发布前杀死真实进程，验证部分事务被诊断且不恢复。
