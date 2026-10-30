# 长时间 Cowboy 基准：ETS、bitmap-v2 与 OTP-public

[English](../../cowboy-long-benchmark.md) · [Русский](../ru/cowboy-long-benchmark.md) · [Español](../es/cowboy-long-benchmark.md) · **简体中文** · [所有语言](../README.md)

## 用途与目标边界

基准运行 900 秒普通 EFZ 活动。输入是一个 HTTP/1.x 请求的字节。
`efz_cowboy_long_target:run/1` 经内存 `efz_cowboy_transport` 将输入送入真实
`cowboy_http:init/6`；`cowboy_http:loop/1` 及内部 `parse_request/3`、`parse_header/4`、
`request/*`、`parse_body/2` 解析请求行、方法、URI、版本、标头、`Content-Length`
及 chunked 传输编码。`efz_cowboy_stream:init/3` 调用 `cowboy_router:execute/2`
和 `cowboy_req:parse_qs/1`；请求体接收 `cowboy_stream:data/4` 直到 `fin`。
没有网络监听器、Ranch acceptor 或 TCP。这是真正的 Cowboy 解析器与 stream 路径，
但不是完整 HTTP 处理流水线或网络基准。

解析错误和不完整请求返回正常 `{ok,rejected}`。
stream sink 将意外异常交给 EFZ 标准崩溃分类。
每个输入在一个目标进程执行；内存传输关闭和结果标记清理均在 `after` 中完成。
测试驱动不调用覆盖 API。

Cowboy 依赖固定于 `rebar.config`/`rebar.lock`：Cowboy 2.19.0、Cowlib 2.20.0、Ranch 1.8.1。
项目支持 OTP 27+。每次运行只自动编译和插桩以下允许列表：

| 模块 | 探针 |
| --- | ---: |
| `cowboy_http` | 485 |
| `cowboy_req` | 282 |
| `cowboy_router` | 101 |
| `cowboy_stream` | 19 |
| **总计** | **887** |

这些计数在 OTP 27.0 和指定 Cowboy 版本上验证；运行器打印并保存实际数量。
位图含 65,536 **位**，超出容量在活动前停止。
若干记录默认值和列表推导式在现有 `efz_instrument_pt` 中原样保留、不插内部探针，
因此要求 `strict => false`。
列表在编译时打印，并保存到每个目标模块 `.efz-manifest`。
两后端共享此插桩限制。

实验性 `otp_native_public` 对相同 Cowboy 允许列表使用 `line_coverage` 编译，
并通过 `code:get_coverage(line, Module)` 读取覆盖。
此环境的 Cowboy 2.19.0 得到 1089 个原生行槽位。
这是 OTP 可执行行，因此 1089 不能作为等价覆盖单位与 EFZ 的 887 个结构探针比较。
模式在目标加载前选择。

种子位于 `test/targets/cowboy/seeds/`：12 个带 CRLF 的小请求，含 GET、query、
带长度 POST、多个标头、HEAD、OPTIONS、绝对 URI、HTTP/1.0、chunked body 及两个畸形请求。

## 运行

从 `efz/` 根目录执行：

```sh
./scripts/run_cowboy_long_bench.sh --backend ets --duration 900 --seed 424242
./scripts/run_cowboy_long_bench.sh --backend bitmap --duration 900 --seed 424242
./scripts/run_cowboy_long_bench.sh --backend otp_native_public --duration 900 --seed 424242
```

分析引擎成本的实验模式包括 `--backend none`（无插桩 Cowboy）、
`--backend none_instrumented`（带 OTP 行插桩但无 reset/read/feedback 的 Cowboy），
另有 `--target noop` 和 `--profile`。
短期测量、开销解释和 `profile.term` 查看命令见[引擎分析](engine-performance-profile.md)。
`none` 不是覆盖引导模式，不改变默认 ETS。
下一阶段包含 15 分钟运行、相同输入序列（`--fixed-replay`）及时间分析的结果见
[engine-performance-profile-v2.md](engine-performance-profile-v2.md)。

每条命令启动全新 Erlang VM。若需反向顺序的额外配对，随后用相同参数运行 bitmap → ETS。
另选初始语料使用 `--corpus DIR`（普通文件的平面目录），显式新结果目录用 `--out DIR`。
已有 `--out` 不覆盖。`--duration` 单位为秒。
`--seed` 用于 EFZ 随机变异及语料父输入选择。
种子相同表示初始状态相同，不保证历史相同：固定时间内后端速度不同，变异数不同，语料可能分化。
严格覆盖语义检查应使用相同 EFZ 事件历史的差分测试。

Rebar3 无法下载依赖的机器需要 GitHub 访问或预填充 Rebar3 缓存。
受限本地环境中 Rebar3 无法解析已配置代理；验证时手动将固定仓库克隆到 `_build/default/lib/`。
这不改变版本锁。

结果写入新目录：

```text
artifacts/cowboy-long-bench/<UTC timestamp>-ets/
artifacts/cowboy-long-bench/<UTC timestamp>-bitmap/
```

每个目录含 `config.term`、`environment.txt`、`samples.csv`、`summary.term`、`summary.csv`、
`coverage.term`、`cleanup.term`、`corpus/`、`crashes/` 和 `target-beams/`。
结果目录被 Git 忽略。
`environment.txt` 包含 git commit/status、OTP/ERTS、Cowboy、OS/CPU/架构、调度器、
后端、位图大小、EFZ 配置、时长及种子。

比较已完成配对：

```sh
python3 scripts/compare_cowboy_long_bench.py \
  artifacts/cowboy-long-bench/<ETS_RUN> \
  artifacts/cowboy-long-bench/<BITMAP_RUN> \
  artifacts/cowboy-long-bench/<OTP_PUBLIC_RUN>
```

脚本接受 2–4 目录，检查初始配置，打印 exec/s 及离散范围、首末 60 秒、覆盖与语料、
内存和进程；长运行还打印约 0/5/10/15 分钟 RSS/VM/ETS 内存。
EFZ 点和 OTP 行绝对计数带不同单位警告。
独立模糊运行之间的差异是描述性的，本身不能证明后端语义改变。

## 独立实验：`erlang-fuzzer(1)`

`./scripts/run_cowboy_long_bench.sh --backend erlang_fuzzer` 调用独立的
`scripts/run_erlang_fuzzer_cowboy_bench.py`。
它使用提供的 `erlang-fuzzer(1)` 源码，对**相同 Cowboy 2.19.0、相同四个目标模块、
相同测试驱动路径和相同种子文件**运行。
Cowboy 以 `line_coverage` 编译，外部 `fuzzer.erl` 选择 OTP `line_counters`，
通过 `core.c` NIF 向 libFuzzer 注册计数器。
源码来自 `~/test/erlang-fuzzer(1)/erlang-fuzzer/fuzzer`（或 `--source DIR`），
不复制入 Git，不改变 EFZ。
副本在独立 `/tmp` 目录构建：原 Makefile 用 GDB 获取当前 `beam.smp` 偏移；
包装器仅关闭用户 GDB init（`gdb -nx`），不替换为预计算偏移。
`core.c`、驱动及 `beam.smp` 的 SHA256 保存于 `environment.txt`。

```sh
./scripts/run_cowboy_long_bench.sh --backend erlang_fuzzer \
  --source "$HOME/test/erlang-fuzzer(1)/erlang-fuzzer/fuzzer" \
  --duration 900 --seed 424242
```

运行使用独立 Erlang VM。
任何 Cowboy 模块未注册原生覆盖或 libFuzzer 没收到特征时，运行器拒绝结果。
支持 `--corpus DIR` 和 `--out NEW_DIR`。
结果写入 `artifacts/cowboy-long-bench/<timestamp>-erlang_fuzzer/`，含
`samples.csv`、`summary.csv`、`environment.txt`、`fuzzer.log`、语料副本、崩溃产物及构建日志。
运行后与三种 EFZ 模式比较：

```sh
python3 scripts/compare_cowboy_long_bench.py \
  artifacts/cowboy-long-bench/<ETS_RUN> \
  artifacts/cowboy-long-bench/<BITMAP_RUN> \
  artifacts/cowboy-long-bench/<OTP_PUBLIC_RUN> \
  artifacts/cowboy-long-bench/<ERLANG_FUZZER_RUN>
```

这是**完整模糊测试引擎比较**，不是单一覆盖收集操作测量：
libFuzzer 在一个进程内执行输入，没有 EFZ guardian，使用不同变异及自身语料保留规则。
即使种子相同，输入序列也会分化。
libFuzzer 的 `ft` 和 `cov` 既不等于 EFZ 结构探针，也不等于唯一 OTP 行数。
提供的 `core.c` NIF 注册 `line_counters` 字节，并按索引构造合成 PC 表，
因此特征数不能与 `code:get_coverage/2` 比较。
共享表中，外部覆盖数量、发现及不可用 VM/进程指标显示 `n/a`；`ft` 与 `NEW/REDUCE` 单独显示。
exec/s 不能证明覆盖收集器本身的速度。
这需要在可比执行生命周期下隔离重放相同输入。

此 NIF 使用 ERTS 私有结构及覆盖缓冲指针，未证明 reload/purge 时的生命周期保护。
只能在一次性 VM 运行；它是研究模式，不是 EFZ 后端。
若 OTP 改变、缺少 DWARF/调试符号或注册失败，结果不可使用。
脚本不重载模块，不把外部 NIF 纳入 EFZ 主运行时。

2026-10-03 短检查：`--duration 2 --seed 424242` 退出码 0，
日志确认全部四个 Cowboy 模块 `coverage on`，`ft` 高于初值，语料增长。
原始输出：`artifacts/cowboy-long-bench/20261003T172502Z-erlang_fuzzer/`（本地，未入 Git）。
`rebar3 eunit`：256 PASS。900 秒外部运行**未运行**；短检查不能估计持续吞吐。

## 采样与摘要

`samples.csv` 先记录起始样本，之后每 10 秒一次，不在每迭代收集遥测。
EFZ 计数、语料大小和全局覆盖通过只读
`efz_fuzzer:benchmark_snapshot/0` / `efz_worker:handle_call/3` 一致读取。
精确 `coverage.term` 只在采样结束后创建一次。
列包括 elapsed、总及窗口 exec/s、语料、全局覆盖、发现、崩溃/超时/错误、进程数、
内存 total/processes/binary/ETS、Linux RSS、run queue、reductions、GC 次数、
映射 arms/allocations 及损坏覆盖观察。
`execution_maps_allocated` 只统计 worker 预分配映射，不是全部可能临时映射数。
`summary.term` 和 `summary.csv` 包含 total/mean、median、p10/p90 窗口 exec/s、
首末 60 秒、最终覆盖及语料、崩溃与超时、内存和进程数变化。
`total_executions` 包含校准，区间速率从 `efz:start/1` 后首个样本起算。

`cleanup.term` 在 `efz:stop/0` 后写入。
按注册名称检查 EFZ 进程不存在；保存停止后的绝对进程数及内存以供人工诊断。
bitmap-v2 提供 arms 计数及 worker 中一个预分配执行映射。
当前公开 API 不能观察退役映射数，因此不声称此指标。
全部内存结论需完整 15 分钟时间序列和重复运行。

## 长运行前检查

2026-10-02 在 OTP 27.0 完成：

- `rebar3 compile` — PASS；
- `rebar3 eunit` — 255 PASS，含 12 个 Cowboy 测试驱动案例；
- `rebar3 ct` — 3 PASS；
- `./scripts/run_cowboy_long_bench.sh --backend ets --duration 30 --seed 424242`
  — 3582 次执行、119.36 exec/s、最终覆盖点 266、语料输入 56、崩溃/超时/错误 0；
- 相同命令使用 `--backend bitmap` — 1992 次执行、66.36 exec/s、
  最终覆盖点 259、语料输入 49、崩溃/超时/错误 0。

30 秒原始结果本地保存在 `artifacts/cowboy-long-bench/20261002T190436Z-ets/`
和 `artifacts/cowboy-long-bench/20261002T190514Z-bitmap/`。
本配对平均 bitmap/ETS ≈0.556。Bitmap 仍为实验性可选模式，ETS 仍为默认。
这些数据不代替 ETS → bitmap → bitmap → ETS 顺序的四次 15 分钟运行：
30 秒不足以判断覆盖饱和、吞吐稳定性及内存增长。
