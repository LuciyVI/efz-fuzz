# EFZ: профиль производительности engine v2 (2026-10-04)

[English](../../engine-performance-profile-v2.md) · **Русский** · [Español](../es/engine-performance-profile-v2.md) · [简体中文](../zh-CN/engine-performance-profile-v2.md) · [Все языки](../README.md)

## 1. Основные выводы

Сохранённые 900-секундные Cowboy runs показывают 269.54 exec/s для `none`,
107.87 для ETS, 64.74 для bitmap-v2 и 103.36 для OTP public. Следовательно,
одним coverage нельзя объяснить разрыв с внешним `erlang_fuzzer` (~19k exec/s),
имеющим другую in-process execution и fuzzing policy. Новый 900-секундный run
здесь не выполнялся.

Два коротких, с обратным порядком **fixed replays одних 1000 inputs** дают полной
no-op EFZ campaign 490.69 exec/s (2037.9 µs/input), Cowboy/none —
461.66–496.88 exec/s (2166.1–2012.6 µs/input). Fixed-replay ranges ETS, bitmap и
OTP public: 214.87–220.21, 89.64–91.75 и 364.67–416.51 exec/s. Input SHA256 —
`16FD09EF19D76F70ECC4E2000038632E30186175A3A6CA85F9FDC7A107B5F814` во всех runs.
Order и host load меняли абсолютные timings, поэтому differences ниже — ranges
двух runs, а не точная изолированная cost primitive.

В reverse-order OTP replay `code:get_coverage/2` занимает 5.4 µs/input (0.228%),
conversion 14.8 µs (0.629%), измеренный pipeline
reset+read+conversion+novelty+merge — 24.0 µs (1.022%). Одна trace setup занимает
~942 µs (40.1%). Compact/opaque OTP coverage API имел бы theoretical upper bound
~1.01× для этого измеренного pipeline. Первый engineering spike должен изучать
trace lifecycle и isolation-preserving alternatives, а не OTP internals.
ETS остаётся default; bitmap-v2 — experimental/reference.

## 2. Сохранённые 15-минутные результаты

Источник: `artifacts/cowboy-long-bench/engine-20261004T063922Z-{none,ets,bitmap,otp_native_public}/summary.csv`
и `samples.csv`. Та же Cowboy version и seed corpus; independent evolving fuzz
histories — **не** equal-input comparisons.

| Mode | Executions | Среднее exec/s | Медиана | P10–P90 | Первые/последние 60 s | Итоговый корпус | Единицы coverage |
|---|---:|---:|---:|---:|---:|---:|---|
| none | 242589 | 269.54 | 276.10 | 222.10–287.90 | 315.73/220.78 | 12 | disabled |
| ETS | 97081 | 107.87 | 108.10 | 105.10–110.20 | 106.18/106.13 | 82 | 296 EFZ probes |
| bitmap-v2 | 58265 | 64.74 | 64.90 | 61.40–68.00 | 63.40/64.83 | 82 | 296 EFZ probes |
| OTP public | 93030 | 103.36 | 59.10 | 20.00–196.80 | 195.12/176.88 | 64 | 336 OTP lines |

ETS и bitmap завершились с одинаковыми structural coverage count и corpus size,
но это не доказывает исполнения тех же inputs. OTP line counts несопоставимы
с structural probe counts. External run описан в
[длительном Cowboy benchmark](cowboy-long-benchmark.md); его ~19k exec/s измеряют
другой engine и feedback policy.

## 3. No-op engine ceiling и Cowboy без coverage

Настоящий `efz_noop_target:run/1` находится в
[test/targets/engine/efz_noop_target.erl](../../../test/targets/engine/efz_noop_target.erl).
`--target noop --backend none` использует те же [worker](../../../src/efz_worker.erl),
[executor](../../../src/efz_executor.erl), [guardian](../../../src/efz_guardian.erl), corpus
и cleanup, что Cowboy. `none` пропускает coverage storage/reset/read/novelty;
это benchmark/debug mode. В fixed replay 1000 inputs с `+S 2:2` и profiling
no-op дал 490.69 exec/s, wall 2037.9 µs/input, **measured iteration mean
1988.2 µs**. Layered full-campaign microbenchmark дал 418.39 exec/s за 300
repetitions; short-run scheduler variation объясняет, почему это разные ceilings.
Cowboy/none run даже достиг 496.88 exec/s при других мгновенных условиях.
Поэтому 490.69 — measured no-op result, а не strict upper bound.

Forward Cowboy/none run дал 496.88 exec/s и 2012.6 µs/input на тех же input bytes;
reverse run дал 461.66 и 2166.1. В reverse run Cowboy target body для `none`
занимал в среднем около 40 µs/iteration; no-op target почти не работает.
Разности whole-cycle means также включают host scheduling, code loading и
input-specific work, поэтому `Cowboy minus no-op` — лишь приближение target cost.

## 4. Поток данных итерации и lifecycle процессов

`efz_worker:handle_info/2` выбирает corpus input и вызывает mutator в evolving
run. `execute_allowed/4` хеширует/проверяет его, а `execute_checked/4` вызывает
`efz_executor:run/4`. `efz_executor:run_pinned/4` создаёт monitored guardian на
testcase. `efz_guardian:start/6` создаёт trace session, baseline shared state,
monitored coordinator и monitored root. `efz_executor:invoke/4` вызывает target
в root и отправляет result coordinator. `efz_guardian:cleanup/2` убивает controlled
tree; `loop/1` вычитывает `DOWN` и trace barriers. `efz_guardian:finish/2`
запечатывает coverage, уничтожает trace и проверяет shared state. Затем worker
вызывает `efz_feedback:evaluate/3`, `retain/3` и записывает decision.

```text
persistent EFZ worker
  -> spawn_monitor guardian -> trace session / coordinator / root
  -> root invokes target -> coordinator classifies -> guardian cleans/drains
  -> guardian result + DOWN -> worker feedback/corpus -> next iteration
```

Не менее трёх processes (`guardian`, `coordinator`, `root`) и трёх операций
`spawn_monitor` создаются на normal testcase в [executor](../../../src/efz_executor.erl)
и [guardian](../../../src/efz_guardian.erl), плюс explicit monitors для caller, guardian
и root. Worker persistent. Application/worker supervisor links относятся к
кампании, а не создаются на каждый testcase. Как минимум происходят messages
coordinate, ready, start, target-result, coordinator-done, guardian-result,
guardian-DOWN и next-iteration; дополнительные `DOWN`, trace-delivered,
execution-context и descendant events делают точный fixed message count
некорректным. Iteration deadline и bounded cleanup deadline проверяются в guardian
receive loops. Per-iteration allocations включают context/metadata maps, hashes,
sets, tracing state, monitors и три process heaps. Reuse worker/corpus/global
coverage не устраняет guardian lifecycle work.

## 5. Stage profiling и учёт

`performance_profile` по умолчанию false в
[efz_config:defaults/0](../../../src/efz_config.erl). С `--profile`
[efz_perf_profile](../../../src/efz_perf_profile.erl) записывает calls, total, mean,
median, p90 и p99; disabled path не читает clock. Worker, guardian и
[OTP native collector](../../../src/efz_cov_native_public.erl) публикуют отдельные
nested timings. Их предоставляют `profile.term` и
`scripts/print_engine_profile.escript`. Таблица использует **current reverse
fixed replay OTP public** run (`v2-current-reverse-otp_native_public`). Его
measured iteration mean — 2351.0 µs; wall с campaign start/report — 2400.9 µs/input.

Соответствующий stage summary сохранён в
[engine-otp-fixed-profile-v2-2026-10-04.term](../../performance/engine-otp-fixed-profile-v2-2026-10-04.term).

900-секундный `none` mean 269.54 exec/s — около 3710 µs/execution, но profiling
в этом run выключен. Percentages короткого fixed replay **нельзя** приписывать
этому точному long-run baseline: mutation/corpus evolution, scheduler conditions
и sampling отличаются. Для точного percentage breakdown наблюдения 270 exec/s
нужна ручная profiled long campaign.

| Stage | µs/iteration | % iteration | Граница |
|---|---:|---:|---|
| Mutation | 0 | 0 | выключена в fixed replay; evolving 20 s run: ~3.9 µs |
| Input preparation | 1.4 | 0.06 | SHA256/check/metadata |
| Worker/executor inclusive | 2162.0 | 91.96 | содержит guardian и target |
| Guardian inclusive | ~1908 | ~81.2 | prepare + target + cleanup + finish + gaps |
| Trace setup within guardian | 942.3 | 40.08 | trace session на iteration |
| Coverage reset | 0.5 | 0.02 | `code:reset_coverage/1` по четырём modules |
| Target body | 33.7 | 1.44 | Cowboy parser path |
| `code:get_coverage/2` | 5.4 | 0.23 | четыре modules |
| Coverage conversion | 14.8 | 0.63 | Erlang terms в bitset |
| Novelty | 3.1 | 0.13 | native bitset |
| Global merge | 0.28 amortized | 0.012 | 34 merge calls |
| Feedback inclusive | 129.0 | 5.49 | включает novelty/merge и decode на discoveries |
| Corpus decision | 0.1 | 0.005 | fixed replay подавляет corpus insertion |
| Corpus store | 0 | 0 | выключен для fixed replay; отдельно измерен на discoveries |
| Cleanup wait | 108.1 | 4.60 | guardian ждёт quiescence |
| Guardian finish inclusive | 583.8 | 24.83 | включает trace destroy, shared checks, coverage read |
| Worker unaccounted | 58.4 | 2.49 | messages/scheduling и code без timing |

**Не складывайте nested rows.** Worker top-level stages плюс
`worker_unaccounted` по построению равны total. Собственный unaccounted mean
guardian — 111.3 µs (~4.7% iteration); `executor_outer_us` — 253.6 µs (~10.8%),
охватывая preflight, caller/guardian handoff, result/`DOWN` wait и scheduling
вне measured lifetime guardian. Это выделено, а не молча скрыто в «прочее»;
constituents отдельно не измерялись. Measured top-level unaccounted fraction
остаётся ниже 10%, но per-stage wall clocks включают scheduler pauses и profiling
overhead.

## 6. Synthetic layers worker/guardian

Воспроизводимый [lifecycle microbenchmark](../../../bench/engine_lifecycle.escript)
выполнен с OTP 27, `+S 2:2`; raw result:
`docs/performance/engine-lifecycle-v2-2026-10-04.term`.

| Layer | Iterations | µs/call | Примечания |
|---|---:|---:|---|
| Direct no-op call | 100000 | 0.006 | JIT/tight-loop lower bound; возможны compiler effects |
| Persistent actor message round trip | 10000 | 0.636 | один actor, без isolation |
| Spawn+monitor no-op process | 1000 | 1.195 | один process; без guardian/tracing |
| Real `efz_executor:run/4` | 300 | 2456 | полный guardian, без worker/corpus loop |
| Full EFZ fixed campaign | 300 | 2390 | включает worker/feedback; scheduler variance не позволяет вычитать |

Разрыв между process message или одним spawn и full executor намного больше
самого target call. Эти synthetic layers имеют разные contracts; times нельзя
механически вычитать для оценки одной EFZ guarantee. Caller reductions и VM GC
deltas сохранены в raw term. Точный dynamic count всех guardian trace messages,
BEAM heap allocations и monitor operations **не измерялся**; static bounds выше
получены из source.

## 7. Стоимость mutation и corpus

`bench/engine_mutation_micro.escript` с fixed input 51 bytes и `+S 2:2`:
1000 random mutations median 631 µs, 10k median 6529 µs, 100k median 65605 µs
(~1.52 million mutation/s). Mean output size в 100k batches — ~51.0 bytes.
Одна mutation ниже 1-µs timer resolution. Staged dictionary: 1000 plan visits
median 601 µs, выдано 398 candidate inputs в этом fixture. Raw repetitions,
reductions, process memory deltas и output-byte totals находятся в
`docs/performance/engine-mutation-v2-2026-10-04.term`; process memory delta —
не exact allocation count. Одной mutation нельзя объяснить engine, ограниченный
несколькими сотнями exec/s на этом workload.

`bench/engine_corpus_micro.escript` с `+S 2:2`: corpus select/input retrieval
1.21 µs, SHA256 0.18 µs, metadata encoding 0.25 µs, in-memory duplicate check
1.03 µs, in-memory insert 2.74 µs. Тридцать durable initial-entry writes
`efz_corpus_store:save/4` с fsync в среднем заняли 2543 µs; disk duplicate —
187 µs. Raw data: `docs/performance/engine-corpus-v2-2026-10-04.term`.
Эти I/O figures зависят от filesystem `/tmp` и cache. На ordinary no-novelty
path [efz_worker:retain/3](../../../src/efz_worker.erl) **не** вызывает
`efz_corpus:add/2`; fixed replay дополнительно запрещает growth по design.
Поэтому novel discoveries могут иметь persistence cost в миллисекундах,
но не каждая iteration пишет на диск.

В последующем evolving OTP smoke 10 seconds (`v2-current-otp-timeseries-10s`)
4152 executions увеличили корпус 12→45. Новый nested timer `corpus_store`
записал total 155716 µs, amortized 37.5 µs/iteration (1.56%); median и p90 нулевые,
поскольку большинство iterations не сохраняют. `corpus_decision` включает это
время. Этот short warmup — не 900-секундное no-novelty plateau.

Stage samples с шагом 1 second этого smoke сохранены как
[engine-otp-stage-samples-v2-2026-10-04.csv](../../performance/engine-otp-stage-samples-v2-2026-10-04.csv).

## 8. Fixed replay: одинаковые inputs и backend overhead

`--fixed-replay N` в [Cowboy runner](../../../scripts/cowboy_long_bench.escript) создаёт
deterministic sequence из тех же 12 seeds и random seed, сохраняет точные
`replay-inputs.term` и SHA256, затем напрямую подаёт их persistent worker.
Benchmark branch [efz_worker:handle_info/2](../../../src/efz_worker.erl) пропускает
calibration/mutation и продвигается по list order;
[execute_result/6](../../../src/efz_worker.erl) всё ещё вычисляет feedback/global coverage,
но подавляет corpus insertion, поэтому feedback не может выбрать следующий
input. Result проверяет ровно `N` executions и `completed`, сохраняя corpus 12.
Эта branch только benchmark и не меняет ordinary fuzz path. Тесты покрывают
duplicate replay inputs, default disabled profiling и неизменные decisions
при toggling profiling.

Обе current series из 1000 inputs использовали `ERL_FLAGS='+S 2:2'`, `--profile`
и тот же SHA256 выше. Run directories:
`artifacts/cowboy-long-bench/v2-current-forward-*` и `v2-current-reverse-*`.
Runner wall time начинается непосредственно до `efz:start/1` и включает
finite-campaign startup/report; stage percentages используют timed iterations.
Inputs идентичны **внутри каждой series и между series**, но target BEAMs
различаются instrumentation; code loading/order и external host load всё ещё
влияют. Более ранние exploratory runs `v2-fixed-*` использовали timer после
`efz:start/1`; runs `v2-final-*` предшествуют отдельному timer `corpus_store`.
Оба исключены из таблицы.

Compact summary с artifact paths и hashes:
[engine-fixed-replay-v2-2026-10-04.term](../../performance/engine-fixed-replay-v2-2026-10-04.term).

| Mode | Forward exec/s | Forward µs/input | Reverse exec/s | Reverse µs/input |
|---|---:|---:|---:|---:|
| No-op + none (отдельный run) | — | — | 490.69 | 2037.9 |
| Cowboy + none | 496.88 | 2012.6 | 461.66 | 2166.1 |
| Cowboy + ETS | 220.21 | 4541.1 | 214.87 | 4654.1 |
| Cowboy + bitmap | 91.75 | 10899.1 | 89.64 | 11155.5 |
| Cowboy + OTP public | 364.67 | 2742.2 | 416.51 | 2400.9 |
| Cowboy + OTP native no read | 473.53 | 2111.8 | 448.82 | 2228.1 |

Парная разность wall time `mode - none` даёт для ETS примерно
**+2.53/+2.49 ms/input**, bitmap **+8.89/+8.99 ms**, OTP public **+0.73/+0.23 ms**
(forward/reverse). Native no-read — +0.10/+0.06 ms против none. OTP pair меняется
намного сильнее measured `get_coverage` time; эти runs не изолируют source.
ETS остаётся ~2.1–2.2× медленнее none, bitmap ~5.1–5.4×. Это total mode
differences, **не pure coverage primitive overhead**. В частности, trace setup
guardian различается между structural и native builds, а feedback policy/global
state разные.

Bitmap остаётся медленнее ETS на identical inputs; несколько миллисекунд
reverse-run iteration mean занимают instrumented target body против ~0.1 ms
ETS. Guardian finish также дороже. Bitmap-v3 optimization не предпринималась;
bitmap-v2 остаётся experimental/reference.

## 9. Разбор OTP native и no-read control

`otp_native_no_read` — benchmark alias `none_instrumented`: Cowboy компилируется
с OTP `line_coverage`, но EFZ использует `coverage_backend => none` на iterations.
Preflight может один раз изучить coverage при setup; iteration не сбрасывает,
не читает, не преобразует, не сравнивает и не объединяет native coverage.
Target и seed/mutation setup совпадают с OTP public. Это приблизительно
разделяет наличие native instrumentation и extraction/feedback, не меняя
production backend.

В reverse fixed replay total mode difference public против native no-read —
**172.8 µs/input**; в forward — **630.4 µs**. Measured
reset+get+conversion+novelty+merge — 24.0 µs/iteration в reverse, inclusive feedback
129.0 µs. Остальное включает schema checks, diagnostic/new-line decoding,
context/result handling и scheduling differences; это не автоматически cost
`code:get_coverage`. Только `get_coverage` — 5.4 µs/iteration (0.228%),
`get_coverage+conversion` — 20.2 µs (0.857%). Разброс ограничивает точность
end-to-end attribution.

## 10. Вариативность OTP throughput и размеры inputs

Сохранённая OTP time series 900 seconds держалась на ~180–200 exec/s в начале,
падала до ~17–26 между ~300–660 s, затем восстанавливалась до ~180 без
соответствующего reversal corpus/coverage. Во время большей части спада corpus
был 61–62, coverage 333–334. Process count оставался 52, VM run queue 1,
VM memory около 46–48 MB. Важное наблюдение: reductions/execution оставались
~83k, GC collections/execution ~3.1 до, во время и после спада. Это ослабляет
объяснения более сложными inputs, большим числом executable lines, coverage
discoveries или частотой GC. Старый run **не** записывал input sizes или stage
timings, CPU steal/throttling или per-scheduler utilization. Host/VM scheduling
slowdown правдоподобен, но **не доказан**; точный механизм открыт.

Новый OTP run 20 seconds `+S 2:2` (`v2-otp-timeseries-20s`) завершил
7445 executions, mean 372.18 exec/s. `samples.csv` и `stage-samples.csv`
записывают throughput с шагом 1 second, corpus, coverage, discoveries, GC,
run queue, mean input bytes и per-execution stage costs. Throughput вырос
с ~255 до ~380–399 exec/s во время warmup. Trace setup упала с ~1518 до
~975–1044 µs/execution; `get_coverage` оставался ~5.6–7.3 µs, conversion ~15–19 µs.
Этот short run **не воспроизвёл** долгий спад. Correlation в этом warmup window
смешана с одновременными discoveries и изменяющимися scheduler/trace costs;
causal mechanism она не определяет. Если спад повторится, нужен будущий manual
diagnostic long run с `--profile --sample-interval 10`.

```sh
./scripts/run_cowboy_long_bench.sh --backend otp_native_public \
  --duration 900 --seed 424242 --profile --sample-interval 10
```

Команда подготовлена для **ручного** run; здесь она не исполнялась. При повторе
slowdown совместите `stage-samples.csv` с OS CPU throttling/steal, per-scheduler
utilization и GC pause time. Текущая telemetry не различает эти причины.

Input buckets собираются лишь с profiling в
[efz_worker:finish_iteration/1](../../../src/efz_worker.erl). Current reverse fixed
OTP replay:

| Input bytes | Count | Mean target µs | Mean iteration µs |
|---|---:|---:|---:|
| 0–64 | 583 | 20.9 | 2344.9 |
| 65–256 | 334 | 57.8 | 2356.9 |
| 257–1024 | 83 | 27.2 | 2370.3 |
| 1025–4096 | 0 | не проверено | не проверено |
| >4096 | 0 | отклоняется campaign limit | отклоняется campaign limit |

Iteration mean мало меняется между measured buckets, несмотря на target-time
differences. Old long-run input-size correlation остаётся неизвестной.

## 11. Пробелы instrumentation

EFZ manifests в `v2-fixed-1000-ets/target-beams/*.efz-manifest` перечисляют
`preserved_without_internal_probes` для следующих constructs. Для native column
загружены точные OTP 27 `line_coverage` BEAMs из fixed run; executable line lists
запрошены через `code:get_coverage(line, Module)`.

| Module / source line | Конструкция | EFZ internal probe | OTP executable line | Следствие |
|---|---|---|---|---|
| `cowboy_http:121` | record default | нет | нет | Ни один не даёт internal point здесь; окружающие function probes могут сработать |
| `cowboy_http:1499` | list comprehension | нет | да | OTP может видеть достижение line; ни один не обязательно отражает каждый comprehension outcome |
| `cowboy_req:488,1056` | list comprehensions | нет | да | EFZ может пропустить internal behavior distinction |
| `cowboy_router:66,90,328,330` | list comprehensions | нет | да | EFZ может пропустить internal behavior distinction |

Это semantic gap, а не доказательство, что OTP line coverage глобально богаче:
EFZ structural probes могут различать outcomes одной line, которые OTP line
coverage объединяет. Instrumentation placement в этой задаче не менялся.

## 12. Внешний erlang_fuzzer и persistent execution

| Свойство | EFZ | External erlang_fuzzer | Следствие для cost и safety |
|---|---|---|---|
| Execution / invocation | target в новом controlled root | persistent in-process call | Меньше setup снаружи; EFZ изолирует BEAM process tree |
| Mutation | Erlang random/staged | libFuzzer | Разные sequence и corpus pressure |
| Worker/guardian | persistent worker, новые guardian/coordinator/root | нет EFZ guardian | EFZ платит за trace, monitors и barriers |
| Coverage/feedback | EFZ structural или OTP lines, EFZ novelty | native counters/features | Разные coverage units и acceptance |
| Corpus scheduling | EFZ queue и durable entries | libFuzzer corpus policy | Разные growth и I/O |
| Crash/timeout | controlled tree и classified cleanup | libFuzzer/NIF runtime | Разный safety contract |
| IPC/process lifecycle | messages, monitored processes на testcase | direct in-process loop | Ожидается большой throughput difference |

Measured full no-op EFZ floor — примерно 2.1 ms при `+S 2:2`; external result —
около 52 µs/iteration, но это **не matched workloads**. Trace setup/destroy и
controlled process/IPC lifecycle — узкие места EFZ; libFuzzer mutation/feedback
и target invocation также отличаются. Causal numerical decomposition разрыва
19k против 270 не обоснована.

Persistent-root mode EFZ потребовал бы отдельного safety design: deadline
enforcement при blocked target, restart после crash, удаление stale messages,
сброс process dictionary/ETS и target-state, descendant ownership, retirement
coverage generation и проверку, что cleanup действительно остановил каждого
writer. Process pool может сохранять safe fallback, выводящий contaminated
workers из использования; fast in-process mode предложит более слабую isolation
и должен явно так обозначаться. **Редизайн не реализован.** Следующий шаг —
bounded trace-lifecycle experiment с deterministic crash/timeout/late-writer
тестами, а не удаление guardian checks на основании microbenchmark.

## 13. Анализ Amdahl и решение о default backend

В current reverse OTP replay `get_coverage+conversion` — 0.857% iteration time,
что даёт theoretical maximum speedup `1/(1-0.00857) ≈ 1.009×`, если оба станут
бесплатными. Весь measured native pipeline — 1.022%, что даёт `≈1.010×`.
Даже устранение всего inclusive feedback stage (5.49%) ограничит speedup
`≈1.058×` для этого replay. Bounds специфичны workload и не объясняют long-run
variability 20–200 exec/s.

Следующий engineering step с наибольшим measured potential — profiling и prototype
более дешёвого **isolation-preserving trace lifecycle**, затем benchmark на
identical inputs и validation crash/timeout/descendant cleanup. Уменьшение
shared-state checks или IPC — после собственных measurements и safety proof.
Optimization или patch OTP coverage API сейчас низкоприоритетны; DWARF/raw-pointer
work не возобновлялась. ETS остаётся default для точности structural-probe
semantics. `otp_native_public` — opt-in alternative с другими line semantics и
неразрешённой long-run variability. Bitmap-v2 остаётся experimental/reference,
поскольку и long, и fixed replay показывают его медленнее ETS.

## 14. Воспроизведение и validation

Короткий fixed replay:

```sh
for backend in none ets bitmap otp_native_public otp_native_no_read; do
  ERL_FLAGS='+S 2:2' ./scripts/run_cowboy_long_bench.sh \
    --backend "$backend" --fixed-replay 1000 --seed 424242 --profile \
    --out "artifacts/cowboy-long-bench/my-fixed-$backend"
done
```

No-op и component benches:

```sh
ERL_FLAGS='+S 2:2' ./scripts/run_cowboy_long_bench.sh --backend none \
  --target noop --fixed-replay 1000 --seed 424242 --profile \
  --out artifacts/cowboy-long-bench/my-fixed-noop
ERL_FLAGS='+S 2:2' escript bench/engine_lifecycle.escript /tmp/efz-engine-lifecycle.term
ERL_FLAGS='+S 2:2' escript bench/engine_mutation_micro.escript /tmp/efz-mutation.term
ERL_FLAGS='+S 2:2' escript bench/engine_corpus_micro.escript /tmp/efz-corpus.term
```

Checks после изменений: `ERL_FLAGS='+S 1:1' rebar3 eunit` **260 PASS**;
CT **3 PASS**; xref и Dialyzer **PASS**. Новый EUnit case проверяет fixed replay,
no-coverage mode, profiling off по умолчанию, profiling behavior и input buckets.
Fixed runs `none`/OTP public/OTP no-read завершились без crashes и timeouts;
output terms с `~w` подходят для consult даже при arbitrary mutated binary bytes.
Один ранний telemetry run 45 seconds завершил target execution, но упал при
записи stage samples из-за `zip` unequal lists; exporter исправлен, последующий
20-секундный run прошёл. Failed run не считается successful telemetry result.
Long-run leak behavior и механизм OTP mid-run slowdown остаются непроверенными.
