# P0 validation — 2026-09-16

## Checkout и environment

- Начальный commit: `205e18ba172d74bd6c652a68abfc73e02e4a1f86`.
- Ubuntu 24.04.4 LTS, x86_64, kernel `6.8.0-nyx+`.
- Erlang/OTP 27.0, ERTS 15.0, Rebar3 3.25.0.
- Для Rebar3/bench использовалось `ERL_FLAGS='+S 4:4'`; внешние опасные lifecycle
  fixtures — `erl +S 2:2` под `timeout 10s`.
- Применимых AGENTS.md в checkout и родительских каталогах не найдено.
- Checkout изначально содержал изменения coverage/hit-count, corpus, CLI и docs:
  [полный исходный status](runtime-validation/preexisting-status.txt).
  Исходный diff сохранён в `/tmp/efz-p0-baseline/preexisting.diff`.
  Reset/clean, обновления ветки, commit/push не выполнялись.
- Существующие harness/target files не редактировались. Новые targets только в
  `fixtures/runtime/`. 11 файлов с посторонними изменениями, не затронутых P0,
  побайтно совпали с сохранённым исходным состоянием.
- [Файлы, изменённые именно этой задачей](runtime-validation/changed-files.txt).

До реализации уже существовали guardian ownership, start gates, monitors, trace
barriers, execution-scoped coverage/integrity, dirty-runner retirement, crash groups,
raw/recipe replay и однократная calibration. Повторной verification, sampler,
runtime store/replay не было. Существующий feedback loop проверен по реальному
checkout; новые повторы не вызывают feedback/retention/planner.

## Команды и результаты

Каждая команда выполнялась из корня checkout:

```sh
ERL_FLAGS='+S 4:4' rebar3 compile
ERL_FLAGS='+S 4:4' rebar3 eunit
ERL_FLAGS='+S 4:4' rebar3 ct
ERL_FLAGS='+S 4:4' rebar3 dialyzer
ERL_FLAGS='+S 4:4' rebar3 xref
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_runtime_tests
```

| Проверка | Исходный checkout | После реализации |
|---|---:|---:|
| compile | PASS | PASS |
| EUnit | 199 passed | 214 passed |
| Common Test | 3 passed | 3 passed |
| Dialyzer | PASS, без warnings | PASS, без warnings |
| xref | PASS | PASS |
| Новые P0 EUnit cases | — | 15 passed, включая несколько сценариев внутри cases |

Полные логи: [baseline EUnit](runtime-validation/baseline-eunit.log),
[финальный EUnit](runtime-validation/eunit.log), [CT](runtime-validation/ct.log),
[compile](runtime-validation/compile.log), [Dialyzer](runtime-validation/dialyzer.log),
[xref](runtime-validation/xref.log). Baseline compile/ct/dialyzer/xref также сохранены
в этой директории. Первоначальный regression обнаружил изменение CLI сообщения
«could not be loaded»; сообщение исправлено, финальный suite прошёл.

Проверены:

| Область | Реальная проверка |
|---|---|
| Stability | Normalized outcome/coverage frequencies, stable/variable probes, valid empty, invalid snapshot exclusion, insufficient samples |
| Return | Fresh references стабильны при default; explicit comparator возвращает not_comparable; bounded large term rejection и scalar unstable_return |
| Executor | Настоящий instrumented target и unchanged binary harness API |
| Verification crash | Первый run успешен, второй детерминированно падает; origin=verification, один crash occurrence; global coverage равен исходному run |
| Mutation state | Полная последовательность random mutation bytes и staged recipes/counters совпадает off/on |
| Resources | Временная память; 100 mailbox messages; 1000 ограниченных ETS rows; peak остаётся после cleanup |
| Ownership | 4 controlled children + root; cap 2 даёт known=5, observed=2, partial=true; инфраструктура исключена |
| Child lifecycle | Abnormal child не меняет успешный root; обычный cleanup child не создаёт abnormal finding |
| Timeout | Настоящие busy/waiting targets; age/evidence; ring с max_samples=2 сохраняет последние наблюдения |
| Missing data | Мёртвый PID, исчезнувшая ETS, отсутствующие samples, sampler failure |
| Stalled sampler | Sampler принудительно suspended в отдельной VM; timeout=150 ms, confirmed cleanup, общая длительность <1000 ms |
| Infrastructure | Dirty до verification: 0 repeats; dirty на первом повторе: дальнейший пропущен; guardian failure сохраняет dirty-runner |
| Limits | Invalid nested keys/types/ranges; sample slot cap; requested=16 при extra budget=1 даёт completed=2, skipped=14 |
| Storage | Representatives/groups/payload caps, suppressed/dropped counters, stale index, corruption, interrupted directory, write-to-file path failure |
| Replay | Runtime round-trip, one-run unstable inconclusive, harness mismatch, build mismatch, fresh CLI VM; legacy artifacts в прежнем suite |
| Regression | Все прежние manual/automatic coverage, random/staged, exact recipes, durable corpus, feedback и isolation tests |

Источник чередующихся ответов в `vary` fixture — **test-only synchronized process**,
а не случайный scheduler. Он не означает поддержку external interactions в production
harness. Dirty/guardian/stalled-sampler fixtures изолированы OS-process watchdog;
нет atom bombs, неограниченных memory/process allocations. Тесты не симулируют
реальное отключение питания или исчерпание диска; interrupted/corrupt storage
проверены созданием неполного/повреждённого состояния.

## Реальный CLI round-trip

Подготовка ограниченного artificial timeout fixture:

```sh
rebar3 compile
mkdir -p _build/runtime-demo-final/harness _build/runtime-demo-final/seeds
ERL_FLAGS='+S 4:4' erlc +debug_info -o _build/runtime-demo-final/harness \
  fixtures/runtime/efz_runtime_harness.erl
ERL_FLAGS='+S 4:4' erl -noshell -pa _build/default/lib/efz/ebin -eval '
  {ok,_}=efz_instrument:compile("fixtures/runtime/efz_runtime_sites.erl",
    #{modules=>[efz_runtime_sites],source_root=>".",outdir=>"_build/runtime-demo-final/targets"}),
  ok=file:write_file("_build/runtime-demo-final/seeds/waiting",<<"waiting">>),halt().'

ERL_FLAGS='+S 4:4' escript scripts/fuzz.escript \
  --target efz_runtime_harness --code-path _build/runtime-demo-final/harness \
  --artifacts _build/runtime-demo-final/targets --seeds _build/runtime-demo-final/seeds \
  --out _build/runtime-demo-final/out --max-iterations 0 --timeout 100 \
  --runtime-diagnostics --runtime-runs 3 --verification-budget 10 --sample-interval 5

EFZ_RUNTIME_FINDING=$(dirname "$(rg --files _build/runtime-demo-final/out/runtime-findings | rg '/artifact.input$' | head -n 1)")
ERL_FLAGS='+S 4:4' escript scripts/replay.escript \
  --runtime-finding "$EFZ_RUNTIME_FINDING" --target efz_runtime_harness \
  --code-path _build/runtime-demo-final/harness --artifacts _build/runtime-demo-final/targets --runs 3
```

Получено: campaign `completed`, 1 calibration + 2 verification executions,
3 timeout occurrences (это три настоящих execution failures), один crash group.
Runtime replay в другой VM: **observed timeout_waiting, 3/3**, compatibility verified.
Логи: [campaign](runtime-validation/cli-fuzz.log), [replay](runtime-validation/cli-replay.log).
Используйте новую `--out`, если локально меняете fixture/build; старый store не мигрируется.

Также проверен **существующий, неизменённый** `efz_example_target`:

```sh
mkdir -p _build/runtime-existing/seeds
ERL_FLAGS='+S 4:4' erl -noshell -pa _build/default/lib/efz/ebin -eval '
  {ok,_}=efz_instrument:compile("examples/simple_parser/efz_example_parser.erl",
    #{modules=>[efz_example_parser],source_root=>".",outdir=>"_build/runtime-existing/targets"}),
  ok=file:write_file("_build/runtime-existing/seeds/seed",<<0>>),halt().'
ERL_FLAGS='+S 4:4' escript scripts/fuzz.escript \
  --target efz_example_target --artifacts _build/runtime-existing/targets \
  --seeds _build/runtime-existing/seeds --out _build/runtime-existing/out \
  --mutation random --max-iterations 10 --timeout 100 \
  --runtime-diagnostics --runtime-runs 3 --verification-budget 20 --sample-interval 20
```

Получено `completed`, 10 mutation executions, 6 verification executions,
0 infrastructure failures. Это короткая smoke campaign, не длительный fuzzing audit;
число discoveries/repeats может отличаться без фиксированного RNG seed в CLI.
[Фактический лог](runtime-validation/existing-harness.log).

## Benchmark — фактические измерения

Driver: `bench/efz_runtime_bench.erl`, launcher `scripts/runtime_bench.escript`.
Один worker, prepared automatic coverage, presence feedback, неизменный instrumented
fixture и binary harness. На каждый mode: отдельная VM с `+S 4:4`, warmup 100 mutations,
пять кампаний по 1000 random mutations + 1 seed, фиксированные mutation/selection seeds.
Stability/full дают по 4 дополнительных исполнения (seed и discovery); это измерено,
а не предполагается. После fast campaigns отдельно исполняется `mailbox_ets` (~160 ms).

Baseline построен отдельно в `/tmp/efz-p0-baseline/checkout` из `git archive HEAD`,
исходного сохранённого diff и исходного untracked `src/efz_cov_count.erl`. Таким образом,
сравнение учитывает прежние изменения пользователя, а не только чистый HEAD. Основные
режимы измерялись последовательно, без параллельного запуска test suite/другого benchmark.
Хост не выделенный; CPU frequency/load не фиксировались.

```sh
# Каждый mode: warmup + пять runs. Обычная сборка EFZ должна быть готова.
ERL_FLAGS='+S 4:4' escript scripts/runtime_bench.escript baseline /tmp/efz-p0-bench/release/baseline /tmp/efz-p0-baseline/checkout/_build/default/lib/efz/ebin
ERL_FLAGS='+S 4:4' escript scripts/runtime_bench.escript off /tmp/efz-p0-bench/release/off
ERL_FLAGS='+S 4:4' escript scripts/runtime_bench.escript stability /tmp/efz-p0-bench/release/stability
ERL_FLAGS='+S 4:4' escript scripts/runtime_bench.escript resources /tmp/efz-p0-bench/release/resources
ERL_FLAGS='+S 4:4' escript scripts/runtime_bench.escript full /tmp/efz-p0-bench/release/full
ERL_FLAGS='+S 4:4' escript scripts/runtime_bench_report.escript /tmp/efz-p0-bench/release summary.csv
```

| Mode | Median mutation exec/s | Min–max | Mutations / verification | Median-run wall, ms | Post-execution diagnostics, ms | Verification elapsed, ms |
|---|---:|---:|---:|---:|---:|---:|
| baseline | 279.5 | 236.1–372.7 | 1000 / 0 | 3577.3 | 0.00 | 0.00 |
| off | 217.6 | 182.7–227.4 | 1000 / 0 | 4596.3 | 0.00 | 0.00 |
| stability | 219.6 | 212.1–224.0 | 1000 / 4 | 4553.4 | 52.37 | 4.35 |
| resources | 205.4 | 179.1–225.5 | 1000 / 0 | 4868.1 | 38.26 | 0.00 |
| full | 194.9 | 176.8–216.9 | 1000 / 4 | 5131.5 | 52.60 | 3.97 |

`runtime_diagnostic_us` — wall time worker после исходного executor: comparisons,
summary/storage и verification **включены**. `verification_elapsed_us` нельзя ещё раз
прибавлять к этой величине. Sampler work time — другая метрика в отдельном процессе.
Данные строки соответствуют run с median throughput, а не независимо выбранным
медианам разных counters.

На быстрых campaigns не было ни одного runtime sample: resources=0/1001 sampled/missed,
full=0/1005; stability отключает sampler. Нули при baseline/off означают отключение
измерений, а не отсутствие потребления. Следовательно, fast-loop slowdown **не является
измерением стоимости одного выполнявшегося sampling hook**.

| Long input mode | Wall, ms | Samples | Sampler work, ms | ETS diagnostic buffer при finish, bytes |
|---|---:|---:|---:|---:|
| baseline | 166.52 | 0 | 0.000 | 0 |
| off | 164.70 | 0 | 0.000 | 0 |
| stability | 166.50 | 0 | 0.000 | 2648 |
| resources | 167.44 | 7 | 1.004 | 7008 |
| full | 166.11 | 7 | 0.534 | 7008 |

Максимальный завершённый ETS buffer в fast campaigns был 2648 bytes при включённом
P0. Это **не полная память diagnostics**: heap sampler, guardian и сохранённые report
maps сюда не входят. Resident slots, children, report bytes и disk metadata ограничены
отдельными caps. Произвольные targets с высокой стоимостью process_info/ETS требуют
отдельного профилирования.

[CSV summary](runtime-validation/bench/summary.csv) и raw `.term`/логи всех пяти
режимов сохранены в `docs/runtime-validation/bench/`. По raw files можно пересчитать
summary тем же report script.

### Проверка неожиданного результата P0=off

Основной последовательный batch показал off **−22.2%** по median wall throughput.
Такой результат нельзя объявить отсутствием регрессии. Выполнен дополнительный
контроль в обратном порядке (сначала off, затем baseline), на том же driver/fixture,
с тем же warmup и пятью кампаниями; дополнительно `/usr/bin/time` измерял CPU всего
escript process, включая compilation/warmup/long fixture, поэтому эти CPU seconds
**не являются CPU одной mutation**:

```sh
/usr/bin/time -f 'wall_s=%e user_s=%U system_s=%S' \
  env ERL_FLAGS='+S 4:4' escript scripts/runtime_bench.escript off /tmp/efz-p0-bench/reverse/off
/usr/bin/time -f 'wall_s=%e user_s=%U system_s=%S' \
  env ERL_FLAGS='+S 4:4' escript scripts/runtime_bench.escript baseline /tmp/efz-p0-bench/reverse/baseline \
  /tmp/efz-p0-baseline/checkout/_build/default/lib/efz/ebin
```

| Reverse-order control | Median mutation exec/s | Min–max | Whole process wall, s | User CPU, s | System CPU, s |
|---|---:|---:|---:|---:|---:|
| off | 253.0 | 248.0–258.6 | 20.78 | 57.28 | 4.30 |
| baseline | 251.6 | 223.5–259.1 | 21.59 | 59.80 | 4.66 |

Здесь off **+0.54%** относительно baseline и не показывает роста CPU time.
Больше CPU seconds, чем wall seconds, нормально для VM с несколькими scheduler threads.
Оба противоположных результата сохранены: `bench/reverse/{off,baseline}/` содержит
raw `.term`, stdout и time logs. Это свидетельствует о чувствительности измерения
к условиям/порядку, но не устанавливает конкретную внешнюю причину. Доказательства
статистически значимого отсутствия регрессии на выделенном хосте нет.

## Итог и незакрытые границы

- **PASS функциональных проверок в этом окружении:** production executor/guardian path,
  repeated calibration, ресурсы/children/timeouts, отдельные findings/report/replay,
  limits и перечисленные regressions; 214 EUnit + 3 CT, compile/Dialyzer/xref.
- **PARTIAL performance acceptance:** все пять режимов реально измерены; off не имеет
  устойчивого ухудшения в reverse control, но значимый разброс не позволяет дать
  общий PASS критерию отсутствия существенной регрессии. Нужен отдельный контроль
  на выделенном стабилизированном хосте перед таким заявлением.
- Samples не гарантируют обнаружение быстрых peaks. ETS enumeration частичный при cap;
  memory метрика не включает полный off-heap footprint. Heap самого sampler/report
  не измерялся как отдельный peak: приведены реальные ETS buffer bytes и ограничения.
- Инициатор child exit обычно `unknown`: DOWN не доказывает, кто послал exit signal.
  Для cleanup сохраняется собственный kill_requested, а неоднозначная гонка не
  превращается в утверждение о точной причине или process leak.
- Resource growth внутри run — диагностическое подозрение. Нет доказательства
  произвольной утечки, memory safety, semantic correctness, race/deadlock/livelock,
  native failures или внешних side effects. Stateful reproducer может требовать
  истории inputs/свежей VM. Эти расширения намеренно не реализованы.
- Полный power-loss/ENOSPC fault injection, другие OTP/OS и длительные производственные
  кампании **NOT RUN**. Команд, заблокированных отсутствием зависимости/прав, в
  перечисленных итоговых compile/test/benchmark проверках нет.

Это отчёт о реально выполненных локальных проверках, не заявление production-ready
и не общий полный PASS всех эксплуатационных свойств.
