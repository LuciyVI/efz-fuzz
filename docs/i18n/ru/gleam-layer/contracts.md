# Нативный контракт Erlang/Gleam v1

[English](../../../gleam-layer/contracts.md) · **Русский** · [Español](../../es/gleam-layer/contracts.md) · [简体中文](../../zh-CN/gleam-layer/contracts.md) · [Все языки](../../README.md)

Требования: **2.0-native**. Контракт: **1**. И
`efz_gleam_adapter:versions/0`, и скомпилированный `efz_qs_model:versions/0` возвращают
`{Contract,Model,Codec,Mutator,FeatureSchema,Property} = {1,1,1,1,1,1}`.
Старт требует точного совпадения; property replay проверяет этот вектор и
`{query_model_agreement,1}`. Несовместимые артефакты не преобразуются незаметно.
[architecture.md](architecture.md) определяет фактических владельцев EFZ и изоляцию P0.

## Типизированное ядро и граница Erlang

Первый парсер: закреплённый Cowlib `cow_qs:parse_qs/1`, commit
`c768a804565ff5b8178ed968a5921e469d6bd7b2`. Harness:
`examples/query_string/efz_qs_target.erl:run/1`. Отдельный
`efz_qs_defect_target` — искусственная acceptance-fixture, а не production-дефект.
`<<"cow_qs">>` идентифицирует семейство цели; артефакты дополнительно фиксируют harness.

Конкретные ADT Gleam находятся в `gleam/efz_semantic/src/efz_qs_model.gleam`.
Именно эти скомпилированные представления проверяются BEAM-вызовами:

| Тип | Представление Erlang / проверяемая граница |
| --- | --- |
| Bytes / `BitArray` | Только `binary()`; bitstrings не по границе байта и текстовые списки отклоняются; UTF-8 не предполагается |
| `Field` | `{field,KeyBinary,ValueBinary}`, непустой ключ, ограниченные компоненты |
| `Query` | `{query,ProperFieldList,canonical | bad_escape}`, точная форма tuple/tag |
| `Limits` | `{limits,Bytes,Fields,Component,1}`, ограниченные целые |
| Gleam result | `{ok,Value}` / `{error,unsupported | limit}` |
| Факты наблюдения | Целые и `true | false`, построенные адаптером после проверки основного outcome |
| Версии | Фиксированный кортеж из шести целых выше |

Records — tagged tuples; внешняя конфигурация/метаданные EFZ — map. Адаптер
проверяет proper lists, tags, binary, выравнивание, целые и ограничения до
вызова ядра. Нет Dynamic/unsafe cast или создания atoms из fuzz bytes.
Вызовы — прямые межмодульные без JSON/ETF/IPC на каждый вызов. ETF ограничен
существующими версионированными кодеками артефактов.

Фактический узкий API, а не предложенный behaviour:

```erlang
prepare(false | OptionsMap, PreparedEFZConfig) -> {ok,Config} | {error,Reason}.
decode(Binary, Limits) -> {ok,Query} | {skip,unsupported | limit} | {error,Reason}.
encode(Query, Limits) -> {ok,Binary} | {skip,limit} | {error,Reason}.
normalize(Query, Limits) -> {ok,Query} | {error,Reason}.
generate(Index, Limits) -> {ok,Binary} | {skip,limit} | {error,Reason}.
mutate(Binary, OperationId, Limits) -> {ok,Binary,RecipeData}
                                      | {skip,unsupported | limit} | {error,Reason}.
observe(Binary, PrimaryOutcome, Limits) -> {ok,SemanticSet}
                                          | {skip,limit} | {error,Reason}.
oracle(Binary, PrimaryOutcome, Limits) -> {pass,query_model_agreement}
  | {fail,query_model_agreement} | {inconclusive,Reason} | {error,Reason}.
```

EFZ владеет явным RNG-выбором вокруг чистого ядра: mutate получает ID
операции, а не скрытый RNG. Generate использует детерминированный индекс каталога 0..4095;
скрипт подготовки использует последовательные индексы и ограничивает результат 64 файлами. Ни один
callback не потребляет состояние RNG caller. Генерация офлайн, не онлайн-семейство.
Seed-каталог имеет отдельно проверяемый `generator_version/0 = 2` и 12 слотов
(индексы повторяются modulo 12); версия пакета 1.1.0. Seeds сохраняются raw-файлами и
manifest schema 2 с диапазоном индексов, версиями, ограничениями, хешами и общим числом байтов,
максимум 64 seeds / 65536 bytes. Runtime-старт по-прежнему проверяет восемь callbacks v1;
версия генератора — возможность холодного пути, проверяемая командой подготовки.
Поэтому семантическая операция Model-and-next-RNG составляется EFZ с
чистым callback модели; фактические переходы состояния определены ниже.

Кандидат EFZ — `{candidate,Binary,PlanMetadata,NextPlanState}`; `input`
корпуса остаётся фактическим raw binary. Декодированная модель временная и никогда не является
постоянным входом. Существующие term-контракты executor/target не меняются.

## Законы кодека, операции и ограничения

Поддерживаемые canonical-модели сохраняют порядок полей и повторяющиеся имена. Decode
поддерживает непустые имена с явным `=`, `&`, percent escapes, plus-as-space
и произвольные байты, включая NUL/non-ASCII. Поля только с именем, пустые имена,
избыточные разделители и bad escapes возвращают unsupported и сохраняют raw-достижимость.

Для canonical-моделей `decode(encode(M)) == normalize(M)` и
`normalize(normalize(M)) == normalize(M)`; нормализация тождественна. Идентичность raw bytes
не обещается. Намеренный `bad_escape` добавляет `&x=%` без исправления
и исключён из decode/encode закона валидной модели.

| Ограничение | Значение v1 / настраиваемый диапазон |
| --- | --- |
| Байты структурного входа/выхода | 0..4096; дополнительно существующий EFZ `max_input_bytes` |
| Максимум полей / байтов компонента | 1..32 / 1..128; пустые query/value разрешены |
| Вложенность | Фиксированная глубина Query → Field 2; без рекурсивного варианта |
| Структурных операций на кандидат | Ровно 1 |
| Основной результат парсера для observer | ≤100 пар, ≤4096 bytes на компонент |
| Признаков исполнения / словарь кампании | ≤4 / 12 допустимых ID |
| Проверки oracle | 0..10000 на кампанию, default 64; калибровка включена |
| Семантический cache/queue/дополнительные workers | Нет (размер 0) |

Байтовые границы проверяются до рекурсии декодера; пределы полей/компонентов останавливают обход.
Encoder вычисляет размер выхода до выделения закодированных байтов. Mutator проверяет
ёмкость полей/компонентов до prepend/append-аллокации и вычисляет wire size
без выделения отброшенного кодирования. Encoder независимо проверяет размер до
аллокации encoded bytes. Большие компоненты/списки каталога имеют allocation guards.
Callbacks — чистые ограниченные
BEAM-вызовы. Учёт прошедшего времени не прерывает зависший callback.

Фиксированные операции: 0 добавить в начало `x={0,255}`; 1 опустошить первое значение; 2 удалить первое поле;
3 обратить поля; 4 добавить байт 255 к первому значению; 5 выбрать `bad_escape`.
0..4 сохраняют валидность в пределах ограничений; 5 намеренно нарушает escape-синтаксис.
Unsupported/limit/unchanged результаты используют контролируемый ordinary fallback.

## PRNG и рецепты

`efz_mutation_plan:new/1` использует явный `rand:seed_s(exsplus,mutation.seed)`.
При отсутствии seed сохраняется существующее однократное crypto-выведение. Воспроизведение
требует parent bytes, seed/state, конфигурацию плана, версии и ограничения.
Прежняя process-local rand-политика random mutation/selection сохраняется;
слой никогда не использует её неявно. В текущем EFZ один worker, поэтому порядок завершения
не является источником случайности. После существующего выбора родителя и lane:

| Случай | Переход состояния |
| --- | --- |
| Off / fraction zero | Дополнительного выбора нет; ordinary начинает с R0 |
| Fraction >0 | `{Branch,R1}=rand:uniform_s(100,R0)` |
| Branch превышает fraction | Ordinary начинает с R1 |
| Structured выбрана | `{OpPlusOne,R2}=rand:uniform_s(6,R1)`, Op=OpPlusOne−1 |
| Успех | Candidate и следующий план используют R2; чистое ядро не делает случайных выборов |
| Unsupported / limit / unchanged | Ordinary начинает с R2, затем следует обычному изменению состояния |
| Ошибка слоя | Вернуть диагностику с R2 и остановиться; без rollback/retry/fallback |

Операция рецепта — только данные:
`{structured_replace,1,{1,1,1,1,1,1},OperationId,OutputBinary}`, ≤4096 output bytes.
Она использует существующие `efz_recipe:make/4` / `efz_mutation:apply_operation/3`.
EFZR envelope остаётся v1; новая structured recipe schema — 3, operation version — 2.
Старые structured schema 2 / operation 2 и ordinary schema 1 / operation 1 остаются
читаемыми. Только structured plan metadata добавляют `source_kind=>structured` и
`structured=>#{schema_version=>1,versions=>V,operation=>Op,limits=>Limits,
fraction=>F,rng_before=>[A,B],rng_after=>[NextA,NextB]}`. Это точные два
58-битных слова состояния exsplus непосредственно до выбора ветви и после выбора
операции, представленные правильными списками; runtime functions в артефакты не попадают.
Холодная проверка рецепта восстанавливает состояние через `rand:seed_s({exsplus,[A|B]})`
и проверяет branch, operation, next state, ограничения и точную форму метаданных.
Регенерация применяет сохранённые байты; типизированная мутация повторно не запускается.
Допустимые операции не могут вызывать модули,
функции или исполняемые terms. Регенерация замены работает без Gleam;
property replay требует его. Записываются исходные primary bytes, identity seed/config,
хеш выхода и build IDs. Adaptive hints/cache/изменения energy нет.

## Конфигурация и возможности

Разбор принадлежит существующим `efz_config` / `efz_cli`. По умолчанию `gleam_layer=>false`;
map включает один фиксированный адаптер, поэтому реестра адаптеров или параллельного CLI нет.
Существующий top-level `target` выбирает поддерживаемый harness/помеченную тестовую fixture.

| Поле слоя | Значения / default |
| --- | --- |
| `structured_fraction` | Целое 0..100 / 10; положительное требует staged-режима |
| `feedback` | disabled, observation_only, guided / disabled |
| `oracle` | disabled, inline / disabled; deferred отклоняется |
| `oracle_budget` | Целое 0..10000 / 64 |
| `limits` | bytes, fields, component, operations / 4096,32,128,1 |

Существующие `mutation.seed`, `random_seed`, `selection_seed` сохраняют разные роли;
`artifacts`, `corpus_dir`, `crash_dir` сохраняют расположение. Дополнения CLI:
`--gleam-layer`, `--structured-fraction`, `--semantic-feedback`,
`--semantic-oracle`, `--oracle-budget`; вложенные ограничения используют Erlang API.
Нативное покрытие использует существующую нативную подготовку/API, не новый CLI-backend.
Подготовка только seeds не включает runtime callbacks.

Старт проверяет известные ключи, типы/диапазоны, цель/режим, target-only манифесты,
доступность пакета, точные версии и полный API ядра из восьми функций,
перечисленный в [p2-integration.md](p2-integration.md). Эти проверки экспорта/модуля не
повторяются на рабочем пути. Отсутствующий экспорт возвращает
`{gleam_configuration,{gleam_callback_unavailable,Function,Arity}}`; версии
проверяются раньше остальных callbacks. Отсутствующий пакет даёт
`{error,{gleam_configuration,{gleam_package_unavailable,Reason}}}`.
Другие причины старта: `unsupported_gleam_oracle_policy`,
`structured_requires_staged_mode`, `unsupported_gleam_target`,
`invalid_gleam_limits` и `incompatible_gleam_versions`; это фиксированные ограниченные
atoms, а не непрозрачные badmatch. Явно выбранное покрытие никогда
незаметно не заменяется fallback. Возможность внешнего фаззера не проверяется. Отключённая подготовка
возвращает неизменную конфигурацию без загрузки необязательных module/application, семантических
state/workers/payloads или дополнительных RNG draws. Off-сборка никогда не вызывает Gleam.

## Feedback и сериализованный допуск

StructuralFeedback остаётся в существующих единицах collector EFZ: presence probes
`{Module,BuildId,ProbeId}`, native module/line units с закреплённой schema либо
существующие count buckets. Не суммируйте их с semantic features как «покрытие».

SemanticFeature — ровно `{<<"cow_qs">>,1,Id}`, Id 0..11. SemanticSet — отсортированный
уникальный proper list на исполнение. Метаданные:
`#{schema_version=>1,namespace=><<"cow_qs">>,feature_version=>1,features=>Fs}`.
У точных tuple/list нет коллизий представления hash/bitmap. ID: 0 accepted,
1 rejected, 2 timeout, 3 exception; 4..7 count 0,1,2,≥3; 8/9 empty value present/
absent; 10/11 byte ≥128 present/absent. Это ограниченные факты, не проверка UTF-8.

CampaignSemanticState — принадлежащий корпусу `semantic_seen`: точное историческое
множество успешно допущенных/аннотированных признаков, ≤12. Это не active refcount
index. Append-only корпус сохраняет представителей всех зафиксированных признаков.
Reset каждого исполнения не очищает историю кампании.

Для успешных primary outcomes `{ok,_}` (включая ожидаемый отказ):

```text
structural_keep = existing reason in {new_coverage,new_probe,new_hit_count}
semantic_new = execution_features minus corpus.semantic_seen
keep_new_input = structural_keep OR semantic_new is nonempty
```

Калибровка аннотирует сохранённые seeds; начальные и остальные существующие retention-
причины сохраняются. Неуспешные outcomes используют существующий канал находок;
наблюдаемые ID timeout/exception не допускают эти сбои через данный предикат.
Находки независимы от новизны и сохранения в корпус.

`efz_corpus:admit_semantic/4` сериализует решение в своём gen_server. Вычисление
новизны не меняет seen. Новые raw input/metadata сохраняются через
`add_checked/3` до фиксации entries/seen. Ошибка хранения/отказ оставляет
seen неизменным для retry. Без store фиксация — вставка в память.
Существующая политика устойчивости sync/rename store сохранена; P1 не добавляет правила
fsync. Аннотации существующих входов объединяют feature/structural evidence и сохраняют
исходную причину допуска вместо создания дубликатов.

Semantic-only entries имеют рабочие metadata `retention_reason=>new_semantic`,
доступны обычным `mutation_entries/0` / `select/0` и не получают новой
energy policy. Observation-only выдаёт metadata/counters без изменения
допуска. Отдельный observation log не доказывает управление поиском.

Online pruning/refcount updates отсутствуют. `efz_semantic:cover/1` предлагает
подмножество, сохраняющее записанные structural probes/counts и semantic unions,
защищая начальные/некалиброванные entries; удаление не применяется. Будущие
merge/prune должны сохранять нужных представителей и атомарно перестраивать
seen/active index до возобновления выбора, избегая подавления историческим seen
замены удалённого представителя.

`efz_corpus:semantic_representatives/0` — сериализованный read-only холодный запрос.
Он возвращает `{ok,#{Feature=>ExistingEntryId}}`, максимум 12 ключей, и отклоняет
seen-признак без активного представителя. Off/observation-only возвращает
`disabled`. Индекс выводится из фактических entries без сохранённых refcounts,
кэша и RNG draws. Семантические метаданные требуют точной schema из четырёх ключей и
канонического ограниченного набора признаков; oversized/improper/unknown-ID metadata отклоняются
до сортировки. [Доказательства P4](p4-feedback.md) применяют консервативное подмножество к
новому store, перезапускают его и проверяют structural/semantic сохранение. Онлайн-правки store
не поддерживаются; правки между кампаниями перестраивают seen из текущего raw-
корпуса при явной калибровке без устаревшего сохранённого global index.

Restart проверяет метаданные, затем калибрует все raw entries, перестраивая совместимые
annotations/seen до мутаций. EFZC envelope v1 и старые записи v1/v2 остаются
принимаемыми; semantic discoveries используют запись v3. Несовпадение namespace/schema/feature
отклоняет restore; build mismatch следует существующей политике reject/recalibrate. Это
восстанавливает переиспользуемый корпус, не точный PRNG checkpoint кампании.

## Observer, oracle, ошибки и replay

Интервал и изоляция module-scoped зафиксированы в architecture.md. Observer
использует ограниченную проверяемую сводку primary outcome без декодирования или
исполнения цели. Включённый oracle с бюджетом сравнивает поля поддерживаемой canonical ordered
модели с завершённым результатом парсера. Совпадение даёт Pass; несовпадение или
отказ поддерживаемой canonical-модели — Fail. Обычный parse rejection
сам по себе не дефект. Unsupported/limit/timeout/exception/исчерпание бюджета
даёт Inconclusive с причиной, никогда не Pass. Чистый oracle не делает дополнительных вызовов цели.
Async/deferred реализации нет. Будущее повторное исполнение цели обязано
использовать отдельный управляемый EFZ интервал, ID, конечный бюджет и счётчики вызовов.

| Категория | Фактическая политика |
| --- | --- |
| expected_rejection | Перечисленные harness ошибки парсера возвращают rejected; обычный outcome цели |
| target_exception / target_timeout | Существующие exception/exit/timeout находки и очистка |
| oracle_failure | Независимое существующее хранилище находок; исходные bytes/outcome и sidecar property/version |
| semantic_layer_error | Отдельный counter/диагностика, остановка как infrastructure_failure; никогда не target bug или fallback |
| infrastructure_error | Существующая политика lifecycle/coverage/persistence/config ошибок |
| VM/native crash | Только существующий применимый external-target outcome; нового native catcher нет |

Некорректная граница codec/mutator/generator возвращает `{error,boundary}`. Ожидаемые unsupported/limit возвращают
skip; сбои границы observer и raised/неожиданные результаты callback становятся
`{error,{semantic_layer_error,Class,BoundedReason}}`. Сбои цели сохраняются
до семантических callbacks; ошибка observer не может их стереть. Проверки времени
не являются отменой, а уничтожение Erlang не гарантирует прерывания native-вызова.

`efz_crash:signature/2` сохраняет fingerprint version/class/reason policy. Находки oracle
используют class oracle_failure, reason `{query_model_agreement,1}`, пустой stack.
Default category fingerprints классифицируют по property tag; полные property/version
и исходный input остаются в артефактах. Replay требует EFZS v1, совместимые
vector/property, raw SHA256 и явно выбранные caller закреплённые сборки harness/target. Artifact-
terms не могут выбирать исполняемые callbacks. Минимизация сохраняет то же нарушение
свойства v1; другие exceptions/timeouts/unsupported inputs его не удовлетворяют.
Конечный бюджет 1..10000 учитывает вызовы цели, включая начальное воспроизведение;
исходные находки неизменяемы. Результат заявляет минимальность по удалению одного байта
или исчерпание бюджета, не глобальную минимальность.

Fixtures, exit codes, ограничения review и передача: [p1-validation.md](p1-validation.md).
