# EFZ: профиль стоимости одной итерации

Следующий этап с 15-минутными результатами, fixed replay и анализом
нестационарности OTP: [engine-performance-profile-v2.md](engine-performance-profile-v2.md).

## 1. Executive summary

Экспериментальный `coverage_backend => none` оставляет обычные mutation, corpus, worker, guardian, timeout и cleanup EFZ, но не собирает покрытие. На этом хосте короткий 30-секундный Cowboy run дал **60.70 exec/s** без instrumentation, а no-op target — **63.13 exec/s** с profiling и **63.70 exec/s** без него. Средняя стоимость итерации no-op при 16 scheduler — **15.82 ms**. Это потолок *данной конфигурации и нагрузки хоста*, а не архитектурный предел EFZ: с `+S 1:1` отдельный 10-секундный no-op run дал **163.88 exec/s**, средняя итерация **6.09 ms**. Минимум отдельной итерации не измерялся как надёжная характеристика.

В профиле `otp_native_public` `code:get_coverage/2` занял **15.25 µs/iteration (0.081%)**. Сумма reset, get, conversion, novelty и merge — **74.77 µs (0.398%)**. Основные измеренные затраты — lifecycle guardian: trace setup, trace destroy и проверка shared state. Патч compact/opaque OTP coverage API сейчас не обоснован как следующий шаг для ускорения EFZ. Это локальный stage profile; для устойчивых выводов о throughput нужны парные повторные прогоны.

## 2. Контекст и воспроизводимость

Пользовательские 15-минутные результаты: ETS 54.66, bitmap-v2 27.56, `otp_native_public` 96.59, внешний `erlang_fuzzer` 19019.08 exec/s. Сырые runs сохранены соответственно в `artifacts/cowboy-long-bench/20261003T065733Z-ets/`, `20261003T065741Z-bitmap/`, `20261003T065750Z-otp_native_public/`, `20261004T053054Z-erlang_fuzzer/`. Последний использует libFuzzer mutation, in-process loop и собственные feedback/corpus features. Отношение ~197 между ним и OTP public **не является** оценкой стоимости coverage.

Короткие прогоны ниже: OTP 27.0, ERTS 15.0, x86_64 Linux, 16 online schedulers, Cowboy 2.19.0, 12 одинаковых seeds, seed 424242, duration 30 s, `--profile`, если не отмечено иначе. Хост был загружен (load average примерно 18–22). Первые no-op/none прогоны дали лишь 17.60/19.57 exec/s при trace setup 35.4/31.1 ms; повторные дали 63.13/60.70. Значит, одиночная пара и абсолютные проценты не переносимы на другую scheduler/host нагрузку. Ни один 900-секундный run в рамках этого этапа не запускался.

| Короткий workload | Run | Выполнений | exec/s | Средняя iteration |
|---|---|---:|---:|---:|
| No-op, none, profile | `20261004T061445Z-noop-none` | 1895 | 63.13 | 15,819 µs |
| No-op, none, без profile | `20261004T061406Z-noop-none` | 1912 | 63.70 | — |
| Cowboy, none | `20261004T061152Z-none` | 1822 | 60.70 | 16,455 µs |
| Cowboy, none_instrumented | `20261004T061050Z-none_instrumented` | 1799 | 59.93 | 16,676 µs |
| Cowboy, ETS | `20261004T061244Z-ets` | 1172 | 39.03 | 25,606 µs |
| Cowboy, bitmap-v2 | `20261004T061324Z-bitmap` | 734 | 24.43 | 40,916 µs |
| Cowboy, OTP public | `20261004T061001Z-otp_native_public` | 1598 | 53.23 | 18,768 µs |

`none_instrumented` собирает Cowboy с `line_coverage`, но не вызывает reset/get/feedback. Разница с raw `none` на одной короткой паре мала и не отделена от шума. Эти прогоны не следует сравнивать по corpus/coverage count как одинаковые fuzzing histories.

## 3. Архитектура итерации и IPC

`efz_worker:handle_info/2` выбирает corpus input и мутирует; `execute_allowed/4` считает hash, проверяет input; `execute_checked/4` вызывает `efz_executor:run/4`. `efz_executor:run_pinned/4` **на каждую итерацию** создаёт и мониторит guardian, ждёт result и `DOWN`. `efz_guardian:start/6` создаёт trace session, снимает baseline shared state, создаёт monitored coordinator и monitored root, устанавливает контекст; `efz_executor:invoke/4` исполняет target в root. Coordinator классифицирует результат, guardian прекращает дерево и ждёт `DOWN`/trace barriers, затем `efz_guardian:finish/2` собирает coverage, уничтожает trace session и проверяет shared state. Worker вызывает `efz_feedback:evaluate/3`, затем `retain/2` и `accepted/5`. Worker кампании сохраняется между итерациями; guardian, coordinator и root создаются заново. Дополнительные descendants создаются по запросу target.

Минимальный normal path включает 3 `spawn_monitor` (guardian, coordinator, root), дополнительные `monitor` (caller/root/guardian), сообщение worker→guardian через spawn closure, `coordinate`, `coordinator_ready`, `start_owned`, `target_result`, `coordinator_done`, guardian→worker result и соответствующие `DOWN`/trace barrier events. Точное число сообщений зависит от runtime sampler, trace и descendants; фиксированное число IPC на каждый testcase **не доказано**. `efz_guardian:cleanup/2` завершает admitted tree даже на no-op; это часть модели безопасности, а не coverage overhead. `efz_cov_integrity:trace_setup/3` и `efz_cov_integrity:close/0` продолжают работать в режиме `none` для проверки lifecycle.

## 4. No-coverage ceiling и no-op harness

`none` требует `automatic + presence`, не загружает coverage schema, не открывает storage и не вызывает `code:reset_coverage/1` или `code:get_coverage/2`. `efz_feedback:evaluate/3` возвращает отсутствие новых точек, но сохраняет calibration и target-failure retention reasons. Corpus выбирается, mutation исполняется и решения сохранения принимаются обычным путём. `none` служит performance/debug baseline, а не production coverage-guided режимом. `none_instrumented` полезен для приближённой оценки стоимости OTP line instrumentation. No-op `test/targets/engine/efz_noop_target.erl` выполняет `run(_Input) -> ok` через настоящий EFZ engine.

No-op при 16 schedulers: 63.13 exec/s и 15,819 µs/iteration с profile. При `ERL_FLAGS='+S 1:1'` 10-секундный run `20261004T062318Z-noop-none` дал 163.88 exec/s и 6093 µs/iteration, trace setup 2479 µs. Это демонстрирует чувствительность trace setup к scheduler settings/нагрузке. В `none` Cowboy target занял в guardian в среднем 104 µs, no-op target 2.25 µs; разницу в полном цикле нельзя считать только target cost из-за непарных runs.

Команды короткого воспроизведения:

```sh
./scripts/run_cowboy_long_bench.sh --backend none --target noop --duration 30 --seed 424242 --profile
./scripts/run_cowboy_long_bench.sh --backend none --duration 30 --seed 424242 --profile
./scripts/run_cowboy_long_bench.sh --backend none_instrumented --duration 30 --seed 424242 --profile
./scripts/run_cowboy_long_bench.sh --backend otp_native_public --duration 30 --seed 424242 --profile
escript scripts/print_engine_profile.escript artifacts/cowboy-long-bench/RUN_DIR
```

## 5. Stage timing и accounting

Profile включается только `performance_profile => true`/`--profile`. `efz_perf_profile:measure/2` не вызывает clock при выключенном флаге; summary хранит максимум 20 000 samples на stage, totals/calls продолжают накапливаться. Median/p90/p99 находятся в `profile.term`; просмотр — `scripts/print_engine_profile.escript`. Числа ниже — mean по 30-секундным прогонам, проценты от `iteration_total`. Вложенные стадии **нельзя суммировать друг с другом**.

| Стадия | No-op none µs | OTP public Cowboy µs | OTP % |
|---|---:|---:|---:|
| Corpus select | 32.6 | см. `profile.term` | — |
| Mutation | 12.8 | см. `profile.term` | — |
| Executor целиком | 15,472 | 17,909 | 95.4% |
| Guardian целиком | 15,074 | 16,753 | 89.3% |
| Guardian prepare | 9,416 | см. `profile.term` | — |
| Trace setup (внутри prepare) | 8,924 | 8,507 | 45.3% |
| Guardian finish | см. `profile.term` | 5,677 | 30.2% |
| Trace destroy (внутри finish) | 3,039 | см. `profile.term` | — |
| Shared state check (внутри finish) | 1,736 | см. `profile.term` | — |
| Cleanup wait | 595 | 1,152 | 6.1% |
| Target body | 2.25 | 92.9 | 0.50% |
| Feedback целиком | см. `profile.term` | 389.7 | 2.1% |
| Corpus decision/save | см. `profile.term` | 86.1 | 0.46% |

Worker accounting раскладывает `iteration_total` на corpus select, mutation, input preparation, executor, feedback, corpus decision и `worker_unaccounted`; guardian accounting аналогично делит guardian total на prepare, target, cleanup wait, finish и unaccounted. Оба суммируются до 100% **по определению расчёта**, а не доказывают отсутствие скрытой стоимости. В no-op `worker_unaccounted` равен 293 µs, `guardian_unaccounted` 122 µs. Сюда входят промежутки между замерами, IPC/scheduling, создание metadata, сообщения и код, не вынесенный в отдельный timer. `executor_outer` — разница между временем вызова executor и guardian total; в OTP run около 1156 µs/iteration. Для дальнейшего точного анализа стоит отдельно измерять ожидание `DOWN`, scheduler wait, reductions и GC, не именуя всё «other».

Для оценки разброса: no-op `executor` median/p90/p99 = 15,112/21,497/27,289 µs, `trace_setup` = 8,598/13,546/18,487 µs. В OTP run `get_coverage` = 14/17/44 µs, conversion = 38/51/79 µs, `feedback` = 324/540/1645 µs. Эти quantiles относятся к отдельным стадиям, а не к синхронным percentiles одной итерации.

## 6. OTP native breakdown

В run `20261004T061001Z-otp_native_public` 1599 вызовов native read/reset включают calibration. Среднее на вызов: reset 1.82 µs, `code:get_coverage(line, M)` по четырём модулям 15.25 µs, conversion 41.26 µs, novelty 15.88 µs. Merge выполнялся 34 раза, 26.4 µs на вызов; амортизированно ~0.56 µs/iteration. Сумма пяти стадий 74.77 µs/iteration, 0.398% wall time. `native_read` 20.5 µs уже включает get и schema checks; не складывать его с `get_coverage`. `feedback` 389.7 µs включает novelty, decode новых lines, schema checks и формирование решения; не складывать его целиком с вложенными стадиями. Даже устранение всего измеренного public coverage pipeline в одиночку дало бы не более ~0.4% ускорения в этом профиле. Это верхняя граница Amdahl для данного run, не прогноз нового OTP API.

## 7. Mutation и corpus

`bench/engine_mutation_micro.escript` с фиксированным 51-byte input: один random mutation — median 1 µs (100 samples, resolution 1 µs); 1000 random mutations — median 879 µs за batch (10 batches, 865–918), около 1.14 млн mutation/s; 1000 staged dictionary plan visits — median 654 µs (10 batches, 398 candidates на batch), **не** 1000 готовых mutated inputs. Raw result: `docs/performance/engine-mutation-2026-10-04.term`. Это локальная оценка mutation, не сравнение с внутренней реализацией libFuzzer. Для текущего no-op потолка random mutation не является главным ограничением. Стадия `mutation` в worker для staged mode также замеряет `efz_mutation_plan:next/2` при profiling.

`efz_corpus:select/0` выполняется на каждой случайной iteration; `efz_worker:execute_allowed/4` считает SHA256 input; `efz_worker:retain/3` решает сохранение. При no novelty feedback возвращает `equivalent_coverage`, поэтому запись нового corpus entry не происходит. `corpus_decision` 86.1 µs/iteration в OTP run **включает** редкие discoveries и filesystem writes, поэтому не является чистой ценой no-novelty path. Выбор, hash и сохранение нуждаются в отдельном controlled benchmark при фиксированной истории для оценки I/O; текущие данные не дают надёжной оценки максимальной стоимости disk write.

## 8. Worker/guardian cost и top bottlenecks

Для no-op run top измеренные неперекрывающиеся подстадии:

| Stage | µs/iteration | Доля | Кандидат и риск | Предел при полном устранении |
|---|---:|---:|---|---:|
| Trace setup | 8924 | 56.4% | Spike reuse trace session; высокий риск для контроля descendants | 2.29× |
| Trace destroy | 3039 | 19.2% | Совместный spike с trace setup; высокий риск stale events | 1.24× |
| Shared-state check | 1736 | 11.0% | Замерить составляющие, затем искать эквивалент; высокий риск пропуска contamination | 1.12× |
| Cleanup wait | 595 | 3.8% | Сократить только при доказанной quiescence; высокий риск late writers | 1.04× |
| Executor outer/IPC | ~398 | ~2.5% | Замерить отдельно ожидание result/`DOWN`; средний риск | ~1.03× |

Пределы вычислены по Amdahl отдельно для каждой стадии и **не являются прогнозом** достижимого ускорения. Trace setup+destroy ~11.96 ms (~75.6%); устранение обеих без стоимости замены дало бы теоретический предел ~4.1× в этом run. Удаление их **без замены гарантий** недопустимо. Практический первый шаг — ограниченный spike по созданию/повторному использованию trace session с доказательством boundary; второй — профилирование `shared_state/0`. Это исследовательские задачи, не готовые изменения.

Bitmap short run дал 24.43 exec/s; его `target_us` 15.24 ms против 0.32 ms у ETS и 0.093 ms у OTP public. Истории мутирования расходятся и это не causal proof, но source-level hit path требует отдельного одинакового-input профиля до следующей оптимизации bitmap. Данный этап bitmap/ETS реализацию не менял.

## 9. EFZ и внешний erlang_fuzzer

| Свойство | EFZ | Внешний `erlang_fuzzer` | Влияние/переносимость |
|---|---|---|---|
| Mutation | Erlang random/staged | libFuzzer | Разные input histories; замена может изменить corpus evolution |
| Execution | guardian/root на testcase | in-process loop | EFZ дороже, но изолирует BEAM process tree |
| Process model | persistent worker, новый guardian/coordinator/root | persistent driver | Перенос persistent root меняет crash/timeout isolation |
| Coverage | EFZ probes или OTP lines | native coverage features | Разная семантика; counts не эквивалентны |
| Corpus/feedback | EFZ novelty и retention | libFuzzer policy | Прямое сравнение acceptance некорректно |
| Cleanup | kill, DOWN, trace barriers, shared checks | reset/reuse процесса | EFZ платит за quiescence и диагностику; не удалять без контракта |
| IPC | несколько сообщений и monitors | прямой вызов | Ожидаемая разница в overhead |
| Persistence | новая execution tree | in-process target повторно | Повторное использование может ускорить при другой модели безопасности |
| Crash/timeout | EFZ классификация в controlled tree | libFuzzer/NIF runtime | Разные гарантии и типы отказов |

Разрыв в 197× главным образом нельзя приписать одному компоненту. Наиболее очевидные 2–3 источника: per-testcase guardian/trace lifecycle, controlled process tree с IPC/cleanup, и полностью другая in-process mutation/feedback/corpus модель. Измерения подтверждают первый источник как большой внутри EFZ, но **не измеряют** его долю в разнице с `erlang_fuzzer` при идентичной истории входов.

## 10. Persistent execution design note

Worker уже persistent, а guardian/coordinator/root — нет. Один persistent root уменьшил бы spawn/monitor и, возможно, trace setup, но timeout/crash может оставить старые descendants, mailbox messages, native coverage writes и shared state. Для безопасного pool нужны per-execution capability, admission gate, поколение coverage context, доказанная quiescence, retirement загрязнённых процессов, restart на crash/timeout и детерминированные barrier tests. Стоимость этих механизмов надо измерить. Это отдельный design spike, не часть данного патча.

## 11. Решение по OTP API и дальнейшие шаги

Измеренный `get_coverage` — 0.081%, весь измеренный coverage pipeline — 0.398%, даже весь inclusive feedback — 2.1% итерации. Поэтому **оптимизация OTP coverage API сейчас не является главным источником потенциального ускорения EFZ**. Варианты compact binary и opaque check-and-advance стоит отложить. Следующий шаг: парный, повторяемый benchmark trace lifecycle на контролируемом хосте с `+S` sweep, затем узкий safety-preserving prototype сокращения trace setup/destroy. Второй кандидат — оптимизация проверки shared state после отдельного профиля. Решение о default `otp_native_public` не принимается: OTP line coverage не эквивалентно EFZ structural probes, а текущие 30-секундные прогоны не доказывают policy/quality equivalence. ETS остаётся default.

## 12. Проверки и ограничения

`rebar3 compile`, 3 focused EUnit, CT (3), xref, Dialyzer прошли. Полный EUnit под default 16 schedulers: 257 PASS, 2 timeout в существующих staged tests (`efz:await(10000/60000)`); под `ERL_FLAGS='+S 1:1'` полный EUnit: 259 PASS, а staged module: 8 PASS. Timeout связан с wall-clock budget этих tests на загруженном хосте; ожидания тестов не менялись. Профилированная и обычная короткие no-op кампании дали одинаковые input IDs и retention reasons в новом тесте. `cleanup.term` для none и OTP runs показывает `efz_fuzzer`, `efz_corpus`, `efz_stats` как `undefined` после остановки; долгосрочный leak check не выполнен. Данные `profile.term` ограничены 20k samples/stage, времена микросекундной точности и включают возмущение самим profiling; `--profile` следует использовать только для диагностики. Сравнение с внешним фуззером не контролирует одинаковые inputs, target invocation и safety policy.
