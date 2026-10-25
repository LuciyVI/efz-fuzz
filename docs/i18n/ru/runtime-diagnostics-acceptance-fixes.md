# Исправления приёмки P0 — 2026-09-21

[English](../../runtime-diagnostics-acceptance-fixes.md) · **Русский** · [Español](../es/runtime-diagnostics-acceptance-fixes.md) · [简体中文](../zh-CN/runtime-diagnostics-acceptance-fixes.md) · [Все языки](../README.md)

## Вердикт: ACCEPT

P0-01, P0-02, P0-03, P0-04: PASS. Canonical compile, EUnit дважды, CT,
Dialyzer и xref: exit 0. Существующие harness files и ownership model неизменны.
Нет P1/P2 features, commits, reset/clean/pull или удаления preexisting changes.
HEAD остаётся `205e18ba172d74bd6c652a68abfc73e02e4a1f86`.
Среда: OTP 27.0 / ERTS 15.0 / rebar3 3.25.0, `ERL_FLAGS='+S 4:4'`.

## Исправления и первопричины

### P0-02: проверять до дорогой работы

`efz_stability:bounded_return/1` прежде сортировал произвольные map keys до
проверки budget. Теперь он проверяет через unordered iterator, поэлементный tuple
access и budget-aware list recursion. Независимые limits: 1024 visited nodes,
1024 binary bytes, 1024 container elements, depth 64. Container sizes и binary
byte_size проверяются до traversal/content access. Нет непроверенных
map-to-list, sorting, reconstruction или serialization. Детерминированные
ETF/hash выполняются только после проверки всего term. Unsupported terms
возвращают not_comparable; default comparison остаётся выключенным.

Тесты покрывают small maps, эквивалентный map insertion order,
references/PIDs/functions, огромные binary keys/values, огромные keys с общим
prefix, oversized maps, aggregate binary budget и depth. Arity-only call trace
ограничивает validation visits и доказывает, что rejected terms никогда не
вызывают term_to_binary/2, maps:to_list/1 или lists:sort/1; огромные arguments
не копируются в trace messages. Нет абсолютного realtime assertion.

### P0-01: отдельное наблюдение памяти после cleanup

Within-execution growth остаётся отдельным существующим observation. Новое
observation измеряет VM-global binary memory до execution и после нормального
guardian DOWN, confirmed cleanup и bounded quiescence. Оно работает вне guardian
через monitored, deadline-limited helpers. Failure даёт incomplete/unavailable;
target outcome не меняется. Failed cleanup остаётся infrastructure failure и
пропускает это observation. Нет target/shared-state mutation, чужого GC или
ownership changes.

Evidence хранит baseline_memory, sampled peak_memory, post_execution_memory,
residual_delta, units, threshold, scope, completeness, cleanup_status, quiescence,
deadline и явное ограничение attribution. Target-owned post memory —
not_applicable после завершения owners. `vm_memory_growth_suspected` имеет scope
vm_global и в evidence, и в artifact/dedup identity; это никогда не proven target
leak. Старые schema-v1 policy maps нормализуются с новыми defaults при загрузке.

Новый fixture возвращает новый binary 16 MiB через обычный run(binary()). EFZ
сохраняет return после root cleanup: поддерживаемая residual VM allocation с
известными attribution limits. Campaign reproduction — 3/3. Replay отбрасывает
raw returns между executions, поэтому сборка старого binary может компенсировать
новую allocation; он сообщает фактическое M/N, а не принудительное 3/3 или leak
verdict. Evidence run получил 1/3. Временная allocation 16 MiB имеет observed
peak, но не residual finding (delta 40 bytes в выделенном запуске, ниже fixture
threshold 8 MiB).

Приостановленный post-observation helper проверен отдельно: target timeout 60 ms,
guardian cleanup завершился на 66 ms, caller вернулся на 167 ms с incomplete
memory evidence, helper dead, runner reusable. Observation deadline 100 ms истёк
**после** cleanup; target termination он не задержал.

### P0-03: явный unknown timeout

Ветка disabled-hangs раньше не возвращала category. Включённая runtime diagnostics
теперь всегда классифицирует timeout как unknown, если hangs выключены.
Существующие no-samples, stale и insufficient-evidence paths также возвращают
unknown. Busy/waiting неизменны, classifications взаимоисключающие на execution.
Primary `{timeout, TimeoutMs}` не меняется.

### P0-04: отдельное исправление test infrastructure

Исходный timeout EUnit 5s охватывал две limits campaigns по 300 executions,
четыре независимых backend variants (~400 executions) или scheduler test на
512 executions. Сами кампании уже имели await bounds 10s. Это превращало
correctness test в непреднамеренный aggregate host-throughput gate.

Новый targeted run до текущих изменений воспроизвёл limits timeout. Обычные
запуски fresh clean-HEAD также были red (его более старый exhaustion await bound
плюс последующий smoke failure в full run), но не воспроизводили стабильно все
три short timeouts. Поэтому отдельно помеченный bounded diagnostic contention
experiment запустил три исходные functions с прежней границей EUnit 5s на обоих
сохранённых pre-fix tree и clean HEAD: все шесть cases отменены. Это diagnostic
FAILs, а не canonical PASS results, хотя сам driver завершился нормально.

Без конкурирующей нагрузки неизменённые assertions завершались по три раза:
limits 2.61–2.64s, scheduler 2.17–2.26s, backend 1.94–2.04s. Каждый возвращался к
processes=41, ETS=19, guardian=undefined, runner=ready. Evidence подтверждает
конечный workload / чувствительный к scheduler aggregate timeout, а не leaked
processes, потерянный cleanup или unbounded receive.

Исправление: разделить independent limits cases и backend variants на отдельные
EUnit cases. Согласовать внешний deadline limits/scheduler test (12s) с
существующим campaign await 10s плюс cleanup. Сохранить все iterations, variants,
assertions и весь scheduler scenario с 256 parents. Нет skips, reduced workload
или catch-all. Существующий exhaustion test 75s / campaign bound 60s сохранён.

Исправление можно просмотреть отдельно в
[test-infrastructure.patch](../../runtime-fixes-validation/test-infrastructure.patch)
относительно исходного dirty checkout, исключая прежние user changes.

## Изменённые implementation и test files

- `src/efz_stability.erl`: bounded comparator.
- `src/efz_runtime.erl`: before/post observations, VM sample context,
  timeout_unknown, более дешёвый итоговый запрос существования ETS.
- `src/efz_runtime_config.erl`: проверенные residual threshold/quiescence/deadline.
- `src/efz_executor.erl`: before measurement и интеграция после нормального guardian DOWN.
- `src/efz_worker.erl`: vm_global artifact scope для новой category.
- `src/efz_runtime_store.erl`: scoped signature, category validation, old policy defaults.
- `src/efz_runtime_replay.erl`: полнота residual observation в recheck.
- `fixtures/runtime/efz_runtime_memory_fixture.erl`: новый fixture без изменений existing harness.
- `test/efz_runtime_acceptance_tests.erl`: comparator/config/memory/timeout regressions.
- `test/efz_limits_tests.erl`, `test/efz_backend_tests.erl`, `test/efz_phase3_tests.erl`:
  отдельные test-infrastructure changes.
- `docs/runtime-diagnostics.md`, этот отчёт и `docs/runtime-fixes-validation/`:
  policy documentation и fresh evidence.

## Результаты регрессии

Все команды ниже выполнялись из project checkout с `ERL_FLAGS='+S 4:4'`.

| Команда | Exit | Passed | Failed / skipped | Секунды |
|---|---:|---:|---:|---:|
| rebar3 compile | 0 | — | — | 1 |
| rebar3 eunit, run 1 | 0 | 223 | 0 / 0 | 117 |
| rebar3 eunit, run 2 | 0 | 223 | 0 / 0 | 123 |
| rebar3 ct | 0 | 3 | 0 / 0 | 6 |
| rebar3 dialyzer | 0 | — | — | 8 |
| rebar3 xref | 0 | — | — | 1 |
| rebar3 eunit --module=efz_runtime_acceptance_tests,efz_runtime_tests | 0 | 20 | 0 / 0 | 8 |

Ранний combined targeted run (runtime + все три бывших timeout modules) прошёл
59 tests; позднейший config validation case включён в оба итоговых runs по
223 tests и итоговый runtime run из 20 tests. Logs:
[run 1](../../runtime-fixes-validation/final-eunit-1.log),
[run 2](../../runtime-fixes-validation/final-eunit-2.log),
[command statuses](../../runtime-fixes-validation/results.txt).

## Targeted acceptance

| ID | До | После | Evidence |
|---|---|---|---|
| P0-01 | FAIL | PASS | post-cleanup VM measurement; peak-only negative; campaign 3/3; stored/replayed actual M/N; suspended helper deadline |
| P0-02 | FAIL | PASS | budgets до traversal/serialization; trace доказывает rejection до дорогих calls; huge-key warm benchmark |
| P0-03 | FAIL | PASS | disabled sampler, interval длиннее timeout, zero/stale/incomplete samples, busy и waiting cases |
| P0-04 | FAIL | PASS | диагностированы исходные functions на обоих trees; full canonical EUnit дважды, 223/223 |

Дополнительная sanity check: существующий CLI efz_example_target с включённым P0
завершился exit 0. Examples и existing runtime harness byte-identical сохранённому
pre-fix tree. 25 random и staged mutations совпадают before-fixes/off/on по
generated inputs, staged traces/counters, coverage и corpus contents (volatile
metadata исключена). Существующие verification-isolation,
verification-only-crash, dirty-runner, guardian failure и suspended-sampler tests
проходят. Artifact, сохранённый до этих исправлений, также replay-ился в новой
CLI VM: compatibility verified, child_abnormal_exit observed 3/3, exit 0
([log](../../runtime-fixes-validation/old-runtime-replay.log)).

## Производительность

Три campaigns по 300 mutations на mode после warmup 50 mutations, одинаковые
input/seeds, один worker, +S 4:4; последовательные VM. Before — сохранённый
**dirty pre-fix tree**, а не clean HEAD (поэтому посторонние hit-count changes
постоянны). Median row по mutation throughput; calibration=1 в каждой строке.

| Исходная серия | Mutations | Verification | Wall s | Mutation/s | Total/s |
|---|---:|---:|---:|---:|---:|
| before fixes, off | 300 | 0 | 1.749 | 171.52 | 172.09 |
| after fixes, off | 300 | 0 | 2.003 | 149.76 | 150.26 |
| resources only | 300 | 0 | 2.005 | 149.60 | 150.10 |
| full | 300 | 4 | 2.065 | 145.28 | 147.70 |

Исходная off delta составила -12.7%; её не скрывали. Reverse-order control дал
before=202.48, after=206.45 mutation/s (+2.0%). Дополнительная CPU/reductions batch
дала before=206.47, after=205.82 (-0.3%). Median CPU runtime по трём runs:
4358 -> 4333 ms (-0.6%); reductions в median-throughput runs:
27,963,230 -> 27,965,219 (+0.007%). Существенная off regression controls не
воспроизвели. Host scheduling/frequency не фиксированы; данные не заявляют
универсальной throughput guarantee. Initial и control rows сохранены в
[bench-summary.log](../../runtime-fixes-validation/bench-summary.log).

Warmed comparator, 100 calls, map с двумя binary keys с общим prefix
(создание вне timing), все results not_comparable:

| Bytes/key | До, us | После, us |
|---:|---:|---:|
| 1025 | 46 | 31 |
| 1048577 | 6533 | 74 |
| 16777217 | 183717 | 44 |

Это подтверждает structural bound, а не утверждает realtime limit.
Ни одного comparator invocation не добавлено при compare_return=false.

## Примечание об ETS и оставшиеся ограничения

Итоговая проверка исчезновения теперь запрашивает только ets:info(Tab,owner),
избегая allocation полного table-info list (включая постороннюю metadata).
Enumeration semantics и owner filtering неизменны. ets:all всё ещё перечисляет
все VM tables до inspection cap: документированное ограничение O(VM table count),
вне guardian. 100 enumeration calls заняли 3210 us с 100 дополнительными tables
и 17313 us с 1000. Ownership redesign и неподдерживаемый VM-wide enumeration
cap не заявляются.

VM-global residual metrics намеренно не могут установить input attribution;
replay M/N может отличаться из-за сборки прежних returns. Quiescence — bounded
wait, а не утверждение о простое всей VM. Нет заявлений о confirmed
leak/deadlock/livelock. В этом наборе исправлений не осталось MAJOR/BLOCKER или
известных correctness MINOR.

## Дополнительные выполненные команды и raw evidence

```sh
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_runtime_acceptance_tests,efz_runtime_tests,efz_limits_tests,efz_phase3_tests,efz_backend_tests
ERL_FLAGS='+S 4:4' escript /tmp/efz-p0-fixes/debt_probe.escript /home/anonymous_usr/erl:fuzz/efz
ERL_FLAGS='+S 4:4' timeout 50s escript /tmp/efz-p0-fixes/debt_contention.escript /tmp/efz-acceptance-20260921/baseline
ERL_FLAGS='+S 4:4' timeout 50s escript /tmp/efz-p0-fixes/debt_contention.escript /tmp/efz-p0-fixes/before-tree
ERL_FLAGS='+S 4:4' escript /tmp/efz-p0-fixes/short_bench.escript /tmp/efz-p0-fixes/before-tree before-off off
ERL_FLAGS='+S 4:4' escript /tmp/efz-p0-fixes/short_bench.escript /home/anonymous_usr/erl:fuzz/efz off off
ERL_FLAGS='+S 4:4' escript /tmp/efz-p0-fixes/short_bench.escript /home/anonymous_usr/erl:fuzz/efz resources resources
ERL_FLAGS='+S 4:4' escript /tmp/efz-p0-fixes/short_bench.escript /home/anonymous_usr/erl:fuzz/efz full full
ERL_FLAGS='+S 4:4' escript /tmp/efz-p0-fixes/post_bound.escript /home/anonymous_usr/erl:fuzz/efz
```

Временные drivers/snapshots остаются в `/tmp/efz-p0-fixes/` и
`/tmp/efz-acceptance-20260921/baseline/`. Fresh logs сохранены в
`docs/runtime-fixes-validation/`; ни один historical acceptance log не засчитан
как PASS.
