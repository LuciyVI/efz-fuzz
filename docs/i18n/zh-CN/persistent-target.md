# 持久目标 VM

本页是简明指南。[完整生命周期、序列日志与重放说明](../../persistent-target.md)以英语发布。

显式设置 `execution.mode = persistent_vm` 和 `state_policy = accumulate`。同一 epoch 中保留目标 VM、driver PID、process dictionary、mailbox 及目标拥有的 OTP/ETS 资源。每个输入开启独立覆盖窗口，不能用累计 union 相减计算。崩溃、超时或完整性丢失会结束 epoch；重新启动属于新的 epoch。

序列日志在投递目标前记录精确字节和顺序。Sequence replay 从 `init` 经完整 prefix 重新执行；单输入 raw replay 不恢复历史。独立重复在新 epoch 中顺序执行，不改变 primary 路径。没有 barrier 的任意后台活动不能保证完整覆盖窗口。
