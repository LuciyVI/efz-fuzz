# UML-диаграммы EFZ

[English](../../../diagrams/README.md) · **Русский** · [Español](../../es/diagrams/README.md) · [简体中文](../../zh-CN/diagrams/README.md) · [Все языки](../../README.md)

Диаграммы сопровождают [описание текущей архитектуры](../architecture.md).
`.mmd` — единственный редактируемый исходник; `.svg` — сгенерированное изображение
для просмотра в Markdown и браузере, а также включения в другие документы.

| Диаграмма | Нотация UML | Исходник | Изображение |
|---|---|---|---|
| Основные модули | Структурная/class со стереотипами Erlang-модулей | [modules.mmd](modules.mmd) | [modules.svg](modules.svg) |
| Процессы и владельцы ETS | Структурная/class со стереотипами процессов/ресурсов | [processes.mmd](processes.mmd) | [processes.svg](processes.svg) |
| Staged feedback loop | Sequence | [feedback-loop.mmd](feedback-loop.mmd) | [feedback-loop.svg](feedback-loop.svg) |
| Один target execution | Sequence | [executor.mmd](executor.mmd) | [executor.svg](executor.svg) |

В Erlang нет классов того вида, который показан в структурных диаграммах:
прямоугольник представляет настоящий module, runtime process или resource
согласно стереотипу. Пунктирные стрелки зависимостей не подразумевают отдельный
server. На диаграмме процессов supervisor children, обычные links и monitors
помечены отдельно.

Sequence diagrams показывают control flow, включая локальные вызовы функций.
Для межпроцессных сообщений показаны настоящие message tuples; точные детали
и альтернативные failure paths описаны в основном документе. Loop/alt на
диаграмме обозначают UML fragments, а не синтаксис реализации Erlang.

## Рендеринг

Требуются установленный Mermaid CLI (`mmdc`) и его локальный Chromium/Puppeteer.
Проверено с Mermaid CLI 11.12.0. Это инструменты документации; EFZ runtime от
них не зависит. Выполняйте команды из корня репозитория:

```sh
for diagram in modules processes feedback-loop executor; do
  mmdc \
    -i "docs/diagrams/$diagram.mmd" \
    -o "docs/diagrams/$diagram.svg" \
    -c docs/diagrams/mermaid-config.json \
    -b white || exit 1
done
```

`mermaid-config.json` фиксирует тему, шрифт и настройки layout. HTML labels
отключены для переносимого SVG без `foreignObject`. Для использования диаграмм
в Mermaid-совместимом Markdown поместите содержимое `.mmd` в code fence
`mermaid`; SVG уже включены в `architecture.md` и не требуют такого renderer.
При изменении архитектуры обновите исходники и заново сгенерируйте SVG.

Для просмотра сгенерированного SVG достаточно браузера. Если среда запрещает
запуск Chromium, используйте локальную среду, где он разрешён; внешний rendering
service и передача исходников по сети не нужны.

Для перестроения диаграмм этой языковой версии замените входные и выходные пути `docs/diagrams/` в команде выше на `docs/i18n/ru/diagrams/`. Общий файл настроек `docs/diagrams/mermaid-config.json` остаётся тем же.
