# Лимиты входов и ошибки хранения

[English](../../input-and-storage.md) · **Русский** · [Español](../es/input-and-storage.md) · [简体中文](../zh-CN/input-and-storage.md) · [Все языки](../README.md)

`max_input_bytes` — единая опция кампании, default **4096**, включительный
диапазон **0..1048576**. Ноль допускает только `<<>>`. Сам максимум разрешён;
максимум плюс один отклоняется. Ни один слой не усекает и не преобразует bytes
входа.

```erlang
{ok, _} = efz:start(#{target => my_harness, artifacts => Artifacts,
    seeds => [<<>>], mutation_mode => staged, max_iterations => 100,
    max_input_bytes => 4096,
    mutation => #{stages => [dictionary_insert, bitflip], dictionary => [<<"A">>]}}).
```

Прежняя вложенная опция кампании `mutation.max_input_bytes` теперь возвращает
`{error,{campaign_level_option,max_input_bytes}}`. Нормализованный внутренний
mutation plan и сохранённые recipes по-прежнему содержат производный limit для
детерминированного replay. Самостоятельный planner API сохраняет свой явный
options map.

| Граница | Поведение |
|---|---|
| Начальные seeds | Config проверяет размеры всех binaries до калибровки в обоих modes |
| CLI seeds | Raw read не более limit + 1 bytes; слишком большие файлы дают ошибку с path и нижней границей размера |
| Восстановленный корпус | Ограниченное чтение input по текущему limit кампании до калибровки; без тихого пропуска |
| Добавление в активный корпус | Проверяет тот же limit до добавления/persistence |
| Random mutation | Получает limit в callback options; встроенный mutator при полной ёмкости заменяет insertion на overwrite; при нуле возвращает пустой input |
| Worker / executor | Проверяют до вызова harness; некорректный пользовательский random callback — infrastructure failure с сохранением его точного candidate |
| Staged mutation | Все operations, промежуточные значения и donors используют производный limit |
| Crash input | `save/4` проверяет limit кампании до работы с filesystem |
| Replay | Low-level raw execution использует `Opts.max_input_bytes`, default 4096; verified replay CLI по умолчанию использует записанный limit кампании |

Исторический low-level executor API по-прежнему поддерживает term-based
instrumentation experiments, если byte-limit option не передана. Campaign и
replay execution всегда передают limit явно и требуют binary input.

## Replay

`efz_recipe:regenerate(Recipe)` проверяет limit кампании, записанный в этом recipe.
`regenerate(Recipe, #{max_input_bytes => Max})` также ограничивает текущей
границей кампании primary, donors, все промежуточные значения и output; он не
ослабляет записанную границу. `regenerate(Recipe, #{})` использует default 4096.

```erlang
{ok, Input} = efz_recipe:regenerate(Recipe, #{max_input_bytes => 4096}),
{ok, Expected} = efz_replay:load(ExpectationPath),
{ok, Result} = efz_recipe:execute_file(InputPath, my_harness, Artifacts, Builds,
    #{timeout => 1000, max_input_bytes => 4096,
      expected_harness => maps:get(harness, Expected)}).
```

```sh
escript scripts/replay.escript finding.recipe exact.input --max-input-bytes 4096
```

Envelopes metadata recipes и корпуса сохраняют отдельные лимиты размера
*metadata*; они не разрешают более крупные fuzz inputs. Oversized binaries в
памяти сообщают SHA-256 и точный размер. Ограниченные file readers сообщают
нижнюю границу размера и path, не выдавая prefix hash за identity всего input.

## Crash transaction и ошибки

`efz_crash:save(Input, Result, Metadata, #{crash_dir => Dir, max_input_bytes => Max})`
возвращает `{ok, Crash}` или `{error, ErrorMap}`. Четвёртый аргумент только с
каталогом использует default 4096. Map filesystem error содержит:

```erlang
#{kind => filesystem, operation => open, path => Path, reason => eacces,
  input_hash => InputSHA256, signature_id => Signature, group_id => Signature,
  occurrence_id => Occurrence, crash_fingerprint => Signature,
  artifact_group => Group, staging_path => Staging}
```

`operation`, `path` и `reason` описывают primary failure. Необязательные
`close_error` / `cleanup_error` сохраняют secondary failures, не заменяя его.

Опубликованный layout:

```text
crash_dir/
  SIGNATURE_SHA256/
    summary                  (bounded durable count / representative index)
    .lock/                   (exclusive writer; absent between saves)
    OCCURRENCE_ID/            (selected representative only)
      artifact.input
      artifact.term          (complete raw Reason/stack and metadata)
      artifact.replay        (expected build/harness/input/signature)
      artifact.recipe        (when valid staged provenance is available)
      manifest               (version, file sizes and SHA-256 hashes)
    .tmp-RANDOM/              (uncommitted staging after a killed writer)
```

Каждый файл записывается эксклюзивно, fsync-ится и закрывается во временном
каталоге. После fsync этого каталога один rename публикует всю группу, затем
fsync-ится parent directory. Отсутствующие parent directories создаются и
синхронизируются. При обычной ошибке неопубликованный staging удаляется;
cleanup failure сообщает его path. Прерванный writer может оставить узнаваемый
каталог `.tmp-*`; у него нет committed group identity, и его нельзя использовать
как finding. Нельзя glob-ить `.input` files без исключения staging. Если writer
убит после rename, опубликованная группа полна. Ошибка parent fsync после rename
сообщает о сбое, хотя полная группа может существовать. Публикация artifact и
обновление summary — отдельные commits: orphan после прерывания диагностируется,
никогда не удаляется молча и не считается пустым store.

`efz_crash_store` применяет `crash_policy.max_representatives` между кампаниями и
перезапусками VM. Он хранит первые N различных input hashes, считает каждое
committed occurrence в синхронизированном atomic `summary` и исключает
одновременных writers directory lock. До сохранения он проверяет summary и
manifests представителей. Только последний committed occurrence ID можно
повторить идемпотентно. Убитый writer может оставить `.lock`, `.tmp-*` или
неиндексированный artifact; всё это блокирует дальнейшие записи со structured
error до проверки. Это не точное возобновление кампании.

`storage => saved` обозначает новый immutable artifact; `duplicate` использует
повторно exact-input representative с идентификатором
`representative_occurrence_id`. Его raw Reason/recipe принадлежат тому сохранённому
occurrence. `limit_reached` не даёт path и не записывает индивидуальный artifact
для этого input. Отчёт содержит текущие counts кампании плюс
`durable_occurrences` и `disk_representatives`. Это ограничения counts на
сигнатуру, а не глобальная byte quota. Полный raw Reason сохраняется для выбранных
представителей.

Отсутствующие/усечённые/несовпадающие representative files не проходят validation.
Legacy groups без `summary` явно отклоняются при записи и остаются replayable;
для bounded storage используйте новый output directory, сохранив исходный архив.
Уменьшение cap ниже сохранённого representative count также отклоняется без
удаления findings. `Crash.path`, когда присутствует, остаётся prefix, оканчивающимся
на `artifact`.

Malformed/mismatching recipe не мешает сохранить выбранный raw input: он
публикуется без recipe, с полной diagnostic и `recipe_error`. Затем `save/4`
возвращает primary recipe error, retention disposition и `saved_artifact`, когда
существует exact-input representative. При достижении cap ошибка по-прежнему
сохраняет triggering bytes в runtime context; хранение на диске не заявляется.
Raw replay требует только `.input` и доверенный `.replay`, независимо от
необязательных recipe/raw diagnostics. См. [crash/replay/report](replay.md).

Storage failure останавливает кампанию с `{infrastructure_failure, ErrorMap}`,
один раз увеличивает `infrastructure_failures` и сохраняет target crash counter.
`unique_crashes` считает обнаруженные сигнатуры, включая несохранённые.
`crash_occurrences` считает все target failures, включая повторы и timeouts.
Отчёт сохраняет crash result/stack и точные bytes в `crashes` и `failure_context`
вместе с recipe, hash и primary storage reason. Для сообщения об ошибке worker
не должен падать. Сбой с повторным fingerprint всегда доступен в
`failure_context`, даже если `crashes` уже содержит более раннего представителя.

Итоговый CLI report и самостоятельные recipe/output writes также публикуются
через временный файл write/fsync/close/rename. Если само сохранение отчёта
не удаётся, CLI увеличивает infrastructure counter и включает in-memory report
в diagnostic ошибки, сохраняя любой предшествующий primary campaign failure.
Гибель worker также увеличивает `infrastructure_failures`; fuzzer сохраняет
последний полученный exact input context. `primary_infrastructure_failure` в
stats задаётся только первой ошибкой.

Протокол предполагает filesystem с поддержкой same-directory atomic rename и
file/directory fsync. Неподдерживаемые operations возвращают infrastructure errors.

## Проверка

`test/efz_limits_tests.erl` проверяет настоящее instrumented execution, random
и staged limits, retained/restored corpus, replay и raw crash boundaries.
Он проверяет regular-file ancestor (эквивалент `/dev/null/invalid-dir`), настоящий
Unix `eacces`, missing parents, ошибку на втором artifact после синхронизации
первого, повреждённые committed data и убитого staging writer. Permissions case
требует unprivileged test process для проверки отказа по Unix mode.
Существующие fresh-VM CLI, recipe replay, durable-corpus и staged-lineage tests
продолжают проверять интеграцию.
