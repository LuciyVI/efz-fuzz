# Coverage tracking EFZ: аудит и сравнение с AFL++

Дата: 15 сентября 2026. Проверяемый production snapshot:
[`205e18ba172d74bd6c652a68abfc73e02e4a1f86`](https://github.com/LuciyVI/efz-fuzz/commit/205e18ba172d74bd6c652a68abfc73e02e4a1f86).
Среда экспериментов: OTP 27 / ERTS 15.0, Linux x86_64, `+S 4:4`.
Production implementation не изменялась. Новые диагностические targets и runner
находятся в [coverage-audit-2026-09-15](coverage-audit-2026-09-15/).

Этот документ описывает указанный snapshot и default presence semantics.
Последующий opt-in прототип со счётчиками и его отдельные измерения описаны в
[hit-count experiment](hit-count-experiment.md); исторические результаты ниже
не являются описанием нового режима.

## 1. Executive conclusion

**RESULT B — AFL++-like feedback semantics implemented, different representation.**

Ответы на два разных вопроса:

* **Coverage feedback exists? YES.** Автоматические hooks записывают coverage
  конкретного execution; worker сравнивает его с accumulated coverage и добавляет
  успешные discoveries в настоящий corpus, доступный следующему scheduling.
* **AFL++-style bitmap/hit-count map exists? NO.** Нет byte-indexed trace bitmap,
  hit counters, buckets, `virgin_bits`, предыдущего edge или call-context hashing.

Корректное название текущей структуры: **execution coverage set / exact probe set**.
Можно говорить «разреженная карта присутствия probes», если явно оговорены set
semantics. Называть её bitmap или edge-hit-count map неправильно.

Представление EFZ не эквивалентно AFL++ по чувствительности feedback: **новый probe
обнаруживается; новая кратность старого probe и новая комбинация старых probes — нет**.
Идентификаторы относятся к source clause/outcome points, а не CFG edges.

Основания: [hook](../src/efz_cov_rt.erl#L43), [snapshot](../src/efz_cov.erl#L31),
[novelty](../src/efz_feedback.erl#L16), [retention](../src/efz_worker.erl#L122),
[scheduler](../src/efz_mutation_plan.erl#L54), независимые runtime experiments
в разделе 13 и реальный [parent-reuse integration test](../test/efz_feedback_loop_tests.erl).

## 2. AFL++ reference model

Reference зафиксирован на AFL++ `stable` commit
[`dbaf11913c1b2702dee5b4d3dcfffd52f1defe50`](https://github.com/AFLplusplus/AFLplusplus/commit/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50),
commit date 2026-09-02. AFL++ здесь не собирался и не запускался: сравнение выполнено
по официальному source. Это модель обычного coverage-guided режима; дополнительные
value-profile/CmpLog/path/sanitizer channels и crash-only mode не подменяют её.

```text
target execution
  → compiler/runtime instrumentation
  → edge/guard mapped to a numeric slot
  → byte hit counter in shared trace_bits
  → count classification
  → compare with virgin bits and clear newly observed feature bits
  → save_if_interesting / add_to_queue
  → clear current trace before next run
```

| Понятие | Смысл в reference |
|---|---|
| Edge coverage | Сведения о переходах control flow; способы размещения instrumentation зависят от compiler/backend. Это не просто множество строк source. |
| Bitmap slot | Числовая позиция в trace buffer. Slot не обязательно тождествен одному уникальному edge. |
| Hit counter | Обычно byte, обновляемый на каждом попадании; это не точное неограниченное число вызовов. |
| Count bucket | Класс значений counter. Новая bucket для известного slot может дать novelty. |
| Per-execution trace | `fsrv.trace_bits`, текущие наблюдения target в shared memory. |
| Virgin map | Биты ещё не наблюдавшихся bucket features; накопление логически хранится в обратном виде. |
| Novelty | Пересечение classified current bits с virgin bits. Новая slot и новая bucket старой slot различаются. |
| Reset | Очистка current trace между runs; virgin state при этом сохраняется. |
| Collisions | В hashed instrumentation несколько edges могут разделить slot и смешать counts. LTO и PCGUARD могут использовать непересекающиеся IDs. |
| Context | Обычная edge identity не включает call chain. Дополнительные instrumentation modes могут учитывать caller/context; это отдельная настройка. |

Историческая схема AFL использует индекс из `cur_location XOR prev_location`, а
`prev_location` обновляется с учётом текущей точки. Это **не универсальное описание
всех современных backend'ов AFL++**. Reference runtime PCGUARD обновляет
`__afl_area_ptr[*guard]`; LTO документирует уникальные IDs и требования к диапазонам
при нескольких instrumented libraries. [Историческая модель](https://aflplus.plus/docs/technical_details/),
[runtime PCGUARD](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/instrumentation/afl-compiler-rt.o.c#L2692),
[LTO](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/instrumentation/README.lto.md).

**Версионная деталь:** активная `count_class_lookup8` в выбранной ревизии имеет
следующие классы; традиционная таблица с отдельным классом для 3 оставлена в source
как `OLD` comment:

| Raw byte count | Classified bit |
|---|---:|
| 0 | 0 |
| 1 | 1 |
| 2–3 | 2 |
| 4–7 | 4 |
| 8–15 | 8 |
| 16–31 | 16 |
| 32–63 | 32 |
| 64–127 | 64 |
| 128–255 | 128 |

`classify_counts` выполняет преобразование byte counts, а `discover_word`
проверяет `current & virgin` и применяет `virgin &= ~current`. `has_new_bits`
возвращает 0 без novelty, 1 при новой count-class известной slot, 2 при новой slot.
Это не сохранение каждого уникального полного trace vector.
[Таблица и has_new_bits](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/src/afl-fuzz-bitmap.c#L46),
[classify_counts/discover_word](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/include/coverage-64.h#L77).

Byte counters могут переполняться. Показанный PCGUARD runtime использует NeverZero:
после 255 переходит к 1. Это **не saturation**. Режим thread-safe instrumentation
отдельный; обычный increment сам по себе не гарантирует точный count при конкуренции.
Shared-memory buffer может быть общим у instrumented threads/fork descendants,
но boundaries input требуют согласованного lifecycle target.
[Counters и thread safety](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/instrumentation/README.llvm.md#L200),
[mapping runtime](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/instrumentation/afl-compiler-rt.o.c).

Размер trace buffer фиксирован на время использования конкретной map, но его
ёмкость выбирается/согласуется с target. Неверно считать любой AFL++ map неизменно
64 KiB. Обычный forkserver path обнуляет `trace_bits` перед execution.
[Map resize и run/reset](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/src/afl-forkserver.c#L2410).

`save_if_interesting` добавляет кандидатов в queue. Crash/hang dedup использует
отдельные `virgin_crash`/`virgin_tmout` после упрощения trace, которое убирает counts;
это отличается от обычной successful queue novelty.
[Queue и crash/hang paths](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/src/afl-fuzz-bitmap.c).

## 3. Actual EFZ coverage architecture

Фактический default staged/prepared path:

```text
efz_cli:launch/1 → efz:start/1
  → supervisor:start_child/2 (efz_sup) → efz_fuzzer:start_link/1
  → efz_config:prepare/1
  → efz_instrument:preflight/1 → efz_cov_integrity:pin/2
  → efz_fuzzer:init/1 → efz_corpus:start_link/4
  → efz_worker_sup:start_link/1 → efz_worker:start_link/1
  → efz_worker:init/1
       efz_cov_manifest:prepare/2       % campaign allowlist, not current coverage
       efz_feedback:new/1               % empty accumulated successful probe set
  → efz_worker:staged_iteration/1
  → efz_corpus:mutation_entries/0
  → efz_mutation_plan:next/2
       → attempts/6 → efz_mutation:apply_operation/3
  ← {candidate, Binary, Provenance, NextPlan}
  → efz_recipe:make/4
  → efz_worker:execute/4 → execute_checked/4
  → efz_executor:run/4 → run_checked/4 → run_pinned/4
  → spawn_monitor guardian → efz_guardian:run/6 → start/6
       efz_cov:open/1; efz_cov_integrity:open/2
       coordinator = efz_executor:coordinate/1
       root = efz_guardian:admit/2
  → root: efz_cov:attach/1 → efz_executor:invoke/4
  → HarnessModule:run(Binary) → selected instrumented functions
  → efz_cov_rt:hit({Module, BuildId, ProbeId})
       → publish/2 → insert/4 → ets:insert_new/2
  → guardian cleanup + process DOWN + trace barriers
  → efz_guardian:finish/2
       → efz_executor:coverage/3 → efz_cov:snapshot/1
       → efz_cov_manifest:validate_prepared/3
       → efz_cov:close/1
  ← execution result; efz_executor waits for guardian DOWN
  → efz_worker:execute_result/6 → efz_feedback:evaluate/3
  → efz_worker:retain/2 → efz_corpus:add/2
  → accepted/5; worker stores next feedback state; self() ! iterate
  → next efz_corpus:mutation_entries/0 includes the retained input
```

Source anchors: [worker](../src/efz_worker.erl#L47), [planner](../src/efz_mutation_plan.erl#L54),
[executor](../src/efz_executor.erl#L11), [guardian](../src/efz_guardian.erl#L33).
Random mode использует `efz_corpus:select/0 → Mu:mutate/2`, затем тот же execution,
coverage и feedback path. `coverage_validation => per_execution` вызывает
`validate_observed/3` вместо prepared membership. Новый engine для эксперимента не создавался.

Ключевые сообщения между процессами:

| Сообщение | Отправитель → получатель | Значение |
|---|---|---|
| `{coordinate,Root,Context}` / `{coordinator_ready,Coordinator}` | guardian ↔ coordinator | Установить root monitor перед стартом кода |
| `{start_owned,Capability}` | guardian/helper → target | Открыть gate после регистрации ownership |
| `{target_result,Ref,Root,Outcome}` | root → coordinator | Return/exception классификация |
| `{coordinator_done,Coordinator,Outcome}` | coordinator → guardian | Перейти к cleanup |
| `{efz_cov_observed,Ref,Identity}` | первый insert hook → guardian | Независимое свидетельство первого hit |
| `{efz_cov_failure,Ref,Reason}` | integrity/hook → guardian | Ошибка observation не должна исчезнуть при caught exception |
| `DOWN`, `trace_delivered` | runtime → guardian | Подтверждение termination и обработки trace |
| `{Request,Guardian,Result}` | guardian → executor caller | Готовый snapshot и lifecycle status |
| `gen_server:call(...,{add,Binary,Meta},infinity)` | worker → corpus | Подтверждённая вставка entry |

Аргументы input — `binary()`. `Provenance`/`Recipe` содержат primary bytes/hash,
parent ID, операции и output hash. `Result` — map с `outcome`, `coverage` (list of
identities), `coverage_status`, `coverage_observation`, `builds`, `cleanup`.
В global set передаётся coverage list; сами bytes остаются у worker/corpus.

## 4. Coverage data structures

| State | Физическое представление | Owner / lifetime |
|---|---|---|
| Per-execution hits | Неназванная public ETS `set`, internal name `efz_execution_coverage` | Guardian; один execution до snapshot/close |
| Target context | Process dictionary key `'$efz_execution_context'` → context tuple | Root/controlled child; до смерти процесса |
| Independent observation evidence | Guardian state `observed_probes => sets:set()` | Тот же execution; первый hit каждой identity |
| Attachment/integrity registry | Named protected ETS `efz_coverage_observers`, `{Pid,Context}`, `{identities,Pins}` | Guardian; одна одновременно активная execution в VM |
| Allowed coverage identities | Protected ETS `efz_coverage_plan` | Worker; campaign, до release/смерти owner |
| Successful global coverage | `S.feedback.global`, Erlang `sets:set()` | Worker; campaign |
| Campaign diagnostics | `coverage_seen`, empty/broken/unstarted counts | Worker; campaign; **не** novelty state |
| Dirty marker | `persistent_term` `{efz_guardian,dirty_runner}` | VM; **не** coverage map |
| Persistence | Source manifests; historical metadata в corpus/crash/report | Файловая система; не per-execution trace buffer |

Точный context и row format:

```erlang
{efz_context, 1, ExecutionRef, Table, GuardianPid}
{efz_context, 1, ExecutionRef, {ets_member, Table}, GuardianPid}

%% Complete ETS object: one-element tuple.
{{probe, {Module, BuildId, ProbeId}}}
%% Its ETS key (default keypos = 1):
{probe, {Module, BuildId, ProbeId}}
```

Один row означает присутствие одного exact probe. Value/counter отдельным полем
не хранится. Fixed-size slot space, binary bitmap, shared-memory byte array,
`counters`/`atomics` coverage backend отсутствуют. `ProbeId` — numeric ID внутри
tuple key, но не индекс массива. ETS сам разрешает внутренние hash collisions
сравнением ключей; он не объединяет разные identities в один coverage bit.
[open/attach/snapshot](../src/efz_cov.erl), [insert](../src/efz_cov_rt.erl#L43).

В **проверенном OTP 27** `sets:new()` возвращает version-1 tuple `{set,...}` с
hash segments, а не native map. EFZ использует API `sets`, не зависит от private
layout. Нельзя считать слово `map` в `S.feedback` доказательством bitmap:
это обычная Erlang map, внутри которой находится set.

Prepared table содержит `{Identity}` и служебные `{'$efz_plan',{Mode,Builds}}`,
`{'$efz_identities',PinsResult}`. Она знает все разрешённые probes, включая ни разу
не исполненные. Это **validation allowlist**, не accumulated coverage.
[make_plan/2](../src/efz_cov_manifest.erl#L60).

## 5. Probe identity

Единица — **source clause/outcome probe**, manifest metric `clause_outcome_probe`.
`efz_instrument_pt:body/5` помещает hook в начало тела после выбора clause.
Фактические виды: `function_clause`, `case_clause`, `if_clause`, `receive_clause`,
`receive_after`, `try_body`, `try_of_clause`, `catch_clause`, `try_after`,
`fun_clause`, `named_fun_clause`. Guards/patterns отдельно не инструментируются;
short-circuit operands не получают автоматически самостоятельных true/false probes.
Таким образом, это не полное branch coverage и не instrumentation всех BEAM basic blocks.
[body/probe](../src/efz_instrument_pt.erl#L106), [AST traversal](../src/efz_instrument_pt.erl#L129).

Identity: `{Module :: atom(), BuildId :: binary(32), ProbeId :: pos_integer()}`.
Transform начинает `next => 1` и выдаёт ID по порядку обхода AST, увеличивая `next`
для каждой точки. Hook содержит эту тройку как compile-time literal.
Manifest сопоставляет ID с module/function/arity, kind, source_file, line/column
и structural_location. Line — metadata, **не ключ покрытия**.

BuildId вычисляется SHA-256 от `{1, OTPRelease, CompilerModuleMd5, CanonicalForms,
IdentityOptions}`. Paths внутри `source_root` нормализуются относительно root.
Другой module имеет отдельный namespace; другая build identity также отдельная.
Manifest validation отвергает повторяющиеся IDs и structural paths.
[Build computation](../src/efz_instrument_pt.erl#L36), [validation](../src/efz_cov_manifest.erl#L4).

Стабильность: executions одной сборки используют одинаковую identity; одинаковые
canonical source/options/toolchain дают воспроизводимые IDs в проверенной среде.
Перестановка/добавление AST points может сдвинуть числовые IDs, а изменение source,
annotations/options/toolchain может изменить BuildId. Это не обещание стабильных
IDs при произвольном редактировании или смене OTP. Тесты `determinism/1`,
`build_options/0` и fresh replay проверяют конкретные границы.

Ограничение identity contract: первая константа `1` — версия схемы, содержимое
самого transform автоматически в BuildId не хэшируется. Изменение semantics
instrumentation требует осознанного version bump. Pinning BEAM/attributes/harness
добавляет независимую проверку текущего кода. SHA-256 collision теоретически
возможна, но это не штатная slot compression, как в hashed bitmap.

**EFZ ProbeId не эквивалентен AFL++ edge/slot index.** Он обозначает AST point
в module/build namespace. Нет `(previous,current)` tuple, XOR slot mapping,
call-stack/caller contribution. `ExecutionRef` из context отвечает за lifetime,
а не за context-sensitive feature identity.

## 6. Per-execution lifecycle

1. `efz_executor:run_pinned/4` создаёт независимый monitored guardian.
2. Guardian проверяет pinned modules, создаёт fresh ETS через `efz_cov:open/1`
   и fresh execution reference. Он же — ETS owner, не root/coordinator.
3. `admit/2` регистрирует root/child до открытия gate; затем `attach/1` кладёт
   ссылку на общую таблицу этого case в process dictionary.
4. Hook проверяет expected context по внешней registry и выполняет insert/member.
5. После root outcome, timeout либо caller/coordinator DOWN guardian завершает
   root, descendants и coordinator, ждёт monitors и trace delivery barriers.
6. `finish/2` проверяет identities, делает snapshot/allowlist validation, сверяет
   независимые observed probes и attachment. Затем закрывает ETS/registry/trace.
7. Result отправляется worker; caller ждёт ещё и guardian DOWN. Feedback получает
   самостоятельный coverage list уже после закрытия per-execution таблицы.
8. Следующий case создаёт новую таблицу/reference; явного memset/reset bitmap нет.

[Guardian start/admit/loop](../src/efz_guardian.erl#L33),
[finish](../src/efz_guardian.erl#L163), [executor result protocol](../src/efz_executor.erl#L33).

Crash root не уничтожает coverage table: owner — guardian. Timeout оставляет
доступными probes, записанные до kill. Coordinator failure даёт infrastructure
outcome; snapshot может содержать реальные hits, но они не идут в global coverage.
Caller death запускает cleanup, хотя некому возвращать result. При потере guardian
нельзя объявлять cleanup подтверждённым: executor маркирует runner dirty и запрещает
reuse; поздний guardian failure сохраняет первичную infrastructure cause.

**Внутри supported model hits предыдущего input не переходят в следующий.**
Это подтверждено distinct contexts, отсутствием ETS после результата и A→B→A.
Закрытый старый context не перенаправляется на новую таблицу.
Однако изменение VM-global состояния target способно изменить *поведение*
следующего input: это отдельный источник недетерминизма, не смешение coverage maps.
Persistent term/env changes диагностируются; записи в чужую существующую ETS,
внешние services и произвольные background processes не полностью изолированы.
Это cooperative runner, не security sandbox. [Политика](execution-isolation.md).

Low-level/manual API не имеет сам по себе всех гарантий guardian. `reset_local/0`
не обнуляет reused global bitmap: создаёт context либо отказывает, если context
уже attached. `snapshot/0` и `{manual,Id}` — compatibility surface; automatic
campaign использует `snapshot/1` и запрещает manual identities в automatic allowlist.

## 7. Global coverage

Authoritative state:

```erlang
%% efz_worker state
#{feedback => #{builds => Builds, global => GlobalSet}}

%% efz_feedback:evaluate/3, valid successful outcome
New = lists:sort(sets:to_list(
    sets:subtract(sets:from_list(Observed), Global))),
NextGlobal = efz_cov:merge(Global, Observed).
%% efz_cov:merge/2 = sets:union(Global, sets:from_list(Observed))
```

То есть формула `New = Current − Global`, `Global' = Global ∪ Current`
**действительно реализована**, для exact identities и только при подходящем outcome.
[evaluate/3](../src/efz_feedback.erl#L16).

| Execution | Global меняется? | Decision / retention |
|---|---|---|
| Успешная mutation, coverage valid | Union с current | `new_coverage` при непустом delta; иначе `equivalent_coverage` |
| Успешная calibration | Union с current | Всегда `seed_calibration`; seed уже в corpus |
| `error` / `throw` / `exit` / external root kill | Нет | `target_failure`, `new_probes => []`; отдельный crash path |
| Timeout | Нет | `target_failure`; timeout artifact/count |
| Infrastructure / invalid coverage / build mismatch | Нет | `{error,Reason}`, остановка campaign |
| Valid zero-hit success | Union с пустым множеством | Не discovery; observation отличается от broken coverage |

Обычное return value `{error,invalid_input}` всё ещё является successful execution:
executor оборачивает его в `{ok,Value}`. Исключение и term-return — разные вещи.

`coverage_seen`/`coverage_diagnostics` включают observation information и от failures;
их нельзя отождествлять с successful global set. Strict policy отказывает campaign,
если probes не наблюдались вообще; это не новый novelty criterion.

Global принадлежит одному worker и не восстанавливается при restart. Durable
corpus восстанавливает bytes/history, потом worker повторно calibrates inputs и
создаёт новое accumulated coverage. Filesystem failure при retention прекращает
campaign; `accepted/5` не подтверждает новый feedback state до успешного retain.

## 8. Hit-count analysis

`efz_cov_rt:insert/4` вызывает `ets:insert_new(Table,{{probe,Id}})`:
первый hit добавляет row и посылает guardian notification; повторный возвращает
`false` и не меняет row. `ets_member` сначала проверяет membership, но итоговая
вставка тоже atomic `insert_new`. Конкурирующие controlled children могут
одновременно увидеть отсутствие row; только один insert будет новым.

Поиск по production source:

```sh
rg -n 'counter|count_class|bucket|bitmap|update_counter|atomics|counters:|array:|prev_loc|edge' src
```

Совпадения `counter` относятся к **crash occurrence storage**, не к probe hits.
Ни integer/saturating/8-bit hit counter, ни lookup bucket table, ни frequency-aware
coverage feature в production path не найдены. Compile-time `next` в transform
считает созданные probe IDs; statistics считают executions/discoveries — это другие счётчики.

| Число вызовов одного x/0 | EFZ row count | Snapshot | Может дать count-only novelty после первого hit? |
|---:|---:|---|---|
| 1 | 1 | `{X}` | Первый X может дать novelty |
| 2 | 1 | `{X}` | Нет |
| 3 | 1 | `{X}` | Нет |
| 8 | 1 | `{X}` | Нет |
| 10 | 1 | `{X}` | Нет |
| 1000 | 1 | `{X}` | Нет |

Это проверено **автоматическими hooks**, не ручным `efz_cov:hit/1`. У target есть
отдельный diagnostic invocation counter в собственной process dictionary, чтобы
подтвердить, что цикл действительно выполнил 1000 вызовов. Он не участвует в EFZ
coverage. Per-execution coverage counter не может переполниться, потому что его нет.

## 9. Novelty semantics

Ниже речь об успешной mutation с valid coverage. В AFL++ A/B/C означают slots/features
без collisions; где counts не заданы, считаем их buckets неизменными.

| Scenario | EFZ `new_probes` | EFZ result | AFL++ coverage-only reference |
|---|---|---|---|
| A: current `{A,B}`, global `{}` | `{A,B}` | `new_coverage`, union `{A,B}`, retain | Новые slots, novelty class 2 |
| B: current `{A,B}`, global `{A,B}` | `{}` | `equivalent_coverage`, без retain | 0 при прежних buckets |
| C: current `{A,B,C}`, global `{A,B}` | `{C}` | `new_coverage`, retain, union `{A,B,C}` | Новая slot C, class 2 |
| D: известный A выполнен 100 раз | `{}` | Count сам по себе не interesting | Может дать class 1, если соответствующая bucket ранее не наблюдалась |
| E: новая комбинация только известных points | `{}` | Не new coverage | Само сочетание известных slot/bucket features не novel; новые edges или counts могут изменить результат |

Set также теряет порядок: `AB` и `BA` одинаковы, если instrumentation дала те же
points. У AFL++ изменение порядка *basic blocks* может означать новые **edges**;
это отличается от перестановки уже известных edge features. Не следует приписывать
AFL++ полную уникальность execution signatures только из-за сохранения trace hash
для calibration/scheduling.

## 10. Corpus feedback integration

`efz_worker:execute_result/6 → efz_feedback:evaluate/3 → retain/2` вызывает
`efz_corpus:add(Input,Meta)` **только** для `new_coverage`.
`efz_corpus:add_checked/3` сравнивает bytes с entries, сохраняет durable record,
если store включён, затем добавляет `#{id,input,metadata,added_at}` в список entries.
Следующий `mutation_entries/0` возвращает compact `#{id,input}` и для нового entry.
Planner читает настоящий актуальный corpus, ведёт per-content cursors и при росте
corpus сбрасывает прежние idle observations. Donor candidates также берутся оттуда.
[Worker retain](../src/efz_worker.erl#L122), [corpus](../src/efz_corpus.erl#L36),
[growing scheduler](../src/efz_mutation_plan.erl#L54).

Это не telemetry-only pipeline. `efz_feedback_loop_tests:feedback_loop/0` выполняет
реальный campaign со staged dictionary operators, tokens только A/B/C:

```text
ID 1: <<>>
  → ID 2: <<"A">>,   parent 1
  → ID 3: <<"AB">>,  parent 2
  → ID 4: <<"ABC">>, parent 3
```

Тест проверяет новые реальные probes, input delivery по execution ref, primary
bytes/hash в recipe и fresh-VM replay. В этом запуске **30 mutation executions,
31 harness delivery, 3 discoveries**. Scripted mutator не используется.
Дополнительный audit experiment также передаёт retained AB настоящему planner и
проверяет `parent => 2, primary => <<"AB">>`.

Новая entry не обязана быть самой следующей: planner завершает текущий snapshot
round. Это scheduling fairness, а не разрыв feedback loop.

## 11. Cross-process limitations

| Вариант | Coverage | Lifecycle/допуск |
|---|---|---|
| Root calls instrumented function | Пишет в execution ETS | Supported |
| `efz_target:spawn/1` | Context автоматически attached до пользовательского кода; общий exact set | Supported; guardian ждёт cleanup |
| `efz_target:spawn_link/1` | То же | Supported; link не определяет coverage identity |
| Nested controlled child | То же, через тот же guardian | Supported в пределах admission limit |
| Обычный `erlang:spawn` | Context автоматически не наследуется | Tracing обнаруживает uncontrolled spawn; infrastructure/dirty runner |
| Уже существующий background process | Обычно нет attached context, hook inactive | Вне supported execution scope |
| Ручной `efz_cov:attach/1` в произвольном child | Сам по себе не даёт lifecycle ownership | Не делает ordinary spawn поддержанным |

Таким образом, **ручной attach пользователю controlled API не нужен**. Но coverage
не распространяется автоматически на любой Erlang process. Обычная process
dictionary не наследуется при spawn; native instrumented hook вне admitted process
с отсутствующим context остаётся inactive. [Target API](../src/efz_target.erl),
[admission](../src/efz_guardian.erl#L51), [uncontrolled detection](../src/efz_guardian.erl#L143).

Unlinked child exception сам по себе не определяет итог root: harness должен
дождаться child и выразить его результат. Probes controlled child входят в snapshot
до cleanup; root outcome определяет, допускается ли этот snapshot к successful feedback.
Общий ETS не создаёт ни caller-sensitive, ни PID-sensitive coverage features.

## 12. EFZ vs AFL++ matrix

`YES` означает одинаковое наличие конкретного свойства, не binary compatibility.
`FUNCTIONALLY SIMILAR` означает одинаковую роль с другой реализацией.

| Механизм | AFL++ | EFZ | Эквивалентность |
|---|---|---|---|
| Instrumentation | Compiler/runtime hooks | Erlang parse transform + runtime hook | FUNCTIONALLY SIMILAR |
| Coverage granularity | Обычно CFG edges; зависит от mode | AST clauses/selected outcomes | PARTIAL |
| Per-execution coverage | Shared byte trace array | Fresh public ETS exact set | FUNCTIONALLY SIMILAR |
| Fixed-size bitmap | Allocated numeric slot buffer | Отсутствует | NO |
| Coverage slot | Numeric index | Exact tuple ETS key | NO |
| Edge ID | Edge/guard identity согласно mode | Source point, нет previous/current edge | NO |
| Hit counter | Byte increments, mode-specific overflow policy | Отсутствует | NO |
| Count buckets | Classified counter classes | Отсутствуют | NO |
| Global/virgin state | Ненаблюдавшиеся feature bits | Наблюдавшиеся successful probe identities | FUNCTIONALLY SIMILAR |
| New coverage detection | Новая slot либо bucket | Только новая probe identity | PARTIAL |
| Reset between executions | Clear/reinitialize trace | Destroy ETS, allocate new context/table | FUNCTIONALLY SIMILAR |
| Collision behavior | Hashed modes collide; LTO/PCGUARD могут быть exact | Нет slot aliasing; exact keys | PARTIAL |
| Crash coverage | Trace + separate crash/hang novelty maps | Snapshot сохраняется, dedup по нормализованной crash signature | PARTIAL |
| Corpus feedback | Novelty → queue → дальнейшие mutations | Novelty → corpus → scheduler → mutations | YES |
| Build identity | Slots связаны с instrumented binary/mapping; нет BuildId в каждом byte | Module + BuildId в каждой identity, pinned harness/BEAM | NO |
| Cross-process coverage | Shared mapping у участвующих instrumented processes/threads | Один ETS у root + controlled descendants | PARTIAL |

Матрица использует source references раздела 2 и фактические EFZ paths разделов 3–11.
`NO` в Build identity не означает, что AFL++ вообще лишён проверок target: речь
именно о встроенном namespace каждого coverage element.

## 13. Runtime experiments

Воспроизведение из корня EFZ:

```sh
ERL_FLAGS='+S 4:4' rebar3 compile
escript docs/coverage-audit-2026-09-15/run.escript
ERL_FLAGS='+S 4:4' rebar3 eunit
ERL_FLAGS='+S 4:4' rebar3 ct
ERL_FLAGS='+S 4:4' rebar3 xref
ERL_FLAGS='+S 4:4' rebar3 dialyzer
```

[Sites](coverage-audit-2026-09-15/efz_cov_audit_sites.erl) компилируются настоящим
`efz_instrument:compile/2`. [Harness](coverage-audit-2026-09-15/efz_cov_audit_harness.erl)
компилируется обычным compiler. Это намеренно исключает probes dispatch/loop control:
иначе LOOP1/LOOP10 могли бы различаться новым probe другой loop clause, что было бы
ложным доказательством count sensitivity.

[Runner](coverage-audit-2026-09-15/run.escript) использует настоящие executor,
prepared validation, feedback и corpus. Для проверки algebra inputs задаются
диагностическим драйвером; это **не утверждение, что их сгенерировал mutator**.
Настоящий mutation→execution→parent reuse отдельно доказывает production campaign
из `efz_feedback_loop_tests`. Никакой mock coverage/corpus и custom mutator не добавлены.

Identity map данного target: A=probe 1, B=2, C=3, X=4; у всех одна module/build пара.
Первые два diagnostic corpus entries: initial empty ID 1 и retained AB ID 2.

| Input по порядку | Current probes | New probes | Retention reason | Global после | Corpus size |
|---|---|---|---|---|---:|
| AB | A,B | A,B | new_coverage | A,B | 2 |
| AB повтор | A,B | — | equivalent_coverage | A,B | 2 |
| ABC | A,B,C | C | new_coverage | A,B,C | 3 |
| BA | A,B | — | equivalent_coverage | A,B,C | 3 |
| AC | A,C | — | equivalent_coverage | A,B,C | 3 |
| LOOP1 | X | X | new_coverage | A,B,C,X | 4 |
| LOOP2 | X | — | equivalent_coverage | A,B,C,X | 4 |
| LOOP3 | X | — | equivalent_coverage | A,B,C,X | 4 |
| LOOP8 | X | — | equivalent_coverage | A,B,C,X | 4 |
| LOOP10 | X | — | equivalent_coverage | A,B,C,X | 4 |
| LOOP1000 | X | — | equivalent_coverage | A,B,C,X | 4 |

Одинаковые результаты получены для `ets` и `ets_member`. В каждом LOOP raw ETS
содержал **один object**, diagnostic x-call count соответствовал 1/2/3/8/10/1000,
snapshot оставался `{X}`. Память этой ETS — 324 machine words при каждом из этих
inputs (2592 bytes при wordsize 8), включая table overhead, без guardian/registry/
plan/result heaps. Для 2 и 3 probes наблюдались 343 и 362 words. Это локальный
storage sample, не throughput benchmark и не универсальная формула расхода памяти.

Дополнительно assertions проверили:

* все contexts серии различаются, owner — guardian, ETS закрыта после результата;
* A→B→A: exact coverage первого и третьего runs совпадает, B не содержит A;
* genuine zero-hit success → `valid_empty_coverage`;
* calibration A обновляет global, reason остаётся `seed_calibration`;
* crash и timeout после X сохраняют `{X}`, feedback не меняет пустой global;
* erase context + caught hook exception → infrastructure, feedback отклоняет;
* child/linked/nested: один C probe, общий context, соответственно 2/2/3 известных
  процессов, все уже мертвы при получении result;
* ordinary spawn в отдельной VM: coverage пустое, infrastructure/dirty-runner,
  два известных процесса завершены, следующий input не запускается;
* retained AB реально выбран `efz_mutation_plan:next/2` с parent ID 2.

Сырые runtime records и command logs: `_build/coverage-audit-2026-09-15/`.
Компактные сохранённые результаты: [results.txt](coverage-audit-2026-09-15/results.txt),
[validation.json](coverage-audit-2026-09-15/validation.json).

Результаты проверок: compile — exit 0; EUnit — **186 passed**, exit 0;
Common Test — **3 passed**, exit 0; xref и dialyzer — exit 0.
Новые audit assertions выполнены отдельно, они не увеличивают число EUnit cases.
SHA-256 всех production source files сверены до/после; изменений нет.

Весь suite проверяет также paths, не дублируемые новым experiment:

| Test | Проверяемая часть |
|---|---|
| `efz_phase2_tests` | AST semantics, manifest identities, repeatability, separate contexts, exceptions/timeouts, compiler options |
| `efz_backend_tests` | Backend equivalence, prepared/per-execution validation, lifecycle и broken observations |
| `efz_integrity_tests` | Hot reload plain/different builds, pinned harness, lost/context corruption, caught exceptions, legitimate empty coverage |
| `efz_isolation_tests` | Caller/coordinator death, descendants during timeout, nested scope, dirty state и guardian failure |
| `efz_crash_retention_tests` | Late guardian failure сохраняет первичную infrastructure cause |
| `efz_feedback_loop_tests` | Real staged discovery→retain→parent reuse и fresh replay |
| `efz_durable_tests` | Discovery восстанавливается в другой VM, recalibrates и становится parent |
| `efz_coverage_SUITE` | Automatic campaign, crash и timeout observations |

## 14. Final classification

**RESULT B — AFL++-like feedback semantics implemented, different representation.**

Доказаны все звенья: automatic instrumentation → execution-owned observations →
validated snapshot → worker global set → exact novelty delta → real corpus insert →
future mutation parent. Поэтому результаты C/D не описывают текущий EFZ.

Результат A исключён: физическая trace структура — ETS set, а hit multiplicity
теряется уже в `insert_new/2`. Добавление имени «bitmap» в документацию этого не
изменит. Результат B описывает общую архитектуру feedback, **не равную AFL++ мощность
наблюдения edges/counts/context**.

## 15. Recommended next step

**Переписывать текущую систему ради сходства с AFL++ не нужно.** Сначала следует
разделить три независимых изменения: (1) representation, (2) count sensitivity,
(3) granularity edge/context. Dense buffer сам по себе не создаёт ни edges, ни buckets.

| Аспект | Вывод для EFZ |
|---|---|
| Lookup/update speed | ETS даёт hashed lookup/atomic insert, но каждый hit также проверяет registry/context. Benchmark должен отдельно измерить hook, integrity tracing и полный executor. Ускорение bitmap нельзя предполагать по названию. |
| Memory usage | Sparse set растёт с количеством hits, но имеет overhead таблицы/tuple rows и дублирование evidence. Dense buffer занимает память по общему диапазону slots, включая неисполненные. |
| Number of probes | При большом total N и малом hit K sparse может быть выгоден; при dense coverage компактый numeric representation может выиграть. Нужны workloads с разными N/K. |
| ETS overhead | Можно сначала оценить compact exact keys/lookup mapping, сохраняя presence semantics. Snapshot сейчас делает tab2list + sort и copies term data. |
| Hit-count sensitivity | Полезная самостоятельная опция для loops. Её можно прототипировать exact counters без hash collisions и без полного bitmap rewrite. |
| Collisions | Вводить modulo/hash aliasing без доказанной необходимости — потерять нынешнюю точность. Предпочтителен collision-free dense index prepared manifest. |
| Deterministic identity | Публичный `{M,Build,Probe}` следует сохранить; numeric slot должен быть внутренним отображением выбранного набора builds. |
| Parallel workers | Текущая VM допускает один execution. Изменение storage не исправляет singleton registry/guardian и общую state-isolation модель. |
| Distributed fuzzing | Сначала независимые VM, versioned identity/metric и обмен raw inputs с локальной calibration. Не объединять произвольные slot maps разных builds. |
| Corpus compatibility | Bytes reusable; old `new_probes` остаются historical presence metadata. Bucket discoveries требуют отдельной версии metric/schema, не тихой переинтерпретации старых records. |
| Replay | Recipe восстанавливает bytes независимо от storage. Проверки pinned build/harness сохраняются; replay coverage expectations должны знать metric/version. |
| Backward compatibility | Presence backend оставить default/reference; новый режим opt-in. Differential tests должны сохранять старые outcomes/identities. |

Минимальная **предлагаемая**, не реализованная архитектура при подтверждённой нужде:

```text
existing instrumentation → {Module,BuildId,ProbeId}
  → immutable prepared exact identity↔dense-slot mapping
  → execution-owned counter array / exact sparse counter backend
  → explicit saturating/overflow policy
  → versioned bucket classification
  → novelty of (ProbeIdentity,Bucket) against campaign global features
  → existing feedback retention path → existing corpus/scheduler
```

Для сравнений качества можно сохранить compatibility `coverage => [Identity]`
и добавить отдельные `coverage_features` / `new_features`; count-only discovery
не должен ложно сообщать новый source probe. Новый snapshot должен сохранять
guardian lifetime, atomic updates controlled children, integrity checks, cleanup,
build validation и правильный reset. Общая shared persistent bitmap без scoped owner
нарушит уже доказанные гарантии.

Без переписывания сохраняются `efz_mutation`, `efz_mutation_plan`, raw input/recipe
regeneration, corpus selection и большая часть `efz_worker`, `efz_executor`,
`efz_guardian`, `efz_instrument_pt`. Изменения сосредоточатся в `efz_cov`,
`efz_cov_rt`, prepared mapping/validation, `efz_feedback`, config и versioned
metadata в corpus/crash/replay. Coverage integrity evidence придётся адаптировать
к counters: нынешнее множество первых observations не подтверждает точность counts.

Acceptance следующего experiment: presence mode даёт прежние результаты; count
mode сохраняет LOOP1 и затем LOOP10 при новой bucket; same-bucket repetitions не
retained; A→B→A остаётся чистым; controlled concurrent increments не теряются;
crash/timeout cleanup не повреждает snapshot; build/metric mismatch отвергается.
Решение о production bitmap — после измерений end-to-end cost и числа полезных
discoveries на реальных targets, а не только скорости отдельного массива.
