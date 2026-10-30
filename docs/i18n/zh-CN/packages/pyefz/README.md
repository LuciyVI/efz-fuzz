# EFZ 本地 Python SDK

本页是简明指南。[完整 API 与示例](../../../../../packages/pyefz/README.md)以英语发布。

SDK 使用本地 EFZ 子进程和显式 checkout 路径。通过 Base64 framing 精确保留 `bytes`，包括 NUL 和无效 UTF-8。客户端提供 `start`、`stats`、`request_stop`、`await_result`、`mutate`、批量操作、raw replay 和 `close`。使用 context manager 或 `finally` 关闭子进程。`mutation_provider.transport = persistent` 在同一会话复用外部 worker；兼容的默认值仍是 `disposable`。
