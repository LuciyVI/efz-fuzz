# UML-диаграммы EFZ

Диаграммы сопровождают [описание текущей архитектуры](../architecture.md).
`.mmd` — единственный редактируемый источник; `.svg` — производный результат для
просмотра в Markdown, браузере и передачи в другие документы.

| Диаграмма | UML-нотация | Исходник | Изображение |
|---|---|---|---|
| Основные модули | Structural/class со стереотипами Erlang modules | [modules.mmd](modules.mmd) | [modules.svg](modules.svg) |
| Процессы и владельцы ETS | Structural/class со стереотипами process/resource | [processes.mmd](processes.mmd) | [processes.svg](processes.svg) |
| Staged feedback loop | Sequence | [feedback-loop.mmd](feedback-loop.mmd) | [feedback-loop.svg](feedback-loop.svg) |
| Один target execution | Sequence | [executor.mmd](executor.mmd) | [executor.svg](executor.svg) |

В Erlang нет классов, представленных на structural diagrams: прямоугольник
обозначает реальный модуль, runtime process или ресурс согласно стереотипу.
Пунктирные dependency arrows не означают отдельный сервер. В схеме процессов
supervisor children, обычные links и monitors подписаны отдельно.

Sequence diagrams показывают control flow, включая локальные function calls.
Для межпроцессных сообщений указаны реальные message tuples; exact details и
альтернативные failure paths описаны в основном документе. Loop/alt на диаграмме
обозначают UML-фрагменты, а не синтаксис реализации Erlang.

## Рендеринг

Нужны установленный Mermaid CLI (`mmdc`) и его локальный Chromium/Puppeteer.
Проверено с Mermaid CLI 11.12.0. Это инструменты документации; runtime EFZ от них не зависит. Команды запускаются
из корня репозитория:

```sh
for diagram in modules processes feedback-loop executor; do
  mmdc \
    -i "docs/diagrams/$diagram.mmd" \
    -o "docs/diagrams/$diagram.svg" \
    -c docs/diagrams/mermaid-config.json \
    -b white || exit 1
done
```

`mermaid-config.json` фиксирует тему, шрифт и layout settings. HTML labels
отключены для переносимых SVG без `foreignObject`. Для переноса
в Mermaid-compatible Markdown содержимое `.mmd` можно поместить в code fence
`mermaid`; SVG уже включены в `architecture.md` и не требуют такого renderer.
При изменении architecture обновляйте исходники и перегенерируйте SVG.

Для просмотра готового SVG достаточно браузера. Если окружение запрещает запуск
Chromium, используйте локальную среду, где запуск разрешён; внешний сервис
рендеринга и передача исходников по сети не требуются.
