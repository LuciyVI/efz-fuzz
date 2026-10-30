# Локальный провайдер Erlamsa

Это краткое руководство. [Полный контракт и каталог операций](../../erlamsa-integration.md) опубликованы на английском.

Провайдер включается явно: `mutation_provider.mode = erlamsa` или `hybrid`. Semantic adapter выбирается независимо; native остаётся режимом по умолчанию. Версия ядра закреплена gitlink `vendor/erlamsa` и не движется вместе с веткой fork.

```sh
git submodule update --init --recursive
ERL_FLAGS='+S 2:2' rebar3 as erlamsa compile
```

При отсутствии подготовленного core включённый провайдер выдаёт ошибку конфигурации до запуска цели. Сохранённый raw input воспроизводится без core; регенерация требует совпадения build/config identity. Ошибки провайдера и timeout не считаются падениями цели. [Историческая проверка](../../erlamsa-validation.md) привязана к указанным там SHA.
