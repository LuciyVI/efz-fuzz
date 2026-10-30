# Harnesses de flujo de datos de Cowboy

[English](../../cowboy-harness-suite.md) · [Русский](../ru/cowboy-harness-suite.md) · **Español** · [简体中文](../zh-CN/cowboy-harness-suite.md) · [All languages](../README.md)

Esta suite comprueba EFZ con las versiones fijadas de sus dependencias Cowboy 2.19.0
y Cowlib 2.20.0. Once targets separados siguen flujos de datos reales de las
bibliotecas. El mismo código de target, corpus inicial, semillas del RNG y
presupuesto de mutación se ejecutan con la capa Gleam opcional desactivada,
observando resultados o guiando la mutación y la retención.

Las entradas son **bytes de payload**, de hasta 1024 bytes. Estos harnesses
construyen mensajes válidos alrededor de cada payload y comprueban lo que
devuelve la biblioteca. Un byte selector elige una variación documentada cuando
corresponde. Toda entrada dentro del presupuesto alcanza el código de la
biblioteca; no hay un envoltorio de codificación de términos que pueda rechazarse
primero. La suite ejercita rutas de análisis y entrega satisfactorias en lugar
de tratar el rechazo ordinario de entradas como un defecto.

## Superficies de entrada y rutas implementadas

Cada nombre selecciona `efz_cowboy_<name>_target:run/1`. Las implementaciones
comparten [`efz_cowboy_flow.erl`](../../../examples/cowboy/targets/efz_cowboy_flow.erl);
los puntos de entrada separados permiten contabilizar la cobertura y el corpus
de forma independiente.

| Nombre | Superficie de entrada y flujo de datos real | Contrato comprobado | Límite del alcance |
| --- | --- | --- | --- |
| `qs` | Payload → `cow_qs:urlencode/1` → `cowboy_req:parse_qs/1` → `match_qs/2` | El par decodificado y el campo coincidente son iguales a los bytes originales, incluidos los bytes cero y los que no son UTF-8 | Un campo con nombre; secuencias de escape válidas construidas |
| `headers` | Selector/payload → valor válido → `cowboy_req:header/2`, `parse_header/2` → parser de Cowlib | La consulta conserva el valor; la longitud del contenido es igual a la del payload | Seis familias de cabeceras: longitud del contenido, tipo de contenido, rango, autorización Basic, codificación aceptada, conexión |
| `cookies` | Payload → valor de cookie hexadecimal → `parse_cookies/1` → `match_cookies/2` → `filter_cookies/2` → nuevo análisis | El valor se conserva tras la coincidencia; el filtrado elimina la otra cookie | Dos cookies válidas; sin gramática de cookies arbitraria |
| `router` | Selector/payload → ruta de la petición → `cowboy_router:execute/2` → conversión mediante restricciones → `cowboy_req:binding/2` o `path_info/1` | La ruta seleccionada, el binding entero y la parte final de la ruta coinciden con lo construido | Despacho fijo de confianza: raíz, ID de elemento con restricción, ruta de archivo con comodín; sin ejecución de handlers |
| `http1` | Petición construida → `cowboy_http:init/6` real → transporte Ranch en memoria existente → handler de stream → router, QS, entrega del cuerpo | La longitud del cuerpo entregado es igual a la longitud original con delimitación content-length/chunked; cero para la variante sin cuerpo | Una petición/conexión completa; sink de stream síncrono existente, sin socket |
| `http2` | Payload → `cow_http2:data/3` → `cow_http2:parse/1` | Coinciden el ID del stream DATA, el indicador FIN, el payload y el resto vacío | Ida y vuelta de una trama de Cowlib, no una conexión HTTP/2 de Cowboy |
| `http3` | Payload → `cow_http3:data/1` → `cow_http3:parse/1` | Coinciden el payload DATA y el resto vacío | Ida y vuelta de una trama de Cowlib, no QUIC ni una conexión HTTP/3 de Cowboy |
| `websocket` | Selector/payload → trama de texto/binaria/ping → `cow_ws:frame/2` → `parse_header/3` → `parse_payload/9` | Coinciden el payload decodificado y el resto vacío | Tramas completas sin máscara, sin fragmentación ni compresión; ping limitado a 125 bytes |
| `multipart` | Payload → campo de formulario hexadecimal con delimitador fijo → `cow_multipart:parse_headers/2` → `parse_body/2` → delimitador final y análisis de content-disposition | Coinciden el cuerpo, el nombre del campo y el delimitador final | Una parte completa; sin ciclo de vida de `read_part` en streaming de Cowboy |
| `hpack` | Payload → lista de cabeceras → `cow_hpack:encode/3` → `decode/3` → segundo bloque que usa las mismas tablas locales | Ambas listas de cabeceras decodificadas son iguales a la original | Tablas nuevas de 512 bytes por ejecución, dos bloques, como máximo 16 cabeceras decodificadas |
| `qpack` | Payload → lista de cabeceras → `cow_qpack:encode_field_section/4` → `decode_field_section/3` | La lista de cabeceras coincide; no hay instrucciones del codificador con capacidad de tabla cero | Secciones de campos estáticas/literales; sin tabla dinámica, bloqueo ni streams de control QUIC |

Este inventario distingue las rutas de biblioteca implementadas de las
superficies de despliegue más amplias. Los sockets TLS/Ranch, la planificación de
conexiones, las máquinas de estados de conexión HTTP/2 y HTTP/3,
QUIC/WebTransport, los mensajes WebSocket comprimidos, multipart en streaming y
el comportamiento REST/static/de handlers específico de cada aplicación
requieren sus propias fixtures de ciclo de vida. La suite no afirma cubrir esas
rutas.

El benchmark existente de HTTP/1 sin procesar sigue documentado por separado en
[`cowboy-long-benchmark.md`](cowboy-long-benchmark.md). Su corpus de entradas de
protocolo difiere del corpus de payloads utilizado aquí.

## Ejecutar sin Gleam

Desde la raíz del repositorio, con Erlang/OTP 27 o posterior:

```sh
export ERL_FLAGS='+S 2:2'
rebar3 compile
escript scripts/cowboy_suite.escript --surface all --mode off \
  --iterations 500 --seed 424242 --out _build/cowboy-flows-off
```

El perfil ordinario no necesita el compilador de Gleam ni los BEAMs del modelo
generados. Los directorios de salida deben ser nuevos. Cada superficie se
ejecuta en una VM nueva con su propio corpus y artefactos de cobertura nativa
de líneas solo del target.

## Ejecutar los tres modos

```sh
export ERL_FLAGS='+S 2:2'
export GLEAM_BIN=/path/to/gleam-1.10.0
rebar3 as gleam compile
escript scripts/cowboy_suite.escript --surface all --mode all --profile gleam \
  --iterations 500 --seed 424242 --out _build/cowboy-flows-three-modes
```

Use, por ejemplo, `--surface http1` para ejecutar una ruta. Los modos son:

| Modo | Fracción estructurada | Admisión | Modelo opcional |
| --- | --- | --- | --- |
| `off` | 0% | Cobertura estructural | Ninguno |
| `observation_only` | 0% | Cobertura estructural; se registran las observaciones | `efz_term_model` de Gleam compilado |
| `guided` | 30% | Cobertura estructural o nuevas características semánticas | El mismo modelo y `efz_cowboy_flow_adapter` |

El modo de solo observación conserva el flujo de mutaciones de referencia y el
consumo del RNG. El modo guiado cambia deliberadamente las mutaciones
seleccionadas y, en consecuencia, el corpus. El adaptador compartido observa los
resultados reales con el modelo de términos de Gleam existente, además de
características de dominio finitas como el tamaño del cuerpo entregado, la ruta,
la familia de cabeceras y el intervalo de longitud del valor. Las operaciones
estructuradas cambian un selector, extienden un payload o generan un payload
acotado cuyo tamaño corresponde a un valor límite. No hay una reimplementación
separada en Gleam del análisis de Cowboy.

Las aserciones del harness se ejecutan en **todos** los modos. Comprueban la
consistencia de ida y vuelta/entrega de datos, no la conformidad completa con las
RFC. El oráculo de la capa semántica está desactivado, por lo que una nueva
característica semántica no es un hallazgo semántico. Las excepciones
inesperadas se propagan a EFZ y requieren investigación; no son automáticamente
defectos confirmados de la biblioteca. No se utiliza ningún defecto conocido ni
exploit.

## Leer la salida

Cada directorio `<surface>/<mode>/` contiene:

- `initial-corpus/`, `config.term` e `identity.term`: entradas exactas,
  configuración del RNG, versiones de las aplicaciones e identidades de
  compilación de los targets.
- `target-beams/` y `artifacts.term`: compilaciones de cobertura nativa solo del
  target. El código del harness, del adaptador, del observador y de EFZ se
  excluye de la lista de módulos medidos.
- `report.term`, `snapshot.term`, `summary.term`: resultado de la campaña,
  cobertura, corpus, tiempos, estadísticas semánticas/estructuradas y recuentos
  de invocaciones a la biblioteca.
- `corpus/` y `crashes/`: artefactos persistentes de EFZ para los flujos de
  reproducción habituales.

El archivo `summary.csv` de la raíz compara superficies y modos.
`comparisons.csv` registra la sobrecarga de tiempo respecto de la ejecución
`off` correspondiente. Una única campaña emparejada es una medición de
comprobación básica; no demuestra una ventaja de velocidad ni de descubrimiento
de defectos. Los tiempos del modo guiado incluyen una carga de entradas
diferente.

`target_invocations` y `target_accepted` incluyen la calibración y las mutaciones.
El runner comprueba la contabilización de invocaciones frente al presupuesto de
ejecución. En una ejecución limpia, cada invocación debe completar el contrato
de la biblioteca. `discoveries` y `corpus_equivalent_rejections` describen la
admisión al corpus, no el éxito o rechazo de la API. La cobertura obtenida durante
la calibración se informa por separado de `mutation_new_coverage_lines` para que
un corpus inicial no pueda hacerse pasar por progreso de las mutaciones. El
denominador de cobertura incluye los módulos seleccionados completos, incluidas
las funciones inalcanzables desde el flujo elegido; no es un máximo de rutas
alcanzables.

`report.etf` conserva el informe binario completo. Los informes de texto etiquetan
las identidades de ejecución para que `file:consult/1` pueda leerlos conservando
los bytes de las entradas binarias.

## Comprobaciones de regresión

```sh
rebar3 eunit --module=efz_cowboy_flow_tests,efz_cowboy_long_tests
GLEAM_BIN=/path/to/gleam-1.10.0 rebar3 as gleam eunit --module=efz_cowboy_flow_tests
```

La validación local completó 33 campañas de 500 mutaciones: 16 500 mutaciones y
264 calibraciones, con las 16 764 llamadas a la biblioteca aceptadas y sin
excepciones, tiempos de espera agotados ni fallos de infraestructura. Las
entradas retenidas, la cobertura y las estadísticas de mutación coincidieron
entre off y observation-only para las once superficies. HTTP/1 alcanzó 313 líneas
y 26 entradas de corpus sin la capa, frente a 312 líneas y 32 entradas con guided;
retener más entradas no demuestra mejor cobertura. Véanse los
[resultados CSV](../../cowboy-harness-suite-validation/summary.csv), las
[identidades de compilación](../../cowboy-harness-suite-validation/identities.term)
y el [manifiesto de reproducción](../../cowboy-harness-suite-validation/manifest.json).
Otras verificaciones locales se ejecutaron en paralelo, por lo que estos tiempos
no aíslan la sobrecarga de la capa. Los informes completos permanecen en el árbol
local `_build`; el manifiesto registra sus hashes y el comando exacto.

Las pruebas cubren entradas vacías/binarias/de tamaño máximo para las once
rutas, mutaciones estructuradas y reducciones repetibles, igualdad de la
configuración de las campañas, entrega del cuerpo y limpieza del transporte
HTTP/1 en memoria. La compilación opcional también comprueba que resultados
distintos de la biblioteca produzcan características semánticas distintas.
