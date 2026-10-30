# SDK local de EFZ para Python

Esta es una guía breve. La [API completa y ejemplos](../../../../../packages/pyefz/README.md) están en inglés.

El SDK usa un proceso EFZ local y una ruta explícita al checkout. Los valores `bytes`, incluso NUL y UTF-8 inválido, se conservan mediante framing Base64. El cliente ofrece `start`, `stats`, `request_stop`, `await_result`, `mutate`, operaciones por lote, raw replay y `close`. Use el context manager o `finally` para cerrar el proceso hijo. `mutation_provider.transport = persistent` reutiliza el worker externo dentro de una sesión; `disposable` sigue siendo el valor compatible predeterminado.
