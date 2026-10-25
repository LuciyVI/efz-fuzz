# Crash occurrences, сигнатуры и проверенный replay

[English](../../replay.md) · **Русский** · [Español](../es/replay.md) · [简体中文](../zh-CN/replay.md) · [Все языки](../README.md)

Raw `.input` — авторитетный triggering binary. Recipe восстанавливает bytes;
signature группирует failures; ни один из них не заменяет raw input или полные
diagnostic Reason/stack. Replay исполняет существующий instrumented executor с
явным контрактом `Module:run(binary())`. Второй fuzzing engine не создаётся.

## Identities и границы отчёта

| Поле | Identity / назначение |
|---|---|
| `occurrence_id` | Новый случайный 128-bit ID каждого detected target failure, включая повторы того же input |
| `input_hash` | SHA-256 точных triggering bytes, независимо от failure classification |
| `signature_id` | SHA-256 нормализованной versioned crash signature |
| `group_id` | Уникальная crash group, сейчас равна `signature_id` |
| `id` | Compatibility alias для group signature; **не occurrence ID** |
| `crash_signature` | Читаемый нормализованный descriptor; не заменяет raw diagnostics |

Конфигурация кампании через `efz:start/1`:

```erlang
crash_policy => #{reason => category, max_frames => 5, max_representatives => 3}
```

Unknown policy keys отклоняются. `max_frames` и `max_representatives` принимают
1..32. Default Reason policy `category` сохраняет atom reason или первый atom
в tuple (например, `{badmatch, Bytes}` становится `{tag,badmatch}`); иначе
сохраняет term type. `exact` сохраняет data values, заменяя identities
pid/reference/port/fun на typed placeholders. `ignore` исключает Reason из
classification. Это grouping heuristics: `category`/`ignore` могут объединять
разные bugs с одинаковым stack, а `exact` намеренно разделяет data-dependent
reasons. Paths внутри `exact` Reason — данные и не переписываются.

Signature schema v2 включает class, reason policy, normalized Reason и не более
`max_frames` target frames. Frames — `{Module,Function,Arity}`: argument lists
становятся arity; file/line/column и executor/guardian/coverage frames исключены.
Signature hash использует явный порядок tuple fields, а Reason maps становятся
sorted pairs. VM-dependent default ETF map order не хешируется. Исходные source
paths, argument lists и **полный raw Reason** остаются в `artifact.term`.
Old fingerprint artifacts оставлены нетронутыми, без automatic regrouping.

`Report.crashes` содержит одну entry на signature с `occurrences`,
`first_occurrence_id`, `last_occurrence_id` и `representatives`. Он сохраняет
input/result/metadata/path первого representative как compatibility fields.
Только первые N **различных input hashes** попадают в representative list и
crash `decisions`; repeated occurrences увеличивают counters, не добавляя
decisions. `crash_occurrences` включает crashes, exits и timeouts; `crashes` и
`timeouts` остаются отдельными counters. `unique_crashes` считает groups,
включая unsaved. Эти counters описывают текущую кампанию. Каждая group также
предоставляет `durable_occurrences`, `disk_representatives` и `group_path`,
полученные с диска.

Тот же cap `max_representatives` применяется к **disk и report на signature**.
Диск хранит первые N различных input hashes между кампаниями/перезапусками VM.
Новое occurrence выбранного input возвращает `storage => duplicate`, увеличивает
counter и повторно использует immutable artifact. Тогда `path` указывает на
этого representative; `representative_occurrence_id` идентифицирует occurrence,
действительно сохранённое там, а `occurrence_id` — текущее событие. Его raw input
bytes совпадают; сохранённые Reason/recipe/build metadata принадлежат исходному
representative.

Новый input сверх disk cap возвращает `storage => limit_reached`, увеличивает
durable counter и **не имеет artifact path**. Файл для него не пишется. Текущая
кампания всё ещё может держать его среди ограниченных in-memory representatives
с точными bytes/Reason и явным storage disposition. Уменьшение cap ниже уже
сохранённого числа даёт ошибку; existing findings не удаляются молча. Увеличение
cap позволяет последующим new inputs стать representatives.

Это count limit на signature, а не global byte quota или граница числа разных
signatures. Full raw Reason сохраняется для selected artifacts; nonselected
occurrences считаются, а не архивируются отдельно. Запрошенный mutation trace
имеет независимый `trace_limit`.

## Атомарный layout artifacts и политика прерываний

```text
CRASH_DIR/SIGNATURE_SHA256/
  summary               EFZG v1 durable counter and representative IDs/hashes
  OCCURRENCE_ID/         only for selected representatives
    artifact.input      exact binary, no term encoding
    artifact.term       schema v2 complete raw result/Reason, metadata and policy
    artifact.replay     EFZX v1 compatibility expectation
    artifact.recipe     optional EFZR v1 concrete mutation provenance
    manifest            file sizes and SHA-256 hashes
  .lock/                exclusive writer; absence required before another save
  .tmp-*                uncommitted writes; not findings
```

`efz_crash_store` сериализует writers эксклюзивным directory lock, включая
writers независимых VM. Он проверяет existing summary и все selected artifact
manifests до приёма следующего occurrence. Сначала selected artifacts
фиксируются через file fsync/close, directory sync и atomic rename. Затем synced
atomic-file replacement публикует `summary`; удаление lock также сопровождается
directory sync. Нет append-only event log или per-occurrence file для discarded
inputs. Повтор **последнего committed occurrence ID** идемпотентен; обычные
calls всегда выделяют новый ID.

EFZG v1 использует 41-byte envelope `EFZG`/version/length/SHA-256 и safe
uncompressed ETF, ограниченный 16 KiB. Seven-key schema содержит version,
signature, unsigned 64-bit occurrence count, first/last occurrence IDs, last input
hash и не более 32 разных representative ID/hash pairs. Декодирование
target-derived atom или raw Reason не требуется.
`efz_crash_store:read(GroupDirectory)` возвращает проверенный index.

Interrupted writer может оставить lock, temporary files или committed artifact,
ещё не указанный summary. Это **явные infrastructure errors**, а не reset к
пустому index. Lock сообщается как `writer_active_or_interrupted`; EFZ не
угадывает, умерла ли другая VM. Failure после artifact publication сохраняет
raw artifact и сообщает `saved_artifact`, когда известен. Counters отражают
committed summary updates; interrupted unacknowledged event не имеет exact-resume
guarantee. При storage errors raw triggering bytes остаются в runtime failure
context.

Legacy groups без `summary` отклоняются при записи как `unindexed_crash_group`.
Они остаются replayable, не удаляются и не мигрируют автоматически. Используйте
новый output directory для нового bounded store, сохранив старый как архив.
Для interrupted stores сначала убедитесь, что writers не осталось, и изучите
committed artifacts до recovery; одно удаление lock не обходит index validation.
Эти guards не дают перезапускам молча превышать disk cap.

Raw replay по-прежнему требует лишь `.input` и доверенный `.replay`;
corrupt/missing optional `.recipe`/`.term` не блокируют raw recovery.
Дальнейшие **writes** в store отклоняют corrupt representatives.
`efz_fs:validate_group/1` остаётся доступным для явной complete-artifact validation.

Malformed recipe не может помешать сохранить selected raw representative:
EFZ хранит input/result/expectation без recipe и возвращает
`operation => encode_recipe`. При достижении cap сообщает recipe error плюс
явный retention disposition; сохранение discarded input не заявляется.
`saved_artifact` включается при наличии exact-input representative. Primary
filesystem/recipe failures не заменяются lock-release или последующими
report-write errors.

При late guardian failure **после** его reply executor сохраняет прежний
infrastructure outcome и записывает secondary `guardian_failure`. Исходный
outcome reply, coverage diagnostics и cleanup evidence остаются в
`execution_evidence`; final cleanup становится `unconfirmed`, VM выводится из
работы. Feedback/report/stats сохраняют primary cause.
`efz_crash_retention_tests` внедряет такой failure после настоящего reply в private
VM, без production fault-injection option.

## Запуск примера и replay в новой VM

Из корня репозитория:

```sh
rebar3 compile
escript examples/staged/run.escript
escript scripts/replay.escript --input _build/staged-example.input \
  --target efz_staged_parser --artifacts _build/staged-targets
escript scripts/replay.escript --recipe _build/staged-example.recipe \
  --target efz_staged_parser --artifacts _build/staged-targets
```

Пример копирует saved expectation в `_build/staged-example.replay`.
Для external adapter добавьте `--code-path /path/to/harness/ebin` (повторяемый).
`--expect FILE.replay` переопределяет default sibling expectation file.
`--timeout MS` имеет default 100; `--max-input-bytes N` для execution по умолчанию
берёт recorded campaign limit. `--help` описывает execution и reconstruction.

| Exit | Значение |
|---|---|
| 0 | `reproduced`: совместимые harness/build и та же normalized failure signature |
| 3 | `not-reproduced`: compatible execution вернул normal result или завершился другим failure |
| 2 | Некорректные arguments/data, input hash mismatch, missing expected identity или build/harness incompatibility |
| 1 | Filesystem/executor infrastructure failure; никогда не выдаётся за обычное non-reproduction |

Execution сначала проверяет exact input SHA-256, делает preflight переданных
artifacts и сравнивает **полный** expected target build set. Он сравнивает saved
harness module name, BEAM MD5, deterministic attributes SHA-256 и optional
instrumented build ID. Compile-source paths исключены из portable harness
record; BEAM code, attributes и instrumented build identity всё равно должны
совпадать. Затем new execution pins защищают от replacement между preflight и
execution. Raw replay **не** загружает `.term` или `.recipe`; поэтому
corrupt/missing diagnostics или recipe не блокируют восстановление valid raw
input. Recipe replay сверяет regenerated bytes с тем же expected input hash.
Mismatches отклоняются до вызова target; нет unchecked fallback или
force-mismatch option.

Reproduction означает равенство normalized signature, а не equality
недетерминированных raw Reason terms или stack source paths. Нестабильный target
вполне может вернуть `not-reproduced`. Failures runner — infrastructure errors.

## Replay expectation (EFZX v1)

`artifact.replay` имеет header 41 bytes: `EFZX`, version byte 1, big-endian 32-bit
payload length, SHA-256, затем uncompressed ETF точной длины. Reads ограничены
2 MiB. Safe decoding не может создавать target-derived atoms: module names —
binaries, требуются только фиксированные EFZ schema atoms. Ready schema имеет
ровно восемь keys: `schema_version`, `status`, `harness`, `target_builds`,
`input_hash`, `signature_id`, `crash_policy`, `max_input_bytes`. Builds содержат
уникальные binary module names и 32-byte hashes; harness fields и sizes
проверяются до execution. Из этих данных не выбирается callable target.

Low-level/manual results без pinned harness плюс selected instrumented builds
записывают `status => unavailable`. Strong execution replay отклоняет такие
expectations. Один legacy recipe не доказывает исходную harness identity.
Caller должен передать отдельно trusted expectation; выбор current harness и
утверждение, что он был old, — не compatibility check. Checksums обнаруживают
corruption, а не intentional tampering и не authenticity.

## Erlang APIs и восстановление bytes

```erlang
[Crash | _] = maps:get(crashes, Report),
Path = maps:get(path, Crash),
{ok, Expected} = efz_replay:load(Path ++ ".replay"),
{ok, Verdict} = efz_replay:run(raw, Path ++ ".input", my_harness,
    Artifacts, Expected, #{timeout => 1000}),
maps:get(status, Verdict).
```

`efz_recipe:execute/5` и `execute_file/5` остаются lower-level execution APIs.
Их Options теперь **требуют `expected_harness`**, полученный из trusted saved
metadata, помимо explicit target/artifacts/expected builds. Они возвращают
executor result без решения signature reproduction. Принимают `timeout`,
`coverage_backend`, `max_input_bytes`; prepared plan handles отклоняются.
Каждый replay создаёт и освобождает новый plan. `efz_replay:run/6` использует
тот же path и сравнивает resulting signature. `harness_identity/1` фиксирует
portable identity при discovery; `pin/3` проверяет её до execution.

Byte reconstruction остаётся независимой от compatible code:

```sh
escript scripts/replay.escript _build/staged-example.recipe _build/regenerated.input
cmp _build/staged-example.input _build/regenerated.input
escript scripts/replay.escript docs/examples/staged-crash.recipe _build/from-docs.input
cmp docs/examples/staged-crash.input _build/from-docs.input
```

Historical positional CLI только восстанавливает bytes (default limit 4096,
optional `--max-input-bytes N`). Он не проверяет target compatibility и не
заявляет crash reproduction. Calibration inputs и random mutations могут не
иметь recipe. Для staged inputs `efz_recipe:load/1` + `regenerate/1`
восстанавливают exact bytes из primary/donor bytes и concrete operations без
corpus, RNG или live plan. Retained corpus entries хранят recipe в
`metadata.mutation`.

## EFZR artifact format, version 1

Все multibyte envelope integers используют big-endian byte order:

```text
"EFZR" (4 bytes)
format version = 1 (1 byte)
payload length (4 bytes)
SHA-256 of payload (32 bytes)
uncompressed Erlang external-term payload (exact length)
```

Payload — проверенный data map ровно с этими fields:

| Поле | Значение |
|---|---|
| `schema_version`, `engine_version`, `operation_version` | В этой phase все 1; unknown versions отклоняются |
| `primary`, `primary_id`, `parent` | Original input bytes, SHA-256 и diagnostic corpus entry ID |
| `operations` | Упорядоченные concrete tuples, максимум 32; donor bytes/hash и actual dictionary/literal bytes находятся внутри operations |
| `stage` | Stage, ответственный за candidate |
| `config_id`, `dictionary_id` | Original normalized configuration/dictionary SHA-256 identities |
| `limits` | Input, block, token и arithmetic bounds для проверки применения operations |
| `output_size`, `output_hash` | Expected candidate byte length и SHA-256 |
| `target_builds` | Binary module names и pinned build IDs; без callable module reference |
| `rng` | Diagnostic algorithm `exsplus` и initial integer seed tuple; без internal state/handlers |

Recipe не требует исходных dictionary, corpus, files, queue indexes,
RNG checkpoints или active plan. Configuration identity обозначает исходные
выборы; concrete operation list, а не повтор planner, определяет replay bytes.
Skipped attempts опущены, поскольку не меняли intermediate bytes. Offsets
применяются последовательно к intermediate result по семантике из
[mutations.md](mutations.md).

Recipe files ограничены 40 MiB. Inputs/donors должны укладываться в recorded
campaign limit, максимум которого 1 MiB. `regenerate/1` использует этот recorded
limit; `regenerate/2` дополнительно принимает current campaign limit (например,
`#{max_input_bytes => 4096}`) и также проверяет intermediate sizes. Replay escript
по умолчанию использует 4096 и принимает `--max-input-bytes N`. Decoder проверяет
length/hash envelope, затем сканирует ETF structure **до** decoding. Он допускает
bounded integers, existing atom tags, binaries, lists, tuples и maps. Он
отклоняет compression, process/reference/port/fun objects, trailing data,
избыточную вложенность (depth выше 24), более 20,000 terms, lists длиннее 4,096
entries и oversized binary fields. Safe decoding не может создать token-derived
atoms. Затем operation/schema validation проверяет allowed fields, versions,
primary/donor hashes, limits, realized operation results и final length/hash.

Malformed encodings возвращают `{error,invalid_recipe_encoding}`; другие
failures включают `incompatible_recipe`, `recipe_size_limit`,
`output_hash_mismatch`, `output_size_mismatch`, `{invalid_recipe,Reason}` и
`{recipe_operation,Reason}`. Operation, которая была бы skipped, включая
неподходящий offset, недопустима в realized recipe. Ни один operation tuple не
исполняется как Erlang source и не диспетчеризуется в arbitrary module. File
parsing не использует expression evaluator.

Checksums обнаруживают corruption; это не authentication scheme. Существующий
crash `.term` result format отдельный и может содержать runtime diagnostic
references; это не bounded EFZR import format и не replay dependency.
## Проверка

`efz_crash_tests` использует настоящий instrumented parser, обычный binary harness,
staged mutations и fresh CLI VM. Он доказывает separate occurrences для разных
inputs, stable signatures после source relocation, настраиваемые data-dependent
reasons, raw и recipe reproduction, build/harness mismatch rejection, обработку
corruption и разные non-reproduction/infrastructure exits (включая unreadable
input и missing artifact directories). Кампания из 1000 occurrences держит одну
group, три representatives и три crash decisions, сохраняя три raw input
artifacts и summary с count 1000. Настоящие coordinator/worker death tests
проверяют primary failure reporting, stats и cleanup. Существующие limits,
recipe, coverage, durable corpus и staged parent-reuse tests покрывают общий
runtime path.

Проверено на toolchain OTP 27 проекта. Пересборка с другими target
source/options/toolchain может изменить build identity и намеренно отклонить
старые execution expectations. Recipe byte reconstruction имеет свой versioned
contract.

## Runtime findings

Runtime schema v1 независима от crash expectations/recipes. Replay через
`efz_replay:runtime(Directory, LocalTarget, Artifacts, #{runs=>3})` или
`scripts/replay.escript --runtime-finding DIRECTORY --target MODULE --artifacts DIR
--runs 3`. Identity/hash/policy checks предшествуют тому же executor; output
различает `observed`, `not_observed`, `inconclusive`, включая sample count и
repeatability. Один успешный repeat не опровергает instability.
[Полный формат и лимиты](runtime-diagnostics.md).
