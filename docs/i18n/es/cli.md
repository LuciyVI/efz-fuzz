# Lanzador universal de fuzzing

[English](../../cli.md) · [Русский](../ru/cli.md) · **Español** · [简体中文](../zh-CN/cli.md) · [Todos los idiomas](../README.md)

`scripts/fuzz.escript` carga la aplicación EFZ compilada con una ruta relativa
al propio script, de modo que puede invocarse desde otro directorio de trabajo.
Las rutas de los argumentos son relativas al directorio de trabajo del llamador.
Ejecute primero `rebar3 compile`.

`--coverage-feedback presence|hit_count` selecciona la realimentación de cobertura.
El valor predeterminado es `presence`; `hit_count` es un modo experimental de
contadores exactos descrito en el [informe del prototipo medido](hit-count-experiment.md).
Cambia qué entradas exitosas se conservan y usa el mismo lanzador y motor de
fuzzing.

El lanzador llama una vez a `efz:start/1`, espera con `efz:await/1`, guarda el
informe y detiene EFZ en un bloque `after`. La configuración, comprobación previa
de instrumentación, calibración, mutación, planificación, ejecución, cobertura,
retención y clasificación de caídas usan el núcleo existente.
`efz_instrument:discover/1` construye descriptores de artefactos a partir del
directorio; `preflight/1` valida sus manifiestos incrustados, archivos auxiliares
asociados e identidades del código cargado antes de ejecutar cualquier entrada.

## Harness externo mínimo

Cree `my_parser.erl`:

```erlang
-module(my_parser).
-export([parse/1]).
parse(<<128, Rest/binary>>) -> {high, Rest};
parse(Input) -> {low, Input}.
```

Cree `my_harness.erl`:

```erlang
-module(my_harness).
-export([run/1]).
run(Input) when is_binary(Input) -> my_parser:parse(Input).
```

Desde la raíz de EFZ, prepare y ejecute:

```sh
rebar3 compile
mkdir -p harness-ebin corpus
erlc -o harness-ebin my_harness.erl
printf '\000' > corpus/seed
erl -noshell -pa _build/default/lib/efz/ebin -eval '
  {ok, _} = efz_instrument:compile("my_parser.erl",
      #{modules => [my_parser], source_root => ".", outdir => "instrumented"}),
  halt().'

escript scripts/fuzz.escript \
  --target my_harness --code-path ./harness-ebin \
  --seeds ./corpus --out ./findings --artifacts ./instrumented \
  --mutation staged --timeout 1000 --max-input-bytes 4096 --max-iterations 100
```

Mantenga los BEAM ordinarios del harness/dependencias separados de los artefactos
instrumentados. Se seleccionan todos los archivos `.beam` en `--artifacts` y
deben tener archivos auxiliares `.efz-manifest` válidos y coincidentes. Un BEAM
ordinario allí es un error. Repita `--code-path DIR` para dependencias ordinarias;
esas rutas se añaden al final de la ruta de código de la VM. Las comprobaciones
de carga y exportaciones se realizan después de validar previamente los módulos
instrumentados, por lo que `--target` también puede nombrar un módulo `run/1`
instrumentado.

Las semillas se leen sin recursión, ordenadas por nombre de archivo. Se ignoran
los directorios; los archivos ilegibles o tipos de archivo no admitidos impiden
el lanzamiento. No hay decodificación de texto, eliminación de saltos de línea,
análisis de términos ni truncamiento. Un archivo vacío produce `<<>>`; un
directorio sin archivos es un corpus no válido.

`--out` se crea si es necesario y se comprueba mediante una escritura temporal
antes de la campaña. Los grupos de caídas se publican atómicamente bajo
`OUT/crashes/SIGNATURE_SHA256/OCCURRENCE_ID/` con `artifact.input`, `artifact.term`,
`artifact.replay`, `artifact.recipe` opcional y un manifiesto de integridad.
Un `summary` por firma almacena el recuento persistente y el índice de
representantes; los grupos antiguos sin él rechazan nuevas escrituras.
`OUT/report.term` es un término externo Erlang con el informe final completo
del núcleo, incluidas las entradas del corpus en memoria y sus metadatos;
sustituye un informe anterior en esa ruta. Añada `--corpus-dir DIR` para persistir
y reutilizar entradas exitosas. La siguiente invocación puede omitir `--seeds`
si ese almacén no está vacío. También se pueden combinar `--seeds` y
`--corpus-dir`; los contenidos duplicados se unifican. La política predeterminada
ante diferencias de compilación es `reject`; `--corpus-build-policy recalibrate`
permite explícitamente reutilizar entradas con distintas identidades de
objetivo/compilación. Ambas políticas recalibran todas las entradas cargadas.
Esto no restaura un punto de control de la campaña. Consulte
[corpus persistente](corpus.md) para almacenamiento, errores de integridad y
diagnósticos.

Los valores predeterminados de la CLI son modo staged, tiempo límite de 100 ms
y 1.000 ejecuciones de mutación. Las ejecuciones de calibración se cuentan por
separado. `--mutation random` selecciona el mutador aleatorio existente. Ambos
modos aplican `--max-input-bytes` de la campaña (predeterminado 4096, inclusivo
0..1048576), incluida la lectura acotada de semillas sin procesar. La CLI no
admite MFA arbitrario, cobertura manual ni evaluar un archivo de configuración
como código Erlang. `--help` enumera todos los parámetros aceptados. Las opciones
de valor único desconocidas o duplicadas y los valores ausentes/no válidos
producen un error explícito.

`--coverage-policy diagnostic` es el valor predeterminado: `report.term` enumera
explícitamente los artefactos no observados y la CLI imprime diagnósticos de
cobertura. `--coverage-policy strict` devuelve el código **1** si la campaña
termina sin ninguna sonda instrumentada. Una entrada válida vacía no hace fallar
la campaña inmediatamente. Esta política es independiente del modo estricto de
sintaxis de instrumentación. Consulte [integridad de cobertura](coverage-integrity.md).

| Código de salida | Significado |
|---|---|
| 0 | `completed`, agotamiento real de mutaciones o parada por inactividad; las caídas/tiempos límite del objetivo son hallazgos |
| 2 | Argumentos no válidos, rutas de semillas/salida inaccesibles, artefactos incorrectos, módulo/callback no disponible o configuración de campaña no válida |
| 1 | Fallo de infraestructura de campaña, excepción inesperada del lanzador/runtime o fallo al guardar el informe final |

## Esquema del mapa de campaña

`efz_config:prepare/1`, usado también por `efz:start/1`, requiere un mapa y
rechaza las claves de primer nivel desconocidas con
`{error,{unknown_campaign_keys,Keys}}` **antes** de cargar artefactos u objetivos.
El esquema de entrada es:

| Clave | Valor aceptado |
|---|---|
| `target` | Átomo de módulo obligatorio que exporta `run/1` |
| `seeds` | Lista obligatoria de binarios; puede estar vacía cuando `corpus_dir` restaura un corpus no vacío |
| `timeout` | Milisegundos enteros no negativos; predeterminado 100 |
| `workers` | `1` |
| `mutator` | Módulo que exporta `mutate/2`; predeterminado `efz_mutator_random`; los callbacks personalizados requieren modo aleatorio |
| `mutation_mode` | `random` (predeterminado de la API) o `staged` |
| `max_iterations` | Entero no negativo o `infinity` en modo aleatorio; 0..1.000.000 en modo staged; si se omite en staged pasa a 1.000 |
| `max_input_bytes` | Límite binario de campaña, inclusivo 0..1.048.576; predeterminado 4.096; se aplica a ambos modos, lectura, restauración y ejecución |
| `mutation` | Mapa solo para staged, validado por `efz_mutation_plan:prepare/2`; consulte [límites de mutación](mutations.md) |
| `coverage` | `automatic` (predeterminado) o modo explícito de compatibilidad `manual`, solo en API |
| `coverage_backend` | `ets` (predeterminado), `ets_member` o `bitmap` (solo presencia automática) |
| `coverage_bitmap_bits` | Capacidad del bitmap en bits, predeterminada `65536`; múltiplo positivo de 64 |
| `coverage_validation` | `prepared` (predeterminado) o `per_execution` |
| `coverage_policy` | `diagnostic` (predeterminado) o `strict`: hacer fallar una campaña sin sondas automáticas observadas |
| `artifacts` | Lista de mapas descriptores de artefactos; el modo automático requiere artefactos válidos y no vacíos |
| `crash_policy` | Mapa estricto: `reason` = `category` (predeterminado), `exact` o `ignore`; `max_frames` = 1..32 (predeterminado 5); `max_representatives` = 1..32 (predeterminado 3), limita disco e informe por firma entre reinicios. Opción de API; consulte [caídas/reproducción/informe](replay.md) |
| `crash_dir` | Ruta de sistema de archivos como lista/binario no vacío; predeterminada `_build/efz-crashes` |
| `random_seed` | Tupla opcional de tres enteros no negativos para el PRNG del worker heredado |
| `selection_seed` | Tupla opcional de tres enteros no negativos o `undefined` para la selección del corpus heredada |
| `corpus_dir` | Ruta opcional no vacía; carga y guarda de forma persistente entradas reutilizables del corpus |
| `corpus_build_policy` | `reject` (predeterminado) o `recalibrate`; requiere `corpus_dir` |

El RNG de las mutaciones staged se configura en `mutation.seed`. La CLI resuelve
`--code-path` y los argumentos de directorios de semillas/salida en el lanzador;
no son claves adicionales del mapa de campaña. Tampoco se aceptan `manifests`
derivados, planes de cobertura ni estado del coordinador como opciones del usuario.

`function` y `arity` se rechazan incluso con los valores `run` y `1`: el contrato
del callback es fijo. Cualquier adaptación debe ir en `Module:run(Input)`.
`corpus_dir` selecciona ahora el formato persistente específico; el directorio
`--seeds` sigue conteniendo archivos ordinarios de semillas sin procesar.
`max_input_bytes => N` es una opción de primer nivel;
`mutation => #{max_input_bytes => N}` se rechaza con
`{campaign_level_option,max_input_bytes}`. La CLI asigna `--max-input-bytes`
directamente a la opción de campaña. Consulte [contrato de entrada/almacenamiento](input-and-storage.md).

```sh
rebar3 eunit --module=efz_cli_tests,efz_config_tests
```

La suite de caja negra ejecuta el lanzador de producción en VM Erlang nuevas,
empaqueta la compilación actual para evitar BEAM antiguos del perfil
predeterminado y utiliza un harness ordinario externo con un parser instrumentado
automáticamente. Verifica la entrega de entradas sin procesar, la retención real
de cobertura, ambos modos de mutación, rutas y artefactos no válidos, errores de
callback, hallazgos de caídas/tiempos límite y códigos de salida de error.

## Diagnósticos automáticos de ejecución

`--runtime-diagnostics` activa la política `runtime_oracles` del núcleo
(desactivada por defecto). `--runtime-runs N` establece el total de ejecuciones
de semillas/interesantes/sospechosas/fallos, incluida la original, 1..16;
`--verification-budget N` limita las ejecuciones adicionales de toda la campaña,
0..1000000; `--sample-interval MS` establece 1..10000 ms. Estas opciones con valor
requieren la opción de activación. Toda la validación se comparte con el núcleo.
La verificación no consume `--max-iterations`. Los umbrales y límites avanzados
están disponibles mediante el mapa con espacio de nombres de la API; se rechazan
las claves anidadas desconocidas.

Las observaciones de ejecución son independientes de las caídas. Utilice
`scripts/replay.escript --runtime-finding DIRECTORY --target MODULE --artifacts DIR --runs 3`
y añada `--code-path` para un harness ordinario. El contenido del artefacto no
puede seleccionar el código del objetivo. La CLI resuelve los nombres de módulo
a partir de BEAM locales de confianza, sin convertir el texto de argumentos en
átomos. Consulte [esquema completo y límites](runtime-diagnostics.md).

## VM externa del worker

En Linux, añada `--supervised` al comando habitual de fuzzing. La delegación
ocurre antes de que la CLI cargue el harness o el objetivo. El controlador
externo calcula las identidades de los archivos locales y lanza la CLI/campaña
real en un proceso BEAM del sistema operativo separado. Todas las ejecuciones
del objetivo, incluidas calibración y verificación P0, pasan por una barrera
persistente de entradas en `efz_executor`.

Las opciones adicionales acotadas son `--restart-budget` (predeterminado 8),
`--supervised-runs` (10000), `--campaign-ms` (3600000), `--startup-ms` (10000),
`--ipc-grace-ms` (1000) y `--journal-bytes` (268435456). Solo las acepta el modo
supervisado. La salida incluye `external-report.json`, un registro
`external-runs/`, directorios por generación de worker e índices de hallazgos
externos bajo `crashes/external/`. Compruebe de nuevo un hallazgo con:

```sh
escript scripts/replay.escript \
  --external-finding OUT/external-runs/CAMPAIGN/RUN \
  --target MODULE --artifacts ARTIFACTS --code-path HARNESS_EBIN \
  --out RECHECK_OUT --reproduce-runs 3
```

El artefacto nunca selecciona código ejecutable. Las identidades locales del
objetivo/artefactos deben coincidir. Una campaña supervisada devuelve 0 solo en
finalización normal/por presupuesto (la comprobación también devuelve 0 con su
veredicto explícito de reproducción), 2 por errores de argumentos y 1 por fallo
de arranque, protocolo, almacenamiento, tiempo límite externo sin recuperación
o presupuesto de reinicios. El controlador informa `observed N/M`, `not_observed`
o `inconclusive`; nunca considera que una ejecución exitosa refute una caída
intermitente. Consulte [P1-01 Supervisor externo](p1-01-external-supervisor.md).
