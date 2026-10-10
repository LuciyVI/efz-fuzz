# Подключение Erlang-библиотеки к Gleam Layer

Подключение использует существующие EFZ execution, corpus, scheduler, coverage,
RNG и replay. Один campaign выбирает один адаптер. Harness сохраняет внешний
контракт `run(binary()) -> term()`; фактическая функция библиотеки может иметь
другую арность и принимать Erlang-термы. Generic adapter не требует собственной
Gleam-модели для каждого API. Протокольные plugins сохраняют исходные wire bytes
и не обязаны использовать generic term codec.

[Результаты реализации и границы проверки](universal-validation.md) содержат
сохранённые команды/логи, compatibility evidence и предварительные измерения.
Новый общий replay CLI прошёл статический review; его запуск и финальная
изолированная comparative серия ещё не выполнены. Последнее указание пользователя
запрещает новые тестовые/измерительные прогоны.

## 1. Выбрать API и уровень подключения

| Способ | Когда использовать | Реальный пример |
| --- | --- | --- |
| Generic term/API | Аргументы описываются bounded Erlang-термами | `lists:reverse/1`, `maps:find/2`, `efz_term_tuple_library:combine/2` |
| Domain/protocol | Нужны wire grammar, коррелированные поля или независимая модель | `efz_xmlrpc_adapter`, `efz_qs_adapter` |
| Stateful harness | Нужны setup/reset/cleanup и список команд | `efz_stateful_target`, `efz_stateful_counter` |

Проверенный envelope: модуль доступен на code path, вызов выполняется локально
на BEAM через воспроизводимый harness, EFZ управляет timeout/cleanup execution.
Harness обеспечивает необходимые ресурсы. Наличие `-spec` или имени модуля не
доказывает корректность произвольного результата. Сокеты, драйверы, внешние
сервисы, аппаратные ресурсы и специальные ОС-зависимости требуют собственного
harness и отдельной проверки execution environment.

## 2. Создать harness

Готовый generic пример:

```erlang
-module(example_library_target).
-export([run/1, options/0, semantic_contract/0]).
options() -> #{entrypoint => {lists, reverse, 1},
              arguments => [#{kind => list, item => #{kind => integer}}]}.
semantic_contract() -> (options())#{kind => term_api}.
run(Raw) -> efz_term_codec:execute(Raw, options()).
```

Для своей `example_library` меняются `entrypoint`, `arguments` и harness;
ядро EFZ не редактируется. `prepare/3` проверяет доступность функции, арность и
совпадение метаданных harness с adapter options. Новый специализированный
пакет для такой библиотеки не нужен. Поддерживается экспортированная арность от
0 до `min(collection, 255)`: default `collection => 32` допускает до 32 аргументов,
а 255 — предел арности BEAM. Нулевой арности соответствует `arguments => []`.
Результат описывается независимо от argument constraints.

`efz_term_codec:execute/2` декодирует canonical packet и вызывает
`apply(Module, Function, Args)` без semantic dispatch или model dependencies.
Прежний `efz_term_api_adapter:execute/2` сохраняется как compatibility delegate.
Unsupported/malformed packet возвращает `{efz_term_input_rejected, Reason}`.
Обычные библиотечные `{error, Reason}` остаются обычными результатами. Harness
определяет, какие исключения API являются ожидаемым отказом, и явно преобразует
их, если этого требует контракт выбранного API.

Harness имеет собственный фиксированный decode envelope. Если он не объявляет
`semantic_contract().input_limits`, используются defaults codec. Campaign limits
`bytes`, `depth`, `nodes`, `collection` должны быть не выше этих границ;
превышение отклоняется до старта с `term_api_input_limits_mismatch`. Более строгие
campaign limits допускаются как структурно поддерживаемое подмножество harness,
если argument constraints остаются допустимыми. Raw mutation при этом может
попадать в более широкую область входов harness.

Для расширения envelope harness передаёт одни и те же limits своему codec и
объявляет их в metadata, например:

```erlang
input_limits() -> #{bytes => 4096, depth => 8, nodes => 256,
                    collection => 64, operations => 1}.
semantic_contract() -> (options())#{kind => term_api,
                                   input_limits => input_limits()}.
run(Raw) -> efz_term_codec:execute(Raw, (options())#{limits => input_limits()}).
```

Adapter options остаются `entrypoint`, `arguments` и optional `property`;
`input_limits` относится к контракту harness. Metadata принимает только общие
ключи limits с документированными finite диапазонами; invalid metadata даёт
`invalid_term_api_input_limits`. В replay тот же harness/code identity сохраняет
свой decode envelope, а semantic identity дополнительно проверяет effective
campaign limits. Рабочая граница collection 64 проверяется отдельным fixture
`efz_term_custom_limits_target` со списком длиной более 32.

Scaffolding создаёт компилируемые исходники, config и seed без перезаписи:

```sh
ERL_FLAGS='+S 2:2' rebar3 compile
escript scripts/semantic_scaffold.escript generic /tmp/new-api efz_example_target
escript scripts/semantic_scaffold.escript domain /tmp/new-domain efz_protocol_target
```

Generic defaults используют настоящий `lists:reverse/1`. Для другой библиотеки
можно передать четвёртым аргументом доверенный `options.term`, содержащий ровно
`#{entrypoint => {Module, Function, Arity}, arguments => Specs}`. Resource specs
scaffolder отклоняет с `resource_harness_required`: lifecycle следует написать
явно. Domain skeleton реализует независимое length-prefixed сообщение и
observer-only plugin; отсутствующая модель не выдаёт успешный oracle.
Инструкции компиляции и CLI находятся в сгенерированном `README.md`.

## 3. Описать аргументы, сценарии и capabilities

Generic codec schema 1 использует собственный binary envelope, а не ETF:
`<<"EFZT", 1, ArgumentCount:16, TaggedArguments/binary>>`. Целочисленные поля
кодируются big-endian. Он сохраняет список аргументов, type tags, ограниченные
размеры и детерминированный порядок map keys. Atom/resource tags являются
индексами отсортированного конечного набора из доверенной конфигурации.
Fuzz input не создаёт atoms.

| `kind` | Дополнительные поля и границы |
| --- | --- |
| `integer` | Signed 64-bit, `min`/`max`; defaults −1000000..1000000 |
| `float` | Finite 64-bit float, finite float `min`/`max`; defaults −1000000.0..1000000.0 |
| `boolean` | `true`/`false` |
| `binary` | Произвольные bytes, `min_length`/`max_length` |
| `charlist` | Proper list Unicode scalar integers, без surrogates; encoding задаёт API |
| `atom` | Обязательный конечный непустой `values => [existing_atom, ...]` |
| `list` | `item => Spec`, `min_length`/`max_length`, proper lists |
| `tuple` | `items => [Spec, ...]`, фиксированная арность tuple |
| `map` | `key => Spec`, `value => Spec`, bounded размер, duplicate keys запрещены codec |
| `term` | Поддерживаемые вложенные scalar/list/tuple/map combinations; atoms только из `atoms => [...]` |
| `resource` | `values => [handle_name, ...]`, сохраняется `{'$efz_resource', Handle}` |

`min_length` по умолчанию равен 0, `max_length` — `collection` (default 32,
maximum 256), в том числе для binary/charlist. При этих defaults binary argument
ограничен 32 bytes, даже если весь packet допускает 4096 bytes. Длина charlist
считается в Unicode codepoints: codec сохраняет каждый codepoint как tagged
signed 64-bit integer, а не как UTF-8 bytes. Преобразование charlist в текстовую
кодировку конкретного API выполняет harness. Atom/resource enum в отдельном
spec содержит не более 256 existing atoms.

Defaults общих limits: `bytes => 4096`, `depth => 8`, `nodes => 128`,
`collection => 32`, `operations => 1`; preflight допускает максимум 1 MiB,
depth 16, nodes 4096 и collection 256. `bytes` включает header и type tags.
Корни аргументов имеют depth 1; каждый list/tuple element, map key/value и
charlist codepoint расходует node budget. Envelope списка аргументов сам не
считается отдельным узлом. Конфигурация аргументов и данные проходят отдельную
валидацию. PID/ref/port/fun не являются переносимыми literal inputs. Observer
может сообщать их конечный класс в результате, не сохраняя сами значения.

Stateful пример кодирует один argument: список не более 16 tuples
`{ResourceHandle, Command, Integer}`. Команды `get`, `put`, `add`, `reset`
выбираются из конечного набора. `semantic_contract/0` объявляет
`resource_lifetime => execution, resource_handles => [counter]`.
`efz_stateful_target:scenario/1` создаёт новый unregistered gen_server через
разрешённый EFZ child spawn `efz_target:spawn_link/1`, устанавливает OTP 27
`proc_lib` metadata (`'$ancestors'`, `'$initial_call'`) и входит в публичный
`gen_server:enter_loop/3`. Harness не вызывает внутренних функций `proc_lib`,
но эти process dictionary keys привязаны к проверенному OTP 27 lifecycle.
Это проверенный OTP 27 bootstrap fixture, а не
обещание поддержки произвольного OTP lifecycle: обычный unmanaged
`gen_server:start_link/3` внутри EFZ execution будет отклонён. При отдельном
прямом запуске вне EFZ harness использует обычный `start_link`. Harness
разрешает symbolic handle в PID, выполняет команды и останавливает процесс в
`after`; `semantic_contract/0` объявляет `execution_modules => [efz_stateful_counter]`.
Каждое execution/replay начинает с нулевого состояния. Один input
является одним primary execution; bounded итог содержит отдельно
`scenario_executions => 1`, `library_operations => N`, `trace => [...]`.
`N` считает команды сценария; setup и остановка процесса в него не входят.
Для иных ресурсов пользователь расширяет harness, а не scheduler или worker.

## 4. Выбрать стандартный адаптер или свой plugin

Точный публичный интерфейс описан в [adapter-contract.md](adapter-contract.md).
Обязательны `descriptor/0` и cold `prepare/3`; подготовленный context immutable.
Descriptor фиксирует adapter ID/API/model/observer/recipe/operation versions,
capabilities, operation IDs, model modules и properties. Опциональный cold
`code_dependencies(Context) -> #{semantic => [module()], target => [module()]}`
позволяет привязать дополнительные helper/property и target dependency BEAMs к
существующему механизму identities. Descriptor уже привязывает сам adapter и
его model modules. Зависимость в identity сама по себе не добавляет coverage.
Generic adapter дополнительно привязывает `efz_term_codec` как semantic
dependency: изменение decode/normalization helper отвергает старый semantic
replay так же, как изменение модели. Cold generic prepare проверяет реальные
Gleam exports `scalar/4` и `observe/6`; отсутствие модельного модуля или
несовместимый ABI отклоняется до campaign. Model-free harness execution и
создание seed через codec не требуют этой проверки.

Операционные callbacks обязательны только для объявленных capabilities:

```erlang
generate(Index, Context) -> {ok, Raw} | {skip, Reason} | {error, Reason}.
mutate(Raw, Operation, #{choice := Choice}, Context) ->
    {ok, Raw, RecipeData} | {skip, Reason} | {error, Reason}.
observe(Raw, PrimaryOutcome, Context) ->
    {ok, LocalFeatureIds} | {skip, Reason} | {error, Reason}.
oracle(Raw, PrimaryOutcome, Context) ->
    {pass, Property} | {fail, Property} | {inconclusive, Reason} | {error, Reason}.
shrink(Raw, Context) -> {ok, Candidates} | {skip, Reason} | {error, Reason}.
```

`Reason` для skip/inconclusive — atom; `Property` — ровно `{Id, Version}` из
descriptor. Features: максимум 64 local IDs 0..255. Dispatcher добавляет
`{AdapterId, ObserverVersion, LocalId}`; одинаковые local IDs разных adapters
не смешиваются со structural coverage или друг с другом. Generation/mutation
детерминированы; `choice` 0..65535 приходит из EFZ RNG и записывается в recipe.
Adapter не заводит свой RNG, registry, worker или process per callback.

Для `example_library` со специальным wire format используется domain skeleton:
заменить target call, metadata и observer; при необходимости добавить собственную
Gleam-модель, её имя в `model_modules`, bounded generation/mutation и независимое
свойство. Центральный dispatch не содержит ветвей по имени этой библиотеки.
Observer-only descriptor может иметь `model_modules => []`, `operations => []`,
`properties => []`; config тогда использует `structured_fraction => 0`,
`oracle => disabled`. Generator-only plugin также допустим без observer/oracle,
с отключённым feedback и fraction 0.

Gleam-модель можно поставлять отдельным Erlang/rebar3 dependency: compile/export
её BEAMs заранее, добавить dependency `ebin` и нужные runtime dependencies на
code path opt-in campaign, объявить model modules в descriptor. Обычный EFZ
build не должен скачивать или компилировать такой пакет. Repo optional build
использует pinned Gleam 1.10.0; runtime-off и обычный build не вызывают models.

## 5. Настроить seeds, mutation, observer и oracle

Рабочие campaign maps в [examples/semantic_configs](../../examples/semantic_configs):
`lists_reverse.term`, `maps_find.term`, `tuple_api.term`, `stateful.term`,
`xmlrpc.term`, `cow_qs.term` и `cow_qs_legacy.term`. Seeds созданы реальным codec
с argument specs каждого harness; XML/QS seeds остаются исходными wire binaries.
Эти configs используют `coverage_backend => none` для исполнения и semantic
smoke. Они не заявляют измеренное structural coverage stdlib API.

```erlang
gleam_layer => #{adapter => efz_term_api_adapter,
    adapter_options => #{entrypoint => {lists, reverse, 1},
        arguments => [#{kind => list, item => #{kind => integer}}]},
    structured_fraction => 10, feedback => guided, oracle => disabled,
    oracle_budget => 64,
    limits => #{bytes => 4096, depth => 8, nodes => 128,
                collection => 32, operations => 1}}
```

Generic observer классифицирует outcome и bounded result tree; он не доказывает
корректность библиотеки. Generic oracle остаётся отключённым, пока пользователь
не задаст `adapter_options.property => #{callback => {Module, Function}}` и
`oracle => inline`. Callback получает `(DecodedArgs, PrimaryOutcome)` и возвращает
`true`, `false` либо `inconclusive`; predicate имеет ID
`{generic_custom_property, 1}`, code identity callback фиксируется отдельно.
`stateful.term` явно выбирает независимый counter trace property.

`guided` admits semantic novelty в обычный corpus и parent selection.
`observation_only` сообщает features, но не направляет corpus/scheduler.
`disabled` отключает observer. `structured_fraction => 0` не делает branch RNG
draw или mutation decode; включённые observer/oracle продолжают работать.
`gleam_layer => false` отключает весь dispatch и сохраняет обычный RNG path.

`skip`, unchanged и limit mutation используют обычный byte fallback. Layer
exception/invalid result завершает campaign как infrastructure error самого
adapter; это не library finding и не успешный fallback. `inconclusive` означает
отсутствие обоснованного verdict.
Ожидаемый parser rejection не становится finding без нарушения явно заданного
поддерживаемого свойства. Callbacks inline; исключения перехватываются, но это
не останавливает бесконечный callback. Plugin обязан иметь конечные алгоритмы и
проверять budgets до дорогостоящих allocation/recursion.

Для QS старый config без `adapter` работает только через изолированный legacy
shim исторических `efz_qs_target`/`efz_qs_defect_target`. Это правило не участвует
в подключении новых targets. Явный `efz_qs_adapter` проверяет harness metadata
`#{kind => query_string, outcome => accepted_pairs}`. QS-specific `fields` и
`component` находятся в `adapter_options`, не в общих limits.

XML-RPC использует [pinned etnt/xmlrpc preparation](../../examples/xmlrpc/README.md).
`efz_xmlrpc_target` вызывает `xmlrpc_decode:payload/1` на charlist. Independent
model v1 проверяет printable ASCII methodCall, int/boolean/string и nested
array/struct, с bytes/depth/nodes/collection/string limits. Имена нормализуются
из existing atoms или charlists в binaries, без atom creation.
Response/fault корректность, i4/double/date/base64/nil, implicit strings,
non-ASCII UTF-8 и широкий XML grammar не поддерживаются oracle v1. Observation
может классифицировать response/fault; это не доказательство их корректности.

## 6. Подготовить target-only coverage artifacts

Использовать существующие `efz_instrument:compile/2` либо
`efz_cov_native_public:compile/3`, затем штатный artifact preflight. Выбираются
модули самой библиотеки; adapter/model/property helpers исключаются. Harness
и инфраструктурный codec не являются заменой library coverage. Для built-in
OTP API без подготовленного coverage backend следует честно использовать
`none`/diagnostic и отдельно фиксировать эту границу.

XML-RPC preparation инструментирует `xmlrpc_decode` и `xmlrpc_util`. OTP xmerl
остаётся dependency, его внутреннее coverage не измеряется. `xmerl.hrl`
record defaults требуют документированного `strict => false`; executable
decoder clauses остаются probed. Например для counter fixture:

```erlang
{ok, A} = efz_instrument:compile("examples/stateful/efz_stateful_counter.erl",
    #{modules => [efz_stateful_counter], outdir => "/tmp/counter-artifacts",
      source_root => ".", erl_opts => [debug_info, warnings_as_errors]}).
```

После подготовки config меняется на `coverage_backend => ets, artifacts => [A]`
либо CLI получает `--artifacts /tmp/counter-artifacts`. Одного наличия dependency
на code path недостаточно для утверждения, что его coverage измерено.
Для counter fixture отдельно проверены ETS probes в admitted child и cleanup
без оставшихся процессов. Это coverage самого `efz_stateful_counter`; внутренние
модули OTP `gen_server`/`proc_lib` в него не входят.

## 7. Запустить validation и campaign

Из корня EFZ:

```sh
ERL_FLAGS='+S 2:2' rebar3 compile
GLEAM_BIN=/path/to/gleam-1.10.0 ERL_FLAGS='+S 2:2' rebar3 as gleam compile
ERL_FLAGS='+S 2:2' rebar3 eunit --module=efz_term_api_tests
ERL_FLAGS='+S 2:2' escript scripts/fuzz.escript \
  --config examples/semantic_configs/lists_reverse.term \
  --code-path _build/gleam/lib/efz/ebin --out /tmp/reverse-run
ERL_FLAGS='+S 2:2' escript scripts/fuzz.escript \
  --config examples/semantic_configs/stateful.term \
  --code-path _build/gleam/lib/efz/ebin --out /tmp/counter-run
```

`--config` читает ровно одну доверенную Erlang campaign map через `file:consult`.
Code paths загружаются до consult/preflight. Существующие явно переданные CLI
flags переопределяют config; `--seeds DIR` импортирует raw файлы, `--artifacts DIR`
переопределяет artifacts. `--out` остаётся обязательным. Config не хранит
исполняемый closure, resource PID или секрет. Trusted config может задавать atoms;
это отдельная граница от недоверенных fuzz bytes. Прежние CLI flags не переименованы.

Startup выявляет неизвестный adapter, отсутствующий обязательный callback/model,
несовместимые metadata/options, неподдерживаемые capabilities и coverage selection.
`--gleam-layer` без explicit adapter остаётся историческим QS CLI compatibility
path; новые integrations используют config с `adapter`.

Для XML-RPC сначала выполнить `examples/xmlrpc/prepare.escript`, затем добавить
`_build/xmlrpc-example/dependency-ebin` и `_build/xmlrpc-example/harness-ebin`
через `--code-path`. Для QS добавить `_build/default/lib/cowlib/ebin`.
Полная проверка изменения включает ordinary/optional build, runtime-off,
релевантные EUnit/CT, xref/Dialyzer и finite campaigns с report/artifact evidence.
Сравнительные результаты должны отдельно указывать wall-clock, execution budget,
calibration/mutation/extra executions, provider outcomes, coverage и adapter-local
semantic novelty. Feature counts разных adapters не являются общей шкалой.
Callback microbenchmark не заменяет campaign throughput или discovery evidence.

## 8. Проверить persistence, replay и минимизацию

Canonical corpus хранит raw binaries. Restart калибрует inputs заново текущим
adapter и не доверяет сохранённым semantic features другой модели. Existing
`corpus_build_policy => reject | recalibrate` определяет mismatch policy.
Adapter/model/options/limits, observer/property и operation catalogue versions,
code/execution identities и RNG provenance входят в существующую metadata.
Identity также фиксирует SHA-256 детерминированного portable prepared context;
cold context должен воспроизводиться, иначе replay получает mismatch.

Восстановление raw input и его выполнение — отдельные операции.
`efz_recipe:load/1` и `efz_recipe:regenerate/1` для schema 4 восстанавливают
сохранённые raw replacement bytes и проверяют recipe/RNG provenance средствами
ядра EFZ. Они не загружают adapter/model, не выполняют target и не декодируют
opaque adapter options/RecipeData. Historical QS recipe schemas сохраняют
прежние raw replay гарантии.

Выполнение восстановленного input требует target/harness/dependency artifacts,
без semantic callback dispatch, adapter или model BEAM. Generic harnesses из
этого руководства используют model-free `efz_term_codec:execute/2`: требуется
codec BEAM, как обычная execution dependency. Wire-format harnesses вызывают
библиотеку напрямую. Пользовательские harnesses также должны отделять свои
execution dependencies от optional semantic callbacks.

`efz_recipe:regenerate_semantic(Recipe, PreparedLayer)` заново вызывает
structured mutation с сохранёнными operation/params и проверяет совпадение
raw bytes и RecipeData. Эта opt-in проверка требует свежего prepared context
из доверенного config, точного adapter identity и доступных adapter/model
BEAMs. Она также не выполняет target. Semantic property replay ниже проверяет
уже outcome реального target execution и требует собственный property contract.

```erlang
{ok, Expected} = efz_semantic_replay:load("finding.semantic"),
ReplayOptions = #{timeout => 1000, coverage_backend => none,
                  gleam_layer => TrustedLayerConfig},
efz_semantic_replay:run(Raw, Target, TargetArtifacts, Expected, ReplayOptions),
efz_semantic_replay:minimize(Raw, Target, TargetArtifacts, Expected,
    ReplayOptions#{minimization_timeout_ms => 30000}, 64).
```

`none` соответствует smoke configs выше. Для сохранённых ETS/native artifacts
нужно выбрать исходный `coverage_backend` и передать именно эти artifacts.

Тот же контракт доступен через общий CLI без библиотечных ветвей:

```sh
ERL_FLAGS='+S 2:2' escript scripts/gleam_replay.escript \
  --config trusted-campaign.term --finding /path/to/finding-prefix \
  --budget 64 --out /tmp/new-replay-result \
  --code-path _build/gleam/lib/efz/ebin --code-path /path/to/harness/ebin
```

Trusted config задаёт `target`, `artifacts`, `coverage_backend`, `gleam_layer`,
`timeout` и optional `max_input_bytes`; seeds и corpus не выполняются этим CLI.
Replay поддерживает `ets`, `ets_member`, `otp_native_public` и `none`;
campaign backend `bitmap` этим replay execution API пока не поддерживается и
отвергается до target execution. Ошибки options/config завершаются с exit2.
CLI сначала выполняет cold validation с effective limits доверенного config и
сравнивает полный adapter identity. Увеличение или уменьшение этих limits
относительно finding приводит к mismatch до target execution; recorded byte
cap finding не подменяет явно выбранный больший лимит config. При этом ни cold
validation, ни чтение finding не вызывают target.
Finding не выбирает executable code: читаются только `.input` и `.semantic`,
diagnostic `.term` не нужен. Output directory должен отсутствовать, включая
symlink; результаты создаются только после фактического reproduction.
`not_reproduced` и `inconclusive` завершают CLI с exit1 до minimization и без
output. Budget 1..10000 включает initial replay и все target executions
минимизатора: при budget 1 сохраняется только `replay.*`, при большем budget
также `minimized.input`, `minimized.semantic` и `minimization.term`.
Настоящий deadline/budget status и total executions сохраняются в результате.
Минимизатор использует deadline 30000 ms: после него новые candidate executions
не планируются; уже начатый execution ограничивает отдельный target `timeout`.
Если final verification пропущена из-за budget/deadline, это явно записано как
`{skipped,budget}` или `{skipped,deadline}`. Сохранённый input воспроизвёл predicate
при последней проверке кандидата (либо initial reproduction, если input не
менялся); дополнительная финальная проверка в этом случае не заявляется.

Прежняя пятиаргументная команда сохраняется как явно ограниченный QS legacy
helper и делегирует `scripts/gleam_replay_legacy.escript`. Его исторические
target names, native `cow_qs` artifact и diagnostic JSON остаются только в
этом helper; новые подключения используют `--config`.

Semantic property replay требует explicit trusted caller config, matching
adapter/model/property/target identities и code path. Artifact сам не выбирает
adapter или callback module. Несовместимость отвергается, predicate не заменяется
тихо. Минимизация использует тот же property ID/version и predicate, учитывает
каждое target execution, initial reproduction и final verification. Она не
обещает глобальный минимум и сообщает исчерпание deadline/budget. Результаты
сохраняются отдельно; canonical corpus и исходные finding groups не перезаписываются.
