# P1: проверка контракта и передача работы

[English](../../../gleam-layer/p1-validation.md) · **Русский** · [Español](../../es/gleam-layer/p1-validation.md) · [简体中文](../../zh-CN/gleam-layer/p1-validation.md) · [Все языки](../../README.md)

Текущая приёмка P5 записана в [p5-validation.md](p5-validation.md).
Утверждения о передаче и незавершённом статусе ниже описывают исторический запуск этапа.

Требования **2.0-native**, контракт **v1**, вектор `{1,1,1,1,1,1}`.
Артефакты запуска: `artifacts/gleam-layer/20261008-p1-contract/` (корень репозитория).
Контракт P1 и исполняемые acceptance-проверки реализованы и протестированы.
Review согласованности ниже — самопроверка автора; независимый reviewer
**не** работал. Это не закрывает весь orchestration package или P5.

## Входы и изменённые файлы

Прочитаны `efz_gleam_native_subagent_prompts/01_COMMON_CONTEXT.txt`, фактический P0
[baseline.md](baseline.md), исходный source snapshot и текущие исходники/тесты.
HEAD остаётся `79d76221c6bc5df30b80e6b0de947f3860f4fa4b`. Этот проход записал
существующий dirty diff до изменений; работа предыдущих этапов не перезаписывалась.
Все девять пользовательских prompt-файлов, их ZIP и `AGENTS.md` сохранили хеши.

В P1 изменены:

- `docs/gleam-layer/architecture.md`: владение EFZ, фактические точки расширения,
  control/data/cold paths, границы покрытия.
- `docs/gleam-layer/contracts.md`: версионированные представления, конфигурация,
  явные RNG transitions, ограничения, ошибки, контракт admission/restart/pruning.
- `docs/gleam-layer/p1-validation.md`, `agent-plan.md`, `decision-log.md`:
  доказательства, ответственность, решения и передача.
- `test/efz_gleam_contract_tests.erl`: дополнительные исполняемые contract-fixtures.
- `src/efz_gleam_adapter.erl`: ограниченные понятные ошибки старта для несовместимых
  options/modes/targets/limits с сохранением успешной и отключённой диспетчеризации.
- `gleam/efz_semantic/src/efz_qs_model.gleam`: проверка ёмкости до prepend/append-
  аллокации; поддерживаемые результаты и семантика отказа не меняются.
- `scripts/build_gleam.sh`: поставляется только вызываемая модель, неиспользуемый
  generated CLI launcher удалён из метаданных runtime application, прежний
  generated BEAM архивирован вне активного ebin. Новый пакет stdlib не добавляется.

Существующее владение/behaviour EFZ и вектор контракта не меняются. Новые
C ABI, NIF, plugin registry, engine или переписывание цели не вводятся.

## Выполненные команды и результаты

Все команды выполнялись из корня репозитория с `ERL_FLAGS='+S 2:2'`, последовательно.
`contract_test_modules` ниже — аргумент EUnit со списком модулей через запятую:

```sh
contract_test_modules=efz_gleam_contract_tests,efz_gleam_layer_tests,efz_config_tests,efz_corpus_store_tests,efz_recipe_tests,efz_mutator_tests,efz_native_public_tests
```

| Проверка / команда | Exit | Результат | Артефакт в каталоге запуска |
| --- | --- | --- | --- |
| `GLEAM_BIN=/no/compiler rebar3 eunit --module="$contract_test_modules"` | 0 | 34 теста пройдены; optional-интеграция не выбрана в off-сборке | `p1-off-eunit.log` / `.json` |
| `GLEAM_BIN=/tmp/efz-gleam-toolchain/gleam rebar3 as gleam eunit --module="$contract_test_modules"` | 0 | 51 тест пройден, реальные Gleam BEAM и native EFZ integration | `p1-on-eunit.log` / `.json` |
| `GLEAM_BIN=/tmp/efz-gleam-toolchain/gleam rebar3 as gleam compile` | 0 | Runtime shipment собран закреплённым Gleam 1.10.0 | `p1-on-build.log` / `.json` |
| То же окружение, `rebar3 as gleam xref` | 0 | Нет неопределённых runtime-ссылок | `p1-xref.log` / `.json` |
| `escript artifacts/gleam-layer/20261008-p1-contract/check_source_refs.escript "$PWD" "$PWD/_build/gleam"` | 0 | 26 явных `file:function/arity` ссылок проверены по compiled abstract forms | `source-references.log` / `.json` |
| `GLEAM_BIN=/no/compiler rebar3 eunit --module=efz_phase2_tests,efz_mutation_tests` | 0 | 42 прежних term/executor и staged-plan теста пройдены | `legacy-compatibility.log` / `.json` |
| `git diff --check` | 0 | Нет whitespace-ошибок в отслеживаемых файлах | `diff-check.log` |

Первый xref Gleam-профиля завершился с **1**: сгенерированный
`efz_semantic@@main:print_term/1` ссылался на отсутствующий `gleam@string:inspect/1`.
`xref.log` / `.json` сохраняют этот сбой. Финальный runtime shipment исключает
неиспользуемый launcher и его объявление модуля application; финальный xref проходит.
Начальные промежуточные EUnit-запуски (34/50) также сохранены. Source-reference
checker сначала отклонил документ без явных path references (exit 127);
это исправлено, финальная проверка ссылок проходит.

Точные commands/env/exit codes и хеши исходников — в `gates.json` и per-check
JSON; полный environment/секреты не сохранялись. `preserved-inputs.json` подтверждает
неизменность пользовательских файлов. `acceptance-proofs-final/` копирует фактические guidance, restart,
coverage attribution и artificial-finding артефакты финальных тестов;
их исходные пути записаны в `acceptance-proofs-final.json`.

## Карта acceptance-fixtures

| Требование | Исполненная fixture / доказательство |
| --- | --- |
| Валидные ADT, законы кодека, произвольные байты | `efz_gleam_layer_tests:codec/0`: canonical empty/binary/duplicate модели; byte-vocabulary differential против закреплённого настоящего Cowlib |
| Некорректные terms, выравнивание, depth/bytes/elements | `boundary_test/0`, `limits_and_failures/0`; `efz_gleam_contract_tests:malformed_model_and_limits_test/0`, `outcome_verdicts/0` |
| Отсутствующий пакет, версии, target/mode/config | `invalid_capabilities_test/0`, `package_capabilities/0`; version stub явно является contract-fault fixture |
| Детерминированные мутации, off/fraction-zero RNG, raw fallback | `determinism/0`, `fallback_rng/0`; одинаковые кандидаты и финальное явное RNG state |
| Runtime-off без callbacks/state | `off_preserves_configuration_test/0`, `runtime_off_callbacks/0`: трассировка вызовов реальной кампании; нет семантического state/report fields |
| Одинаковые structural units, разные semantic facts | `coverage_attribution/0`, `guidance/0`: настоящий native snapshot; semantic-only working entry, затем обычный parent selection |
| Observation-only без изменения допуска | `observer_only/0`, сравнение с рабочими inputs runtime-off |
| Ошибка допуска/retry/повтор признака | `persistence_retry/0`: seen не меняется при неудачной записи; retry успешен, дубликат сохраняет admission reason |
| Сохранение представителей/restart | `reduction/0`, `restart/0`: записанные structural/semantic unions и semantic-only flag сохраняются; сокращение read-only |
| Pass/Fail/Inconclusive, нулевой бюджет | `limits_and_failures/0`, `outcome_verdicts/0`, `zero_budget_random_mode/0`; дополнительных вызовов цели нет |
| Находки независимо от новизны, property replay/minimize | `finding_replay/0`: искусственная fixture, три нарушения при одном рабочем входе; replay того же свойства и ограниченное удаление байтов |
| Ошибка слоя — диагностика, не fallback | `fault_injection/0`: явный fault stub; кампания останавливается до мутационного исполнения цели |
| Schema mismatch / legacy artifacts | `semantic_schema_restore_test/0`, corpus store v1/v2 tests, recipe v1/negative/fresh-VM tests, property-version mismatch test |
| Существующие term inputs / ordinary scheduling | `efz_phase2_tests` comprehension-fixtures включают list/map/tuple terms; `efz_mutation_tests` сохраняет обычные операции, fairness, ограничения и выбор |
| Shipment без optional CLI/stdlib | `runtime_shipment/0`: только модули модели, без старта optional application |

Mocks/stubs закрывают только error-контракты. Реальная модель и EFZ/native coverage тесты
закрывают integration evidence; mock не считается доказательством управления. Известная искусственная
находка — fixture подключения/replay, не независимое обнаружение дефекта.

## Review согласованности исходников

Ведущий сверил P0 и текущих владельцев с [architecture.md](architecture.md):
выбор родителя предшествует structured decode; ordinary retry сохраняет существующие
budget/cursors; off не выбирает дополнительных случайных чисел; исполнение/снимок цели предшествуют чистым
callbacks; принимаются только cow_qs manifests; guardian сериализует интервалы EFZ;
находки предшествуют ошибке observer; corpus фиксирует semantic seen после вставки;
restart отклоняет schema mismatch и калибрует raw bytes; сокращение не
удаляет представителя незаметно. Обнаруженные этим проходом ранняя аллокация, непрозрачная startup-диагностика и unused-launcher
исправлены, затронутые проверки повторены.

Ограничения review: самопроверка автора, без независимого reviewer/субагентов;
неуправляемые вызовы цели в той же VM остаются вне изоляции. Parallel,
deferred или native-interruptible oracle не заявляется. Off-equivalence/performance
серии прежнего запуска не переобозначаются как финальные измерения P5 после
этих изменений исходников. Полная clean-off упаковка и финальные same-engine benchmark-
серии остаются работой P5. Полный prompt package **не завершён**.

## Передача P2/P3/P4 и ответственность

Ведущий отвечает за общие архитектуру/контракты, сборку/конфигурацию, цикл и корпус;
параллельно пишущих исполнителей нет. Любое позднейшее делегирование обязано явно назначить
файлы и передать common context, P0 evidence, этот v1 contract и `gates.json`.

- **P2:** сохранить закреплённый Gleam 1.10.0 и реальные BEAM-вызовы, проверять внешние terms,
  упаковывать только вызываемые runtime-модули и сохранять off-сборку без компилятора.
  Generated Erlang source не является обязательным артефактом сборки. Текущий shipment и
  проверки отсутствующих/несовместимых возможностей имеют реальные тестовые доказательства.
- **P3:** сохранить выведение операций/RNG transitions, принадлежащее EFZ, и существующий план;
  проверять ограничения до аллокации field/byte/output, сохранять намеренно некорректное
  представление и хранить raw bytes/data-only recipe v2. Ни планировщик, ни
  cache/hint policy этим контрактом не разрешены.
- **P4:** потреблять конечные признаки только через сериализованный допуск EFZ, сохранять
  нейтральность observation-only и поведение persistence retry/restart, держать primary
  coverage отдельно и учитывать/ограничивать любое дополнительное исполнение цели. Deferred support
  требует пересмотра capability contract; в v1 он отклоняется.

Это инварианты передачи, не утверждение, что все последующие phase gates или
независимый orchestration review завершены.
