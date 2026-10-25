# EFZ UML diagrams

**English** · [Русский](../i18n/ru/diagrams/README.md) · [Español](../i18n/es/diagrams/README.md) · [简体中文](../i18n/zh-CN/diagrams/README.md) · [All languages](../i18n/README.md)

The diagrams accompany the [description of the current architecture](../architecture.md).
`.mmd` is the only editable source; `.svg` is a generated image for viewing in
Markdown and a browser, and for inclusion in other documents.

| Diagram | UML notation | Source | Image |
|---|---|---|---|
| Main modules | Structural/class with Erlang module stereotypes | [modules.mmd](modules.mmd) | [modules.svg](modules.svg) |
| Processes and ETS owners | Structural/class with process/resource stereotypes | [processes.mmd](processes.mmd) | [processes.svg](processes.svg) |
| Staged feedback loop | Sequence | [feedback-loop.mmd](feedback-loop.mmd) | [feedback-loop.svg](feedback-loop.svg) |
| One target execution | Sequence | [executor.mmd](executor.mmd) | [executor.svg](executor.svg) |

Erlang has no classes of the kind shown in structural diagrams: a rectangle
represents a real module, runtime process or resource according to its stereotype.
Dashed dependency arrows do not imply a separate server. In the process diagram,
supervisor children, ordinary links and monitors are labeled separately.

Sequence diagrams show control flow, including local function calls. Actual
message tuples are shown for interprocess messages; exact details and alternative
failure paths are described in the main document. Loop/alt in a diagram denote
UML fragments, not Erlang implementation syntax.

## Rendering

An installed Mermaid CLI (`mmdc`) and its local Chromium/Puppeteer are required.
Verified with Mermaid CLI 11.12.0. These are documentation tools; the EFZ runtime
does not depend on them. Run the commands from the repository root:

```sh
for diagram in modules processes feedback-loop executor; do
  mmdc \
    -i "docs/diagrams/$diagram.mmd" \
    -o "docs/diagrams/$diagram.svg" \
    -c docs/diagrams/mermaid-config.json \
    -b white || exit 1
done
```

`mermaid-config.json` fixes the theme, font and layout settings. HTML labels are
disabled to produce portable SVG without `foreignObject`. To use the diagrams
in Mermaid-compatible Markdown, place the `.mmd` content in a `mermaid` code
fence; the SVG files are already included in `architecture.md` and do not require
that renderer. When changing the architecture, update the sources and regenerate
the SVG files.

A browser is sufficient to view a generated SVG. If the environment prevents
Chromium from starting, use a local environment where it is permitted; no external
rendering service or transfer of sources over the network is required.
