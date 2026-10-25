# Bitmap coverage backend: отчёт о реализации

[English](../../coverage-bitmap-implementation-report.md) · **Русский** · [Español](../es/coverage-bitmap-implementation-report.md) · [简体中文](../zh-CN/coverage-bitmap-implementation-report.md) · [Все языки](../README.md)

Исторический baseline bitmap-v1. Текущий campaign path повторно использует
sealed map; см. [продолжение bitmap-v2](coverage-bitmap-v2-results.md).
Измерения и утверждения об отсутствии reuse ниже описывают v1 на момент отчёта.

Дата: 2026-10-02. Checkout: `8b5cb05b5b57231b9133be13c883f25863e05d11` плюс существовавшие uncommitted changes. Эта работа не перезаписывала посторонние dirty files и не меняла default backend. [Архитектура](coverage-bitmap-architecture.md) и [план](plans/coverage-bitmap-implementation-plan.md) определяют предполагаемый контракт.

## Реализовано

| Граница | Файлы и API |
| --- | --- |
| Mapping/storage | [`efz_cov_bitmap.erl`](../../../src/efz_cov_bitmap.erl): `prepare/2`, `open/1`, `hit/2`, `snapshot_bits/1`, `reset/1`, `close/1`, `release/1`, `unseen_bits/2`, `merge_bits/2`, `decode/2`. |
| Dispatch | [`efz_coverage.erl`](../../../src/efz_coverage.erl): внутренние `open/3`, `prepare_schema/2`, `new_global/1`, `snapshot_bits/1`, побитовое сравнение/объединение и diagnostic decode. Существующий ETS API сохранён. |
| Выбор/lifecycle | [`efz_config.erl`](../../../src/efz_config.erl) разрешает bitmap только для automatic presence и проверяет capacity до кампании; [`efz_worker.erl`](../../../src/efz_worker.erl) владеет schema/global и удаляет internal bits из persisted results; [`efz_guardian.erl`](../../../src/efz_guardian.erl) собирает bits после cleanup контролируемых writers; [`efz_executor.erl`](../../../src/efz_executor.erl) проверяет schema/build pins; [`efz_feedback.erl`](../../../src/efz_feedback.erl) применяет существующую success-only commit policy. [`efz_instrument_pt.erl`](../../../src/efz_instrument_pt.erl) исключает новый внутренний module из target instrumentation. |
| Тесты/измерения | [`efz_bitmap_contract_tests.erl`](../../../test/efz_bitmap_contract_tests.erl), bitmap cases в [`efz_isolation_tests.erl`](../../../test/efz_isolation_tests.erl), парный [`bitmap_bench.escript`](../../../bench/bitmap_bench.escript), [raw samples](../../performance/bitmap-2026-10-02-samples.txt). |

Instrumentation по-прежнему выдаёт `efz_cov_rt:hit({Module,BuildId,ProbeId})`;
harnesses и mutation operators не обращаются к backend. Worker подготавливает
защищённую ETS table `FullId → Slot` из проверенных manifests, сортируя full IDs
по UTF-8 module name, всем 32 bytes BuildId и ProbeId. Он отклоняет duplicates
и `N > coverage_bitmap_bits`. Versioned SHA-256 fingerprint включает metric,
schema/instrumentation versions, capacity и canonical identities. Unknown hits
и несовместимые fingerprints явно дают ошибку. Default **65,536 bits** требуют
**8 KiB payload**, плюс atomics, mapping, reverse tuple, context и allocator
overhead. Нет modulo, hashing или импорта bitmap между builds.

Каждый controlled execution получает уникальный unsigned массив words `atomics`
и active flag. Admitted process явно получает context через существующий
guardian gate. Slot `s` использует atomics index `s div 64 + 1` и маску
`1 bsl (s rem 64)`; `compare_exchange/4` повторяет попытку при stale reads,
включая bit 63. Guardian уже прекращает admission, завершает controlled
descendants и ждёт `DOWN`/trace barriers до snapshot. Одна проверка active flag
не закрывает check-to-CAS race, поэтому production никогда не использует старую
mutable map повторно. Confirmed results получают immutable snapshot 8 KiB;
unconfirmed cleanup — infrastructure failure и не может выполнить commit.
`reset/1` выделяет новую map. `clear_quiescent/1` — лишь измеренный primitive
для callers, отдельно доказавших остановку всех writers. Worker владеет
immutable global snapshot и последовательным compare/commit. Его меняет лишь
корректный result `{ok,_}`; crash, exit и timeout сохраняют существующие
classification/artifact behavior без global merge. Публичные observations и
reports сохраняют exact IDs; diagnostic decode выполняется вне hit path.

## Валидация

До реализации: `ERL_FLAGS='+S 4:4' rebar3 compile`, полный `eunit` (**226 passed**),
`ct` (**3 passed**), `xref` и `dialyzer` прошли. Старый
`bench/run.escript all _build/bitmap-baseline reference` оставался в длительном
этапе `hooks` более трёх минут и был прерван; у него **нет полного baseline
result**. Исторический
`ERL_FLAGS='+S 4:4' escript scripts/coverage_bench.escript` запускался после
реализации и прошёл, но это instrumentation hook microbenchmark, а не сквозное
сравнение bitmap. Ранний параллельный запуск Rebar3 после изменений провалил
20 fresh-VM EUnit cases с `undef`, пока несколько команд компилировали в общее
build tree, а Dialyzer сообщил spec warning для явного исключения. После
последовательного запуска и spec `no_return()` результаты были такими:

| Команда | Результат |
| --- | --- |
| `ERL_FLAGS='+S 4:4' rebar3 compile` | PASS |
| `ERL_FLAGS='+S 4:4' rebar3 eunit` | PASS, 238 tests |
| `ERL_FLAGS='+S 4:4' rebar3 ct` | PASS, 3 tests |
| `ERL_FLAGS='+S 4:4' rebar3 xref` | PASS |
| `ERL_FLAGS='+S 4:4' rebar3 dialyzer` | PASS |

Contract tests покрывают empty и repeated observations, slot 0/63/64/last,
overflow, одинаковый local ID в двух modules, несовместимые builds/snapshots,
one/multiple/no new bits, A→B→A, global isolation, success/crash/timeout feedback,
детерминированный stale-read CAS retry, shared writers и late contexts.
Controlled descendant и timeout tests используют messages/barriers, а не только
sleeps. Seeded ETS→bitmap→ETS campaigns сравнивают корпус и exact coverage
decisions; low-level executor tests сравнивают равные event histories. Это не
доказывает изоляцию произвольного raw `spawn` или remote processes, которыми
существующий EFZ guardian не владеет.

## Benchmark

Команда: `ERL_FLAGS='+S 4:4' escript bench/bitmap_bench.escript _build/bitmap-benchmark`.
Raw per-sample time, reductions и minor GC data:
[bitmap-2026-10-02-samples.txt](../../performance/bitmap-2026-10-02-samples.txt).
Driver делает два warmups, берёт 10 чередующихся paired samples на stage и хранит
binary term в `_build/bitmap-benchmark/bitmap-benchmark.term`. Среда: OTP 27.0,
ERTS 15.0, Rebar3 3.25.0, Linux x86_64, Intel i7-1260P, `+S 4:4`; bitmap 65,536
bits, 1,024 synthetic manifest probes. Script SHA-256
`975240e42d32a96228d7c177f33053492904c2c9a3aaca1a71d766168e95266b`;
bitmap module SHA-256
`e1e5d44bc248c031b8724bb99c1d8bd34109cb1a3a048989e8e2b31398b1fa99`;
parser fixture SHA-256
`c834f09eb2bbeabf54c2948ad849ab0f9294e2e455f35ead54d75f589be35747`.

| Этап (медиана микросекунд) | ETS | Bitmap |
| --- | ---: | ---: |
| 5,000 repeated hits | 825 | 1,401 |
| 64 sparse hits | 18 | 23 |
| 1,024 distinct hits | 650 | 775 |
| 64-hit snapshot | 15 | 37 |
| 1,024-hit snapshot | 284 | 41 |
| Decode 1,024 IDs | 324 | 85 |
| Quiescent full clear | 1* | 18 |
| Compare 256 bits/IDs | 84 | 29 |
| Merge 256 bits/IDs | 58 | 28 |
| Ten sparse full cycles | 124 | 6,826 |
| Five dense full cycles | 23,418 | 11,310 |
| 1/2/4/8 writers in one word | 3,925 / 7,758 / 16,061 / 28,523 | 4,499 / 7,825 / 16,324 / 29,044 |
| 50-execution parser campaign wall time | 116,580 | 129,445 |

`*` Сравнение ETS — создание новой table, а не clear; 0–1 µs ниже полезного
разрешения таймера. Parser workload использует `efz_example_target`, seeded
random mutator, фиксированные 50 executions, тот же corpus size 4 и reported
coverage size 5 в каждом sample. Его bitmap/ETS exec/s ratio по median wall
times — около **0.90**; median 10 paired exec/s ratios — **0.887**, с percentile
bootstrap 95% interval **[0.825, 0.985]** (10,000 resamples, seed `20261002`).
Parser wall-time p95 (nearest rank из 10 samples) — **145,333 µs ETS** и
**144,728 µs bitmap**. Sparse full cycle существенно хуже; dense bitmap
compare/snapshot лучше. Общий speedup из этого не следует. `atomics:info(memory)`
сообщает 8,232 bytes для words и 48 для active flag; mapping ETS сообщает 20,084
VM words, external size reverse tuple — 58,633 bytes. ETS execution table с
1,024 hits сообщает 22,071 VM words. Это частичные размеры компонентов, а не
сравнение полного RSS кампании. Campaign benchmark не изолирует внешний
scheduler/thermal noise; второй production harness не запускался. Поэтому
opt-in performance gate плана не проходит на измеренном parser workload, а
default-switch gate **NOT MET**. Bitmap остаётся experimental opt-in; после
измерений не добавлялись reset или hot-path optimizations.

## Выбор, rollback и оставшаяся работа

В API campaign config используйте
`#{coverage => automatic, coverage_feedback => presence, coverage_backend => bitmap, coverage_bitmap_bits => 65536, ...}`;
передавайте instrumented artifacts как обычно. Для rollback задайте
`coverage_backend => ets` или удалите этот ключ. `ets_member` и ETS `hit_count`
остаются доступны. Выбор campaign backend не открыт через CLI; изменения harness
API не нужны. Recompile/reload требует новой кампании и повторно проверенных
manifests. Corpus input bytes можно калибровать заново; stored coverage bits
требуют точного fingerprint и не импортируются между builds.

Остаётся: без прерывания завершить исторический P0 benchmark; повторить
performance на представительных production harnesses с paired confidence
intervals, p95 и полной memory/RSS; решить, оправдывает ли sparse map cost другой
storage layout. Production default остаётся ETS. OTP-native coverage, edge
coverage, buckets, NIF и OTP patches вне этой реализации.
