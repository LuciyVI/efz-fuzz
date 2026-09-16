# Automatic Runtime Diagnostics (P0)

P0 включается настройками EFZ. Существующий `Target:run(Input) when is_binary(Input)`
и instrumented target менять не нужно. Default `enabled=false`. `run/3` сохраняет
прежний tuple API; `run/4` получает дополнительный `runtime_observations` schema v1.
Повторы организует campaign worker, а standalone `run/4` выполняет один input.

Поддержанная модель остаётся **synchronous binary harness with controlled descendants**.
Мониторинг не легализует произвольный `spawn`, фоновые OTP applications, внешние
сообщения, shared-state mutation или I/O. Правила [guardian/isolation](execution-isolation.md)
сохраняются. Никакого production disposable-VM backend здесь нет.

## Конфигурация

Полные defaults (можно передавать только переопределяемые поля):

```erlang
runtime_oracles => #{
  enabled => false,
  stability => #{enabled => true, seed_runs => 3, interesting_runs => 3,
    suspicious_runs => 3, failure_runs => 3, compare_return => false,
    max_extra_executions => 1000},
  resources => #{enabled => true, sample_interval_ms => 20, max_samples => 64,
    max_sampled_processes => 128, ets_interval_ms => 100, max_ets_tables => 256,
    memory_bytes => 67108864, mailbox_messages => 1000,
    ets_memory_bytes => 16777216},
  hangs => #{enabled => true, max_stack_frames => 8,
    busy_reductions => 1000, max_sample_age_ms => 100},
  storage => #{max_groups => 128, max_representatives => 3,
    max_metadata_bytes => 1048576, max_total_metadata_bytes => 16777216}}
```

`efz_runtime_config:prepare/1` — общий validator API, executor, CLI и replay.
Все неизвестные поля и неверные типы отклоняются, включая выключенные разделы.

| Поле | Диапазон / единица |
|---|---|
| `*_runs` | 1..16, **включает исходный запуск** |
| `max_extra_executions` | 0..1 000 000 на всю кампанию, включая seed verification |
| `sample_interval_ms` | 1..10 000 ms; интервал после окончания предыдущего опроса |
| `max_samples` | 2..256, последние samples, не первые |
| `max_sampled_processes` | 1..256; произведение с `max_samples` ≤32768 |
| `ets_interval_ms` | 10..60 000 ms; первый ETS scan только по истечении интервала |
| `max_ets_tables` | 1..4096 проверяемых VM table IDs за scan |
| Resource thresholds | 1..2^40; process/ETS memory в bytes, mailbox в messages |
| `max_stack_frames` | 0..32, только MFA, без arguments/locals |
| `busy_reductions` | 1..10^9 за последний интервал, не CPU utilization |
| `max_sample_age_ms` | 1..60 000, не меньше sample interval при включённых hangs |
| `max_groups` / `max_representatives` | 1..1024 / 1..16 |
| `max_metadata_bytes` | 4096..4 MiB на один finding payload |
| `max_total_metadata_bytes` | 4096..64 MiB, не меньше индивидуальной квоты |

Раздел hangs может собирать process samples при `resources.enabled=false`.
Пороговые resource findings при этом отключены. Если оба раздела выключены,
resource samples отсутствуют; lifecycle evidence всё ещё доступно.

CLI:

```sh
escript scripts/fuzz.escript \
  --target my_harness --code-path ./harness-ebin --artifacts ./instrumented \
  --seeds ./corpus --out ./findings --max-iterations 1000 --timeout 1000 \
  --runtime-diagnostics --runtime-runs 3 --verification-budget 1000 \
  --sample-interval 20
```

`--runtime-runs` задаёт все четыре repeat counts. Другие runtime flags требуют
`--runtime-diagnostics`. Core валидирует числовые лимиты; CLI не создаёт atoms из
текста module name: target разрешается только по выбранным artifacts или локальному
BEAM в code path. CLI по-прежнему не исполняет Erlang expressions из аргументов.

## Calibration и verification

Повторяются seeds, новые successful coverage discoveries, target failures
и подозрительные runtime inputs. Одно `descendant_activity` само по себе не запускает
дополнительные проверки. Каждый повтор — **новый штатный executor/guardian/root** с
полным cleanup. Рекурсивной verification нет. Повторы не вызывают mutator, corpus
selection, staged planner, feedback или retention. Исходный результат проходит
прежний feedback и остаётся единственным источником retention для этого кандидата.

Если выполнено `M` mutation executions и `S` seed executions, общее число executions
не больше `M + S + max_extra_executions`. Более точная граница дополнительных runs:
`min(budget, sum(requested_runs_for_selected_input - 1))`. `max_iterations` не
включает verification. Timeout и cleanup bounds применяются отдельно к каждому run;
это bound executions, не wall-clock deadline кампании.

Любая infrastructure failure немедленно прекращает повторения и кампанию. Исходная
причина остаётся в failure context, включая dirty-runner и guardian failure. Crash,
exit или timeout, впервые увиденный на повторе, сохраняется обычным crash storage с
`metadata.origin=verification` и новым occurrence. Один execution учитывается ровно
один раз. Runtime category не увеличивает crash counters.

Outcome signature сравнивает `ok`, тип исключения и bounded category причины,
exit category либо timeout. Произвольный успешный return **не сравнивается**.
Опциональный return comparator принимает atoms, signed 64-bit integers, binaries,
списки, tuples/maps в общем бюджете 1024 nodes/bytes. PID, refs, ports, functions,
floats, большие/deep terms получают `not_comparable`. Он не угадывает семантику
integer timestamps: при явном compare_return такие значения могут отличаться.

Собственные метрики EFZ, **не эквивалент AFL++ stability**:

- Outcome repeatability = `100 * max_frequency(normalized_outcome) / completed`.
- Coverage repeatability = `100 * max_frequency({builds, exact_probe_set}) / valid`.
  При полностью пригодной серии `valid=completed`. Невалидный/unstarted snapshot
  исключён, а не заменён пустым set.
- Stable probes = пересечение валидных sets. Variable probes = union − intersection.
- Stable-probe ratio = `100 * |intersection| / |union|`.
- Несколько валидных пустых sets: обе coverage метрики 100%, `valid_empty_coverage=true`.
- Менее двух пригодных runs: `insufficient_samples`, даже если единственный run успешен.

`requested` включает исходный run; `attempted=completed+failed`; `completed` — runs
без infrastructure failure; `valid` дополнительно исключает unstarted coverage;
`failed` — infrastructure failures; `skipped=requested-attempted`. У каждой строки
есть duration, coverage/build identity, cleanup status и runtime summary.
Verification имеет отдельные requested/executions/completed/valid/failed/skipped
counters. Coverage integrity errors никогда не становятся `unstable_coverage`.

## Наблюдения и scope

| Category | Что измерено / предположено | Чего это не доказывает |
|---|---|---|
| `unstable_outcome` | Отличается normalized outcome в серии | Security vulnerability |
| `unstable_coverage` | Отличается exact valid coverage set/build | Ошибка target или причина нестабильности |
| `unstable_return` | Различные comparable successful values, только opt-in | Семантический дефект |
| `memory_pressure` | Наблюдавшаяся сумма process memory ≥ threshold bytes | Утечка; полная память VM/бинарных ресурсов |
| `memory_growth_suspected` | Рост между первым и последним сохранённым sample ≥ threshold | Остаточный рост между inputs / memory leak |
| `mailbox_pressure` | Наблюдавшаяся сумма message_queue_len ≥ threshold | Потеря сообщений |
| `ets_growth_suspected` | Наблюдавшийся owned ETS memory peak ≥ threshold | Утечка таблиц после cleanup |
| `descendant_activity` | Guardian admit count и observed peak live | Process leak |
| `child_abnormal_exit` | Ненормальный child DOWN, принятый guardian в running phase | Безусловный дефект или изменение root outcome |
| `timeout_busy` | Существенный reductions delta у сопоставленных owned PID | CPU utilization, livelock или отсутствие progress |
| `timeout_waiting` | Полные свежие samples: waiting и малый delta | Deadlock |
| `timeout_unknown` | Мало, устаревшие, неполные или неоднозначные данные | Причина timeout |

Все resource thresholds диагностические: heap limits не меняются, дополнительных
причин kill нет. `thresholds` хранит baseline, observed, threshold, interpretation
и `defect=unproven`. `reproductions` показывает количество runs с category. Первый
failure не скрывается как warmup. Нет принудительного GC чужих процессов и rollback
persistent_term/env/shared ETS.

Sampler получает только guardian-admitted PID через отдельную ограниченную таблицу.
`processes()` не используется для определения ownership. Guardian/coordinator,
sampler, coverage/corpus/reporting ETS исключены. Во время исполнения доступны
memory, mailbox length, reductions, status, current_function, bounded stack.
Содержимое mailbox/ETS/process dictionaries не читается. Process IDs в persisted
summary заменены portable placeholders; `process_id`/`owner_id` — admission ordinals.

Baseline фиксируется **до admission**: target-owned processes/ETS равны нулю;
VM counters имеют `scope=vm_global`. Это не снимок памяти уже работающего target.
Snapshots во время execution измеряют observed peaks; последние доступные samples
сохраняются отдельно от after-cleanup lifecycle evidence. При отсутствии опроса
живого PID — `not_sampled`, не нулевое потребление.

ETS `memory` в OTP 27 измеряется в words и умножается на `erlang:system_info(wordsize)`:
[официальная документация ETS info](https://www.erlang.org/docs/27/apps/stdlib/ets.html#info/2).
ETS scan выполняется в sampler с отдельной частотой и cap. Он перечисляет VM table
IDs через `ets:all()`, но проверяет лишь первые `max_ets_tables`, фильтруя owner.
Показываются known VM tables / scanned VM tables / observed owned tables, и
`partial=true`, если обход неполный или ресурс исчез. Число всех owned tables при
усечённом scan неизвестно. Это не утверждение, что partial sum равна расходу target.
Старые shared-state snapshots guardian (`ets:all()` до/после case) сохранены как часть
контракта cleanup; новый sampler не добавляет ETS scan на каждую быструю итерацию.

Sampler хранит ring из последних `max_samples`; peak сохраняется независимо от ring.
Он имеет monitor на guardian, guardian — monitor на sampler. При cleanup сначала
уничтожаются target processes, затем sampler. Guardian не запрашивает последний
`process_info` и не ждёт «идеального» снимка перед kill. DOWN sampler входит в
ограниченный cleanup lifecycle. Самостоятельная смерть sampler отмечается failed /
partial и не подменяет outcome. Потеря самого guardian сохраняет dirty-runner policy.

Child DOWN во время running хранит reason category и phase; initiator обычно unknown:
monitor не доказывает, что child остановил именно parent. Cleanup помечает kill_requested;
DOWN, принятый уже в cleaning phase, имеет classification=unknown из-за гонки с
естественной смертью. Cleanup kills не создают child_abnormal_exit. `after_cleanup`
сообщает подтверждение termination owners и known survivors; escaped ETS/shared
state всё ещё обрабатываются прежним infrastructure failure, а не resource finding.

Timeout сохраняет исходный outcome/deadline. Классификация использует последние два
samples, сопоставляет PID и сохраняет age, interval, matched/observed process counts,
reductions delta, statuses, mailbox, bounded stacks. Partial activity может доказать
наблюдавшуюся busy activity; waiting требует полных samples. Данные о всех завершённых
между samples процессах восстановить нельзя.

## Storage, report и replay

Хранилище находится рядом с `crash_dir`: `dirname(crash_dir)/runtime-findings/`;
для CLI это `OUT/runtime-findings/`. Оно независимо от crash groups.

```text
runtime-findings/
  index                       checksummed EFZO v1 index
  SIGNATURE_HASH-INPUT_HASH/
    artifact.input            точные raw bytes
    artifact.term             bounded ETF schema v1
    manifest                  hashes и размеры обеих файлов
```

Record содержит SHA-256 input, category/scope/origin, portable harness/build identity,
normalized original outcome, policy/thresholds, bounded evidence со всеми проверками,
и **исходную exact mutation recipe**, если она была. Raw input сохраняется всегда
для выбранного representative, независимо от наличия recipe.

Signature = SHA-256 version/category/scope/harness/builds. PID, refs, timestamps,
конкретные memory deltas не участвуют. Такое grouping может объединять разные причины.
`max_representatives` ограничивает distinct inputs на group, `max_groups` — groups
в store; suppressions и drops учитываются отдельно. Metadata quota включает payloads,
manifests и index; raw bytes дополнительно ограничены `max_groups * max_representatives *
max_input_bytes`. При слишком большом payload representative drops, не бесконечная
сериализация/запись. Есть фиксированный предел 128 report checks и byte quota;
`checks_dropped` показывает усечение. Store сохраняет counters/caps между кампаниями.

Group публикуется атомарно с fsync/manifest, затем атомарно index. Прерванный промежуток,
corrupt committed entry, stale writer/index или оставшийся `.writer-lock` — явная
storage failure и остановка кампании. Автоматического удаления/«починки» нет; используйте
новую output directory после исследования ошибки. Single writer lock не разрешает
параллельную работу разных campaigns с устаревшим in-memory index.

Пример фрагмента report (схема, не обещание конкретных измерений):

```erlang
#{runtime_diagnostics => #{
    verification_executions => 2,
    checks => [#{requested => 3, completed => 3, valid => 3, failed => 0,
                 skipped => 0, origin => calibration,
                 outcome_repeatability => 100.0,
                 reproductions => #{timeout_waiting => 3}}],
    findings => #{groups => #{}, suppressed => 0, dropped => 0}},
  stats => #{executions => 0, calibrations => 1, verification_executions => 2}}.
```

Проверка выбранной директории representative, **с явным локальным target**:

```sh
escript scripts/replay.escript \
  --runtime-finding ./findings/runtime-findings/SIGNATURE_HASH-INPUT_HASH \
  --target my_harness --code-path ./harness-ebin --artifacts ./instrumented --runs 3
```

API: `efz_replay:runtime(Directory, LocalTarget, Artifacts, #{runs=>3})`.
Policy/timeout/input limit берутся из finding; `runs` 1..16, default saved interesting_runs.
Target/artifacts берутся только от caller. Raw SHA-256, manifest, build и harness
проверяются до execution. Safe ETF decode не создаёт target-derived atoms.
`observed` (exit 0), `not_observed` или `inconclusive` (exit 3); несовместимость/invalid
invocation — exit 2, infrastructure — exit 1. Старые crash `.replay`, recipes и raw
input CLI остаются поддержанными.

Для unstable categories один run даёт inconclusive; report показывает sample count,
repeatability и variable fraction. Даже `not_observed` означает только результат
конечной выборки. Для resources отсутствие полных samples даёт inconclusive, а не
доказательство отсутствия проблемы. Повтор использует тот же executor и прекращается
при infrastructure failure. Replay не записывает новые campaign crash groups: найденный
на повторе failure входит в returned summary. Campaign verification сохраняет его на диск.

## Стоимость и ограничения

`stats` разделяет mutation executions, calibrations и verification. Есть отдельно
verification elapsed time, post-execution `runtime_diagnostic_us` (wall time worker,
включая verification и storage, без исходного executor), sampler work time,
sampled/missed executions и максимум
байтов ETS diagnostic buffer, измеренных при завершении runs. Последнее **не включает heap sampler/guardian/report**;
sample slots, child records, report и disk metadata имеют отдельные bounds. Snapshot
copying/worker comparison/storage тоже стоят времени; `sampling_us` не равно всей
стоимости P0. Это cooperative BEAM diagnostics, не realtime scheduling guarantee.

P0 не доказывает memory safety, произвольные resource leaks, race conditions,
deadlock/livelock как причину, native failures, семантическую корректность и внешние
side effects. Нет FD/socket leak detector, NIF/ASan/UBSan/LSan, scheduler perturbation,
stateful/sequence fuzzing, distribution, power scheduling или unstable-probe masking.
Не измеряется полный off-heap binary footprint. Samples пропускают быстрые пики и
быстро завершившиеся children/tables. Для state-dependent роста могут требоваться
история inputs или свежая VM; одиночный raw input не гарантирует reproducer такого роста.

Реальные команды, результаты и ограничения измерений: [validation report](runtime-diagnostics-validation.md).
