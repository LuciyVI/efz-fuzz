# P0 baseline

[English](../../../gleam-layer/baseline.md) · **Русский** · [Español](../../es/gleam-layer/baseline.md) · [简体中文](../../zh-CN/gleam-layer/baseline.md) · [Все языки](../../README.md)

HEAD 79d76221c6bc5df30b80e6b0de947f3860f4fa4b; исходные tracked/index diffs пусты.
Каталог и zip с требованиями пользователя сохранены (hashes в artifacts запуска).
Runtime: OTP 27.0, ERTS 15.0, Rebar3, +S 2:2, JIT x86_64 Linux.
Pinned commits Cowboy/Cowlib/Ranch в rebar.lock не изменены.

Исходный `rebar3 compile`: exit 1 (недоступный настроенный proxy).
Ограниченное прямое получение зависимостей по HTTPS + compile: exit 0.
Глобальная конфигурация не менялась.
Исходный layout EUnit/CT: ошибка до тестов, поскольку вложенные source dirs
test targets становятся symlinks, конфликтующими с копированием test/ в Rebar.
Воспроизведено в новом /tmp/efz-native-baseline-20261007. Идентичные harness
sources скопированы там в непересекающийся source dir: EUnit exit 0,
**260 passed**; CT exit 0, **3 passed**. Main checkout исправляет layout переносом
четырёх неизменённых harness modules в examples/cowboy/targets и examples/engine.
Исходный _build/test сохранён как _build/test-before-gleam-layout.
Ни один корпус не удалён.

До реализации через EFZ завершились 200 настоящих staged executions
efz_example_target с mutation seed {17,23,41}. baseline.term и p0-trace.log
фиксируют точные candidates, findings и outcomes. Baseline source snapshot
и runner: /tmp/efz-native-baseline-20261007 (git archive исходного HEAD;
отличается только layout source-dir сборки). Обычный compile не требует Gleam.

`efz_cov_native_public:preflight/1` проверяет публичную OTP coverage capability
и mode без тихого backend fallback. Native storage OTP 27 имеет module scope
(установленный kernel-10.0/src/code.erl, строки 270-296 и 2309-2312).
Существующие EUnit tests покрывают ETS, ETS-member, bitmap и native backends.
Native line mode поддерживается в этой VM; его нельзя сочетать с hit_count или
manual. Одна кампания/один worker и guardian cleanup barrier сериализуют online
intervals. Одновременные unmanaged target calls в этой VM вне данного контракта.
Gleam не добавляет backend, parallel oracle или async observer.

Уточнение P2 toolchain (2026-10-08): основной `erl` разрешается через asdf в
`/home/fbogoslavskii/.asdf/installs/erlang/27.0`, ERTS 15.0. Его проверенный source —
`lib/kernel-10.0/src/code.erl` под этим root. `/usr/bin/erl` независимо выбирает
системный OTP 27.3.4.13 / ERTS 15.2.7.9. P2 фиксирует оба и повторяет clean
off-build/tests на том же основном OTP 27.0, который использовался для on-build
(`toolchain-paths.json` в P2 run).
