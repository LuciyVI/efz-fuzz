# P0 基线

[English](../../../gleam-layer/baseline.md) · [Русский](../../ru/gleam-layer/baseline.md) · [Español](../../es/gleam-layer/baseline.md) · **简体中文** · [所有语言](../../README.md)

HEAD 为 79d76221c6bc5df30b80e6b0de947f3860f4fa4b；初始已跟踪文件和暂存区差异为空。
用户需求目录和 zip 均已保留（哈希位于运行产物中）。
运行时：OTP 27.0、ERTS 15.0、Rebar3、+S 2:2、JIT x86_64 Linux。
rebar.lock 中固定的 Cowboy/Cowlib/Ranch 提交未改变。

原始 `rebar3 compile`：退出码 1（配置的代理不可达）。
限定范围内通过直接 HTTPS 获取依赖并编译：退出码 0。未改变全局配置。
原始 EUnit/CT 布局在运行测试之前失败，因为嵌套测试目标源码目录变成符号链接，
与 Rebar 复制 test/ 的操作冲突。该问题已在全新的
/tmp/efz-native-baseline-20261007 中复现。将相同测试驱动源码复制到其中不重叠的源码目录后：
EUnit 退出码 0，**260 项通过**；CT 退出码 0，**3 项通过**。
主工作副本通过把四个未经修改的测试驱动模块移动到 examples/cowboy/targets 和 examples/engine
实现此布局修复。原 _build/test 保留为 _build/test-before-gleam-layout。未删除语料。

实现前，efz_example_target 使用变异种子 {17,23,41}，经 EFZ 完成了 200 次真实 staged 执行。
baseline.term 和 p0-trace.log 记录了精确候选、发现与结果。
基线源码快照和运行器位于 /tmp/efz-native-baseline-20261007
（原始 HEAD 的 git archive；仅构建源码目录布局不同）。普通编译不需要 Gleam。

`efz_cov_native_public:preflight/1` 检查公开 OTP 覆盖能力及模式，不会静默回退后端。
OTP 27 原生存储以模块为范围（已安装 kernel-10.0/src/code.erl 的第 270-296 和 2309-2312 行）。
现有 EUnit 测试覆盖 ETS、ETS-member、bitmap 和 native 后端。
本 VM 支持原生行模式；它不能与 hit_count 或 manual 组合。
单活动、单 worker 以及 guardian 清理屏障将在线区间串行化。
同一 VM 内不受管理的并发目标调用不属于该契约。
Gleam 不引入后端、并行判定器或异步观察器。

P2 工具链澄清（2026-10-08）：主要 `erl` 经 asdf 解析到
`/home/fbogoslavskii/.asdf/installs/erlang/27.0`，ERTS 15.0。
其已验证源码为该根目录下的 `lib/kernel-10.0/src/code.erl`。
`/usr/bin/erl` 独立选择系统 OTP 27.3.4.13 / ERTS 15.2.7.9。
P2 记录两者，并使用与开启构建相同的主要 OTP 27.0 重复全新关闭构建与测试
（P2 运行中的 `toolchain-paths.json`）。
