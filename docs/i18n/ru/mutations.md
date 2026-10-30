# Нативные staged mutations (engine version 1)

[English](../../mutations.md) · **Русский** · [Español](../es/mutations.md) · [简体中文](../zh-CN/mutations.md) · [Все языки](../README.md)

Staged mutation включается явно. Существующие кампании по-прежнему используют
`efz_mutator_random` и его behaviour `mutate/2`. Coverage defaults остаются
prepared validation и исходный ETS hook; `coverage_backend => ets_member`
по-прежнему доступен. Ни один mutation mode не меняет probe identities,
exception handling, seed calibration или политику объединения только successful
coverage.

```erlang
{ok, Artifact} = efz_instrument:compile("examples/staged/efz_staged_parser.erl",
    #{modules => [efz_staged_parser], source_root => ".",
      outdir => "_build/my-staged-target"}),
{ok, _} = efz:start(#{target => efz_staged_parser, artifacts => [Artifact],
    seeds => [<<0>>], mutation_mode => staged, max_iterations => 200,
    max_input_bytes => 64,
    mutation => #{seed => {17,23,41},
        dictionary => [<<"TOKEN">>, <<"BOOM!">>],
        stages => [dictionary_insert,boundary,arithmetic,havoc,splice],
        max_block_bytes => 16, max_token_bytes => 16,
        attempts_per_visit => 8, havoc_depth => 4, random_retries => 4,
        max_idle_visits => 256, trace_limit => 0}}),
Report = efz:await(30000),
ok = efz:stop().
```

После `rebar3 compile` запустите `escript examples/staged/run.escript` для полной
сборки, кампании, сохранённого crash recipe и execution replay. Его dictionary
читается из `examples/staged/tokens.hex`, а не из inline option выше.

## Ответственности и состояние

* `efz_mutation:apply_operation/3` применяет concrete operation без random
  choices, corpus reads, clocks, coverage или process state. `apply_operations/3`
  применяет упорядоченную realized sequence к intermediate binaries.
* `efz_dictionary` разбирает/нормализует tokens один раз при configuration validation.
* `efz_mutation_plan` владеет explicit RNG state, lazy deterministic cursors и
  scheduling. Его `prepare/2` принимает mutation options и initial seed binaries;
  `new/1` принимает нормализованную configuration. Считайте returned state opaque.
* `efz_corpus:mutation_entries/0` предоставляет IDs и bytes в insertion order.
  `efz_worker` просит planner выдать candidate и вызывает **существующие** executor
  и feedback loop. Старый random mode сохраняет старый selector.
* `efz_recipe` упаковывает concrete operations и bytes для независимого
  regeneration и создаёт новые validated execution contexts для replay.
  См. [replay.md](replay.md).

Low-level planner interface — `next(State, Entries)`, где entries содержат `id`
и `input`. Он возвращает `{candidate, Binary, Provenance, NextState}`,
`{skip, Reason, NextState}`, `{done, Reason, NextState}` или
`{error, Reason, NextState}`. Inputs/configuration должны пройти validation;
поддерживаемого setter для изменения configuration активного state нет.
Ошибки planning/application — infrastructure failures, а не target crashes.

Configuration и dictionary заморожены в worker на весь lifecycle кампании.
Каждый cursor имеет ключ `{SHA256(SeedBytes), ConfigurationId}`. Initial entries
с одинаковым content разделяют deterministic work, даже если числовые corpus IDs
различны. New content получает новые cursors. Whole-campaign checkpoint format
отсутствует.

## Defaults и границы

`mutation_mode => random` — публичный default. Staged mode использует новый map
`mutation` и требует default setting `mutator`; пользовательский legacy callback
он отклоняет, а не игнорирует молча. Опции `mutation` в random mode — ошибка.
В staged mode отсутствующий `max_iterations` становится 1,000; явный `infinity`
отклоняется. Random mode сохраняет прежнюю budget semantics и не приобретает
staged limits неявно.

| Настройка planner (внутри `mutation`, кроме campaign `max_input_bytes`) | Default | Допустимая граница |
|---|---:|---:|
| `max_input_bytes` (производная от кампании; direct planner API также принимает её) | 4,096 | 0–1,048,576 |
| `max_block_bytes` | 128 | 1–65,536 |
| `max_token_bytes` | 128 | 1–65,536; actual tokens также соблюдают block limit |
| `max_tokens` | 256 | 0–4,096 |
| `max_dictionary_bytes` | 16,384 | 0–1,048,576 |
| `max_delta` | 8 | 1–128 |
| `attempts_per_visit` | 8 | 1–1,024 |
| `havoc_depth` | 8 | 1–32 |
| `random_retries` | 4 | 1–128 |
| `max_idle_visits` | 256 | 1–100,000 |
| `trace_limit` | 0 | 0–10,000 generated recipes |
| `prng` | `exsplus` | Только `exsplus` в engine v1 |
| `seed` | Генерируется один раз | Tuple из трёх integers, каждый 0–2^64−1 |
| `dictionary` | `[]` | Список непустых binary tokens |

Top-level staged `max_iterations` допускает 0–1,000,000 mutation target executions.
Принимается не более 4,096 initial seeds; каждый должен укладываться в input
limit. Oversized seeds не проходят validation и никогда не усекаются.
Calibration executions считаются отдельно, поэтому total target-execution bound —
seed count плюс `max_iterations`. Некорректные limits, stage names, повторные
stage names, unknown mutation options или unsupported algorithms дают ошибку
до target execution.

Havoc attempt может применить до `havoc_depth` constituent operations. Attempt
limit ограничивает candidate/stack attempts, а не отдельные stack operations;
поэтому per-visit work всё равно явно ограничена их произведением. Operation
planners проверяют available sizes до создания literal blocks. Primitive
operations проверяют final concatenation sizes до выделения candidate binaries.
Dictionary parsing и configuration work выполняются до mutation loop.

## Hex dictionaries EFZ

Inline tokens — binary literals, например `dictionary => [<<"TOKEN">>, <<0,255>>]`.
Альтернатива: задать `dictionary_file => "examples/staged/tokens.hex"` внутри
`mutation`. Можно передать обе options: normalized tokens будут объединены.
Path читается один раз при configuration; в report он заменяется normalized
bytes и их identity, позднейшие изменения файла не влияют.

**EFZ hex dictionary format** содержит один hex token чётной длины на строку:

```text
# TOKEN and the artificial crash token
544f4b454e
424f4f4d21

00ff
```

Допускается hex верхнего/нижнего регистра. Leading/trailing whitespace и CRLF
обрезаются; blank lines и trimmed lines, начинающиеся с `#`, игнорируются.
Inline comments, odd-length hex и nonhex bytes отклоняются с номером строки.
Это не AFL dictionary syntax; source code не исполняется, atoms не создаются.

Empty tokens inline отклоняются (blank file lines просто игнорируются).
Duplicates удаляются, tokens сортируются по binary term order. Normalization
проверяет token count и total bytes до deduplication каждого source; объединённые
normalized lists проверяются вновь до final deduplication. Token bytes должны
укладываться и в token, и в block limits. SHA-256 normalized token-list encoding
даёт dictionary identity независимо от original order/path. File reader также
накладывает physical byte bound
`2*max_dictionary_bytes + 128*max_tokens + 4096`, включая comments/whitespace.
Ни один token не усекается молча. Empty normalized dictionary допустим;
dictionary stages тогда завершаются либо сообщают `dictionary_unavailable` в
havoc.

## Scheduling и lazy enumeration

Default ordered stages:

```erlang
[bitflip,byteflip,arithmetic,boundary,
 dictionary_insert,dictionary_overwrite,havoc,splice]
```

Допускается любое непустое подмножество без duplicates в явно заданном порядке.
Нет automatic power schedule или learning. Scheduler фиксирует snapshot corpus
IDs в начале каждого round и посещает их в insertion order. New entries
присоединяются в следующем round, поэтому непрерывный рост не лишает старые
entries исполнения. Для каждой выбранной content identity stage lane
продвигается round-robin, **не более одного executed candidate на visit**.
Поэтому длинный deterministic sweep не блокирует другие entries или enabled
random stages.

Внутри deterministic visit skip/no-change продвигает cursor и повторяет попытку
до `attempts_per_visit`; полученный candidate завершает visit. Finished stages
остаются finished. Хранится лишь integer cursor на stage; candidate space
никогда не материализуется в list. Width/field/value tables — небольшие bounded
lists.

Стабильный порядок enumeration:

| Stage | Порядок |
|---|---|
| `bitflip` | Width 1, 2, 4 bits; затем каждый fitting bit offset по возрастанию |
| `byteflip` | Width 1, 2, 4 bytes; затем каждый fitting byte offset по возрастанию |
| `arithmetic` | Fields `(8,big)`, `(16,little)`, `(16,big)`, `(32,little)`, `(32,big)`; fitting byte offset; deltas `+1,-1,+2,-2,...,+max_delta,-max_delta` |
| `boundary` | Те же fields и offsets; девять boundary patterns ниже |
| `dictionary_insert` | Insertion boundary по возрастанию, затем normalized token order |
| `dictionary_overwrite` | Normalized token order, затем каждый fitting offset по возрастанию |

Progress означает получение candidate либо продвижение deterministic operation
cursor, включая no-op или size-limited operation. Оба сбрасывают idle counter и
учёт lanes, посещённых без progress. Visit unavailable/finished lane или
исчерпание random retries увеличивает idle. Такой visit возвращает `skip`;
worker планирует следующий visit, не расходуя target-execution budget.

Пока у любого deterministic cursor остаются operations в current corpus, idle
guard не может остановить planner. Когда вся finite work израсходована, есть
два разных stop conditions:

| Условие | Причина planner `done` | Campaign `status` |
|---|---|---|
| Все deterministic cursors exhausted, random stages не включены | `mutation_exhausted` | `{mutation_exhausted, mutation_exhausted}` |
| Random stages включены; idle budget достигнут **и** каждый content посетил каждую enabled lane после последнего progress | `idle_budget_exhausted` | `{mutation_stopped, idle_budget_exhausted}` |
| Нет corpus entries (low-level API) | `empty_corpus` | `{mutation_exhausted, empty_corpus}` |

Второе условие — progress guard, а не доказательство отсутствия теоретического
random candidate. `max_idle_visits` — минимальное число последовательных visits
без progress до возможной остановки guard; это не жёсткий cap на visits,
продвигающие finite cursors или нужные для полного lane sweep. Даже budget one
позволяет поздней productive lane работать. Например, с 256 one-byte seeds,
`[dictionary_overwrite,bitflip]` и token `<<"AB">>` за 256 unavailable overwrite
visits следуют bitflip candidates, а не преждевременное exhaustion.

Для fixed corpus finite cursors завершаются за конечное число bounded visits;
zero-count deterministic space останавливается сразу. Если затем random stages
остаются без progress, idle threshold и один full lane sweep ограничивают
remaining visits. Sweep bookkeeping хранит один count на content/configuration
identity, используя существующий cyclic lane order; mutations не перечисляются.
Добавление corpus entries сбрасывает idle/sweep accounting, поскольку new primary
inputs или donors меняют search space. Existing cursors, RNG state и pending
round сохраняются; возобновление с тем же corpus также сохраняет idle accounting.
Planner ожидает append-only entries, предоставляемые `efz_corpus`.

Worker всё ещё останавливается с `completed` на `max_iterations` target executions.
Empty binary candidates — обычные candidates, а не exhaustion sentinels.

## Точная семантика operations (operation version 1)

Все byte offsets zero-based. Для input размера `N` insertion boundaries —
`0..N`; fitting range — `0 <= Offset`, `Length >= 0`, `Offset + Length <= N`.
Offset `N` добавляет в конец; удаление `[0,N)` даёт `<<>>`. Primitive calls
принимают normalized limits и возвращают `{ok, Candidate}` только при изменении
bytes, иначе `{skip, Reason}` или `{error, Reason}`.

| Concrete operation | Значение и ограничения |
|---|---|
| `{flip_bits, Offset, Width}` | Bit 0 — старший бит byte 0. XOR ровно 1, 2 или 4 последовательных bits; range должен укладываться в `8*N`. Поддерживаются cross-byte flips. |
| `{invert_bytes, Offset, Length}` | XOR каждого byte с 255; length ровно 1, 2 или 4, range должен помещаться. |
| `{add, Offset, Width, Endian, Delta}` | Читать полное 8/16/32-bit unsigned field; `little` или `big`; записать `(Old + Delta) band ((1 bsl Width)-1)`. `abs(Delta) <= max_delta`. Delta zero — no-op. |
| `{set_integer, Offset, Width, Endian, Value}` | Записать точный unsigned bit pattern `0..2^Width-1` в fitting 8/16/32-bit field. Planner использует versioned boundary table, primitive принимает любой fitting pattern. |
| `{overwrite, Offset, Bytes}` | Заменить ровно `byte_size(Bytes)` fitting bytes без изменения размера. Literal length соблюдает block limit. |
| `{insert, Offset, Bytes}` | Вставить полные literal bytes на valid boundary. Без truncation. Empty source поддерживается. |
| `{delete, Offset, Length}` | Удалить непустой fitting range. Planner выбирает range не больше block limit; primitive допускает любое fitting nonempty deletion. |
| `{duplicate, Offset, Length, At}` | Скопировать непустой fitting source range, затем вставить на boundary в **исходном** input. Overlap допустим; length соблюдает block limit. |
| `{dictionary_insert, Offset, Token}` | Вставить полный непустой token с token/block/result-size limits. |
| `{dictionary_overwrite, Offset, Token}` | Заменить fitting token-sized range без изменения размера; те же limits. |
| `{splice, CutA, CutB, DonorBytes, DonorSHA256}` | `Primary[0:CutA] ++ Donor[CutB:DonorSize]`. Оба cuts — boundaries. Проверить donor hash и input bound до concatenation. Соблюдать final size. |

Для boundary width `W` пусть `H = 2^(W-1)`, `U = 2^W-1`. Порядок version 1:
`[0,1,2,H-2,H-1,H,H+1,U-1,U]`. Для восьми bits это
`[0,1,2,126,127,128,129,254,255]`. Это bit patterns, включая values около границ
signed interpretation; случайный signed overflow не используется.

Непомещающиеся fields/ranges дают skip с `insufficient_length`; partial field
не читается. Oversized resulting inputs/literals дают skip с `size_limit`.
Идентичный output или empty ordinary literal даёт skip с `no_change`; empty
dictionary tokens unavailable на primitive level и invalid на dictionary
configuration level. Malformed operations, invalid donor hashes, oversized source
inputs и deltas за configured bound — errors. Некоторые nonfitting offsets дают
skip, а не shape error; recipe regeneration отклоняет **оба** результата.
Все operators, требующие bytes, дают skip на empty inputs; literal/dictionary
insertion и подходящий splicing могут создавать candidates из empty inputs.

Donors берутся из existing corpus snapshot, исключая content, равный primary
seed. Различные donor contents deduplicate-ятся и сортируются по binary term
order до uniform choice. Duplicate queue entries не искажают donor choice.
One-content corpus сообщает `donor_unavailable`. Operation несёт donor bytes и
content hash, provenance — primary bytes/hash и corpus ID; replay никогда не
ищет donor queue index. Donor, равный current intermediate binary, также даёт
skip; cuts с unchanged output дают skip. Ни одна corpus entry не меняется.

## Havoc и воспроизводимость

Havoc равномерно выбирает depth в `1..havoc_depth`, затем равномерно одну из
11 operation families: bit flip, byte inversion, arithmetic, integer boundary,
overwrite, insert, delete, duplicate, dictionary insertion, dictionary overwrite,
splice. Это простое fixed weighting не заявляется оптимальным. Parameters каждой
operation выбираются по preceding intermediate result. Missing dictionary/donor
data и другие inapplicable choices расходуют stack slot вместо неограниченного
повтора operator.

Каждый attempted stack расходует depth draw (standalone splice имеет fixed
depth 1). Havoc расходует family draw на slot. Parameter draws расходуются в
code order; prerequisite failures возвращаются сразу, не выбирая unavailable
parameters. Всё consumed RNG state сохраняется при skips. На visit бывает не
более `min(attempts_per_visit, random_retries)` random candidate attempts.
Final binary, равный primary input, — no-op, даже если intermediate operations
меняли bytes. Повтор возможен в той же границе. В realized recipe появляются
лишь успешно изменившие данные constituent operations; skipped operations
не нужно replay-ить, поскольку intermediate bytes они не меняли.

Все новые choices используют `rand:seed_s(exsplus, Seed)` и `rand:uniform_s/2`;
implicit `rand:uniform()` в staged engine нет. Private state принадлежит planner
в worker. Target randomness, legacy corpus-selection randomness, logging и
stats не берут из него draws. Без `mutation.seed` 24 random bytes генерируют
три seed integers **один раз** при initialization; actual seed и algorithm
сообщаются в `Report.mutation` и recipes.

В проверенной среде OTP 27.0 воспроизведение choices требует engine version,
normalized configuration, algorithm/seed, initial corpus bytes/order и dictionary,
а также deterministic outcomes/retention. `Report.mutation_initial_corpus`
фиксирует ordered content hashes; corpus report сохраняет initial bytes.
Configuration identity — SHA-256 sorted normalized setting pairs, включая engine
version, seed и dictionary identity. `trace_limit` исключён как observational.
Изменение configuration/dictionary требует новой кампании. Internal rand state,
содержащий handlers, не пишется в recipes. Cross-OTP PRNG compatibility не
обещается.

Воспроизвести choices, восстановить конкретный binary и воспроизвести target
outcome — разные утверждения. Recipes восстанавливают bytes без RNG или corpus;
time-sensitive targets всё ещё могут вести себя иначе при execution replay.

## Provenance и учёт

Retained entries предоставляют full recipes в `Entry.metadata.mutation`;
unique crash records — в `Crash.metadata.mutation`, crash storage пишет `.recipe`
рядом с `.input` и existing `.term` result file. Decisions сохраняют короткий
mutation summary (stage, primary/config/candidate hashes), избегая full recipes
для каждого failed decision. Equivalent rejected candidates не сохраняются.
Optional `trace_limit` хранит лишь первое bounded number generated recipes,
включая позднее rejected, и не расходует RNG state.

Существующий `Report.stats` сохраняет counters calibration, mutation execution,
discovery, rejection, crash/timeout, unique fingerprint и infrastructure.
`Report.mutation_stats` добавляет:

* `visits`: scheduling visits, включая completed/inapplicable lanes.
* `mutation_attempts`: deterministic operation attempts или random stack attempts.
* `operation_attempts`: constituent attempts, включая unavailable choices.
* `skipped_operations` и `skip_reasons`: operation skips; reasons также считают
  final no-op stacks, поэтому totals не обязаны совпадать.
* `skipped_candidates`: visits, закончившиеся без candidate.
* `generated_candidates`: candidates, действительно переданные на execution
  при обычных runs.

Live API `efz:stats/0` остаётся существующими target/campaign counters; подробные
mutation counters и bounded trace находятся в final report. Stack — один
candidate/retention decision, а не доказательство, что каждая operation
независимо вызвала discovery. Crash fingerprint groups — не число доказанных
независимых bugs. Crashes/timeouts сохраняют execution observations, но никогда
не объединяют crash-only coverage с successful-corpus novelty. Ограничения
one-worker, one-target-process и fixed-build coverage/isolation из
[coverage.md](coverage.md) по-прежнему действуют.
