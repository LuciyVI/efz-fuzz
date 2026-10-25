# P1-01 Внешний supervisor

[English](../../p1-01-external-supervisor.md) · **Русский** · [Español](../es/p1-01-external-supervisor.md) · [简体中文](../zh-CN/p1-01-external-supervisor.md) · [Все языки](../README.md)

Статус: **DONE** на Linux. Дата validation: 2026-09-21. Implementation baseline:
`9303c6e0734cc135700e62b0774f4a0011e97d48`.

Supervised backend включается явно. Legacy execution и публичный harness
contract `Module:run(binary())` неизменны.

## Baseline и фактическая архитектура

Среда: Linux 6.8.0 x86_64, OTP 27, ERTS 15.0, rebar3 3.25.0. Проект объявляет
минимум OTP 27. Существующий code поддерживает legacy mode там, где работают
OTP 27 и его filesystem assumptions; lifecycle guarantees P1-01 явно ограничены
Linux, поскольку используют `pidfd`, `PR_SET_PDEATHSIG`, subreaping, Unix peer
credentials и `/proc` descendant enumeration.

Checkout был dirty до P1-01. Pre-existing hit-count/corpus changes перечислены
в `_build/p1-validation/before.status` и сохранены отдельно. Не выполнялись reset,
clean, checkout, target harness change или deletion.

Настоящий legacy call path:

```text
scripts/fuzz.escript
  -> efz_cli:main/1
  -> efz:start/1 -> efz_fuzzer:init/1
  -> efz_worker (seed calibration / mutation / feedback / corpus / P0 verification)
  -> efz_executor:run/4
  -> efz_guardian:run/6
  -> efz_executor:invoke/4 -> Harness:run(Binary)
  -> guardian cleanup/coverage/runtime result
  -> efz_feedback:evaluate/3 -> efz_corpus / crash and runtime stores
```

`efz_guardian` владеет target root и controlled descendants внутри worker VM,
target deadline, cleanup и решением dirty-runner. `efz_runtime` семплирует эти
owned processes. `efz_corpus_store` — durable successful-corpus path;
`efz_runtime_store` и `efz_crash` публикуют findings. Replay находится в
`efz_replay_cli`, `efz_replay` и `efz_runtime_replay`. Restored corpus калибруется
заново, но minimizer в этом checkout отсутствует. Target callback validation
и `on_load` выполняются через `efz_config`/`code:ensure_loaded` внутри campaign
VM; instrumented BEAM загружается через `efz_instrument`. Следовательно,
во внешний worker нужно перенести полный campaign loop, а не только `run/1`.

Canonical baseline до P1-01:

| Команда (`ERL_FLAGS='+S 4:4'`) | Exit | Результат |
|---|---:|---|
| `rebar3 compile` | 0 | PASS |
| `rebar3 eunit` | 0 | 223 tests PASS |
| `rebar3 ct` | 0 | 3 tests PASS |
| `rebar3 dialyzer` | 0 | PASS |
| `rebar3 xref` | 0 | PASS |

Raw logs: `_build/p1-validation/baseline-*.log`.

## Реализованная граница процессов

`--supervised` делегирует в `efz_cli:main/1` до target lookup, application startup,
replay или callback validation. Исходный CLI process запускает file-only Python
controller через `open_port({spawn_executable, Python}, ...)` с явным argument
vector. Controller никогда не импортирует, не загружает и не вызывает target,
harness или NIF code. Он хеширует local EFZ, artifact, sidecar, harness и `.so`
files и bounded command configuration.

Для каждой generation controller запускает `priv/efz_vm_launcher` через argument
vector (без shell). C launcher делает fork и `execv` для `erl`; новый BEAM
вызывает `efz_external_worker:main/0`, который затем запускает обычный `efz_cli`
и настоящую кампанию. Поэтому загрузка target/harness/NIF ограничена worker
address space. Guardian внутри этого worker неизменен.

Launcher:

- получает `pidfd` controller и устанавливает `PR_SET_PDEATHSIG` с проверкой
  parent после установки;
- делает BEAM новым session/process-group leader с собственной race check
  parent-death SIGKILL;
- работает child subreaper, убивает/дожидается adopted descendants до сообщения
  `cleanup_confirmed=true`;
- возвращает raw `waitpid` status, отдельные signal и exit code, а также факт,
  что kill инициировал launcher;
- непрерывно вычитывает worker stdout/stderr, считает все bytes и сохраняет
  лишь tail 4096 bytes; crash dumps и cores у worker выключены;
- никогда не запускает replacement до confirmed cleanup старого worker.

Controller также удерживает `pidfd` вызывающего CLI и выполняет live ACK
challenge через унаследованный port. Поэтому SIGKILL CLI или controller заставляет
launcher убить и reap worker, зависший в NIF. Это lifecycle containment, а не
security sandbox: native code всё ещё имеет доступ к filesystem, network и host
с credentials worker.

## Обязательный execution barrier

Единственный integration hook — первая operation `efz_executor:run/4`:

```text
efz_worker selects/generates Input
  -> efz_executor:run/4
  -> efz_external_worker:execution/4
  -> PREPARE(Input, digest, phase, timeout, bounded recipe)
  -> controller validates the fixed schema
  -> fsync artifact.input, artifact.external.json, optional artifact.recipe,
     and manifest.json in a private staging directory
  -> fsync staging directory
  -> rename the whole directory to CAMPAIGN/RUN and fsync campaign directory
  -> atomically write/fsync authorized.json and fsync the run directory
  -> COMMITTED/RUN(RunId, digest)
  -> worker verifies generation, RunId and digest
  -> existing executor -> guardian -> Harness:run(Input)
  -> bounded RESULT -> atomic checksummed result.json -> RESULT ACK
```

Hook покрывает seed calibration, corpus recalibration, mutation executions и
P0 verification/reproduction, поскольку все используют `efz_executor:run/4`.
External-finding reproduction — настоящая кампания с одним input, проходящая
тот же barrier. Реализации minimization для покрытия нет. В legacy mode gate —
прямой call без IPC или filesystem work.

Ни один target execution не разрешён после failed write/fsync/rename/authorization.
Journal имеет один in-flight run, limit input 1 MiB, limits recipe и metadata
64 KiB, настраиваемый total byte budget и максимум 100000 scanned/run records.
Raw input авторитетен. Existing EFZR mutation recipe включается, когда доступен
и valid; отсутствие или metadata cap отмечаются явно.

Publication делает группу input и metadata атомарно видимой в одной filesystem.
File и соответствующие directory fsync дают сильнейшую практическую гарантию
локальной filesystem, используемую в других местах EFZ. Это не обещает поведение
storage hardware сверх successful OS fsync. `authorized.json` отличает
committed-but-not-issued PREPARED run от run с долговечно записанным permission.
Он не может доказать, что worker дошёл до target code. Поэтому:

- uncommitted staging не приписывается target;
- PREPARED без authorization становится `interrupted_prepared`;
- authorized без RESULT становится `interrupted_unknown`, если live launcher
  не даёт более сильного termination evidence;
- реализация не заявляет exactly-once execution между crashes.

Finalization атомарна, checksummed и идемпотентна по campaign/RunId. Startup
проверяет все bounded manifests/results и финализирует incomplete records,
не выдумывая native crash. Committed input остаётся replayable, если позднее
падает result или index publication.

## Protocol и машина состояний

Unix-domain control socket отделён от stdout/stderr. Linux `SO_PEERCRED` должен
совпадать с worker PID из launcher и current uid. Frames — `u32` big-endian
length, за которой следует fixed primitive schema. Length отклоняется после
первых четырёх bytes и до накопления payload. Maximum frame size — input +
64 KiB recipe + 59 bytes. Reads по 4096 bytes, у partial frames deadline одна
секунда, decoder обрабатывает multiple frames.

На control channel нет ETF/JSON/compression. RESULT — четыре bytes. Optional
recipe остаётся existing checksummed EFZR data format; его size, ETF version и
compressed tag проверяются до storage, controller никогда его не декодирует.

Сообщения protocol v1: HELLO, READY, PREPARE, RUN, RESULT, DONE/SHUTDOWN и ACK.
Каждый frame проверяет type, state, generation, RunId, identity и exact payload
length. HELLO содержит protocol marker, combined file identity, worker
configuration identity, OS PID, OTP и ERTS. Unexpected, stale, duplicate и
post-terminal results — protocol failures.

States: STARTING, SETUP, READY, PREPARING, EXECUTING, FINALIZING, RECYCLING и
STOPPING. RESULT долговечно принимается до ACK и очищает in-flight record;
позднейший process exit не может переписать этот run в native crash. Если первым
достигнут absolute hard deadline, поздний RESULT игнорируется, а launcher kill
остаётся единственной terminal classification. EOF и wait status обрабатываются
независимо, чтобы вычитать final complete frame до death classification.

Classification использует raw evidence:

| Observation | Classification |
|---|---|
| signal при authorized in-flight run, без controller kill | `native_vm_crash` |
| exit code без signal | `worker_unexpected_exit` |
| controller absolute deadline/kill | `worker_hard_timeout` |
| invalid IPC | `worker_protocol_failure` |
| finalized non-reusable guardian result | `dirty_recycle` |
| death до READY/во время idle | startup/infrastructure, без testcase finding |
| user/parent stop | campaign stop, никогда не native crash |

Signal evidence доказывает завершение VM, а не вину target или root cause.
`exit(139)` записывается как exit code 139 и signal 0. Launcher SIGKILL фиксирует
`launcher_kill=true` и никогда не называется native crash.

## Deadline, recycle и recovery

Внешний per-run deadline монотонный и абсолютный:

```text
target timeout + guardian cleanup (1000 ms)
+ CLI P0 post-memory allowance (100 ms when enabled)
+ configured IPC grace (default 1000 ms)
```

Traffic и logs никогда его не продлевают. Startup/idle отдельно ограничен
(default 10000 ms), launcher termination — пятью секундами, adopted-child cleanup —
двумя. Unconfirmed cleanup прерывает работу без restart.

Native crash, hard timeout и dirty result сохраняют/финализируют current run,
карантинируют digest, ждут гибели старого process, увеличивают generation,
повторно проверяют file identity, восстанавливают existing durable corpus и
калибруют его заново. Каждый recalibration execution использует тот же barrier.
Quarantined inputs пропускаются, предотвращая цикл crashing corpus seed.
Restart budget (8), linear bounded backoff, campaign deadline, execution cap,
mutation execution remainder, P0 verification remainder и journal bytes
принадлежат controller. Startup/identity failure до READY не перезапускается
бесконечно.

Recovered state — durable corpus и настроенные global budgets. Worker-local
coverage, feedback, RNG и staged cursors создаются заново; exact campaign resume
не заявляется.

## CLI и artifacts

Пример:

```sh
ERL_FLAGS='+S 4:4' rebar3 compile
ERL_FLAGS='+S 4:4' escript scripts/fuzz.escript \
  --supervised --target my_harness --code-path harness-ebin \
  --artifacts instrumented --seeds seeds --corpus-dir out/corpus \
  --out out --timeout 1000 --max-iterations 10000 \
  --restart-budget 8 --supervised-runs 20000 \
  --campaign-ms 3600000 --ipc-grace-ms 1000 --journal-bytes 268435456
```

`OUT/external-runs/CAMPAIGN/RUN/` содержит `artifact.input`,
`artifact.external.json`, optional `artifact.recipe`, `manifest.json`,
`authorized.json` и checksummed `result.json`. Configuration identity и точный
file list хранятся в campaign directory. External findings также индексируются
в существующем namespace `OUT/crashes/external/`. Worker reports и обычные
crash/runtime findings остаются в `OUT/worker-GENERATION/`.

Reproduction выбирает target code локально и проверяет file/harness identity:

```sh
escript scripts/replay.escript \
  --external-finding OUT/external-runs/CAMPAIGN/RUN \
  --target my_harness --code-path harness-ebin --artifacts instrumented \
  --out recheck --reproduce-runs 3
```

Он выполняет bounded number isolated generations и сообщает observed N/M,
а не boolean одного run.

## Evidence native acceptance

Итоговая команда:

```sh
python3 -m unittest discover -s test -p '*supervisor_test.py' -v
```

Exit 0, 13/13 tests. Raw log:
`_build/p1-validation/posthook-native.log`. Evidence root:
`_build/p1-native-68udkvqj`.

Настоящая CLI кампания SAFE -> SIGSEGV -> restart -> SAFE зафиксировала:

- campaign `119e4f3df348420e98488ed25bde3cc4`;
- supervisor PID 739219, CLI PID 738777;
- generation 1 worker PID 739271; RunId 1 SAFE completed;
- RunId 2 raw `SEGV`, SHA-256
  `8f243e33082126167daac18a24f576245ff332a18dc217093bc6cf9d6bbcdc1b`;
- authoritative `waitpid`: signal 11, exit code -1, raw status 139,
  `launcher_kill=false`, `cleanup_confirmed=true`;
- finding:
  `_build/p1-native-68udkvqj/SEGV-61938280703258/out/external-runs/119e4f3df348420e98488ed25bde3cc4/2`;
- generation 2 worker PID 740096; restored corpus сообщил 3 inputs,
  recalibrated SAFE1, RunId 4 успешно исполнил SAFE2;
- final status completed, две generations, четыре barriered executions.

SIGABRT независимо дал signal 6 с `launcher_kill=false`, перезапустился и
завершился. Два isolated rechecks каждого native finding сообщили `observed 2/2`.
Fixture NIF загружался лишь в child worker VM; core и crash dumps выключены.

Дополнительные final acceptance results:

- hung NIF: `worker_hard_timeout`, launcher signal 9,
  `launcher_kill=true`, cleanup confirmed, generation 2 достигла SAFE2;
- DIRTY: original result сохранён как `dirty_recycle`; generation сменилась
  до SAFE2; native finding отсутствует;
- `exit(139)`: `worker_unexpected_exit`, exit 139, signal 0;
- internal WAIT/BUSY: guardian outcomes сохранены с `timeout_waiting` и
  `timeout_busy` соответственно;
- 8,389,639 bytes target output вычитаны без блокировки; retained tail остался
  4096 bytes;
- startup `on_load` SIGABRT до READY: ноль executions и ноль findings;
- durable write-budget failure: nonzero exit, marker доказывает отсутствие
  входа в target;
- withheld RUN test: настоящий child BEAM выдал PREPARE, но не касался target
  до journal commit и permission, привязанного к digest;
- malformed/oversized/compressed-looking frames, partial/multiple frames,
  stale generation, wrong identity и duplicate RESULT отклонены;
- finalization EIO оставил committed raw input и был recovered ровно один раз;
- SIGKILL CLI evidence: worker 744649, launcher 744647, controller 744618 все
  исчезли из `/proc`; SIGKILL controller evidence: worker 744920, launcher
  744919, controller 744894 все исчезли; recovery классифицировал uncertainty,
  а не native target crash;
- zero restart budget остановил работу после первого crash с
  `restart_budget_exhausted`; persistent startup failure остановился до READY.

## Регрессия и performance

Final canonical results (все с `ERL_FLAGS='+S 4:4'`):

| Команда | Exit | Результат |
|---|---:|---|
| `rebar3 compile` | 0 | PASS; Linux helper собран pre-hook |
| `rebar3 eunit` | 0 | 224 tests PASS (baseline 223) |
| `rebar3 ct` | 0 | 3 tests PASS |
| `rebar3 dialyzer` | 0 | PASS, без warnings |
| `rebar3 xref` | 0 | PASS |

Logs: `_build/p1-validation/release2-*.log`. Второй canonical EUnit run также
завершился успешно со всеми 224 tests.

Точное staged P1-only tree также экспортировано через `git checkout-index` и
проверено независимо от pre-existing hit-count work: compile, 211 EUnit,
3 Common Test, Dialyzer и Xref прошли; 13 native tests прошли за 33.649 s.
Меньшее число EUnit ожидаемо: snapshot намеренно исключает посторонние
uncommitted tests.

Diagnostic benchmark выполнил три чередующихся repeats одного safe target
с 300 mutation executions плюс одной calibration. Fsync включён:

| Медиана | Legacy | Supervised |
|---|---:|---:|
| wall time | 2.246 s | 6.062 s |
| mutation throughput | 133.6/s | 49.5/s |
| total throughput | 134.0/s | 49.7/s |
| durable prepare total | n/a | 2.441 s |

Supervised wall time составил 2.70x legacy; throughput ниже на 62.9%.
Durable publication и authorization стоят около 8.11 ms/input. Remaining cost
включает extra VM, IPC и finalization. Raw rows:
`_build/p1-validation/benchmark-final.log`; per-run artifacts:
`_build/p1-bench-i_u4wnm7/`.

## Ограничения

- Полные guarantees только для Linux. Supervised launch на других ОС явно
  отказывает; legacy mode остаётся доступным.
- Это crash containment и recovery, а не sandbox для враждебного native code.
- Побочные эффекты filesystem/network/external-service нельзя откатить.
- Работа полагается на successful fsync/rename; поведение при потере питания
  в конечном счёте зависит от соблюдения этих operations filesystem и hardware.
- Journal доказывает preparation и permission, а не точный вход в target code.
  Exactly-once не заявляется.
- Corpus восстанавливается и калибруется заново. Exact RNG, staged cursor и
  global coverage checkpoint resume намеренно не заявляются.
- Поддерживаются один worker и один in-flight testcase; multi-worker/distributed
  scheduling вне P1-01.
