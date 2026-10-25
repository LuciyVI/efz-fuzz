# Производительность и протокол завершения Phase 2.1

[English](../../phase2.1-performance.md) · **Русский** · [Español](../es/phase2.1-performance.md) · [简体中文](../zh-CN/phase2.1-performance.md) · [Все языки](../README.md)

Локально закрыта 2026-09-09. Default — **prepared validation с original exact
ETS hook**. Membership остаётся opt-in. Preparation улучшает измеренные complete
parser и sparse executions/campaigns; membership помогает repeated-hit workloads,
но удорожает first observations и не даёт надёжного выигрыша в sparse campaigns.
Для получения результатов не менялись probes, timeouts, identities или retention
rules.

## Environment, baseline и provenance

Репозиторий — `efz/` в предоставленном workspace. Применимых `AGENTS.md` или
formatter/linter configuration не найдено. Worktree уже был dirty, большая часть
source Phase 1/2 — untracked. Сравнение с сохранённым snapshot Phase 2
`/tmp/efz-phase21-baseline` выделяет изменения этой phase; один Git status их
не различает. Не выполнялись clean/reset, staging, commit, identity, remote
или push operations.

При входе в Phase 2.1 compilation, 24 EUnit tests, три Common Test cases,
Dialyzer и xref проходили. Прерванная implementation затем прошла 36 EUnit tests
и остальные те же gates. Closeout добавил два focused tests и исправил один
artifact-loading defect; final gate проходит **38 EUnit tests**. Environmental
blockers не было. Historical results Phase 2 остаются в
[phase2-validation.md](phase2-validation.md); это observations, а не test constants.

Unprofiled final throughput и все memory VM записали:

* OTP 27.0, ERTS 15.0; Rebar3 3.25.0; JIT, words 8 bytes.
* Ubuntu 24.04.4 LTS, Linux, `x86_64-pc-linux-gnu`; Intel Core i7-1260P.
* `ERL_FLAGS='+S 4:4'`: четыре schedulers, четыре online, четыре dirty CPU schedulers.
* Fixture compilation через `compile:noenv_file/2`, `debug_info`,
  `warnings_as_errors`; strict instrumentation, явные module allowlists,
  `source_root => "."`, отдельные instrumented directories. Во время throughput
  measurements profiling нет; custom NIF, port-based runner или external engine нет.

Исходный tight-loop benchmark действительно повторили при входе в Phase 2.1:
семь warmed samples по 200,000 iterations дали medians **766 / 2,218 / 33,407 us**
для ordinary / inactive / active. Это отличается от ранее сообщённых
518 / 5,315 / 67,209 us и не воспроизводит независимо эти точные numbers.
Raw samples архивированы; scheduler settings не записаны в benchmark artifact,
поэтому он не объединяется с comparison четырёх schedulers. Исходный example
также завершился с 500 mutations, одной calibration, четырьмя discoveries,
494 rejections и двумя crashes, одним unique.

Авторитетные artifacts полного run:

| Группа | Содержимое и completion evidence | Применимость |
|---|---|---|
| `_build/performance-final/{environment,hooks,executor,campaign}.term` и `.txt`, `summary.txt` | 36 hook, 12 executor, 24 campaign rows; по пять samples. Complete command завершилась exit 0; progress log заканчивается после сохранения всех шести campaign cases. Audit пересчитывает каждую median/min/max и сравнивает canonical campaign objects до compaction. | Текущие hooks, executor, feedback и mutation timing. Historical startup samples заменены ниже. |
| `_build/performance-final/*-candidates.term` | Полные prerecorded loop/parser/sparse candidate sequences | Тот же input order между variants; также включены в durable evidence |
| `_build/performance-memory-{reference,member,prepared,prepared_member}/` | Четыре отдельные VM, каждая сохранила полный environment и memory result; loop command завершилась exit 0 | Original memory observations до closeout preflight fix |
| `_build/performance-final/profile-sparse-prepared.txt` | Полная eprof table и `Total: 6331`; profile command завершилась exit 0 | Только focused diagnostic; preparation/loading вне profile |
| `_build/performance-final/automatic-example.{term,txt}` | Completed report, ненулевые discoveries/crashes, ноль infrastructure failures; command sequence завершилась exit 0 | Прежний working example. Его команда **не** задавала `ERL_FLAGS`; scheduler count не записан и не предполагается равным четырём. |
| `_build/phase21-closeout-startup/` | Пять warmed zero-mutation campaign samples на fixture/variant, exit 0 | Текущие preflight startup/calibration costs |
| `_build/phase21-closeout-memory-*/` | Четыре новые отдельные VM; полные bounded memory checks, exit 0 | Текущие memory observations после preflight fix |
| `_build/phase21-closeout-fixed/` | Final gate logs, обновлённый example, artifact audit | Current source validation; обновлённый example явно использует `+S 4:4` |

При возобновлении работы benchmark process прерванной session не осталось.
Существование или modification time файла не использовались как completion proof.

[Durable evidence](../../performance/phase2.1-samples.term) содержит все raw timing
samples и spread, startup samples, оба набора memory records (включая
`/proc/self/status`), compact environment data, полные build/source/input
identities, artifact SHA-256s, profile tables, validation logs,
example/termination results и prerecorded candidates. Runtime references/pids
явно заменены на `runtime_reference_omitted`/`runtime_pid_omitted` в этой
consultable copy. Repeated campaign check objects заменены digests **после exact
comparison**; original full checks остаются в ignored raw campaign files.
Digests — архивная помощь, а не differential test oracle.

Граница provenance указана явно: old harness записывал fixture hashes, compiler
options, build IDs и runtime metadata, но не full source-tree hash в момент
measurement. Closeout archive записывает source hashes ретроспективно,
перекомпилирует все 22 current application BEAMs с recorded compiler options
и сравнивает code MD5 и abstract forms. Он также перестраивает три fixture
identities и проверяет saved BEAM/sidecar terms и source hashes во всех artifact
groups. Prior successful execution records и unchanged hot-path source
подтверждают continuity; это не обещание изначально signed Git revision или
одновременного whole-tree snapshot.

Audit обнаружил preflight defect Phase 2: эквивалентные ETF maps могут
сериализоваться в другом key order в другой VM. Byte comparison отклонял valid
saved sidecars. Теперь `efz_instrument` безопасно декодирует sidecar и сравнивает
exact terms с validated embedded manifest. Invalid encodings и changed manifests
по-прежнему не проходят. Это покрывают deterministic reversed-key encoding test
и fresh-VM preflight regression. Изменение работает при artifact loading,
а не в probe, execution или mutation interval. Обновлены лишь
startup/calibration, memory observations и example; throughput/profile rerun
не требовался.

## Variants и публичные defaults

Names определены `backend/1`, `prepared/1` и campaign options в `bench/efz_perf.erl`:

| Variant | Стратегия validation | Coverage storage/hook |
|---|---|---|
| `reference` | `per_execution`: перестроить allowed exact set из manifests | `ets`: original insert на каждый hit |
| `member` | `per_execution` | `ets_member`: membership lookup, insert только при отсутствии |
| `prepared` | `prepared`: один protected allowlist, compact executor options | Original `ets` |
| `prepared_member` | `prepared` | `ets_member` |

`efz_config:defaults/0`, следовательно `efz:start/1` и ordinary automatic example,
выбирают `prepared` + `ets`. Existing campaign configurations без этих options
получают новый validation default с unchanged feedback policy. Для optional
hook добавьте:

```erlang
coverage_backend => ets_member
```

Для complete reference configuration используйте:

```erlang
coverage_backend => ets, coverage_validation => per_execution
```

Default `efz_cov:open/0` остаётся original ETS. Low-level `run/4` лишь с
`manifests` всё ещё проверяет per execution; shared plan не создаётся неявно.
`run/3` сохраняет manual compatibility API. Оба hook backends сохраняют schema 1
contexts и exact observations `{Module, BuildId, ProbeId}`.

Оценены две focused alternatives: membership до insertion и подготовка
validation/исключение копирования full worker state в каждый coordinator.
Не введены atomics backend, compact/hash IDs, process-local seen cache,
asynchronous publication или final target flush. Membership всё ещё проверяет
external table на каждом hit; deleted table не скрывается cache.

## Граница prepared validation

Public campaign preflight проверяет selected artifacts, embedded manifest schema
и instrumentation version, sidecar equivalence, descriptor build ID и loaded
module identity. Сам target adapter не обязан быть instrumented; явно выбранные
modules — обязаны. Configuration отклоняет invalid backend/validation choices
и multiple workers.

`efz_cov_manifest:prepare(Mode, Manifests)` отдельно проверяет manifest format,
unique probe IDs/structural paths, непустой automatic selection и duplicate
modules. Он создаёт `{efz_cov_plan,1,Table,BuildMap}`. Unnamed **protected** ETS
set содержит каждую exact allowed identity и mode/build marker `'$efz_plan'`.
Сама preparation не загружает artifacts; low-level users сначала должны сделать
preflight. Plan работает с обоими hook backends, поскольку observation formats
совпадают.

Campaign worker владеет plan. Он передаёт только coverage/backend/plan options
каждому coordinator, убирая repeated set construction и full
manifest/worker-state copying. Low-level caller может намеренно разделять plan
с другими callers, пока owner жив: это immutable read capability, а не campaign
ID или execution context. Foreign processes не могут в него писать. Owner
освобождает его после остановки всех users, либо owner termination удаляет его.
Completion сохраняет campaign worker, plan, corpus и report до `efz:stop/0` или
application shutdown. Отдельные campaigns создают отдельные plans.

Каждый execution всё ещё создаёт собственные reference, target process и public
ETS observation set, принадлежащий coordinator. Attach проверяет context
ownership; каждый active hit обращается к table. После target termination
validation проверяет plan marker даже для empty snapshot и тестирует **каждую
observed identity** по prepared allowlist. Feedback также сравнивает pinned
build map. Disposed/mismatched plans и broken active tables становятся
infrastructure results, а не discovered target bugs или valid empty feedback.
Malformed descriptor versions могут давать infrastructure result
`coordinator_down` вместо более точного `invalid_coverage_plan`; ни один не
является success. Valid observations переживают expired plan с error status,
если descriptor shape остаётся valid.

Новый lifetime test покрывает protected foreign writes, shared read use,
repeated use, wrong schema/mode/build descriptors, plan-owner death во время
синхронизированного execution и rejection после disposal с **нулём observations**.
Existing tests покрывают changed builds, invalid manifests, deleted active
observation tables и caught runtime-hook errors.

Selected builds должны оставаться неизменными весь campaign/plan lifetime.
Preflight отклоняет already loaded ordinary/different builds; observation
validation отклоняет unexpected new-build probes. Ни один не доказывает safety
при позднейшем arbitrary code replacement, особенно replacement без hooks.
Hot-code management и reload-safe cache вне supported API contract.

## Методология и workloads

Пять measured samples на case после discarded pilot или полной warmup batch.
Variant order обращается в alternating rounds. Executor pilots выбирают batches
около 180 ms (128–20,000 executions); counts могут различаться и нормализованы
ниже. Campaigns имеют 2,048 mutations на sample плюс одну отдельно timed seed
calibration. Cap делает slow reference практичным: fast campaign batches всё
ещё занимают десятки миллисекунд, не sub-millisecond timing. Machine-specific
thresholds или confidence intervals не заявляются; spread — observed min–max.

| Fixture | Manifest probes | Executor observations | Input/work и проверенный result |
|---|---:|---:|---|
| `efz_bench_fixture` | 6 | 6 | `run(1024) = 2304`; tail-loop microbenchmark использует 20,000,000 iterations и проверяет checksum 45,000,000 |
| `efz_perf_parser` | 20 | 10 | 32 копии `<<0,0,7,1,35,2,2,97,98,3,2>>`; 352 bytes, result `{ok,128,1888}` |
| `efz_perf_sparse` | 2,051 | 2 | `<<0,7>>`, result 22; сгенерировано 2,048 explicit choice clauses плюс fallback и entry probes |

Build IDs, неизменные после closeout:

```text
loop    943bea4cf9695048788654bbe520185c78611ad26733a1066989d28e4b0fd80d
parser  c966463003a8d5244d58710e533634f4003faeece71c7a9d61fdfa2559df2351
sparse  bf27f5190ec9b6744e8d20179a0c9110ae265238ac22fe4d70b2add7645f5534
```

Ordinary и instrumented fixtures загружаются в controlled sequence без active
target calls; values сравниваются. Renamed-module approximation не используется.
Complete-executor samples измеряют `run/4` до coordinator termination и cleanup,
включая context allocation, process/monitor startup, target work, snapshot,
validation и deletion. Outcome/status/canonical probe set каждого execution
сравнивается с reference. Plan setup вне timer и записана отдельно (sparse:
603 us prepared, 431 us prepared-member, single observations; не stable setup
benchmark).

Campaign mutation clocks включают corpus selection, actual mutation, executor,
feedback, retention, stats и crash artifact writes. Они исключают fixture
compilation, calibration и final report construction/printing. API-start и
stop/cleanup timing записаны отдельно. Заданы и mutation RNG `{17,23,41}`, и
corpus selection RNG `{101,109,113}`. Последний — optional new configuration;
default unseeded corpus selection неизменна.

Replay циклически проходит saved candidate lists; это только benchmark, а не
новый production mutator. Real mode использует existing `efz_mutator_random`.
Exact sanitized coverage, corpus inputs, decisions/new probes, crash outcomes
и stats совпадают между всеми четырьмя variants и всеми пятью repetitions
каждого workload/mode. Loop campaigns калибруют все шесть probes и не сохраняют
additional inputs. Parser replay/real сохраняют total corpus inputs 5/10 и
наблюдают successful probes 15/19; sparse replay/real сохраняют inputs 9/538
и наблюдают successful probes 10/540. Поэтому campaigns включают разную
retention/metadata workload, а не только repeated writes.

## A. Стоимость hooks

Repeated observations ниже используют 2,000,000 direct hook calls, настоящие full
identities из sparse manifest на 2,051 probes и pre-published set. Times —
**ms на batch**, median [min–max]; inactive всё равно исполняет тот же calling
loop.

| Различные probes | Неактивно | ETS reference | Membership | Reference/member time ratio |
|---:|---:|---:|---:|---:|
| 1 | 15.208 [14.648–17.336] | 182.385 [179.183–185.007] | 118.594 [114.060–123.957] | 1.54x |
| 8 | 9.673 [8.811–10.222] | 176.121 [174.143–179.749] | 111.413 [110.601–115.619] | 1.58x |
| 64 | 8.670 [8.553–8.829] | 177.991 [176.712–180.876] | 112.828 [112.526–113.132] | 1.58x |
| 1,024 | 8.595 [8.534–8.792] | 189.348 [186.503–194.945] | 125.183 [124.630–128.117] | 1.51x |

Calling-loop/list traversal влияет на times, объясняя изменение inactive cost
с distinct-count batching. Все results 500,000 calls также сохранены. Это
измеряет настоящий path `hit/1`, не приписывая всю cost process-dictionary lookup.

First observations используют fresh preallocated contexts; timing включает
attach и first publications, исключает allocation/snapshot/deletion. Каждый
expected set проверяется затем. Здесь намеренно много live contexts для
изоляции writes; production остаётся одним worker с одним live execution.

| Hook calls | Probes/context | Contexts | ETS ms [range] | Member ms [range] | Добавленное время member |
|---:|---:|---:|---:|---:|---:|
| 131,072 | 64 | 2,048 | 15.168 [14.983–16.831] | 20.565 [20.091–22.281] | 35.6% |
| 524,288 | 64 | 8,192 | 87.746 [87.056–92.194] | 112.473 [110.292–121.294] | 28.2% |
| 131,072 | 1,024 | 128 | 20.230 [19.191–20.427] | 25.031 [24.558–25.196] | 23.7% |
| 524,288 | 1,024 | 512 | 91.261 [90.249–91.978] | 113.625 [111.488–115.044] | 24.5% |

Existing loop fixture на 20,000,000 iterations:

| Режим | Медиана ms [min–max] | Относительно ordinary |
|---|---:|---:|
| Ordinary | 35.087 [32.072–35.191] | 1.00x time |
| Instrumented inactive | 227.358 [220.167–229.080] | 6.48x time |
| Instrumented ETS | 4,046.383 [3,962.962–4,088.383] | 115.32x time |
| Instrumented membership | 2,593.771 [2,503.256–2,614.029] | 73.93x time |

Все шесть probes появляются; всего 40,000,002 hook calls. Membership в 1.56x
быстрее ETS в этом synthetic loop, но существенный instrumentation overhead
остаётся. Preparation в этих hook measurements не участвует. Ни один hook
ratio не выдаётся за campaign throughput.

## B. Полный executor

Times — **us/execution**, median [min–max]. `N` — measured batch size каждого
variant в порядке reference/member/prepared/prepared-member. В каждой row
используются те же fixture input и exact result/probe set.

| Fixture; N | Reference | Member | Prepared (default) | Prepared-member |
|---|---:|---:|---:|---:|
| Loop; 808/1,260/860/1,335 | 230.853 [221.092–235.197] | 149.522 [142.960–157.459] | 221.483 [213.171–231.353] | 142.897 [138.843–144.178] |
| Parser; 4,105/4,974/4,975/6,386 | 50.392 [48.179–50.662] | 40.454 [37.910–41.297] | 37.471 [37.168–39.381] | 27.998 [27.633–29.012] |
| Sparse; 132/129/17,311/20,000 | 1,331.235 [1,241.583–1,623.515] | 1,624.434 [1,409.581–1,770.605] | 7.405 [7.234–7.943] | 7.582 [7.034–7.607] |

Preparation даёт reference/default median ratios 1.04x / 1.34x / 179.76x.
У small loop change overlapping ranges; одно это преимущество слабо. Large
sparse change удаляет работу, пропорциональную manifest на 2,051 probes,
из каждого two-hit execution. Это не general Erlang speedup. Median sparse
reference-path membership **на 22% медленнее**, с широкими overlapping ranges;
с preparation он медленнее на 2.4%, снова недостаточно для точного различия.

## C. Полные campaigns

Каждый sample содержит **2,048 mutations и одну отдельную calibration**.
Значения — mutation **ms/batch**, median [min–max]. Manifest и successful probe
counts заданы в methodology; разные modes нельзя усреднять вместе.

| Fixture / mode | Reference | Member | Prepared (default) | Prepared-member |
|---|---:|---:|---:|---:|
| Loop / replay | 140.439 [130.715–150.496] | 114.871 [104.974–124.499] | 124.164 [121.846–134.971] | 94.616 [87.827–102.950] |
| Loop / real | 157.566 [149.826–177.073] | 120.003 [112.035–142.344] | 139.574 [128.366–141.977] | 106.589 [99.934–111.639] |
| Parser / replay | 162.143 [147.937–163.049] | 138.111 [133.298–174.021] | 111.907 [109.947–115.914] | 99.370 [85.961–111.084] |
| Parser / real | 122.444 [115.189–129.781] | 111.796 [107.400–115.664] | 95.287 [91.475–99.000] | 85.973 [81.385–91.675] |
| Sparse / replay | 2,842.573 [2,738.130–2,892.657] | 2,910.044 [2,882.867–3,023.839] | 33.266 [31.554–33.738] | 34.619 [31.641–40.462] |
| Sparse / real | 3,939.023 [3,409.309–4,382.920] | 3,750.131 [3,152.201–4,191.928] | 49.230 [46.300–78.594] | 47.972 [39.963–75.125] |

| Fixture / mode | Reference mutations/s | Default mutations/s | Default speed ratio |
|---|---:|---:|---:|
| Loop / replay | 14,583 | 16,494 | 1.13x |
| Loop / real | 12,998 | 14,673 | 1.13x |
| Parser / replay | 12,631 | 18,301 | 1.45x |
| Parser / real | 16,726 | 21,493 | 1.29x |
| Sparse / replay | 720 | 61,564 | 85.45x |
| Sparse / real | 520 | 41,601 | 80.01x |

Добавление membership к prepared default улучшает loop campaign medians в
1.31x и parser в 1.13x replay / 1.11x real. Sparse replay медленнее на 4.1%;
sparse real быстрее на 2.6% с overlapping ranges и large outliers. Это
поддерживает opt-in repeated-hit optimization, а не universal backend switch.
Необъяснённого aggregate speedup нет. Reference полезен для differential checks,
включая исходные costs per-execution set construction/copying.

Current observations **startup** получены zero-mutation campaigns после sidecar
fix, одной full warmup и пяти alternating samples. Compilation всех трёх
ordinary/instrumented fixtures заняла 1,174,788 us в той VM (одно cold build
observation); original final-run build занял 575,889 us. Это включает compiler
startup и loading, а не compiler-speed comparison. Median startup до
calibration / calibration / stop time, us:

| Fixture | Reference | Member | Prepared | Prepared-member |
|---|---:|---:|---:|---:|
| Loop | 220 / 148 / 650 | 210 / 132 / 640 | 215 / 125 / 640 | 232 / 115 / 653 |
| Parser | 349 / 178 / 646 | 366 / 162 / 651 | 344 / 156 / 655 | 357 / 139 / 643 |
| Sparse | 19,318 / 3,392 / 1,378 | 20,327 / 4,129 / 1,629 | 22,710 / 156 / 1,765 | 21,215 / 152 / 2,685 |

Эти short startup samples — diagnostic, а не главное throughput comparison.
Sparse startup ranges — 18,864–20,533 / 19,100–22,979 / 20,341–24,678 /
19,610–27,023 us. Все raw samples и ranges startup/calibration/API-start/cleanup
архивированы. `api_start_us` пересекается с worker initialization/calibration;
его нельзя добавлять к `startup_us + calibration_us`. Historical campaign
startup values остаются в archive, но current measurements заменены этим run.

## Память и cleanup

Memory sampling отделён от throughput. Каждый variant работает в fresh VM:
compile/load fixtures, snapshot после GC, optional allocation plan на 2,051 ID,
attach context и 80,000 hits по восьми distinct IDs, snapshot live state,
close context/release plan и GC, затем bounded sparse replay campaign на 5,000
mutations с sampler и остановка всего. Sampler записывает VM/ETS/process peaks
на nominal intervals 2 ms; само чтение memory стоит времени, actual sampling
spacing больше. Это **sampled peaks**, а не absolute peaks или unprofiled
throughput.

Original saved observations (decimal MB для VM totals):

| Вариант | До | С plan | Живой context | После context/plan cleanup | После campaign cleanup | Sampled VM peak / samples |
|---|---:|---:|---:|---:|---:|---:|
| Reference | 57.143 | 56.191 | 61.645 | 56.205 | 54.809 | 81.542 / 2,315 |
| Member | 57.124 | 56.169 | 56.202 | 56.165 | 54.775 | 87.575 / 2,367 |
| Prepared | 59.509 | 58.720 | 64.187 | 58.448 | 57.104 | 77.915 / 34 |
| Prepared-member | 59.335 | 58.680 | 64.137 | 56.810 | 56.963 | 76.673 / 34 |

После closeout preflight fix тот же bounded protocol дал:

| Вариант | До | С plan | Живой context | После context/plan cleanup | После campaign cleanup | Sampled VM peak / samples |
|---|---:|---:|---:|---:|---:|---:|
| Reference | 56.129 | 56.154 | 61.597 | 56.135 | 54.749 | 84.452 / 4,534 |
| Member | 57.339 | 57.356 | 57.389 | 57.387 | 55.924 | 91.795 / 4,429 |
| Prepared | 58.326 | 58.640 | 64.107 | 58.371 | 57.007 | 84.378 / 76 |
| Prepared-member | 56.274 | 56.579 | 62.062 | 54.741 | 54.926 | 79.588 / 71 |

Все refreshed checks также возвращаются к **41 processes, нулю observation tables
и нулю plan tables** после каждого cleanup. Live observation storage вновь
3,656 bytes; allocation plan увеличивает total ETS на 300,072–300,096 bytes.
Refreshed ETS sampled peaks — 517,624 / 517,912 / 820,288 / 818,016 bytes;
process peaks остаются 52. Final ETS totals — 515,976 / 515,872 / 515,968 /
516,264 bytes. Это observations, а не thresholds или требования к другим machines.

Например, refreshed prepared `VmRSS` — 125,952 kB с plan и 125,476 kB после
campaign cleanup; `VmHWM` остаётся на прежнем high-water mark 240,416 kB.
Prepared-member RSS фактически растёт с 133,776 до 137,428 kB, хотя все его
EFZ-owned tables освобождены. Это показывает, почему одни RSS или VM total не
доказывают leak и не опровергают его. Refreshed runs включают изменённую startup
allocation; разные sampled maxima не приписываются backend speed или memory
improvement.

Все original variants имели одну observation table во время работы, **3,656 bytes
для восьми probes**, затем ноль. Prepared variants дополнительно держали один
plan; observed total ETS increase при allocation — 300,072 bytes для 2,051
identities и marker. Это exact term-keyed set, а не packed bitmap. Whole-VM live
memory включает heap/allocator и compiler warmup effects; вычитание VM columns
не изолирует plan cost. Legacy loop table с six hits — 3,352 bytes, что согласуется
с другим observed set.

Original sampled total ETS peaks — 517,424 / 517,624 / 817,464 / 817,752 bytes.
Все четыре original VM возвращались к 41 processes и нулю coverage/plan tables
на обеих cleanup boundaries; sampled process-count peaks были 52. Final total
ETS values оставались примерно на 18 KB выше early snapshots из-за другого
VM/app state. Это не evidence утечки EFZ execution-table.

Большие VM-total fluctuations возникают уже между `before` и `with_plan`, даже
если plan не выделяется. Рассматривайте это как cold-start/warmup и GC/allocator
observations. Prepared campaigns намного короче и получили гораздо меньше
samples; smaller sampled maxima не доказывают smaller absolute peaks.
`/proc/self/status` отдельно фиксирует RSS и lifetime `VmHWM` в archive.
Ни один не равен `erlang:memory(total)` или ETS table words.

Resource-release evidence сильнее сходных VM totals: тесты ждут monitored
target/coordinator termination, проверяют exact table inventories, повторяют
50 deadline/next-execution pairs на variant, убивают непрерывно публикующие
targets и проверяют caller death, plan-owner death, cancellation, application
shutdown и restart. Completed campaigns намеренно сохраняют corpus, successful
coverage, decisions, unique crash reports и plan до stop. Эти объекты — не
execution-local leaks. Это bounded evidence поддерживает resource cleanup в
документированном lifecycle, а не unlimited-soak или arbitrary VM-state leak
guarantee.

## Выводы profiling и решение

Исходный loop eprof run относит 47.97% sampled function time к 100,002 ETS
inserts, 30.38% к `efz_cov_rt:hit/1`, 21.52% к loop. Parser profile относит
26.52% к inserts и 17.76% к hooks. Это мотивировало membership-before-insert;
first-hit measurements показывают extra lookup cost. Parser profile input —
32 копии `<<0,0,7,1,35,3,2>>`, семь observed probes; он отличается от throughput
input с ten probes. Не сравнивайте их elapsed times напрямую.

Original sparse profile, 100 complete executions с двумя observations и
manifest на 2,051 probes, делает 205,100 allowed-set insertions и 3,591,131
traced calls. Доминируют set bucket update/add/rehash и hashing; `spawn_opt`
также стоит 7.51%, что согласуется с копированием full options/manifests в каждый
coordinator. Code inspection подтверждает передачу full growing worker state
как options в campaigns. Preparation устраняет repeated allowlist construction
и вместо него передаёт compact execution options. Измерения не разделяют эти
два improvements. Per-hit full-manifest scan для удаления не было.

Сохранённый follow-up profile `sparse prepared` завершился: **6,331 traced calls**,
100 executions, 200 hook hits/inserts и 200 prepared membership checks.
Manifest set больше не перестраивается. Крупнейшие attributed costs:
`spawn_opt` 14.71%, ETS snapshot `match_object` 13.68%, coordinator 13.42%,
`run/4` 12.71%, ETS info 7.87% и wait handling 7.74%. Profiling total 1,550 us —
attributed function-time diagnostic, **не** unprofiled executor batch duration.

Context allocation/deletion, process/monitor setup и snapshots остаются
видимыми fixed costs. Full identities всё ещё создаются и хранятся, global
novelty и retained metadata всё ещё требуют работы. Эта phase не утверждает,
что каждый — bottleneck на всех workloads. Future work может измерять remaining
snapshot/setup costs или более лёгкое exact identity representation; при
closeout это не выполнялось. Correct termination semantics сохранена, включая
отсутствие требования target flush.

Поэтому простейшее supported decision неизменно: **prepared validation по
умолчанию; original ETS hook по умолчанию; membership optional**. Large sparse
benefits — улучшения validation/copying. Одна membership не даёт надёжного
sparse executor/campaign benefit.

## Correctness и фактические command results

Final sequence после sidecar fix завершилась exit 0:

```sh
rebar3 compile
rebar3 eunit
rebar3 ct
rebar3 dialyzer
rebar3 xref
```

| Проверка | Фактический результат |
|---|---|
| Compile | Pass, настроенный warnings-as-errors |
| EUnit | 38 passed: original semantic/lifecycle tests плюс 13 backend groups и fresh-VM sidecar test |
| Common Test | Все 3 integration cases прошли |
| Dialyzer | Pass, 22 project files; проверен PLT из 278 files; без warnings |
| xref | Pass, настроенные undefined/deprecated checks |
| Artifact audit | Все 360 original timing samples internally consistent; exact canonical comparisons совпадают; fixture identities и current BEAM/source code проверены |
| Automatic example, `+S 4:4` | Completed 500 mutations, 1 calibration, 4 discoveries, 494 rejections, 2 crashes / 1 unique, 0 timeouts или infrastructure failures |
| `git diff --check` | Pass |

Expected negative-test output включает strict-mode syntax diagnostics и
coordinator errors для намеренно incompatible plan versions. Эти тесты
проверяют infrastructure outcomes и cleanup; это не unexplained regressions.
Первый closeout gate (37 tests) прошёл до обнаружения cross-VM defect.
Artifact audit сначала отклонил noncanonical sidecar bytes; этот failure был
evidence узкого fix, а не baseline test failure.

Exact differential tests покрывают return values, nested clauses, cross-module
calls, repeated hits, error/throw/exit, synchronized external kill и timeout,
completion/deadline boundaries, isolated contexts, broken storage,
missing/build-mismatched instrumentation и deterministic corpus/crash decisions.
Existing plain/instrumented semantics и tail-position tests неизменны и проходят.
Ни одно expectation не ослаблялось для backend.

Конкретное current evidence: после seed `<<0>>` real-mutator example сохранил
`<<>>` как corpus entry 3, parent 2, `new_coverage`, probe 2. Source mapping —
`efz_example_parser:classify/1`, `examples/simple_parser/efz_example_parser.erl:7`,
build `5f11a3a9df248ba517a1ae78cfad9462d6c6453bc0565bfe27089fa4a8239b6a`.
Deterministic five-candidate test отдельно доказывает repetition rejection и
retention после artificial crash; эти IDs/inputs не находятся в fuzzer core.

Saved artificial crash из `<<255,0>>` содержит execution probe 7 с
`coverage_status => ok`, а decision имеет `target_failure` и `new_probes => []`.
Successful campaign coverage — probes `{2,3,4,5,8,9}`. Fields имеют разный смысл:
execution observations включают crash hits; corpus novelty и global successful
coverage исключают crash-only observations. Кампания продолжилась и сохранила
`<<0,0>>` после первого artificial crash. Reporting-policy change не требовалось.

Final termination snapshots сохраняют exact fixture probes `{30,66}` для error,
`{30,65}` для throw, `{30,67}` для exit и `{58}` для external kill/timeout под
build `19b2e8635273c78d98eb79d7bb4c2b11d1b94e4da9608e217d5636864fd80096`.
Все имеют `coverage_status => ok`. Differential tests сравнивают complete
module/build/probe tuples между variants. Kill/timeout tests ждут явное
post-publication message; timeout возвращает лишь после target termination.

## Воспроизведение

Запускайте из корня репозитория `efz/`. Для нового measurement используйте
**новый output directory**; храните archived outputs. Следующие commands
используют отдельные directories `reproduce-*` и current retained reference path:

```sh
rebar3 compile
rebar3 eunit
rebar3 ct
rebar3 dialyzer
rebar3 xref

ERL_FLAGS='+S 4:4' escript bench/run.escript all _build/reproduce-performance
escript bench/report.escript _build/reproduce-performance

for EFZ_VARIANT in reference member prepared prepared_member; do
  ERL_FLAGS='+S 4:4' escript bench/run.escript memory \
    "_build/reproduce-memory-$EFZ_VARIANT" "$EFZ_VARIANT" || exit
done

ERL_FLAGS='+S 4:4' escript bench/run.escript startup _build/reproduce-startup
ERL_FLAGS='+S 4:4' escript bench/profile.escript sparse
ERL_FLAGS='+S 4:4' escript bench/profile.escript sparse prepared
ERL_FLAGS='+S 4:4' escript bench/profile.escript parser
ERL_FLAGS='+S 4:4' escript bench/profile.escript loop
ERL_FLAGS='+S 4:4' escript examples/automatic/run.escript
```

`all` запускает hooks, executor и real/replay campaigns. Individual stages и
optional variant argument выбирают bounded subset. `startup` явно zero-mutation;
это не throughput benchmark. Profiling commands выполняются отдельно от final
timing. `escript scripts/coverage_bench.escript` воспроизводит более старый
small seven-sample loop harness, у которого ordinary batches sub-millisecond.

Closeout-specific archive command читает названные original и refreshed artifact
groups, проверяет их и пишет новый consultable evidence file:

```sh
ERL_FLAGS='+S 4:4' escript bench/archive.escript \
  _build/performance-final _build/phase21-closeout-evidence.term
```

Он требует эти saved group directories; это auditor данного record, а не
portable benchmark stage. Repository deliverable включает result в
`docs/performance/`, поэтому future readers не нужны ignored `_build` files
для inspection samples/metadata. Build directory не добавлен в Git.

## Изменённые файлы и remaining limits

Относительно saved Phase 2 state runtime/integration changes:
`efz_cov`, `efz_cov_rt`, `efz_cov_manifest`, `efz_executor`, `efz_worker`,
`efz_config`, `efz_corpus`, `efz_fuzzer` плюс closeout fix в `efz_instrument`.
Tests добавляют `test/efz_backend_tests.erl` и sidecar regression в
`test/efz_phase2_tests.erl`. Benchmark/replay/profile/archive tools — в `bench/`;
ordinary parser/sparse fixtures — в `fixtures/performance/`. Documentation
changes — README, architecture, coverage, этот report и его небольшой durable
evidence file. Rebar configuration, transform, mutations, feedback rules и
ordinary example source сохранены в Phase 2.1.

Acceptance завершена для tested local contract; required results не заблокированы.
Limits: только OTP 27.0, один production worker, coverage scope явно подключённого
target process, fixed selected builds на campaign, source-level clause/outcome
probes и documented skipped syntax. Timing и allocation меняются при
instrumentation. Arbitrary spawned work, hot reload, stateful OTP applications
и complete VM/OS isolation не поддерживаются. Пять samples на одной невыделенной
machine не доказывают universal speedups или absolute memory peaks. Preparation
использует memory пропорционально selected manifest; membership сохраняет
first-hit cost и workload dependence.
