# Bitmap coverage v2: реализация и измеренный результат

[English](../../coverage-bitmap-v2-results.md) · **Русский** · [Español](../es/coverage-bitmap-v2-results.md) · [简体中文](../zh-CN/coverage-bitmap-v2-results.md) · [Все языки](../README.md)

Дата: 2026-10-02. Это продолжение [аудита v1](coverage-bitmap-audit.md), а не
замена его baseline. Bitmap остаётся явным opt-in; `ets` остаётся default.

## Изменения и границы

* [`efz_worker:init/1`, `execute_checked/4`](../../../src/efz_worker.erl) выделяют одну execution map на bitmap campaign и передают её каждому guardian. Итоговый campaign report включает `bitmap_storage`: одну выделенную map, arm count и normal reuse count. Worker исполняет итерации синхронно и не активирует map, пока `efz_executor:run/4` не получит итоговый `DOWN` guardian.
* [`efz_guardian:finish/2`](../../../src/efz_guardian.erl) запечатывает compact successful bitmap observation только после достижения `confirmed` существующей процедурой cleanup controlled descendants: admission остановлен, все известные descendants и coordinator завершены, process и global trace barriers доставлены, runtime sampler остановлен. Failed или unconfirmed cleanup помечает runner dirty. Гибель guardian также преобразуется в dirty runner через [`efz_executor:guardian_failed/2`](../../../src/efz_executor.erl). Ни одна map такого execution не активируется повторно; кампания останавливается. Late writer ещё может изменять свой **retired** allocation после гибели guardian, но не может писать в map следующего execution. Контракт покрывает admitted local descendants, а не произвольные remote или uncontrolled processes.
* [`efz_cov_bitmap:allocate/1`, `open/2`, `seal/1`](../../../src/efz_cov_bitmap.erl) используют reusable unsigned массив words `atomics`, active state и generation number. `open/2` полностью очищает 1,024 words default map из 65,536 bits и увеличивает generation. Sealed token прежней generation отклоняется даже после seal последующего execution. Одного `Active=0` **недостаточно** как evidence quiescence writers; это evidence предоставляет guardian lifecycle. Прежние `open/1`, `snapshot_bits/1`, `reset/1` и immutable snapshot path остаются для low-level differential tests и fallback.
* [`efz_cov_bitmap:has_new/2`](../../../src/efz_cov_bitmap.erl) сканирует words через `Current AND NOT Global`, выходя на первом новом word. [`efz_feedback:bitmap_sealed_success/5`](../../../src/efz_feedback.erl) не меняет global, когда нет new bit; при novelty декодирует только **новые** bits для существующего exact решения `new_probes`, затем отдельно выполняет wordwise global merge. Crash, exit, timeout и infrastructure outcomes по-прежнему не объединяются. Feedback module обращается к bitmap operations через [`efz_coverage`](../../../src/efz_coverage.erl).
* Обычный success path кампании больше не материализует полный bitmap snapshot или все observed probe IDs. First-hit messages остаются в integrity accounting guardian; wordwise bit count подтверждает совпадение их числа с sealed map. [`efz_cov_integrity:observation_count/3`](../../../src/efz_cov_integrity.erl) сохраняет observation classification/count. Старый exact list по-прежнему создаётся для failures, low-level executor calls и campaigns с включёнными runtime oracles. Итоговый global report по-прежнему декодирует exact IDs. Instrumentation, harness API, mutation engine, crash classification и corpus acceptance не менялись.
* [`efz_config:valid_field/2`](../../../src/efz_config.erl) отклоняет capacity больше 2^26 bits (8 MiB payload) до старта кампании; capacity остаётся положительной и кратной 64. Default — 65,536 **bits** (8 KiB payload). Default allocation v2 использует около 8,232 bytes для words плюс 56 bytes для active/generation atomics, плюс schema, reverse IDs, binaries, Erlang terms и allocator overhead.

## Машина состояний изоляции и reuse

`карта во владении worker (inactive) → guardian: arm/полная очистка → управляемые процессы записи → подтверждённая очистка guardian → seal → сравнение в worker → опциональный commit → решение о корпусе → следующий arm`.

Sealed map не меняется, пока feedback её читает, поскольку worker не начинает
следующее execution до завершения этого шага feedback/corpus. Если cleanup
unconfirmed или guardian погибает, runner становится dirty, а старая map выводится
из использования вместе с worker/VM; последующее execution в этом runner
отклоняется. Новый runner/campaign выделяет новую map. Generation предотвращает
случайные чтения через stale sealed tokens. Одна active check не закрывает
check-to-CAS race и не используется как доказательство reclamation. Завершение
controlled writers и вычитка traces остаются фактической границей seal.

## Проверка

Baseline до изменений: 241 EUnit PASS. После v2: 243 EUnit PASS, 3 CT PASS,
xref PASS, Dialyzer PASS. Команды:

```sh
ERL_FLAGS='+S 4:4' rebar3 eunit
ERL_FLAGS='+S 4:4' rebar3 ct
ERL_FLAGS='+S 4:4' rebar3 xref
ERL_FLAGS='+S 4:4' rebar3 dialyzer
```

[`efz_bitmap_audit_tests`](../../../test/efz_bitmap_audit_tests.erl) добавляют 10,000
A/B re-arms одной map, стабильный размер atomics allocation, отклонение stale
generation, управляемый barriers late writer retired map и сравнение ETS/v2
feedback для success, repeated coverage, crash и timeout.
[`efz_isolation_tests`](../../../test/efz_isolation_tests.erl) добавляют fresh-VM bitmap
случай гибели guardian: cleanup unconfirmed, runner dirty и отказывает следующему
execution. [`efz_bitmap_contract_tests`](../../../test/efz_bitmap_contract_tests.erl)
проверяют campaign map allocation/reuse counts и отклонение invalid capacity.
Существующие full differential tests продолжают сравнивать observed IDs, novelty,
global coverage и corpus decisions. Эти тесты не вызывают настоящий выход за
cleanup deadline в живой VM; гибель guardian детерминированно проверяет
unconfirmed/retirement path.

## Протокол benchmark и результаты

Команды (raw files сохранены рядом с отчётом):

```sh
ERL_FLAGS='+S 4:4' escript bench/bitmap_bench.escript _build/bitmap-v2-benchmark-final-code
ERL_FLAGS='+S 4:4' escript bench/bitmap_audit_bench.escript _build/bitmap-v2-baseline-full-cycle.term
ERL_FLAGS='+S 4:4' escript bench/bitmap_v2_cycle_bench.escript docs/performance/bitmap-v2-cycle-2026-10-02.term
ERL_FLAGS='+S 4:4' escript bench/bitmap_v2_components.escript docs/performance/bitmap-v2-components-2026-10-02.term
```

Среда: OTP 27.0, ERTS 15.0, Linux x86_64, Intel Core i7-1260P, `+S 4:4`.
Парные campaign и full-cycle drivers используют две warmup pairs и 10
чередующихся pairs. Component driver использует два warmups и десять samples
по 100, 1,000 или 10,000 calls. Parser campaign выполняет 50 seeded random-mutator
executions на `efz_example_target`/`efz_example_parser`; corpus size 4 и итоговый
coverage size 5 совпали в каждом sample. Это короткие локальные измерения;
CPU frequency/scheduler noise и один harness ограничивают обобщение. Измерения
v1 сделаны до изменений кода в том же checkout и сохранены как
[v1 campaign/micro raw data](../../performance/bitmap-v2-v1-baseline-2026-10-02.term)
и [v1 full cycles](../../performance/bitmap-v2-v1-full-cycle-2026-10-02.term).
V2 campaign/micro [run 1](../../performance/bitmap-v2-2026-10-02-samples.term),
[run 2](../../performance/bitmap-v2-2026-10-02-final-samples.term) и
[final-code run 3](../../performance/bitmap-v2-2026-10-02-final-code-samples.term),
трёхсторонние [full cycles](../../performance/bitmap-v2-cycle-2026-10-02.term) и
[component data](../../performance/bitmap-v2-components-2026-10-02.term) сохранены отдельно.

Медианы, микросекунды, если не указано exec/s:

| Нагрузка | ETS | bitmap-v1 | bitmap-v2 |
|---|---:|---:|---:|
| Parser campaign, exec/s | 362 / 264 | 325 | 255 |
| Full cycle, 1 hit | 4 | 411 | 195 |
| Full cycle, 100 hits | 106 | 432 | 250 |
| Full cycle, 1,000 hits | 2,832 | 985 | 773 |
| Full cycle, 10,000 hits | 9,685 | 7,143 | 6,939 |
| Full cycle, 10,000 repeated hits | 5,805 | 10,479 | 8,731 |
| Repeated hit stage, 5,000 hits | 927 / 1,887 | 1,546 | 2,928 |
| Full clear / arm | <1 (новая ETS table) | 21 (clear-only benchmark) | 15.01 (clear plus arm, 100 calls/sample) |
| Novelty, 256 local/128 global | 82 (exact new IDs) | 27 (new bitmap) | 0.197 (boolean early exit) |
| Merge, 256 local/128 global | 57 | 28 | 43.72 |

Для parser и repeated hits разделённые slash значения ETS — baseline v1 и
paired run итогового кода v2; они **не** взаимозаменяемые знаменатели. Median wall
time v1: 153,702 µs bitmap против 138,236 µs ETS; для итогового кода v2 — 195,798
против 189,237 µs. Median paired bitmap/ETS exec/s ratios: **0.881** v1 и **0.974**
final v2 (по 10 pairs). Два других paired ratios v2 — **0.938** и **0.984**;
исходный аудит сообщал 0.893 по более раннему независимому запуску. Запуски v2
показывают существенный wall-time variation и отсутствие надёжного выигрыша на
parser. Строки трёхсторонних full cycles относятся к одному paired run и прямо
сопоставимы как algorithms, но этот run использует небольшое изменение
repeated-hit из source v2 для обоих bitmap paths; нетронутые исторические
full-cycle medians v1 составляют соответственно 419, 431, 1,852, 8,844 и 8,517 µs.
Строка novelty намеренно сообщает разные return contracts: ETS возвращает exact
IDs, v1 материализует новый bitmap, v2 возвращает лишь boolean; v2 декодирует
exact new IDs только после `true`. В строках reset различаются operations, а
время ETS меньше микросекунды; для reset cost используйте component measurements,
а не speedup ratio.

Component medians v2 (µs/call, min–max в raw data): full clear/arm **15.01**,
sealed count sparse **25.83**, sealed count dense **53.39**, no-novelty sparse
**24.00**, no-novelty dense **23.47**, novelty first word **0.084**, novelty last
map word **23.27** и 256-slot merge **43.72**. Этап 5,000 repeated hits остаётся
медленнее ETS во всех v2 runs: 1,486 против 998 µs, 1,361 против 890 µs и
2,928 против 1,887 µs.

В изолированных component samples по 10,000 calls process-dictionary lookup
занял **0.007 µs/call**, integrity registry lookup **0.210**, exact slot ETS lookup
**0.100**, atomic read **0.021**, а полный repeated `efz_cov_rt:hit/1` **0.431**;
эти раздельно измеренные costs не строго аддитивны. В этой подготовке нет
guardian registry, поэтому integrity measurement проходит missing-registry
branch, а не registered production writer. Repeated-hit path всё ещё платит
за оба ETS lookups и guards, хотя bit уже установлен. Эти lookups и full-map
count/no-novelty scans — оставшиеся измеренные узкие места sparse executions.
Default full clear проще и дешевле совокупной sparse count/check cost;
dirty words не добавлены, поскольку они нагрузили бы каждый hit и потребовали
отдельного concurrent bookkeeping design и сквозного выигрыша.

## Решение и оставшаяся работа

Correctness и feedback compatibility: **PASS** для проверенного controlled-process
контракта. Concurrency/isolation: **PASS** для admitted local descendants,
confirmed cleanup и dirty-runner retirement; uncontrolled remote processes
остаются вне существующего контракта EFZ. Memory: **PARTIAL**: обычная кампания
выделяет одну map, и 10,000 reuse cycles сохраняют размеры atomics постоянными,
но long-running RSS study не выполнялось. Performance: **FAIL** для
default-switch gate: v2 улучшает paired parser ratio, но paired median остаётся
ниже 1 во всех трёх runs с большим разбросом, а repeated hits медленнее.
Maintainability: **PARTIAL**: v1 и compact paths намеренно сосуществуют для
differential comparison; compact path связан с lifecycle, как описано выше.

Сохранить `coverage_backend => ets` как default. Bitmap-v2 доступен только по
явному `coverage_backend => bitmap` для automatic presence. Rollback — удалить
эту опцию или задать `coverage_backend => ets`. До пересмотра default повторить
paired parser и дополнительные representative harness campaigns, выполнить
long campaign RSS/resource test и профилировать, что доминирует в этих workloads:
hit lookup или sparse full-map scans. Не вводить dirty-word tracking или
OTP-native coverage без отдельного измеренного обоснования correctness/performance.
