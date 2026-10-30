# Cowboy：EFZ 的小型目标

[English](../../../../../examples/cowboy/README.md) · [Русский](../../../ru/examples/cowboy/README.md) · [Español](../../../es/examples/cowboy/README.md) · **简体中文** · [所有语言](../../../README.md)

新的十一目标测试集以关闭 Gleam、仅观察和语义引导三种模式检查数据流。请参阅 [Cowboy 数据流测试工具](../../cowboy-harness-suite.md)：依赖版本固定在本仓库中，每次运行都会记录库代码覆盖率。

`efz_cowboy_target:run/1` 接受**不含开头 `?` 的查询字符串字节**，例如
`<<"q=hello+world&edit">>`，并调用 `cowboy_req:parse_qs/1`。结果为
`{ok, Pairs}`，或在 Cowboy 预期拒绝时为 `{invalid, qs | limit_reached}`。
包装器不捕获意外异常。Cowboy 本身将解析器异常转换为 `request_error`，
因此该测试包装器测试的是公共 API 及其错误语义，而不保留每一种内部原因。

执行在目标进程内同步进行。它使用仅包含 `qs` 字段的最小 Req；不启动监听器、
连接或 Cowboy 应用。范围仅为 Cowboy/Cowlib 的查询字符串解码。HTTP 消息分帧、
头部、套接字、路由、处理器和子进程均不在此范围内。

## 运行

从 **efz/** 根目录运行，并准备好相邻目录中已构建的 Cowboy 检出副本：

```sh
rebar3 compile
make -C ../cowboy
escript examples/cowboy/run.escript ../cowboy check
escript examples/cowboy/run.escript ../cowboy 500
```

当前工作区路径包含 `:`。Cowboy 的 `erlang.mk` 无法在这样的路径中构建
（`target pattern contains no '%'`）。已验证的替代方法是在 `/tmp` 中创建单独副本，
保留原始检出副本：

```sh
COWBOY_BUILD=$(mktemp -d /tmp/efz-cowboy.XXXXXX)
cp -a ../cowboy "$COWBOY_BUILD/cowboy"
make -C "$COWBOY_BUILD/cowboy"
rebar3 compile
escript examples/cowboy/run.escript "$COWBOY_BUILD/cowboy" check
escript examples/cowboy/run.escript "$COWBOY_BUILD/cowboy" 500
```

`make` 下载 Cowboy Makefile 中固定版本的依赖。此环境中的代理不可用时，
通过直接访问完成的构建已得到验证：

```sh
env -u HTTPS_PROXY -u HTTP_PROXY -u ALL_PROXY \
    -u https_proxy -u http_proxy -u all_proxy make -C "$COWBOY_BUILD/cowboy"
```

对于单独的 Cowboy HTTP/1 长时间基准测试，Cowboy 2.19.0 现在已固定在
`rebar.config` 和 `rebar.lock` 中；运行器说明位于
[`docs/cowboy-long-benchmark.md`](../../cowboy-long-benchmark.md)。
这个较早的查询字符串示例继续使用相邻的 Cowboy 检出副本，并在新的 VM 中运行。

运行器自动将允许列表 `[cowboy_req, cow_qs]` 插桩到 `_build/cowboy-targets`，
验证 BEAM/清单并运行标准执行器。普通 Cowboy 产物被保留。对于 `cow_qs`，
传入 Cowlib 的 include 目录。对于 `cowboy_req`，显式使用 `strict => false`：
在已验证的版本中，两个列表推导式（`filter_cookies/2`、`kvlist_to_map/2`）
保留原样，不插入内部探针。它们不在 `parse_qs/1` 路径上；限制会在构建时打印并记录在清单中。
这里不声称覆盖整个 Cowboy 的全部代码。

示例使用 staged 模式、种子 `{17,23,41}`、初始语料库 `[<<>>]`、
`dictionary_insert`、`bitflip`、`havoc` 阶段，以及 1024 字节的输入限制。
执行次数参数接受 1–100000，默认 500。保留 EFZ 覆盖率的默认设置：prepared 验证 + ETS。
预期的解析拒绝算作正常目标完成，因此其新探针可以扩充语料库。
报告：`_build/cowboy-report.term`；意外崩溃：`_build/cowboy-crashes/`。

## 本地验证

已验证环境：OTP 27.0、Rebar3 3.25.0、Cowboy 2.19.0
（`79e3fb02b31d47af6e69e8f3ba18fba291a3072a`）、Cowlib 2.20.0
（`c768a804565ff5b8178ed968a5921e469d6bd7b2`）。`check` 运行 14 项 EUnit 检查：
空输入、重复键、百分号解码、零字节/非 UTF-8 字节、格式错误的转义、99/100/101 键边界、
ETS/ets_member 快照的精确匹配、新的执行引用，以及在带有自动覆盖率的真实字典变异后保留
`a=1`。这些额外检查通过 `check` 命令执行，与普通 `rebar3 eunit` 分开，且需要真实的 Cowboy。

一次本地运行完成了 500 次变异执行，结果为：1 次种子执行、20 项发现、480 次拒绝，
0 次崩溃/超时/基础设施故障。这是对指定构建的观察，不是对其他版本的固定预期。
基线 `rebar3 compile` 和 `rebar3 eunit` 均通过：62 项 EFZ 测试。
