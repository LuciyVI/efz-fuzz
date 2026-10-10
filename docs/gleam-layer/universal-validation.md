# Gleam Layer: реализация и проверяемые результаты

Состояние на 10 октября 2026 года: общий контракт, term/API adapter, QS и
XML-RPC plugins, stateful harness и интеграция persistence/replay реализованы.
Реальные вызовы и основные проверки выполнены до последнего указания пользователя
«Не запускай тесты». После него выполнялись только статический review, правки
replay-скрипта и документации, чтение существующих артефактов.

Полная приёмка остаётся открытой: новый общий replay CLI ещё не запускался,
а сравнительные измерения относятся к более ранним snapshots. Новая изолированная
серия для окончательных исходников не запускалась по указанию пользователя.
Сохранённые измерения ниже не являются performance acceptance или доказательством
ускорения/discovery improvement.

## Исходное состояние и сохранение работы

Baseline: `e4c0244c403d74b041df7e0e2f0dd4465a977453`, ветка `feat/gleam-layer`.
HEAD не изменён. До правок сохранены
[baseline.json](../../artifacts/gleam-layer/20261010-universal/baseline.json),
[user-before.status](../../artifacts/gleam-layer/20261010-universal/user-before.status)
и `user-before.patch`. Изначально присутствовали пользовательские untracked
`artifacts/`, `efz_socket_regression_pack/`, `fuzz/`; reset/clean/stash не выполнялись,
корпусы и findings пользователя не заменялись. Результаты этой работы добавлены
в `artifacts/gleam-layer/20261010-universal/`.

Для старого слоя использован отдельный source checkout через `git archive HEAD`
в `/tmp/efz-universal-baseline-e4c0244`, без изменения основной рабочей копии.
Это отдельный checkout, не Git worktree. Settings: OTP 27.0 / ERTS 15.0,
Rebar3 3.25.0, `ERL_FLAGS='+S 2:2'`, Gleam 1.10.0 из
`/tmp/efz-gleam-toolchain/gleam`. Сетевое получение baseline dependencies
не завершилось; использован существующий локальный pinned dependency cache.
Baseline ordinary/optional compile прошли. Полный baseline EUnit не прошёл:
269 passed, 1 failed и cancelled tests; сохранён
[baseline-eunit-prior.log](../../artifacts/gleam-layer/20261010-universal/baseline-eunit-prior.log).
Сбой включает старые wall-clock ожидания corruption/scheduler tests. Текущие
test wrappers получили увеличенные сроки ожидания; execution budgets и
проверяемые assertions сохранены. Это не исправление производительности baseline.

## Архитектура и публичный контракт

[efz_semantic_adapter.erl](../../src/efz_semantic_adapter.erl) — публичный behaviour;
[efz_gleam_adapter.erl](../../src/efz_gleam_adapter.erl) — cold preflight,
dispatch и единая проверка результатов. Никакого центрального списка новых
библиотек/targets нет. Adapter проверяет совместимость с metadata harness в
собственном `prepare/3`. Один adapter выбирается явно на campaign.

Точные signatures и границы зафиксированы в
[adapter-contract.md](adapter-contract.md):

```erlang
descriptor() -> DescriptorMap.
prepare(Target, Options, Limits) -> {ok, ImmutableContext} | {error, Reason}.
code_dependencies(Context) -> #{semantic => [Module], target => [Module]}.
generate(Index, Context) -> {ok, Raw} | {skip, Atom} | {error, Reason}.
mutate(Raw, OperationId, #{choice => Integer}, Context) ->
    {ok, Raw, RecipeDataMap} | {skip, Atom} | {error, Reason}.
observe(Raw, PrimaryOutcome, Context) ->
    {ok, LocalFeatureIds} | {skip, Atom} | {error, Reason}.
oracle(Raw, PrimaryOutcome, Context) ->
    {pass, {PropertyId, Version}} | {fail, {PropertyId, Version}} |
    {inconclusive, Atom} | {error, Reason}.
shrink(Raw, Context) -> {ok, [RawCandidate]} | {skip, Atom} | {error, Reason}.
```

Обязательны только `descriptor/0` и `prepare/3`; `code_dependencies/1` optional.
Операционные callbacks обязательны, если объявлена соответствующая capability.
Descriptor содержит устойчивый binary ID, API version 1, model/observer/recipe/
operation catalogue versions, capabilities, каталог operation IDs, model modules
и property IDs/versions. Generation index 0..4095; единственный mutation parameter
`choice` 0..65535; catalogue не более 256 уникальных IDs 0..65535. Observer
возвращает максимум 64 local IDs 0..255. Dispatcher создаёт namespace
`{AdapterId, ObserverVersion, LocalId}` и удаляет дубликаты. Shrink возвращает
максимум 64 bounded binary candidates. Все versions 1..65535.

EFZ сохраняет свой loop, RNG, scheduler, mutation plan, feedback и corpus.
Callbacks inline на BEAM, context immutable. Нет нового engine/NIF, модельного
сервиса, обязательного worker или отдельного процесса на callback. API 1 передаёт
завершённый результат единственного primary execution; observation/oracle
не выполняют target повторно. Catch обрабатывает исключения, но не останавливает
бесконечный callback: plugin должен реализовать конечные алгоритмы и budgets.

`skip`, unchanged и limit при mutation используют существующий byte fallback.
`inconclusive` не создаёт finding. Invalid callback/exception — infrastructure
layer error, завершающий campaign, а не ошибка библиотеки. Finding создаёт только
явное нарушение объявленного property на поддерживаемом подмножестве.
Ожидаемый parser rejection вне такого предиката не становится semantic finding.

При `gleam_layer => false` нет semantic dispatch/model decode/дополнительного
RNG draw. При fraction 0 нет выбора structural branch и mutation decode;
отдельно включённые observer/oracle сохраняют свои функции. `observation_only`
не направляет corpus/scheduler. При `guided` semantic-only inputs допускаются
в обычный corpus и участвуют в штатном parent selection.

## Term/API, domain и stateful подключения

[efz_term_codec.erl](../../src/efz_term_codec.erl) сохраняет список arguments в
детерминированном собственном binary codec `EFZT`, schema 1. Он не меняет raw
XML/QS inputs. Поддерживаются signed 64-bit integer, finite float, boolean,
binary, Unicode scalar charlist, proper list, tuple, map и bounded nested
combinations. Atoms допускаются только из конечного набора существующих atoms
доверенного config; fuzz bytes atoms не создают. Return type не задаёт arguments.
Generic observer ограниченно классифицирует outcome/result tree и не доказывает
корректность произвольного API.

[efz_term_api_adapter.erl](../../src/efz_term_api_adapter.erl) использует общие
Gleam primitives `efz_term_model`; новый package на библиотеку не требуется.
Generic oracle по умолчанию disabled. Custom property отдельно задаёт callback
`(DecodedArgs, PrimaryOutcome) -> true | false | inconclusive`, с ID
`generic_custom_property` version 1 и собственной code identity.
Пять structural operations меняют scalar, вставляют/удаляют элемент, заменяют
subtree или преобразуют bounded container в рамках constraints. RNG решения
принимает EFZ и записывает в provenance.

Проверенные подключения одним и тем же adapter:

| API | Harness/config | Аргументы и результат |
| --- | --- | --- |
| `lists:reverse/1` | `efz_term_reverse_target`, [lists_reverse.term](../../examples/semantic_configs/lists_reverse.term) | Integer list → list |
| `maps:find/2` | `efz_term_maps_target`, [maps_find.term](../../examples/semantic_configs/maps_find.term) | Key/map → `{ok, Value}` либо `error` |
| `efz_term_tuple_library:combine/2` | `efz_term_tuple_target`, [tuple_api.term](../../examples/semantic_configs/tuple_api.term) | Map/tuple → Erlang term |
| Stateful counter | `efz_stateful_target`, [stateful.term](../../examples/semantic_configs/stateful.term) | Command list/resource handles → bounded trace |
| XML-RPC | `efz_xmlrpc_target`, [xmlrpc.term](../../examples/semantic_configs/xmlrpc.term) | Raw XML bytes → decoder term |
| cow_qs | `efz_qs_target`, [cow_qs.term](../../examples/semantic_configs/cow_qs.term) | Raw QS bytes → parser pairs/rejection |

Стандартный путь для условной `example_library`: добавить harness с `run/1` и
`semantic_contract/0`, настроить `{Module, Function, Arity}` и arguments,
выбрать `efz_term_api_adapter`. Специальные wire constraints: добавить domain
adapter/model с тем же behaviour. Worker/config/corpus/scheduler/replay не меняются.
Независимый length-prefixed plugin fixture реализован только через
target/adapter/config; observer-only и generator-only fixtures обходятся без
XML/QS model, mutation или oracle. Два разных adapters с local feature ID 1
получают разные namespaces.

Defaults: bytes 4096, depth 8, nodes 128, collection 32, operations 1; maxima:
1 MiB, depth 16, nodes 4096, collection 256. По умолчанию binary/charlist
argument также ограничен collection 32, а не всеми 4096 bytes. Charlist codec
хранит codepoints как tagged integers; преобразование в нужную API кодировку
делает harness. Поддерживаемая арность — 0..min(collection,255). Campaign
decode envelope не может превышать объявленные `semantic_contract.input_limits`
harness. Отдельный fixture проверяет collection 64 со списком длиннее 32.

PID/ref/port/fun нельзя сохранять как переносимые literal inputs. Symbolic
`{'$efz_resource', Handle}` кодируется конечным enum; harness создаёт ресурс
заново на execution/replay и очищает его в `after`. Stateful counter допускает
до 16 команд get/put/add/reset, reset состояния до нуля и новый unregistered
gen_server на каждый input. EFZ guardian требует admitted child spawn; fixture
использует `efz_target:spawn_link/1`, OTP 27 proc_lib metadata и публичный
`gen_server:enter_loop/3`. Эта привязка к OTP 27 документирована; произвольные
unmanaged OTP spawns/ресурсы автоматически не поддержаны. Trace отдельно хранит
`scenario_executions => 1` и `library_operations => N`; setup/cleanup не входят
в N. Проверены независимые outcomes, отсутствие state carryover и cleanup
при исключении/timeout.

## Persistence, identities и compatibility

Используется существующий механизм BEAM/execution identities, а не второе
хранилище. Semantic identity включает descriptor, adapter/model/helper/target
code identities, opaque deterministic options, effective limits и SHA-256
portable prepared context. Property ID/version, observer/catalogue versions
и RNG provenance сохраняются в metadata.

Новые recipes schema 4/operation version 3 содержат bounded raw replacement
и opaque RecipeData. Raw load/regeneration/replay не требуют adapter/model;
generic harness требует обычный codec BEAM как execution dependency.
`regenerate_semantic/2` — отдельная opt-in проверка mutation callback с exact
identity. Semantic property artifacts schema 2 требуют явного trusted config,
matching target/harness/adapter/model/property identities. Artifact не выбирает
код. Restart хранит canonical raw bytes и пересчитывает feedback штатной
calibration; mismatch следует `reject | recalibrate`, чужие features не
используются молча.

Минимизация сохраняет тот же property ID/version/context/predicate, учитывает
initial reproduction, все candidates и final verification. Structural shrink
только предлагает кандидатов существующему predicate; затем работают byte
reductions. Canonical corpus и исходные finding groups не перезаписываются.
Budget/deadline exhaustion отражается явно; глобальный minimum не обещается.

QS модель `efz_qs_model` сохранена. Специфические операции, лимиты, outcomes,
features и `query_model_agreement` перенесены в `efz_qs_adapter`.
`efz_qs_legacy` содержит только прежний implicit config для двух исторических
QS targets; это не путь подключения новых библиотек. Старые direct facade
signatures, recipe schemas 1/2/3 и QS finding schema 1 сохраняют прежние гарантии.
Legacy mutation сохраняет прежние RNG draws; новый explicit adapter записывает
ещё `choice`, поэтому campaign traces нового и старого config не обязаны совпадать.

Фиксированный before/after probe сравнил 24 generation cases, 11 fixtures,
66 операций, decode/outcome/features/oracle. Results идентичны, SHA-256:
`daa8274871c75cc0a611e9509b5154b9d1a335d6ac986694f103ada30cd6c87e`.
См. [qs-compatibility.json](../../artifacts/gleam-layer/20261010-universal/qs-compatibility.json).
Это fixture evidence дополняет реальные regression tests, не заменяет их diff.

Общий `scripts/gleam_replay.escript` теперь принимает `--config`, `--finding`,
`--budget`, `--out`, repeated `--code-path`. Cold preflight сравнивает effective
trusted limits/identity до execution; workflow budget включает replay и
минимизатор. Output создаётся после reproduction, существующий каталог/symlink
отвергается. Пятиаргументный QS body вынесен в отдельный
`gleam_replay_legacy.escript`. **Новый wrapper и forwarding статически просмотрены,
но не проверены исполнением после указания не запускать тесты.** Основные Erlang
replay/minimization APIs проверены ранее.

## XML-RPC: фактическая граница

Использован etnt/xmlrpc commit
`fb46463b2acadf164ec534d9e2033e194341c507`, с подготовкой identity/artifacts в
`_build/xmlrpc-example/`. `efz_xmlrpc_target:run/1` преобразует raw binary в
charlist и вызывает настоящий `xmlrpc_decode:payload/1` один раз. HTTP/TCP,
прикладные methods и encoder не используются.

Независимая Gleam модель v1 поддерживает methodCall, параметры, explicit int32,
boolean 0/1, string, nested array/struct. Printable ASCII U+0020..U+007E и пять
predefined XML entities; ограниченный exact XML grammar. Example limits:
4096 bytes, depth 8, nodes 128, collection 16, string/name 128 bytes. Method/member
names из existing atoms или charlists нормализуются в binaries без atom creation.
Сравниваются semantic values independent model и actual decoder, а не XML bytes.

Oracle/generation/mutation не поддерживают response/fault, i4, double, date,
base64, nil, implicit strings, non-ASCII UTF-8, широкий XML grammar, inter-tag
whitespace, attributes, self-closing tags, numeric entities, DTD, CDATA и namespaces.
Observer может классифицировать response/fault; это не oracle их корректности.
Encoder properties и semantic round-trip также не реализованы. Его atom name
требования/iolist output не расширяют decoder predicate.

Target coverage: только prepared `xmlrpc_decode`/`xmlrpc_util`. `xmerl_scan`
участвует в execution identity, но его внутреннее coverage не измеряется.
`strict => false` нужен для record defaults из xmerl.hrl; executable decoder
clauses имеют probes. Adapter/model/observer/oracle/core helpers не входят в
target coverage. Stdlib APIs без подготовленных artifacts используют `none`.

## Уже выполненные проверки

Команды ниже — запись выполненных запусков. После запрета пользователя они
не повторялись. Логи находятся в `artifacts/gleam-layer/20261010-universal/`.

| Команда / проверка | Сохранённый результат | Лог/артефакт |
| --- | --- | --- |
| `ERL_FLAGS='+S 2:2' rebar3 compile` | PASS; default build без Gleam/model | `compile-final.log` |
| `ERL_FLAGS='+S 2:2' rebar3 eunit` | 300/300 PASS до добавления CLI tests | `eunit-off-final.log` |
| `ERL_FLAGS='+S 2:2' rebar3 eunit --module=efz_semantic_cli_tests` | 3/3 PASS | `semantic-cli-off-final.log` |
| `ERL_FLAGS='+S 2:2' rebar3 ct` | 3/3 PASS | `ct-final.log` |
| `ERL_FLAGS='+S 2:2' rebar3 xref` | Exit 0, без предупреждений | `xref-final.log` |
| `ERL_FLAGS='+S 2:2' rebar3 dialyzer` | Exit 0, без предупреждений | `dialyzer-final.log` |
| `ERL_FLAGS='+S 2:2' GLEAM_BIN=/tmp/efz-gleam-toolchain/gleam rebar3 as gleam compile` | PASS | `optional-compile-final.log` |
| `ERL_FLAGS='+S 2:2 -pa /home/fbogoslavskii/efz-fuzz/_build/xmlrpc-example/dependency-ebin' GLEAM_BIN=/tmp/efz-gleam-toolchain/gleam rebar3 as gleam eunit` | 368/368 PASS, exit 0 | `eunit-optional-final.log` |
| Все 7 example configs через `scripts/fuzz.escript --config … --max-iterations 2` | Exit 0; unknown adapter exit 2 | `cli-final/results.json` |
| Generic/domain scaffold, compile `-Werror`, seed call, CLI; повторное создание | PASS; repeat exit 2 и исходные hashes неизменны | `scaffold-final.json` |
| Before/after QS fixture probe | Exact equality | `qs-compatibility.json` |

Поведенческие проверки покрывают direct BEAM dispatch, разные API/арности,
nested codec/mutation bounds, finite atoms/resources, state reset/cleanup,
missing/optional callbacks, unknown adapter/options/capabilities, model ABI,
layer errors, malformed/rejection/fallback, deterministic RNG provenance,
semantic-only corpus admission/parent selection, restart/recalibration,
raw replay в отдельной VM без adapter/model BEAMs, semantic identity mismatch,
raw/semantic regeneration, predicate-preserving minimization и budget/deadline.
XML integration проверяет 18 actual generated calls, 216 mutations и independent
model agreement. Старые QS integration fixtures также сохранены.

Ранние неуспешные логи оставлены: в том числе неверный selection focused tests,
stale test output directory, затем исправленный missing expected_harness в
новом XML raw replay test. Они не представлены как PASS; итоговый optional
full suite прошёл после исправлений. Default full suite 300 и focused CLI 3
не выдаются за один full run 303.

## Сохранённые сравнительные измерения: предварительные

На той же машине Intel i7-1260P, affinity CPUs 0/1, OTP 27 и `+S 2:2`:

* QS old/new/off: 3 повтора, одинаковые шесть seeds, RNG `{17,18,19}`,
  300 mutations + 6 calibration = 306 primary/total executions на sample.
  Отдельный warmup 20 mutations не входит в 306. Backend `otp_native_public`,
  общий target BEAM SHA-256
  `c407d6be5bb023b5ea907ff2bfc69820fe90dc9f39932caf688bcba7ea07464f`,
  target timeout 1000 ms, campaign deadline 120000 ms, driver timeout 135 s.
* Generic/XML/stateful off/on: 3 повтора, один одинаковый seed каждого API,
  RNG `{17,23,41}`, 100 mutations + 1 calibration = 101 primary/total executions,
  extras 0; target-only ETS, timeout 1000 ms, campaign deadline 30000 ms,
  driver timeout 45 s, campaign warmup 0. Generic — tuple library combine/2.

Все сохранённые QS 9/9 и остальные 18/18 samples завершили execution budget,
exit 0 и без driver timeout. Это completed snapshots, не ранний timeout,
названный completed. Медианы wall включают campaign setup/calibration; driver
wall с запуском VM сохранён отдельно в runs.json.

| Snapshot / mode | Медиана wall, ms | Диапазон wall, ms | Primary/s | Coverage | Semantic-only novelty | Provider success / fallback |
| --- | ---: | --- | ---: | ---: | ---: | --- |
| QS old | 739.309 | 713.198..753.390 | 413.900 | 47 | 1 | 11 / 16* |
| QS new explicit | 723.828 | 722.336..729.559 | 422.752 | 48 | 1 | 9 / 22 |
| QS off | 756.010 | 742.380..771.641 | 404.757 | 46 | 0 | 0 / 0 |
| Generic off | 1332.773 | 495.633..1693.731 | 75.782 | 1 | 0 | 0 / 0 |
| Generic on | 314.443 | 307.972..370.118 | 321.203 | 1 | 1 | 7 / 4 |
| XML-RPC off | 1740.152 | 461.274..1854.316 | 58.041 | 26 | 0 | 0 / 0 |
| XML-RPC on | 1923.890 | 1865.013..2250.691 | 52.498 | 37 | 1 | 5 / 5 |
| Stateful off | 524.489 | 327.623..1620.321 | 192.568 | 6 | 0 | 0 / 0 |
| Stateful on | 337.611 | 334.484..389.764 | 299.161 | 6 | 1 | 3 / 5 |

Fallback здесь прочитан из raw counters, а не ошибочного прежнего aggregate.
`*` Old QS не имел общего fallback counter: 27 attempts − 11 successes = 16,
также 3 limit + 11 unsupported + 2 unchanged. В старых summary XML/stateful/new
QS unchanged повторно прибавлялся к уже включавшему его fallbacks; summary
содержит соответственно 6/6/26 вместо 5/5/22. Исходные артефакты не переписаны;
drivers исправлены для будущей серии.

Stateful cost в этой серии — стоимость всех input executions, включая codec
rejection, не изолированная стоимость принятого сценария. Из canonical packets
восстановлены: off 1 valid scenario/3 команды/100 rejected packets, on
5 valid scenarios/14 команд/96 rejected packets. Это реконструкция planned
operations, не runtime aggregate выполненных gen_server calls. Поле старого
summary `primary_scenarios=101` неправильно называло 101 primary input execution.
Outcome fixture различает 1 scenario/N operations; отдельное полноценное
измерение accepted scenarios и actual operation totals остаётся открытым.

Callback microbenchmark отдельно: 3×1000 calls на каждый path, 100 warmup calls,
один setup target execution вне timing, measured target executions 0. Медианы
direct adapter / validated facade, µs:

| Callback | Generic | QS | XML-RPC |
| --- | --- | --- | --- |
| Generation | 0.943 / 1.003 | 0.211 / 0.270 | 0.499 / 0.560 |
| Mutation | 1.935 / 2.394 | 2.539 / 3.552 | 1.494 / 1.890 |
| Observation | 0.479 / 1.251 | 0.250 / 0.491 | 0.187 / 0.490 |
| Oracle | 0.024 / 0.060 | 1.531 / 1.672 | 0.581 / 0.669 |

Generic oracle здесь `inconclusive,no_property`, не стоимость проверки API.
Это fixed-input callback cost, а не все возможные размеры/форматы. Features
разных adapters не сопоставляются как общая шкала.

Evidence:
[performance-final manifest](../../artifacts/gleam-layer/20261010-universal/performance-final/manifest.json),
[runs](../../artifacts/gleam-layer/20261010-universal/performance-final/runs.json),
[QS manifest](../../artifacts/gleam-layer/20261010-universal/qs-performance-final/manifest.json),
[QS runs](../../artifacts/gleam-layer/20261010-universal/qs-performance-final/runs.json),
individual summary.json и *-callbacks.json.

Почему status предварительный: source hashes performance-final уже расходятся
с текущими core/codec/worker и driver; QS manifest фиксирует общий target и
ограниченную часть engine identities, но не весь финальный plugin/dispatcher.
В прежней серии также был overlap подготовки artifacts с другим измерением.
При n=3 с одинаковыми RNG traces и наблюдаемом wall разбросе нельзя утверждать
ускорение, лучшую discovery или performance acceptance. Failed preparation
первой QS серии (`cow_inline.hrl` отсутствовал) сохранён отдельно и не породил
подставных результатов.

## Изменённые файлы и оставшаяся проверка

| Группа | Файлы/каталоги | Назначение |
| --- | --- | --- |
| Public boundary/plugins | `src/efz_semantic_adapter.erl`, `efz_gleam_adapter.erl`, `efz_term_api_adapter.erl`, `efz_term_codec.erl`, `efz_qs_adapter.erl`, `efz_qs_legacy.erl`, `efz_xmlrpc_adapter.erl` | Contract, generic codec, preflight, bounded dispatch и private semantics |
| Core integration | `efz_mutation_plan.erl`, `efz_mutation.erl`, `efz_worker.erl`, `efz_semantic.erl` | Adapter catalogue, RNG provenance, single-outcome callbacks и semantic admission |
| Durable APIs | `efz_recipe.erl`, `efz_replay.erl`, `efz_semantic_replay.erl`, `efz_corpus_store.erl`, `efz_semantic_corpus.erl` | Versioned identity/restart/replay/reduction/minimization |
| CLI/build | `efz_cli.erl`, `rebar.config`, `scripts/build_gleam.sh`, `gleam_replay*.escript`, `semantic_scaffold.escript` | Trusted config path, optional models и reusable scaffolding |
| Models/examples | `gleam/efz_semantic/src/efz_term_model.gleam`, `efz_xmlrpc_model.gleam`, `examples/{term_api,stateful,xmlrpc,semantic_configs}`, QS metadata | Реальные reusable подключения; исходная QS model сохранена |
| Behaviour evidence | `test/efz_{plugin_*,semantic_api,semantic_cli,semantic_portability,term_api,xmlrpc_adapter}*`, regression tests | Boundary, lifecycle, identity, persistence и compatibility |
| Comparative evidence | `scripts/{run_semantic_bench.py,run_qs_semantic_bench.py,semantic_bench.escript,gleam_bench.escript,qs_compatibility_probe.escript}` | Finite serial drivers, manifests и before/after probe |
| Docs | `adapter-contract.md`, `connecting-erlang-libraries.md`, `user-guide.md`, этот отчёт, XML README | Public contract, 8-step guide, configs/limits и validation status |

Без новых запусков завершены review replay CLI и учёт сохранённых результатов.
Открыты runtime/syntax verification нового replay CLI и legacy forwarding,
финальная изолированная comparative серия и измерение actual accepted stateful
scenario/operation costs. Подготовленные команды для будущего запуска, здесь
**не выполнялись**:

```sh
python3 scripts/run_semantic_bench.py --out /tmp/efz-semantic-verified
python3 scripts/run_qs_semantic_bench.py \
  --baseline /tmp/efz-universal-baseline-e4c0244/_build/gleam \
  --out /tmp/efz-qs-verified
```

Практическое руководство, templates и configs:
[Подключение Erlang-библиотеки к Gleam Layer](connecting-erlang-libraries.md).
Execution envelope ограничен доступным code path, разрешённым lifecycle EFZ,
воспроизводимым harness и реально подготовленным target coverage. Внешние
services, устройства, custom ports/NIFs, unmanaged processes и иные resources
требуют отдельных adapters/harness/environment checks. Наличие общего контракта
не выводит семантику произвольной библиотеки автоматически.
