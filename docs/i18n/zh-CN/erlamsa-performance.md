# Erlamsa 持久外部 worker

本页是简明指南。[完整架构和限制](../../erlamsa-performance.md)以英语发布。

`transport = disposable` 保留旧行为。显式选择 `transport = persistent` 后，一次活动使用一台外部 Erlang VM 顺序处理请求；每个请求在新的 Erlang 进程中使用独立 seed。启动时验证代码标识；外部 watchdog 可在超时后终止整台 VM。`max_requests` 可在请求之间回收 worker。回收次数、PID 和耗时属于运行证据，不改变 recipe。

该 VM 与可选的持久目标 VM 是不同子系统。[性能数据](../../erlamsa-performance-validation.md)仅适用于所记录的构建与输入。
