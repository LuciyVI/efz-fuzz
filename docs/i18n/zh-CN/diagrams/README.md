# EFZ UML 图

[English](../../../diagrams/README.md) · [Русский](../../ru/diagrams/README.md) · [Español](../../es/diagrams/README.md) · **简体中文** · [所有语言](../../README.md)

这些图配合[当前架构说明](../architecture.md)使用。
`.mmd` 是唯一可编辑的源文件；`.svg` 是生成的图像，用于在
Markdown 和浏览器中查看，以及插入其他文档。

| 图 | UML 表示法 | 源文件 | 图像 |
|---|---|---|---|
| 主要模块 | 带 Erlang 模块构造型的结构图/类图 | [modules.mmd](modules.mmd) | [modules.svg](modules.svg) |
| 进程和 ETS 所有者 | 带进程/资源构造型的结构图/类图 | [processes.mmd](processes.mmd) | [processes.svg](processes.svg) |
| 分阶段反馈循环 | 时序图 | [feedback-loop.mmd](feedback-loop.mmd) | [feedback-loop.svg](feedback-loop.svg) |
| 一次目标执行 | 时序图 | [executor.mmd](executor.mmd) | [executor.svg](executor.svg) |

Erlang 没有结构图中所示的那种类：矩形根据其构造型
表示实际的模块、运行时进程或资源。
虚线依赖箭头不表示独立的服务器。在进程图中，
监督者子进程、普通链接和监控分别标注。

时序图展示控制流，包括本地函数调用。进程间消息
展示实际的消息元组；具体细节和其他
失败路径在主文档中说明。图中的 Loop/alt 表示
UML 片段，而不是 Erlang 实现语法。

## 渲染

需要已安装的 Mermaid CLI（`mmdc`）及其本地 Chromium/Puppeteer。
已使用 Mermaid CLI 11.12.0 验证。这些是文档工具；EFZ 运行时
不依赖它们。从仓库根目录运行以下命令：

```sh
for diagram in modules processes feedback-loop executor; do
  mmdc \
    -i "docs/diagrams/$diagram.mmd" \
    -o "docs/diagrams/$diagram.svg" \
    -c docs/diagrams/mermaid-config.json \
    -b white || exit 1
done
```

`mermaid-config.json` 固定主题、字体和布局设置。HTML 标签已
禁用，以生成不含 `foreignObject` 的可移植 SVG。要在
兼容 Mermaid 的 Markdown 中使用这些图，请将 `.mmd` 内容放入 `mermaid` 代码
围栏；SVG 文件已包含在 `architecture.md` 中，无需
该渲染器。修改架构时，请更新源文件并重新生成
SVG 文件。

查看生成的 SVG 只需要浏览器。如果环境阻止
Chromium 启动，请使用允许其启动的本地环境；无需外部
渲染服务，也无需通过网络传输源文件。

要重新生成本语言版本的图，请将上述命令的输入和输出路径 `docs/diagrams/` 替换为 `docs/i18n/zh-CN/diagrams/`。共享配置文件仍使用 `docs/diagrams/mermaid-config.json`。
