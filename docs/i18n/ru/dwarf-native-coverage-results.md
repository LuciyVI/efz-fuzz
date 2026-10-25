# Результаты DWARF/native coverage

[English](../../dwarf-native-coverage-results.md) · **Русский** · [Español](../es/dwarf-native-coverage-results.md) · [简体中文](../zh-CN/dwarf-native-coverage-results.md) · [Все языки](../README.md)

Статус на 2026-10-03: **helper прямого чтения отложен**. См.
[`dwarf-native-coverage.md`](dwarf-native-coverage.md): наблюдавшийся layout OTP,
проблема времени жизни указателя и воспроизводимая подготовка для продолжения.

| Проверка | Результат |
| --- | --- |
| Публичный API native coverage OTP | PASS на небольшом line-coverage fixture и экспериментальном backend `otp_native_public` |
| Обнаружение типов/полей DWARF | PASS для исследованного binary OTP 27.0 |
| Безопасное прямое чтение покрытия | NOT RUN — нет доказанного контракта времени жизни code loader/helper |
| Прямое чтение против `code:get_coverage/2` | NOT RUN |
| OTP-public Cowboy smoke (30 s) | PASS после исправления формы metadata корпуса: 5889 executions, 196.26 exec/s, 0 infrastructure errors на итоговом коде; только один запуск итогового кода |
| DWARF-native Cowboy smoke (30 s) | NOT RUN — backend не реализован |
| Microbenchmark native reset/read/novelty/merge | PASS; см. `docs/performance/otp-native-public-2026-10-03.term` и `otp-native-public-cowboy-2026-10-03.term` |
| 15-минутные запуски Cowboy | NOT RUN; оставлены для ручного выполнения после smokes |

На фиксированном Cowboy GET path медианы компонентов составили: reset 0.50 µs,
`code:get_coverage` 5.63 µs, преобразование в компактный формат 30.77 µs,
сканирование без novelty 3.37 µs, merge 4.97 µs, полный цикл прямого вызова target
68.68 µs (10 samples по 100 итераций после двух warmups). Полный 30-секундный
запуск EFZ даёт в среднем около 5.1 ms на execution, поэтому пока не показано,
что `get_coverage` или преобразование доминируют в сквозном времени EFZ. Одни
эти измерения не обосновывают прямой helper. Показателей производительности
DWARF-native **нет**.
