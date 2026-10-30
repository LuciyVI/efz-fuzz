# DWARF/原生覆盖率：可行性检查点

[English](../../dwarf-native-coverage.md) · [Русский](../ru/dwarf-native-coverage.md) · [Español](../es/dwarf-native-coverage.md) · **简体中文** · [所有语言](../README.md)

状态：**尚未实现 DWARF 直接后端**（2026-10-03）。安全的
`otp_native_public` 对比后端仅使用已记录的 OTP API；参见
[`dwarf-native-coverage-results.md`](dwarf-native-coverage-results.md)。
ETS 仍为默认后端，bitmap 仍需显式启用。本检查点
止步于读取 VM 内存之前，因为当前环境尚未提供一种经过验证的方法，
可在复制期间固定动态分配的覆盖率存储。下面的 DWARF 偏移量
只是对某个二进制文件的观察结果，并不构成可用的覆盖率读取器。

## EFZ 集成边界

`efz_config:valid_field/2` 接受 `ets`、`ets_member`、`bitmap` 和
`otp_native_public`。
`efz_coverage` 负责分派这些后端。`efz_guardian:run/6` 管理一次
迭代的覆盖率上下文；`efz_feedback` 决定新颖性和全局合并。
Cowboy 运行器（`scripts/cowboy_long_bench.escript`）通过
`efz_instrument:compile/2` 为 ETS/bitmap 编译四个 Cowboy
模块，并在其中插入 EFZ 结构探针。公开原生路径使用带有
`line_coverage` 的 `efz_cov_native_public:compile/2`，并在加载这些模块
之前选择 `line` 模式。
它表示可执行行，而非 EFZ 子句/结果，因此绝对覆盖率
计数不具有可比性。

## 已验证的运行时和布局

运行时：OTP 27、ERTS 15.0、x86-64 Linux。本次调查确认的
活动可执行文件是 Erlang/OTP 27.0 安装中的
`beam.smp`（ERTS 15.0）。
其 SHA256 为
`dcc7fac32e6f401be539022fce3e15a3f92461600208a41f1e7bfe3ef9e5d98f`；
其 ELF GNU build-id 为 `545a52682e29950d87511c488a8d0f31551f5ad2`。
该 ELF 包含 `.debug_info`，且未剥离符号。

GDB 的 DWARF 类型查询（`gdb -q -batch -ex 'ptype /o BeamCodeHeader'
<beam.smp>`）报告了一个 144 字节的 `BeamCodeHeader`，包含以下字段：

| 字段 | 字节偏移量 | DWARF 类型 |
| --- | ---: | --- |
| `coverage_mode` | 80 | `Uint` |
| `coverage` | 88 | `void *` |
| `line_coverage_valid` | 96 | `byte *` |
| `loc_index_to_cover_id` | 104 | `Uint32 *` |
| `line_coverage_len` | 112 | `Uint` |

在这个二进制文件中，`Module`（`struct erl_module`）的 `curr.code_hdr`
位于偏移量 32，`old.code_hdr` 位于偏移量 96。必须针对每个确切的
可执行文件重新发现这些值；绝不能将它们复制到另一构建的
运行时配置中。OTP 27.0 源码将 `coverage` 声明为 `void *`，因此
仅凭类型无法确定其分配方式、数组元素类型或生命周期：
[OTP 27.0 `beam_code.h`](https://github.com/erlang/otp/blob/OTP-27.0/erts/emulator/beam/beam_code.h)。
模块表源码明确区分了活动实例的无锁查找与
另行保护的旧实例/暂存实例：
[OTP 27.0 `module.c`](https://github.com/erlang/otp/blob/OTP-27.0/erts/emulator/beam/module.c)。

这里的 `code:coverage_support/0` 返回 `true`。使用
`[binary, line_coverage, debug_info]` 编译并在
`code:set_coverage_mode(line)` 之后加载的模块，在执行一次分支后，
通过 `code:get_coverage(line, Module)` 得到 `[{3,false},{4,true}]`；公开的
`code:reset_coverage(Module)` 将其清除为两个 `false` 条目。这仅验证了
公开 OTP 的行为。尚未执行或对比任何直接读取。

## 直接读取受阻的原因

DWARF 描述的是 `coverage` **指针字段**在一个已经定位的
`BeamCodeHeader` 内的位置；它既不标识已加载模块头部的堆地址，
也不维持该对象的存活。PIE/ASLR 还意味着 ELF 符号
地址并非进程地址。如果不遵循 ERTS 的代码索引/线程进度规则，
就通过 `Module.curr.code_hdr` 再读取 `coverage`，则可能
与重新加载/清除操作发生竞争，并解引用已释放的内存。在读取前
比较 build-id 和模块 MD5 并不能消除检查到使用之间的竞争。

纯 Erlang 通过 `code:get_coverage/2` 以 Erlang 项的形式公开覆盖率，
而不是固定的指针。独立端口无法调用 VM 的内部模块
查找，也不具备代码加载器同步机制；在此主机上，
`/proc/sys/kernel/yama/ptrace_scope` 为 `1`，因此子进程通常也无法通过
`/proc/<pid>/mem` 读取其父 BEAM。原则上，进程内 NIF 可以
调用私有 ERTS 例程，但正确的辅助组件需要
匹配的 OTP 源码/构建头文件，以及经过验证的活动代码索引生命周期
契约。这里不具备这些前提。猜测偏移量并调用
私有符号不能作为可接受的替代方案，即使只是为了基准测试也不行。

因此，不会将 `otp_native_direct` 添加到 `coverage_backend` 或
Cowboy 运行器中。不存在直接读取的正确性测试、冒烟测试、
微基准测试或 15 分钟命令。公开 API 的测量结果单独
记录；它们不能证明 DWARF 辅助组件能够提高端到端
模糊测试吞吐量。

## 安全继续研究的最小可复现设置

1. 获取与**这个确切 `beam.smp` 构建匹配的完整 OTP 27.0 源码**
   及其构建配置。在布局产物中保留可执行文件的 SHA256/build-id；
   如果正在运行的 `/proc/<beam-pid>/exe` 不匹配，则以拒绝运行的方式失败。
2. 使用实际的 ERTS 覆盖率和代码加载器定义，构建一个最小的、进程内、
   针对特定构建的**只读**辅助组件。它必须按照 ERTS 已记录的
   线程进度/代码索引规则获取活动模块实例，
   验证模式、模块身份和边界，复制一个有界的紧凑缓冲区，
   并在返回前解除固定。绝不在调用之间保留 ERTS 指针。
   如果无法从源码确定这些要求，则在一次性研究 OTP 构建中使用小型 ERTS 访问器
   补丁，而不是使用不安全的 NIF。
3. 在启动时从该可执行文件的 DWARF 中发现字段和大小。要求
   对应的 SHA256/build-id，并在缺少 DWARF 或不匹配时拒绝运行。
   从匹配的源码推导覆盖率数组的实际元素类型和索引方式；
   DWARF 中的 `void *` 并不足够。
4. 在模糊测试活动运行期间禁止目标重新加载或代码升级，或在发生时中止。
   证明重置和读取仅在子写入进程静止之后发生，包括
   超时和清理失败的情况。
5. 首先在一个小型 `line_coverage` 测试夹具上，将直接快照与
   `code:get_coverage(line, Module)` 进行比较，涵盖分支、重复执行、重置、
   重新加载和无效布局测试。之后才将原生模式集成到
   `efz_coverage`/`efz_guardian`，并保留 EFZ 反馈和语料库策略。
6. 让已实现的 OTP 公开模式继续保持为显式启用。任何后续直接辅助组件
   都应在提供 900 秒手动运行之前，使用相同行模式与它进行测量对比。
   保持 ETS 为默认后端，并将行覆盖率计数与 EFZ
   结构探针计数分开报告。

在一次性目录中复现公开 API 测试夹具：

```sh
cat >/tmp/efz_dwarf_fixture.erl <<'EOF'
-module(efz_dwarf_fixture).
-export([run/1]).
run(0) -> zero;
run(N) when N > 0 -> X = N + 1, {positive, X}.
EOF
erl -noshell -eval '{ok,M,B}=compile:file("/tmp/efz_dwarf_fixture.erl",[binary,line_coverage,debug_info]), code:set_coverage_mode(line), {module,M}=code:load_binary(M,"/tmp/efz_dwarf_fixture.erl",B), io:format("before=~p~n",[code:get_coverage(line,M)]), efz_dwarf_fixture:run(1), io:format("after=~p~n",[code:get_coverage(line,M)]), ok=code:reset_coverage(M), io:format("reset=~p~n",[code:get_coverage(line,M)]), halt().'
```

该命令是公开 OTP 基线，**并非** DWARF 读取器。
