# Технический аудит bitmap coverage backend EFZ

Это исходный аудит bitmap-v1. Исправления и новые замеры описаны в
[отчёте bitmap-v2](coverage-bitmap-v2-results.md); исходные результаты ниже сохранены.

Дата: 2026-10-02. Область: текущая рабочая копия на `8b5cb05b5b57231b9133be13c883f25863e05d11` с уже существующими незакоммиченными изменениями. Код backend не исправлялся. Прочитаны [архитектура](coverage-bitmap-architecture.md), [план](plans/coverage-bitmap-implementation-plan.md), [отчёт о реализации](coverage-bitmap-implementation-report.md), исходники и тесты. Новые тесты и отдельный audit benchmark перечислены ниже.

## 1. Вывод

Для поддерживаемого режима `automatic` + `presence` bitmap без потерь представляет **те же структурные точки**, что ETS: ключ — полный `{Module,BuildId,ProbeId}`, slots уникальны, результаты ETS/bitmap совпали на одинаковой истории events и на seeded campaign. При нескольких допущенных processes разные биты одного слова сохраняет CAS loop. Production выделяет новую карту для каждого execution; late writer не может записать в следующую карту. Это доказательства в рамках *controlled descendants* EFZ, а не гарантия изоляции произвольных удалённых/внешних процессов.

**Ускорение не подтверждено.** На повторном парном запуске реального example parser campaign bitmap даёт меньший exec/s: медиана отношения bitmap/ETS `0.893`, bootstrap 95% интервал `[0.851,0.949]`. Редкий полный storage/feedback цикл особенно дорог. Default `ets` менять нельзя; `bitmap` допустим только как экспериментальный opt-in для профилирования и differential tests. Корректностных P0 blockers на проверенном пути не найдено; bitmap-specific dirty cleanup failure injection ещё не выполнен.

## 2. Фактическая архитектура и путь testcase

| Шаг | Функция и данные | Состояние, владелец и concurrency |
| --- | --- | --- |
| Подготовка кампании | [`efz_config:prepare_coverage/1`](../src/efz_config.erl#L85) preflight manifests/capacity; [`efz_worker:init/1`](../src/efz_worker.erl#L7) вызывает `efz_coverage:prepare_schema/2`, создаёт feedback/global. | Worker владеет protected ETS `FullId→Slot`, обратным tuple и immutable global binary. Один worker (`workers=1`), поэтому commit сериален. |
| Input/итерация | [`efz_worker:execute_checked/4`](../src/efz_worker.erl#L93) передаёт binary input, backend/schema и pinned plan в [`efz_executor:run/4`](../src/efz_executor.erl#L11). | Worker mutable state, corpus и mutation selection; backend не выбирает input. |
| Execution context | [`efz_guardian:start/6`](../src/efz_guardian.erl#L33) открывает `{efz_context,1,Ref,{bitmap,Schema,Words,Active},Owner}` через `efz_coverage:open/3`. | Guardian владеет отдельным unsigned atomics array и active flag на execution. |
| Привязка процессов | [`efz_guardian:admit/2`](../src/efz_guardian.erl#L53) и [`efz_target:spawn_owned/2`](../src/efz_target.erl#L9) запускают root/children через gate; [`efz_cov_bitmap:attach/1`](../src/efz_cov_bitmap.erl#L84) явно записывает context в process dictionary. | Несколько controlled writers разделяют одну карту. Обычный `spawn` не наследует context; trace обнаруживает его и делает runner dirty. |
| Instrumented target/hit | [`efz_instrument_pt:body/5`, `probe/4`](../src/efz_instrument_pt.erl#L112) вставляет `efz_cov_rt:hit({M,B,Id})`; [`efz_cov_rt:hit/1`](../src/efz_cov_rt.erl#L6) проверяет PID/context и передаёт полный ключ в `efz_coverage:hit/2` → `efz_cov_bitmap:hit/2`. | Hot path меняет одно 64-битное слово CAS; первый hit посылает guardian событие. Concurrent writers возможны. |
| Завершение | [`efz_guardian:cleanup/2`, `loop/1`](../src/efz_guardian.erl#L72) закрывает admission, убивает оставшихся controlled writers, ждёт `DOWN` и trace barriers; deadline даёт unconfirmed/dirty. | `DOWN` одного root не считается достаточным. Стабильность основана на завершении всей зарегистрированной группы и trace drain. |
| Observation | [`efz_guardian:finish/2`](../src/efz_guardian.erl#L172) вызывает [`efz_executor:coverage/3`](../src/efz_executor.erl#L123) для exact ID list/validation; для подтверждённого успешного результата отдельно берёт immutable `snapshot_bits/1`, затем закрывает map. | Два снимка допустимы только после quiescence. Публичный `Result.coverage` остаётся списком; `coverage_bits` внутреннее поле результата. |
| Novelty/global | [`efz_feedback:evaluate/3`, `bitmap_success/5`](../src/efz_feedback.erl#L21) проверяет статус/outcome, вычисляет `Local & ~Global`, декодирует new IDs и строит `Global | Local`. | Global — immutable 8 KiB binary в worker; сравнение и commit происходят последовательно. Crash/timeout не merge. |
| Corpus/failures | [`efz_worker:execute_result/6`, `retain/2`, `record_failure/4`](../src/efz_worker.erl#L101) использует прежний `retention_reason`; успешное новое покрытие добавляет input через `efz_corpus:add/2`, failures сохраняет отдельно. | Как и у ETS, global обновлён в feedback **до** записи corpus. Ошибка записи останавливает кампанию; это прежний порядок, не новое поведение bitmap. |
| Reset/release | Следующий `efz_guardian:start/6` создаёт новую карту; [`efz_cov_bitmap:close/1`, `reset/1`](../src/efz_cov_bitmap.erl#L151) не обнуляют global. [`efz_worker:terminate/2`](../src/efz_worker.erl#L345) удаляет schema ETS. | Старая mutable map не переиспользуется в production. Atomics освобождаются GC после исчезновения context references. |

Legacy проходит те же executor/guardian/feedback/worker policy этапы. Отличия: [`efz_cov_ets:open/2`, `hit/2`, `snapshot/1`](../src/efz_cov_ets.erl#L7) используют fresh public ETS table с `insert_new`, а [`efz_coverage:unseen/2`, `merge/2`](../src/efz_coverage.erl#L40) работают с exact Erlang sets/списками. Bitmap меняет storage и сравнение, сохраняя публичные identities и решения worker.

## 3. Identity, slots и instrumentation

[`efz_instrument_pt:parse_transform/2`, `probe/4`](../src/efz_instrument_pt.erl#L7) начинают локальный `ProbeId` с 1 и вставляют вызов с `{Module,BuildId,ProbeId}`; BuildId зависит от canonical forms, OTP/compiler и identity options (строки 37–55). [`efz_cov_manifest:identities/1`, `validate/1`](../src/efz_cov_manifest.erl#L4) сохраняют эту полную identity и запрещают неположительный/повторный локальный ID. Placement для function/case/if/receive/try/fun показан в [`body/5`, `expr/3`](../src/efz_instrument_pt.erl#L107) и проверен [`efz_phase2_tests:manifest/1`](../test/efz_phase2_tests.erl#L70); bitmap не изменял этот traversal. [`efz_phase2_tests:determinism/1`](../test/efz_phase2_tests.erl#L195) проверяет одинаковый BuildId при эквивалентной сборке и отличие при изменении макроса.

[`efz_cov_bitmap:validate_manifests/1`, `prepare/2`](../src/efz_cov_bitmap.erl#L23) валидируют manifests, запрещают повтор выбранного модуля и дубликаты IDs, сортируют *полные* identities и присваивают последовательные slots `0..N−1`. Protected ETS хранит `FullId→Slot`; tuple — `Slot→FullId`. Нет `ProbeId rem MapSize`, hash mask или усечения. Разные модули с одинаковым локальным ID получают разные slots. Две сборки одного модуля **не допускаются одновременно** в одну campaign; fingerprint содержит полную последовательность IDs и capacity. Равная каноническая сборка даёт те же slots; новая BuildId/schema требует новую campaign и не принимает старые bitmap snapshots (`unseen_bits/2`, `merge_bits/2`, строки 177–191). Corpus **input bytes** можно повторно запустить и рекалибровать после пересборки; старые coverage bits автоматически не импортируются.

Capacity: `N > Bits` возвращает `{bitmap_capacity_exceeded,#{required_bits,configured_bits}}` до кампании ([`check_capacity/2`](../src/efz_cov_bitmap.erl#L14), [`efz_config:prepare_coverage/1`](../src/efz_config.erl#L90)). `MapSize` как slot не возникает из валидированной схемы; неизвестный ID, отрицательный/огромный ID или чужой BuildId дают явный `unexpected_probe_or_build` в [`hit/2`](../src/efz_cov_bitmap.erl#L93). Повреждённый manifest отклоняется. Отдельные тесты: [`mapping_and_capacity_test/0`, `boundary_test/0`, `default_last_slot_test_/0`](../test/efz_bitmap_contract_tests.erl#L4), [`invalid_identity_test/0`](../test/efz_bitmap_audit_tests.erl#L7) и [`wide_differential/0`](../test/efz_bitmap_audit_tests.erl#L39).

## 4. Представление, hot path и concurrency

Default `coverage_bitmap_bits=65536`: 65 536 **бит**, 8 192 bytes payload, 1 024 слова по 64 бита. [`efz_cov_bitmap:open/1`](../src/efz_cov_bitmap.erl#L74) выделяет `atomics:new(Bits div 64,[{signed,false}])` и отдельный active flag. Slot `s` адресуется как `Word=s div 64+1` (atomics 1-based), `Mask=1 bsl (s rem 64)`. Значит slots `0,1,63,64,65,65535` соответствуют `word/bit` `1/0,1/1,1/63,2/0,2/1,1024/63`. Slot `65536` не выделен. Старший бит unsigned; [`cas_word/4`](../src/efz_cov_bitmap.erl#L119) повторяет CAS при stale read, сохраняя соседние биты. Детерминированный тест [`cas_stale_read_test/0`](../test/efz_bitmap_contract_tests.erl#L95) задерживает несколько writers после чтения одного `Old=0`, затем проверяет биты 0, 1 и 63; [`shared_writers_and_late_context_test/0`](../test/efz_bitmap_contract_tests.erl#L107) проверяет общий context. Простого небезопасного `get→OR→put` нет.

Один probe hit: [`efz_cov_rt:hit/1`](../src/efz_cov_rt.erl#L6) делает membership lookup в PID registry через [`efz_cov_integrity:expected/0`](../src/efz_cov_integrity.erl#L70), сверяет process dictionary, затем [`efz_coverage:hit/2`](../src/efz_coverage.erl#L20) вызывает [`efz_cov_bitmap:hit/2`](../src/efz_cov_bitmap.erl#L93). Последний дважды читает active flag, выполняет exact ETS lookup, вычисляет word/mask и вызывает CAS loop; при первом 0→1 посылает guardian сообщение. Конфигурация не читается, binary/list/set/map карты не создаются на hit, диагностика/source decode отсутствуют. Но `ets:lookup` в integrity registry и slot table возвращает Erlang terms; **hot path не allocation-free**. Для повторного hit benchmark показывает рост времени относительно `ets:insert_new`.

Production snapshot стабилен только после [`efz_guardian:loop/1`](../src/efz_guardian.erl#L72) с пустыми alive/barriers и остановленным coordinator, затем [`finish/2`](../src/efz_guardian.erl#L172). `snapshot_bits/1` сам читает слова последовательно и не является атомарным snapshot при живых writers ([`efz_cov_bitmap:snapshot_bits/1`](../src/efz_cov_bitmap.erl#L139)). `Active=0` тоже не закрывает гонку между проверкой и CAS. Production избегает записи в следующую iteration благодаря новой карте; при грязном cleanup runner не считается reusable. [`efz_isolation_tests`](../test/efz_isolation_tests.erl#L17) проверяют controlled descendants и timeout, [`shared_writers_and_late_context_test/0`](../test/efz_bitmap_contract_tests.erl#L107) — late hit в старый context после close/reset. Новые и старые mailbox messages помечены `Ref`, guardian принимает лишь свой `Ref` ([`loop_event/2`](../src/efz_guardian.erl#L138)); после завершения owner не переносит сообщения в другую карту.

`reset/1` выделяет fresh array, dirty-word list и epochs нет. Full clear реализован как [`clear_quiescent/1`](../src/efz_cov_bitmap.erl#L163) только для benchmark. Его проверка `Active=0` **не доказывает**, что writer не прошёл предыдущую проверку и не ждёт CAS: [`closed_clear_stale_cas_test/0`](../test/efz_bitmap_audit_tests.erl#L28) воспроизводит запись после clear. Это не production leak, потому что production не переиспользует массив. Название/API требуют явного предусловия join либо удаления из доступного интерфейса.

## 5. Novelty, global и fuzzing feedback

[`efz_cov_bitmap:wordwise/4`](../src/efz_cov_bitmap.erl#L193) вычисляет `Local band bnot Global` и `Local bor Global` по 64-битным словам, без conversion в sets. [`efz_feedback:bitmap_success/5`](../src/efz_feedback.erl#L42) декодирует **новые** bits для `new_probes` и `retention_reason`; после этого получает новый global. Сравнение не мутирует прежний global. *Early exit* при первом новом слове отсутствует: функция всегда строит полный difference binary; нынешнее API требует точный список всех новых probes. Даже при отсутствии novelty выполняются full scan, новый binary и decode по всем manifest IDs. Это измеримый fixed cost, описанный ниже.

Для истории `{} → {1,2} → {1,2} → {1,2,3} → {3} → {64,65} → {65}` результаты novelty должны быть `new, none, new, none, new, none`; реализованный побитовый оператор даёт именно эту последовательность, а [`wide_differential/0`](../test/efz_bitmap_audit_tests.erl#L39) сравнивает другую заданную историю с тем же правилом, включая пустой result, 63/64/65/65535, повторные hits, два модуля, crash и timeout. [`efz_feedback:evaluate/3`](../src/efz_feedback.erl#L13) пропускает merge только для `coverage_status=ok` и `{ok,_}`; crash/exit/timeout дают `target_failure` и оставляют global как был. Calibration успешного seed обновляет global, не вызывает повторного corpus add. [`efz_worker:retain/2`](../src/efz_worker.erl#L245) решает о corpus после feedback, а [`record_failure/4`](../src/efz_worker.erl#L256) классифицирует/saves failures отдельно. Те же границы у ETS branch (`efz_feedback:evaluate/3`, строки 30–39). Внешний `Result.coverage` остаётся exact ID list; `coverage_bits` удаляется из report/failure context через [`public_result/1`](../src/efz_worker.erl#L352).

## 6. Проверки и benchmark

Запускались **последовательно**, чтобы команды Rebar3 не компилировали одну `_build` одновременно:

| Команда | Результат |
| --- | --- |
| `ERL_FLAGS='+S 4:4' rebar3 eunit` | PASS, после audit tests **241** tests (см. лог `_build/bitmap-audit-eunit-final.log`) |
| `ERL_FLAGS='+S 4:4' rebar3 ct` | PASS, 3 tests |
| `ERL_FLAGS='+S 4:4' rebar3 xref` | PASS |
| `ERL_FLAGS='+S 4:4' rebar3 dialyzer` | PASS |
| `ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_bitmap_audit_tests` | PASS, 3 audit tests |
| `ERL_FLAGS='+S 4:4' escript bench/bitmap_bench.escript _build/bitmap-audit-benchmark` | PASS; [raw samples](performance/bitmap-audit-2026-10-02-existing-bench.txt) |
| `ERL_FLAGS='+S 4:4' escript bench/bitmap_audit_bench.escript docs/performance/bitmap-audit-2026-10-02-samples.term` | PASS; [raw samples](performance/bitmap-audit-2026-10-02-samples.term) |

OTP 27.0 / ERTS 15.0, Linux x86_64, i7-1260P, `+S 4:4`, Rebar3 3.25.0. Оба benchmark прогревались 2 пары, затем чередовали порядок ETS/bitmap в 10 парных повторах. Синтетический manifest: 1 024 probes, capacity 65 536 bits; parser campaign: seeded `efz_example_target`, 50 executions, corpus size 4, coverage size 5 во всех samples. Цифры ниже — median, microseconds, с min/max в raw artifacts. Встроенный benchmark отдельно собирает reductions и minor GC; парный audit script делает то же. SHA-256 скриптов: `bench/bitmap_bench.escript` `975240e42d32a96228d7c177f33053492904c2c9a3aaca1a71d766168e95266b`, `bench/bitmap_audit_bench.escript` `fdde7eea1345717f69e41863458b5f68f9970c06e41a35db19fb0c3511def29e`. Измерения проведены на одной машине, не доказывают результат для иных harness/OTP.

| Этап существующего benchmark | ETS | Bitmap |
| --- | ---: | ---: |
| 5 000 повторных hits | 824 | 1 413 |
| 64 sparse hits | 18 | 23 |
| 1 024 distinct hits | 629 | 768 |
| Snapshot 64 / 1 024 | 13 / 293 | 39 / 38 |
| Decode 1 024 IDs | 312 | 88 |
| Compare / merge 256 | 84 / 58 | 30 / 28 |
| Full clear после close | 0* | 19 |
| 10 sparse full cycles | 135 | 7 451 |
| 5 dense full cycles | 34 379 | 13 013 |
| 1 / 2 / 4 / 8 writers, one word | 4 367 / 8 345 / 12 169 / 26 675 | 4 377 / 8 656 / 11 904 / 32 422 |
| Parser campaign, 50 executions wall time | 116 842 | 125 835 |

`*` ETS stage создаёт новую table, не очищает её; 0 µs ниже полезного разрешения таймера. По медианам wall time для 50 executions это примерно **428 exec/s ETS** и **397 exec/s bitmap**. Медиана парных отношений exec/s `0.893`; bootstrap percentile 95% `[0.851,0.949]`, 10 000 resamples, seed `20261002`. Это замер example parser, не production harness. Полные cycles в отдельном audit script включают fresh context, hits, exact public observation, bitmap snapshot, novelty и merge:

| Hits/execution | ETS median (min–max), µs | Bitmap median (min–max), µs |
| --- | ---: | ---: |
| 1 | 4 (3–4) | 402 (347–452) |
| 100 | 97 (92–227) | 400 (286–546) |
| 1 000 | 3 054 (2 115–3 948) | 1 546 (725–2 125) |
| 10 000, cycle over 1 024 IDs | 8 509 (6 471–9 730) | 7 374 (6 338–9 449) |
| 10 000 hits of one ID | 6 045 (4 951–6 885) | 7 796 (7 309–8 219) |

Audit cycle intentionally excludes actual guardian process cleanup, mutation and corpus IO; parser campaign includes them. Для редкого покрытия фиксированная стоимость открытия карты, двух snapshot/decode и полного обхода карты/manifest доминирует; один `hit/1` не является единственным bottleneck. Для большого числа повторов hit path заметен: bitmap 1.7× медленнее ETS в 5 000-hit microbenchmark. Dense unique workload лучше у bitmap благодаря дешёвым wordwise compare/merge. Профиль затрат зависит от density; исследование OTP-native/JIT coverage нельзя обосновать этими данными до устранения fixed execution cost и измерения production harness.

Фактические компоненты памяти из `efz_cov_bitmap:memory/1` при 1 024 probes: atomics words **8 232 B**, active **48 B**, mapping ETS **20 084 VM words** (на этой VM по 8 B ≈160 672 B), reverse tuple `external_size` **58 633 B**. Global binary и один immutable snapshot по **8 192 B**; manifests/plan/context/allocator сверх этого. ETS execution table после 1 024 hits — **22 071 VM words**. `external_size` не RSS и размеры компонентов нельзя просто принять за полную память кампании. RSS и memory retention после многих кампаний здесь **NOT TESTED**.

## 7. Найденные проблемы и оценка

| Категория | Статус | Доказательство и ограничение |
| --- | --- | --- |
| Correctness | **PASS** | Collision-free mapping, bounds, high bit и разные сборки проверены кодом и тестами; silent coverage loss в проверенной области не обнаружен. |
| Concurrency safety | **PARTIAL** | **Medium:** production CAS сохраняет соседние биты, но экспортированный [`clear_quiescent/1`](../src/efz_cov_bitmap.erl#L163) проверяет лишь `Active=0`; stale writer после close/clear воспроизведён audit test. Не применять helper для reuse без join. |
| Execution isolation | **PARTIAL** | **Medium:** fresh map/Ref и controlled descendant timeout проверены, но bitmap-specific unconfirmed cleanup/guardian death не прогонялись в fresh VM. [`efz_guardian:finish/2`](../src/efz_guardian.erl#L172) использует общий lifecycle с ETS, однако нужен bitmap вариант [`efz_isolation_tests:fresh_vm/2`](../test/efz_isolation_tests.erl#L27) с принудительным cleanup deadline/guardian kill и проверкой отсутствия commit/reuse. |
| Semantic compatibility | **PASS** | Identical event history и seeded campaigns дают те же observed/new/global/corpus/crash/timeout decisions в тестах. |
| Performance | **FAIL** | **High:** parser campaign exec/s ratio `0.893`; 1-hit full cycle `402` против `4` µs. Источник: [`efz_guardian:finish/2`](../src/efz_guardian.erl#L172) делает exact decode и второй bitmap snapshot, [`efz_cov_bitmap:wordwise/4`, `decode/2`](../src/efz_cov_bitmap.erl#L193) обходят всю карту/схему, [`efz_feedback:bitmap_success/5`](../src/efz_feedback.erl#L42) делает это и при отсутствии novelty. Требуется profiling/упрощение fixed work перед default. |
| Memory efficiency | **PARTIAL** | **Medium:** payload 8 KiB, но mapping ETS ~160 KiB VM words и reverse external size ~58 KiB уже при 1 024 probes; [`prepare/2`, `memory/1`](../src/efz_cov_bitmap.erl#L23). Полный RSS/retention не измерены. Снять peak/RSS на повторных campaigns до rollout. |
| Maintainability | **PARTIAL** | **Medium:** [`snapshot_bits/1`](../src/efz_cov_bitmap.erl#L139) можно вызвать при живых writers; её собственный guard `Active=1` не делает результат стабильным. Production guardian соблюдает нужное условие, но API должен явно требовать quiescence либо выдавать snapshot только через lifecycle owner. |
| Observability/debuggability | **PARTIAL** | **Low:** [`efz_worker:finish/2`](../src/efz_worker.erl#L306) публикует exact IDs, однако нет отдельных phase timings для mapping/open, snapshot/decode, compare/merge и полного RSS. Воспроизвести parser benchmark и добавить счётчики затрат прежде чем оптимизировать. |

Дополнительный robustness gap (**medium**): [`efz_config:valid_field/2`](../src/efz_config.erl#L69) допускает произвольно большой положительный `coverage_bitmap_bits`, а [`efz_cov_bitmap:check_capacity/2`](../src/efz_cov_bitmap.erl#L14) проверяет только число probes `<= Bits`. Значение вроде `1 bsl 60` проходит этот check, но [`efz_cov_bitmap:new_global/1`, `open/1`](../src/efz_cov_bitmap.erl#L74) попытаются выделить огромные binary/atomics при старте worker/execution. Это явный сбой ресурса, не silent collision; следует ограничить конфигурацию поддерживаемым максимумом либо пробно выделить и освободить ресурсы до запуска кампании с понятной ошибкой.

## 8. Приоритет доработок

**P0 correctness blockers:** не найдены для проверенных automatic/presence сценариев. Перед расширением opt-in запуска нужен bitmap-specific fault injection для unconfirmed cleanup. При появлении расхождения event history или dirty cleanup без infrastructure result — немедленно откатиться на `coverage_backend => ets`.

**P1 performance/architecture:** (1) добавить phase timings в [`efz_guardian:finish/2`](../src/efz_guardian.erl#L172) и [`efz_feedback:bitmap_success/5`](../src/efz_feedback.erl#L42), снять профиль sparse parser и production harness; (2) если подтвердится fixed scan, получить exact ID list и bytes из одного stable прохода и избегать полного decode `NewBits` при доказанном нуле novelty, сохранив `new_probes` и commit order; (3) затем отдельно оценить два ETS lookup/active checks/CAS в повторном hit. Dirty words/epochs не вводить до измерений и нового concurrency gate.

**P2 robustness/observability:** (1) уточнить контракт или убрать benchmark-only `clear_quiescent/1`; (2) сделать boundary стабильного snapshot явным в API; (3) проверить верхнюю границу capacity до выделения и обрабатывать allocation errors; (4) провести bitmap-specific dirty cleanup fault injection; (5) публиковать peak RSS, active maps/schema ETS count при repeated campaigns. Эти задачи не меняют instrumentation и harness API.

## 9. Ответы на основные вопросы

- **Семантика старого EFZ сохранена?** Да, в протестированном automatic/presence режиме, включая success-only global merge и corpus/failure policy.
- **Есть silent coverage loss?** Не обнаружен: full identity проверяется exact lookup, overflow/unknown BuildId дают ошибки, CAS сохраняет соседние биты.
- **Несколько processes безопасны?** Да для controlled descendants и production fresh-map lifecycle; `clear_quiescent/1` сам по себе недостаточен для reuse.
- **Iterations изолированы?** Да в проверенных controlled timeout сценариях: у A и B разные atomics arrays; late hit A не может попасть в B. Bitmap-specific unconfirmed cleanup fault injection остаётся открытой проверкой.
- **Bitmap быстрее?** Не на измеренном parser campaign и sparse cycles; на dense unique stages встречается выигрыш.
- **Новый bottleneck?** На sparse input — фиксированное per-execution snapshot/decode/full-map work; на очень частых повторных hits — также сам Erlang `hit/1` с проверками и ETS lookup. Единый bottleneck для всех harness не установлен.
- **Готов к default?** Нет. Оставить экспериментальным opt-in, ETS — default/reference/rollback.
