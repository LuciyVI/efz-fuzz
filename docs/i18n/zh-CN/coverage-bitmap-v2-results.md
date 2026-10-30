# 位图覆盖 v2：实现与测量结果

[English](../../coverage-bitmap-v2-results.md) · [Русский](../ru/coverage-bitmap-v2-results.md) · [Español](../es/coverage-bitmap-v2-results.md) · **简体中文** · [所有语言](../README.md)

日期：2026-10-02。这是 [v1 审计](coverage-bitmap-audit.md)的后续报告，不替代其基线。
位图仍需显式启用；`ets` 仍为默认。

## 变更与边界

* [`efz_worker:init/1`、`execute_checked/4`](../../../src/efz_worker.erl)为每个位图活动分配一个执行映射，并传给每个 guardian。最终活动报告包含 `bitmap_storage`：分配映射数为一个、激活次数和正常复用次数。worker 同步执行迭代，只有在 `efz_executor:run/4` 收到 guardian 最终 `DOWN` 后才会激活映射。
* [`efz_guardian:finish/2`](../../../src/efz_guardian.erl)仅在现有受控后代清理达到 `confirmed` 后封存紧凑成功位图观察：停止接纳、全部已知后代和协调器死亡、进程及全局追踪屏障已送达、运行时采样器停止。失败或未确认清理会把运行器标为 dirty。[`efz_executor:guardian_failed/2`](../../../src/efz_executor.erl)也将 guardian 死亡转换为 dirty runner。此类执行的映射不会重新激活；活动停止。guardian 死亡后，晚到写入者仍可能修改其**已退役**分配，但不能写入下一执行映射。此契约涵盖已接纳本地后代，不涵盖任意远程或不受控进程。
* [`efz_cov_bitmap:allocate/1`、`open/2`、`seal/1`](../../../src/efz_cov_bitmap.erl)使用可复用无符号 `atomics` 字数组、活动状态及代际编号。对于默认 65,536 位映射，`open/2` 完整清零 1,024 个字并递增代际。即使后续执行已封存，旧代际封存令牌仍被拒绝。单独的 `Active=0` **不能**作为写入者已静止的证据；该证据由 guardian 生命周期提供。原有 `open/1`、`snapshot_bits/1`、`reset/1` 和不可变快照路径保留，用于低层差分测试及回退。
* [`efz_cov_bitmap:has_new/2`](../../../src/efz_cov_bitmap.erl)按字扫描 `Current AND NOT Global`，在首个新字处退出。[`efz_feedback:bitmap_sealed_success/5`](../../../src/efz_feedback.erl)在无新位时不改变全局状态；存在新颖性时，仅解码**新**位用于现有精确 `new_probes` 决策，再单独按字合并全局状态。崩溃、退出、超时和基础设施结果仍不合并。反馈模块通过 [`efz_coverage`](../../../src/efz_coverage.erl)访问位图操作。
* 常规活动成功路径不再物化完整位图快照或全部已观察探针 ID。首次命中消息仍进入 guardian 完整性记账；按字位计数确认其数量与封存映射一致。[`efz_cov_integrity:observation_count/3`](../../../src/efz_cov_integrity.erl)保留观察分类和计数。故障、低层执行器调用及启用运行时判定器的活动仍生成原有精确列表。最终全局报告仍解码精确 ID。插桩、测试驱动 API、变异引擎、崩溃分类和语料接纳未改变。
* [`efz_config:valid_field/2`](../../../src/efz_config.erl)在活动启动前拒绝大于 2^26 位（8 MiB 有效载荷）的容量；容量必须为正且可被 64 整除。默认 65,536 **位**（8 KiB 有效载荷）。默认 v2 分配约使用字数组 8,232 字节、活动及代际 atomics 56 字节，另加模式、反向 ID、二进制、Erlang term 和分配器开销。

## 隔离与复用状态机

`worker 拥有的映射（非活动） → guardian 激活并完整清零 → 受控写入者 → guardian 确认清理 → 封存 → worker 比较 → 可选提交 → 语料决策 → 下次激活`。

反馈读取期间封存映射保持不变，因为 worker 在反馈和语料步骤结束前不会启动下一执行。
若清理未确认或 guardian 死亡，运行器变为 dirty，旧映射随 worker/VM 退役；
该运行器拒绝后续执行。新运行器或活动分配新映射。
代际编号防止通过过期封存令牌误读。单次活动检查无法关闭检查到 CAS 的竞争窗口，
不会被当作回收证明。受控写入者终止和追踪排空仍是真正的封存边界。

## 验证

变更前基线：241 项 EUnit PASS。v2 后：243 项 EUnit PASS、3 项 CT PASS、xref PASS、Dialyzer PASS。
命令如下：

```sh
ERL_FLAGS='+S 4:4' rebar3 eunit
ERL_FLAGS='+S 4:4' rebar3 ct
ERL_FLAGS='+S 4:4' rebar3 xref
ERL_FLAGS='+S 4:4' rebar3 dialyzer
```

[`efz_bitmap_audit_tests`](../../../test/efz_bitmap_audit_tests.erl)增加在同一映射上 10,000 次 A/B
重新激活、稳定 atomics 分配大小、过期代际拒绝、屏障控制的退役映射晚到写入者，
以及跨成功、重复覆盖、崩溃和超时的 ETS/v2 反馈比较。
[`efz_isolation_tests`](../../../test/efz_isolation_tests.erl)增加全新 VM 的位图 guardian 死亡案例：
清理未确认，运行器变为 dirty 并拒绝下一次执行。
[`efz_bitmap_contract_tests`](../../../test/efz_bitmap_contract_tests.erl)断言活动映射分配和复用次数，
并检查无效容量拒绝。现有完整差分测试继续比较观察 ID、新颖性、全局覆盖和语料决策。
这些测试未在活动 VM 中强制产生真实清理截止时间超限；guardian 死亡确定性地覆盖未确认及退役路径。

## 基准协议与结果

命令（原始文件与报告一同保留）：

```sh
ERL_FLAGS='+S 4:4' escript bench/bitmap_bench.escript _build/bitmap-v2-benchmark-final-code
ERL_FLAGS='+S 4:4' escript bench/bitmap_audit_bench.escript _build/bitmap-v2-baseline-full-cycle.term
ERL_FLAGS='+S 4:4' escript bench/bitmap_v2_cycle_bench.escript docs/performance/bitmap-v2-cycle-2026-10-02.term
ERL_FLAGS='+S 4:4' escript bench/bitmap_v2_components.escript docs/performance/bitmap-v2-components-2026-10-02.term
```

环境：OTP 27.0、ERTS 15.0、Linux x86_64、Intel Core i7-1260P、`+S 4:4`。
配对活动和完整周期驱动预热两组，再交替运行 10 组配对。
组件驱动预热两次，对 100、1,000 或 10,000 次调用采集十个样本。
解析器活动使用 `efz_example_target`/`efz_example_parser`，运行 50 次固定种子随机变异；
每个样本的语料大小 4 和最终覆盖大小 5 都一致。
这些是短期本地测量；CPU 频率和调度器噪声以及仅一个测试驱动限制了推广能力。
v1 测量在同一工作副本改代码之前完成，保留为
[v1 活动及微基准原始数据](../../performance/bitmap-v2-v1-baseline-2026-10-02.term)和
[v1 完整周期](../../performance/bitmap-v2-v1-full-cycle-2026-10-02.term)。
v2 活动及微基准[运行 1](../../performance/bitmap-v2-2026-10-02-samples.term)、
[运行 2](../../performance/bitmap-v2-2026-10-02-final-samples.term)、
[最终代码运行 3](../../performance/bitmap-v2-2026-10-02-final-code-samples.term)、
三方[完整周期](../../performance/bitmap-v2-cycle-2026-10-02.term)和
[组件数据](../../performance/bitmap-v2-components-2026-10-02.term)分别保存。

中位数，除标明 exec/s 外均为微秒：

| 工作负载 | ETS | bitmap-v1 | bitmap-v2 |
|---|---:|---:|---:|
| 解析器活动，exec/s | 362 / 264 | 325 | 255 |
| 完整周期，1 次命中 | 4 | 411 | 195 |
| 完整周期，100 次命中 | 106 | 432 | 250 |
| 完整周期，1,000 次命中 | 2,832 | 985 | 773 |
| 完整周期，10,000 次命中 | 9,685 | 7,143 | 6,939 |
| 完整周期，10,000 次重复命中 | 5,805 | 10,479 | 8,731 |
| 重复命中阶段，5,000 次命中 | 927 / 1,887 | 1,546 | 2,928 |
| 完整清零及激活 | <1（新 ETS 表） | 21（仅清零基准） | 15.01（清零加激活，每样本 100 次调用） |
| 新颖性，256 本地/128 全局 | 82（精确新 ID） | 27（新位图） | 0.197（布尔提前退出） |
| 合并，256 本地/128 全局 | 57 | 28 | 43.72 |

对于解析器和重复命中，斜杠分隔的 ETS 值分别来自 v1 基线与最终代码 v2 配对运行，
**不可**互换作为分母。v1 墙钟中位数为位图 153,702 µs、ETS 138,236 µs；
最终代码 v2 为 195,798 对 189,237 µs。
配对 bitmap/ETS exec/s 比中位数分别为 v1 **0.881**、最终 v2 **0.974**（各 10 对）。
另两次 v2 配对比为 **0.938**、**0.984**；原始审计先前独立运行报告 0.893。
v2 运行显示墙钟时间波动很大，无法可靠确认解析器收益。
三方完整周期行来自同一配对运行，作为算法可直接比较，但两个位图路径都使用 v2 源码中
小幅修改的重复命中逻辑；未经修改的历史 v1 完整周期中位数依次为
419、431、1,852、8,844 和 8,517 µs。
新颖性行有意报告不同返回契约：ETS 返回精确 ID，v1 物化新位图，v2 只返回布尔值；
v2 仅在 `true` 后解码精确新 ID。
重置行包含不同操作，ETS 为亚微秒计时；应使用组件测量理解重置成本，而不是计算加速比。

v2 组件中位数（µs/调用，最小最大值见原始数据）：完整清零与激活 **15.01**、
稀疏封存计数 **25.83**、稠密封存计数 **53.39**、无新颖性稀疏 **24.00**、
无新颖性稠密 **23.47**、首字新颖性 **0.084**、最后一个映射字新颖性 **23.27**，
以及 256 槽位合并 **43.72**。
5,000 次重复命中阶段在全部 v2 运行中都慢于 ETS：
1,486 对 998 µs、1,361 对 890 µs、2,928 对 1,887 µs。

隔离的 10,000 次调用组件样本中，进程字典查找耗时 **0.007 µs/调用**、
完整性注册表查找 **0.210**、精确槽位 ETS 查找 **0.100**、原子读取 **0.021**，
完整重复 `efz_cov_rt:hit/1` **0.431**；这些单独计时成本不能严格相加。
此设置没有 guardian 注册表，因此完整性测量覆盖缺少注册表分支，而非已注册生产写入者。
即使位已经置位，重复命中路径仍支付两次 ETS 查找和保护检查成本。
这些查找以及全映射计数和无新颖性扫描，是稀疏执行剩余的已测瓶颈。
默认完整清零比稀疏计数与检查的组合更简单、成本更低；未加入 dirty words，
因为它会增加每次命中负担，需要独立并发记账设计及端到端收益证据。

## 决策与后续工作

正确性与反馈兼容性：对已测试受控进程契约为 **PASS**。
并发及隔离：对已接纳本地后代、已确认清理和 dirty runner 退役为 **PASS**；
不受控远程进程仍不属于 EFZ 既有契约。
内存：**PARTIAL**；常规活动仅分配一个映射，10,000 次复用周期保持 atomics 大小不变，
但未执行长期 RSS 研究。
性能：默认切换门槛 **FAIL**；v2 改善了解析器配对比，但三次运行中配对中位数均低于 1，
且波动很大，重复命中也更慢。
可维护性：**PARTIAL**；v1 与紧凑路径有意并存以便差分比较；紧凑路径有上文记录的生命周期耦合。

保持 `coverage_backend => ets` 为默认。
bitmap-v2 仅通过显式 `coverage_backend => bitmap` 用于自动 presence。
移除该选项或设置 `coverage_backend => ets` 即可回滚。
重新考虑默认值前，应重复解析器配对运行及其他代表性测试驱动活动，执行长期活动 RSS 和资源测试，
并分析这些工作负载中命中查找还是稀疏全映射扫描占主导。
若无独立测量的正确性与性能依据，不要采用 dirty-word 跟踪或 OTP 原生覆盖。
