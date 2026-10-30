# Harnesses de flujo de datos de XML-RPC

[English](../../xmlrpc-harness-suite.md) · [Русский](../ru/xmlrpc-harness-suite.md) · **Español** · [简体中文](../zh-CN/xmlrpc-harness-suite.md) · [All languages](../README.md)

Esta suite comprueba seis flujos de datos funcionales locales de
[etnt/xmlrpc](https://github.com/etnt/xmlrpc), fijado en el commit
`fb46463b2acadf164ec534d9e2033e194341c507`. Cada superficie ejecuta el mismo
target, corpus inicial, semilla del RNG y presupuesto de mutación con la capa
Gleam opcional desactivada, observando resultados o guiando la mutación y la
retención en el corpus.

Las entradas son bytes de payload, limitados a 512 bytes. El harness deriva
valores XML-RPC acotados de esos bytes y construye mensajes completos con
etiquetas XML fijas. Los flujos válidos usan nombres de métodos y de miembros de
struct que son átomos fijos; la validación usa alternativas mal formadas fijas.
Los valores de cadena son ASCII imprimible derivado del payload. Las mutaciones
de bytes no se convierten en marcado XML ni en átomos nuevos. En los flujos de
valores tipados, el primer byte módulo ocho selecciona un entero, booleano,
cadena, doble, fecha, valor base64, array o struct; una entrada vacía selecciona
un entero con un payload vacío. Los contenedores tienen como máximo cuatro
elementos hijos y se anidan como máximo en dos niveles. Los métodos son `echo`
y `sum`; los nombres de miembros de struct son `value`, `count`, `enabled` e
`items`. El constructor XML independiente escapa las cinco entidades XML
predefinidas.

## Superficies de entrada y rutas implementadas

Cada nombre selecciona `efz_xmlrpc_<name>_target:run/1`. Los targets ligeros
comparten [`efz_xmlrpc_flow.erl`](../../../examples/xmlrpc/efz_xmlrpc_flow.erl);
los puntos de entrada separados permiten atribuir la cobertura, el corpus y los
resultados a cada flujo.

| Nombre | Flujo de datos real | Contrato comprobado | Límite del alcance |
| --- | --- | --- | --- |
| `call` | Payload → XML `methodCall` construido manualmente → `xmlrpc_decode:payload/1` | El método y los parámetros decodificados son iguales a los de la llamada construida | Nombres de método fijos y valores tipados acotados; sin gramática XML arbitraria |
| `response` | Payload → XML `methodResponse` de un parámetro construido manualmente → decodificador | El valor de respuesta decodificado es igual al valor construido | Las respuestas satisfactorias contienen exactamente un parámetro |
| `fault` | Payload → XML de fallo construido manualmente → decodificador | El código y la cadena del fallo son iguales a los valores construidos | Códigos enteros acotados y cadenas imprimibles |
| `roundtrip` | Payload → `{call, echo, [TypedValue]}` → `xmlrpc_encode:payload/1` → decodificador | La llamada decodificada es igual al valor entregado al codificador | Un parámetro con un valor acotado admitido |
| `dispatch` | Payload → llamada codificada → decodificador → fixture local de echo/sum → respuesta codificada → decodificador | La respuesta final coincide con el resultado esperado de la fixture | Fixture en el mismo proceso; sin servicio RPC externo |
| `encoder_validation` | Payload → valores de Erlang deliberadamente no admitidos → codificador | Registrar `{error, Reason}` como rechazo y cualquier éxito del codificador como aceptado | Un conjunto finito de casos de validación; los errores esperados no son defectos |

El decodificador rechaza el XML de una respuesta satisfactoria vacía
(`{response, []}`). Ese caso no se afirma como una ida y vuelta satisfactoria de
codificación/decodificación. Los errores de validación del codificador son
resultados esperados de la API, registrados como `target_rejected`; no son
defectos ni crashes.
Los casos de validación cubren una tupla de payload no válida, un valor de mapa
no admitido, un nombre de miembro de tipo cadena, un miembro mal formado, un
átomo de array no admitido, texto de fallo que no es una cadena, dos parámetros
de respuesta y un nombre de método de tipo lista. La observación registra si el
resultado coincide con el error esperado; las excepciones se propagan.

El despacho elige echo para longitudes de payload pares y sum para longitudes
impares. Sum usa como máximo los primeros cuatro bytes del payload, resta 128 a
cada byte y compara la respuesta de la fixture con un total calculado de forma
independiente.

La fixture de despacho no llama a `xmlrpc_http` ni a código de servidor o HTTP,
y no abre sockets. Ejercita la codificación, la decodificación y una pequeña
decisión de aplicación local. La suite no establece el comportamiento del
transporte HTTP, los listeners, los ciclos de vida de callbacks, las peticiones
concurrentes, la gramática XML arbitraria ni la conformidad completa con XML-RPC.
El [adaptador existente del decodificador de XML sin procesar](examples/xmlrpc/README.md)
sigue siendo un ejemplo separado con un formato de entrada y un modelo
diferentes.

## Preparar la dependencia

Ejecute desde la raíz del repositorio con Erlang/OTP 27 o posterior, Rebar3 y
`xmerl` de OTP:

```sh
git clone --no-checkout https://github.com/etnt/xmlrpc.git _build/xmlrpc-dependency
git -C _build/xmlrpc-dependency checkout --detach fb46463b2acadf164ec534d9e2033e194341c507
export ERL_FLAGS='+S 2:2'
escript examples/xmlrpc/prepare_flows.escript
rebar3 compile
```

La preparación compila `xmlrpc_encode`, `xmlrpc_decode` y `xmlrpc_util` en
`_build/xmlrpc-example/dependency-ebin`. Rechaza un commit distinto o cambios en
cualquiera de esos tres archivos fuente o en `src/log.hrl`. Los targets y
auxiliares del ejemplo se compilan mediante el directorio fuente existente
`examples/xmlrpc` de Rebar3. La compilación ordinaria no requiere el compilador
de Gleam ni los BEAMs del modelo generados.

Si el checkout está en otra ubicación, pase esa ruta a la preparación y utilice
la misma ruta con la opción `--source` del runner:

```sh
escript examples/xmlrpc/prepare_flows.escript /path/to/pinned-xmlrpc
```

## Ejecutar sin Gleam

```sh
ERL_FLAGS='+S 2:2' escript scripts/xmlrpc_suite.escript \
  --surface all --mode off --iterations 500 --seed 424242 \
  --source _build/xmlrpc-dependency --out _build/xmlrpc-flows-off
```

Los directorios de salida deben ser nuevos. Cada celda de superficie/modo se
ejecuta en una VM nueva con su propio corpus y estado de cobertura. El corpus
de semillas incluye una entrada vacía, caracteres especiales XML, bytes binarios
y el límite de 512 bytes. Use, por ejemplo, `--surface dispatch` para seleccionar
una ruta. El runner acepta `--surface all|NAME`,
`--mode all|off|observation_only|guided`, `--iterations N`, `--seed N`,
`--profile default|gleam`, `--source PINNED_CHECKOUT` y `--out NEW_DIR`.

## Ejecutar los tres modos

```sh
export ERL_FLAGS='+S 2:2'
export GLEAM_BIN=/path/to/gleam-1.10.0
rebar3 as gleam compile
escript scripts/xmlrpc_suite.escript --surface all --mode all --profile gleam \
  --iterations 500 --seed 424242 --source _build/xmlrpc-dependency \
  --out _build/xmlrpc-flows-three-modes
```

| Modo | Fracción estructurada | Admisión | Modelo opcional |
| --- | --- | --- | --- |
| `off` | 0% | Cobertura estructural | Ninguno |
| `observation_only` | 0% | Cobertura estructural; se registran las observaciones | `efz_term_model` de Gleam existente |
| `guided` | 30% | Cobertura estructural o nuevas características semánticas | El mismo modelo de términos con `efz_xmlrpc_flow_adapter` |

El modo de solo observación conserva el flujo de mutaciones de referencia y el
consumo del RNG. El modo guiado cambia las mutaciones seleccionadas y puede
cambiar posteriormente el corpus. El adaptador observa los resultados con el
modelo genérico de términos existente y características finitas del tipo de
resultado, el intervalo del número de elementos, el intervalo del tamaño
codificado y la coincidencia con el error esperado del codificador. Las
operaciones estructuradas sustituyen el selector, añaden un byte o eligen una
muestra acotada. El adaptador no reimplementa el parser XML ni el codificador en
Gleam. El modo off se ejecuta sin el modelo.

Los mismos contratos del harness se ejecutan en todos los modos. El oráculo de
la capa semántica está desactivado: retener una nueva característica semántica
no crea un hallazgo de propiedad. Las excepciones inesperadas y los tiempos de
espera agotados requieren investigación; no son automáticamente defectos
confirmados de la biblioteca. Esta es una suite de integración funcional, no una
búsqueda de un bug conocido ni una prueba de que un modo descubre más defectos.

## Cobertura y salida

La cobertura nativa incluye solo los módulos XML-RPC seleccionados de la versión
fijada: `xmlrpc_encode`, `xmlrpc_decode` y `xmlrpc_util`, según los utilice cada
superficie. Se excluyen las funciones internas del parser `xmerl` de OTP, los
auxiliares de flujo, la fixture local de despacho, el adaptador, el observador y
el código de EFZ. El denominador incluye todas las líneas ejecutables de cada
módulo seleccionado, incluidas las rutas inalcanzables desde el flujo elegido.

Cada directorio `<surface>/<mode>/` contiene:

- `initial-corpus/`, `config.term` e `identity.term`: bytes exactos de las
  semillas, configuración de la campaña, identidades del código fuente y de la
  compilación, de OTP/ERTS y de los auxiliares.
- `target-beams/` y `artifacts.term`: compilaciones de cobertura nativa de los
  módulos de biblioteca seleccionados.
- `report.term`, `snapshot.term` y `summary.term`: resultados de la campaña,
  cobertura, corpus, tiempos, estadísticas semánticas y estructuradas, y
  recuentos de invocaciones.
- `report.etf`: el informe binario sin pérdida. Los términos de texto UTF-8 usan
  etiquetas explícitas `{efz_runtime_identity, Kind, Text}` para las identidades
  en tiempo de ejecución, de modo que `file:consult/1` pueda leer los informes
  mientras los bytes de payload binario permanecen intactos.
- `corpus/` y `crashes/`: artefactos persistentes de EFZ para la reproducción
  habitual.

La raíz de salida contiene `matrix.term`, resúmenes agregados, `summary.csv` y
`comparisons.csv`. Las comparaciones emparejan superficies coincidentes con una
ejecución off y comprueban el hash del corpus inicial, la semilla del RNG y el
presupuesto solicitado.

`target_invocations`, `target_accepted` y `target_rejected` incluyen la
calibración y las mutaciones. La contabilización de invocaciones los comprueba
frente al presupuesto de ejecución. Para `encoder_validation`, los retornos
esperados `{error, Reason}` contribuyen a `target_rejected`. `discoveries` y
`corpus_equivalent_rejections` describen la admisión al corpus,
independientemente de la aceptación o el rechazo de la API. La cobertura de
calibración está separada de `mutation_new_coverage_lines`, de modo que la
cobertura de las semillas no se informa como progreso de las mutaciones.

Las columnas de tiempos describen una campaña por celda. No aíslan el coste del
observador o del adaptador, y el modo guiado tiene una carga de entradas
diferente. Una única ejecución no permite afirmar una superioridad en velocidad,
cobertura o descubrimiento de defectos.

## Comprobaciones de regresión

La dependencia opcional debe estar preparada y presente en la ruta de código
de la VM de pruebas:

```sh
ERL_FLAGS='+S 2:2 -pa _build/xmlrpc-example/dependency-ebin' \
  rebar3 eunit --module=efz_xmlrpc_flow_tests
ERL_FLAGS='+S 2:2 -pa _build/xmlrpc-example/dependency-ebin' \
  GLEAM_BIN=/path/to/gleam-1.10.0 \
  rebar3 as gleam eunit --module=efz_xmlrpc_flow_tests
```

Las comprobaciones específicas ejercitan los contratos compartidos, el manejo
acotado de payloads, las operaciones estructuradas repetibles, la configuración
de la suite y las rutas de observación opcionales. La salida de la campaña sigue
siendo la fuente de los resultados medidos.

La validación local completó 18 campañas de 500 mutaciones: 9 000 mutaciones y
270 calibraciones. Hubo 7 725 invocaciones de flujo aceptadas y 1 545 rechazos
previstos del codificador, sin excepciones, tiempos de espera agotados ni fallos
de infraestructura. Off y observation-only conservaron las mismas entradas,
cobertura y estadísticas de mutación en las seis superficies. Toda la cobertura
estructural observada se alcanzó durante la calibración; las mutaciones no
añadieron líneas en esta ejecución acotada. Guided retuvo 17 entradas en dispatch
frente a 15 en off, sin más cobertura de líneas. Esto confirma la ejecución
funcional, no una ventaja del modo guiado.

Los [resultados CSV](../../xmlrpc-harness-suite-validation/summary.csv), las
[identidades de compilación](../../xmlrpc-harness-suite-validation/identities.term)
y el [manifiesto de reproducción](../../xmlrpc-harness-suite-validation/manifest.json)
registran la ejecución. Los informes completos permanecen en el árbol local
`_build`; el manifiesto contiene sus hashes y el comando exacto. Otras
verificaciones locales se ejecutaron en paralelo, por lo que estos tiempos no
aíslan la sobrecarga de la capa.
