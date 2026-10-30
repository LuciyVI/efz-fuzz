# EFZ (fuzzer para Erlang)

[English](../../../README.md) · [Русский](../ru/README.md) · **Español** · [简体中文](../zh-CN/README.md) · [Todos los idiomas](../README.md)

EFZ es un fuzzer en Erlang con gestión de corpus, mutaciones binarias aleatorias
y por etapas conectables, recetas exactas de candidatos, ejecución controlada
del objetivo, artefactos de caídas e instrumentación automática del código
fuente. EFZ no depende de otros motores de fuzzing.

Capa semántica/Gleam opcional: [conectar bibliotecas Erlang](gleam-layer/connecting-erlang-libraries.md) ·
[validación final de P5](gleam-layer/p5-validation.md) ·
[generación automática de conectores desde `-spec`](gleam-layer/connector-generation.md).

Modo continuo: [staged/Gleam sin límite de ejecuciones](continuous.md).

TUI: [panel de campaña en terminal](tui.md) — `python3 scripts/tui.py --demo --out _build/tui-demo-1`.

Documentación: [arquitectura y UML](architecture.md) ·
[mapa de todos los directorios y archivos](repository-map.md).

La [auditoría del backend original de presencia y comparación con AFL++](coverage-tracking-audit.md)
está fijada al commit `205e18b`. También está disponible la
[realimentación experimental por número de aciertos](hit-count-experiment.md):
`coverage_feedback => hit_count` o CLI `--coverage-feedback hit_count`.
El valor predeterminado sigue siendo `presence`. La presencia automática admite
la opción `coverage_backend => bitmap`: un bit por sonda estructural exacta,
sin hashing ni cobertura de aristas.

Inicio rápido con un corpus de prueba preparado:

```sh
# Desde efz/: comprobar OTP/Rebar3, compilar, instrumentar y preparar archivos iniciales del corpus.
escript scripts/prepare.escript
# Ejecute el comando que imprime el script.
```

[Comando de fuzzing verificado, reproducción y etapas pendientes de desarrollo](quickstart.md).
La preparación usa el parser staged existente; `BOOM!` es una caída de
demostración.

La fase 2 recopila **cobertura del código fuente de cláusulas de función y
resultados de ramas dentro de una ejecución**. Los objetivos ordinarios no
necesitan llamadas a EFZ. La compilación instrumenta módulos de una lista
explícita; los archivos BEAM y manifiestos de fuente se sitúan en un directorio
separado. Un worker de campaña calibra las entradas iniciales y conserva las
mutaciones exitosas que alcanzan puntos de cobertura no observados antes.
Las excepciones, salidas y tiempos límite conservan la cobertura y aparecen en
los resultados; los fallos de infraestructura detienen la campaña.

El modo adicional `hit_count` conserva entradas exitosas que alcanzan un nuevo
intervalo de recuento para un punto de cobertura exacto existente. La novedad
de sondas y de contadores se registra por separado (`new_probe` / `new_hit_count`);
se usan los mismos mecanismos de mutación, ejecución, corpus y reproducción.
Consulte los [resultados del experimento](hit-count-experiment.md) antes
de elegir un modo.

Modelo de ejecución: un harness síncrono de entrada binaria y procesos hijos
controlados creados mediante `efz_target:spawn/1` o `spawn_link/1`. Un guardian
independiente gestiona su ciclo de vida y cobertura, espera la limpieza antes
de devolver el resultado y retira las VM contaminadas. Consulte
[aislamiento de ejecución y reglas de estado compartido](execution-isolation.md).
Las aplicaciones OTP asíncronas arbitrarias requerirán un backend separado de
VM desechables.

Entorno verificado: Erlang/OTP **27.0**, ERTS 15.0, Linux x86_64,
Rebar3 3.25.0. La versión mínima configurada es OTP 27; aquí no se verificaron
otras versiones.

```sh
rebar3 compile
rebar3 eunit
rebar3 ct
rebar3 dialyzer
rebar3 xref
```

Ejecute su propio `my_harness:run(Input) when is_binary(Input)` mediante la CLI
general:

```sh
escript scripts/fuzz.escript \
  --target my_harness \
  --code-path ./harness-ebin \
  --seeds ./corpus \
  --out ./findings \
  --artifacts ./instrumented \
  --mutation staged \
  --timeout 1000 \
  --max-input-bytes 4096 \
  --max-iterations 1000

escript scripts/fuzz.escript --help
```

Compile un harness ordinario en `harness-ebin`; este llama a su parser u otro
código bajo prueba. Compile los módulos seleccionados del objetivo con
`efz_instrument:compile/2` en `instrumented` —pares BEAM y `.efz-manifest`,
como muestra el ejemplo posterior—. Repita `--code-path` para los directorios
BEAM de dependencias. El propio harness puede estar entre los módulos
instrumentados si exporta `run/1`.

El lanzador lee los archivos ordinarios del corpus inicial como datos binarios
sin procesar, ordenados por nombre. Se permiten archivos vacíos, pero no un
directorio vacío. Antes de ejecutar se comprueban los artefactos, la exportación
`run/1` y la disponibilidad del directorio de salida. Los hallazgos van a
`findings/crashes/`; `findings/report.term` contiene el informe de campaña,
incluido el corpus activo. Reutilizar el directorio de salida reemplaza ese
informe. Códigos de salida: `0` para finalización normal, incluidas caídas del
objetivo; `2` para argumentos o configuración no válidos; `1` para fallos de
infraestructura de ejecución o al guardar el informe. La CLI usa por defecto
mutaciones staged y 1000 ejecuciones de mutación. Los valores predeterminados
de la API Erlang no cambian salvo el límite compartido de tamaño de entrada.
`--max-input-bytes` se aplica a los modos staged y aleatorio —predeterminado
4096, inclusivo, rango 0..1048576—.

Los mapas de configuración de campaña rechazan claves de primer nivel
no conocidas, incluidas `function` y `arity`. El callback estándar es `run/1`;
`max_input_bytes => N` se configura al nivel de campaña. La opción anidada
antigua `mutation.max_input_bytes` se rechaza con un mensaje explícito de
migración. Las entradas demasiado grandes se rechazan sin truncar. Consulte
[límites de entrada y fallos de almacenamiento](input-and-storage.md)
y [configuración de CLI y esquema de campaña](cli.md).

Para un corpus persistente entre ejecuciones, configure
`--corpus-dir ./findings/corpus` (API Erlang:
`corpus_dir => "./findings/corpus"`). Las entradas iniciales y los descubrimientos
exitosos con cobertura nueva se guardan por SHA-256 antes de confirmar su
admisión al corpus. Use el mismo directorio en la siguiente ejecución; entonces
puede omitir `--seeds`. Las semillas proporcionadas junto a entradas restauradas
se deduplican por contenido. Cada entrada restaurada se recalibra y puede
convertirse en padre de una mutación.

Se restauran entradas reutilizables, no el estado exacto de campaña: no se
restauran cursores del planificador, estado del RNG, cobertura global ni los
antiguos identificadores enteros de cola. Por defecto, una identidad distinta
del objetivo o compilación produce un error. La opción explícita
`--corpus-build-policy recalibrate` admite entradas de otra compilación con
diagnósticos y nueva recopilación de cobertura. Una entrada persistente corrupta
provoca un error de restauración; las escrituras intermedias incompletas se
excluyen con diagnósticos. Consulte [formato del corpus persistente, garantías
y pruebas](docs/corpus.md).

Ejecute el ejemplo acotado desde la raíz del repositorio:

```sh
escript examples/automatic/run.escript
```

El ejemplo compila solo `efz_example_parser`, utiliza el adaptador separado
`efz_example_target`, calibra `<<0>>` y realiza 500 mutaciones con el mutador
aleatorio estándar y una semilla RNG fija. El informe se escribe en
`_build/example-report.term`, la compilación instrumentada en
`_build/instrumented-example` y los artefactos de caídas artificiales en
`_build/example-crashes`. El parser es código fuente Erlang ordinario;
`artificial_example_exception`, provocada deliberadamente, demuestra un fallo
del objetivo.

Para una ejecución interactiva después de compilar, abra un `rebar3 shell`
nuevo:

```erlang
{ok, Artifact} = efz_instrument:compile(
    "examples/simple_parser/efz_example_parser.erl",
    #{modules => [efz_example_parser], source_root => ".",
      outdir => "_build/instrumented-shell"}).
{ok, _} = efz:start(#{target => efz_example_target, artifacts => [Artifact],
                     seeds => [<<0>>], max_iterations => 500,
                     timeout => 100, workers => 1, random_seed => {17,23,41}}).
Report = efz:await(30000).
efz:stats().
efz:stop().
```

Los objetivos siguen implementando `run/1`; los adaptadores pueden llamar a
uno o varios módulos seleccionados en el mismo proceso.
`efz_executor:run/3` conserva la API de tuplas de fase 1 en un modo explícito
de compatibilidad manual; `run/4` añade metadatos de cobertura por ejecución.
Las campañas automáticas requieren artefactos validados; no recurren a
realimentación manual. No precargue un objetivo ordinario ni reemplace su código
durante una campaña; use una VM nueva al cambiar de compilación.

```sh
# Comprobaciones deterministas de cobertura, semántica, identidad y ciclo de vida:
rebar3 eunit --module=efz_phase2_tests
# Bucle real de cobertura: <<>> -> A -> AB -> ABC, IDs de padres conservados,
# entrega exacta de la entrada al harness y reconstrucción de la receta en una VM nueva:
rebar3 eunit --module=efz_feedback_loop_tests
# Medición local repetible del rendimiento después del calentamiento:
escript scripts/coverage_bench.escript
# Compilación ordinaria limpia sin eliminar resultados existentes:
EFZ_CLEAN_BUILD=$(mktemp -d /tmp/efz-clean.XXXXXX)
REBAR_BASE_DIR="$EFZ_CLEAN_BUILD" rebar3 compile
```

La implementación se describe en [API de cobertura, sintaxis admitida,
manifiestos, mediciones y limitaciones](docs/coverage.md),
[arquitectura bitmap](coverage-bitmap-architecture.md),
[informe de implementación y mediciones](coverage-bitmap-implementation-report.md),
[integridad de cobertura, identidades fijadas y política de cobertura nula](coverage-integrity.md),
[arquitectura EFZ y diagramas UML](architecture.md),
[registro de decisión arquitectónica](adr/0002-automatic-coverage.md)
y [resultados de validación](phase2-validation.md).

La cobertura y limpieza incluyen la raíz y los hijos controlados. Los hijos
creados arbitrariamente, aplicaciones OTP con estado, estado compartido de la
VM, fallos nativos, campañas distribuidas, mutaciones conscientes de gramática
y minimización del corpus quedan fuera de esta fase. Un proceso Erlang no es
una zona aislada de seguridad a nivel de VM o sistema operativo.

Las identidades exactas de cobertura se validan una vez por campaña. El backend
predeterminado `ets` utiliza `insert_new` e informa de la primera observación
al guardian de forma independiente; `coverage_backend => ets_member` comprueba
si existe una entrada antes de insertarla. La opción `coverage_backend => bitmap`
con `coverage_bitmap_bits => 65536` usa un esquema de campaña y un bitmap
atómico por ejecución para la presencia automática de sondas. Configure
`coverage_backend => ets` para volver a la implementación de referencia.
Los resultados de reutilización, aislamiento y rendimiento del bitmap están en
el [informe bitmap v2](coverage-bitmap-v2-results.md). El backend experimental
`coverage_backend => otp_native_public` usa las API públicas de cobertura de
líneas ejecutables de OTP 27+ y artefactos del objetivo compilados por separado.
Sus semánticas de cobertura difieren; ETS sigue siendo el predeterminado.
Consulte [mediciones breves y limitaciones](otp-native-public-results.md).
ETS y bitmap conservan observaciones por ejecución y recuperación tras caídas
o tiempos límite. Las compensaciones medidas y artefactos originales se
encuentran en el [informe de rendimiento](phase2.1-performance.md).
Configure `random_seed` y, opcionalmente, `selection_seed` para reproducir las
mutaciones y selección del corpus.

La identidad del harness y los módulos instrumentados seleccionados se fija
para la campaña. El reemplazo en caliente o la corrupción del contexto de
ejecución provoca un fallo de infraestructura aunque el objetivo capture la
excepción del hook de cobertura. Una entrada válida sin puntos de cobertura
observados recibe `valid_empty_coverage`. `coverage_diagnostics` enumera los
artefactos no usados; `--coverage-policy strict` (API:
`coverage_policy => strict`) hace fallar la campaña si no se observó ningún
punto durante toda ella. La política predeterminada es `diagnostic`. La
calibración sin aciertos avisa, pero permite que las mutaciones encuentren el
primer punto. Las cifras históricas de rendimiento preceden a estas
comprobaciones de integridad.

```sh
# Recompilar el fixture disperso grande de forma determinista:
escript bench/generate_sparse.escript
# Todos los niveles de medición de rendimiento sin perfilador (varios minutos):
ERL_FLAGS='+S 4:4' escript bench/run.escript all _build/performance
escript bench/report.escript _build/performance
# Medir memoria por separado del rendimiento:
ERL_FLAGS='+S 4:4' escript bench/run.escript memory _build/performance-memory prepared
# Comprobaciones diferenciales de backend/validador y ciclo de vida:
rebar3 eunit --module=efz_backend_tests
```

La fase 3 añade **mutaciones staged conectables**. Las configuraciones existentes
conservan los valores predeterminados anteriores de mutación aleatoria y
cobertura. El planificador staged usa estado `exsplus` explícito, cursores
perezosos por contenido, havoc acotado, diccionarios binarios y donantes para
splice identificados por contenido. Las recetas registran operaciones y bytes
concretos; reconstruirlos no requiere estado RNG ni una campaña activa.

```sh
rebar3 compile
# Parser ordinario, archivo de diccionario, operadores reales de mutación, guardado de caídas y reproducción:
ERL_FLAGS='+S 4:4' escript examples/staged/run.escript
# Reconstruir bytes exactos en una VM nueva sin ejecutar el objetivo:
escript scripts/replay.escript _build/staged-example.recipe _build/regenerated.input
cmp _build/staged-example.input _build/regenerated.input
# Ejecutar bytes originales en otra VM comprobando la compilación y el harness guardados:
escript scripts/replay.escript --input _build/staged-example.input \
  --target efz_staged_parser --artifacts _build/staged-targets
# La misma ejecución desde una receta de mutación concreta:
escript scripts/replay.escript --recipe _build/staged-example.recipe \
  --target efz_staged_parser --artifacts _build/staged-targets
```

En un shell Erlang nuevo con EFZ en la ruta de código:

```erlang
{ok, A} = efz_instrument:compile("examples/staged/efz_staged_parser.erl",
    #{modules => [efz_staged_parser], source_root => ".",
      outdir => "_build/staged-shell"}).
{ok, _} = efz:start(#{target => efz_staged_parser, artifacts => [A],
    seeds => [<<0>>], mutation_mode => staged, max_iterations => 200,
    max_input_bytes => 64,
    mutation => #{seed => {17,23,41}, dictionary => [<<"TOKEN">>, <<"BOOM!">>],
        stages => [dictionary_insert,boundary,arithmetic,havoc,splice],
        max_block_bytes => 16, max_token_bytes => 16,
        max_tokens => 16, max_dictionary_bytes => 256,
        attempts_per_visit => 8, havoc_depth => 4, random_retries => 4,
        max_idle_visits => 256}}).
StagedReport = efz:await(30000).
ok = efz:stop().
[Crash | _] = maps:get(crashes, StagedReport).
Recipe = maps:get(mutation, maps:get(metadata, Crash)).
ok = efz_recipe:save("_build/saved.recipe", Recipe).
ok = file:write_file("_build/saved.input", maps:get(input, Crash)).
{ok, Regenerated} = efz_recipe:regenerate(Recipe).
{ok, Expected} = efz_replay:load(maps:get(path, Crash) ++ ".replay").
{ok, Replay} = efz_recipe:execute_file("_build/saved.input",
    efz_staged_parser, [A], maps:get(target_builds, Recipe),
    #{timeout => 100, expected_harness => maps:get(harness, Expected)}).
maps:get(outcome, Replay).
```

Para usar un **diccionario hexadecimal de EFZ**, sustituya `dictionary => [...]`
por `dictionary_file => "examples/staged/tokens.hex"`. Formato: un token por
línea, con un número par de caracteres hexadecimales; se permiten líneas vacías
y comentarios que empiecen por `#`. Se rechazan tokens vacíos, se eliminan
duplicados y se ordenan los tokens. El diccionario normalizado se fija para la
campaña. Si no se proporciona la semilla RNG de mutación, se crea una vez y
se registra en `StagedReport.mutation`.

Los archivos `.input` sin procesar siguen siendo la fuente de referencia de
bytes. Para ejecutarlos se requiere seleccionar explícitamente un objetivo
local compatible; una receta no puede elegir código ejecutable. La reproducción
usa la identidad `.replay` guardada e informa `reproduced` (código 0) o
`not-reproduced` (código 3). Una compilación o harness distintos se rechazan
(código 2); los fallos de infraestructura devuelven código 1. Los informes
cuentan ocurrencias de cada firma normalizada. La política predeterminada
`crash_policy => #{reason => category, max_frames => 5, max_representatives => 3}`
conserva los tres primeros representantes de entradas distintas **tanto en
disco como en el informe**; `reason` también acepta `exact` e `ignore`.
El `summary` en disco cuenta todas las ocurrencias registradas y conserva el
límite entre reinicios de VM. Los artefactos seleccionados conservan bytes
originales exactos y el `Reason` completo; otras entradas se cuentan sin
archivos de artefactos separados. `storage` distingue `saved`, `duplicate` y
`limit_reached`; solo los dos primeros proporcionan una ruta al artefacto con
la entrada exacta. Los grupos antiguos sin `summary` siguen siendo reproducibles;
use un directorio de salida nuevo para almacenamiento con límite de
representantes. Un almacén interrumpido o corrupto informa un error en vez de
reiniciar contadores o eludir el límite. Consulte [semántica de operadores,
orden de etapas y límites](docs/mutations.md), [formato de recetas y API de
reproducción](docs/replay.md) y [validación de fase 3 y costes medidos](phase3-validation.md).

```sh
# Series acotadas solo de mutaciones y campañas con presupuestos comparables, sin perfilado:
ERL_FLAGS='+S 4:4' escript bench/mutations.escript _build/phase3-performance
```

## Ejecutar con Cowboy

El wrapper `efz_cowboy_target:run/1` pasa bytes de la cadena de consulta sin el
`?` inicial a `cowboy_req:parse_qs/1`. La cobertura se recoge automáticamente
de `cowboy_req` y `cow_qs` (Cowlib). No se inicia un listener HTTP: se prueba
el análisis síncrono de cadenas de consulta en el proceso del objetivo.

Combinación verificada: OTP 27.0, Rebar3 3.25.0, Cowboy 2.19.0 y Cowlib 2.20.0.
La compilación requiere además Git, GNU Make y acceso a las dependencias públicas
de Cowboy. Ejecute todos los comandos siguientes en una misma terminal desde
la raíz **efz/**; las fuentes de Cowboy deben estar en el directorio hermano
**../cowboy/**.

Compile EFZ y una copia separada de Cowboy. La copia en `/tmp` es necesaria por
la ruta actual `erl:fuzz`: los dos puntos causan el error de `erlang.mk`
`target pattern contains no '%'`. El checkout original se conserva.

```sh
rebar3 compile
COWBOY_BUILD=$(mktemp -d /tmp/efz-cowboy.XXXXXX)
cp -a ../cowboy "$COWBOY_BUILD/cowboy"
make -C "$COWBOY_BUILD/cowboy"
```

Si la descarga de dependencias se detiene con `Proxy CONNECT aborted` y hay
acceso directo a GitHub, repita la compilación sin variables de proxy:

```sh
env -u HTTPS_PROXY -u HTTP_PROXY -u ALL_PROXY \
    -u https_proxy -u http_proxy -u all_proxy make -C "$COWBOY_BUILD/cowboy"
```

Después de compilar correctamente, compruebe el wrapper y ejecute
500 mutaciones:

```sh
escript examples/cowboy/run.escript "$COWBOY_BUILD/cowboy" check
escript examples/cowboy/run.escript "$COWBOY_BUILD/cowboy" 500
```

`check` ejecuta 14 comprobaciones EUnit adicionales sobre la versión de Cowboy
seleccionada. El último argumento establece el número de ejecuciones:
1–100000, predeterminado 500. El ejemplo usa mutaciones staged, semilla RNG
`{17,23,41}`, un diccionario pequeño, corpus inicial `[<<>>]` y límite de entrada
de 1024 bytes. Se conservan los valores predeterminados de cobertura de EFZ:
validación preparada y ETS. Cada invocación de escript inicia una VM nueva.

Al final se imprimen estado y estadísticas. El informe completo se guarda en
`_build/cowboy-report.term`, los BEAM instrumentados y manifiestos en
`_build/cowboy-targets/`, y los artefactos de caídas inesperadas en
`_build/cowboy-crashes/`. El rechazo esperado de análisis devuelve
`{invalid, Reason}` y no se cuenta como caída del objetivo.

El lanzador advierte de dos comprensiones de listas de `cowboy_req` conservadas
sin sondas internas de cobertura; no están en la ruta `parse_qs/1`. Consulte
el [README del wrapper de Cowboy](examples/cowboy/README.md) para conocer el
ámbito, la semántica de errores y las limitaciones.

## Diagnósticos automáticos de ejecución (opcionales)

P0 añade calibración y verificación repetidas, muestreo acotado de procesos y
ETS propiedad de la ejecución, observaciones de salida de hijos y evidencias
de tiempos límite. No es necesario modificar los harnesses `run/1` existentes.
Actívelo con `runtime_oracles => #{enabled => true}` o las opciones de CLI
`--runtime-diagnostics --runtime-runs 3 --verification-budget 1000 --sample-interval 20`.
Los resultados de ejecución, la retención de cobertura y el modelo de
descendientes controlados no cambian. Los hallazgos se escriben en
`OUT/runtime-findings/`; la reproducción usa
`replay.escript --runtime-finding DIRECTORY --target MODULE --artifacts DIR`.
Consulte [política, categorías, límites y ejemplos](runtime-diagnostics.md)
y [resultados de validación y rendimiento](runtime-diagnostics-validation.md).

## VM externa del worker (Linux, opcional)

`--supervised` ejecuta el mismo bucle de campaña en un proceso BEAM del sistema
operativo propiedad del lanzador. Cada llamada al executor publica primero su
entrada exacta en el registro externo y espera un permiso RUN vinculado al
resumen criptográfico. Una caída nativa de VM, tiempo límite externo o runner
contaminado retira esa VM; el controlador espera la limpieza confirmada a nivel
del sistema operativo, inicia otra generación, restaura el corpus persistente,
lo recalibra y continúa dentro de los presupuestos globales de campaña. Los
harnesses `run(binary())` existentes y el modo heredado no cambian. Compile
primero con `rebar3 compile` —también compila el pequeño helper de ciclo de vida
para Linux— y añada `--supervised` al comando habitual.

Las garantías exactas, formato de registro, comando de reproducción, límites de
recuperación y evidencias de caídas nativas están en
[P1-01 Supervisor externo](p1-01-external-supervisor.md).

```sh
ERL_FLAGS='+S 4:4' escript scripts/fuzz.escript \
  --supervised --target my_harness --code-path harness-ebin \
  --artifacts instrumented --seeds corpus --corpus-dir out/corpus \
  --out out --timeout 1000 --max-iterations 10000
```

El modo supervisado no está disponible deliberadamente en sistemas distintos
de Linux, en lugar de debilitar silenciosamente las garantías de limpieza del
worker y de muerte del padre.

## Integraciones y guías actuales

- [Erlamsa](erlamsa-integration.md)
- [Persistent worker](erlamsa-performance.md)
- [Feature stability](feature-stability.md)
- [Python SDK](packages/pyefz/README.md)

- [VM persistente del objetivo](persistent-target.md)
