# 崩溃发生次数、签名与验证式重放

[English](../../replay.md) · [Русский](../ru/replay.md) · [Español](../es/replay.md) · **简体中文** · [所有语言](../README.md)

原始 `.input` 是权威触发二进制。配方重建字节；签名聚合失败；二者都不能
替代原始输入或完整诊断 Reason/stack。重放以显式 `Module:run(binary())`
契约使用原有插桩 executor，不创建第二个模糊测试引擎。

## 身份与报告上限

| 字段 | 身份 / 用途 |
|---|---|
| `occurrence_id` | 每次检测到目标失败（含相同输入重复）新建随机 128 位 ID |
| `input_hash` | 精确触发字节的 SHA-256，独立于失败分类 |
| `signature_id` | 规范化、版本化崩溃签名的 SHA-256 |
| `group_id` | 唯一崩溃组，目前等于 `signature_id` |
| `id` | 组签名的兼容别名；**不是发生 ID** |
| `crash_signature` | 可读规范化描述，不替代原始诊断 |

通过 `efz:start/1` 配置：

```erlang
crash_policy => #{reason => category, max_frames => 5, max_representatives => 3}
```

未知键拒绝。`max_frames`、`max_representatives` 范围 1..32。
默认 Reason 策略 `category` 保留原子原因或元组首原子（如
`{badmatch, Bytes}` 变为 `{tag,badmatch}`）；其他保留 term 类型。
`exact` 保留数据值，以带类型占位符代替 pid/reference/port/fun 身份。
`ignore` 不把 Reason 纳入分类。这是分组启发式：`category`/`ignore` 可合并
同栈的不同缺陷；`exact` 刻意区分依赖数据的原因。`exact` Reason 内路径是
数据，不改写。

签名模式 v2 包含 class、reason 策略、规范化 Reason 及最多 `max_frames`
个目标帧。帧为 `{Module,Function,Arity}`：参数列表转为 arity，排除文件/行/
列及 executor/guardian/coverage 帧。哈希采用显式元组字段顺序，Reason map
变为有序 pairs，不哈希依赖 VM 的默认 ETF map 顺序。原路径、参数列表及
**完整原始 Reason** 留在 `artifact.term`。旧 fingerprint 工件不改动，
不自动重分组。

`Report.crashes` 每签名一条，含 `occurrences`、`first_occurrence_id`、
`last_occurrence_id`、`representatives`。首代表 input/result/metadata/path
保留作兼容字段。只有前 N 个**不同输入哈希**进入代表列表与崩溃 `decisions`；
重复只增加计数不追加决定。`crash_occurrences` 含 crash、exit、timeout；
`crashes` 和 `timeouts` 仍分别计数。`unique_crashes` 包括未保存组。
这些是当前活动计数；每组另有磁盘读取的 `durable_occurrences`、
`disk_representatives`、`group_path`。

同一 `max_representatives` 作用于**每签名的磁盘与报告**。磁盘跨活动/VM 保存
前 N 个不同哈希。已选择输入再次出现返回 `storage => duplicate`，增加计数并
复用不可变工件。`path` 指该代表；`representative_occurrence_id` 指实际保存
的发生，`occurrence_id` 指当前事件。字节相同；保存的 Reason/recipe/build
元数据属于原代表。

超磁盘上限的新输入返回 `storage => limit_reached`，增加持久计数且**无工件
路径**。不为此输入写文件。当前活动仍可在有界内存代表中保存精确字节/Reason
及明确存储状态。下调至低于现有代表数时失败，不静默删除发现。上调允许之后新
输入成为代表。

这是每签名数量上限，不是全局字节配额或不同签名数量上限。所选工件保留完整
Reason；未选发生只计数，不单独归档。请求的变异 trace 有独立 `trace_limit`。

## 原子工件布局与中断策略

```text
CRASH_DIR/SIGNATURE_SHA256/
  summary               EFZG v1 持久计数和代表 ID/哈希
  OCCURRENCE_ID/         仅所选代表
    artifact.input      精确二进制，无 term 编码
    artifact.term       模式 v2 完整原始结果/Reason、元数据和策略
    artifact.replay     EFZX v1 兼容 expectation
    artifact.recipe     可选 EFZR v1 具体变异来源
    manifest            文件大小和 SHA-256 哈希
  .lock/                独占写者；下次保存前须不存在
  .tmp-*                未提交写入，不是发现
```

`efz_crash_store` 用独占目录锁串行所有写者，包括独立 VM。接受新发生前验证
summary 和所有已选工件 manifest。所选工件先通过文件 fsync/close、目录 sync、
原子 rename 提交；再同步原子替换 `summary`。释放锁后也同步目录。
无 append-only 事件日志，也不为丢弃输入逐一写文件。重复**最后提交的发生 ID**
幂等；普通调用总分配新 ID。

EFZG v1 是 41 字节 `EFZG`/版本/长度/SHA-256 封装，加安全未压缩 ETF，最多
16 KiB。七键模式含版本、签名、无符号 64 位发生计数、首/末发生 ID、末输入
哈希和最多 32 组不同代表 ID/哈希。无需解码目标派生原子或原 Reason。
`efz_crash_store:read(GroupDirectory)` 返回验证索引。

中断写者可留下锁、临时文件或 summary 尚未引用的已提交工件。这些产生**明确
基础设施错误**，不重置为空索引。锁报告 `writer_active_or_interrupted`；
EFZ 不猜另一 VM 是否已死。发布后失败保留原工件，已知时报告 `saved_artifact`。
计数只反映已提交 summary；未确认中断事件无精确恢复保证。存储错误时触发字节
仍在运行时失败上下文。

无 summary 旧组写入时以 `unindexed_crash_group` 拒绝。仍可重放，不删除或
自动迁移。新有界存储用新输出目录，旧目录留档。恢复中断存储前先确认无写者并
检查已提交工件；仅去锁不绕过索引验证。这防止重启静默超磁盘上限。

原始重放仅需 `.input` 与可信 `.replay`；可选 `.recipe`/`.term` 损坏或缺失
不阻止恢复。继续**写入**则拒绝损坏代表。`efz_fs:validate_group/1` 可显式
验证完整工件。

配方损坏不能阻止保存已选原始代表：EFZ 保存 input/result/expectation，无
recipe，并返回 `operation => encode_recipe`。达到上限仍报告配方错误和明确
保留状态，不宣称丢弃输入已落盘。有精确代表时提供 `saved_artifact`。主文件/
配方错误不被释放锁或之后写报告错误替代。

guardian 回复**之后**再失败，executor 保留先前基础设施结果并记录次要
`guardian_failure`。回复原 outcome、覆盖诊断和清理证据留在
`execution_evidence`；最终清理改为 `unconfirmed`，VM 退役。
feedback/report/stats 保留主因。`efz_crash_retention_tests` 在私有 VM 真正
回复之后注入该错误，生产无故障注入开关。

## 运行示例并在新 VM 重放

从仓库根目录：

```sh
rebar3 compile
escript examples/staged/run.escript
escript scripts/replay.escript --input _build/staged-example.input \
  --target efz_staged_parser --artifacts _build/staged-targets
escript scripts/replay.escript --recipe _build/staged-example.recipe \
  --target efz_staged_parser --artifacts _build/staged-targets
```

示例把 expectation 复制到 `_build/staged-example.replay`。外部适配器加入
可重复 `--code-path /path/to/harness/ebin`。`--expect FILE.replay` 覆盖
默认同目录 expectation。`--timeout MS` 默认 100；执行用
`--max-input-bytes N` 默认记录的活动上限。`--help` 列执行与重建用法。

| 退出 | 含义 |
|---|---|
| 0 | `reproduced`：harness/build 兼容、规范化失败签名相同 |
| 3 | `not-reproduced`：兼容执行正常返回或以不同方式失败 |
| 2 | 参数/数据无效、输入哈希不同、缺预期身份、build/harness 不兼容 |
| 1 | 文件系统/executor 基础设施失败；绝不报告为普通未复现 |

先核对精确 SHA-256、预检所供工件，再比较**完整**预期构建集。比较保存的
harness 名、BEAM MD5、确定性 attributes SHA-256 及可选插桩 build ID。
portable harness 记录不含编译源路径；代码、attributes、插桩身份仍须相同。
新 pins 防止预检到执行间替换。原始重放**不**加载 `.term` 或 `.recipe`，
故缺失/损坏不阻止有效输入恢复。recipe 重放对再生字节核对相同预期哈希。
不一致在调用目标前拒绝，无未经检查的回退或强制忽略选项。

复现指规范化签名相等，不是非确定原 Reason 或栈路径相等。非确定目标可合法
返回 `not-reproduced`。runner 本身失败是基础设施错误。

## 重放 expectation（EFZX v1）

`artifact.replay` 头 41 字节：`EFZX`、版本字节 1、大端 32 位载荷长度、
SHA-256，后跟精确长度未压缩 ETF。读取最多 2 MiB。安全解码不创建目标派生原子：
模块名是二进制，只需固定 EFZ 模式原子。ready 模式严格八键：
`schema_version`、`status`、`harness`、`target_builds`、`input_hash`、
`signature_id`、`crash_policy`、`max_input_bytes`。Builds 有唯一二进制模块名
和 32 字节哈希；执行前验证 harness 字段/大小。此数据不选择可调用目标。

未同时固定 harness 与所选插桩构建的低层/manual 结果写 `status => unavailable`。
强执行重放拒绝。旧配方本身不能证明原 harness 身份；调用方须提供独立可信
expectation，选择当前 harness 并声称它是旧版不算兼容检查。校验和检损坏，
不提供防篡改或真实性。

## Erlang API 与字节重建

```erlang
[Crash | _] = maps:get(crashes, Report),
Path = maps:get(path, Crash),
{ok, Expected} = efz_replay:load(Path ++ ".replay"),
{ok, Verdict} = efz_replay:run(raw, Path ++ ".input", my_harness,
    Artifacts, Expected, #{timeout => 1000}),
maps:get(status, Verdict).
```

`efz_recipe:execute/5`、`execute_file/5` 仍是低层执行 API。除显式 target/
artifacts/expected builds 外，Options 现在**要求 `expected_harness`**，
来自可信保存元数据。返回 executor 结果，不判断签名复现。接受 `timeout`、
`coverage_backend`、`max_input_bytes`；拒绝 prepared plan 句柄。每次重放创建/
释放新 plan。`efz_replay:run/6` 用同路径并比较签名。`harness_identity/1`
在发现时捕获 portable 身份；`pin/3` 执行前验证。

字节重建独立于兼容代码：

```sh
escript scripts/replay.escript _build/staged-example.recipe _build/regenerated.input
cmp _build/staged-example.input _build/regenerated.input
escript scripts/replay.escript docs/examples/staged-crash.recipe _build/from-docs.input
cmp docs/examples/staged-crash.input _build/from-docs.input
```

历史位置参数 CLI 只再生成字节（默认 4096，可选 `--max-input-bytes N`），
不验证目标兼容性，不声称重现崩溃。校准输入和 random 变异可能没有配方。
Staged 输入用 `efz_recipe:load/1` + `regenerate/1` 从主/捐赠字节与具体操作
精确重建，无需 corpus、RNG、活 plan。保留条目的 recipe 在 `metadata.mutation`。

## EFZR 工件格式，版本 1

所有多字节封装整数为大端：

```text
"EFZR"（4 字节）
格式版本 = 1（1 字节）
载荷长度（4 字节）
载荷 SHA-256（32 字节）
未压缩 Erlang external-term 载荷（精确长度）
```

载荷为验证后的数据 map，严格包含：

| 字段 | 含义 |
|---|---|
| `schema_version`, `engine_version`, `operation_version` | 本阶段全为 1；拒绝未知版本 |
| `primary`, `primary_id`, `parent` | 原输入字节、SHA-256、诊断 corpus 条目 ID |
| `operations` | 顺序具体元组，最多 32；内含捐赠字节/哈希及真实字典/字面字节 |
| `stage` | 产生候选的阶段 |
| `config_id`, `dictionary_id` | 原规范化配置/字典 SHA-256 身份 |
| `limits` | 验证操作所需输入、块、token、算术上限 |
| `output_size`, `output_hash` | 预期候选长度、SHA-256 |
| `target_builds` | 二进制模块名及固定 build ID；无可调用模块引用 |
| `rng` | 诊断 `exsplus` 算法和初始整数种子元组；无内部状态/handler |

配方无需原字典、corpus、文件、队列索引、RNG 检查点或活 plan。配置身份描述
原选择；具体操作表而非重跑 plan 决定字节。跳过尝试因未改中间字节不记录。
Offset 顺序作用于中间结果，语义见 [mutations.md](mutations.md)。

配方文件最多 40 MiB。输入/捐赠须满足记录的活动限制（最大 1 MiB）。
`regenerate/1` 用记录限制；`regenerate/2` 另接受当前限制（如
`#{max_input_bytes => 4096}`），也查中间大小。脚本默认 4096，可设
`--max-input-bytes N`。解码器检查长度/哈希，随后在解码**之前**扫描 ETF
结构。允许有界整数、已有原子标签、二进制、列表、元组、map。拒绝压缩、
process/reference/port/fun、尾随数据、深度超 24、超 20,000 terms、列表超
4,096 及超大二进制字段。安全解码不能创建 token 派生原子。再做操作/模式验证，
检查字段、版本、主/捐赠哈希、限制、实现的操作结果及最终长度/哈希。

错误编码返回 `{error,invalid_recipe_encoding}`；其他有 `incompatible_recipe`、
`recipe_size_limit`、`output_hash_mismatch`、`output_size_mismatch`、
`{invalid_recipe,Reason}`、`{recipe_operation,Reason}`。会 skip 的操作（包括
offset 不合适）在已实现配方中非法。任何操作元组不作为 Erlang 源码求值，也不
派发任意模块。文件解析不使用表达式求值器。

校验和检损坏，不是认证。原 crash `.term` 另有格式，可含运行诊断引用；
不是有界 EFZR 导入格式，也不是 replay 依赖。
## 验证

`efz_crash_tests` 用真实插桩 parser、普通二进制 harness、staged 变异和新 CLI
VM。证明不同输入独立发生、源码搬移后签名稳定、可配置数据原因、raw/recipe
复现、build/harness 不符拒绝、损坏处理及区分未复现/基础设施退出（含不可读
输入、缺工件目录）。1000 次发生活动保留一组、三代表、三 crash decisions，
三个原始输入工件和计数 1000 的 summary。真实 coordinator/worker 死亡测试验证
主失败报告、计数和清理。既有限制、配方、覆盖、持久 corpus、staged 父复用测试
覆盖共享路径。

在项目 OTP 27 工具链验证。改变目标源/选项/工具链可能改变 build 身份并刻意
拒绝旧 expectation。配方字节重建有自己的版本契约。

## Runtime 发现

Runtime schema v1 独立于 crash expectation/recipe。使用
`efz_replay:runtime(Directory, LocalTarget, Artifacts, #{runs=>3})` 或
`scripts/replay.escript --runtime-finding DIRECTORY --target MODULE --artifacts DIR
--runs 3`。身份/哈希/策略检查后用同 executor；区分 `observed`、`not_observed`、
`inconclusive`，包含样本数量及可重复性。一次成功不能反证不稳定。
[完整格式与限制](runtime-diagnostics.md)。

### 提供者与 raw replay

已保存的原始字节可在没有 Erlamsa 的情况下重放。候选重新生成需要兼容的 build/config 标识；不匹配时会明确报错。参见[简明指南](erlamsa-integration.md)。
