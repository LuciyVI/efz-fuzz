# P4: oracle и feedback корпуса — PASS

[English](../../../gleam-layer/p4-feedback.md) · **Русский** · [Español](../../es/gleam-layer/p4-feedback.md) · [简体中文](../../zh-CN/gleam-layer/p4-feedback.md) · [Все языки](../../README.md)

Текущая приёмка P5 записана в [p5-validation.md](p5-validation.md).
Утверждения о передаче и незавершённом статусе ниже описывают исторический запуск этапа.

Требования **2.0-native**; вектор contract/model/codec/mutator/feature/property
**{1,1,1,1,1,1}**. Пакет **1.1.0**, холодный генератор **2**, recipe schemas **1/2/3**
не меняются. Дата: 2026-10-08. Toolchain: OTP **27.0** / ERTS **15.0**,
Rebar3 **3.25.0**, Gleam **1.10.0**. Dependency locks не меняются.

Доказательства: `artifacts/gleam-layer/20261008-p4-feedback/`; см. `gates.json`,
`proofs-complete/proofs.json`, девять соответствующих raw `.term` proofs и
`p4-changes.patch`. HEAD остаётся `79d76221c6bc5df30b80e6b0de947f3860f4fa4b`.
Начальные HEAD, dirty/index patches и 65 file fingerprints сохранены.
[Общие требования](../../../../efz_gleam_native_subagent_prompts/01_COMMON_CONTEXT.txt),
[путь исполнения P0](execution-path.md), [контракт P1](contracts.md),
[P2](p2-integration.md) и [P3](p3-provider.md) прочитаны до изменений.

Начальный checkout уже содержал чистые observer/oracle и guided
worker/corpus dispatch. Этот проход проверяет полный путь, ужесточает
точную границу метаданных и добавляет принадлежащий корпусу read-only запрос представителей.
Ведущий отвечает за эти изменения и fixtures; субагенты и независимый review не
заявляются. Новый scheduler, corpus, engine, native bridge или instrumentation отсутствуют.

## Фактическая карта исходников

| Ответственность | Фактический file:function |
| --- | --- |
| Завершённое исполнение / неизменяемый снимок | `src/efz_guardian.erl:finish/2`, `src/efz_executor.erl:run_pinned/4` |
| Существующий структурный предикат | `src/efz_feedback.erl:evaluate/3`, `native_success/5` |
| Завершённый outcome → callbacks | `src/efz_worker.erl:execute_result/6`, `semantic_callbacks/4`, `semantic_observe/5`, `semantic_oracle/5` |
| Проверяемая прямая BEAM-граница | `src/efz_gleam_adapter.erl:observe/3`, `summary/1`, `oracle/3`, `oracle_model/3` |
| Реальные скомпилированные typed callbacks | `gleam/efz_semantic/src/efz_qs_model.gleam`; BEAM `efz_qs_model:observe/4`, `check/2` |
| Текущий допуск / последовательный владелец | `src/efz_worker.erl:retain_layer/4`, `src/efz_corpus.erl:semantic_admission/6`, `add_checked/3` |
| Хранение / совместимый restore | `src/efz_corpus_store.erl:save/4`, `restore/3`; `src/efz_corpus.erl:init/1` и worker calibration |
| Активные представители / консервативное сокращение | `src/efz_corpus.erl:semantic_representatives/0`; `src/efz_semantic.erl:representatives/1`, `cover/1` |
| Существующий выбор родителя | `src/efz_corpus.erl:select/0`, `mutation_entries/0`; `src/efz_mutation_plan.erl:next/2`, `visit/2` |
| Находка / fingerprint | `src/efz_worker.erl:record_failure/4`, `src/efz_crash.erl:signature/2`, `save/4` |
| Raw property replay / минимизация | `src/efz_semantic_replay.erl:run/5`, `minimize/6`, существующий `src/efz_recipe.erl:execute/5` |
| Неизменённый реальный парсер | `examples/query_string/efz_qs_target.erl:run/1` → закреплённый `cow_qs:parse_qs/1` |

## Контракт свойства и outcome

**query_model_agreement / 1** сравнивает упорядоченные поля завершённого настоящего парсера
с отдельно реализованным supported-query decoder. Предусловия:
binary ≤4096 bytes, canonical поддерживаемая форма, ≤32 явных поля с непустым именем,
каждый name/value ≤128 bytes; без намеренного bad escape. Произвольные байты принимаются
как байты. Это expected-result свойство, не независимый differential
oracle и не `decode(encode(model))`.

| Результат | Предикат / политика |
| --- | --- |
| Pass | Завершённый `{ok,{accepted,Pairs}}` совпадает с поддерживаемыми ordered binary fields |
| Fail | Принятый результат отличается или парсер отклоняет поддерживаемый canonical query |
| Inconclusive | Неподдерживаемый query, model/byte limit, target exception/timeout или исчерпанный check budget; причина сохраняется |
| expected_rejection | Перечисленные harness parse errors возвращают `rejected`; сами по себе они не находки |
| target_exception / target_timeout | Существующая классификация находок цели и lifecycle cleanup |
| semantic_layer_error | Ограниченная диагностика/counter; остановка через infrastructure failure, никогда не ordinary fallback или target bug |
| infrastructure_error | Существующая политика coverage/lifecycle/configuration/storage failures |

Минимизируемый предикат — то же версионированное свойство, возвращающее **Fail** для
неизменённых target/build. Unsupported, timeout и Inconclusive не сохраняют
нарушение. Fingerprints используют существующую class/category/frame политику EFZ; property ID,
version, target builds и исходный outcome остаются в semantic sidecar.
Находки цели сохраняются до вызова observer, поэтому последующая ошибка слоя
не может их стереть. Oracle failures независимо входят в тот же finding pipeline.
Текущая политика EFZ продолжает после находок и останавливает infrastructure failures;
`crash_policy` управляет fingerprints/representatives, не новой опцией остановки.

## Конечный семантический словарь

Feature = `{<<"cow_qs">>,1,Id}`. ID — точные sorted tuples без hashes,
вероятностных коллизий, dynamic atoms, неограниченных строк или runtime identities.
Structural units остаются native module/build/line units в существующей schema.

| ID | Значение |
| --- | --- |
| 0 / 1 / 2 / 3 | Accepted / expected rejection / target timeout / target exception |
| 4 / 5 / 6 / 7 | Число принятых пар: 0 / 1 / 2 / ≥3 |
| 8 / 9 | Пустое binary-значение присутствует / отсутствует |
| 10 / 11 | Байт ≥128 в возвращённых name/value присутствует / отсутствует |

Принятое исполнение выдаёт четыре признака; остальные outcomes — один. Observer
сводит завершённый outcome без декодирования входа или исполнения цели.
Проверка границы принимает proper lists максимум из 100 пар, binary-компоненты
≤4096 bytes и name-only представление Cowlib `true`. Сам закреплённый Cowlib
ограничивает query keys числом 100. Некорректный output — layer error. Oversized input —
учитываемый observation skip без выведенных признаков.

CurrentFeatures — новый локальный список; SeenSemantic принадлежит владельцу корпуса.
Seen и каждый объединённый набор entry имеют максимум 12 ID. На этой 64-битной VM измеренные
flat sizes — 288 bytes для четырёх features, 864 bytes для всех 12 и 896 bytes
для выведенной representative map с 12 ключами. Это консервативные размеры terms, не
полная VM memory или corpus size. Cache, queue, semantic ETS или persistent active
index не выделяются. Entry metadata масштабируются с существующим корпусом EFZ; новый
глобальный предел ёмкости корпуса не вводится.

## Допуск, постоянное хранение и retention

Для успешных primary outcomes (включая `{ok,rejected}`) сохраняется
структурная причина EFZ и добавляется:

```text
SemanticNew = CurrentFeatures minus corpus.semantic_seen
KeepNewInput = ExistingStructuralKeep OR nonempty(SemanticNew)
```

Начальные seeds/calibration и прочие существующие причины сохраняются. Exceptions
и timeouts используют существующий канал находок; их observation IDs не
допускают неуспешные исполнения, как согласовано в P1. Disabled и observation-only исполняют
обычный admission path. Observation-only не хранит historical seen state;
guided начинает/перестраивает свежую историю корпуса при старте кампании.

Существующий gen_server сериализует novelty, persistence и commit. Новые raw
input/metadata сохраняются до добавления entries или seen. Failure/rejection оставляет
seen неизменным; без хранилища commit — вставка в память.
Аннотации существующих входов объединяют evidence без дублирования raw corpus entries
и без потери исходной причины допуска. Semantic-only entries используют обычные
storage, `select/0` и staged `mutation_entries/0`; energy policy не меняется.

Restart проверяет EFZC/record/namespace версии, затем явно калибрует
текущие raw corpus entries для перестройки annotations/seen до мутаций. Эти
исполнения сообщаются как calibrations отдельно от mutation executions.
Старые EFZC records 1/2 и текущая semantic record 3 поддерживаются. Несовместимые
feature schemas отклоняют restore. Сохранённый global seen index не переживает ручное
удаление между кампаниями; recalibration отражает оставшихся представителей.

Онлайн-корпус append-only. Холодный `cover/1` сохраняет записанные structural
probe/count unions и всех semantic representatives, защищая initial или
uncalibrated entries. Тесты применяют подмножество к **новому** store и перезапускают его;
исходный корпус сохраняется. Нет online deletion/refcount transaction
или глобально оптимального reducer. Правка файлов корпуса во время кампании не поддерживается.
Read-only запрос представителей выводит один working ID на признак и проверяет,
что все seen features по-прежнему представлены.

## Интервал покрытия и oracle

`reset → target → controlled-tree completion/cleanup barriers → sealed snapshot
→ observer/pure oracle → admission/finding handling`.

Native counters имеют область модуля. Существующий guardian отклоняет параллельное
локальное исполнение цели с `runner_busy`, завершает управляемых потомков, дожидается
trace barriers и публикует только после cleanup; caller ждёт guardian
DOWN. Тесты подтверждают смерть delayed child, неизменность native counters
после его deadline и baseline coverage следующей итерации.
Выбирается только `cow_qs`; helpers/Gleam/oracle не добавляют target units.
Неуправляемые вызовы выбранных модулей в той же VM остаются вне этого контракта.

Production oracle прямой, ограниченный, чистый и добавляет **ноль** target executions.
Budget по умолчанию 64, максимум 10000, включая calibration. Он проверяет каждое
исполнение до исчерпания независимо от structural novelty; оставшиеся проверки
явно Inconclusive/budget и учитываются как skipped. Этот детерминированный префикс
не заявляет проверку всех входов или статистическую выборку. Expensive/deferred
oracle, worker protocol, queue или parallel replay не поддерживаются; deferred отклоняется
при старте. Явные cold replay/minimization используют отдельные сериализованные интервалы EFZ
и сообщают свои target executions. Native cancellation не заявляется.

## Выполненные acceptance-доказательства

| Проверка | Команды / результат (все перечисленные exit 0) |
| --- | --- |
| Полные on-регрессии | `rebar3 as gleam eunit`: **313** тестов; `full-on-tests.json` |
| Финальное focused native-доказательство | `rebar3 as gleam eunit --module=efz_gleam_feedback_tests`: **11** тестов; `snapshot-test-build.json` |
| Экспортированные финальные raw proofs | `export_proofs.escript`: повторяет **11** тестов в своей VM, safe-декодирует/копирует **9** proofs; `export-proofs-final.json` |
| Clean off без компилятора | Частный source-only `/tmp/efz-p4-off-vg8psokv`, изначально без package/compiler/BEAM; `rebar3 compile` и focused EUnit **55** тестов, `clean-off-compile.json`, `clean-off-tests-r2.json` |
| Off runtime / term compatibility | `off_check.escript`: нет Gleam/helper/application/state, обычная кампания и существующий term target проходят; `off-runtime-check-r2.json` |
| Другие backends / static calls | `rebar3 ct`: **3** теста; `rebar3 as gleam xref`; `ct-regression.json`, `on-xref.json` |
| Observation neutrality | Две реальные staged-кампании, seed 17, fraction 0, **200** мутаций: каждый candidate hash/stage/parent совпадает, идентичные corpus/coverage; `observation-sequence-proof.json` |
| Finding CLI | `scripts/gleam_replay.escript … efz_qs_defect_target 64 …`: воспроизведено за **1** исполнение, минимизировано до `bug=` за **34**; `finding-cli-replay.json` |

Для A входы `613d31` (`a=1`) и `613dff` (`a=` + byte 255) имеют точно
те же **14** native units. Все **9** прослеженных primary sealed bit snapshots —
`67041a2c00000300000000` с теми же decoded units. Features соответственно
`[0,5,9,11]` и `[0,5,9,10]`. Guided допускает второй raw input как `new_semantic`
с пустым `new_probes`; corpus size 2. Фактические parent IDs существующего scheduler —
`[1,2,1,1,2,1,1,1]`. Off/observation-only сохраняет size 1. Повтор не получает
дополнительного зачисления. Trace подтверждает девять compiled Gleam observe calls и ноль
decode calls; контролируемый raw mutator ограничен test-fixture.

B проверяет failed write/retry, 1000 duplicate retries, двух одновременных corpus API
callers с ровно одним зачислением, startup rebuild/schema mismatch, conservative
subset restart и recovery после удаления между кампаниями. Отдельная contract-
fixture выполняет 10000 admission attempts, достигая 12 seen IDs и лишь восьми
entries; target executions ноль, это не доказательство кампании/discovery.

C проверяет target-only coverage, неизменность следующих интервалов и delayed-child
cleanup. Явный отдельный target replay не может менять уже возвращённый основной
снимок. Parallel native-coverage PASS не заявляется.

D использует явно искусственный `efz_qs_defect_target`: добавляет NUL к `bug` value.
Одна calibration и две повторные нормальные мутации дают три oracle failures,
одну finding group, ноль corpus discoveries и неизменные features. Исходные
bytes `bug=11&x=2`, property/version и build metadata сохранены. Скопированные
finding/native artifacts этого запуска поддерживают успешный настоящий CLI replay.
Это проверка подключения; реальный дефект Cowlib или независимое discovery не заявляется.

## Счётчики и samples стоимости

`gleam_stats` сообщает observer calls/skips/us, oracle checks/pass/fail/inconclusive/
skipped/us, expected rejection, timeout/exception и layer errors. Чистый oracle
сообщает ноль дополнительных executions. Budget-fixture: семь primary executions, семь
observations, два Pass checks, включая структурно эквивалентный input, пять
явных skips. Находки обрабатываются без зависимости от admission. В EFZ нет
опции ёмкости корпуса, поэтому отдельное full-capacity условие неприменимо.

Конечный component probe: 10000 повторов, outcomes из модели, без target
execution и production trace. Средние в микросекундах (`component-costs.json`):

| Input bytes / fields | Observer | Pure oracle | Exact set difference | Cold 12-feature index |
| --- | ---: | ---: | ---: | ---: |
| 3 / 1 | 0.28 | 1.34 | 0.46 | 3.31 |
| 4096 / 16 | 14.71 | 304.70 | 0.50 | 3.44 |

Четыре реальные same-engine smoke-кампании используют seed 17, fraction 10%, шесть typed seeds,
по 500 мутаций с отключённым trace:

| Режим | Main calls | Observer calls | Oracle checks / skipped | Corpus / semantic-only | Structural units |
| --- | ---: | ---: | ---: | ---: | ---: |
| Structured, feedback disabled | 506 | 0 | 0 / 0 | 14 / 0 | 48 |
| Observation-only | 506 | 506 | 0 / 0 | 14 / 0 | 48 |
| Guided | 506 | 506 | 0 / 0 | 15 / 1 | 48 |
| Guided + inline oracle | 506 | 506 | 64 / 442 | 15 / 1 | 48 |

Oracle checks: 19 Pass и 45 Inconclusive, без failures. Все кампании
завершились без infrastructure errors; target rejection учитывается отдельно.
Отдельные wall rates (177–226 executions/s) — smoke samples, не превосходство
производительности или выбор оптимума. Worker/message overhead неприменим к
прямым callbacks; существующий target execution overhead вне component samples.

## Diff, ограничения review и передача P5

Production-изменения — `src/efz_semantic.erl` и `src/efz_corpus.erl`: точная
проверка метаданных и холодное выведение/запрос представителей. Новые файлы —
три feedback test/fixture-модуля, `scripts/gleam_feedback_probe.escript` и
этот отчёт. Два явных режима расширяют существующий benchmark driver; обновлены contract,
guide, ownership и decision docs. `p4-changed-files.json` и
`p4-changes.patch` отделяют эти изменения от ранее dirty worktree.
AGENTS, пользовательские prompt archive/texts, target/model/package, locks, coverage, mutation,
worker, findings и replay code в этом проходе не менялись.

Неудачные попытки архивированы: timestamp-sensitive stats assertion, несуществующие
имена test-модулей, safe proof export до загрузки runtime atoms, неверная
none/manual diagnostic configuration. Первое trace-доказательство сравнивало пустые
diagnostic lists; исправленная приёмка использует sealed native bits/nonempty units.
Source-only preparation command сначала столкнулась с именем proof-файла;
повторная подготовка сохраняет раздельные command и source-proof файлы. Ни одна
из прежних попыток не используется как финальное gate evidence.

P5 должен независимо проверить contract/code, выполнить финальные cross-phase регрессии
и реальные discovery-эксперименты, провести воспроизводимые multi-seed same-engine
benchmarks с финальной стоимостью хранения. Сохранить консервативные defaults и raw
representatives. Exact campaign checkpointing, online pruning, deferred oracles
и unmanaged parallel target execution не поддерживаются. Push/PR/commit
не выполнялись; P4 PASS не закрывает P5 или все orchestration prompts.
