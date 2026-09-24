# Технический аудит EFZ — 12 сентября 2026

## 1. Executive Summary

**EFZ уже является работающим coverage-guided fuzzer для синхронного binary target в одном Erlang process. Цикл mutation → execution → coverage → active corpus → следующая mutation замкнут. Это подтверждено реальным запуском, а не только наличием API.**

В отдельном эксперименте штатные efz_mutation_plan, efz_worker, efz_executor, automatic instrumentation и efz_corpus построили цепочку:

~~~text
corpus id=1: <<>>          initial seed из файла
    dictionary_insert "A"
corpus id=2: <<"A">>       новое покрытие; parent=1
    dictionary_insert "B" в позицию 1
corpus id=3: <<"AB">>      новое покрытие; parent=2
    dictionary_insert "C" в позицию 2
corpus id=4: <<"ABC">>     новое покрытие; parent=3
~~~

Выполнены 40 реальных мутаций, 41 input точно передан отдельному harness, 40 recipes восстановили исходные байты. Получены три discoveries и один crash. Сохранённый input CRASH воспроизвёл error(test_crash), в том числе в новой VM. Доказательства: [e2e.txt](audit-2026-09-12/e2e.txt), [исходник эксперимента](audit-2026-09-12/run.escript), [полный report ETF](audit-2026-09-12/e2e-report.term), [fresh replay](audit-2026-09-12/fresh-replay.log).

**Граница работоспособности:** successful corpus существует в памяти одной кампании. Встроенных чтения seed directory, сохранения новых successful inputs на диск, восстановления очереди и универсального fuzz CLI нет. После stop/start в эксперименте осталось исходное множество из одного seed. Готовые escripts сохраняют итоговый report по собственной инициативе; это не persistence corpus service.

**Staged mutator действительно интегрирован.** Random mode остаётся default и также использует пополняемый corpus. Утверждения «новый mutator существует отдельно» или «scheduler видит только initial seeds» текущему коду не соответствуют.

Три главных проблемы:

1. Не завершён пользовательский жизненный цикл кампании: общий launcher, seed files, долговременный corpus и restart.
2. Изоляция ограничена корневым target process; child execution не измеряется автоматически, children могут оставаться живыми, глобальное состояние меняет последующие cases. Успешная проверка manifest не доказывает, что выбранный target вообще исполнил инструментированный код.
3. Staged scheduler может остановиться до доступных мутаций: 256 допустимых seeds, этапы dictionary_overwrite/bitflip, неподходящий словарь и default max_idle_visits дают ноль mutation executions. Штатные тесты не проверяют этот случай и явно не утверждают повторное использование coverage-discovered parent.

Следующая фаза должна довести существующий один-worker loop до воспроизводимого инструмента: закрепить ancestry end-to-end тестом, исправить преждевременную остановку, добавить вход/выход corpus и восстановление, формализовать границы execution/coverage и ошибки хранения. Новый mutation engine, другой coverage backend, distributed scheduling и UI для этого не нужны.

## 2. Current Architecture

### Проверенный checkout и область аудита

Основной репозиторий: /home/anonymous_usr/erl:fuzz/efz, ветка main, HEAD ac09c1f3e938c3a79b369fc6a87d61c1ae739db4, «chore: initialize efz OTP project». Родительский workspace не является рабочим Git repository.

HEAD не описывает проверенную реализацию: большинство src/*.erl, test/, docs/, examples/, fixtures/, bench/, scripts/ — уже существовавшие untracked файлы; README.md, rebar.config, src/efz.app.src изменены. Зафиксированы [исходный status](audit-2026-09-12/status-before.txt) и [SHA-256 всех 83 исходных файлов](audit-2026-09-12/before-sha256.json). Соседний efz.worktrees/agents-condemned-silverfish содержит те же 83 файла с идентичными байтами: это отдельный checkout, а не второй engine в runtime.

После аудита SHA-256 всех этих 83 файлов совпадают. Добавлены только данный отчёт и audit-2026-09-12/ с доказательствами и диагностическими исходниками; production-код и штатные tests не менялись, commit/push не выполнялись. Сохранённый комплект повторно запущен из нового temporary directory: diagnostic assertions и fresh replay прошли. [Проверка целостности и структуры отчёта](audit-2026-09-12/verification.json).

Изучены все модули src, тестовые компоненты, launch/replay scripts, примеры, fixtures, назначение benchmark drivers и документация архитектуры, coverage, mutation, replay и предыдущих фаз. Исторические performance numbers не пересчитывались и не используются как новые доказательства. Документ calibration-readiness.md содержит аудит и предложения; production calibration/stability collector из его плана не реализован.

Среда: OTP 27.0 / ERTS 15.0, Rebar3 3.25.0, Linux. rebar.config устанавливает minimum_otp_vsn=27, debug_info, warnings_as_errors, src_dirs=[src,examples/simple_parser], deps=[]. Основное приложение зависит от kernel, stdlib, crypto. Runtime-код Go/Python, NIF coverage, rebar provider для fuzz CLI, CI workflow и дополнительных project profiles не обнаружено.

### Карта каталогов

| Каталог / файл | Фактическая роль |
|---|---|
| src/ — 24 Erlang modules и efz.app.src | Единственная production реализация |
| examples/simple_parser/ | Два module, обычный parser и adapter; входят в обычную сборку |
| examples/automatic/run.escript | Конкретная random campaign, target/seeds прописаны в script |
| examples/staged/ | Staged parser, hex dictionary и конкретная campaign с replay |
| examples/cowboy/ | Отдельный synchronous parse_qs harness, launcher, 14 дополнительных проверок; внешняя зависимость |
| test/ | EUnit, Common Test и scripted test mutator |
| fixtures/ | Проверка семантики instrumentation, unsupported AST, include/record/tail cases, performance targets |
| scripts/replay.escript | CLI только для recipe → bytes |
| scripts/coverage_bench.escript, bench/ | Benchmark, profiling, отчёты, архивирование; не campaign services |
| docs/ | Контракты, исторические проверки, планы; сами по себе не реализации |
| _build/ | Собранные BEAM, сгенерированные manifests/reports/crash artifacts; не source of truth |

### Реальное дерево процессов

~~~text
application controller
└── efz_sup                    supervisor: one_for_all, intensity=0, period=1
    └── efz_fuzzer             temporary dynamic child, gen_server
        ├── efz_corpus         start_link; linked child, НЕ отдельный child spec efz_sup
        ├── efz_stats          start_link; linked child
        └── efz_worker_sup     linked supervisor: one_for_one, 5/10
            └── efz_worker     один temporary child
                └·· coordinator  spawn_monitor на каждый input; не supervised child
                    └·· target   spawn_monitor на каждый input; M:run(Input)
~~~

Пунктирные отношения обозначают создание/monitor, а не links. efz_fuzzer дополнительно мониторит worker. Реализация: [efz_fuzzer:init/1](../src/efz_fuzzer.erl), строки 17–25; [efz_worker_sup:init/1](../src/efz_worker_sup.erl), строка 2; [efz_executor:coordinate/6](../src/efz_executor.erl), строки 25–60.

При нормальном target exception worker продолжает кампанию. Worker не перезапускается: fuzzer возвращает infrastructure_failure/worker_down. Падение corpus/stats/worker supervisor приводит через trapped EXIT к остановке fuzzer; terminate/2 останавливает worker supervisor, затем stats и corpus. Глобальное coverage и mutation cursors при падении worker не восстанавливаются. При campaign completion worker остаётся живым без следующего iterate: освобождение corpus, prepared ETS plan и всех campaign services требует efz:stop/0.

### Владение состоянием

| Состояние | Владелец / механизм | Время жизни |
|---|---|---|
| Active corpus, next integer ID, random selection PRNG | efz_corpus gen_server state; PRNG в его process dictionary | Одна campaign |
| Global successful coverage, builds | efz_worker.feedback: map + sets | Одна campaign |
| Mutation plan, explicit RNG, cursors, pending IDs | efz_worker.mutation_state | Одна campaign |
| Prepared allowed probe set | Protected unnamed ETS efz_coverage_plan; owner worker | До смерти worker |
| Current execution coverage | Public unnamed ETS efz_execution_coverage; owner coordinator | Один input |
| Pointer к current coverage | Target process dictionary, '$efz_execution_context' | Один target process |
| Decisions, crash IDs, bounded recipe trace | Worker state | Одна campaign |
| Counters | efz_stats gen_server | Одна campaign |
| Final report, await waiters | efz_fuzzer state | До stop |
| Instrumented BEAM + manifest sidecar | Filesystem; loaded modules — общий code server | За пределами одного input |
| Crash .input/.term/.recipe | Filesystem, efz_crash:save/4 | Между запусками |

В production src нет persistent_term. Он используется в benchmark-only efz_perf_replay и может использоваться target, но не очищается executor.

## 3. Component Inventory

Статус оценивает заявленную функцию компонента, а не только компиляцию. PARTIAL также используется для отсутствующей части пользовательского сценария с явным указанием, что соответствующего модуля нет. STUB обозначал бы существующую заглушку; таких модулей в основном пути не найдено. UNUSED означает отсутствие вызовов из основного runtime, а не разрешение на немедленное удаление.

В таблице «Реализация / назначение» объединяет Purpose и Current implementation; I/O — Inputs и Outputs. Файл module X находится в src/X.erl, если явно не указан другой путь.

| Component | Relevant modules/files; реализация / назначение | Inputs → Outputs | State ownership | Called by → Calls | Status |
|---|---|---|---|---|---|
| Public entry | efz:start/1, stop/0, stats/0, await/1; OTP API | Config map → {ok,Pid} / error; await → report map | App / fuzzer | Erlang caller, examples → application, supervisor, fuzzer | IMPLEMENTED |
| Generic CLI | Отдельного efz_cli и общего run TARGET CORPUS нет; examples/*/run.escript содержат конкретные campaigns | Args конкретного примера → API config | Escript main | shell → efz:start | PARTIAL — generic launcher отсутствует |
| Configuration | efz_config:prepare/1; defaults, callbacks, coverage preflight; mutation schema отдельно | map → {ok,prepared map}/{error,...} | Caller, затем worker | fuzzer → instrument, mutation_plan, code | PARTIAL — верхний уровень нестрогий |
| Harness contract | efz_target; -callback run(binary()) -> term(); behavior не обязателен для runtime | binary → любой term / exception | Target process | executor → M:run/1 | IMPLEMENTED |
| Harness / target selection | config target atom; callback фиксирован run/1; проверяет экспорт | target atom, artifacts → loaded callbacks | Code server | config → ensure_loaded/function_exported | PARTIAL — нет MFA/arity/source loader в общем API |
| Target invocation | efz_executor:run/4, coordinate/6 | Module, Input, timeout, options → result map | Per-case coordinator | worker, recipe → M:run/1 | IMPLEMENTED в scope одного process |
| Input delivery | worker execute/4 → executor; binary не декодируется | binary + parent → тот же binary в harness | Worker/coordinator/target | corpus/planner → executor/harness | IMPLEMENTED |
| Worker | efz_worker gen_server, сообщения iterate | prepared config/corpus → executions/report | Worker | worker_sup → mutator, executor, feedback, corpus, crash, stats | IMPLEMENTED |
| Timeout handling | executor wait_target/5, kill_and_drain/2; deadline + DOWN | timeout integer ms → {timeout,T} | Coordinator | executor → monitor/exit/receive | PARTIAL — root cleanup; descendants не учтены |
| Exception handling | executor try/catch; infrastructure отделено от target failures | Exception/exit → outcome tuple, stack для error/throw | Coordinator + worker | target → feedback/crash | IMPLEMENTED с оговорками origin |
| Coverage compiler facade | efz_instrument:compile/2, preflight/1, load/1 | .erl, allowlist, options → BEAM/manifest/artifact map | Filesystem/code server | Caller/config/replay → compiler/PT/manifest | IMPLEMENTED |
| Coverage instrumentation | efz_instrument_pt:parse_transform/2 | Abstract forms → hook-instrumented forms, manifest attribute | Локальный compile state | compile → efz_cov_rt:hit/1 в сгенерированном коде | PARTIAL — ограниченное AST, strict default |
| Coverage hook | efz_cov_rt:hit/1; ETS insert / member+insert | Probe identity → ok или tagged error | Per-case ETS через PD context | Instrumented target → ETS | IMPLEMENTED для attached process |
| Coverage context/collection | efz_cov:open/attach/snapshot/close | Backend/context → exact sorted identities | Coordinator owns ETS | executor → ETS/runtime | IMPLEMENTED |
| Coverage identity/validation | efz_cov_manifest; source mappings, exact allowlist, prepared plan | manifest/hits → ok/error, builds map | Worker ETS / immutable maps | config/executor/recipe → ETS/sets/beam_lib | PARTIAL — проверяет observed IDs, не непрерывную целостность loaded code |
| Coverage state/feedback | efz_feedback:new/1,evaluate/3 | Previous set + result + phase → new set + decision | Worker | worker → efz_cov:merge/2 | IMPLEMENTED |
| Corpus | efz_corpus; entries list, input dedup при add, IDs | [binary], add(binary,meta) → entry/list/{ok,id}/{existing,binary} | Corpus gen_server | fuzzer/worker → rand | PARTIAL — только RAM, initial duplicates остаются |
| Queue | Тот же entries; отдельного queue service нет | Ordered entries → selectable entries | Corpus | worker/planner → corpus API | IMPLEMENTED базовая очередь |
| Seed selection | corpus:select/0 random; mutation_plan:visit/2 staged round-robin | Entries → parent entry | Corpus RNG / worker plan | worker → rand либо plan cursor | PARTIAL — idle cutoff может опередить полезный stage |
| Random mutator | efz_mutator callback; efz_mutator_random:mutate/2, четыре операции | binary, #{iteration=>N} → binary | Worker process PRNG | worker random branch → rand/list operations | IMPLEMENTED, legacy/default path |
| Staged mutation | efz_mutation_plan:new/1,next/2 | Plan + текущие entries → candidate/skip/done/error | Worker | worker staged branch → efz_mutation, dictionary, rand:*_s | PARTIAL — интегрирован, premature exhaustion |
| Deterministic stages | mutation_plan:deterministic/4, det_op/4 | Stage, binary, index, config → operation/done | Content/config cursors | Planner → mutation primitives | IMPLEMENTED |
| Mutation primitives | efz_mutation:apply_operation/3,apply_operations/3 | binary + concrete ops + limits → ok/skip/error | Нет mutable state | Planner/recipe/tests → binary/crypto | IMPLEMENTED |
| Havoc | mutation_plan:random_attempts/5,stack/7 | Primary, active entries, explicit RNG → realized stack | Worker plan | Planner → primitives/random_operation | IMPLEMENTED |
| Dictionary | efz_dictionary:normalize/2,load/2; EFZ hex format | binary tokens или hex file → normalized tokens + hash | Prepared mutation config | mutation_plan:prepare → bounded file read | IMPLEMENTED |
| Splicing | mutation_plan:random_operation/6; mutation splice op | Primary + donors из всех entries → prefix/suffix binary, donor bytes/hash | Worker plan | Havoc/splice lane → mutation:apply_operation | IMPLEMENTED |
| Recipes | efz_recipe:make/4, encode/decode, regenerate | Primary + realized ops → EFZR data / exact output | Metadata corpus/crash; optional bounded trace | worker/replay → mutation, hash | IMPLEMENTED для staged |
| Replay | recipe:execute/5, execute_file/5; scripts/replay.escript | Explicit target/builds + input → executor result; CLI recipe → file | Fresh prepared plan | Caller/scripts → preflight/executor | PARTIAL — generic execution CLI нет, harness identity не pinned |
| Crash storage | efz_crash:fingerprint/3,save/4 | Input/result/meta/dir → .input/.term/[.recipe], crash record | Files + worker crash_ids | worker → file/crypto/recipe | PARTIAL — неатомарная запись, errors роняют worker |
| Statistics | efz_stats:inc/get; worker timing/counts | Counter key → updated counters/map | Stats gen_server | Worker/fuzzer/API → gen_server | PARTIAL — worker_down не увеличивает infra counter |
| Supervision | efz_app, efz_sup, efz_fuzzer, efz_worker_sup | Start/stop/death → lifecycle/report | OTP processes | efz/application → links/monitors/supervisors | PARTIAL — per-case coordinator не supervised |
| Parallel workers | config valid принимает только workers=1 | workers>1 → invalid configuration | Нет | config rejects | PARTIAL — функция отсутствует, не dormant pool |
| Persistent campaign state | Corpus/global coverage/queue cursors/RNG restore не реализованы | — | Нет | — | PARTIAL — только crash artifacts и внешние reports |
| Manual compatibility | efz_cov:hit/1, executor:run/3; общий executor | Manual ID → {manual,Id}; run/3 → outcome | Тот же execution context | Legacy callers/tests → runtime | LEGACY, доступен явно |
| Old helper APIs | cov:interesting/2, reset_local/0, snapshot/0 | Direct manual helpers | PD/context | В текущем src/test/examples вызовов нет | UNUSED основным путём |
| Test prerecorded mutator | test/efz_scripted_mutator | iteration → заранее заданный binary; parent игнорируется | Нет | Phase2/CT/backend tests → lists:nth | UNUSED production |
| Benchmark replay / measurement | bench/efz_perf*, *.escript, scripts/coverage_bench | Inputs/workloads → timing/ETF/text | Benchmark VM; replay uses persistent_term | Explicit bench scripts → public EFZ APIs | UNUSED production |

## 4. Actual End-to-End Execution Flow

### Общий старт

~~~text
Erlang caller / examples/.../run.escript:main
  -> efz_instrument:compile(SourceFile, CompilerConfig)           % явный предварительный шаг
  -> efz:start(ConfigMap)
  -> application:ensure_all_started(efz)
  -> supervisor:start_child(efz_sup, efz_fuzzer child spec)
  -> efz_fuzzer:start_link(ConfigMap)
  -> efz_config:prepare(ConfigMap)
       -> efz_mutation_plan:prepare(MutationOptions, Seeds)       % только staged
            -> efz_dictionary:normalize/2, load/2
       -> efz_instrument:preflight(Artifacts)                    % automatic
            -> load/1 -> loaded_manifest/2
       -> code:ensure_loaded(Target), function_exported(Target,run,1)
  -> efz_fuzzer:init(PreparedConfig)
       -> efz_corpus:start_link([binary()], SelectionSeed)
       -> efz_stats:start_link()
       -> efz_worker_sup:start_link(Config#{coordinator=>FuzzerPid})
            -> efz_worker:init(Config)
                 -> efz_cov_manifest:prepare(Mode, Manifests)     % default
                 -> efz_feedback:new(Builds)
                 -> efz_mutation_plan:new(MutationConfig)        % staged
                 -> self() ! iterate
~~~

Artifact descriptor имеет module atom, absolute beam path, manifest path, build_id binary SHA-256, warnings. Prepared config — обычная map, не application env и не persistent_term. Артефакты загружаются до создания worker. Loader не компилирует отдельный неинструментированный harness из переданного пути: harness должен быть доступен code server.

### Calibration и два пути мутации

Worker сначала копирует efz_corpus:all() в pending_seeds. Каждое начальное entry исполняется один раз с Phase=calibration; это инициализация GlobalCoverage, не repeated stability calibration.

~~~text
random:
  efz_worker:handle_info(iterate, State)
    -> efz_corpus:select()
       gen_server:call(efz_corpus, select)
       <- #{id:=integer(), input:=binary(), metadata:=map(), added_at:=integer()}
    -> MutatorModule:mutate(Input, #{iteration => N+1})
       <- binary()

staged:
  efz_worker:staged_iteration(State)
    -> efz_corpus:mutation_entries()
       gen_server:call(efz_corpus, mutation_entries)
       <- [#{id:=integer(), input:=binary()}]                     % весь актуальный corpus
    -> efz_mutation_plan:next(PlanMap, Entries)
       <- {candidate, Binary, ProvenanceMap, NextPlan}
        | {skip, Reason, NextPlan}
        | {done, Reason, NextPlan}
        | {error, Reason, NextPlan}
    -> efz_recipe:make(Provenance, Binary, MutationConfig, Builds)
       <- RecipeMap
    -> efz_worker:execute(Binary, #{id=>ParentId}, mutation, State)
~~~

skip только планирует следующий iterate. Счётчик iteration/max_iterations относится к сгенерированным и исполняемым candidates; skips и initial calibration в него не входят.

### Исполнение, messages и возврат

~~~text
efz_worker:execute(Input, ParentEntry, Phase, State)
  -> efz_executor:run(TargetModule, Input, TimeoutMs, ExecutorOptions)
       Request = make_ref()
       spawn_monitor(coordinate(Caller, Request, ...))
         monitor(Caller)
         efz_cov:open(Backend)
           <- {efz_context,1,Ref,TableOrBackendTable,OwnerPid}
         spawn_monitor(target fun)
           efz_cov:attach(Context)
             put('$efz_execution_context', Context)
           TargetModule:run(Input)
             -> synchronous target calls
             -> instrumented clause: efz_cov_rt:hit({Module,BuildId,ProbeId})
                  ets:insert(Table, {{probe, Identity}})
           Parent ! {target_result, Ref, self(), Outcome}
         receive target_result / DOWN / caller DOWN / timeout
         дождаться target DOWN; при timeout kill_and_drain/2
         efz_cov:snapshot(Context) -> {ok,SortedHits} / {error,...}
         efz_cov_manifest:validate_prepared(...) -> ok / error
         Caller ! {Request, CoordinatorPid, ResultMap}
         after: kill_and_drain(Target), close(Context), demonitor(Caller)
       caller ждёт DOWN coordinator, затем возвращает ResultMap
~~~

ResultMap содержит execution_ref, outcome, target_outcome, coverage, coverage_status, elapsed_us, builds. В coordinator_down fallback нет target_outcome, coverage=[], builds=#{} и инфраструктурная ошибка; это не обычный пустой successful snapshot.

Дополнительные messages: стандартные {'DOWN',Monitor,process,Pid,Reason}; при ошибке ETS hook отправляет владельцу {efz_cov_failure,Ref,Why}. После завершения кампании worker отправляет {campaign_done,WorkerPid,Report}; fuzzer отвечает сохранённым gen_server callers await. Target input не проходит через файловый descriptor, stdin, port, socket или общий mailbox worker: он захватывается closures при spawn_monitor.

### Обратная связь и следующее поколение

~~~text
ResultMap
  -> efz_feedback:evaluate(FeedbackState, ResultMap, Phase)
       successful: New = Observed \ Global
                   Global1 = Global union Observed
       <- {ok,NewFeedback,#{new_probes=>New,retention_reason=>Reason}}
  -> efz_worker:retain(Input, Metadata)
       if Reason = new_coverage:
         efz_corpus:add(Input, Metadata)
           gen_server:call(efz_corpus,{add,Input,Metadata})
           entries := entries ++ [NewEntry]
           next := next + 1
           <- {ok,Id} / {existing,Input}
  -> efz_worker:record_failure(...)                              % отдельная ветвь artifacts
  -> self() ! iterate
  -> corpus:select() либо corpus:mutation_entries()              % видят NewEntry
  -> следующая mutation, где NewEntry может быть Parent
~~~

Конкретное замыкание: worker строки 42–49, 58–90; corpus строки 12–14; mutation_plan строки 63–76. Между successful retain и следующим select отсутствует разрыв. Файловой операции в этом участке нет.

## 5. Harness and Input Delivery

### Как пользователь выбирает цель

**Минимальный run(Input) when is_binary(Input) можно запустить сегодня без изменения внутренних модулей EFZ.** Достаточно экспортировать run/1, скомпилировать/загрузить module обычными средствами Erlang и передать target => Module в efz:start/1. Отдельный adapter нужен только если существующий target не соответствует run/1 или необходимо управлять классификацией ошибок. Формальный behavior efz_target существует; runtime проверяет функцию, но не требует атрибута -behaviour.

В automatic mode дополнительно нужны instrumented artifacts тех module, которые реально будут вызваны. Можно инструментировать сам module с run/1 — как staged example — либо отдельный parser, оставив harness обычным — как automatic/Cowboy/audit example.

| Вопрос | Фактический ответ / evidence |
|---|---|
| Target module | Config key target, atom; config:valid/1 строки 29–33 |
| Function и arity | Фиксированы run/1. function/arity options не реализованы; произвольные верхнеуровневые ключи могут быть молча сохранены |
| Contract | efz_target: -callback run(binary()) -> term() |
| Загрузка | artifacts preflight сначала; затем ensure_loaded(Target); отдельного compile_harness API нет |
| Проверка экспорта | erlang:function_exported(M,run,1), config строки 42–48 |
| Process | Новый target process для каждого input; один и тот же BEAM |
| Вызов | M:run(Input), executor строка 34; явного apply/3 нет |
| Success | Любой нормальный возврат, включая {error,...}, false или {invalid,...}, обёрнут в {ok,ReturnValue} |
| Error/throw | {crash,Class,Reason,Stack} |
| exit/1 | {exit,Reason}, stack не сохраняется |
| Linked abnormal exit | Может завершить root → monitor DOWN → {exit,Reason}; если root trap_exit и обработал сигнал, нормальный return считается success |
| Timeout | Убивается и дожидается DOWN только root; children не регистрируются |
| Cleanup callbacks | before_input/reset/after_input/cleanup не существуют |
| Application lifecycle | init target application / stop target application EFZ не управляет |

Для существующих targets, ожидающих list, iolist, arbitrary term или MFA, преобразование/adapter пишет пользователь. В audit_harness input передавался audit_target:parse/1 без изменений. В Cowboy harness bytes кладутся в #{qs=>Input}; штатные request_error qs/limit_reached преобразуются в {invalid,...}, неожиданные исключения проходят наружу.

### Один seed от файла до target

Production API принимает готовый непустой список binaries. Ни config, ни corpus не читают seed-файлы. Доступный путь:

~~~erlang
{ok, Seed} = file:read_file(SeedPath),       % caller, не функция EFZ
efz:start(#{target => Harness, seeds => [Seed], artifacts => Artifacts, ...}).
~~~

Затем binary хранится в entry.input, выбирается напрямую или передаётся planner, полученный binary идёт execute → run/4 → M:run/1 → parser. Audit script делает именно это; file:read_file и запись fixture находятся вне coverage. Эти подготовительные действия не подменяют core mocks.

| Тип / ограничение | Random runtime | Staged runtime |
|---|---|---|
| Initial inputs | Только binary(); список должен быть непустым | То же; максимум 4096 initial entries |
| Верхняя граница input | Нет общей границы в config/worker/executor | max_input_bytes default 4096, допустимо 0…1048576 |
| Generated type | Worker проверяет is_binary | Primitives возвращают binary; ошибки/skip обрабатываются planner |
| Empty binary | Допустим; delete может получить <<>>, mutate(<<>>) даёт <<0>> | Допустим; delete/splice могут получить <<>> |
| Oversized seed | Принимается при достаточной памяти | prepare отклоняет oversized_initial_seed |
| Oversized candidate | Общей проверки размера нет | Размер проверяется при операциях; skip(size_limit)/error |
| Byte conversions | Полное binary_to_list и list_to_binary для непустого input | Binary operations; только генерация literal bytes через список |
| Exact recipe | Нет | Primary bytes + concrete ops + literal tokens/donors + hash |
| Persistence successful input | Только RAM entry | Только RAM entry с recipe |

Input как Erlang term передаётся между corpus, worker, coordinator и target. Это не zero-copy API: maps/lists и heap data передаются через process boundaries; у refcounted binaries backing storage может разделяться. Семантических искажений binary нет. В staged режиме mutation_entries/0 каждый раз переносит список всего корпуса; snapshots/report также копируют структуры. Это последующий performance вопрос, а не разрыв feedback loop.

Низкоуровневый efz_executor:run/4 не проверяет is_binary(Input) и в тестах получает tuples/atoms. Это полезно для executor tests, но не расширяет binary contract основного fuzz loop. Replay execute/execute_file ограничивает raw input одним MiB, тогда как random mode такого общего предела не имеет.

### Изоляция case и влияние предыдущего input

| Ресурс | Реальная очистка / возможность влияния |
|---|---|
| Root process dictionary | Исчезает с root; следующий root новый. EFZ добавляет один служебный context key |
| Root mailbox | Исчезает; result/monitor messages остаются в отдельном coordinator и не попадают в следующий case |
| Coverage ETS | Новая таблица на case, удаляется coordinator; normal root termination её не уничтожает |
| Target-owned ETS | Обычные owner tables исчезают с root; heir transfer, чужие/child-owned tables не очищаются EFZ |
| Registered root name | Освобождается при смерти root; имена живых children остаются |
| Spawned children | Registry/kill-tree нет; как unlinked, так и linked child могут пережить нормальный return root |
| Timers | Общего cancel/reset нет; сообщения/действия в адрес выживших процессов могут исполняться позднее |
| Monitors/links root | Root прекращается; EFZ drains собственные monitors. Чужие процессы и их связи не обходятся |
| Application env, persistent_term, code server | Не очищаются и разделяются cases |
| Файлы, внешние сервисы, sockets, NIF state | Универсального reset/изоляции нет |

Подтверждённый A→B→A сценарий: input state вызывает path_a; dirty записывает persistent_term; повторный идентичный state вызывает path_ab и другой probe set. См. [cross_case_state.txt](audit-2026-09-12/cross_case_state.txt).

Подтверждены unlinked и linked children, которые исполнили instrumented path_abc, но имели undefined execution context: coverage root execution осталось пустым, child остался жив после return. Отдельно child остался жив после timeout root. Диагностический script сам завершил созданные им children после фиксации результатов; **эта уборка не приписывается EFZ**.

Следовательно, успешная изоляция root ETS/PD не гарантирует воспроизводимость произвольного OTP-приложения. erlang:halt, VM/NIF crash или неограниченное потребление общей памяти также не изолированы отдельным process.

## 6. Coverage Pipeline

### Механизм и granularity

EFZ использует собственный source parse_transform и ETS exact set. OTP native coverage, cover, counters, hit-count buckets и bitmap в основной реализации отсутствуют. Instrumentation выполняется заранее, при compile:noenv_file/2, а не на каждой итерации.

Metric в manifest — clause_outcome_probe. Hook добавляется в начало тела выбранной clause/outcome. Реальные kind:

~~~text
function_clause
case_clause
if_clause
receive_clause
receive_after
try_body
try_of_clause
catch_clause
try_after
fun_clause
named_fun_clause
~~~

Это не edge coverage, не полное branch coverage и не line coverage. Два исхода на одной строке имеют разные probe IDs; строки нужны для source mapping. Факт входа в тело clause не показывает каждый переход между clauses или каждый исход проверки guard. andalso/orelse обходятся как обычные op nodes: отдельные true/false probes для оператора не создаются. Patterns и guards сохраняются без hook.

List/binary/map comprehensions, maybe, неизвестные AST constructs и executable record defaults не получают внутренних probes. strict=true отклоняет incomplete instrumentation; strict=false сохраняет конструкцию, пишет limitations в manifest и предупреждает. Проверки семантики есть в phase2_tests:semantics/1, manifest/1, tail/1, skipped/0. Вся native/NIF часть и невыбранные modules вне измерения.

### Identity и source mapping

Полная identity:

~~~erlang
{ModuleAtom, BuildIdSHA256, ProbeIdInteger}
~~~

ProbeId начинается с 1 внутри каждого module и увеличивается в детерминированном AST traversal. BuildId вычисляется SHA-256 от tuple с instrumentation version, OTP release, compile module MD5, нормализованными preprocessed forms и relevant compiler options. [efz_instrument_pt:parse_transform/2](../src/efz_instrument_pt.erl), строки 35–55; probe/4, строки 109–118.

| Свойство | Вывод |
|---|---|
| Повторная сборка одинакового source/options/toolchain | Identity стабильна; проверено phase2 determinism |
| Порядок компиляции разных modules | Не влияет на локальную нумерацию: общий mutable allocator отсутствует |
| Перестановка/добавление AST nodes | Может перенумеровать probes; меняется build namespace |
| Разные builds | Старые IDs нельзя механически переносить в новую coverage epoch |
| Коллизии | В пределах валидного manifest duplicate integers/structural paths отклоняются. Межмодульного bitmap aliasing нет. SHA-256 остаётся cryptographic hash, не математической гарантией уникальности |
| Relocation | Source paths внутри source_root нормализуются, relocated-build test проходит; внешние absolute include paths/изменения toolchain могут менять hash |
| Mapping | Каждый probe содержит function, arity, kind, structural_location, source_file, line, column |

BEAM содержит efz_manifest attribute, sidecar — тот же term. Loader сравнивает sidecar с BEAM manifest и уже загруженный module с ожидаемым manifest. Запрет других parse transforms, module allowlist, запрет EFZ internals/OTP modules и отдельный outdir защищают согласованность обычного build path.

### Local → snapshot → global

~~~text
local coverage:
    fresh public unnamed ETS set, execution coordinator owner
    row = {{probe, {Module,BuildId,ProbeId}}}
    duplicate hit overwrites тот же key

local context:
    {efz_context,1,FreshRef,TableOr{ets_member,Table},Owner}
    target PD '$efz_execution_context'

snapshot:
    ets:tab2list → sorted list of full probe identities
    after root DOWN; observations survive crash/kill/timeout

validation:
    allowed exact identities in protected worker-owned ETS plan
    alternative per_execution: build allowed set from manifests

global coverage:
    worker.feedback.global, Erlang sets
    only successful input coverage is unioned

reset:
    next execution получает другую таблицу, reference и root process
    previous table удаляется; глобальное множество не сбрасывается до конца campaign
~~~

ets_member сначала проверяет ets:member, затем insert при отсутствии. Это оптимизация повторных hits в том же set, не отдельная metric. Prepared/per_execution — две стратегии validation, не разные collectors. Differential suite проверяет все четыре комбинации.

### Точная семантика interesting

[efz_feedback:evaluate/3](../src/efz_feedback.erl), строки 5–22:

~~~text
require Result.builds == Feedback.builds
require coverage_status == ok

if outcome == {ok, _}:
    New = set(Observed) - Global
    Global := Global union Observed
    calibration -> retention_reason = seed_calibration
    mutation and New == [] -> equivalent_coverage
    mutation and New != [] -> new_coverage
else if infrastructure/coverage error:
    stop campaign as infrastructure failure
else:
    target_failure; Global unchanged; new_probes=[]
~~~

**New coverage = ранее не наблюдавшаяся полная probe identity на успешном выполнении.** Не новый count, не новая комбинация известных probes, не hash signature и не новый bitmap bit. Идентичное множество с другими кратностями выполнения неинтересно. Другой набор, являющийся подмножеством Global, тоже неинтересен.

Проверяемая формула C_new = C_current − C_global реализована, но с условиями success и phase. Crashes/throws/exits/timeouts могут иметь непустой execution coverage, однако не пополняют successful global и corpus. Это явная policy, которая не позволяет crash-only probe подавить будущую полезную successful mutation.

Calibration делает merge успешных initial seeds, но не вставляет их повторно и не увеличивает discoveries. Full snapshot successful input после evaluate не сохраняется в его corpus metadata: остаются new_probes, builds, outcome, input identity и provenance. Report.coverage — union всей campaign, не coverage конкретного input.

### Границы достоверности feedback

1. **Неиспользованные artifacts.** Автоматическая campaign с валидным artifact audit_target и harness, который его не вызывает, завершилась completed, coverage=[], infrastructure_failures=0. Валидация проверяет допустимость фактически увиденных IDs; пустой список допустим. Нельзя по успешному preflight заключить, что harness связан с selected target. [Evidence](audit-2026-09-12/disconnected_artifacts.txt).
2. **Hot reload.** После preflight выбранный module заменён обычной неинструментированной сборкой. Следующий case вернул path_a, coverage=[], coverage_status=ok и старую builds map. Prepared plan — pinned allowlist, не проверка выполняющегося кода на каждом case. [Evidence](audit-2026-09-12/hot_reload.txt). README запрещает такой reload, но runtime не обнаруживает нарушение.
3. **Children.** Context process dictionary не наследуется spawn. Instrumented child без attach выполняет hook как no-op. Ручной перенос context в child возможен через API, но quiescence/tree cleanup executor от этого не появляется.
4. **Повреждение context.** Ошибка ETS шлёт sticky failure message, но malformed-context clause в cov_rt только raises. Target, заменивший context и поймавший exception, вернул success с пустым coverage. [Evidence](audit-2026-09-12/caught_malformed_context.txt). Обычный код, стирающий весь process dictionary, также может отключить hook.
5. **Потеря coordinator.** Target остаётся живым; Result fallback содержит builds=#{}. evaluate может заменить первичную coordinator_down ошибку на instrumentation_build_mismatch. Это не target crash, но первичная причина теряется на уровне campaign report.

Эти пункты не отменяют работоспособность coverage в заявленной области свежего root process с неизменяемой instrumented сборкой. Они ограничивают применимость результата к stateful/async targets и требуют явной диагностики.

## 7. Corpus and Queue Pipeline

**Corpus feedback loop: WORKING внутри одной кампании. Persistent/restart часть: PARTIAL, не реализована.**

Ключевой модуль — [efz_corpus.erl](../src/efz_corpus.erl), всего 15 строк; малый размер скрывает существенные ограничения, но не отсутствие queue.

| Понятие | Что имеется фактически |
|---|---|
| Initial corpus | Config.seeds = [binary()]; entry создаётся на каждый элемент без initial dedup |
| Active queue | State.entries; вначале seeds, затем все successful new-coverage inputs |
| Interesting input | Mutation с outcome {ok,_} и NewProbes ≠ [] |
| Saved input | В successful path — entry.input в RAM. В crash path — файл .input |
| Favored input | Понятия/оценки/флага нет |
| Donor input | Любой entry.input из текущего active corpus, отличный по content от Primary |
| Queue ID | Порядковое целое 1…N, выделяется serial corpus gen_server |
| Content ID | SHA-256 в worker metadata и planner/recipe; initial metadata изначально пустая |

### Вставка и повторное использование

retain/2 вызывает add/2 при new_coverage. Corpus последовательно проверяет binary equality по списку entries. При отсутствии совпадения добавляет entry в конец и увеличивает next ID. Уже существующий binary возвращает {existing,Binary}, а не ID; worker меняет retention_reason на existing_input.

Random select/0 вызывает rand:uniform(length(Entries)) по **всему текущему** списку. У недавно добавленного entry ненулевая вероятность выбора. Детерминированной гарантии выбора до завершения конечного бюджета у random mode нет.

Staged mode при каждом next получает текущие mutation_entries/0; snapshot IDs на round формируется из insertion order. Вновь добавленный entry становится primary со следующего round. Donor list в random_operation(splice,...) берётся из всех текущих Entries, даже когда pending primary IDs относятся к началу round. Поэтому новый corpus input может стать donor до своей первой очереди как primary.

Эксперимент подтвердил parent=2 для AB и parent=3 для ABC. Дополнительно штатный random example создал corpus entry <<>> с parent=2, где entry 2 был ранее найденной mutation <<"@">>. Default random loop тоже способен использовать newly discovered parent; конкретная последовательность этого example не обязана повторяться без selection_seed.

### Metadata, дедупликация и scheduling

| Свойство | Состояние |
|---|---|
| Duplicate successful mutations | По полному binary equality, линейный поиск; SHA не используется как dedup index |
| Duplicate initial seeds | Сохраняются с разными integer IDs; fresh check с двумя <<"noop">> дал corpus size=2 и calibrations=2 |
| Parent | Есть parent integer ID для retained mutation |
| Mutation depth/generation | Явных полей нет; пока сохранены ancestors, глубина выводима из parent links |
| Insertion order | Список, append в конец |
| Coverage signature | Отдельного signature/full successful snapshot нет; только discovery delta и build namespace |
| Per-entry seed status | Нет quarantine для crash/timeout/нестабильного seed; initial failures остаются в active corpus |
| Favored/power/energy | Не реализовано |
| Global corpus size/memory bound | Нет общей квоты; staged ограничивает initial count и размер input, не число накопленных entries |
| Random starvation | Возможно в конечной campaign; равномерная вероятность, не гарантия обслуживания |
| Staged fairness | Round snapshots защищают старые entries от постоянного роста, пока campaign не остановлена idle cutoff |
| Identical content staged state | Cursors keyed по content hash + config ID; initial duplicate queue IDs разделяют progress |

### Disk и restart

Corpus не вызывает file, DETS, disk_log, Mnesia или persistent_term. Не имеет load/save/resume API. Config corpus_dir не интерпретируется. Successful discovery не получает input file и sidecar на диске.

Examples записывают полный report.term после await. Из него пользователь может вручную получить binaries и передать как seeds новой campaign, но EFZ не выполняет этот импорт, не восстанавливает IDs, cursors, PRNG, global coverage и crash index. Повторная seed calibration также не равна продолжению прерванной campaign.

В experiment после нового start с тем же Config corpus size стал 1 вместо 4. Следовательно, runtime feedback-loop не обрывается между retain и select, но **перенос прогресса через stop/restart отсутствует**.

## 8. Mutation Pipeline

### Какие операторы работают

«Deterministic stage» означает перебор без случайных выборов. Любая отдельная concrete operation efz_mutation детерминирована. «Replayable» ниже относится к штатно записанным staged recipes; legacy random сам recipes не создаёт.

| Mutation | Реализация | Deterministic stage | Replayable | Used by runtime |
|---|---|---|---|---|
| Bit flip | flip_bits: contiguous 1/2/4 bits, MSB-first; legacy random: один bit | Да, все fitting offsets | Да, staged | Random; staged bitflip/havoc |
| Byte flip | invert_bytes: 1/2/4 bytes | Да | Да | Staged byteflip/havoc |
| Arithmetic | add: 8/16/32 bits, signed delta, modulo 2^W; endian big/little для multi-byte | Да, ±1…±max_delta | Да | Staged arithmetic/havoc |
| Interesting integers | set_integer: 0,1,2,half−2,half−1,half,half+1,max−1,max | Да, boundary | Да | Staged boundary/havoc |
| Insert | Concrete binary block, включая append boundary | Отдельного literal stage нет | Да | Havoc; legacy вставляет один random byte |
| Delete | Удаление непустого блока, вплоть до empty output | Нет отдельного stage | Да | Havoc; legacy один byte |
| Overwrite | Literal block с сохранением размера | Нет отдельного literal stage | Да | Havoc; legacy один random byte |
| Duplicate | Копия блока в insertion position | Нет отдельного stage | Да | Havoc |
| Dictionary insert | Вставка token в каждый byte boundary | Да | Да, token bytes в recipe | dictionary_insert/havoc |
| Dictionary overwrite | Token в каждый fitting offset | Да | Да | dictionary_overwrite/havoc |
| Splice | prefix(Current,CutA) ++ suffix(Donor,CutB) | Нет; random cut points/donor | Да, donor bytes/hash в op | splice stage и havoc |
| Havoc | Стек реализованных операций глубиной 1…havoc_depth | Нет; explicit RNG state | Да | Staged havoc lane |

Все операции реализованы в [efz_mutation:operation/3](../src/efz_mutation.erl); выбор/перебор — в [efz_mutation_plan](../src/efz_mutation_plan.erl), строки 81–187. Width order и offsets проверяются independent bit/block models и enumeration tests.

### Фактический порядок staged execution

Default stages:

~~~text
bitflip, byteflip, arithmetic, boundary,
dictionary_insert, dictionary_overwrite, havoc, splice
~~~

Это **interleaved round-robin lanes**, а не «полностью закончить все deterministic stages каждого seed, затем начать havoc, затем splice».

На visit выбирается очередной corpus ID. Для его content/config key значение lane определяет один stage по modulo length(Stages). Lane увеличивается; stage выполняет не больше attempts_per_visit попыток и выдаёт максимум один candidate. Следующий visit этого content использует следующий lane даже если текущий sweep не закончен. Поэтому havoc может выполняться задолго до окончания bitflip sweep.

Per-stage cursor хранит следующий integer mutation index. На skip/no_change deterministic index продвигается. На exhaustion stage остаётся завершённым; candidates заранее не материализуются. Возвращённый Plan можно передать следующему next/2 — in-memory resumability работает и протестирована. API сохранения cursor/RNG plan на диск отсутствует.

### Ограничения и ресурсы

| Параметр | Default | Допустимый диапазон / смысл |
|---|---:|---|
| max_input_bytes | 4096 | 0…1048576 |
| max_block_bytes | 128 | 1…65536 |
| max_token_bytes | 128 | 1…65536; token также ограничен max_block_bytes |
| max_tokens | 256 | 0…4096 |
| max_dictionary_bytes | 16384 | 0…1048576 |
| max_delta | 8 | 1…128 |
| attempts_per_visit | 8 | 1…1024; максимум попыток, не число outputs |
| havoc_depth | 8 | 1…32 |
| random_retries | 4 | 1…128, дополнительно ограничены attempts budget |
| max_idle_visits | 256 | 1…100000 consecutive empty visits на ВСЮ campaign |
| trace_limit | 0 | 0…10000 recipes |
| max_iterations для staged | 1000, если не задано | 0…1000000; infinity запрещён |

Отдельного max mutations per seed нет. Общее ограничение — execution budget, finite deterministic search либо idle cutoff. Seeds ≤4096 проверяются только staged prepare. Strict mutation options отклоняют неизвестные ключи, в отличие от верхнего campaign config.

Словарь загружается один раз bounded read; формат — even-length hex token per line, whole-line comments # и пустые строки. Это не AFL dictionary parser. Empty tokens запрещены, duplicates сортируются/usort; ограничения количества/суммарных bytes проверяются до dedup. Tokens и dictionary_id фиксируются на campaign.

No-change primitives пропускаются; havoc stack, вернувшийся к исходному Primary, тоже пропускается и может повторить попытку. Но одинаковые binaries от разных stages/parents не фильтруются перед execution. Corpus дедуплицирует только retained bytes; equivalent coverage executions остаются полезными для correctness, но расходуют бюджет.

### Donors

random_operation(splice,...) получает Entries непосредственно от efz_corpus:mutation_entries(). Donors — lists:usort всех input binaries, отличных от Primary. Выбор не ограничен initial seeds. В provenance сохраняется hash donor и сам donor binary; операция проверяет соответствие hash. Splice может дать пустой output; identical donor и no-change output обрабатываются как skip.

### Преждевременное exhaustion — воспроизведённый дефект

Условие next/2:

~~~erlang
Idle >= maps:get(max_idle_visits,C) orelse complete(State,Entries)
~~~

Обе причины возвращают одинаковый done mutation_exhausted. С 256 уникальными однобайтными seeds, stages=[dictionary_overwrite,bitflip] и dictionary=[<<"AB">>] первый lane не имеет fitting overwrite ни для одного seed. После 256 visits campaign останавливается **до первого bitflip**, хотя существует 5120 bitflip candidates только для исходных seeds.

Реальный запуск дал calibrations=256, executions=0, generated_candidates=0, infrastructure_failures=0, status={mutation_exhausted,mutation_exhausted}. [edge-cases.log](audit-2026-09-12/edge-cases.log), [reproducer](audit-2026-09-12/edge-cases.escript), mutation_plan строки 51–77.

Документация mutations.md предупреждает, что idle cutoff не доказывает математическое исчерпание всех мутаций. Поэтому это не скрытая отсутствующая реализация stage, но практический дефект scheduling policy: нормальная конфигурация может не выполнить ни одного доступного mutation stage. Причины stop нужно различать, а progress учитывать на полном обходе релевантных lanes.

### Recipe determinism

Seed + Recipe → exact mutated Input **работает** для realized staged candidate. Recipe сама содержит Primary bytes, primary hash, parent queue ID, stage, concrete operations, limit values, output size/hash, config/dictionary IDs, target_builds, версии schema/engine/operation и исходный RNG seed.

Все случайные решения уже превращены в offsets, widths, deltas, literal tokens и donor bytes. regenerate/1 не вызывает random selection, corpus lookup или target. Проверяются hash Primary, limits, валидность operations, размер и hash output. EFZR envelope имеет magic/version, payload length, SHA-256, ограниченный ETF scanner и binary_to_term(...,[safe]); compressed ETF и runtime objects отвергаются.

Это точный replay отдельного candidate, а не restart campaign schedule. Recipe не хранит весь corpus, positions остальных seeds или full PRNG/cursor state на момент остановки. Config hash — provenance, не сериализация полной исходной config. Legacy random можно воспроизводить при фиксированных mutation и selection RNG seeds в той же среде, но individual random recipe path отсутствует.

## 9. Crash/Timeout Handling

### Классификация

| Событие target | Outcome | Что делает worker |
|---|---|---|
| Нормальный return любого term | {ok,Term} | Может merge coverage и retain input |
| error(Reason) | {crash,error,Reason,Stack} | Сохраняет exact input/metadata, продолжает |
| throw(Reason) | {crash,throw,Reason,Stack} | То же |
| exit(Reason), включая normal/kill | {exit,Reason} | Сохраняет, считает target failure; stack отсутствует |
| Непойманный linked exit / external kill | {exit,Reason} из DOWN | Сохраняет; источник завершения не отличён от caught exit |
| function_clause/case_clause/badmatch/badarg/badarith/undef | Error class → crash с соответствующим Reason | Специального whitelist исключений нет |
| system_limit как Erlang error | Error class → crash | Реальное исчерпание общей VM памяти может завершить всю VM; не изолировано |
| Deadline | {timeout,TimeoutMs} | Сохраняет input/partial observed coverage; timeouts++, global не меняется |
| Tagged efz_infrastructure error / invalid coverage | {infrastructure,...} или coverage failure | Останавливает campaign; не считается target bug |
| Ошибка пользовательского mutator/nonbinary output | infrastructure failure до execution | Не сохраняет как target crash |

См. executor строки 32–39, 62–85; worker строки 58–107. [Exception diagnostics](audit-2026-09-12/exception_classes.txt) проверяют catch-классификацию явно поднятых error reasons; это не опыт реального resource exhaustion для system_limit. Естественные pattern/guard/try semantics отдельно проверены fixture tests.

Deadline ждёт не только target_result, но и root DOWN. Если root уже послал результат, но ещё не завершился, оставшийся timeout действует. Если timeout ветвь победила, результат остаётся timeout даже при racing message. kill_and_drain создаёт свежий monitor и ждёт фактического DOWN, затем удаляет исходный monitor с flush. Это корректно отделяет поздние сообщения разных cases.

Однако deadline не является верхней границей полного wall time run/4 при заблокированном native коде; у cleanup receives нет независимого внешнего watchdog. Произвольные child processes не охватываются.

### Fingerprint, dedup и файлы

[efz_crash:save/4](../src/efz_crash.erl), строки 6–25:

~~~text
crash ID = SHA256(term_to_binary({Class,Reason,first_3_stack_frames}))
exit ID  = fingerprint(exit,Reason,[])
timeout ID = fingerprint(timeout,deadline,[])

base = crash_dir / hex(crash ID) + "-" + hex(SHA256(Input))
base.input   = exact input bytes
base.term    = ETF #{result=>Result, metadata=>Metadata}
base.recipe  = EFZR, только если metadata содержит staged mutation
~~~

Crash-only coverage сохраняется в result. new_probes=[] в crash metadata отражает policy, а не отсутствие coverage. Для initial calibration crash recipe обычно отсутствует: мутации ещё не было.

Dedup уровни различны: все encounters увеличивают crashes/timeouts; unique_crashes определяется signature set в worker. save вызывается **до** проверки signature set, поэтому разные inputs с одной signature получают разные файлы, а report.crashes содержит только первый record каждой signature. Повтор того же input/signature перезаписывает те же paths. Timeouts разных inputs имеют один signature, а их inputs сохраняются раздельно.

Signature не нормализует file paths, lines, reason terms или arguments в stack frames. Reason с PID/ref либо data-dependent reason может раздробить один bug на множество signatures. Перенос source directory меняет stack path и может менять crash ID при том же логическом сбое. Build identity не является отдельной частью signature.

### Ошибки хранения и воспроизводимость

Запись .input, затем .term, затем .recipe последовательная, без temporary+rename/transaction. Падение между операциями оставляет частичный набор. Ошибки filelib:ensure_dir/file:write_file/recipe:save обрабатываются через ok=..., то есть роняют worker.

Диагностика crash_dir=/dev/null/efz-audit дала worker_down с {{badmatch,{error,enotdir}},...efz_crash:save/4 line 17...}. Итоговый infrastructure_failures остался 0; raw triggering input не попал в crash artifact, а аварийный report содержит только status/stats/corpus. [Лог](audit-2026-09-12/edge-cases.log).

Raw saved input можно выполнить через recipe:execute_file/5 с явно выбранными target, artifacts, expected builds. CLI scripts/replay.escript регенерирует bytes и target не запускает. Fresh-VM replay фактического audit CRASH и штатного staged exception прошёл.

Гарантия exact input не означает гарантии того же crash на stateful target. Replay проверяет selected artifact builds, но не fingerprint отдельного неинструментированного harness, его environment/dependencies и external state. Непрерывный replay всей campaign не реализован.

### Fault isolation и concurrency

При abrupt kill **caller/worker** coordinator обычно получает DOWN и выполняет cleanup root/ETS — это покрывают phase2/backend tests. Тест, названный «owner death cleans target and table», убивает caller, а не ETS-owning coordinator; эти сценарии нельзя смешивать.

При kill **самого coordinator** его after не исполняется. В audit run/4 вернул {infrastructure,{coordinator_down,killed}}, но target ещё был жив; диагностический script остановил его сам. [Evidence](audit-2026-09-12/coordinator_kill.txt).

Несколько workers сейчас невозможны: config требует workers=1, child spec один, services имеют singleton names. Поэтому race A/B «оба увидели новый probe, оба retain» внутри поддержанной campaign отсутствует. Compare/merge и последующая вставка последовательны в одном worker; corpus add и integer ID allocation serial gen_server operations. Crash ID — hash, отдельного allocator нет.

Это не доказательство готовности к workers>1. Каждый worker держал бы собственный GlobalCoverage, compare/merge не является общей транзакцией с corpus, crash writes не синхронизированы. Prepared plan и per-execution contexts способны поддерживать concurrent reads/раздельные executions, что тестируется, но общий campaign scheduling/feedback concurrency не реализован.

## 10. Component Integration Matrix

«Working» относится к конкретной связи. Наличие двух endpoints без runtime call не считается интеграцией.

| Producer | Output | Consumer | Connection | Working | Evidence |
|---|---|---|---|---|---|
| CLI / caller | Config map | efz_config | Escript → efz:start → fuzzer:start_link → config:prepare | PARTIAL: примеры/API да, общего CLI нет | efz.erl:3–7; fuzzer:6–10; examples/* |
| Config | Target atom, artifacts | Harness loader / executor | preflight + ensure_loaded + run/1 export validation | YES в фиксированном contract | config:35–48 |
| Seed file | Binary | Initial corpus | file:read_file у caller → seeds | PARTIAL: внешний glue, builtin importer нет | audit run.escript:e2e/2; corpus:init/1 |
| Corpus | Full entry / id,input entries | Mutator | select/0 random; mutation_entries/0 staged | YES | worker:33–49 |
| Mutator | Binary + staged provenance | Worker | Mu:mutate/2 / mutation_plan:next/2 | YES | worker:35–52; EUnit phase3 |
| Worker | Binary, module, timeout, options | Executor | efz_executor:run/4 synchronous call | YES | worker:58–60 |
| Executor / worker | Exact binary | Harness | Fresh monitored root → M:run(Input) | YES | executor:31–40; 41 exact deliveries |
| Harness | Binary / target-specific arguments | Target | Обычный синхронный Erlang call | YES для работающего harness; связь не проверяется config | audit_harness:run/1; Cowboy adapter |
| Target execution | Probe identity | Coverage | Generated efz_cov_rt:hit/1 → attached ETS | YES, root scope | PT:probe/4; cov_rt:hit/1 |
| Spawned child execution | Probe event | Parent input coverage | Context автоматически не наследуется | NO | child/linked_child diagnostics |
| Coverage | Exact snapshot + status/builds | Feedback | executor result → evaluate/3 | YES | worker:60–65; differential tests |
| Feedback | new_coverage + delta | Corpus | worker retain → corpus:add | YES, RAM | worker:87–91; e2e A/AB/ABC |
| Corpus | Newly inserted entry | Scheduler | Current entries доступны select/next rounds | YES, до idle cutoff / stop | corpus:12–14; plan:63–76; ancestry evidence |
| Scheduler | Parent + lane/index/donor set | Mutator | plan visit/attempts либо random select | PARTIAL: работает, premature idle exhaustion | edge-cases.log |
| Accumulated corpus | Donor binary/hash | Splice | entries → usort donors excluding Primary | YES | mutation_plan:152–157 |
| Interesting successful input | Binary/meta/recipe | Filesystem corpus | Отсутствует | NO | corpus:13 только state append |
| Filesystem corpus | Seeds/queue/state | Restart | Отсутствует | NO | corpus:init/1; restart size=1 |
| Exception/timeout | Outcome, stack, input | Crash storage | worker:record_failure → crash:save | YES при рабочем storage | crash files/replay; storage failure отдельный дефект |
| Recipe | Primary + concrete operations | Replay | recipe:regenerate → mutation:apply_operations | YES | 40/40 audit recipes; recipe tests |
| Raw crash + compatible artifacts | Binary/build set | Execution replay | recipe:execute_file → executor:run/4 | YES в fixed-build scope | fresh-replay.log |
| Worker report | Map | API caller | campaign_done → gen_server:reply await | YES | fuzzer:26–39 |

Матрица показывает единую работающую систему с недостающим durable lifecycle и ограниченной изоляцией. Отдельного разрыва mutator → executor → coverage → active corpus в поддержанном режиме не найдено.

## 11. End-to-End Validation Results

### Выполненные команды

Все команды запускаются из efz/. Штатные checks запускались на текущем dirty source tree; production-код не изменялся.

| Команда | Результат текущего запуска | Доказательство |
|---|---|---|
| erl -noshell с system_info; rebar3 version | OTP 27, ERTS 15.0; Rebar3 3.25.0 | Вывод диагностики среды |
| rebar3 compile | PASS | Приложение собрано, exit 0 |
| rebar3 eunit | PASS: 62 tests | [eunit.log](audit-2026-09-12/eunit.log) |
| rebar3 ct | PASS: 3 tests | [ct.log](audit-2026-09-12/ct.log) |
| rebar3 xref | PASS, exit 0 | [xref.log](audit-2026-09-12/xref.log) |
| rebar3 dialyzer | PASS, exit 0; 26 files analyzed | [dialyzer.log](audit-2026-09-12/dialyzer.log) |
| escript examples/automatic/run.escript | PASS: completed, 500 executions, 4 discoveries, 2 crashes, 1 unique, 0 infra/timeouts | [Архивированный summary и parent links](audit-2026-09-12/random-example-summary.txt); _build/example-report.term |
| escript examples/staged/run.escript | PASS: completed, 200 executions, 5 discoveries, 7 crashes, 1 unique; actual replay | [staged-example.log](audit-2026-09-12/staged-example.log) |
| escript /tmp/efz-audit-20260912/run.escript /tmp/efz-audit-20260912 | PASS diagnostic assertions; они включают подтверждение существующих дефектов | e2e.txt и отдельные *.txt рядом |
| escript /tmp/efz-audit-20260912/fresh-replay.escript /tmp/efz-audit-20260912 | PASS, fresh VM, exact CRASH, один automatic probe | [fresh-replay.log](audit-2026-09-12/fresh-replay.log) |
| escript /tmp/efz-audit-20260912/edge-cases.escript /tmp/efz-audit-20260912 | Дефекты premature exhaustion, ignored config и storage failure воспроизведены; diagnostic exit 0 | [edge-cases.log](audit-2026-09-12/edge-cases.log) |
| escript examples/cowboy/run.escript ../cowboy check | BLOCKED prerequisite, exit 1; 14 target checks НЕ выполнялись | [cowboy-check.log](audit-2026-09-12/cowboy-check.log) |

Точная ошибка Cowboy launcher:

~~~text
Missing build artifact: /home/anonymous_usr/erl:fuzz/efz/../cowboy/ebin/cowboy_req.beam
Run make in COWBOY_DIR first.
~~~

Внешняя сборка Cowboy с загрузкой dependencies в этом аудите не выполнялась. Она не нужна для доказательства собственного EFZ loop: реальный ordinary audit target был скомпилирован, инструментирован и исполнен через отдельный harness. Исторические 14 Cowboy checks и performance numbers из docs не выдаются за результаты текущего запуска.

### Проверка каждого шага requested experiment

| Шаг | Статус | Наблюдение |
|---|---|---|
| 1. EFZ запускается | PASS | efz:start/1 принял audit_harness и automatic artifacts |
| 2. Initial corpus загружается | PASS через существующий API | Caller прочитал seed.input; corpus id=1, input=<<>> |
| 3. Mutator изменяет seed | PASS | Штатный dictionary_insert; custom test mutator не использовался |
| 4. Input достигает harness | PASS | Observer получил 41 delivered event; полное побайтовое равенство seed + 40 regenerated candidates |
| 5. Harness вызывает target | PASS | audit_harness:run/1 → ordinary audit_target:parse/1 |
| 6. Coverage меняется | PASS | Разные function_clause probes для unknown/A/AB/ABC/CRASH |
| 7. New coverage определяется | PASS | Три successful discoveries |
| 8. Input добавляется в corpus | PASS в RAM; disk часть отсутствует | IDs 2,3,4 с new_coverage metadata; core не пишет successful corpus files |
| 9. Новый input выбирается как seed | PASS, прямое доказательство | AB.parent=2 (A); ABC.parent=3 (AB), подтверждено recipes |
| 10. Crash сохраняется | PASS | Exact five-byte CRASH, .term и .recipe |
| 11. Crash replay | PASS | regenerate + execute_file; отдельный fresh-VM execute получил error(test_crash) |
| 12. Corpus после restart | FAIL требуемой persistence-функции | Новый campaign сохранил только initial seed: size=1 |

На отсутствующем disk persistence path не использовался mock saver или ручное добавление discovery в очередь. Loop внутри campaign проверен отдельно, потому что его существование не зависит от долговременного хранения. Запись итогового аудиторского report не считается реализацией corpus persistence.

Завершение custom campaign — {mutation_exhausted,mutation_exhausted}, executions=40: в **этом** эксперименте реально исчерпаны все dictionary_insert candidates для четырёх entries (4+8+12+16). Это нормальное завершение, в отличие от separate edge case, где тот же status выдан при наличии неисполненных bitflip candidates.

### Тесты по компонентам

| Component | Existing tests | Что доказано / чего не хватает |
|---|---|---|
| Legacy mutator | efz_mutator_tests | Binary output/empty seed; очень поверхностные проверки |
| Mutation primitives | efz_mutation_tests:operators, limits, bit_model, block_model, boundaries | Concrete vectors, independent models, endian/overflow/size bounds |
| Staged plan | enumeration, fairness, finite, random_state, noop_stack, growing_corpus, duplicate_donors | Lazy cursors, deterministic order, PRNG independence, вручную растущий entries list |
| Recipe replay | efz_recipe_tests, phase3 fresh_replay/replay_boundaries | Operations roundtrip, invalid data, fresh VM, actual crash |
| Corpus | Phase2/phase3 campaigns, smoke, backend variants | Discovery insertion и reports; отдельного corpus unit suite/persistence test нет |
| Coverage compiler / semantics | efz_phase2_tests | Clause kinds, source mapping, same-line distinct probes, strict AST, plain/instrumented outcomes, builds |
| Coverage runtime | efz_backend_tests, phase2 lifecycle, CT | ETS variants, prepared/reference, simultaneous contexts, target/caller kill, timeout |
| Worker / mutator errors | phase3:mutator_failure, exhaustion; smoke | Infrastructure classification, budget/skip accounting |
| Harness | example adapters + campaigns; efz_config target validation | Реальный run/1; generic CLI/source loader absent |
| Timeout | executor_tests, phase2, backend, CT | Root DOWN, coverage survives, table cleanup; tree cleanup отсутствует |
| Crashes | Phase2 campaign; phase3 campaign/replay; CT | Raw storage, exceptions, continuation, crash-only coverage policy |
| Full loop | Phase3 real staged campaign; phase2/CT scripted campaign | Реальный loop есть, но explicit «discovered entry later became mutation parent» assertion в штатных EUnit/CT не найден |

Ключевое различие: phase2/CT используют efz_scripted_mutator, который игнорирует выбранный parent и берёт predetermined candidate по iteration. Такие тесты подтверждают feedback/insertion, но не mutation ancestry. Phase3 использует настоящий planner и проверяет discovery/recipe/replay; growing_corpus_test добавляет entries вручную без target/feedback. **Нового самостоятельного теста, одновременно утверждающего discovery и последующее использование именно этого entry, в штатном suite нет.** Аудиторский reproducer теперь содержит такую проверку, но не включён в rebar3 eunit/ct.

### Воспроизведение audit diagnostics

В docs/audit-2026-09-12 сохранены исходники диагностических targets/scripts. Они не входят в src_dirs, не изменяют EFZ и не являются новой feature. run.escript специально проверяет также существующие ограничения и сам убирает свои leaked test processes.

~~~sh
rebar3 compile
EFZ_AUDIT_DIR=$(mktemp -d /tmp/efz-full-audit.XXXXXX)
cp docs/audit-2026-09-12/audit_*.erl "$EFZ_AUDIT_DIR/"
cp docs/audit-2026-09-12/*.escript "$EFZ_AUDIT_DIR/"
escript "$EFZ_AUDIT_DIR/run.escript" "$EFZ_AUDIT_DIR"
escript "$EFZ_AUDIT_DIR/fresh-replay.escript" "$EFZ_AUDIT_DIR"
escript "$EFZ_AUDIT_DIR/edge-cases.escript" "$EFZ_AUDIT_DIR"
~~~

Каждый escript использует отдельную VM. После исправления выявленных дефектов негативные audit assertions нужно обновить; текущие diagnostic PASS не являются утверждением «багов нет».

## 12. Dead Code / Parallel Implementations

| Реализации одной концепции | Связь с runtime | Решение после аудита |
|---|---|---|
| efz_mutator_random / efz_mutation_plan + efz_mutation | Обе реально используются: default random и opt-in staged | KEEP обе сейчас; MIGRATE пользовательский рекомендуемый путь к проверенному staged после P0; не удалять compatibility внезапно |
| efz_executor:run/3 / run/4 | run/3 — wrapper над run/4 с manual coverage, не второй runner | KEEP; документировать потерю result metadata в wrapper |
| Manual efz_cov:hit / automatic PT hooks | Общий runtime/ETS; manual identity namespace иной | KEEP как explicit compatibility; DEPRECATE использование manual для новых automatic campaigns |
| ETS insert / ets_member | Backend switch в том же cov_rt/context/executor | KEEP; differential tests уже есть |
| Per-execution validation / prepared validation | Одинаковый whitelist contract; default prepared | KEEP reference path для differential correctness |
| efz_cov:interesting/2 / efz_feedback:evaluate/3 | Первый helper не вызывается runtime; authoritative decision во втором | DEPRECATE unused helper; DELETE только после проверки external callers |
| efz_cov:reset_local/0, snapshot/0 | Legacy standalone helpers; не используются нынешними campaigns/tests | DEPRECATE. reset_local не очищает существующий context: повторный вызов raises context_already_attached |
| efz_stats:handle_cast({inc,...}) / публичный inc через call | Cast handler есть, публичный API использует synchronous call | DELETE либо документировать после отдельной проверки потребителей; не влияет на нынешний loop |
| efz_scripted_mutator / bench:efz_perf_replay / production mutators | Scripted и prerecorded replay только tests/bench | KEEP для измерений и точных fixtures; не представлять их результаты как evidence реального mutation search |
| bench/efz_perf*, reporting/profile scripts | Явно загружаются escripts, не OTP application services | KEEP, отдельно от core |
| Docs calibration/stability collector proposal | Соответствующих production modules нет | KEEP как design document; не считать implemented component |
| efz.worktrees/agents-condemned-silverfish | Та же snapshot-копия файлов, не другой runtime | KEEP по решению владельца; не удалять в рамках аудита |

Несколько corpus implementations, скрытый старый worker pool, второй coverage collector или alternative orchestration language не обнаружены. Поиск UNUSED ограничен текущим repository; export означает, что внешние callers теоретически возможны.

## 13. Bugs and Architectural Gaps

### Три главных architectural gaps

**G1. Неполный lifecycle usable campaign.** Core API принимает bytes и хранит successful progress в RAM; общий пользовательский путь target/config + seed directory → durable corpus → restart не реализован. Runtime retain→reuse при этом уже работает. Связанные места: efz.erl, efz_config.erl, efz_corpus.erl, example launchers.

**G2. Неполный контракт execution/coverage integrity.** Root isolation корректна в обычном пути, но async children, coordinator loss, shared state и disconnected/replaced instrumentation не дают надёжной атрибуции к input. Особенно важно для Erlang/OTP, где полезная работа часто выполняется другими processes. Связанные места: executor, cov_rt, cov_manifest, instrument, harness contract.

**G3. Scheduler progress и regression proof.** Staged engine интегрирован и replayable, но global idle cutoff способен остановить campaign до полезных lanes. Штатные tests не утверждают ancestry discovered seed → next mutation и пропускают этот дефект. Связанные места: mutation_plan:next/visit, worker staged path, phase3/mutation tests.

### Конкретные findings

| ID / priority | Finding и последствие | Evidence / достоверность |
|---|---|---|
| F01 / P0 | Successful corpus не переживает restart; основной результат search теряется без внешнего report/export | corpus:9–14; runtime restart size 4→1 |
| F02 / P0 | Global idle cutoff останавливает доступные stages; 256 valid seeds дают 0 mutations | mutation_plan:51–77; реальный edge-cases campaign |
| F03 / P1 | Kill coordinator оставляет root живым при уже возвращённом infrastructure result | executor:9–23,31–60; coordinator_kill.txt |
| F04 / P1 | Child coverage и cleanup отсутствуют; child после timeout жив | executor:31–85; child_timeout.txt, linked_child.txt |
| F05 / P1 | Shared VM state меняет coverage повторного identical input | Нет reset в executor; cross_case_state.txt |
| F06 / P1 | Валидные, но не вызываемые artifacts дают completed/empty без диагностики disconnected target | config:35–48; manifest validator; disconnected_artifacts.txt |
| F07 / P1 | Hot replacement обычным module не invalidates prepared builds; отдельный harness не pinned | instrument:115–127; manifest:72–85; recipe:97–108; hot_reload.txt |
| F08 / P1 | Caught malformed context может превратиться в успешный пустой coverage | cov_rt:26–27; caught_malformed_context.txt |
| F09 / P1 | Storage error роняет worker; atomic artifact group отсутствует; trigger может не сохраниться | crash:17–23; edge-cases enotdir |
| F10 / P1 | Верхнеуровневые function/arity/max_input_bytes/corpus_dir принимаются, но игнорируются | config:7–15,29–33; edge-cases IGNORED_CONFIG |
| F11 / P1 | Random input size не ограничен общим contract; saved input >1MiB не пройдёт execute_file replay API | config:29–33, worker:37 vs recipe:87,113–114; code-only |
| F12 / P2 | Worker_down report содержит infra counter=0; coordinator_down может маскироваться build mismatch | fuzzer:34–39; feedback:5–7,22; enotdir evidence / code |
| F13 / P2 | Dedup initial seeds отсутствует; duplicate IDs делят staged content cursor | corpus:9–14; plan:68; duplicate_initial_seeds.txt |
| F14 / P2 | Failure decisions растут на каждом повторе, даже при одной unique crash signature; default random budget infinity | worker:75–79,94–105; config defaults; code-only |
| F15 / P2 | Signature включает нестабильные stack paths/reason terms; exact same bug может иметь разные IDs | crash:fingerprint/3; code-only |
| F16 / P1 test gap | Нет штатного direct ancestry E2E assertion, persistence/restart corpus test, tree cleanup/owner-kill regression | Поиск и разбор всех test modules; новый audit reproducer |

Не все ограничения выше — ошибки относительно документации: root scope, fixed build, ручной launcher и bounded idle policy описаны. Но это реальные ограничения относительно запрошенного цельного fuzzing pipeline. Источником вывода является call path и текущий запуск.

Репозиторий не содержит CI execution evidence для текущего дерева; успешные локальные 62+3 checks не означают успешную remote CI или пригодность произвольного OTP target.

## 14. Maturity Assessment

Шкала: 0 — отсутствует; 1 — минимальный фрагмент; 2 — частично работает; 3 — рабочий MVP с существенными ограничениями; 4 — хорошо работающая и проверенная подсистема в заявленном scope; 5 — полный требуемый contract с regression coverage и устойчивым lifecycle. Оценки не являются benchmark.

| Component | Score 0–5 | Причина |
|---|---:|---|
| Harness API | 3 | Реальный run/1 behavior, validation и adapters; нет generic launcher/source loader/reset contract, selection только module |
| Input delivery | 4 | Exact binaries подтверждены 41 delivery; uniform size/replay bounds и seed-file ingestion отсутствуют |
| Execution isolation | 1 | Только fresh root/coordinator; children/shared state/VM failures не изолированы, owner kill оставляет root |
| Coverage collection | 4 | Exact per-execution source probes, manifest mapping, backend/lifecycle tests; root-only и ограниченное AST |
| Coverage feedback | 4 | Exact set difference/union и failure policy работают; нет stability validation и disconnected-code detection |
| Corpus management | 2 | In-memory append/dedup/select/metadata; нет persistence, restart, initial dedup, lifecycle metadata |
| Corpus feedback loop | 4 | Прямо доказано A→AB→ABC; оценка для active RAM loop, не durable workflow; scheduler cutoff ограничивает другие campaigns |
| Mutation engine | 3 | Богатые primitives/stages/havoc/splice/recipes и model tests; существенный scheduler exhaustion defect |
| Crash handling | 3 | Error/throw/exit/timeout storage/continuation работают; запись неатомарна, failure paths слабее, VM crash не охвачен |
| Replayability | 4 | Exact realized staged mutation и fresh-VM crash replay; random recipes/campaign resume/harness pinning отсутствуют |
| Concurrency safety | 3 | Один-worker путь serial и scoped ETS тестированы; several workers отвергаются, tree lifecycle не решён |
| End-to-end integration | 3 | Core loop реально замкнут; packaging, persistence и broad OTP isolation ещё не закончены |

Текущая зрелость — интегрированный исследовательский MVP для bounded synchronous targets. Называть EFZ только набором несвязанных prototypes неверно; объявлять его готовым универсальным OTP application fuzzer также преждевременно.

## 15. Recommended Development Direction

**Следующая фаза: надёжная, сохраняемая и проверяемая кампания с одним worker на уже существующем engine.**

P0 должен закрепить рабочий feedback loop и устранить ситуации, когда корректная config лишает его возможности работать: ancestry E2E, premature exhaustion, реальный импорт seeds, durable retention и повторное использование после restart. Одновременно нужен минимальный универсальный launcher поверх существующего run/1, а не новый harness framework.

P1 — корректность границ: единые byte bounds, atomic/error-aware artifact storage, root/descendant cleanup, нарушение instrumentation contract, зафиксированные target/harness builds и воспроизводимый replay. Для первой поддержанной модели следует явно определить synchronous binary harness; переход к arbitrary OTP applications не должен происходить неявно через spawn без coverage context.

Repeated stability calibration может быть полезной следующей correctness функцией, но большой новый collector не требуется для завершения обнаруженного loop. Сначала должны быть достоверными source identity, per-input scope и cleanup. Существующий документ calibration-readiness.md полезен как требования, а не как признак уже реализованного stability feature.

P2 performance работы — indexing corpus, стоимость mutation_entries/0, binary conversions, ETS hook tuning — после correctness gate. P3 advanced schedules и P4 distributed/UI не входят в предлагаемый этап.

## 16. Prioritized Implementation Plan

Ниже только предложение следующей фазы. В этом аудите production implementation не менялась.

| Task | Problem solved | Files/modules affected | Expected behavior | Test/evidence | Priority |
|---|---|---|---|---|---|
| T1. Добавить штатный lineage end-to-end gate | В тестах не доказано повторное использование найденного input | test/efz_phase3_tests.erl или новый integration suite; простой fixture/harness | Real staged mutator получает A, сохраняет его, затем именно A порождает AB; AB может породить ABC; fixed bytes до harness и actual coverage | Assertion parent ID + primary bytes/hash + recipe output; никакого scripted mutator; отдельная fresh replay проверка | P0 |
| T2. Исправить критерий отсутствия progress | max_idle_visits останавливает campaign до полезного lane | src/efz_mutation_plan.erl; test/efz_mutation_tests.erl; integration tests | Недоступный stage не предотвращает visit доступного; true exhaustion и idle-budget stop имеют разные reasons; finite empty search остаётся bounded | 256-seed reproducer обязан выполнить bitflip; cases с empty corpus/dictionary/no donor и реально исчерпанным sweep | P0 |
| T3. Минимальный общий launcher + строгая campaign schema | Пользователь не может штатно задать harness source/code path, seeds directory и outdir; неизвестные ключи молча игнорируются | Новый scripts/fuzz.escript или efz_cli; src/efz_config.erl, README, examples | CLI/config выбирают module с run/1, paths/artifacts, seed directory, mutation mode, limits, timeout, output; seed bytes читаются без преобразования; неизвестные ключи reject | Black-box запуск fresh VM с внешним minimal run/1; missing module/export/file, invalid config и no-artifacts cases | P0 |
| T4. Durable corpus retention и restore | Discoveries теряются при stop/restart | src/efz_corpus.erl, src/efz_worker.erl, config; новый scoped corpus-store при необходимости | Content-addressed exact .input + versioned metadata сохраняются до подтверждения durable retain; add в active queue; restart загружает successful discovered inputs без duplicates | Kill/restart после A discovery → A загружен и выбран как parent; corrupt/partial entries обнаруживаются; build policy явна | P0 |
| T5. Единый input/storage failure contract | Random size без bounds; crash write errors теряют context; artifacts частичны | config, worker, crash, recipe, corpus store | Одинаковый max input для seeds/mutations/replay; атомарные отдельные records; errors возвращаются структурированно с triggering input/hash и operation/path; worker report не выдаёт 0 infra как success | Boundary 0/max/max+1; enotdir/read-only/storage failure; exact crash bytes при рабочем storage; interrupted-write recovery | P1 |
| T6. Подтвердить execution cleanup | Coordinator loss/timeout оставляют root/children | executor, target contract; lifecycle tests; при необходимости отдельный runner/guardian | Cleanup ownership переживает coordinator; DOWN root и всех поддержанных descendants подтверждён. Если scope нельзя безопасно очистить, campaign не переиспользует dirty runner; для общего async scope нужна изолированная runner VM с уничтожением при потере контроля | owner kill, root trap_exit, linked/unlinked children, timeout и cancellation; отсутствие живых targets после completion/abort; A→B→A с определённым state policy | P1 |
| T7. Уточнить coverage/harness validity | Пустой feedback скрывает disconnected target; hot reload/PD corruption не видны | config, instrument, cov_manifest, cov_rt, executor; tests/docs | Фиксируется harness identity и selected builds; нарушение contract detected; campaign с полностью отсутствующим feedback явно диагностируется. Legitimate empty case отличается от missing/broken snapshot; metadata scope/termination/cleanup явны | Unused artifact, ordinary hot replacement, erased/malformed context, actual valid empty case; fail closed для invalid instrumentation | P1 |
| T8. Завершить crash/replay/report contract | Динамические signatures, unbounded repeated failure decisions, разные failure origins | crash, worker, fuzzer, stats, recipe, scripts/replay.escript | Exact raw input остаётся authoritative; signature отдельно от occurrence/provenance; repeated failures bounded/aggregated; primary infrastructure reason и counters сохраняются; explicit CLI execution replay проверяет target+harness identities | Повтор одной signature с разными inputs; replay той же сборки и reject mismatch; worker_down counter/reason; длительный bounded-report test | P1 |
| T9. Подключить воспроизводимый release gate | Локальные проверки не запускаются автоматически, gaps легко вернутся | CI config по принятой площадке, rebar.config при необходимости, docs | compile/EUnit/CT/xref/Dialyzer + T1/T2/storage/restart/lifecycle gate выполняются на заявленной OTP версии; вспомогательный Cowboy suite отдельно | CI logs и artifacts с source/build identity, exact commands, ancestry witness и fresh replay result | P1 |

Для T4 минимальное корректное restore — загрузка persisted inputs и повторная calibration в новой campaign. Оно не должно называться «точное продолжение прежнего schedule», пока отдельно не сериализованы и не версионированы global coverage, IDs, cursors и RNG. Full checkpoint можно выделить следующим отдельным шагом после доказанного reusable disk corpus.

Для T6 нельзя выполнить acceptance tree cleanup простым утверждением «дочерние процессы вне scope». До реализации общего async runner допустимо явно ограничить поддержанные targets и отклонять нарушение контракта; если следующая версия заявляет сохранение работы в той же VM после async timeout, соответствующий cleanup обязан быть реализован и проверен.

## 17. Acceptance Criteria for the Next Phase

Checklist ниже — release gate следующей версии. Часть пунктов уже выполнена в текущем synchronous in-memory scope, но все должны подтверждаться автоматическими тестами на итоговой реализации.

- [ ] EFZ принимает target/harness через общий CLI/config; поддержанный callback contract явен, module/export и доступность artifacts проверяются.
- [ ] Initial seed-файл читается как binary и появляется в active corpus; duplicates и неправильные paths обрабатываются определённо.
- [ ] Corpus seed действительно передаётся штатному mutation engine.
- [ ] Mutated binary побайтово совпадает с тем, что получил harness.
- [ ] Harness вызывает реальный instrumented target; полностью disconnected feedback диагностируется.
- [ ] Coverage собирается отдельно для конкретного input и имеет validated build/source identity.
- [ ] Coverage одного input не загрязняется другим input; scope и shared-state policy проверены, missing/broken observation не принимается за valid empty.
- [ ] New coverage вычисляется как CurrentCoverage − GlobalCoverage для successful outcomes; global обновляется определённо.
- [ ] Input с новым coverage сохраняется на диск и добавляется в active corpus с parent/content/build metadata.
- [ ] **Этот newly generated, coverage-discovered input затем действительно выбирается и становится родителем следующей mutation; тест проверяет parent ID, exact primary bytes и результат.**
- [ ] Restart загружает сохранённый discovered input; он остаётся доступным как future parent. Restore и exact campaign resume различены.
- [ ] Scheduler не объявляет exhaustion, не посетив ещё доступный productive stage; 256-seed regression выполняет реальные mutations.
- [ ] Crash сохраняет exact triggering input; storage failure имеет явный инфраструктурный результат и не теряет объяснение.
- [ ] Saved crash воспроизводится через replay execution в свежей VM с совместимыми target/harness builds.
- [ ] Mutation recipe детерминированно восстанавливает input без live corpus и RNG; mismatch/corruption отвергаются.
- [ ] Timeout/cancellation/coordinator loss не оставляют живых target processes в поддержанной модели, включая её descendants; недоказанная очистка запрещает reuse runner.
- [ ] Invalid instrumentation, mutation failure, target failure и infrastructure failure различаются в report и counters.
- [ ] End-to-end integration test подтверждает весь цикл, disk retention, restart reuse и fresh crash replay без mock target/mutator/coverage/corpus.

**Критерий завершения фазы:** один воспроизводимый тест проходит seed file → real mutation → real harness/target → per-input coverage → successful discovery → durable + active corpus → mutation от discovered parent; второй запуск использует тот же persisted input. Текущий audit уже доказал внутреннюю часть этой цепочки, поэтому следующий этап должен сохранить её и устранить установленные gaps.
