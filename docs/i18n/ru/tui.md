# Терминальная панель EFZ

[English](../../tui.md) · **Русский** · [Español](../es/tui.md) · [简体中文](../zh-CN/tui.md) · [Все языки](../README.md)

Необязательный viewer на Python/curses сочетает график скорости executions и
покрытия с последним завершённым input в hex/ASCII и именами покрытых функций.
Требуются Python 3 с curses, интерактивный UTF-8 терминал и обычный toolchain
OTP/Rebar. Пакеты Python и web server не нужны.

Из корня репозитория:

```sh
rebar3 compile
python3 scripts/tui.py --demo --out _build/tui-demo-1
```

Demo инструментирует встроенный parser, выполняет 10 000 мутаций и намеренно
содержит искусственные target exceptions. Оно не тестирует внешний сервис.
При каждом запуске используйте новый output directory; существующие результаты
никогда не заменяются.

Для собственного target передайте ту же доверенную Erlang campaign map, которую
принимает `efz:start/1`, включая raw binary seeds и подготовленные artifact maps:

```sh
python3 scripts/tui.py --config campaign.term --out _build/tui-run-1 \
  --code-path harness-ebin
python3 scripts/tui.py --attach _build/tui-run-1
```

Повторяйте `--code-path` для dependencies или optional Gleam build. Относительные
пути в конфигурации кампании разрешаются относительно корня репозитория.
Launcher переопределяет `monitoring` на true и `crash_dir` на OUTPUT/crashes;
остальные настройки кампании, включая durable corpus identity/policy, задаёт
вызывающая сторона. Конфигурация кампании — доверенная локальная исполняемая
конфигурация, а не finding. Этот launcher пока использует обычный режим execution
в одной VM, а не внешний CLI-протокол `--supervised`.

## Экран и управление

- Слева: график скорости primary executions (калибровка + мутации), накопленное
  покрытие, бюджет мутаций, число калибровок, статистика корпуса и findings.
- Справа: hex и ASCII последнего завершённого input, phase, parent, outcome и
  функции target. Preview input ограничен 512 байтами с отметкой об усечении.
  Списки функций ограничены 64 записями; панель показывает три.
- Пробел закрепляет/открепляет input и его outcome/functions. Графики продолжают
  обновляться.
- Стрелки вверх/вниз прокручивают preview input строками по 16 байтов.
- `q` или Ctrl-C закрывает только viewer. Отсоединённая кампания продолжает работу;
  выводятся её PID и output path. Подключитесь заново через `--attach OUTPUT`.
- Поддерживается изменение размера терминала. При размере меньше 90×26 сообщение
  об изменении размера заменяет панели. После завершения итог остаётся на экране
  до закрытия viewer.

Фоновый bridge атомарно записывает snapshot.json примерно дважды в секунду,
а также campaign.log и обычный binary report.term при завершении. Ошибка bridge
показывается в запустившем его viewer; подробности находятся в campaign.log.
Чтобы явно остановить отсоединённую кампанию, отправьте SIGTERM напечатанному
PID bridge. Это отмена процесса, не обещающая завершённый отчёт; уже долговечно
сохранённые записи корпуса остаются под обычными гарантиями EFZ. В первой версии
панели нет интерактивных controls для replay, minimization или аннотаций findings.

## Корректная интерпретация данных

Input соответствует последнему **завершённому** execution, а не заявленному
текущему program counter. Для source-instrumented ETS coverage точные достигнутые
probes отображаются в функции из переданных manifests. Если per-execution
functions отсутствуют, незакреплённая панель явно помечает fallback как
**cumulative coverage**. Native line coverage без function manifests и
конфигурации с выключенным coverage показывают недоступность данных о функциях,
не выдумывая call stack. Live stack sampling не реализован.

Проценты отображаются только при известном числе probes в manifest. Native
coverage обозначается строками, manual coverage — manual units. При нулевом или
недоступном знаменателе выводится только абсолютное число. Статистика накопительная,
а графики хранят не более 120 sampled points. Скорость основана на разнице числа
executions между snapshot times, а не на заявленном распределении target latency.

Счётчики outcomes включают калибровку и primary mutations, исключая дополнительные
runtime verification calls. `Returned value` не подразумевает semantic success.
Только явные соглашения о return values `{efz_term_input_rejected, Reason}`,
`rejected` и `{rejected, Reason}` классифицируются как codec/target rejection.
Другие возвращаемые ошибки остаются returned values. Исключения автоматически
не признаются реальными дефектами: ожидаемые parser throws всё ещё требуют
подходящего harness contract или review. Старый счётчик EFZ `rejections` также
включает coverage-equivalent executions; здесь он не используется как число
отказов parser.

## Интеграция и накладные расходы

`monitoring => false` — значение по умолчанию. Только opt-in campaigns хранят
ограниченное представление input и счётчики outcomes. Не добавляются RNG draws
или target calls. `efz_fuzzer:monitor_snapshot/0` — read-only snapshot API версии 1:
он возвращает cached sample и запрашивает асинхронное обновление. В ожидании
находится не более одного refresh, поэтому медленный target не блокирует
координатор и не увеличивает неограниченную очередь опросов. Итоговый sample
публикуется до отчёта кампании. Opt-in форматирование preview, отображение
функций и материализация sampled coverage имеют накладные расходы; отсутствие
накладных расходов не заявляется.

## Валидация

На OTP 27.3.4.1 / Rebar3 3.25.0:

- Default EUnit: 311 passed; full Gleam/XML-RPC EUnit: 377 passed.
- Common Test: 3 passed; xref и Dialyzer прошли.
- Monitor integration проверяет точное совпадение mutation recipes и coverage
  при monitoring off/on, ограниченные previews, согласованные итоговые outcome
  totals и отзывчивость snapshot API при намеренно заблокированном target.
- `python3 -m unittest discover -s test -p 'tui_test.py'`: 2 passed, проверяются
  rate sampling/history bounds, отображение bytes и очистка terminal controls.
- Настоящий запуск в псевдотерминале проверил отрисовку панелей, закрепление input,
  fallback при узком терминале, восстановление размера, выход и повторное
  подключение. После запуска demo и закрытия viewer кампания продолжила работу;
  она завершила 10 000 мутаций и показала 7/9 probes с видимой функцией
  `efz_example_parser:classify/1`.

Эти проверки подтверждают поддерживаемое поведение панели в одной VM, а не
отсутствие влияния monitoring на производительность или поддержку всех
эмуляторов терминала.

## Непрерывный режим

```sh
python3 scripts/tui.py --demo --continuous --out _build/tui-continuous-1
```

Это demo работает без лимита mutation executions и долговечно сохраняет записи
корпуса в OUTPUT/corpus. Бюджет показан как ∞. Нажмите `s`, чтобы прекратить
планирование новых inputs, завершить текущий ограниченный target execution и
сохранить report.term. Экран остаётся открытым со статусом `stopped_by_user`;
`q` по-прежнему отсоединяет viewer без остановки. Подключённый monitor также
может запросить остановку. Ожидающие stop/refresh requests объединяются, пока
target занят.

Для своей кампании задайте `max_iterations => infinity` в доверенной
конфигурации. Задайте `corpus_dir`, если записи корпуса должны переживать
аварийное завершение процесса. Staged continuous mode сохраняет RNG, content
cursors, рабочий корпус и конфигурацию Gleam; он добавляет havoc lane, если она
не выбрана. Когда обычный planner исчерпывает idle sweep, гарантированная
ограниченная по размеру вставка/bit flip создаёт настоящий replayable candidate,
а не цикл повторов, расходующий только CPU. Нулевой input limit отклоняется
для continuous staged campaigns: у единственного пустого input нет отличной от
него допустимой мутации.

Per-execution target timeouts, oracle budgets, runtime verification budgets,
input limits, infrastructure failures и существующие quarantine rules продолжают
действовать. Continuous reports хранят последние 1 024 поясняющих decisions со
счётчиком `decisions_dropped`; это не удаляет рабочий корпус или finding groups.
Trace limits остаются ограниченными. Фактический рост корпуса и различные
findings всё ещё расходуют диск/память; неограниченное исполнение не означает
неограниченных ресурсов.
