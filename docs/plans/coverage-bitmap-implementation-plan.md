# План реализации bitmap coverage backend

Статус: P1–P7 реализованы и проверены 2 октября 2026 года; P0 performance baseline и P8 rollout не завершены. Подробные результаты — в [отчёте](../coverage-bitmap-implementation-report.md). Основа — [архитектурный документ](../coverage-bitmap-architecture.md), сверенный с текущими исходниками. Первая версия: `automatic` + `presence`, один EFZ worker, обычная сборка OTP, прежние структурные probes. `ets` остаётся default и reference; `ets_member` и ETS `hit_count` продолжают работать. Патчи OTP/ERTS, DWARF, NIF, edge coverage, hit-count buckets для bitmap, изменения harness и mutation engine исключены.

## Проверенная исходная точка и поправки к архитектуре

| Контракт | Доказательство в коде |
| --- | --- |
| `efz_instrument:compile_target/2` подключает `efz_instrument_pt`; `probe/4` вставляет `efz_cov_rt:hit({Module,BuildId,ProbeId})` в clause/outcome body. `ProbeId` нумеруется с 1 внутри каждой сборки модуля. | [`efz_instrument.erl`](../../src/efz_instrument.erl), [`efz_instrument_pt.erl`](../../src/efz_instrument_pt.erl) |
| Текущий вход hit проверяет PID/context и отправляет событие первого hit; ETS хранит точные identities. `efz_cov` даёт публичный compatibility API, `efz_coverage` уже dispatch, `efz_cov_ets` реализует storage и текущие set operations. | [`efz_cov_rt:hit/1`](../../src/efz_cov_rt.erl), [`efz_cov.erl`](../../src/efz_cov.erl), [`efz_coverage.erl`](../../src/efz_coverage.erl), [`efz_cov_ets.erl`](../../src/efz_cov_ets.erl) |
| Guardian создаёт новый context/table на execution; root и `efz_target:spawn[_link]/1` допускаются через gate и прикрепляются явно. Несколько writers пишут одну execution table. После timeout/завершения guardian прекращает admission, убивает оставшихся, ждёт `DOWN`/trace barriers и делает snapshot. Неуспешный cleanup помечает runner dirty. | [`efz_guardian:start/6`, `admit/2`, `cleanup/2`, `finish/2`](../../src/efz_guardian.erl), [`efz_target.erl`](../../src/efz_target.erl), [`efz_cov_integrity.erl`](../../src/efz_cov_integrity.erl) |
| `efz_feedback:evaluate/3` сравнивает `Observed − Global` и сливает **только** `coverage_status=ok`, `outcome={ok,_}`. Calibration обновляет global, но не добавляет seed повторно. Crash/exit/timeout не обновляют global. Corpus retention делает worker по `retention_reason`; crash artifacts — отдельный путь. | [`efz_feedback.erl`](../../src/efz_feedback.erl), [`efz_worker:execute_result/6`, `retain/2`, `record_failure/4`](../../src/efz_worker.erl), [`efz_corpus.erl`](../../src/efz_corpus.erl) |
| `rebar.config` требует минимум OTP 27, `warnings_as_errors`; локально проверены OTP 27.0 / ERTS 15.0, x86_64, Rebar3 3.25.0. `atomics` экспортирует `compare_exchange/4`, но не OR; unsigned array принимает и возвращает `1 bsl 63` и `2^64−1`. CAS возвращает `ok` при успехе и прежнее значение при несовпадении. Это локальная проверка API, а не performance proof. | [`rebar.config`](../../rebar.config); команды ниже |
| Тесты: `rebar3 eunit --module=efz_coverage_layer_tests,efz_backend_tests`, `rebar3 ct`, полный `rebar3 eunit`, xref/dialyzer. Интеграция: `efz_coverage_SUITE`, `efz_feedback_loop_tests`, `efz_isolation_tests`, `efz_backend_tests`. Bench: `scripts/coverage_bench.escript`, `bench/run.escript` (`hooks`, `executor`, `campaign`, `memory`, `startup`), `bench/profile.escript`. | [`test/`](../../test), [`bench/run.escript`](../../bench/run.escript), [`bench/efz_perf.erl`](../../bench/efz_perf.erl), [`scripts/coverage_bench.escript`](../../scripts/coverage_bench.escript) |

Проверка в этом сеансе: `ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_coverage_layer_tests,efz_backend_tests` — **18/18 PASS**. Это baseline существующего ETS, не проверка bitmap. Исходное дерево уже было dirty; логические и временные baseline нужно сохранять с точным commit/diff и отдельной директории результатов.

Воспроизведение проверки primitive на данной OTP без изменения файлов:

```sh
erl -noshell -eval 'A=atomics:new(1,[{signed,false}]), M=1 bsl 63, ok=atomics:compare_exchange(A,1,0,M), M=atomics:get(A,1), ok=atomics:compare_exchange(A,1,M,16#ffffffffffffffff), 16#ffffffffffffffff=atomics:get(A,1), io:format("~p~n",[atomics:module_info(exports)]), halt().'
```

Уточнения к первоначальной архитектуре внесены в неё: для первой версии bitmap + `hit_count` отвергается конфигурацией; signedness и CAS на проверенной OTP 27.0 конкретизированы. Ещё одна существенная деталь к реализации: нынешний `efz_coverage:unseen/2` и `merge/2` работают с Erlang sets/списками, а `Result.coverage` — список точных identities. Поэтому побитовое сравнение требует **внутреннего** snapshot наряду с прежним публичным списком; одной замены `hit/2` недостаточно. Текущий guardian даже при dirty cleanup может сформировать список Hits, но помечает `coverage_status` ошибкой; bitmap также не должен считать такой список стабильным/допустимым для commit.

## Окончательные решения для первой версии

### A. Schema и slot

Единственный ключ — `{Module, BuildId, ProbeId}` из валидированных manifests. При подготовке кампании [`efz_cov_manifest:prepare/2`](../../src/efz_cov_manifest.erl) остаётся источником allowlist/build pins; bitmap-подготовка строит отдельный **неизменяемый дескриптор схемы**, привязанный к этому plan. Сортировка по UTF-8 имени модуля, всем 32 байтам BuildId, затем положительному ProbeId; проверка уникальности; последовательные slots `0..N−1`. Worker владеет protected ETS `FullId → Slot`, а обратный массив/tuple `Slot → FullId` нужен только для snapshot/report. Сохранять полную identity в lookup: одинаковый `ProbeId` разных модулей/сборок получает разные slots. Build map и SHA-256 от versioned canonical sequence входят в schema fingerprint. Несовпадение schema/build — infrastructure error до сравнения; новые/неизвестные probes не игнорировать.

Fingerprint вычислять из явного format version, метрики `clause_outcome_probe`, версий manifest/instrumentation, capacity и канонической последовательности identities; не полагаться на неоговорённый порядок ETF map. Конфигурация `coverage_bitmap_bits`: default **65536 бит**, целое кратное 64; `N > capacity` — понятная ошибка подготовки с `required_bits` и `configured_bits`. Автоматического роста во время кампании нет. Пользователь может задать большую карту **до** старта. Неиспользуемые slots остаются нулём. Никаких `rem MapSize`, усечения или смешивания BuildId. Сохранённые corpus input bytes разрешено рекалибровать на новой сборке; coverage bitmap между сборками автоматически не переносится. Первая версия не добавляет формат сохранения global bitmap на диск.

### B. Mutable map и бит 63

Execution map — `atomics:new(Capacity div 64,[{signed,false}])`, 64-битные беззнаковые слова. Для `Slot ∈ [0,Capacity)` вычислять `Word = Slot div 64 + 1` (API atomics индексируется с 1) и `Mask = 1 bsl (Slot rem 64)`. Для slot 63 mask `2^63`, значение допустимо в unsigned array; slot 64 — слово 2, mask 1. Сначала проверять bounds и schema lookup, затем CAS-loop: `Old=atomics:get`, если `(Old band Mask) /= 0`, готово; иначе `compare_exchange(Ref,Word,Old,Old bor Mask)`; при `ok` — первый hit, при возвращённом текущем значении — повторить. При ошибке `badarg` уведомить guardian как backend failure. Событие `efz_cov_observed` отправлять **после** успешного 0→1 CAS, ровно один раз для данного бита. Нельзя заменять CAS на `get` + `put`. Для чтения и merge учитывать unsigned mask и последний word; `Slot >= N`/бит сверх схемы не является probe.

### C. Isolation, snapshot, reset

Guardian владеет **отдельной картой на execution** и сохраняет текущий `{efz_context,1,Ref,Storage,Owner}` как внешний wire shape; `Storage` становится opaque tagged handle. Context передаётся только через существующий `efz_guardian:admit/2` и `efz_coverage:attach/1`. Не полагаться на наследование process dictionary. PID registry и проверки в `efz_cov_rt:hit/1` сохраняются. После timeout guardian закрывает admission и завершает все controlled writers, включая descendants, ожидает `DOWN` и trace barriers, затем берёт snapshot. События первого hit/ошибки также должны быть drained/сверены с snapshot.

Флаг/epoch может быстро отвергать поздний hit, но проверка `active` перед CAS **не закрывает** окно между проверкой и записью. Безопасность обеспечивают уникальная карта execution, отсутствие переиспользования до доказанной quiescence и отказ от валидного snapshot/commit при неподтверждённом cleanup. После close поздний hit должен дать диагностируемую infrastructure error, но даже если гонка позволит CAS в **старую** карту, запись не сможет попасть в следующую iteration. При unconfirmed cleanup старую карту не очищать и не использовать повторно, runner retire; событие не становится success coverage. Первая реализация освобождает карту после подтверждённого snapshot, новая iteration выделяет новую: это безопасный production reset. **Full clear** (`atomics:put(...,0)` по всем словам) реализовать/измерить только для доказанно quiescent карты в тесте/benchmark; включать её reuse в production лишь если lifecycle докажет exclusive ownership. Dirty-word tracking и epochs — только после P8.

### D. Global и feedback

Worker остаётся единственным policy owner. [`efz_feedback:evaluate/3`](../../src/efz_feedback.erl) проверяет статус и outcome **до** вызова bitmap compare/merge. Для успешного presence result сравнение `Local & ~Global` даёт список новых точных identities для прежнего `new_probes`/`retention_reason`; после решения global получает `Global | Local`. Global первой версии — immutable binary с fingerprint в состоянии worker: новое значение строится **на iteration**, не на hit, и устанавливается только после успешного решения. Crash/exit/timeout и infrastructure result оставляют global без изменения. Не отдавать backend функцию, которая сама решает corpus retention. `efz_worker:retain/2` и `record_failure/4` остаются действующими. При будущем multi-worker понадобится сериализация compare-and-commit, сейчас `workers=1`.

### E. API, metadata, compatibility

Сохранить `efz_cov_rt:hit/1`, `efz_cov:open/0,/1,/2`, `attach/1`, `detach/0`, `snapshot/1`, `close/1`, manual API, `efz_executor:run/4`, `Result.coverage` (отсортированные exact IDs), `efz_feedback:evaluate/3` и публичный campaign report. Дополнить **внутренний** `efz_coverage:open/3` параметром validated schema, оставив `open/2` для ETS; добавить `prepare_schema/2`, `snapshot_bits/1`, `new_global/1`, `unseen_bits/2`, `merge_bits/2`, `decode_new/2` (точные имена допустимо скорректировать в P1, семантику — нет). Новые `-opaque bitmap_schema()` / `bitmap_context()` / `bitmap_snapshot()` должны скрывать atomics handle и schema fingerprint; descriptor version проверяется на каждом boundary. Для bitmap successful result передавать worker внутренний immutable `coverage_bits` с fingerprint, а обычный `coverage` декодировать при завершении execution для validation и reporting. Дополнительное поле low-level `run/4` не считается частью сохранённого формата: worker удаляет его перед crash/runtime artifact, failure context и campaign report; crash/timeout result его не несёт. Не путать это поле с существующим `coverage_observation` (classification map). Сравнение fingerprint обязательно для `unseen_bits/merge_bits`. Диагностика переводит set bits через reverse mapping в probe IDs и manifest source positions; текущие отчёты/краш-артефакты получают прежний список IDs.

Bitmap + `hit_count` и bitmap + `manual` отклонять на уровне `efz_config:prepare/1` и low-level `open/3` до выполнения target. `ets`/`ets_member` продолжают поддерживать оба текущих режима. Выбор backend не меняет instrumentation manifest и не переносит старое global coverage в новую кампанию.

## Этапы и условия приёмки

Команды выполняются из корня `efz`; для тестов/benchmark фиксировать `ERL_FLAGS='+S 4:4'`. Для каждого этапа: commit только его файлов после проверки, fallback — удалить/отключить добавленный путь, вернуть `coverage_backend => ets`, не мигрировать persisted coverage. Названия новых файлов ниже — предложения, существующие модули перечислены по реальным функциям.

| Этап | Конкретная работа и API | Зависит от | Проверка / наблюдаемый результат / приёмка | Откат |
| --- | --- | --- | --- | --- |
| **P0 Baseline** | Зафиксировать commit/diff, OTP и `erl:system_info`, manifests, exact history и решения для seeded fixtures. Добавить baseline fixture/запись events в `test/efz_backend_tests.erl` и новый `test/efz_bitmap_contract_tests.erl` без bitmap-ветки. Сохранить raw benchmark в `_build/bitmap-baseline/`, не в docs с историческими логами. API не менять. | Нет | `rebar3 compile`; `ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_coverage_layer_tests,efz_backend_tests`; `ERL_FLAGS='+S 4:4' rebar3 ct`; `ERL_FLAGS='+S 4:4' escript bench/run.escript all _build/bitmap-baseline reference`. Зафиксированы exact IDs, global/decisions, команды и raw samples; без утверждения ускорения. | Удалить только новые baseline fixtures/artifacts; production код не затронут. |
| **P1 Backend boundary** | Уточнить dispatch в `src/efz_coverage.erl` и legacy adapter `src/efz_cov_ets.erl`; сохранить делегирование `open/2`, `attach/1`, `hit/2`, `snapshot/1`, `close/1`, `unseen/2`, `merge/2`. Ввести внутренние типы/`open/3` с явным отказом `bitmap` без schema. Не менять `efz_cov_rt:hit/1`/`efz_cov` behavior. | P0 | Focused EUnit + `rebar3 xref`; legacy context shape, события, error/status и corpus decisions байт-в-байт/структурно совпадают с P0. | Вернуть dispatch к текущей версии. |
| **P2 Mapping** | `src/efz_cov_manifest.erl`: сохранить `prepare/2`/`validate_prepared/3`; новый подготовитель schema из validated manifests/plan. При необходимости `src/efz_cov_bitmap.erl` для immutable mapping; `src/efz_config.erl` — capacity validation позже, пока внутренний аргумент. Implement `FullId→Slot`, reverse map, fingerprint, overflow/unknown/mismatch errors. | P1 | `ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_bitmap_contract_tests,efz_backend_tests`; bijection, same local ID across modules, BuildId, 0/last/overflow. Ни одной коллизии. | Удалить mapping module/ветку, ETS plan не менять. |
| **P3 Storage** | `src/efz_cov_bitmap.erl`, `src/efz_coverage.erl`: unsigned atomics map, bounded slot lookup, CAS hit, first-hit event, `snapshot_bits/1`, full clear after quiescence. Внутренний opaque handle; `efz_cov_rt:hit/1` остаётся прежним. | P2; успешный ограниченный CAS spike ниже | Focused EUnit, синхронизированные два writers на один word, slots 0/63/64/last, repeated hit, unsigned high bit, malformed handle. Все биты/события точны; unsupported OTP прекращает подготовку. | Снять bitmap dispatch; ETS untouched. |
| **P4 Lifecycle** | `src/efz_guardian.erl:start/6,admit/2,cleanup/2,finish/2`, `src/efz_executor.erl:coverage/3`, `src/efz_worker.erl:executor_reference_options/1`, `src/efz_cov_integrity.erl`: передать schema в `open/3` также при `coverage_validation=per_execution`, дождаться quiescence до snapshot, проверить first-hit evidence, запретить reuse при dirty cleanup, диагностировать late hits. Не менять API `efz_target`. | P3 | `ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_backend_tests,efz_isolation_tests,efz_bitmap_contract_tests`; барьеры для hit-vs-timeout, child admission, cleanup failure, A→B→A. Только confirmed result имеет стабильный snapshot; dirty никогда не commit. | Отключить bitmap selection; guardian ETS branch прежний. |
| **P5 Comparison** | `src/efz_coverage.erl`: bitmap `new_global/1`, `unseen_bits/2`, `merge_bits/2`, `global_snapshot/1`, fingerprint checks; `src/efz_feedback.erl:new/3,evaluate/3`: новый внутренний initializer с schema, прежние `new/1,/2` сохраняются; presence branch сравнивает/сливает только успешный immutable snapshot; `src/efz_worker.erl:init/1,execute_checked/4,execute_result/6,record_failure/4`: создаёт schema/global, использует внутренние bits и удаляет их из persisted/report/failure-context metadata. Внешние `Result.coverage`, `new_probes`, retention_reason прежние. | P4 | Синтетическая единая event history через ETS/bitmap, `efz_feedback_loop_tests`; global после crash/timeout неизменен, calibration/mutation решения совпадают, mismatched snapshot error, в crash/replay файлах нет внутреннего bits payload. | Вернуть присутствие в ETS set path; corpus API не трогать. |
| **P6 Config/integration** | `src/efz_config.erl:valid_field/2,prepare_coverage/1`, `src/efz_worker.erl:init/1,executor_reference_options/1`, `src/efz_guardian.erl:start/6`, `docs/cli.md`: принять **API** config `bitmap` и `coverage_bitmap_bits`, reject manual/hit_count pair и over-capacity до execution. CLI запуска кампании сейчас не предоставляет backend flag; добавление его не требуется. Default `ets`. `efz_recipe:execute/5` и `efz_replay_cli` оставляют reference ETS replay входов, проверяя те же exact identities. Harness/mutator без изменений. | P5 | `ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_config_tests,efz_backend_tests,efz_cli_tests,efz_phase3_tests`; `ERL_FLAGS='+S 4:4' rebar3 ct`. API выбирает bitmap, CLI и replay с ETS сохраняют прежний результат, недопустимые пары дают стабильные ошибки. | Вернуть config allowlist `ets,ets_member`; replay path не менялся. |
| **P7 Differential acceptance** | `test/efz_bitmap_contract_tests.erl`, `test/efz_backend_tests.erl`, `test/efz_coverage_SUITE.erl`, `test/efz_feedback_loop_tests.erl`: одна заранее заданная event history для storage/feedback; затем те же fixtures/seeded campaigns на двух backend. Сравнить exact coverage, statuses, novelty, corpus IDs/content, crash/timeout evidence. | P6 | `ERL_FLAGS='+S 4:4' rebar3 eunit`; `ERL_FLAGS='+S 4:4' rebar3 ct`; `rebar3 xref`; `rebar3 dialyzer`. Ноль расхождений по контракту; недетерминированный real harness сравнивать по инвариантам/повторениям, не по побуквенному trace. | Переключить default на ETS, bitmap экспериментальную ветку выключить. |
| **P8 Benchmark/rollout** | Расширить `bench/efz_perf.erl`/`bench/run.escript` bitmap variant и отдельные `hit/clear/snapshot/compare/merge/full-cycle` workloads; `bench/profile.escript` для attribution. Измерить по протоколу ниже. Только при доказанной выгоде исследовать dirty words/epochs отдельным решением. Обновить `README.md`, `docs/coverage.md`, architecture status. | P7 | Raw samples, environment, parser/sparse/dense/repeat/multiwriter; correctness gate остаётся обязательным. Default меняется отдельным решением после performance gates; иначе bitmap остаётся opt-in. | Вернуть `coverage_backend => ets` default; сохранить bitmap opt-in или удалить при дефекте корректности. |

Команды для каждого gate (новые `efz_bitmap_contract_tests` и bitmap variant появляются на соответствующем этапе):

```sh
# P0
ERL_FLAGS='+S 4:4' rebar3 compile
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_coverage_layer_tests,efz_backend_tests
ERL_FLAGS='+S 4:4' rebar3 ct
ERL_FLAGS='+S 4:4' escript bench/run.escript all _build/bitmap-baseline reference
# P1
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_coverage_layer_tests,efz_backend_tests
ERL_FLAGS='+S 4:4' rebar3 xref
# P2, P3 and spike correctness
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_bitmap_contract_tests,efz_backend_tests
# P4
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_bitmap_contract_tests,efz_backend_tests,efz_isolation_tests,efz_integrity_tests
# P5
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_bitmap_contract_tests,efz_backend_tests,efz_feedback_loop_tests
# P6
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_config_tests,efz_backend_tests,efz_cli_tests,efz_phase3_tests
# P7
ERL_FLAGS='+S 4:4' rebar3 eunit
ERL_FLAGS='+S 4:4' rebar3 ct
ERL_FLAGS='+S 4:4' rebar3 xref
ERL_FLAGS='+S 4:4' rebar3 dialyzer
# P8 (после добавления bitmap variant в bench/run.escript)
ERL_FLAGS='+S 4:4' escript bench/run.escript all _build/bitmap-compare reference
ERL_FLAGS='+S 4:4' escript bench/run.escript all _build/bitmap-compare-bitmap bitmap
```

Для P8 дополнительно запустить новый stage с раздельными reset/snapshot/compare/merge, заданными seed и числом writers; имя stage и параметры закрепить в README benchmark до первого сравнения. В P0 не запускать ещё не существующий bitmap test/variant.

### Ограниченный spike перед P3

В отдельном тестовом файле/скрипте под `bench/` сравнить unsigned `atomics` CAS-loop и альтернативу с сериализованным ETS/counter owner **только** на корректности и стоимости shared-word contention. Проверить значения 0, `2^63`, `2^64−1`, `compare_exchange` success/failure, 1-based bounds; запустить 1/2/4/8 writers по барьеру на соседние биты, 10 повторов и сверку итоговых слов. Победитель: вариант, который сохраняет каждый бит и имеет измеряемую стоимость; при равной корректности оставить CAS как простой путь. Если unsigned CAS на поддерживаемой OTP не проходит — P3 заблокирован до выбора другого BEAM primitive; не переходить к `get+put`. Spike не меняет production API.

## Матрица проверок

`B` — bitmap, `E` — ETS reference. Для storage/feedback тестов подавать **одинаковую последовательность exact hit identities и завершений iterations** в оба backend. Для integration фиксировать binary inputs, seeds и manifest/builds; отдельные настоящие harness могут быть недетерминированными, поэтому их сравнивать по допустимым outcome/coverage инвариантам и повторениям, а не требовать одинаковый порядок scheduling.

| Сценарий | Метод / ожидаемый результат |
| --- | --- |
| Пустое покрытие | Confirmed attached execution: `[]`, `valid_empty_coverage`, `New=[]`; broken/unstarted отдельно и не принимается как пустое. E=B. |
| Повторный hit | Один slot остаётся 1, одно first-hit событие, snapshot содержит один ID. E=B. |
| Два разных бита одного слова | Два writers одновременно читают исходное 0 через тестовый barrier перед CAS; после разрешения обеих записей оба бита есть. Повторить с CAS retry. |
| Slots 0, 63, 64, последний | Проверить адрес `(0→word1,bit0)`, `(63→word1,bit63)`, `(64→word2,bit0)`, `(capacity−1→last)`; старший бит unsigned не становится отрицательным. |
| Capacity overflow | `N=capacity+1` отклоняется при prepare с required/configured; slot `capacity` hit отвергается, не wrap. |
| Локальный ID совпадает | `{M1,B1,1}` и `{M2,B2,1}` получают разные slots; другое BuildId того же module не сливается. |
| Schema/build mismatch | Подменить BuildId/fingerprint, plan или loaded code: ошибка до merge; Saved bitmap другой сборки не использовать. |
| Нет novelty; один/несколько новых битов | History `[A]→[A]→[A,B]→[B,C,D]`; new lists `A, [], B, C/D`; решения и порядок IDs совпадают E/B. |
| Global accumulation | После успешных `A`, `B` global=`{A,B}`; повтор не меняет; calibration обновляет global без повторного corpus add. |
| A→B→A | Три executions с независимыми картами; третий local=`{A}`, global=`{A,B}`. Full clear старой карты только после quiescence, никогда global. |
| Crash/timeout | Барьер гарантирует hit до crash/timeout; result содержит ID, global/corpus успеха не меняются, crash artifacts и counters прежние. |
| Поздний hit и failed cleanup | Задержать writer после проверки active, начать timeout/close, затем отпустить. Он не пишет в карту B следующей iteration; при отсутствии доказанной смерти A не имеет valid snapshot, runner dirty. Проверить порядок с барьерами, не одним stress. |
| Concurrent same-word hits | N controlled children получают один context, barrier перед первым CAS, конкурентно ставят соседние и одинаковые биты; итоговая popcount точна, first-hit evidence полон. Дополнительно stress 10⁴ циклов. |
| Переключение backend | Отдельные campaigns ETS→B→ETS с той же схемой/inputs дают одинаковые decisions; никакого переноса global по умолчанию. |
| Corpus decision | Seeded integration и replayed candidate stream: `retention_reason`, `new_probes`, additions/deduplication, crash/timeout classification равны E/B. `hit_count` на bitmap получает config error без target run. |

## Benchmark protocol и performance gates

1. Сначала P0: `ERL_FLAGS='+S 4:4' rebar3 compile`, затем `ERL_FLAGS='+S 4:4' escript bench/run.escript all _build/bitmap-baseline reference` и `ERL_FLAGS='+S 4:4' escript scripts/coverage_bench.escript`. Последний — исторический hook microbenchmark, не полная campaign стоимость. Сохранить raw `.term`, SHA-256 исходников/fixture, `git rev-parse HEAD`, `git diff --stat`, OTP/ERTS, `system_architecture`, wordsize, `schedulers_online`, JIT/flags и hardware. Не сравнивать с прежними опубликованными числами без одинаковой среды.
2. После P7 использовать одинаковые manifests и seeded event stream: sparse/dense sets, 1/8/64/1024+ distinct probes, разное число hit на execution, 90%+ повторных hit, 1/2/4/8 controlled writers с contention и без. Подготовка mapping измеряется отдельно от steady state; память включает atomics, ETS mapping, reverse map, context, manifest/plan, global state и process heap.
3. Замерять отдельно `hit` (первый и повторный), полный clear/reset, quiescence+snapshot, decode, comparison, merge, полный `reset→execute→collect→compare→commit` и end-to-end mutation exec/s на parser/loop/sparse и настоящем harness. Разделять время calibration, startup и steady mutation. Нормализовать corpus/outcome проверкой, не выкидывать ошибки/timeout из знаменателя молча.
4. Использовать одинаковый scheduler setting, прогрев, минимум 10 парных повторов с чередованием порядка E/B, отдельную VM при необходимости для очистки состояния. Публиковать все samples, median, min/max, paired ratios и bootstrap 95% interval; reductions, GC counts, allocated/process memory и `atomics:info(memory)`/ETS memory где доступны. Профиль `bench/profile.escript` — для объяснения затрат, не throughput result. Соседние процессы/thermal drift записывать как ограничение.
5. **Correctness gate:** все P7 тесты и матрица проходят, ноль потерянных битов, ноль смешанных схем, ноль изменённых corpus decisions. **Opt-in performance gate:** нет устойчивого ухудшения median end-to-end exec/s более 5% на каждом заранее выбранном representative workload; если есть, оставить экспериментальным и профилировать. **Default-switch gate:** помимо correctness, нижняя граница парного 95% интервала отношения bitmap/ETS по exec/s больше 1.0 на заранее выбранной основной workload и не ниже 0.95 на каждой другой representative workload; полный memory footprint и p95 latency опубликованы и не превышают заранее записанных лимитов кампании. Эти пороги — правила принятия решения, не ожидаемые результаты. При нестабильных измерениях default остаётся ETS. Любой correctness regression немедленно возвращает ETS.
6. Начальный reset — полный clear всех words только после quiescence. Dirty words/epochs вынести в новый opt-in эксперимент, если разложение времени покажет, что clear существенно влияет на полный цикл; повторить concurrency/lifecycle матрицу и benchmark после изменения.

## Definition of done и rollout

Фактический статус этапов: P0 **частично** (226 baseline EUnit и 3 CT пройдены, исторический `bench/run.escript all` прерван после более трёх минут без результата); P1–P7 **реализованы** и прошли последовательные проверки; P8 **частично** (парный micro/campaign benchmark выполнен отдельным `bench/bitmap_bench.escript`, performance gate на parser не достигнут, default не переключён). Отдельный benchmark driver вместо bitmap variant в `bench/run.escript` — осознанное узкое отклонение; benchmark старого драйвера всё ещё нужен для сопоставления исторических workloads. См. [отчёт](../coverage-bitmap-implementation-report.md).

- [x] Exact instrumentation identities и source mapping неизменны; bitmap выбирается только для automatic/presence.
- [x] Mapping injective, versioned fingerprint и capacity errors проверены; несовместимые builds не смешиваются.
- [x] CAS для bit63/word boundaries и controlled concurrent writers проверен тестами; first-hit integrity не потеряна в проверенных сценариях.
- [x] Snapshot только после confirmed quiescence; late hits/dirty cleanup не дают valid commit или reuse для controlled descendants.
- [x] `Result.coverage`, feedback, global, corpus и crash/timeout decisions совпадают с ETS в реализованной матрице.
- [x] `rebar3 compile`, полный `rebar3 eunit`, `rebar3 ct`, `rebar3 xref`, `rebar3 dialyzer` проходят на поддерживаемой OTP.
- [ ] Полный P8 protocol: опубликованы raw samples, но остаются исторический baseline, production harness, полный RSS/p95 и confidence intervals.
- [x] Default остаётся ETS до отдельного решения по performance gates; rollback одним config selector, без миграции сохранённого coverage.

Рекомендуемый rollout: внутренний low-level тест → opt-in `coverage_backend => bitmap` для автоматической presence campaign → differential CI на обоих backend → измерения на реальном harness → отдельное решение о default. При обнаружении расхождения немедленно вернуть `ets`, сохранить failing event history и map/schema metadata для воспроизведения. Входы corpus могут быть переиспользованы с новой рекалибровкой; сохранённые coverage bits — только при полном совпадении fingerprint, иначе не импортировать.

## Первые задачи агенту реализации

1. **P0:** зафиксировать воспроизводимую event history и ETS baseline в `test/efz_backend_tests.erl`/новом contract test, сохранить raw benchmark и environment; не менять production path.
2. **P1:** закрепить внутренний `efz_coverage` dispatch/type contract с неизменным ETS поведением и focused EUnit.
3. **P2:** реализовать schema mapping + fingerprint + capacity errors с bijection/boundary тестами; hit path пока не подключать.
4. **Spike/P3:** проверить unsigned CAS на OTP 27 и реализовать atomic bit set с управляемым concurrent test, затем интегрировать execution map.

Каждая задача имеет отдельный проверяемый результат; следующая начинается после прохождения gate предыдущей.
