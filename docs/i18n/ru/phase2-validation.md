# Протокол валидации Phase 2

[English](../../phase2-validation.md) · **Русский** · [Español](../es/phase2-validation.md) · [简体中文](../zh-CN/phase2-validation.md) · [Все языки](../README.md)

Дата: 2026-09-08. Все execution targets и corpora — локальные искусственные fixtures.
Среда: OTP 27.0, ERTS 15.0, x86_64-pc-linux-gnu; Rebar3 3.25.0.

## Baseline и scope

Репозиторий — подкаталог `efz/` предоставленного workspace. При входе README и
app metadata были изменены, а большая часть кода, примеров, тестов и docs Phase 1
была untracked. AGENTS.md и дополнительные repository instructions не найдены.
Работа сравнивалась с копией этого исходного состояния; посторонние исходники
corpus, mutator, behaviour, application callback и root-supervisor сохранены.
Git identity, remotes, commits, staging и pushes не менялись.

До редактирования кода: `rebar3 compile` прошёл; `rebar3 eunit` прошёл все 7 tests;
`rebar3 ct` прошёл с нулём cases; `rebar3 dialyzer` прошёл. Настроенного plugin
formatter/linter не было. Существующие xref checks выполнены в final validation.

Baseline executor мог вернуть результат до подтверждения завершения по timeout,
а coverage было общим gen_server set. Отсутствовали initial calibration, crash
storage и надёжный campaign teardown. Эти основы исправлены в существующем
execution/worker/fuzzer path; исходные random mutator и in-memory corpus
implementation сохранены.

## Команды и итоговые outcomes

| Команда | Результат |
|---|---|
| `rebar3 compile` | Pass, warnings считаются errors |
| `rebar3 eunit` | 24 tests pass, включая 17 сгруппированных Phase 2 cases |
| `rebar3 eunit --module=efz_phase2_tests` | Pass, все 17 focused Phase 2 cases |
| `rebar3 ct` | 3 integration cases pass |
| `rebar3 dialyzer` | Pass; compiler добавлен в PLT extra apps для compilation APIs |
| `rebar3 xref` | Pass, настроенные undefined/deprecated checks |
| `REBAR_BASE_DIR="$EFZ_CLEAN_BUILD" rebar3 compile` с новым каталогом `mktemp` | Pass; ordinary parser BEAM не содержит EFZ manifest |
| `escript examples/automatic/run.escript` | Instrumented build и 500 real-mutator iterations завершены |
| `escript scripts/coverage_bench.escript` | Семь measured samples на warmed mode; без threshold |
| `git diff --check` | Pass |

Ни одна dependency не заблокировала команды. Ожидаемые negative-test diagnostics
включают strict-mode rejection comprehensions, `maybe` и nonliteral record
defaults, missing/changed artifacts и unselected modules. Во время разработки
relocation test выявил нормализацию source-root `.`; она исправлена.
Некорректный record-default test fixture исправлен после того, как compiler
отклонил bound variable в record declaration. Это development failures, а не
baseline failures; итоговые test outcomes приведены выше.

Clean build создан в `/tmp/efz-clean.cl22wE` без clean/reset существующих
worktree/build. Его ordinary parser проверен через `efz_cov_manifest:from_beam/1`,
вернувший ожидаемый `{error,missing_instrumentation}`. Generated outputs остаются
ignored в `_build` или в явно заданном временном build directory.

## Конкретное evidence retention и продолжения

Детерминированный test mutator (только `test/efz_scripted_mutator.erl`) выдаёт:

```erlang
[<<>>, <<>>, <<255>>, <<1,7>>, <<1,7>>]
```

После calibration единственного seed `<<0>>`, `<<>>` сохраняется как corpus entry 2
с parent entry 1 и `retention_reason => new_coverage`. Он возвращает `{ok,empty}`
и обнаруживает empty-input clause `classify/1` в
`examples/simple_parser/efz_example_parser.erl:7:1`. В записанном build его
logical identity имеет probe ID 2 и build SHA-256:

```text
5f11a3a9df248ba517a1ae78cfad9462d6c6453bc0565bfe27089fa4a8239b6a
```

Этот ID прочитан из сгенерированного manifest/decision, а не захардкожен в core
logic или acceptance test. Metadata также включает execution reference и input
SHA-256. Следующая идентичная mutation отклоняется. `<<255>>` вызывает помеченное
искусственное exception и сохраняется как crash с непустым coverage. Кампания
продолжается, сохраняет `<<1,7>>`, затем отклоняет его повтор.

Итоговые deterministic counts: 1 calibration, 5 mutation executions,
2 discoveries, 2 equivalent rejections, 1 crash и 3 corpus entries. Crash-only
coverage не объединяется; отдельный assertion доказывает, что оно всё ещё может
быть novel для последующего successful result. `_build/phase2-acceptance.term`
хранит полный report.

Production mutator run использует `random_seed => {17,23,41}`, seed `<<0>>` и
500 iterations. Измеренный result: 5 discoveries, 2 artificial crashes (1 unique),
493 equivalent rejections, 0 timeouts, 0 infrastructure failures и 6 corpus
entries. Он завершается после обоих crashes. `_build/example-report.term` и
`_build/example-report.txt` содержат report; input и metadata files находятся в
`_build/example-crashes`. Random-mutator observations отделены от scripted
acceptance proof.

## Coverage после завершения и изоляция

Lifecycle fixture отправляет `{probe_recorded, self()}` только после возврата
automatic entry probe. Тесты ждут это сообщение до запроса external kill или
ожидания timeout намеренно заблокированного execution. Final results проверяют
непустое coverage, отображённое в function entry, `coverage_status
=> ok` и соответственно `{exit,killed}` или `{timeout,1000}`. Процесс мёртв до
возврата итогового timeout coverage. Results исключений error, throw и exit
также сохраняют pre-termination coverage. Проверенные snapshots содержат по
два probes для error/throw/exit и по одному для external kill/timeout, все с
`coverage_status => ok`.

EUnit записывает доступные для inspection snapshots в `_build/phase2-kill.term`,
`_build/phase2-timeout.term`, `_build/phase2-error.term`,
`_build/phase2-throw.term` и `_build/phase2-exit.term`.

Другие checks покрывают новые empty contexts, равные probe sets и разные
references для одного input, непересекающиеся entry probes разных inputs, два
одновременно подключённых contexts, selected cross-module calls, повторные
deadline-boundary executions и неизменные counts ETS tables. Caller death,
публичная отмена кампании и application shutdown во время синхронизированного
active target завершают target и context owner. Перехваченное invalid-table
hook exception всё равно становится infrastructure result, а не target crash
или successful empty feedback.

## Наблюдения benchmark

См. [полные measured samples](coverage.md#воспроизводимая-validation-и-overhead).
Один ordinary/instrumented fixture исполнил по 200,000 tail-loop iterations на
sample после 30,000 warmup iterations, семь repeats на mode:

| Режим | Медиана | Относительно ordinary |
|---|---:|---:|
| Ordinary | 518 us | 1.00x |
| Instrumented, no context | 5,315 us | 10.26x |
| Instrumented, active context | 67,209 us | 129.75x |

Active set содержал шесть probes в 419 ETS words (3,352 bytes при 8 bytes/word),
затем был удалён. Synthetic loop выявляет hook/ETS overhead; это не утверждение
о сквозной parser throughput. OTP cover не измерялся. Machine-specific
correctness thresholds отсутствуют.

## Изменённые файлы относительно предоставленного worktree Phase 1

* Compilation/runtime additions: `src/efz_instrument.erl`,
  `src/efz_instrument_pt.erl`, `src/efz_cov_rt.erl`,
  `src/efz_cov_manifest.erl`, `src/efz_feedback.erl`.
* Изменения существующей интеграции: `src/efz.erl`, `src/efz_config.erl`,
  `src/efz_cov.erl`, `src/efz_executor.erl`, `src/efz_worker.erl`,
  `src/efz_fuzzer.erl`, `src/efz_worker_sup.erl`, `src/efz_stats.erl`,
  `src/efz_crash.erl`, `src/efz.app.src`, `rebar.config`.
* Пример: изменён `examples/simple_parser/efz_example_parser.erl`; добавлены
  `examples/simple_parser/efz_example_target.erl` и
  `examples/automatic/run.escript`.
* Тесты: изменён `test/efz_smoke_tests.erl`; добавлены `test/efz_phase2_tests.erl`,
  `test/efz_scripted_mutator.erl` и `test/efz_coverage_SUITE.erl`.
* Fixtures/benchmark: `fixtures/efz_fixture.erl`,
  `fixtures/efz_fixture_helper.erl`, `fixtures/include/efz_fixture.hrl`,
  `fixtures/efz_skipped.erl`, `fixtures/efz_record_default.erl`,
  `fixtures/efz_bench_fixture.erl`, `scripts/coverage_bench.escript`.
* Документация: `README.md`, `docs/architecture.md`, `docs/coverage.md`,
  `docs/adr/0002-automatic-coverage.md` и этот validation record.

Оставшиеся ограничения явны: проверен только OTP 27.0; один worker и один
execution process; нет cleanup/attribution произвольных children; skipped syntax
требует permissive mode; нет arbitrary BEAM rewriting или других parse transforms;
существенный измеренный hook overhead; нет полного branch/CFG/state coverage
или VM/OS sandbox.
