# Локальный Python SDK EFZ

Это краткое руководство. [Полный API и примеры](../../../../../packages/pyefz/README.md) опубликованы на английском.

SDK использует локальный процесс EFZ и явный путь к checkout; данные `bytes`, включая NUL и невалидный UTF-8, передаются без потери через Base64 framing. Клиент поддерживает `start`, `stats`, `request_stop`, `await_result`, `mutate`, batch, raw replay и `close`. Используйте context manager или `finally`, чтобы закрыть дочерний процесс. `mutation_provider.transport = persistent` повторно использует внешний worker в одной сессии; `disposable` остаётся совместимым значением по умолчанию.
