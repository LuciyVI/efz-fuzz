# 实验性 OTP-public 行覆盖率（2026-10-03）

[English](../../otp-native-public-results.md) · [Русский](../ru/otp-native-public-results.md) · [Español](../es/otp-native-public-results.md) · **简体中文** · [所有语言](../README.md)

## 已实现

需主动启用的 coverage_backend => otp_native_public 使用有文档说明的 OTP 27 原生
行覆盖率。efz_cov_native_public:compile/2 使用
line_coverage 编译目标模块。preflight/1 在加载前选择 code:set_coverage_mode(line)，并
记录各模块的 SHA256、BEAM MD5 和有序的可执行行列表。
prepare/1 为 {Module, BuildId, Line} 固定分配每行一个槽位，并为
模式生成指纹。整数形式的行标识符合现有语料库元数据格式。

在准许目标运行前，efz_guardian:start/6 调用 efz_coverage:open/3，后者
重置原生覆盖率。确认清理完成后，efz_guardian:finish/2 通过
code:get_coverage(line, Module) 读取覆盖率，并立即按照预先准备的行顺序，将项列表
打包为位集。efz_feedback:native_success/5
检查新颖性，并且仅对成功结果执行合并。崩溃、超时和
基础设施结果不会更新全局覆盖率。语料库接纳
仍然通过 efz_worker:retain/2 进行。测试驱动和变异代码不包含任何
原生覆盖率调用。

行覆盖率并不是 EFZ 结构点覆盖率。持久化覆盖率不会
在不同后端或变更后的构建之间导入。此实验性后端要求
使用专用虚拟机，其中选定目标模块没有无关调用者：OTP
覆盖率存储属于各个已加载模块，而非某次 EFZ 执行。
guardian 会在读取前确认其控制的后代进程均已退出，
但无法隔离同一虚拟机中任意无关的调用者。不兼容的
模块 MD5 或行列表会产生明确的覆盖率失败。ETS 是默认后端。

## 正确性

专用 EUnit 测试夹具已通过。它检查空状态/重置状态、行 A、
重复的 A、新行 B、原始 code:get_coverage/2 的已到达行
与紧凑位集完全一致、新颖性与合并、崩溃/超时不提交
策略，以及模块变更并重新加载后的模式拒绝。
它还使用成功、崩溃和
超时输入运行真实的 guardian/executor 路径，然后检查仅成功结果会改变全局
反馈状态。
最终代码的完整验证：rebar3 compile 通过；rebar3 eunit 256 项通过；
rebar3 ct 3 项通过；rebar3 xref 通过；rebar3 dialyzer 通过。Dialyzer PLT
包含 Cowboy；确定性的内存传输具有一个范围很窄的
注解，因为 Cowboy 的套接字类型并未描述其引用令牌。
OTP 27.0 的 code.erl 模式类型使用名称 line_coverage，而其文档和
运行时使用 line；启动时通过 apply/3 调用文档所述模式，以避免
误报的契约警告。覆盖率读取均未使用未公开的 API。

最初的一次 Cowboy 冒烟测试暴露了 corpus_persistence invalid_probe：原生
标识曾使用 {line,N} 作为第三个成员。现有语料库格式
要求正整数。现在它是 {Module,BuildId,Line}；修正后的
4 秒运行完成了 707 次执行，基础设施错误为零。
没有为掩盖此失败而修改任何测试预期。

## 短时端到端 Cowboy 运行

每种模式均在新的虚拟机中运行一次，持续 30 秒，使用 Cowboy 2.19.0、相同的
四个选定模块、12 个种子和随机种子 424242。这些是探索性的
单次运行，并非性能门槛。

| 后端 | 执行次数 | 平均 exec/s | 窗口 exec/s 中位数 | 发现数 | 最终语料库大小 | 错误数 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| ETS | 3911 | 130.33 | 131.49 | 45 | 57 | 0 |
| bitmap-v2 | 1997 | 66.53 | 65.99 | 37 | 49 | 0 |
| OTP-public | 5889 | 196.26 | 196.58 | 35 | 47 | 0 |

所有模式均报告零崩溃和零超时。ETS/bitmap 使用 887 个 EFZ
结构探针；原生后端使用 1089 个可执行行槽位。因此，最终覆盖率
计数的单位不同。语料库和变异历史会产生差异，
因为各次运行完成的迭代次数不同。原始目录：
 /tmp/efz-ets-smoke-30-compare
 /tmp/efz-bitmap-smoke-30-compare
 /tmp/efz-native-public-final2-smoke-30

## 组件测量

合成测试夹具在独立的
源代码行上生成了 1、100 和 1000 次执行调用。先进行两次预热采样，再进行十次计时采样；1 行和 100 行的情况每个样本
100 次迭代，1000 行的情况为 20 次。数值为每次迭代的
微秒数中位数，环境为 OTP 27.0 / ERTS 15.0、x86-64、16 个调度器。
原始数据：docs/performance/otp-native-public-2026-10-03.term。

| 请求行数 | 重置 | get_coverage | 转换 | 无新颖性 | 合并 | 完整的直接目标循环 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 0.046 | 0.050 | 0.147 | 0.047 | 0.104 | 0.476 |
| 100 | 0.034 | 0.167 | 1.271 | 0.166 | 0.232 | 2.363 |
| 1000 | 0.060 | 2.670 | 13.535 | 1.291 | 1.795 | 24.637 |

编译器会为 run/0 额外生成一行可执行代码，因此实际到达的
行数为 2、101 和 1001。此组件基准测试不包含 guardian、
模式检查、变异和语料库 IO。配套的 ETS/bitmap-v2 循环
基准测试已重新运行，原始输出位于
docs/performance/bitmap-v2-cycle-2026-10-03.term。它的工作负载和
插桩方式不同，因此其微秒数值不能用于与原生后端进行对等
比较。

固定的真实 Cowboy GET 路径采用两次预热采样和十个样本，每个样本 100
次迭代。中位数为：重置 0.50 us、公共读取 5.63 us、转换 30.77 us、
无新颖性扫描 3.37 us、合并 4.97 us、直接目标执行 15.08 us、
完整本地循环 68.68 us。原始数据：
docs/performance/otp-native-public-cowboy-2026-10-03.term。转换占
此本地循环的很大一部分；单独的 get_coverage 则并非如此。完整 EFZ 运行的
平均每次执行时间约为 5.1 ms。这些结果并未表明公共 API 的
数据物化是完整模糊测试活动的主要瓶颈。测量没有
单独分离 guardian、变异或语料库中的每项开销。安全的直接读取器
仍是一项需要单独通过门槛检查的研究。未实现任何指针读取、NIF 或 DWARF 直接后端。

## 复现

从 efz/ 运行：

    rebar3 compile
    rebar3 eunit --module=efz_native_public_tests
    escript bench/otp_native_public_components.escript docs/performance/otp-native-public-repeat.term
    escript bench/otp_native_public_cowboy_profile.escript docs/performance/otp-native-public-cowboy-repeat.term
    ./scripts/run_cowboy_long_bench.sh --backend otp_native_public --duration 30 --seed 424242

900 秒运行留待正确性门槛通过后手动执行。
