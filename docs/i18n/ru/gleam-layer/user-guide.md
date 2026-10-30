> Этот документ описывает исторический интерфейс совместимости QS. Актуальное

[English](../../../gleam-layer/user-guide.md) · **Русский** · [Español](../../es/gleam-layer/user-guide.md) · [简体中文](../../zh-CN/gleam-layer/user-guide.md) · [Все языки](../../README.md)
> руководство по публичным плагинам и общему API — [Подключение Erlang-библиотек](connecting-erlang-libraries.md).

# Необязательный нативный слой Gleam

Стандартная сборка `rebar3 compile` и все обычные цели EFZ не требуют Gleam.

Сборка закреплённым компилятором (ничего не устанавливает):

```sh
GLEAM_BIN=/path/to/gleam-1.10.0 ERL_FLAGS='+S 2:2' rebar3 as gleam compile
escript scripts/gleam_seeds.escript /tmp/new-qs-seeds
```

[Доказательства интеграции P2](p2-integration.md) фиксируют чистую off-сборку без компилятора,
воспроизводимую on-сборку, runtime-off, прямые BEAM-трассы и проверки границы.
Диагностика компонентов в отдельной VM:

```sh
escript scripts/gleam_beam_bench.escript "$PWD/_build/gleam" /tmp/gleam-beam-samples.json
escript scripts/gleam_dispatch_bench.escript /tmp/gleam-dispatch-samples.json
```

Эти драйверы собирают конечные счётчики и времена без production-логирования или
состояния телеметрии. Не запускайте их одновременно с benchmark-кампаниями.

Seed-манифест находится вне каталога raw seeds, поэтому EFZ не сможет случайно
фаззить манифест. Подготовленные seeds затем можно использовать с отключённым слоем.
Генерация по умолчанию создаёт 12 разных seeds, включая пустые values/query,
повторяющиеся имена, произвольные байты, некорректный percent escape, 31/32 поля,
127/128-байтовые значения и 4096-байтовый wire input. Команда отклоняет существующий
каталог результата/манифест. Каталог индексов детерминирован; schema 2 записывает
версию генератора 2, версии runtime, ограничения и SHA-256 каждого raw input.
При подготовленных обычных ETS-артефактах импорт выполняется существующим CLI:

```sh
escript scripts/fuzz.escript --target efz_qs_target --artifacts /tmp/qs-ets \
  --code-path _build/default/lib/efz/ebin --seeds /tmp/new-qs-seeds \
  --out /tmp/qs-seeds-only --max-iterations 100 --mutation staged
```

В этой команде нет флага runtime-слоя. Независимые доказательства приёмки/импорта цели
и результаты структурного smoke-теста записаны в [p3-provider.md](p3-provider.md).

Первая цель: `efz_qs_target:run/1`, оборачивающая закреплённый `cow_qs:parse_qs/1`. Поддерживаемая
модель: непустые binary-имена, явный `=`, упорядоченные binary-значения, percent/plus
кодирование, разделители `&`. Неподдерживаемые и некорректные байты идут обычным
путём. Ожидаемый отказ парсера возвращает `rejected` без находки.

Подготовка нативных артефактов только цели из Erlang:

```erlang
{ok,A}=efz_cov_native_public:compile(
  "_build/default/lib/cowlib/src/cow_qs.erl", "/tmp/qs-native",
  ["_build/default/lib/cowlib/include"]).
{ok,_}=efz:start(#{target=>efz_qs_target, seeds=>[<<"a=1">>], artifacts=>[A],
  coverage_backend=>otp_native_public, mutation_mode=>staged,
  mutation=>#{seed=>{17,23,41},stages=>[havoc]},
  timeout=>1000, max_iterations=>1000, crash_dir=>"/tmp/qs-findings",
  gleam_layer=>#{structured_fraction=>10}}).
Report=efz:await(30000).
ok=efz:stop().
```

Используйте code paths `_build/gleam/lib/efz/ebin` и зависимости Cowlib. Доля 0
не выбирает структурную ветвь и не декодирует вход. `gleam_layer=>false` отключает все
callbacks и семантическое состояние, в том числе в on-сборке. Отсутствующий пакет или
неподдерживаемая цель/конфигурация явно отклоняется при старте. Поддерживается один
адаптер и нет deferred oracle policy. Изоляция исполнения по умолчанию не меняется.

Для существующего CLI с обычными ETS-артефактами добавьте
`--code-path _build/gleam/lib/efz/ebin --gleam-layer --structured-fraction 10
--semantic-feedback guided --semantic-oracle inline --oracle-budget 64`.
API выше — процесс подготовки нативного покрытия; существующее обнаружение
артефактов CLI остаётся для парных ETS-артефактов инструментирования исходников.

Проверки: query_model_agreement v1 сравнивает поддерживаемую модель с завершённым
результатом основного парсера. Неподдерживаемый вход, исчерпанный бюджет, timeout или
exception дают Inconclusive с причиной. Дополнительных исполнений цели нет.
Признаки observer имеют точное пространство из 12 ID, независимое от структурного
покрытия. Semantic-only discoveries используют обычные корпус/планировщик EFZ.

[Доказательства feedback P4](p4-feedback.md) фиксируют одинаковые нативные снимки, фактический
выбор semantic-only родителя, повтор записи, сохранение после restart/subset и
replay находок. `efz_corpus:semantic_representatives/0` возвращает холодный read-only
индекс признак→рабочая запись в guided-режиме; off/observation-only возвращает
`disabled`. Restart повторно калибрует текущие raw entries корпуса до мутаций.
Deferred oracle и удаление корпуса во время кампании не поддерживаются.

Стоимость ограниченных компонентов callback измеряется отдельно от кампаний:

```sh
escript scripts/gleam_feedback_probe.escript "$PWD/_build/gleam" /tmp/feedback-costs.json
```

Эта конечная диагностика использует derived-from-model fixtures результатов и не исполняет цель.
Она измеряет стоимость callback, а не корректность парсера или производительность кампании.

Находка oracle сохраняет `.input`, `.term`, `.replay`, необязательный `.recipe` и
`.semantic` с контрольной суммой. Property replay требует Gleam и явно неизменных
артефактов цели/native; регенерация рецепта и обычный raw replay этого не требуют.
Replay/минимизация искусственной fixture тестов (не реального дефекта Cowlib):

Следующая команда с пятью позиционными аргументами — QS legacy helper. Новые
адаптеры используют явный интерфейс `--config` из
[руководства подключения библиотек](connecting-erlang-libraries.md#8-проверить-persistence-replay-и-минимизацию).

```sh
escript scripts/gleam_replay.escript ARTIFACT_PREFIX NATIVE_ARTIFACT_DIR \
  efz_qs_defect_target 64 /tmp/qs-minimized
```

Результаты записываются вне неизменяемой группы находки. Минимизатор учитывает все
исполнения цели, сохраняет тот же предикат свойства, останавливается на конечном бюджете
и сообщает, достигло ли удаление одного байта неподвижной точки. Он не
обещает глобального минимума входа. Перед property replay остановите активные кампании.

`efz_semantic:cover/1` возвращает консервативное подмножество с сохранением записанных probe-,
hit-count и semantic-объединений; файлы корпуса не удаляются. Начальные или
некалиброванные entries защищены. Restart корпуса перестраивает текущие признаки
обычной калибровкой seeds, учитываемой отдельно от мутационных исполнений.

Превосходство производительности или оптимальная доля не заявляются. Финальные регрессии P5 и приёмка конечных кампаний
отражены в [p5-validation.md](p5-validation.md);
одни компонентные замеры P2 не закрывают этот этап.
P3 сообщает attempts/successes, ID операций, unsupported/limit/unchanged fallback,
ошибки слоя, сгенерированные байты и суммарные микросекунды callbacks. Отдельные
конечные замеры компонентов (decode / core mutation / encode / whole provider):

```sh
escript scripts/gleam_provider_probe.escript "$PWD/_build/gleam" \
  artifacts/gleam-layer/20261008-p3-provider/p2-model-original.beam /tmp/provider.json
```

BEAM модели P2 — локальное доказательство, а не поставляемая runtime-зависимость. Структурные
рецепты теперь используют schema 3 с точным RNG provenance; старые schemas 1/2 воспроизводятся
без Gleam. Ни рецепты, ни метаданные не меняют canonical raw inputs корпуса.
