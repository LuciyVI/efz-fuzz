# Повторно используемый долговечный корпус

[English](../../corpus.md) · **Русский** · [Español](../es/corpus.md) · [简体中文](../zh-CN/corpus.md) · [Все языки](../README.md)

Persistence включается через `corpus_dir` в campaign map или `--corpus-dir`
launcher. Без него остаётся существующий in-memory campaign path. Store
сохраняет initial inputs и successful new-coverage discoveries между
`efz:stop/0`, завершением процесса и перезапусками VM. Mutated crashes и timeouts
по-прежнему попадают только в существующее crash storage. Initial seeds
сохраняются до calibration, включая те, которые позднее окажутся crashing.

```erlang
{ok, _} = efz:start(#{target => my_harness, artifacts => Artifacts,
    seeds => [<<>>], corpus_dir => "findings/corpus",
    mutation_mode => staged, max_iterations => 1000}).
First = efz:await(infinity),
ok = efz:stop().

%% A later VM loads the same compatible harness and artifacts.
{ok, _} = efz:start(#{target => my_harness, artifacts => Artifacts,
    seeds => [], corpus_dir => "findings/corpus",
    mutation_mode => staged, max_iterations => 1000}).
Second = efz:await(infinity).
```

В CLI добавьте `--corpus-dir ./findings/corpus` при первом запуске. Позднее:

```sh
escript scripts/fuzz.escript \
  --target my_harness --code-path ./harness-ebin \
  --artifacts ./instrumented --out ./findings \
  --corpus-dir ./findings/corpus --mutation staged --max-iterations 1000
```

## Хранение и публикация

```text
CORPUS_DIR/
  <64 lowercase hex SHA-256 of input>/
    input       exact raw binary, including zero-length inputs
    metadata    checksummed EFZC envelope containing versioned metadata
  .tmp-<random transaction suffix>/   unpublished transaction, if interrupted
```

Content hash — identity. Committed entries immutable; duplicate сохраняет
первую записанную provenance. Save проверяет существующую entry до deduplication;
он никогда молча не исправляет и не перезаписывает corrupt committed data.
Новые integer corpus IDs принадлежат текущей кампании. Historical IDs в metadata —
только provenance, а не инструкции реконструкции queue.

Metadata содержит:

| Поле | Значение |
|---|---|
| `schema_version` | `1` для initial/presence entries; `2` для hit-count discoveries |
| `content_hash`, `input_size` | SHA-256 и точная длина в bytes |
| `queue_id` | Historical queue ID исходной кампании |
| `origin` | `initial` или successful new-coverage `discovery` |
| `parent` | `none` для initial seeds; content SHA-256 и historical queue ID родителя для discoveries |
| `discovery` | Phase и новые observed probe identities; v2 также хранит `coverage_feedback`, `retention_reason`, `new_count_features` |
| `identity` | Harness module name, canonical `run/1`, MD5 загруженного harness code, coverage mode и выбранные module/build SHA-256 identities |
| `recipe` | Закодированный EFZR recipe, когда доступен, иначе `none` |

Automatic probe и build module names хранятся как binaries, поэтому загрузка
metadata не может создавать произвольные atoms. Manual coverage IDs — opaque
ETF binaries для historical inspection; при restore они никогда не декодируются.
Runtime execution references, target return values, PIDs, ETS handles и process
dictionaries не входят в durable metadata. Recipe RNG seeds и probe deltas —
historical provenance; ни одно из них не инициализирует новый scheduler или его
global coverage.

Необязательный [hit-count mode](hit-count-experiment.md) записывает record v2 для
discoveries: `retention_reason` — `new_probe` или `new_hit_count`,
`new_count_features` содержит пары `{PortableProbeIdentity, BucketLowerBound}`.
Count-only discoveries имеют пустой `new_probes` и непустую feature delta.
Версия envelope EFZC остаётся 1; readers проверяют record version и её
специфичную форму. Существующие v1 records загружаются без изменений. Старые
binaries явно отклоняют v2 entries; используйте отдельный corpus directory,
если его должен читать более старый EFZ.

Feedback mode не входит в target/build compatibility: raw inputs повторно
используются в обоих modes, каждый restored input калибруется заново. Historical
bucket deltas не импортируются в global feature set новой кампании.

Файл EFZC содержит magic `EFZC`, envelope version 1, 32-bit payload length,
32-byte SHA-256 payload и uncompressed ETF metadata. Loading проверяет
размер/checksum envelope, ограниченную data-only ETF grammar, schema,
обязательные поля, input size/hash, directory content identity и согласованность
recipe с input, parent и recorded builds. Raw inputs ограничены 1 MiB,
metadata — 64 MiB на entry. Unsupported schema versions — ошибки, а не попытки
migration.

Порядок публикации:

1. Создать уникальный staging directory внутри corpus directory.
2. Записать raw input через exclusive creation; выполнить fsync и close.
3. Записать полный metadata file; выполнить fsync и close.
4. Fsync staging directory, затем атомарно переименовать его в content hash.
5. Fsync corpus directory до подтверждения save.

Новые ancestor directories также синхронизируются через parent. Files и staging
directory находятся в одной filesystem, поэтому при публикации readers видят
полную entry. Второй publisher того же content проверяет уже опубликованную
entry, а не заменяет её. Native Erlang implementation использует `file:sync/1`,
включая directory handles с `[read,raw,directory]`. Это проверено на текущих
Linux filesystem/OTP 27. Filesystem без directory fsync явно даёт ошибку;
durability молча не понижается. Настоящее восстановление после отключения
питания здесь не проверялось.

Corpus gen_server сериализует persistence и insertion. Successful discovery
фиксируется до попадания в active queue или увеличения `discoveries`.
При write/fsync error input не вставляется, worker сообщает corpus persistence
infrastructure failure. Если rename прошёл, а final fsync не удался, entry
уже может быть видна; кампания всё равно сообщает failure, а позднейший restore
проверяет эту entry. Успех не подтверждается до sync.

## Restore и build policy

`efz_config` восстанавливает entries только после проверки текущих target/artifacts.
Он объединяет supplied seeds (в insertion order) с persisted inputs (в hash
order) и deduplicate-ит по SHA-256. Corpus owner назначает новые IDs и
предоставляет restored entries через обычные paths `mutation_entries/0` и
`select/0`. Historical metadata доступны в `metadata.persistence` каждой entry;
restored entries также имеют `metadata.restored => true`.

Существующий worker калибрует **каждый** starting input, включая restored.
Он создаёт новый global coverage set, RNG и lazy mutation plan. Ни scheduler
cursor, ни PRNG state, ни old global coverage, ни точные queue IDs или scheduling
order не возобновляются. Это reuse inputs, а не точное возобновление кампании
или checkpoint.

Restored inputs должны укладываться в текущий `max_input_bytes` кампании
(оба mutation modes); oversized entries приводят к configuration failure с
content-addressed path, нижней границей размера и active limit. Ничего не
усекается и не исключается молча. Существующая граница 4,096 supplied-initial-seed
по-прежнему применяется после durable-mode deduplication; restored active queue
может быть больше, поскольку могла расти в прежних кампаниях. Store загружается
целиком заранее, поэтому все inputs/metadata должны помещаться в доступную
VM memory.

| `corpus_build_policy` | Поведение |
|---|---|
| `reject` (default) | Ошибка restore при отличии harness name/code, callback, coverage mode или selected build identities |
| `recalibrate` | Reuse exact inputs при изменённых identities; сохранить historical provenance, выдать diagnostics и калибровать на текущем build |

В обоих modes old coverage deltas никогда не объединяются с новой кампанией.
Schema, checksum, input и recipe errors остаются fatal даже с `recalibrate`.

## Частичные entries и диагностика

Corrupt committed entry, отсутствующий `input` или `metadata`, truncation,
некорректный content hash/directory name или incompatible schema делают restore
ошибочным с path и reason. Никакое частичное подмножество не принимается молча.
Filesystem entries, не соответствующие выделенному store format, также дают
ошибку.

Entries `.tmp-*` — неопубликованные writes. Они никогда не загружаются как inputs
и оставляются для inspection. Restore сообщает каждую как
`{interrupted_corpus_write,Path}`, загружая valid committed entries. Эта diagnostic
и любой разрешённый build mismatch появляются в startup warnings и итоговом
отчёте `corpus_restore.diagnostics`. `corpus_restore` также сообщает directory,
выбранную build policy и restored input count. Удаляйте abandoned staging entry
лишь после подтверждения, что её не использует никакой writer.

## Evidence

```sh
rebar3 eunit --module=efz_corpus_store_tests,efz_durable_tests,efz_cli_tests
```

Integration test исполняет настоящие staged dictionary mutations и automatic
instrumentation в отдельных Erlang VM:

- VM 1: initial `<<>>` ID 1 производит `<<"A">>` ID 2, открывает new coverage и
  фиксирует его.
- VM 1 завершается. Отдельный вызов проверяет deduplication initial/persisted content.
- VM 2: с `seeds => []` восстанавливает и калибрует оба inputs. `<<"A">>` теперь
  имеет ID 1 и становится фактическим primary/parent мутации, производящей `<<"AB">>`.
- Последующие новые VM проверяют default build rejection, явную cross-build
  recalibration, input bounds и исключение mutated crashes из этого store.

Тест проверяет parent IDs/hashes, exact recipe regeneration, target results,
new probes и stored provenance. Logs и reports сохраняются по пути, записанному
в `_build/durable-e2e-latest.txt`. Unit tests покрывают duplicate publication,
corrupt/missing/truncated files, schema versions, content names, build policy и
write failure без queue insertion. Interrupted-write test убивает настоящий
process после записи/fsync staging input, но до publication; он проверяет,
что partial transaction диагностируется и не восстанавливается.
