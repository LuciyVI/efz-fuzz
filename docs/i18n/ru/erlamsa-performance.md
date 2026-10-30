# Постоянный внешний worker Erlamsa

Это краткое руководство. [Полная архитектура и пределы](../../erlamsa-performance.md) опубликованы на английском.

`transport = disposable` сохраняет старое поведение. Явный `transport = persistent` запускает одну внешнюю Erlang VM для последовательных запросов кампании; каждый запрос исполняется в новом процессе с собственным seed. VM проверяет identity при startup, а внешний watchdog может завершить её при timeout. `max_requests` позволяет перезапускать worker между запросами. Перезапуск, PID и задержки относятся к runtime evidence и не меняют recipe.

Не смешивайте эту VM с opt-in persistent VM тестируемой цели. [Измерения](../../erlamsa-performance-validation.md) относятся только к записанным сборкам и входам.
