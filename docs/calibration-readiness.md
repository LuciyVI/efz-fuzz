# Аудит готовности EFZ к калибровке и feature_stability

Дата: 2026-09-09. **Вердикт: READY WITH PREREQUISITES.**

Для фиксированной сборки, кооперативной цели и области **одного target-процесса**
уже доступны полные точные множества наблюдений одного исполнения. Второй executor,
новый backend, hit counters или buckets не нужны. Перед достоверной интеграцией
нужны явная причина завершения, контракт полноты/очистки и обработки потери runner,
а затем отдельный сборщик повторов, не вызывающий novelty на каждом повторе.

Для произвольного дерева процессов, stateful OTP-приложения, native/NIF coverage
или восстановления после аварии всей VM текущая реализация **NOT READY**: таких
контрактов/runner нет. Это ограничение области, а не повод выдать их покрытие за
пустое и получить 100%.

В этом задании механизм калибровки **не внедрялся**. Production-код, API, зависимости,
defaults и алгоритмы поиска не менялись. Единственный постоянный новый файл — этот
отчёт. Fixtures, диагностические скрипты и логи находятся в
`/tmp/efz-calibration-audit.rIBEql/`; их исходники включены в приложение для
воспроизведения после удаления временного каталога.

Обозначения доказательств: **К** — обнаружено в текущем коде; **Э** — подтверждено
новым запуском; **Д** — утверждение документации; **П** — предложено, ещё не
реализовано; **НП** — не проверено. Исторические показатели не считаются результатами
этого аудита.

## 1. Checkout, инструменты и действующая архитектура

**К/Э.** Репозиторий — `efz/`, ветка `main`, HEAD
`ac09c1f3e938c3a79b369fc6a87d61c1ae739db4` (`chore: initialize efz OTP project`).
Commit не описывает всю проверенную реализацию: на входе уже были изменения
`README.md`, `rebar.config`, `src/efz.app.src`, untracked каталоги `bench/`, `docs/`,
`examples/`, `fixtures/`, `scripts/`, `test/` и большинство модулей `src/efz_*.erl`.
Полный исходный status/diff сохранён в [status.txt](/tmp/efz-calibration-audit.rIBEql/status.txt)
и [diff.txt](/tmp/efz-calibration-audit.rIBEql/diff.txt).

До запуска сняты SHA-256 всех 78 существовавших файлов из
`git ls-files --cached --others --exclude-standard`. После экспериментов их
содержимое совпало. До добавления отчёта не изменился ни один такой файл.
Не выполнялись reset/clean/stage/commit/push и изменения Git identity/remotes.
Применимых `AGENTS.md` в репозитории и проверенных родительских каталогах нет.

Хеш списка исходного дерева (отсортированные UTF-8 строки
`path + NUL + file_sha256 + LF`) —
`24eafa7e45d6584b1ff2eb03021391c3e299b95df2a51ab7041726c9a612cf23`.
Полный список — [before-sha256.json](/tmp/efz-calibration-audit.rIBEql/before-sha256.json).
Ключевые файлы для привязки выводов к dirty checkout:

| Файл | SHA-256 |
|---|---|
| `src/efz_executor.erl` | `c4a7802a9ac299445b5b6b50fd1ded92ae09e814ad25f4f300054503e6745f47` |
| `src/efz_cov.erl` | `2d32b0aca9c1641e40ab111e844d020004fb5cb9b743d76c40a46385fa4489d0` |
| `src/efz_cov_rt.erl` | `47e84c8f84861ff7ec7817fa34b9b1234af571ce3bf316fe3d2867428dcfb466` |
| `src/efz_cov_manifest.erl` | `4951ecc1f7104fca08928ee7dfa669cfacc8b27cac856961db06f9ea14451544` |
| `src/efz_feedback.erl` | `0be0ecc64e967b776cc990259d569539e520ba7f603e838c444cdd44e2b30bb6` |
| `src/efz_worker.erl` | `3e4f4d383f86b0bfe9af2d6a366fda848818dcb33f85652efd69d325a9e3baa4` |
| `src/efz_instrument.erl` | `c4dfbe3b9caadfc4ed60153d1a6573b152f31fc5b95e34a168a6bea730695351` |
| `src/efz_instrument_pt.erl` | `b781f83981aef57f59a79c42c099a07076002434ceecd2ecef8feb05930766cd` |

**Э.** `rebar3 version`: Rebar3 3.25.0, OTP 27 / ERTS 15.0.
`releases/27/OTP_VERSION` содержит `27.0`. Архитектура
`x86_64-pc-linux-gnu`, ОС Linux. Штатная VM аудита: **16 schedulers, 16 online**;
`ERL_FLAGS`, `ERL_AFLAGS`, `ERL_COMPILER_OPTIONS` не заданы. Основной диагностический
скрипт и три его свежие VM также записали 16 online. Число 4 из Phase 2.1 сюда
не перенесено. Существующие fresh-VM EUnit helper явно используют два schedulers;
это отдельные тестовые настройки, не конфигурация основного измерения.

**К.** [rebar.config](../rebar.config), строки 1–14: минимум OTP 27,
`debug_info,warnings_as_errors`, `src_dirs = ["src","examples/simple_parser"]`,
`deps = []`; `rebar.lock` пустой. Именованных project profiles нет. `compile`
использует default, EUnit/CT — стандартный test profile Rebar3. CI-конфигурации
GitHub/GitLab, отдельного Makefile, Go module/controller или Python управляющего
слоя в текущем дереве не найдено. README перечисляет локальные rebar-команды;
это не доказательство запуска CI. Форматтер/линтер не настроен.

**К/Э.** Это одна Erlang-native OTP-реализация EFZ:

```text
escript / Erlang caller
  efz:start/1 -> efz_sup -> efz_fuzzer
                              |-> efz_corpus (entries, selector RNG)
                              |-> efz_stats
                              `-> efz_worker_sup -> один efz_worker
                                       |-> prepared validation plan
                                       |-> random / staged mutation state
                                       `-> efz_executor:run/4
                                              -> coordinator -> target process
```

`src/efz.erl:start/1`, строки 3–7; `efz_fuzzer:init/1`, строки 17–25;
`efz_worker_sup:init/1`, строка 2. Приложение `efz` версии 0.1.0 зависит от
`kernel`, `stdlib`, `crypto` (`src/efz.app.src:1–18`). Использование crypto не
означает наличия native coverage.

| Поисковый ориентир | Что обнаружено |
|---|---|
| EFZ/ErlFuzz, Go controller, `input_coverage` | В актуальном runtime — EFZ, Erlang; остальные имена/режим не найдены |
| `efz_instrument`, `efz_cov`, `efz_feedback`, `efz_executor` | Существуют |
| `efz_cov_runtime`, `efz_run_context` | Фактически `efz_cov_rt` и tuple context в `efz_cov`; модулей с указанными именами нет |
| `efz_value_runtime`, `efz_hook_runtime`, `efz_data` | Не найдены; value/transition feedback отсутствует |
| `execution_ref`, `builds`, `coverage_status`, `elapsed_us`, `target_outcome` | Есть в результате `run/4`, но аварийная ветвь может не иметь `target_outcome` |
| `input_id` | SHA-256 входа в metadata worker/corpus, не поле обычного executor result |
| `cleanup_status`, generation, layout digest, `feedback_epoch` | Нет; не следует приписывать их существующему контракту |
| `RunRef` | Есть внутренний `Request` и отдельный context `Ref`; переносимый input ID из них не получается |

**К/Э.** Defaults подтверждены `efz_config:defaults/0`, строки 4–6, и runtime:
`coverage => automatic`, `coverage_validation => prepared`,
`coverage_backend => ets`, `workers => 1`, `mutation_mode => random`, timeout 100 ms.
`ets_member` разрешён явно; `per_execution` — альтернативная валидация. Это две
независимые оси, не четыре разных пространства features. Низкоуровневый `run/4`
сам не создаёт prepared plan: caller передаёт `coverage_plan` либо `manifests`.
`run/3` использует manual compatibility и возвращает только outcome.

**К/Э.** `seed_calibration` — **одно исполнение каждого начального seed**:
`efz_worker:init/1`, строки 20–24, `handle_info/2`, 26–30;
`efz_feedback:evaluate/3`, 9–17. Проверка с двумя seeds и нулём мутаций дала
`calibrations=2, executions=0, discoveries=0`, две причины `seed_calibration`.
Повторов R, intersection/frequencies и показателя устойчивости сейчас нет.
Слово «calibrates» в README означает эту начальную обработку, а не повторную
оценку стабильности.

## 2. Фактический путь testcase и владельцы состояния

Ссылки на основной код: [executor](../src/efz_executor.erl),
[coverage context](../src/efz_cov.erl), [hook](../src/efz_cov_rt.erl),
[worker](../src/efz_worker.erl), [feedback](../src/efz_feedback.erl).

```text
До измерения:
  config + artifacts preflight; загрузка selected BEAM; plan создаётся один раз
  seed берётся как есть ИЛИ corpus selection -> mutation -> binary/recipe

Для одного run/4:
  caller создаёт Request, spawn_monitor(coordinator)
    coordinator monitor(caller)
    open: новый context Ref + новая public ETS       [до Started]
    Started = monotonic_time(microsecond)
    spawn_monitor(target)
      attach(Context) -> M:run(Input)
      selected module bodies -> синхронные ETS membership publications
      outcome / caught error, throw, exit
      target_result{Ref, target PID, Outcome}
    wait: результат + target DOWN, либо DOWN/timeout/caller DOWN
    timeout/cancel -> kill(target) + подтверждённый DOWN
    обычная ветвь: sticky failure -> snapshot -> identity validation -> result
    отправка result caller                         [ещё до finally cleanup]
    after: повторный kill_and_drain -> close ETS -> demonitor caller
    coordinator завершается
  caller ждёт coordinator DOWN перед возвратом run/4

После run/4:
  worker увеличивает calibration ИЛИ mutation execution counter
  feedback(status, outcome, builds, Observed) -> novelty/merge decision
  corpus add для нового успешного input; crash storage отдельно
  decisions/statistics; следующая итерация
```

**К.** Время `elapsed_us` начинается после `efz_cov:open/1` и включает startup target,
attach, `M:run/1`, ожидание завершения, чтение и валидацию snapshot; заканчивается
до `builds(Options)`/отправки result и finally cleanup
(`efz_executor:coordinate/6:28–59`). Это не чистое target time и не полный wall time
`run/4`. Полный синхронный вызов включает context allocation и cleanup. Deadline
в `wait_target/5:62–79` отсчитывается отдельно в миллисекундах после spawn target;
это не гарантированная верхняя граница wall time при зависшем native вызове.

**К.** Общего decoder, `before_input`, reset target state, `after_input` и target
cleanup callback нет. Seeds — binary, мутации возвращают binary; staged recipe
составляется до executor (`efz_worker:staged_iteration/1:42–52`). Проверки размеров
и словаря находятся вне coverage. Низкоуровневый `run/4` допускает произвольный
Erlang term как `Input`, передавая его прямо в `M:run/1`; диагностические tuple
inputs с PID используют именно этот низкоуровневый seam, не новый campaign API.
В replay чтение файла/регенерация/preflight выполняются до исполнения
(`efz_recipe:execute/5`, `execute_file/5`, строки 85–114).

**К.** Область features — тела выбранных модулей, вызываемые процессом после attach.
Поэтому decoder/setup внутри выбранного `M:run/1` тоже будет измеряться, если он
там есть. Target `try ... after` измеряется до нормального/exception завершения;
принудительный kill не обещает выполнения target cleanup. EFZ hook, executor,
сборщик статистики и transform исключены из allowlist самим transform
(`efz_instrument_pt:parse_transform/2:26–33`). Compilation/load до attach и cleanup
coordinator после target DOWN не добавляют EFZ probes. Иначе выбранный пользователем
adapter может добавлять свои общие probes — это нужно фиксировать в allowlist,
а не вычитать такие features после получения процента.

| Состояние/ресурс | Владелец и lifetime | Гарантия / граница |
|---|---|---|
| Corpus и selector RNG | `efz_corpus` gen_server; campaign lifetime | insertion order; random selector либо staged planner; `src/efz_corpus.erl:5–14` |
| Mutation RNG/cursors, global novelty, decisions | `efz_worker` | Не должны изменяться от stability repeats; `worker:7–24,42–56,108–125` |
| Prepared plan | Worker; offline caller `prepare/2` | protected unnamed ETS; до release/смерти владельца; не observation buffer |
| Request и monitor coordinator | Caller `run/4:7–24` | Response привязан к Request/PID; caller ждёт завершения coordinator |
| Context Ref и public ETS set | Coordinator `coordinate/6:26–29`; `cov:open/0:11–13` | ETS живёт после смерти target, уничтожается с owner; heir нет |
| Context reference в PD | Только target после attach | Не единственное хранилище hits; не наследуется детьми |
| Caller/target monitors, deadlines | Coordinator, `wait_target/5`, `kill_and_drain/2` | `receive after`, не timer process/port; отдельный fresh monitor в cleanup |
| Snapshot list | Coordinator, затем копия result у caller | Неизменяемый Erlang list; живёт после удаления ETS; данные до novelty |
| Порты в production executor | Отсутствуют | Fresh-VM ports в тестах/аудите принадлежат внешнему диагностическому escript |
| Children, OTP servers, target timers, внешние ресурсы | Не управляются executor | Нет списка target tree, child ACK barrier или общего reset |

### Что действительно доказывает quiescence

**К/Э.** Синхронный завершённый `ets:insert` публикует присутствие до возврата hook.
`target_result` сам по себе недостаточен: executor дополнительно ждёт monitor DOWN.
Timeout/cancel вызывают `exit(Target,kill)` и ждут DOWN fresh monitor без sleep
(`kill_and_drain/2:82–87`). После этого target PID больше не пишет; из нового
исполнения создаются новые PID/Ref/Tid. Список snapshot читается до удаления ETS.
Caller не получает успешный возврат `run/4` до завершения coordinator.

Это доказательство **одного PID**, не дерева. Для дочерних процессов нет ни ACK
протокола, ни transitively joined scope. Spawned children не наследуют PD; обычные
их hooks неактивны. Child с вручную переданным context способен писать в старую
таблицу, пока она жива, в том числе после завершения родителя. Между snapshot и
close для такого unsupported writer барьера нет. После close stale hook получает
ошибку таблицы, а не новый context. Диагностика явно дождалась child после root,
запустила следующий context и подтвердила отсутствие загрязнения следующего.
Это не подтверждает полноту покрытия child tree.

**К/Э.** Generation validation при hit **нет**. Ref сопоставляет result/failure
messages, но не хранится в ETS строке и не проверяется against table при hit.
`attach/1:24–29` проверяет owner таблицы и тип reference/PID, не привязку Ref к Tid.
Подмена только Ref при том же owner/Tid принята в диагностике. Изоляция штатного
пути обеспечена свежими непереиспользуемыми Tid и процессом, а не проверкой
поколения. `snapshot/1:31–34` сам не проверяет, что writers остановлены: прямое
чтение live context вернуло `{a}`, после разрешённой записи того же writer — `{a,b}`.
Для калибровки нужно брать результат `run/4`, а не произвольно читать ETS.

### Ветви завершения: текущий результат и допустимость для метрики

| Ветка | Фактические данные и cleanup | Решение для будущей серии |
|---|---|---|
| Нормальный return | `outcome={ok,V}`, `target_outcome` такой же, полный root snapshot при status ok; DOWN перед чтением и close перед возвратом | Измеряемый повтор при соблюдённом root/reset/build контракте |
| Target возвращает `{error,invalid_input}` | Это `{ok,{error,invalid_input}}`, не отдельная executor invalid category; текущий feedback считает return успешным | Не исключать по названию Value; outcome записать отдельно; пустой U даёт N/A |
| Некорректная конфигурация/oversized staged seed | Reject до target; snapshot не создаётся (`efz_config:prepare/1,prepare_mutation/1`) | Ошибка запроса, не пустой измеряемый повтор |
| `error`/`throw` из target | `{crash,Class,Reason,Stack}`; hook hits сохранены, target DOWN и cleanup штатные | Валидный snapshot терминального exception; crash не исключать из stability по outcome |
| `exit(Reason)` из target | `{exit,Reason}`, status ok возможен | Семантически завершённый exception допустим, но текущий result не отличает его от внешнего termination; нужен origin |
| Внешний kill target | `{exit,killed}`, сохранён опубликованный префикс; root DOWN доказан | Полный префикс завершённого PID, **не полный testcase**; обычно incomplete, не пустой F |
| Timeout | `{timeout,T}`, status ok возможен, hooks до фактического kill/DOWN сохранены | Срез по deadline не считать полным x; diagnostic prefix отдельно, основная серия incomplete |
| Race completion/timeout | Result + DOWN успели — Outcome; иначе timeout wins; late messages остаются у retiring coordinator | Проверять terminal source, не угадывать по duration или наличию hits |
| Caller death / campaign cancel | Coordinator убивает/drains target, closes table, не возвращает snapshot (`cancelled -> ok`, executor:44) | Missing/cancelled slot; incomplete. DOWN caller/worker не заменяет DOWN coordinator |
| `efz:await(Timeout)` истёк | Это timeout `gen_server:call`; campaign продолжает работать | Не считать отменой target; отдельный cancel/stop нужен явно |
| Worker kill | Fuzzer возвращает `status={infrastructure_failure,{worker_down,killed}}`; snapshot в report отсутствует; coordinator асинхронно cleans target | Incomplete; не выводить успех из нулевого counter infrastructure_failures |
| Coordinator killed | `run/4`: infrastructure `coordinator_down`, `coverage=[]`, status error, builds пустой; таблица исчезает; target может выжить | Missing, dirty/unknown VM state; прекратить серию, не переиспользовать VM без доказанного cleanup |
| Backend/plan/validation failure | Infrastructure, status error, иногда доступны диагностические hits; при обычном исключении coordinator выполняет finally | Не пустой F и не target bug; серия incomplete/incomparable по причине |
| Ненормальный DOWN coordinator после result | `cleanup_failed` заменяет outcome/status (`run/4:15–18`) | Данные только диагностические до подтверждения cleanup; не допускать автоматически |
| Node/VM crash | В той же VM контроллер тоже потерян; результата нет | Потерянная серия incomplete, external exit status отдельно; U не строить из отсутствия файла |

Для `halt(23)` во **внешней диагностической VM** подтверждён exit status 23 и
отсутствие result/snapshot файла. Это контроль потери VM, не тест NIF segfault.
Распределённого runner и отдельной ветки `nodedown` в EFZ нет.

`kill_and_drain` намеренно ждёт реального DOWN, а не объявляет cleanup после
произвольной задержки. Но его ожидание не ограничено вторым таймером: NIF, который
не возвращает управление, может потребовать уничтожения VM извне. Такой NIF не
проверялся. Dirty shared/application state не становится чистым от смерти одного
target PID. При недоказанном reset/cleanup будущий сборщик должен прекратить серию
с `requires_fresh_vm`, а не продолжить и признать counters достоверными.

## 3. Точное пространство features и сопоставимость

**К/Э.** Единица automatic feedback:
`{Module, BuildId_SHA256, ProbeId_integer}` — **присутствие source-level
clause/outcome probe**. Строка в обоих backend — `{{probe,Id}}` в ETS `set`:

* `ets`: вставляет ту же строку на каждом hit (`efz_cov_rt:hit/1:20–26`).
* `ets_member`: сначала проверяет membership, при отсутствии вставляет такую же
  строку (`hit/1:8–19`). Повторная запись не увеличивает никакое значение.
* `manual`: отдельное пространство `{manual,Id}` через `efz_cov:hit/1:38–39`, с теми
  же двумя вариантами ETS storage. Это compatibility API; стабильность произвольных
  пользовательских Id должен обеспечивать caller. Automatic/manual не смешиваются.

Нет counters, buckets, CFG edges, value features, transition sequence или hashed
bitmap. Нет переполнения счётчика, поскольку счётчика нет. Exact ETS key сравнивает
полный term, а не маленький hash. SHA-256 build namespace не является математической
гарантией отсутствия всех возможных hash collisions, но здесь нет намеренных
коллизий bitmap/index. Повторные публикации не теряются из-за local cache: кеша нет.
Кратность 1 и 100 одного site экспериментально дала одинаковое одноэлементное F
в обоих backend. Поэтому `feature_stability` здесь совпадает с site-presence
stability; вводить вторую дублирующую метрику или buckets незачем.

`efz_cov:snapshot/1` возвращает **весь отсортированный список присутствующих Id**,
а не count/hash/delta. `efz_feedback:evaluate/3:10–17` только после этого вычисляет
`Observed - Global`. `Result.coverage`, `Report.coverage` и `Decision.new_probes`
различны: последнее — delta для retention, report — union успешных исполнений.
Полные snapshots успешных/отклонённых исполнений в обычном campaign report не
сохраняются; crash result сохраняет своё полное coverage. По старому report нельзя
восстановить отсутствующие F_r. Нужно переисполнение через `run/4` либо будущий
observer до feedback; восстановления из SHA/count/new_probes не предлагать.

**К/Э.** Смена входа создаёт новую пустую table, а не очищает общий bitmap. Изоляция
повторных/параллельных context проверена на одинаковых probe IDs. Return/exception
сохраняют все завершённые root publications при контракте неизменяемого context.
Для kill/timeout это все опубликованные hits до прекращения данного процесса,
не все ветви, которые он мог бы выполнить без прерывания. Вставка, прерванная kill,
не даёт оснований объявлять незавершённый hit наблюдённым. Snapshot не повреждён,
но полнота задачи — отдельный вопрос.

**К.** Идентичность задаётся `efz_instrument_pt:parse_transform/2:35–53` и
`probe/4:114–121`: SHA-256 `{instrumentation_version, OTP release, compiler MD5,
canonical preprocessed forms, relevant compiler options}`, затем детерминированный
ordered AST index. Manifest schema/instrumentation version = 1,
metric = `clause_outcome_probe`. Probe mapping содержит M/F/arity/kind/path/file/
line/column. Root-relative source path нормализуется; absolute path-sensitive
литералы могут менять build. Нет separate native layout или feedback_epoch.
Произвольный hash всего ETF map нельзя использовать как portable digest без
канонизации: map serialization order не является таким контрактом.

`efz_instrument:preflight/1`, `load/1`, `loaded_manifest/2`, строки 94–142,
проверяют BEAM, decoded sidecar, manifest и атрибут загруженного модуля. Sidecar
сравнивается по точному term, не байтам (`matching_sidecar/2:111–113`).
Существующий reversed-map-order/fresh-VM тест прошёл вновь. В трёх новых VM один
artifact дал **те же полные Id**, ту же build map и S=100%; соответствие проверялось
по спискам Id, не только count/digest.

Hot replacement после preflight не контролируется непрерывно. В диагностике старый
valid plan после контролируемой загрузки **ordinary** версии того же модуля дал
`coverage_status=ok, coverage=[]` и старую build map. Повторный явный preflight
отклонил `loaded_module_identity_mismatch`. Смена на новый instrumented build,
публикующий новые Id, ловится валидатором; замена на код без probes этим способом
не ловится. Lifetime требует неизменяемых selected builds и harness. При изменении
build или manifest нужен новый plan и новая серия; arbitrary hot reload не
объявляется поддержанным.

**К/Э.** Prepared plan — `{efz_cov_plan,1,Tid,BuildMap}`. `prepare/2:51–68` валидирует
manifest schema, instrumentation version, uniqueness, непустой automatic selection
и отсутствие duplicate modules, создаёт protected ETS marker `{'$efz_plan',{Mode,Bs}}`
и exact allowed identities. Он **не заменяет preflight** и не содержит input,
execution Ref, RNG или accumulated coverage. Worker владеет им до stop, даже после
`await` completed. Для low-level API допустим foreign caller с живым owner; запись
в чужой protected plan запрещена. Release выполняет владелец после всех читателей;
owner death удаляет таблицу автоматически.

На каждом execution validate проверяет marker/mode/builds и каждый observed Id,
включая проверку marker при пустом F (`validate_prepared/3:72–85`). Disposed/wrong
mode/подменённая build map не становятся успешным пустым снимком. Иная версия tuple
может дополнительно упасть в `builds/1:70` и дать coordinator_down infrastructure.
Существующие negative/lifetime tests это проверяют, включая смерть plan owner при
активном исполнении. План backend-independent; storage backend и validation
strategy всё же записываются в конфигурацию опыта из-за разной нагрузки на timing.

## 4. Применимость feature_stability и правила допуска

**П.** Это собственная метрика EFZ, не штатная формула libFuzzer и не численный
эквивалент AFL++ stability. Нормализация v1 — dedup + canonical ordering **полных**
probe identities; без маскирования sites, counters или исключения crash-only Id.
Для одного и того же x с фиксированным контрактом состояния и R >= 2:

```text
frequency_x(f) = число измеряемых повторов, где f присутствовал хотя бы раз
U_x = union всех F_r(x)
I_x = { f из U_x | frequency_x(f) == R }
V_x = U_x \ I_x
S(x) = feature_stability = 100 * |I_x| / |U_x|
S_C = 100 * sum_x |I_x| / sum_x |U_x|
```

Повторные hits внутри одного F не повышают frequency. Reference run не нужен.
Долю полностью совпавших прогонов при желании называть отдельной метрикой с явно
выбранным эталоном; не подменять ею S. Для точного сравнения порогов сохранять
числитель/знаменатель и сравнивать целые произведения, округлять только отображение.

**Э.** Диагностическая цель со всего четырьмя probes дала при одном input:

```text
F1={a,b,c}; F2={a,b,d}; F3={a,b,c}
frequency={a:3,b:3,c:2,d:1}; I={a,b}; U={a,b,c,d}; V={c,d}; S=50%
```

Все размеры равны трём. Второй вход с обратным чередованием также имеет S=50%;
правильный corpus aggregate — 50%. Если сначала объединять оба входа каждого
раунда, три раза получится `{a,b,c,d}` и ошибочные 100%. Это проверено assert,
не оценено по визуальному сходству логов.

**П.** Машина состояний результата одного input:

| Условие | Статус / значение |
|---|---|
| Requested R < 2 | N/A `insufficient_repeats`; не 100 |
| Все R достоверны и сравнимы, U непусто | `complete`, S и полные frequencies |
| Все R достоверны, U пусто | N/A `empty_feature_union`; отдельно различать empty bytes и empty snapshot |
| Snapshot missing, infra error, неподтверждённая quiescence/reset/cleanup, cancellation, потеря owner/VM, оборванный testcase | `incomplete`, основной S отсутствует |
| Смена build/manifest/schema/scope или несопоставимые Id | `incomparable`, основной S отсутствует; не переводить в другой namespace автоматически |
| Есть только k<R достоверных повторов | `incomplete`; можно отдельно показать diagnostic S для фактического k>=2, без automatic admission |
| Полные terminal error/throw/caught exit либо нормальный invalid return | Могут участвовать в stability; outcome учитывается отдельно, не исключается только из-за класса |

Для сопоставимости предполагается отсутствие вмешательства в instrumentation-owned
state. Status ok сам по себе не доказывает это против враждебного target. При
выявленном вмешательстве или смене кода series invalid/incomplete независимо от
того, остался ли непустой subset одинаковых hits.

Для фиксированного C заморозить content identity, порядок/перестановки и протокол
повторов заранее. Aggregate взвешивает **пары input–feature**, а не уникальные
features всего корпуса. Вместе с S_C обязательны rows каждого x, min S(x), число
unstable inputs (`|V_x|>0`), `selected_entries`, `unique_inputs`, `measured`,
`scored`, `empty`, `incomplete`, `incomparable` и их input IDs. Дубликаты byte-identical
entries явно сопоставить одному x для этой контрольной метрики; исходные seed entries,
их порядок/статус и обычные calibration counters не удалять и не менять.

При неполном корпусе основной aggregate имеет статус incomplete/incomparable,
а не «всё устойчиво». Допустим отдельный `complete_subset` aggregate с точным
перечнем включённых x и denominators. Пустые полные x дают нулевой вклад в суммы,
но остаются N/A rows, явно отмечаются и не превращаются в «проверенные 100%».
Если суммарный знаменатель равен нулю, S_C=N/A. Нельзя молча исключать failures
или недостающие повторы, заменять их пустым set, либо retry до набора удобных R.
Новый согласованный запуск после сбоя — новая серия с новым диагностическим job ID.

Основной outcome comparison предложен отдельно: exact return value либо exception
class/reason; target stack хранить как evidence, не как feature. Volatile PID/ref/
port/fun значения нельзя объявить portable совпадением между VM. Записывать outcome
changes/несопоставимость outcome отдельно; исходный result не уничтожать. Полное
равенство F не доказывает одинаковый порядок выполнения, одинаковый outcome или
отсутствие дефектов.

Если когда-либо feedback станет `{site,bucket}`, смена bucket может создавать
несколько нестабильных features одного site; это отличается от числа стабильных
ячеек AFL++. Сейчас такого backend нет. Вводить второй schema и отдельную
site-presence метрику только при реальном изменении feedback, не для этого аудита.

Предлагаемые настраиваемые внутренние ориентиры: цель **100%**, warning при
`S < 95%`, усиленный разбор при `S < 90%`; все вариативные x видны и выше 95%.
Это начальные project thresholds, не отраслевой стандарт и не доказательство
корректности. Incomplete не проходит пороговую проверку. Более высокий R повышает
шанс обнаружить вариативность; сравнение процентов требует фиксированных R, C,
feature schema, builds/manifest и execution/reset/warmup режима.

## 5. Изоляция BEAM и протоколы повторяемости

| Режим | Что подтверждено / что должен фиксировать будущий запуск |
|---|---|
| Повторы x штатным `run/4` | Fresh target PD/mailbox, новый context; main schedulers 16; first call включён. Для deterministic fixture одинаковые полные F и S=100 |
| A→B→A, фиксированные permutations | У независимых `only_a`/`only_b` наборы disjoint, оба A совпали, permutations дали тот же mapping input→F |
| Контролируемое нарушение независимости | `state_b` меняет `persistent_term`; A до/после дал c/d, S=0. Явный reset fixture восстановил A. Это свидетельство общей VM state, не дефект ETS isolation |
| Свежая VM для каждого x | Три автономных VM, одинаковый artifact/manifest и Id, S=100; штатные 16 schedulers. Контрольный режим, не обещание изоляции ОС |
| Предусмотренный warmup | В этом аудите W=0. Первый вызов не отбрасывался. Будущий W/последовательность warmup — явная часть протокола/ключа, failures warmup тоже учитываются |

В первом ETS опыте `elapsed_us=[919,10,7]`, при начале последующего ets_member
опыта `[15,12,11]`; F совпадают. Вторая группа уже работала в прогретой VM, поэтому
это **не backend performance comparison**. Числа показывают, почему нельзя незаметно
исключать первый вызов или смешивать cold/steady режимы. Полный warmup/stability
на реальной библиотеке не измерялся.

**Э.** Target-local `put`, mailbox message и implicit rand state не перенеслись в
следующий свежий target. Но общие ETS/registered servers/persistent_term/application
state не сбрасываются executor. В тесте уже запущенный gen_server, синхронный OTP
callback и timer-delivered message вызвали instrumented site без прикреплённого
context: child/background hooks были inactive. `spawn`, `spawn_link`, `spawn_monitor`
после нормального root return оставляли child живым; ни link, ни monitor от родителя
не обеспечивают завершения всего дерева. Child release/ACK выполнены явно, не после
sleep. Таймеры/сообщения не переносят process dictionary; адресат определяет процесс
исполнения. Контекст существующим OTP-серверам не выдаётся автоматически.

Если цель stateful по замыслу, x должен включать initial state, configuration и
последовательность действий. `state_a` после различных намеренных состояний нельзя
выдавать за один scenario x. Текущий EFZ принимает binary+`run/1`, scenario/reset API
нет. Минимальная первая интеграция должна явно ограничиться существующим
`fresh_target_process / unreset_shared_vm / root_probe_scope` и согласованной
независимостью harness. Не подменять это универсальным reset OTP-приложения.

Непройденные границы: произвольные ETS других владельцев, registry/global state,
общие приложения, файлы/порты, неуправляемые timers/фоновые actors, distributed node
state, shared native resources. Свежая VM изолирует process state этой VM, но не
гарантирует reset внешних ресурсов ОС. Ни context Ref, ни public ETS, ни prepared
plan не являются security boundary. Target внутри той же VM может менять runtime,
убить coordinator или повредить instrumentation state. Часть вмешательств уже
классифицируется как infrastructure; полной защиты/dirty-worker detector нет.

## 6. Запуски и доказательная матрица

Все команды выполнялись из `efz/`. Входные build flags — текущий rebar.config;
диагностические модули компилировались `debug_info,warnings_as_errors`, без новых
зависимостей, только `audit_sites` был allowlisted. Его четыре probes:
`a/0:3`, `b/0:4`, `c/0:5`, `d/0:6` (column 1), build
`68bd7a9201c0be5e43ed13f5850558fcefe6e07493252a66204f7fe36fc7e809`.
Adapter/background fixture намеренно uninstrumented, чтобы общие ветви управления
не загрязняли заданные множества a/b/c/d. Нормальные production examples также
проверены, а не заменены этим специальным пространством probes.

| Команда | Новый результат | Лог |
|---|---|---|
| `rebar3 compile` | exit 0 | [compile.log](/tmp/efz-calibration-audit.rIBEql/compile.log) |
| `rebar3 eunit` | exit 0, **62 passed** | [eunit.log](/tmp/efz-calibration-audit.rIBEql/eunit.log) |
| `rebar3 ct` | exit 0, **3 passed** | [ct.log](/tmp/efz-calibration-audit.rIBEql/ct.log) |
| `escript /tmp/efz-calibration-audit.rIBEql/audit.escript /tmp/efz-calibration-audit.rIBEql` | exit 0, **54 evidence records**, все asserts passed | [diagnostic.log](/tmp/efz-calibration-audit.rIBEql/diagnostic.log) |
| `escript /tmp/efz-calibration-audit.rIBEql/existing_example.escript /tmp/efz-calibration-audit.rIBEql` | exit 0; `efz_example_target` на `<<0>>` и `<<255>>`, R=3 каждый, точные F совпали, S=100; exception не исключён | [existing-example.log](/tmp/efz-calibration-audit.rIBEql/existing-example.log) |

Полные diagnostic results до novelty, включая exact IDs и metadata, —
[events.term](/tmp/efz-calibration-audit.rIBEql/events.term) и
[events.txt](/tmp/efz-calibration-audit.rIBEql/events.txt). Assertions сравнивают
канонические наборы, не только их размеры. Логи/скрипты — временные; таблица здесь
и встроенные исходники — постоянная воспроизводимая запись. В первом пробном
скрипте было предупреждение OTP о float pattern `0.0`; заменено на `+0.0` только
во временном скрипте, итоговый опыт повторён успешно. Прежние временные результаты
сохранены с суффиксом `first`, в выводах используется финальный запуск.

SHA-256 финальных доказательств: `eunit.log` —
`1aaf27c24e7f320e7b331d2f9e7f06dea647981627050cd53aba37c513fe8a3e`,
`diagnostic.log` —
`b4bc09d285bd1681b13ffbd7f4a61233ccef6ace37af8dfabf7dc32ddac3ba66`,
`events.term` —
`fc7773394e458dedd9f742b80c5b0d9f7c44913add1e48d79146d9e8a2ea37c9`.
Встроенные в отчёт исходники затем извлечены **самими командами приложения** в
`/tmp/efz-calibration-reproduce.5h0yayqu`; оба диагностических escript снова
завершились exit 0. Это проверка воспроизводимости команд, не новая выборка для
смешивания процентов/времён. См. [контроль воспроизведения](/tmp/efz-calibration-audit.rIBEql/report-reproduction.txt).

| Требование / опыт | Текущая реализация и доказательство | Пробел / минимальное изменение |
|---|---|---|
| Deterministic x, R=3 | Оба backend: abc три раза, S=100; `{B,deterministic}` | Для public metric нужен отдельный collector |
| Equal-size different sets / known alternation | abc/abd/abc, frequencies 3/3/2/1, S=50; `{B,alternation}` | Считать по identity, не по count/hash |
| Corpus aggregation | Два противоположных x: correct 50, collapsed 100 | Хранить отдельную частоту `(x,feature)` |
| Разная кратность | 1 и 100 hits site a → один probe; `{B,multiplicity}` | Не вводить counters/buckets |
| A→B→A/permutations | Disjoint a/b, оба A совпадают; `{B,aba}` | Зафиксировать order/reset contract |
| Shared state | persistent_term изменяет A; reset fixture восстанавливает | Нет универсального target reset; не считать процесс свежей VM |
| Delayed child | Все три spawn-варианта inactive, следующий root set чист; explicit-copy child после close получил invalid table | Tree quiescence/coverage не поддержаны; root-only scope явно |
| Existing OTP server/timer | Hook в background inactive, root snapshot только a | Для OTP application scope нужен отдельный будущий runner, не эта интеграция |
| Concurrent contexts, одинаковые Id | Разные Ref/Tid, оба exact `{a}`, после возврата таблиц нет | Нельзя выводить production multiworker поддержку из этого теста |
| Error/throw/exit | Все сохранили a, status ok; `{B,exceptions}` | Terminal exception допустим, нужен origin для exit |
| External kill / timeout | ACK после a, затем kill либо deadline, a сохранён, target/owner DOWN | Это prefix; completeness полного testcase отсутствует |
| Completion/deadline race | Существующий `efz_backend_tests:boundary/1:188–198` и Phase 2 tests прошли | Метаданные terminal source вместо угадывания |
| Caller/cancel/shutdown | Существующие `caller_death/1`, `cancel/1:179–210` прошли для четырёх комбинаций; новый campaign cancel подтвердил await != cancel | Cancellation snapshot отсутствует, cleanup async относительно смерти caller |
| Empty input/snapshot | `<<>>` return invalid и отдельный empty route различимы; обе пустые серии N/A | Не путать error/missing с valid empty |
| Worker crash | status infrastructure, report без snapshot, stats infra=0; `worker_kill` | Observer должен читать status; telemetry нуждается в уточнении |
| Coordinator crash | Сохранённый до kill a утрачен вместе с таблицей; root оставался жив, harness явно его убил | Incomplete + dirty; cleanup guard либо запрет reuse/утилизация VM |
| Prepared ownership/dispose/foreign | `efz_backend_tests:plan_lifetime/1:128–166` прошёл; disposed + empty у обоих backend infra | Сохранять owner до окончания читателей; no release while executing |
| Missing/mismatched manifest/sidecar | EUnit preflight negatives и `efz_phase2_tests:sidecar_encoding/0:229–253` прошли | Offline API обязан делать preflight, raw run/4 его не делает |
| Same build, fresh VM | Три новых VM приняли один sidecar и дали exact abc + одинаковые builds | При смене namespace — incomparable, не merge |
| VM loss | External helper exit 23, snapshot файла нет | Existing native runner отсутствует; external job должен отметить missing |
| Live snapshot / Ref | До quiescence a, после ab; изменённый Ref при том же Tid принят | Не брать snapshot напрямую; Ref — correlation, не generation/security guard |
| Broken active state | Invalid table пойман и остаётся sticky infrastructure; malformed PD context, пойманный target, дал ok+empty | См. finding F4; no blanket trust по status ok |
| Hot ordinary replacement | Old plan accepted empty; explicit preflight rejected loaded identity | Freeze builds и контроль на поддержанных границах series |

Существующий EUnit включает transform semantics, same-line/nested syntax, exception
class/reason, tail position, instrumentation identities, backend/validator canonical
outcomes/novelty, cancel/shutdown и повторное освобождение execution resources.
Expected malformed-plan errors в логах — negative tests, не провалы сборки.
`efz_backend_tests:variants/0:21` действительно проверяет обе storage реализации
с обоими validators. Находящиеся в старых отчётах 38/3 не использованы как новые
результаты: текущий запуск — 62/3.

**НП.** Dialyzer/xref в этом аудите повторно не запускались: нет production изменений,
применимых инструкций с обязательным gate и вопроса, требующего нового static
analysis вместо рассмотренных runtime tests. Их старые PASS не выдаются за этот
запуск. Не запускались Phase 2.1 profiling/soak, Cowboy (нет dependency/harness),
произвольные внешние targets, native/NIF coverage reset/quiescence, NIF segfault,
distributed nodedown, exhaustive OTP resource isolation. Эти границы не закрываются
настоящими тестами a/b/c/d.

## 7. Приоритизированные findings

### F1 — P1: outcome/status не задают полноту и источник termination

**К/Э.** `efz_executor:coordinate/6:35–38`, `wait_target/5:64–79`, `coverage/3:89–104`.
Caught `exit(killed)` и external kill дали **одинаковые** outcome, target_outcome,
coverage_status, coverage, builds; различаются только incidental Ref/time. Timeout
также может иметь status ok и непустой F. Если считать это достаточным для полного
повтора, прерванные исполнения могут создать ложную устойчивость.

**П. Минимум:** additive terminal origin/scope/quiescence/snapshot/cleanup metadata;
не переименовывать старые outcome tuples. Выдавать признаки на основе выбранной
ветки executor, а не эвристики по Reason. Валидатор серии допускает terminal caught
exceptions, но не неполный deadline/monitor-exit testcase. **Приёмка:** один и тот
же public `{exit,killed}` distinguishable по origin; prefix и missing никогда
не превращаются в full/empty для метрики.

### F2 — P1: untrappable смерть coordinator оставляет unsupported живой target

**К/Э.** Target создан `spawn_monitor`, не под переживающим owner cleanup guard
(`coordinate/6:31–41`). Kill coordinator не выполняет `after:55–60`; `run/4:20–23`
возвращает infrastructure, но target в тесте ещё жил. Диагностический harness
мониторил и убил именно этот target, затем дождался DOWN; чужие процессы не трогались.

**П. Минимум для метрики:** abort series, missing snapshot, `requires_fresh_vm` при
неподтверждённом cleanup; не продолжать следующие x в dirty VM. Для разрешения reuse
после такой аварии нужен отдельный owner-surviving guardian/tracked target cleanup
и ACK реального DOWN. Простого link недостаточно для target с `trap_exit`; sleep
не является исправлением. Не менять outcome и не добавлять счётчики ради скорости.
**Приёмка:** forced owner kill никогда не даёт score; продолжение разрешено только
после доказанной остановки tracked writers либо в новой внешней VM.

### F3 — P1: plan не доказывает неизменность исполняемого кода

**К/Э.** `efz_cov_manifest:validate_prepared/3:72–85` сравнивает observed IDs с marker,
не loaded code. `efz_instrument:loaded_manifest/2:124–127` проверяет actual loaded
attribute только при preflight. Ordinary hot replacement дал valid empty snapshot
со старой build map. Полный result.builds берётся из options/plan, не из трассы.

**П. Минимум:** fixed selected modules **и target adapter** на lifetime series;
preflight на входе, capture/проверка выбранных loaded identities на оговорённых
границах серии, invalidation по build/manifest/harness. Код, меняющийся во время
исполнения и возвращающийся к прежнему виду, этим не защищён; не обещать arbitrary
hot loading. **Приёмка:** incompatible boundary rejected; new build — new series,
не subset merge; unchanged fixed build спокойно переиспользует plan.

### F4 — P1 для нарушенного runtime-контракта: caught malformed context теряется

**К/Э.** `efz_cov_rt:hit/1:16–27`: bad table посылает sticky notification, а последний
invalid-context clause только raises. Fixture заменила PD context и поймала это
исключение; executor вернул `{ok,caught}`, status ok, empty coverage. RunRef не
защищает instrumentation state от target.

**П. Минимум:** явный запрет модификации instrumentation-owned state в поддержанном
harness; fail-closed проверка исходного context из wrapper перед завершением и
диагностика нарушения. Проверка только «на выходе» не защищает от умышленной
подмены/восстановления. Для враждебной цели нужна другая security/isolation boundary,
не обещание калибровки. **Приёмка:** сохраняющийся bad/erased context после пойманной
ошибки — infrastructure/incomplete; runtime available без attach в обычном
неизмеряемом child остаётся допустимым inactive no-op.

### F5 — P1 для интеграции: данные campaign report нельзя принять за F_r

**К.** `efz_worker:execute/4:60–82`, `finish/2:115–118`, `efz_feedback:evaluate/3:10–20`.
Success snapshots уходят в global merge и не сохраняются как per-run report.
`new_probes=[]` у crash — retention policy, не отсутствие execution features.

**П. Минимум:** collector сохраняет полный result до novelty, либо самостоятельно
повторяет выбранные bytes через тот же run/4. Не вызывать `feedback:evaluate/3`
на каждом повторе. **Приёмка:** одинаковая серия повторов не создаёт несколько NEW,
не меняет corpus/RNG/cursors и не сливает crash-only features в global.

### F6 — P2: потеря worker и source failure хуже отражены в телеметрии

**К/Э.** `efz_fuzzer:handle_info/2:34–39` возвращает worker_down infrastructure, но не
увеличивает infrastructure_failures; observed counter был 0. **К:**
`efz_feedback:evaluate/3:6–7,22` сначала требует равенства builds; coordinator_down
с builds=#{} может превратиться в `instrumentation_build_mismatch`, маскируя
исходную infrastructure reason, хотя target bug из него не делается.

**П. Минимум:** стабильность определять по структурированному result/status,
не aggregate counters. Сохранить первичную failure reason; при будущем изменении
stats учесть worker failure ровно один раз. **Приёмка:** lost run остаётся missing,
а actual reason доступна в calibration row; никто не объявляет 0 infra counter
доказательством полноты.

### F7 — P2 / scope: root isolation не есть независимость testcase

**К/Э.** Нет reset/child registry в executor; persistent_term и delayed child tests
подтвердили границу. Direct `snapshot/1` и подмена Ref не устанавливают quiescence.
**П:** record root-only/unreset-VM mode; diagnostic A→B→A и fixed permutations;
несогласованный stateful scenario — unsupported, не автоматическое обнуление
частоты. **Приёмка:** измеряется известный контракт, не удаляются unstable seeds и
не маскируются probes ради повышения процента.

## 8. Минимальный проект интеграции — только предложение

### Границы API и владельцы

**П, не существующий API:**

```erlang
%% Полный offline контрольный корпус, без mutator и feedback side effects.
efz_calibration:run(Target, Entries, Artifacts, Options)
    -> {ok, CalibrationReport} | {error, ConfigurationReason}.
%% Pure aggregation, отдельно от storage/execution.
efz_stability:fold(Accumulator, ValidatedRun).
efz_stability:finalize(Accumulator, RequestedR).
```

Предлагаемые options: `repeats` (R>=2, начальный bounded opt-in пример R=5), timeout,
backend/validation strategy, `mode=fresh_target_process`, `scope=target_process`,
`warmup=0`, protocol/order/reset-contract identity, limits на inputs/R/общий wall
budget, output trace/witness budget. Feature cap при превышении должен завершать
input incomplete, а не обрезать множество. Enabled-функциональность не должна
создавать infinity retry. В первой версии не принимать произвольный stateful
scenario под видом binary input; свежая VM — отдельный явно выбранный helper mode.

Инициатор получает фиксированный набор bytes/identities и explicit Target/Artifacts,
как нынешний replay. `efz_config`/`efz_instrument` валидируют selection; никаких
arbitrary callable targets из файла результатов. Decoder/recipe regeneration —
один раз до серии; каждое измерение получает **те же bytes**, а не повторную мутацию.
Низкоуровневый executor не заменяется.

Предлагаемая ownership схема:

* Job controller/caller владеет frozen corpus, compatibility key и агрегатором;
  получает bounded progress по каждому запланированному run index.
* Один calibration collector process владеет prepared plan и вызывает
  `efz_executor:run/4` последовательно. Никаких concurrent production fuzzing workers.
  Plan создаётся после preflight, живёт до окончания всех run/4 и освобождается
  owner в `after`. Per-execution contexts, ETS и monitors остаются у существующего
  coordinator. Parent JobRef/PID — только correlation, не durable cache key.
* Collector передаёт controller immutable full RunResult после возврата run/4,
  то есть после coordinator DOWN/cleanup. Controller increment frequency один раз
  на feature текущего slot, исходя из полного snapshot, не decision delta.
* Отмена offline job первоначально **кооперативная между run/4**: дождаться текущего
  вызова, не release его plan, затем не начинать следующий slot. Остальные slots —
  cancelled/not_run; итог incomplete. Это не promise мгновенного cancel при зависшем
  NIF. Collector мониторит инициатора и проверяет stop/death перед следующим run.
* При forced collector/owner death Job controller сохраняет полученные ранее slots,
  missing остальные, наблюдает имеющиеся cleanup guarantees и при недоказанной
  quiescence требует новую VM. Нельзя принять одиночный DOWN collector как ACK всех
  ресурсов. Если нужна немедленная отмена с продолжением в той же VM, prerequisite —
  explicit executor cleanup observer/guardian; это отдельное additive расширение
  существующего протокола, не второй executor.

**П:** дополнять существующий `run/4` metadata, сохранив его outcome/coverage поля и
старый `run/3` wrapper. Предлагаемая структура (названия ещё не реализованы):

```erlang
#{termination_origin => returned | caught_error | caught_throw | caught_exit |
                         monitor_exit | deadline | caller_cancel | coordinator_loss,
  coverage_scope => target_process,
  writers_stopped => confirmed | unknown,
  snapshot_status => full_scope | terminated_prefix | missing | invalid,
  cleanup_status => complete | failed | unknown}.
```

`full_scope` ограничен root и соблюдённым instrumentation contract, не «вся OTP
application». Поля устанавливает ветка executor, а calibration admission отдельно
проверяет builds, scope, reset contract, terminal origin и coverage_status. Передача
result до finally допустима только с нынешним ожиданием DOWN у caller; cleanup
metadata должно отражать результат этого барьера, не выставляться заранее.
Cancellation без возвращаемого result остаётся missing, пока не появится явный
наблюдатель. Epoch не подменяет quiescence.

### Схема результата и ключ инвалидирования

**П:** добавить отдельный versioned `calibration` report/index; прежние corpus,
mutation recipes, crash tuples, decisions и counters не переименовывать.
На каждый x хранить:

```erlang
#{schema_version => 1, compatibility_key => Key,
  input_id => SHA256, input_size => N, corpus_ids => [...],
  requested_repeats => R, attempted => A, trusted_repeats => K,
  status => complete | incomplete | incomparable | not_applicable,
  reason => Reason, union_size => UCount, intersection_size => ICount,
  variable_features => [...], frequencies => [{ExactFeature, PresenceFrequency}],
  feature_stability => NumberOrUndefined,
  outcomes => BoundedOutcomeSummaries, outcome_changes => Changes,
  runs => BoundedRunMetadata, witness_inputs => References,
  timing => #{startup_us => ..., repetitions_us => ..., aggregation_us => ...}}.
```

Дополнительно corpus summary, min S, unstable count, selected/measured/incomplete
с точными ID списками. Не сохранять все rejected recipes/snapshots бесконечно.
Frequencies достаточно для I/U/V; raw snapshots/witnesses — bounded option. Сами
input bytes должны оставаться проверяемыми по hash/length в corpus или packaged
копии; donor/RNG state для повторов готового binary не нужны.

**П.** `Key = SHA256(canonical versioned structure)` со следующими обязательными
частями, никакой сериализации неканонического map как «переносимого ключа»:

| Компонент | Фактическое основание / правило |
|---|---|
| Input/scenario | SHA-256 **bytes + length**, проверка packaged bytes; для будущего scenario — initial state/config/actions digest, не одно сообщение |
| Target/harness | Explicit `{Module,run,1}`, identity actual loaded adapter/обычного harness BEAM (сопоставленный code MD5/object digest), harness/reset contract version; один только selected BuildMap adapter не покрывает |
| Selected code | Sorted `{module-name-binary, BuildId, canonical manifest digest}`; schema/instrumentation version, limitations и toolchain |
| Feature semantics | `clause_outcome_probe / exact_presence / normalization_v1 / target_process`; version/code digest действующего EFZ runtime/executor/validator; manual отдельный namespace/explicit ID contract |
| Compatibility epoch | Новый предложенный portable digest перечисленных схем/semantics; **existing feedback_epoch нет**; изменение политики/schema требует новой серии |
| Execution settings | Timeout, backend implementation, validation strategy, OTP/ERTS/arch, scheduler settings, target config, protocol/reset mode; меняют окружение/нагрузку даже при сопоставимых features |
| Trial protocol | R, warmup count/inputs, cold/steady policy, consecutive versus corpus rounds/fixed permutations/fresh VM; control corpus/order digest для order-dependent опытов |
| Outcome policy | Версия нормализации outcome, без скрытого выбрасывания return changes/volatile values |

`ets` и `ets_member` имеют одинаковые feature semantics и их F сопоставимы, но
result cache не следует бесшумно переиспользовать между разными timing/config
вариантами. `execution_ref`, PID, Tid, monotonic timestamps и родительский queue
index не являются portable identity. Selection/mutation seed не нужен для
регенерации уже замороженного x; если он определял контрольный corpus/order,
сохраняются их identities и происхождение. Prepared descriptor нельзя сохранять
как reusable artifact; при новой VM создаётся новый plan.

Это ключ **совместимости опыта**, не доказательство идентичности неизвестного
содержимого shared VM. В режиме unreset VM автоматический cache reuse между jobs
по одному этому ключу следует отключить. Сохранять отдельные observation series
с одинаковым compatibility key, не объединять их повторы в новое R и не заменять
новый запуск прежними «100%». Reuse результата допустим только при отдельно
подтверждённом контракте initial state/reset и выбранной политике актуальности.
Job ID/time нужны для различения записей, но не становятся input/feature identity.

Текущие formats — Erlang report maps/`term_to_binary`, pretty-print в escript;
EFZR — отдельный формат конкретной mutation recipe, не calibration database.
Минимальный новый CLI `scripts/calibrate.escript` может вызвать предложенный API и
сохранить отдельный versioned `.term` report. JSON API/encoder в проекте нет;
не добавлять dependency ради него. Если позднее потребуется JSON export, binary IDs
отдавать hex, undefined score — null + reason, runtime handles исключать; schema
эквивалентен report map. Это предложенный export, не нынешняя возможность.

### Инициаторы, novelty и однократная фиксация

**П.** Порядок внедрения: offline frozen corpus сначала; затем opt-in report-only
инициаторы при старте campaign, после нового интересного input и при явной проверке
снимка корпуса. Изменение build/manifest/schema **инвалидирует** результаты и требует
новой подготовки; live hot reload в текущей campaign не поддерживать.

В offline path нет `efz_feedback:evaluate/3`, `efz_corpus:add/2`, selector/mutator
или перезапуска stats. В campaign можно захватить оригинальный full RunResult в
`efz_worker:execute/4` сразу после строки 60 и использовать как первый повтор R,
затем выполнить R−1 наблюдательных повторов этих bytes. Их отдельная очередь не
двигает staged cursors, RNG и mutation iteration, не меняет parent/recipe.
Старый feedback/retention вызывается **ровно один раз для исходного результата**,
в прежнем порядке; calibration observations не сливаются в Global.

Начальные seeds остаются baseline entries; обычный seed pass с причиной
`seed_calibration` сохраняется, не превращается в mutation discovery. Исторические
baseline/candidate streams сохраняют свой контракт при выключенной функции.
Включённые дополнительные исполнения неизбежно меняют timing/VM side effects;
для целей без reset независимость после такой вставки требует проверки, а не
обещания идентичного campaign stream.

Результаты повторов прикреплять через отдельный `Report.calibration` index по
content/key. Нынешний `efz_corpus:add/2` не обновляет metadata существующего input;
не злоупотреблять им для повторной вставки. В первой версии новый corpus-update API
не нужен. Исходные input/metadata/added_at/recipes и число discoveries остаются.
Отдельного scorer/last-new-coverage timestamp сейчас нет; не вводить его случайно
и не переинициализировать `stats.started_at` из-за проверки устойчивости.

Outcome variation и новые calibration crash witnesses сохранять с происхождением
`stability`, raw input и actual result; не отбрасывать findings из-за низкого S и
не считать их mutation discovery. Можно использовать существующее crash storage
для witness bytes/result с дополнительной metadata, при отдельном учёте повторов.
Crash-only probe observations по-прежнему не suppress успешную будущую novelty.

Если позже будет принято **отдельное** решение менять поиск на stable-only feedback,
понадобится отложенная однократная транзакция `G_before + original result + series +
compatibility epoch -> один commit`. Это нельзя сделать повторным вызовом evaluate
для R прогонов или merge(U): последний может включать crash-only/вариативные features.
Такое изменение retention и scheduler требует собственного ADR/тестов и не входит
в предлагаемый report-only этап. Автоматическое удаление unstable seeds, masking
probes, suppression crashes и переоценка baseline status здесь не предлагаются.

### Стоимость и раздельная статистика

**П, оценка сложности, не новый benchmark:** offline N уникальных inputs требует
`N*R` измеряемых исполнений (+ явно выбранный warmup). При использовании исходного
seed/candidate результата первый раз уже выполнен: дополнительно `R−1` на input.
Никакого нового измерения Phase 2.1 backend throughput для этой оценки не нужно.

Пусть P — число manifest probes, H_r — unique hits повторa, T_r — hook calls.
Plan preparation — O(P) storage один раз; публикации зависят от T_r.
`tab2list` O(H_r), sorting O(H_r log H_r), prepared validation — membership по
H_r; per_execution дополнительно строит allowed set O(P) каждый раз. Aggregation
с hash-map частот ожидаемо O(sum H_r), memory O(|U_x|), финальный вывод сортируется.
Хранение всех raw F стоило бы O(sum H_r), поэтому оно bounded optional; frequencies
не требуют R копий каждого set. Snapshot/result copying и ETF serialization тоже
пропорциональны данным и должны измеряться отдельно от target time.

В диагностике plan на четыре probes занимал 5 ETS rows (4 + marker), 3,128 bytes
в обоих backend. Это один живой plan, **не peak и не total campaign memory**.
После опытов coverage/plan tables отсутствовали. Orphan targets от намеренного
coordinator kill очищались **диагностическим harness**, не автоматически движком;
этот факт нельзя замаскировать итоговым «нет утечек». Lifecycle tests отдельно
подтверждают штатный cleanup после caller/cancel/shutdown.

Предлагаемые additive counters: `stability_attempts`, `stability_completed`,
`stability_missing`, `stability_target_failures`, `stability_infra_failures`.
Не увеличивать `stats.executions`/`discoveries`/`rejections` для повторов; прежний
`calibrations` оставить счётчиком initial seed passes для compatibility.
Wall time: добавить `stability_us`, `stability_in_mutation_us`,
`mutation_active_us = existing mutation_us - stability_in_mutation_us`.
Старый `mutation_us` может остаться wall time исходной фазы; новый отчёт throughput
использует **mutation executions / mutation_active_us**, а не R repeats в числителе.
Startup/seed phase, aggregation, serialization и fresh-VM startup сообщаются отдельно.
При выключенной функции прежние timings/counters/stream не меняются.

## 9. План реализации и критерии приёмки

Все изменения ниже **предложены**, сейчас в коде их нет.

| Этап | Файлы/зависимости | Критерий готовности | Отключение и compatibility |
|---|---|---|---|
| 1. Prerequisites | `src/efz_executor.erl`, при guard `src/efz_cov_rt.erl`; `test/efz_backend_tests.erl`, новые focused cases | Terminal origin отличает caught exit от kill; metadata не обещают tree completeness; owner loss abort/dirty; caught broken context fail closed; current 62/3 остаются | Outcome tuples и run/3 сохранены; никаких default backend/worker changes |
| 2. Snapshot admission contract | Executor metadata + proposed `src/efz_stability.erl`; manifest/preflight reuse | Full immutable F после root DOWN и до уничтожения store; series проверяет scope/build/cleanup; empty != missing, timeout prefix != full | Snapshot code backend не заменяется; существующий feedback не зависит от нового observer |
| 3. Offline collector | Proposed `src/efz_calibration.erl`, `scripts/calibrate.escript`, разрешённые internal modules в transform denylist | Frozen bytes, R/state protocol, живой plan owner, тот же run/4; versioned keys; bounded cancellation/limits; никакого novelty side effect | Только явный отдельный вызов; current campaigns не используют collector |
| 4. Regression suite | Proposed `test/efz_stability_tests.erl`, calibration integration suite, существующие backend/semantic tests | 50% vector, equal-size sets, frequency vs multiplicity, corpus masking trap, R<2/empty/incomplete/incomparable; A→B→A, child scope, fresh VM IDs; exception/kill/timeout/owner/cancel; corruption/build mismatch | Tests не фиксируют performance thresholds и не меняют ожидаемые старые probe/outcome sets |
| 5. Campaign report-only integration | `efz_config`, `efz_worker`, `efz_stats`, report docs; optional index без corpus reinsertion | Первый результат + R−1 repeats; original feedback ровно один раз; no RNG/cursor advance; отдельные times/counters; witness failures не скрываются | **`stability => disabled` по умолчанию**; включение явное, configurable R/95/90; старые baselines работают без новой серии |
| 6. Reporting/measurement | CLI/README/coverage documentation, короткий fixed-budget overhead опыт | Per-input rows, weighted corpus/min/unstable/subset membership; actual overhead, cold/warm distinction; JSON только при реальной потребности | Старые отчёты/EFZR/CLI сохраняются; additive versioned section |

Реализация не должна начинаться с повторного `efz:start` для каждого input: это
путает seed initialization с stability, создаёт отдельный feedback state и не
сбрасывает всю VM. Также не следует менять scheduler count/target rand seed ради
красивого процента. Основной режим остаётся штатным, altered runtime — отдельный
помеченный диагностический опыт.

Открытые внешние вопросы ограничены тем, что нельзя получить из этого checkout:
каков reset/warmup/initial-state контракт конкретной реальной цели и оправданы ли
выбранные R/95/90 на ней. Cowboy harness/dependencies отсутствуют; универсальная
независимость реальных Erlang приложений не проверена. Для описанного root-only
engine контракта owners, snapshots, failure paths и первые implementation points
установлены; предполагать скрытый Go/OTP application runner не требуется.

## 10. Воспроизведение диагностики без постоянных fixtures

Исходники ниже — только аудиторские. Они не подключены к приложению или build
profiles и не реализуют production calibration API. Один `audit_sites` компилируется
с обычной автоматической instrumentation; остальные модули дают контролируемые
inputs, state и ACK. В опытах kill сначала принимается сообщение после завершённого
probe; sleeps для доказательства публикации не используются. Все созданные children
явно завершены, а VM-loss тест убивает только собственный внешний helper.

Из корня `efz/`:

```sh
AUDIT_DIR=$(mktemp -d /tmp/efz-calibration-audit.XXXXXX)
python3 - "$AUDIT_DIR" <<'PY'
from pathlib import Path
import re,sys
text=Path('docs/calibration-readiness.md').read_text()
blocks=re.findall(r'<!-- audit-source: ([a-z_.]+) -->\n```erlang\n(.*?)\n```',text,re.S)
assert {name for name,_ in blocks} == {'audit_sites.erl','audit_target.erl','audit_background.erl','audit.escript','existing_example.escript'}
for name,source in blocks:
    Path(sys.argv[1],name).write_text(source+'\n')
PY
rebar3 compile > "$AUDIT_DIR/compile.log" 2>&1
rebar3 eunit > "$AUDIT_DIR/eunit.log" 2>&1
rebar3 ct > "$AUDIT_DIR/ct.log" 2>&1
escript "$AUDIT_DIR/audit.escript" "$AUDIT_DIR" > "$AUDIT_DIR/diagnostic.log" 2>&1
escript "$AUDIT_DIR/existing_example.escript" "$AUDIT_DIR" > "$AUDIT_DIR/existing-example.log" 2>&1
```

Не добавляйте `+S 4:4` к этому воспроизведению молча: original main и fresh controls
использовали штатную конфигурацию. Проверяйте exit statuses каждой команды; файлы
логов сами по себе не доказывают успех. Этот скрипт намеренно обнаруживает описанные
текущие ограничения assertions; после их будущего исправления аудитный expected
результат потребуется пересмотреть, а не использовать старый скрипт как policy test.

<!-- audit-source: audit_sites.erl -->
```erlang
-module(audit_sites).
-export([a/0,b/0,c/0,d/0]).
a()->a.
b()->b.
c()->c.
d()->d.
```

<!-- audit-source: audit_target.erl -->
```erlang
-module(audit_target).
-export([run/1]).
run(<<"a">>)->audit_sites:a(),audit_sites:b(),audit_sites:c(),ok;
run(<<"b">>)->audit_sites:a(),audit_sites:b(),audit_sites:d(),ok;
run(<<"only_a">>)->audit_sites:a();
run(<<"only_b">>)->audit_sites:b();
run(<<"alternate">>)->
 N=persistent_term:get({?MODULE,alternate},0),persistent_term:put({?MODULE,alternate},N+1),
 case N rem 2 of 0->run(<<"a">>);1->run(<<"b">>) end;
run(<<"state_a">>)->case persistent_term:get({?MODULE,dirty},false) of false->audit_sites:c();true->audit_sites:d() end;
run(<<"state_b">>)->persistent_term:put({?MODULE,dirty},true),audit_sites:b();
run(<<>>)->{error,invalid_input};
run(<<"empty">>)->ok;
run(<<"halt">>)->audit_sites:a(),erlang:halt(23);
run(<<"hold">>)->run({hold,persistent_term:get({?MODULE,observer}),campaign});
run({repeat,N})->lists:foreach(fun(_)->audit_sites:a() end,lists:seq(1,N)),ok;
run({fail,Kind})->audit_sites:a(),case Kind of error->error(artificial);throw->throw(artificial);exit->exit(killed) end;
run({hold,P,Tag})->audit_sites:a(),P!{published,Tag,self(),get('$efz_execution_context')},receive finish->ok end;
run({local_state})->
 Before={get(audit_user_key),process_info(self(),messages),rand:export_seed()},
 put(audit_user_key,dirty),self()!audit_old_message,rand:seed(exsplus,{1,2,3}),audit_sites:a(),Before;
run({child,Kind,P,Copy})->
 audit_sites:a(),C=get('$efz_execution_context'),
 F=fun()->Before=get('$efz_execution_context'),
   case Copy of true->efz_cov:attach(C);false->ok end,
   P!{child_ready,self(),Before},receive go->ok end,
   Result=try audit_sites:c(),ok catch error:E->{error,E} end,
   P!{child_done,self(),Result}
 end,
 Child=case Kind of spawn->spawn(F);spawn_link->spawn_link(F);spawn_monitor->{CP,_}=spawn_monitor(F),CP end,
 {child,Child};
run({background,Bg})->audit_sites:a(),gen_server:call(Bg,work);
run({background_timer,Bg,P})->audit_sites:a(),erlang:send_after(0,Bg,{work,P}),ok;
run(<<"bad_context_caught">>)->put('$efz_execution_context',bad_context),try audit_sites:a() catch error:_->caught end;
run(<<"broken_table_caught">>)->C=get('$efz_execution_context'),put('$efz_execution_context',setelement(4,C,make_ref())),try audit_sites:a() catch error:_->caught end.
```

<!-- audit-source: audit_background.erl -->
```erlang
-module(audit_background).
-behaviour(gen_server).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2]).
init([])->{ok,#{}}.
handle_call(work,_,S)->audit_sites:c(),{reply,get('$efz_execution_context'),S}.
handle_cast(_,S)->{noreply,S}.
handle_info({work,P},S)->audit_sites:c(),P!{background_done,get('$efz_execution_context')},{noreply,S}.
```

<!-- audit-source: audit.escript -->
```erlang
#!/usr/bin/env escript
-mode(compile).
main([D,"fresh",Out])->
 paths(D),{ok,AB}=file:read_file(filename:join(D,"artifact.term")),A=binary_to_term(AB),
 {ok,Ms}=efz_instrument:preflight([A]),{ok,P}=efz_cov_manifest:prepare(automatic,Ms),
 R=run(<<"a">>,options(ets,P)),ok=efz_cov_manifest:release(P),
 ok=file:write_file(Out,term_to_binary(#{result=>R,online=>erlang:system_info(schedulers_online)}));
main([D,"halt",_Out])->
 paths(D),{ok,AB}=file:read_file(filename:join(D,"artifact.term")),{ok,Ms}=efz_instrument:preflight([binary_to_term(AB)]),
 {ok,P}=efz_cov_manifest:prepare(automatic,Ms),run(<<"halt">>,options(ets,P));
main([D])->
 paths(D),put(events,[]),
 lists:foreach(fun(M)->File=filename:join(D,atom_to_list(M)++".erl"),
   {ok,M}=compile:noenv_file(File,[debug_info,warnings_as_errors,{outdir,filename:join(D,"plain")}])
 end,[audit_target,audit_background]),
 {ok,A}=efz_instrument:compile(filename:join(D,"audit_sites.erl"),
   #{modules=>[audit_sites],source_root=>D,outdir=>filename:join(D,"targets")}),
 ok=file:write_file(filename:join(D,"artifact.term"),term_to_binary(A)),
 {ok,[M]}=efz_instrument:preflight([A]),
 put(identities,maps:from_list([{maps:get(function,X),{audit_sites,maps:get(build_id,M),maps:get(probe_id,X)}}||X<-maps:get(probes,M)])),
 OTPFile=filename:join([code:root_dir(),"releases",erlang:system_info(otp_release),"OTP_VERSION"]),
 emit(environment,#{otp_file=>file:read_file(OTPFile),otp=>erlang:system_info(otp_release),erts=>erlang:system_info(version),
  architecture=>erlang:system_info(system_architecture),schedulers=>erlang:system_info(schedulers),
  online=>erlang:system_info(schedulers_online),erl_flags=>os:getenv("ERL_FLAGS"),
  compiler=>compile:module_info(md5),manifest=>M,defaults=>efz_config:defaults()}),
 lists:foreach(fun(B)->suite(B,[M]) end,[ets,ets_member]),
 campaign_cases(A),fresh_vms(D),hot_code(D,A,[M]),
 []=tables(),emit(final_resources,#{coverage_and_plan_tables=>tables()}),
 Events=lists:reverse(get(events)),
 ok=file:write_file(filename:join(D,"events.term"),term_to_binary(Events)),
 ok=file:write_file(filename:join(D,"events.txt"),unicode:characters_to_binary(io_lib:format("~tp.~n",[Events]))),
 io:format("ALL DIAGNOSTIC ASSERTIONS PASSED (~B records)~n",[length(Events)]).
paths(D)->true=code:add_patha(filename:absname("_build/default/lib/efz/ebin")),
 ok=filelib:ensure_dir(filename:join([D,"plain","x"])),true=code:add_patha(filename:join(D,"plain")).
options(B,P)->#{coverage=>automatic,coverage_backend=>B,coverage_plan=>P}.
run(I,O)->efz_executor:run(audit_target,I,1000,O).
hits(R)->ok=maps:get(coverage_status,R),maps:get(coverage,R).
ids(Names)->lists:sort([maps:get(N,get(identities))||N<-Names]).
emit(K,V)->put(events,[{K,V}|get(events)]),io:format("PASS ~tp~n",[K]).
series(Sets)->
 R=length(Sets),U=lists:foldl(fun ordsets:union/2,[],Sets),
 F=lists:foldl(fun(S,M)->lists:foldl(fun(X,A)->A#{X=>maps:get(X,A,0)+1} end,M,ordsets:from_list(S)) end,#{},Sets),
 I=lists:sort([X||{X,N}<-maps:to_list(F),N=:=R]),
 Score=case R>=2 andalso U=/=[] of true->100*length(I)/length(U);false->not_applicable end,
 #{r=>R,union=>U,intersection=>I,variable=>ordsets:subtract(U,I),frequencies=>F,score=>Score}.
suite(B,Ms)->
 {ok,P}=efz_cov_manifest:prepare(automatic,Ms),O=options(B,P),
 First=[run(<<"a">>,O)||_<-lists:seq(1,3)],[H,H,H]=[hits(X)||X<-First],H=ids([a,b,c]),
 #{score:=100.0}=Stable=series([hits(X)||X<-First]),emit({B,deterministic},#{runs=>First,series=>Stable}),
 persistent_term:erase({audit_target,alternate}),
 Alt=[run(<<"alternate">>,O)||_<-lists:seq(1,3)],As=[hits(X)||X<-Alt],
 [3,3,3]=[length(X)||X<-As],#{score:=50.0}=S=series(As),
 [F1,F2,F3]=As,F1=F3,F2=ids([a,b,d]),
 50.0=maps:get(score,series([F2,F1,F2])),
 Collapsed=series([ordsets:union(X,Y)||{X,Y}<-lists:zip(As,[F2,F1,F2])]),100.0=maps:get(score,Collapsed),
 emit({B,alternation},#{runs=>Alt,series=>S,corpus_input_feature_score=>50.0,wrong_collapsed_score=>100.0}),
 R1=run({repeat,1},O),R100=run({repeat,100},O),H1=hits(R1),H1=hits(R100),H1=ids([a]),
 emit({B,multiplicity},#{once=>R1,hundred=>R100}),
 [AA,BB,AA]=[hits(run(X,O))||X<-[<<"only_a">>,<<"only_b">>,<<"only_a">>]],
 []=ordsets:intersection(AA,BB),
 Perms=[[<<"only_a">>,<<"only_b">>],[<<"only_b">>,<<"only_a">>]],
 Rows=[lists:sort([{X,hits(run(X,O))}||X<-Order])||Order<-Perms],[Row,Row]=Rows,
 emit({B,aba},#{a=>AA,b=>BB,permutations=>Rows}),
 persistent_term:erase({audit_target,dirty}),DA1=hits(run(<<"state_a">>,O)),_=run(<<"state_b">>,O),DA2=hits(run(<<"state_a">>,O)),
 #{score:=+0.0}=Dirty=series([DA1,DA2]),persistent_term:erase({audit_target,dirty}),DA1=hits(run(<<"state_a">>,O)),
 emit({B,shared_state},#{without_reset=>Dirty,after_explicit_fixture_reset=>DA1}),
 L1=run({local_state},O),L2=run({local_state},O),{ok,{undefined,{messages,[]},undefined}}=LO=maps:get(outcome,L1),LO=maps:get(outcome,L2),
 emit({B,local_state},#{runs=>[L1,L2]}),
 E=run(<<>>,O),E2=run(<<"empty">>,O),[]=hits(E),[]=hits(E2),{ok,{error,invalid_input}}=maps:get(outcome,E),
 #{score:=not_applicable}=EmptySeries=series([[],[]]),emit({B,empty},#{invalid_return=>E,empty_snapshot=>E2,series=>EmptySeries}),
 Failures=[run({fail,K},O)||K<-[error,throw,exit]],
 lists:foreach(fun(X)->H1=hits(X) end,Failures),emit({B,exceptions},Failures),
 concurrent(O),terminations(B,O),children(B,O),background(B,O),live_snapshot(B),
 Bad=run(<<"bad_context_caught">>,O),[]=hits(Bad),{ok,caught}=maps:get(outcome,Bad),
 Broken=run(<<"broken_table_caught">>,O),{error,_}=maps:get(coverage_status,Broken),{infrastructure,_}=maps:get(outcome,Broken),
 emit({B,context_interference},#{malformed_context_caught=>Bad,invalid_table_caught=>Broken}),
 {efz_cov_plan,1,PT,_}=P,emit({B,live_plan},#{owner=>ets:info(PT,owner),protection=>ets:info(PT,protection),rows=>ets:info(PT,size),bytes=>ets:info(PT,memory)*erlang:system_info(wordsize)}),
 ok=efz_cov_manifest:release(P),undefined=ets:info(PT),
 Disposed=run(<<"empty">>,O),{error,invalid_coverage_plan}=maps:get(coverage_status,Disposed),
 emit({B,disposed_empty},Disposed).
async(I,T,O)->Parent=self(),Tag=make_ref(),{C,M}=spawn_monitor(fun()->Parent!{done,Tag,efz_executor:run(audit_target,I,T,O)} end),{C,M,Tag}.
ready(Tag)->receive {published,Tag,T,C}->{T,C} after 3000->error(no_publication_ack) end.
finished({C,M,Tag})->R=receive {done,Tag,X}->X after 4000->error(no_result) end,
 down(M,C),R.
down(M,P)->receive {'DOWN',M,process,P,_}->ok after 3000->error(missing_down) end.
table({efz_context,1,_,{ets_member,T},_})->T;table({efz_context,1,_,T,_})->T.
concurrent(O)->
 Q1=make_ref(),Q2=make_ref(),C1=async({hold,self(),Q1},3000,O),C2=async({hold,self(),Q2},3000,O),
 {T1,X1}=ready(Q1),{T2,X2}=ready(Q2),false=element(3,X1)=:=element(3,X2),false=table(X1)=:=table(X2),
 T1!finish,T2!finish,R1=finished(C1),R2=finished(C2),A=ids([a]),A=hits(R1),A=hits(R2),
 undefined=ets:info(table(X1)),undefined=ets:info(table(X2)),
 emit({maps:get(coverage_backend,O),concurrent},#{first=>R1,second=>R2,separate_refs_and_tables=>true}).
terminations(B,O)->
 lists:foreach(fun(Kind)->Q=make_ref(),H={Caller,CM,_}=async({hold,self(),Q},case Kind of timeout->1000;_->3000 end,O),
 {T,C}=ready(Q),Owner=element(5,C),TM=monitor(process,T),OM=monitor(process,Owner),
 {ok,Before}=efz_cov:snapshot(C),Before=ids([a]),
 case Kind of
  kill->exit(T,kill),R=finished(H),{exit,killed}=maps:get(outcome,R),Before=hits(R),down(TM,T),down(OM,Owner),emit({B,kill},R),
    Caught=run({fail,exit},O),Keys=[outcome,target_outcome,coverage_status,coverage,builds],
    true=maps:with(Keys,R)=:=maps:with(Keys,Caught),emit({B,exit_origin_ambiguity},#{caught_exit=>Caught,external_kill=>R});
  timeout->R=finished(H),{timeout,1000}=maps:get(outcome,R),Before=hits(R),down(TM,T),down(OM,Owner),emit({B,timeout},R);
  caller_death->exit(Caller,kill),down(CM,Caller),down(TM,T),down(OM,Owner),emit({B,caller_death},#{snapshot_returned=>false});
  coordinator_kill->exit(Owner,kill),R=finished(H),down(OM,Owner),true=is_process_alive(T),
    {infrastructure,{coordinator_down,killed}}=maps:get(outcome,R),{error,coordinator_down}=maps:get(coverage_status,R),
    []=maps:get(coverage,R),exit(T,kill),down(TM,T),emit({B,coordinator_kill},#{result=>R,target_was_alive_after_result=>true,diagnostic_harness_killed_orphan=>true})
 end,undefined=ets:info(table(C))
 end,[kill,timeout,caller_death,coordinator_kill]).
children(B,O)->
 lists:foreach(fun({Kind,Copy})->R=run({child,Kind,self(),Copy},O),{ok,{child,CP}}=maps:get(outcome,R),
 receive {child_ready,CP,undefined}->ok after 3000->error(no_child_ready) end,
 true=is_process_alive(CP),CM=monitor(process,CP),Q=make_ref(),H=async({hold,self(),Q},3000,O),{T,_}=ready(Q),
 CP!go,CR=receive {child_done,CP,V}->V after 3000->error(child_not_done) end,down(CM,CP),
 case Copy of false->ok=CR;true->{error,{efz_infrastructure,invalid_coverage_table}}=CR end,
 T!finish,Next=finished(H),A=ids([a]),A=hits(R),A=hits(Next),
 emit({B,child,Kind,Copy},#{parent=>R,next_execution=>Next,child_result=>CR,child_context_before_attach=>undefined})
 end,[{spawn,false},{spawn_link,false},{spawn_monitor,false},{spawn,true}]).
background(B,O)->
 {ok,Bg}=gen_server:start(audit_background,[],[]),
 R=run({background,Bg},O),{ok,undefined}=maps:get(outcome,R),
 Timer=run({background_timer,Bg,self()},O),receive {background_done,undefined}->ok after 3000->error(no_timer_ack) end,
 A=ids([a]),A=hits(R),A=hits(Timer),ok=gen_server:stop(Bg),emit({B,background},#{otp_call=>R,timer=>Timer}).
live_snapshot(B)->
 C=efz_cov:open(B),FakeRef=make_ref(),Copied=setelement(3,C,FakeRef),Parent=self(),
 {Writer,Mon}=spawn_monitor(fun()->efz_cov:attach(Copied),audit_sites:a(),Parent!writer_ready,
   receive write_more->audit_sites:b() end,Parent!writer_finished end),
 receive writer_ready->ok after 3000->error(no_writer_ack) end,
 {ok,First}=efz_cov:snapshot(C),First=ids([a]),
 Writer!write_more,receive writer_finished->ok after 3000->error(no_second_ack) end,down(Mon,Writer),
 {ok,Second}=efz_cov:snapshot(C),Second=ids([a,b]),ok=efz_cov:close(C),
 emit({B,unguarded_snapshot_and_ref},#{before_quiescence=>First,after_quiescence=>Second,changed_reference_accepted=>true}).
campaign_cases(A)->
 lists:foreach(fun(Kind)->
  persistent_term:put({audit_target,observer},self()),
  {ok,_}=efz:start(#{target=>audit_target,artifacts=>[A],seeds=>[<<"hold">>],max_iterations=>0,timeout=>3000}),
  {T,C}=ready(campaign),Owner=element(5,C),TM=monitor(process,T),OM=monitor(process,Owner),
  [{efz_worker,W,worker,_}]=supervisor:which_children(efz_worker_sup),
  case Kind of
   cancel->Await=catch efz:await(0),{'EXIT',{timeout,_}}=Await,true=is_process_alive(T),
     ok=efz:stop(),emit(campaign_cancel,#{await_timeout_did_not_cancel=>true,result_snapshot=>unavailable});
   worker_kill->exit(W,kill),R=efz:await(3000),{infrastructure_failure,{worker_down,killed}}=maps:get(status,R),
     emit(worker_kill,R),ok=efz:stop()
  end,down(TM,T),down(OM,Owner),[]=tables()
 end,[cancel,worker_kill]),
 {ok,_}=efz:start(#{target=>audit_target,artifacts=>[A],seeds=>[<<"only_a">>,<<"only_b">>],max_iterations=>0}),
 R=efz:await(3000),#{calibrations:=2,executions:=0,discoveries:=0}=maps:get(stats,R),
 [seed_calibration,seed_calibration]=[maps:get(retention_reason,X)||X<-maps:get(decisions,R)],
 emit(seed_initialization,R),ok=efz:stop().
fresh_vms(D)->
 Samples=[begin Out=filename:join(D,"fresh-"++integer_to_list(N)++".term"),
   {0,Text}=child_vm(D,"fresh",Out),ok=file:write_file(Out++".log",Text),
   {ok,Bytes}=file:read_file(Out),binary_to_term(Bytes)
 end||N<-lists:seq(1,3)],
 [R1,R2,R3]=[maps:get(result,X)||X<-Samples],F=hits(R1),F=hits(R2),F=hits(R3),F=ids([a,b,c]),
 B=maps:get(builds,R1),B=maps:get(builds,R2),B=maps:get(builds,R3),
 emit(fresh_vm_same_build,#{samples=>Samples,series=>series([F,F,F])}),
 Out=filename:join(D,"halt-result.term"),{23,Text}=child_vm(D,"halt",Out),false=filelib:is_file(Out),
 ok=file:write_file(filename:join(D,"halt.log"),Text),emit(vm_halt,#{exit_status=>23,snapshot_file=>missing}).
child_vm(D,Mode,Out)->
 Port=open_port({spawn_executable,os:find_executable("escript")},[binary,exit_status,stderr_to_stdout,
   {args,[filename:join(D,"audit.escript"),D,Mode,Out]}]),port_result(Port,<<>>).
port_result(P,Acc)->receive {P,{data,B}}->port_result(P,<<Acc/binary,B/binary>>);{P,{exit_status,N}}->{N,Acc}
 after 10000->port_close(P),error(child_vm_deadline) end.
hot_code(D,A,Ms)->
 {ok,P}=efz_cov_manifest:prepare(automatic,Ms),O=options(ets,P),
 {ok,audit_sites,Plain}=compile:noenv_file(filename:join(D,"audit_sites.erl"),[binary,debug_info,warnings_as_errors]),
 code:purge(audit_sites),code:delete(audit_sites),{module,audit_sites}=code:load_binary(audit_sites,"diagnostic_plain",Plain),
 R=run(<<"a">>,O),[]=hits(R),{ok,ok}=maps:get(outcome,R),
 {error,{loaded_module_identity_mismatch,audit_sites}}=Preflight=efz_instrument:preflight([A]),
 emit(hot_plain_replacement,#{old_plan_result=>R,explicit_preflight=>Preflight}),
 ok=efz_cov_manifest:release(P),code:purge(audit_sites),code:delete(audit_sites),{ok,_}=efz_instrument:preflight([A]).
tables()->[T||T<-ets:all(),lists:member(ets:info(T,name),[efz_execution_coverage,efz_coverage_plan])].
```

<!-- audit-source: existing_example.escript -->
```erlang
#!/usr/bin/env escript
-mode(compile).
main([D])->
 true=code:add_patha(filename:absname("_build/default/lib/efz/ebin")),
 {ok,A}=efz_instrument:compile("examples/simple_parser/efz_example_parser.erl",
  #{modules=>[efz_example_parser],source_root=>".",outdir=>filename:join(D,"existing-target")}),
 {ok,Ms}=efz_instrument:preflight([A]),{ok,P}=efz_cov_manifest:prepare(automatic,Ms),
 Rows=[begin Rs=[efz_executor:run(efz_example_target,B,1000,#{coverage=>automatic,coverage_backend=>ets,coverage_plan=>P})||_<-lists:seq(1,3)],
  [H,H,H]=[maps:get(coverage,R)||R<-Rs],true=H=/=[],[ok,ok,ok]=[maps:get(coverage_status,R)||R<-Rs],
  #{input=>B,runs=>Rs,exact_sets_equal=>true,feature_stability=>100.0}
 end||B<-[<<0>>,<<255>>]],
 ok=efz_cov_manifest:release(P),
 ok=file:write_file(filename:join(D,"existing-example.term"),term_to_binary(Rows)),
 io:format("~tp~n",[Rows]).
```
