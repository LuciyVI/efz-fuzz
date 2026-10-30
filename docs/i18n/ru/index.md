# Документация EFZ

[English](../../README.md) · **Русский** · [Español](../es/index.md) · [简体中文](../zh-CN/index.md) · [Все языки](../README.md)

Основной язык документации — английский. [Указатель языков](../README.md) содержит полные русскую, испанскую и упрощённую китайскую версии README, руководств, аудитов и отчётов. Обзор возможностей приведён в [README проекта](README.md).

## Начните здесь

- [Подготовка и запуск EFZ](quickstart.md)
- [Универсальный launcher фаззинга](cli.md)
- [Терминальная панель EFZ](tui.md)
- [Непрерывный фаззинг](continuous.md)
- [Генерация коннектора из Erlang spec](gleam-layer/connector-generation.md)
- [Подключение Erlang-библиотеки к Gleam Layer](gleam-layer/connecting-erlang-libraries.md)
- [Архитектура EFZ](architecture.md)
- [Карта репозитория EFZ: директории и файлы](repository-map.md)

## Полный справочник

Исторические отчёты сохраняют дату, проверенную среду, объём и ограничения исходной работы. Зафиксированный результат описывает конкретный запуск и не является утверждением о каждой последующей версии. Исходные логи, бинарные артефакты и идентификаторы кода сохранены как доказательства. Некоторые отчёты ссылаются на временные каталоги запусков или файлы результатов, отсутствующие в новой рабочей копии; исходные пути сохранены для прослеживаемости.

### Руководства по движку и эксплуатации

- [Архитектура EFZ](architecture.md)
- [Аудит готовности EFZ к калибровке и feature_stability](calibration-readiness.md)
- [Универсальный launcher фаззинга](cli.md)
- [Непрерывный фаззинг](continuous.md)
- [Повторно используемый долговечный корпус](corpus.md)
- [Bitmap backend для покрытия EFZ](coverage-bitmap-architecture.md)
- [Технический аудит bitmap coverage backend EFZ](coverage-bitmap-audit.md)
- [Bitmap coverage backend: отчёт о реализации](coverage-bitmap-implementation-report.md)
- [Bitmap coverage v2: реализация и измеренный результат](coverage-bitmap-v2-results.md)
- [Целостность automatic coverage](coverage-integrity.md)
- [Coverage tracking EFZ: аудит и сравнение с AFL++](coverage-tracking-audit.md)
- [Контракт автоматического покрытия](coverage.md)
- [Длительный Cowboy benchmark: ETS, bitmap-v2 и OTP-public](cowboy-long-benchmark.md)
- [Харнессы потоков данных Cowboy](cowboy-harness-suite.md)
- [Результаты DWARF/native coverage](dwarf-native-coverage-results.md)
- [DWARF/native coverage: контрольная точка осуществимости](dwarf-native-coverage.md)
- [EFZ: профиль производительности engine v2 (2026-10-04)](engine-performance-profile-v2.md)
- [EFZ: профиль стоимости одной итерации](engine-performance-profile.md)
- [Execution model: synchronous binary harness with controlled descendants](execution-isolation.md)
- [EFZ: экспериментальный hit-count feedback](hit-count-experiment.md)
- [Лимиты входов и ошибки хранения](input-and-storage.md)
- [Нативные staged mutations (engine version 1)](mutations.md)
- [Экспериментальное OTP-public line coverage (2026-10-03)](otp-native-public-results.md)
- [P1-01 Внешний supervisor](p1-01-external-supervisor.md)
- [Протокол валидации Phase 2](phase2-validation.md)
- [Производительность и протокол завершения Phase 2.1](phase2.1-performance.md)
- [Валидация Phase 3: staged mutation и точный replay](phase3-validation.md)
- [Подготовка и запуск EFZ](quickstart.md)
- [Crash occurrences, сигнатуры и проверенный replay](replay.md)
- [Карта репозитория EFZ: директории и файлы](repository-map.md)
- [Исправления приёмки P0 — 2026-09-21](runtime-diagnostics-acceptance-fixes.md)
- [P0 validation — 2026-09-16](runtime-diagnostics-validation.md)
- [Automatic Runtime Diagnostics (P0)](runtime-diagnostics.md)
- [Технический аудит EFZ — 12 сентября 2026](technical-audit-2026-09-12.md)
- [Терминальная панель EFZ](tui.md)

### Семантический слой / Gleam

- [Semantic adapter API 1](gleam-layer/adapter-contract.md)
- [Ответственность и порядок контрольных этапов](gleam-layer/agent-plan.md)
- [Нативная архитектура Gleam — контракт v1](gleam-layer/architecture.md)
- [P0 baseline](gleam-layer/baseline.md)
- [Подключение Erlang-библиотеки к Gleam Layer](gleam-layer/connecting-erlang-libraries.md)
- [Генерация коннектора из Erlang spec](gleam-layer/connector-generation.md)
- [Нативный контракт Erlang/Gleam v1](gleam-layer/contracts.md)
- [Решения](gleam-layer/decision-log.md)
- [Фактическая карта исходников](gleam-layer/execution-path.md)
- [P1: проверка контракта и передача работы](gleam-layer/p1-validation.md)
- [P2: необязательная нативная интеграция BEAM](gleam-layer/p2-integration.md)
- [P3: структурный provider — PASS](gleam-layer/p3-provider.md)
- [P4: oracle и feedback корпуса — PASS](gleam-layer/p4-feedback.md)
- [P5: финальная приёмка replay, регрессий и сравнений на одном движке](gleam-layer/p5-validation.md)
- [Gleam Layer: реализация и проверяемые результаты](gleam-layer/universal-validation.md)
- [> Этот документ описывает исторический интерфейс совместимости QS. Актуальное](gleam-layer/user-guide.md)

### Архитектурные решения

- [ADR 0002: source clause/outcome probes с ETS, принадлежащим execution](adr/0002-automatic-coverage.md)

### Планы реализации

- [План реализации bitmap coverage backend](plans/coverage-bitmap-implementation-plan.md)

[Исходники и изображения UML-диаграмм](diagrams/README.md) сопровождаются отдельно.
