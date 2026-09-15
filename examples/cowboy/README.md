# Cowboy: небольшой target для EFZ

`efz_cowboy_target:run/1` принимает **байты query string без начального `?`**,
например `<<"q=hello+world&edit">>`, и вызывает `cowboy_req:parse_qs/1`.
Результат — `{ok, Pairs}` либо `{invalid, qs | limit_reached}` для штатного
отказа Cowboy. Неожиданные исключения обёртка не перехватывает. Сам Cowboy
переводит исключения своего парсера в `request_error`, поэтому это harness
публичного API с его семантикой ошибок, а не сохранение всех внутренних причин.

Запуск выполняется синхронно в процессе target. Используется минимальный Req
с полем `qs`; listener, соединение и Cowboy application не запускаются.
Область проверки — декодирование query string в Cowboy/Cowlib. HTTP framing,
заголовки, сокеты, router, handlers и дочерние процессы сюда не входят.

## Запуск

Из корня **efz/**, с собранным соседним checkout Cowboy:

```sh
rebar3 compile
make -C ../cowboy
escript examples/cowboy/run.escript ../cowboy check
escript examples/cowboy/run.escript ../cowboy 500
```

В текущем workspace путь содержит `:`. `erlang.mk` Cowboy не собирается в таком
пути (`target pattern contains no '%'`). Проверенный обход — отдельная копия
в `/tmp`, исходный checkout сохраняется:

```sh
COWBOY_BUILD=$(mktemp -d /tmp/efz-cowboy.XXXXXX)
cp -a ../cowboy "$COWBOY_BUILD/cowboy"
make -C "$COWBOY_BUILD/cowboy"
rebar3 compile
escript examples/cowboy/run.escript "$COWBOY_BUILD/cowboy" check
escript examples/cowboy/run.escript "$COWBOY_BUILD/cowboy" 500
```

`make` скачивает зависимости, закреплённые в Cowboy Makefile. При недоступном
прокси в этой среде проверена сборка через прямой доступ:

```sh
env -u HTTPS_PROXY -u HTTP_PROXY -u ALL_PROXY \
    -u https_proxy -u http_proxy -u all_proxy make -C "$COWBOY_BUILD/cowboy"
```

EFZ не добавляет
Cowboy в свои основные зависимости. Каждый запуск escript использует свежую VM.

Runner автоматически инструментирует allowlist `[cowboy_req, cow_qs]` в
`_build/cowboy-targets`, проверяет BEAM/manifest и запускает штатный executor.
Обычные артефакты Cowboy сохраняются. Для `cow_qs` передаётся include-каталог
Cowlib. Для `cowboy_req` явно используется `strict => false`: в проверенной
версии два list comprehension (`filter_cookies/2`, `kvlist_to_map/2`) сохранены
без внутренних probes. Они не входят в путь `parse_qs/1`; ограничения выводятся
при сборке и записаны в manifest. Полное покрытие всего Cowboy не заявляется.

Пример использует staged mode, seed `{17,23,41}`, начальный корпус `[<<>>]`,
этапы `dictionary_insert`, `bitflip`, `havoc` и предел входа 1024 байта.
Аргумент числа исполнений: 1–100000, по умолчанию 500. Сохраняются defaults
покрытия EFZ: prepared validation + ETS. Штатные отказы разбора считаются
нормальным завершением target, поэтому их новые probes могут расширять корпус.
Отчёт: `_build/cowboy-report.term`; неожиданные падения: `_build/cowboy-crashes/`.

## Локальная проверка

Проверено на OTP 27.0, Rebar3 3.25.0, Cowboy 2.19.0
(`79e3fb02b31d47af6e69e8f3ba18fba291a3072a`), Cowlib 2.20.0
(`c768a804565ff5b8178ed968a5921e469d6bd7b2`). `check` — 14 EUnit-проверок:
пустой вход, повторные ключи, percent decoding, нулевые/не-UTF-8 байты,
повреждённые escapes, граница 99/100/101 ключей, точное совпадение snapshots
ETS/ets_member, новые execution refs и удержание `a=1` после реальной dictionary
мутации с automatic coverage. Эти дополнительные проверки запускаются командой
`check`, отдельно от обычного `rebar3 eunit`, и требуют настоящего Cowboy.

Локальный запуск на 500 mutation executions завершился: 1 обработка seed,
20 discoveries, 480 rejections, 0 crashes/timeouts/infrastructure failures.
Это наблюдение на указанной сборке, не ожидаемая константа для других версий.
Базовые `rebar3 compile` и `rebar3 eunit` прошли: 62 теста EFZ.
