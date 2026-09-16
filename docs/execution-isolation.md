# Execution model: synchronous binary harness with controlled descendants

Поддержанный backend работает в одной локальной Erlang VM с OTP 27 и одним
одновременным execution. Contract: **synchronous binary harness with controlled
descendant lifecycle**. Root реализует `Module:run(binary()) -> term()` и вызывает
обычные instrumented functions. Для дочерних процессов используется lifecycle API:

```erlang
run(Input) ->
    Parent = self(),
    Child = efz_target:spawn(fun() ->
        Parent ! {parsed, self(), my_parser:parse(Input)}
    end),
    receive {parsed, Child, Value} -> Value end.
```

`efz_target:spawn_link/1` создаёт такой же owned child с link к вызывающему
target-процессу. Обе функции принимают `fun(() -> term())`, возвращают PID и
доступны только внутри execution. Nested children используют тот же API.
Guardian создаёт процесс с закрытым start gate, устанавливает monitor и tracing,
записывает ownership, затем отдаёт PID родителю. Только после этого helper
открывает gate. В child передаются coverage context и lifecycle capability;
остальная process dictionary и mailbox создаются заново.

Root return определяет outcome case. Если важен результат или exception unlinked
child, harness должен дождаться его и отразить его в своём результате. EFZ не
подменяет такой протокол: живые descendants при завершении root принудительно
останавливаются, а уже записанные probes входят в snapshot этого execution.

## Независимый владелец lifecycle

```text
worker / executor caller
  └─ monitor ─ guardian (efz_guardian)
                  ├─ monitor caller
                  ├─ monitor ─ coordinator (классификация root result + DOWN)
                  ├─ owns ─ observation ETS и trace session
                  ├─ monitor ─ gated root
                  └─ monitor ─ все controlled descendants
```

Guardian не связан link с caller или coordinator и использует стабильный `user`
group leader. Это необходимо и для `application:stop(efz)`: application master
может завершать процессы своей I/O group независимо от links. В поддержанном
окружении существует локальный процесс `user`; stdout targets идёт через него.

Coordinator сообщает `coordinator_ready` после установки root monitor. До этого
root не исполняет пользовательский код. Coordinator ждёт `target_result` и root
`DOWN`; guardian владеет timeout независимо от него. Смерть coordinator даёт
infrastructure outcome и запускает тот же cleanup.

Guardian проходит состояния:

```text
running
  ├─ root completed/crashed
  ├─ timeout
  ├─ caller DOWN (включая campaign cancellation)
  ├─ coordinator DOWN
  └─ неподдержанный spawn / превышение admission bound
       ↓
cleaning: новые admissions запрещены
       ↓
kill root + descendants + coordinator
       ↓
DOWN каждого owned process + trace delivery barriers
       ↓
global loader trace barrier + pinned code/context integrity
       ↓
snapshot / validation / close ETS / destroy trace session
       ↓
проверка доступных признаков загрязнения VM
       ↓
final result → caller ждёт также guardian DOWN
```

`kill` действует независимо от `trap_exit`. Cleanup deadline — 1000 ms; допускается
не более 4096 controlled processes за case, включая root. Clock проверяется и при
непустой mailbox, чтобы непрерывные spawn requests не вытеснили timeout.
Это границы lifecycle, не новая mutation/campaign config.

Trace session использует `procs` и `set_on_spawn`. Обычный local `erlang:spawn`
обнаруживается как **uncontrolled spawn**: context не внедряется задним числом,
case прекращается с dirty-runner outcome. Guardian отслеживает и убивает найденные
local descendants, включая nested. Их `DOWN` может прийти раньше отложенного
spawn trace, поэтому после каждого `DOWN` вызывается `trace:delivered(Session,Pid)`.
Возврат разрешён после исчезновения всех live monitors и всех delivery barriers;
поздно обнаруженный child добавляет новый monitor/barrier. Простого обхода links
или одного snapshot списка PID здесь нет.

Семантика trace sessions и delivery barriers проверена по установленному OTP 27.0
и [официальной документации trace](https://www.erlang.org/docs/27/apps/kernel/trace.html),
[trace_delivered](https://www.erlang.org/docs/27/apps/erts/erlang.html#trace_delivered/1).
Для основных control paths используются реальные monitors и start gates;
tracing дополняет проверку границ модели.

## Result и запрет reuse

К существующим `outcome`, `coverage`, `coverage_status`, `builds` добавлены:

```erlang
#{execution_model => controlled_descendants,
  cleanup => #{status => confirmed,
               processes => [RootPid, ChildPid],
               survivors => [], violations => []},
  runner_reusable => true}.
```

`confirmed` подтверждает завершение известных процессов и trace closure, а не
полную очистку произвольного OTP application. При обнаруженном глобальном
изменении процессы могут быть полностью завершены, но runner всё равно dirty.

Если cleanup deadline истёк или погиб сам guardian, возвращается
`{infrastructure, #{kind => dirty_runner, ...}}`, `runner_reusable => false` и
`cleanup.status => unconfirmed`. Guardian failure не объявляется чистым run.
Потенциально живые процессы после потери guardian требуют уничтожения VM.
Если погиб caller, результата ему нет, но guardian самостоятельно завершает
cleanup и при необходимости помечает VM dirty.

Dirty marker хранится в `persistent_term` под `{efz_guardian, dirty_runner}`.
`efz_executor:runner_status/0` возвращает `ready` или `{dirty, Reason}`. Marker
сохраняется после `efz:stop/0` и не имеет публичного reset: требуется новая VM.
Повторный `run/4` в dirty VM возвращает infrastructure result с
`cleanup.status => not_started`, не создавая новый target. Одновременный второй
execution отклоняется как `runner_busy`; общий VM state нельзя проверять как
изолированный при параллельных cases.

Worker останавливает campaign, увеличивает `infrastructure_failures` и сохраняет
exact input, recipe и execution result в `failure_context`. Такие observations
не проходят successful feedback и не расширяют global coverage/corpus.

## Политика общего состояния

| Ресурс | Поддержанная политика | Проверка / действие EFZ |
|---|---|---|
| Process dictionary, mailbox | Только собственные root/controlled child | Уничтожаются вместе с процессами; следующий case получает новые. |
| Coverage ETS | Принадлежит guardian | Snapshot только после cleanup; таблица закрывается до результата. |
| Target-owned ETS | Без heir и передачи ownership наружу | Исчезает с owner; новые surviving tables помечают runner dirty. |
| Existing shared ETS | Записи запрещены в этой модели | Их содержимое автоматически не копируется/откатывается. Для заведомо такого эффекта harness вызывает `efz_target:dirty(Reason)`; требуется disposable VM. |
| Registered names | Только для owned processes | После `DOWN` owned names освобождены. Новые/изменённые surviving registrations помечают runner dirty; внешний процесс произвольно не убивается. |
| `persistent_term` | Target не должен менять VM-global values | Сравнение before/after keys/values; изменение даёт dirty marker. Автоматического восстановления нет. |
| Application env | Target не должен менять общий env | Сравнение env загруженных applications; изменение даёт dirty. Новая application без env сама по себе не считается env mutation. |
| Ports, remote spawn, timers/messages во внешние процессы, внешние services, files | Вне поддержанного shared-VM scope | Нет обещания cleanup/rollback или cancellation удалённой работы. Нужен следующий backend. |

Snapshots — диагностика нарушений кооперативного contract, **не security sandbox**.
Они не обнаруживают все записи в уже существующую ETS, временные изменения с
последующим восстановлением, удаление чужой регистрации, сообщения внешним
сервисам или намеренную подделку tracing/protocol. Повреждение EFZ coverage context
и hot reload дополнительно контролирует [coverage integrity](coverage-integrity.md).
Параллельные изменения VM
посторонним кодом могут дать conservative dirty result. Восстановление снимка
`persistent_term`/env поверх чужих изменений было бы небезопасным, поэтому его нет.

`A → dirty → A` проверяется двумя способами. Для process-local dictionary/mailbox,
owned ETS и registrations третий `A` действительно выполняется и возвращает те же
outcome и probes. Для VM-global mutation второй run возвращает dirty, а третий
`A` **не исполняется**. Загрязнённые values намеренно не «лечатся»; VM выводится из
использования. Для test isolation эти случаи запускаются в отдельных OS processes.

## Следующий backend для async OTP scope

Произвольные OTP applications, фоновые servers, NIF/ports, remote calls и shared
services требуют **disposable Erlang VM** с внешним владельцем OS process и
подтверждением его завершения. Этот backend пока не реализован. Даже VM backend
должен отдельно описать filesystem/network side effects и remote cleanup.
Текущий guardian не следует links к чужим processes и не выдаёт такую изоляцию
за уже решённую задачу.

## Regression evidence

[efz_isolation_tests](../test/efz_isolation_tests.erl) компилирует реальный
[instrumented target](../fixtures/efz_isolation_target.erl). Проверяются normal,
crash, timeout, trap_exit, linked/unlinked/nested children, caller/coordinator death,
spawn около deadline, registration/ETS cleanup и совпадение child coverage context.
После supported case все PID из ownership report должны быть dead, включая
процессы, умершие ещё на start gate.

Отдельные свежие VM проверяют persistent_term/env/shared ETS, escaped ETS/name,
обычный/nested unmanaged spawn, потерю guardian и campaign dirty-report. Guard
failure test сначала доказывает `unconfirmed` и запрет reuse, затем сам завершает
оставшиеся тестовые процессы: это не выдаётся за cleanup со стороны executor.
Логи этих runs находятся в `_build/isolation-test/`. Общие regression tests по
coverage, crash/replay и `A → AB → ABC` продолжают проверять прежний pipeline.

При сочетании первичной infrastructure failure (например, `coordinator_down`)
и dirty cleanup `outcome` сохраняет первую причину. `coverage_status`, `cleanup`
и `runner_reusable => false` фиксируют невозможность повторного использования VM;
следующий input отклоняется как dirty runner. Regression `coordinator_dirty`
проверяет это сочетание в отдельной VM.

Поздняя потеря guardian после настоящего reply проверяется отдельно в
`efz_crash_retention_tests`: test-only преобразование AST guardian добавляет gate
после отправки сообщения в приватной VM. После coordinator death reply несёт
исходную ошибку; затем guardian завершается ненормально. Report/stats сохраняют
исходную причину, `guardian_failure` описывает вторичную, а `execution_evidence`
сохраняет исходный cleanup/coverage. Runner retired, следующий target не запускается.
В production нет опции fault injection.

## Optional runtime observations

P0 samples only guardian-admitted processes and their ETS owners. It adds a bounded
sampler monitor/lifecycle to this guardian; ownership/start gates/trace barriers
and dirty-runner rules remain authoritative. Sampler failure is partial diagnostic
evidence; guardian or unconfirmed lifecycle failure still retires the VM. Cleanup
kills do not constitute process leaks. See [runtime diagnostics](runtime-diagnostics.md).
