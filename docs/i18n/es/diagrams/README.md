# Diagramas UML de EFZ

[English](../../../diagrams/README.md) · [Русский](../../ru/diagrams/README.md) · **Español** · [简体中文](../../zh-CN/diagrams/README.md) · [Todos los idiomas](../../README.md)

Los diagramas acompañan la [descripción de la arquitectura actual](../architecture.md).
`.mmd` es la única fuente editable; `.svg` es una imagen generada para verla en
Markdown y navegador e incluirla en otros documentos.

| Diagrama | Notación UML | Fuente | Imagen |
|---|---|---|---|
| Módulos principales | Estructural/clases con estereotipos de módulos Erlang | [modules.mmd](modules.mmd) | [modules.svg](modules.svg) |
| Procesos y propietarios ETS | Estructural/clases con estereotipos de proceso/recurso | [processes.mmd](processes.mmd) | [processes.svg](processes.svg) |
| Bucle staged de realimentación | Secuencia | [feedback-loop.mmd](feedback-loop.mmd) | [feedback-loop.svg](feedback-loop.svg) |
| Una ejecución del objetivo | Secuencia | [executor.mmd](executor.mmd) | [executor.svg](executor.svg) |

Erlang no tiene clases del tipo mostrado en los diagramas estructurales:
un rectángulo representa un módulo real, proceso de ejecución o recurso según
su estereotipo. Las flechas discontinuas de dependencia no implican un servidor
separado. En el diagrama de procesos, los hijos del supervisor, enlaces
ordinarios y monitores están etiquetados por separado.

Los diagramas de secuencia muestran el flujo de control, incluidas llamadas
locales a funciones. Para mensajes entre procesos se muestran las tuplas reales;
los detalles exactos y rutas alternativas de fallo se describen en el documento
principal. Loop/alt denotan fragmentos UML, no sintaxis de implementación Erlang.

## Renderizado

Se requieren Mermaid CLI (`mmdc`) y su Chromium/Puppeteer local instalados.
Verificado con Mermaid CLI 11.12.0. Son herramientas de documentación; el
runtime EFZ no depende de ellas. Ejecute desde la raíz del repositorio:

```sh
for diagram in modules processes feedback-loop executor; do
  mmdc \
    -i "docs/diagrams/$diagram.mmd" \
    -o "docs/diagrams/$diagram.svg" \
    -c docs/diagrams/mermaid-config.json \
    -b white || exit 1
done
```

`mermaid-config.json` fija tema, fuente y disposición. Las etiquetas HTML están
desactivadas para producir SVG portables sin `foreignObject`. Para usar los
diagramas en Markdown compatible con Mermaid, coloque el contenido `.mmd`
en un bloque `mermaid`; los SVG ya están incluidos en `architecture.md` y no
requieren ese renderizador. Si cambia la arquitectura, actualice las fuentes
y regenere los SVG.

Basta un navegador para ver un SVG generado. Si el entorno impide iniciar
Chromium, utilice un entorno local donde esté permitido; no hace falta un
servicio externo de renderizado ni transferir fuentes por la red.

Para regenerar los diagramas de esta edición, sustituya las rutas de entrada y salida `docs/diagrams/` del comando anterior por `docs/i18n/es/diagrams/`. El archivo de configuración compartido sigue siendo `docs/diagrams/mermaid-config.json`.
