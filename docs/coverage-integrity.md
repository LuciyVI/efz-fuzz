# Целостность automatic coverage

Контракт применяется к executor с [controlled descendant lifecycle](execution-isolation.md).
Пустой список probes сам по себе не доказывает, что наблюдение работало. EFZ
проверяет загруженный код, attachment context, ошибки hooks и сохранность уже
опубликованных probes независимо от успешного возвращаемого значения harness.

## Закреплённые identities

`efz_config:prepare/1` формирует `execution_identities`:

```erlang
#{harness => #{module => my_harness, beam_md5 => <<...>>,
               build_id => undefined, attributes_sha256 => <<...>>,
               compile => [...]},
  modules => #{my_parser => #{module => my_parser, beam_md5 => <<...>>,
                             build_id => <<...>>, attributes_sha256 => <<...>>,
                             compile => [...]}}}.
```

Harness закрепляется отдельно, даже если он не instrumented и не входит в
`artifacts`. `build_id => undefined` у обычного harness ожидаем. Идентичность
берётся из **загруженного кода** через `erlang:get_module_info/1`, а не из файла,
найденного в code path. `beam_md5` — OTP checksum исполняемого кода, не SHA-256
полного BEAM-файла; отдельно проверяются attributes и compile metadata.
[OTP описывает различие code checksum и compilation attributes](https://www.erlang.org/doc/apps/stdlib/beam_lib#md5/1).

Preflight сверяет manifest sidecar с embedded manifest, затем checksum кода
artifact BEAM и manifest с загруженным модулем. Копирование старого manifest в
другую реализацию больше не позволяет пройти проверку. `efz_cov_manifest:prepare/2`
сохраняет loaded identities выбранных модулей в protected validation plan.

Worker передаёт campaign pins в оба режима validation: `prepared` и
`per_execution`. Pins входят в execution results, retained metadata и итоговый
report. Поле `builds` обозначает **ожидаемые выбранные builds**; при ошибке identity
его нельзя интерпретировать как подтверждение исполнения прежнего кода.

Standalone `efz_executor:run/4` без `execution_identities` закрепляет harness на
время одного вызова; plan сохраняет identities выбранных модулей между вызовами.
Для campaign используются pins, созданные при `efz_config:prepare/1`. Replay
сравнивает явно предоставленные target/artifacts с сохранёнными build IDs и
harness identity из `artifact.replay`, затем создаёт pins для execution. Низкоуровневый
`efz_recipe:execute/5` требует `expected_harness`; сама mutation recipe старую
версию harness не доказывает. Attributes hash использует deterministic ETF,
чтобы совпадать между VM. Подробности: [replay](replay.md).

## Проверка replacement

Guardian сравнивает pins до запуска target и после его termination. В течение
execution отдельная OTP trace session наблюдает запросы загрузки/удаления
выбранных модулей через `code_server`, включая batch `code:finish_loading/1` с
кодом, подготовленным до execution. Попытка загрузки выбранного модуля делает
результат недостоверным, даже если загрузчик затем вернул исходный BEAM.
Это консервативное правило: повторная загрузка тех же bytes или неудачная попытка
замены выбранного модуля тоже отклоняется. Загрузка обычных новых зависимостей
через code server разрешена, если они не входят в pins.

Дополнительно отслеживаются ERTS `delete_module/1`, `finish_after_on_load/2`
для выбранных модулей и `finish_loading/1` вне code server. Прямой ERTS commit
консервативно даёт `unsupported_direct_code_loading`: opaque prepared-code
handles не дают надёжно отфильтровать выбранные модули. Это закрывает замену
через ERTS с последующим восстановлением исходной сборки.

Перед final result guardian дожидается DOWN и trace barriers всех owned
processes, затем глобального delivery barrier для loader traces, проверяет
snapshot и identities и удаляет execution resources. Невалидный или уничтоженный
prepared plan также даёт infrastructure failure, в том числе при пустом snapshot.

## Context и observation states

`efz_coverage_observers` — named **protected ETS**, принадлежащая guardian.
До открытия start gate в неё записывается `PID → expected context`; там же
хранятся execution pins. Таблица не хранит global coverage и не служит глобальным
«текущим input»: hook ищет только запись собственного PID. Один local execution
на VM уже ограничен lifecycle guardian.

Hook сверяет process dictionary с этой записью. Поэтому `erase()` или malformed
value не превращают активный hook в inactive. Ошибка отправляется guardian до
исключения; target не может скрыть её своим `catch`. Trace `put/erase` сохраняет
свидетельство изменения context, даже если target восстановил ключ либо был
убит до проверки на выходе. Ошибки sticky: последующий корректный hit их не
снимает. Controlled descendants проверяются так же, как root.

Каждый новый probe сначала синхронно вставляется в observation ETS, затем
сообщается guardian. В конце все такие сообщения должны соответствовать
сохранившимся ETS rows. Стирание опубликованных observations без повторной записи
даёт `coverage_observations_lost`. Дубликаты не создают поток одинаковых сообщений.

| `coverage_observation.classification` | `state` | Значение |
|---|---|---|
| `observed_coverage` | `observed` | Целое наблюдение с probes |
| `valid_empty_coverage` | `attached` | Root attachment подтверждён, ошибок нет, probes отсутствуют |
| `broken_coverage_observation` | `failed`, `detached` или `invalid` | Ошибка hook, context, identity, validation или потеря observations |
| `unstarted_coverage_observation` | `unattached` | Target не успел attach, например timeout до открытия gate; это не successful empty execution |

Map содержит `attached_processes`, `probe_count`, при ошибке — `reason`.
Successful outcome без подтверждённого root attachment запрещён. При нарушении
`outcome = {infrastructure, Reason}`, `coverage_status = {error, Reason}`;
`target_outcome` сохраняет отдельный результат target, если он получен. Worker
увеличивает `infrastructure_failures`, сохраняет exact input/result в
`failure_context` и останавливает campaign. Частично записанные probes можно
диагностировать, но они не участвуют в successful feedback.

## Настоящий zero-hit и disconnected campaign

Вызов instrumented function может закончиться `function_clause` до входа в тело
любого clause. Обычный harness может поймать это исключение и вернуть `zero`.
Это настоящий `valid_empty_coverage`. Harness, пропустивший target для конкретного
input, тоже может дать валидный пустой результат. По одному такому запуску нельзя
доказать, что harness ошибочно подключён.

Campaign считает наблюдавшиеся модули **по всем целым execution observations**,
включая target crashes, отдельно от successful global coverage. Report содержит:

```erlang
#{coverage_diagnostics => #{policy => diagnostic,
    status => no_probes_observed, % либо observed / manual
    observed_modules => [],
    unused_artifacts => [#{module => my_parser, build_id => <<...>>}],
    empty_executions => 1, unstarted_executions => 0, broken_observations => 0}}.
```

- `coverage_policy => diagnostic` — default: отсутствие probes явно видно в
  report, CLI печатает diagnostic. Campaign может завершиться обычным status.
- `coverage_policy => strict` — при окончании campaign без единого достоверного
  instrumented probe возвращается `{infrastructure_failure, #{kind =>
  coverage_not_observed, ...}}`, счётчик infrastructure failures увеличивается,
  CLI возвращает **1**. Существующая primary infrastructure error не заменяется.
- Отдельный unused artifact перечисляется даже когда другие дали probes. Strict
  требует хотя бы один probe суммарно, а не hits каждого выбранного artifact.
- Нулевая calibration вызывает warning, но не прерывает mutation: первый полезный
  input может появиться позже. Это также даёт раннюю диагностику infinite campaign.
  Счётчики `coverage_*_executions` и `coverage_broken_observations` доступны через
  `efz:stats/0` во время работы.

```sh
escript scripts/fuzz.escript --target my_harness --code-path ./ebin \
  --seeds ./corpus --out ./findings --artifacts ./instrumented \
  --coverage-policy strict --max-iterations 1000
```

Campaign policy независима от `strict` parse transform, проверяющего поддержку
Erlang syntax при instrumentation. Ни одна из этих проверок не меняет novelty:

```text
New = Current - Global
successful valid execution: Global := Global union Current
broken observation: error, без merge и без retain
```

## Границы и проверки

Это проверка correctness в доверенной shared VM, не защита от произвольного
враждебного Erlang-кода. Замена самого EFZ, отключение tracing, подделка protocol
messages/ETS rows и remote execution не входят в supported model. Для полного
async OTP scope нужен отдельный disposable VM backend. Trace-адаптер code server
проверен на OTP 27.0; при поддержке других OTP его regression tests обязательны.
Identity/trace проверки добавляют стоимость execution; старые benchmark numbers
не характеризуют этот backend после усиления integrity.

[efz_integrity_tests](../test/efz_integrity_tests.erl) покрывает normal/zero-hit,
disconnected/unused artifacts, strict policy, unchanged novelty, dictionary
erase/malformed/restore, caught hook exceptions, потерю ETS rows, child context,
kill, pre-execution/during-execution/transient reload, отдельный harness pin,
prepared plan, copied manifest, public atomic load и прямой ERTS commit.
[efz_cli_tests](../test/efz_cli_tests.erl) проверяет diagnostic/strict/invalid policy
в отдельных fresh Erlang VM.
