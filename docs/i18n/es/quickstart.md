# Preparar y ejecutar EFZ

[English](../../quickstart.md) · [Русский](../ru/quickstart.md) · **Español** · [简体中文](../zh-CN/quickstart.md) · [Todos los idiomas](../README.md)

Estado verificado el 15 de septiembre de 2026 con OTP 27.0 / ERTS 15.0,
Rebar3 3.25.0, Linux x86_64. El bucle principal guiado por cobertura ya funciona:
mutación → objetivo → nuevas sondas → retención → reutilización como padre.
Lo confirma la [prueba de integración del motor staged real](../../../test/efz_feedback_loop_tests.erl).
El ámbito actual es `Module:run(binary())` síncrono y descendientes controlados;
una aplicación OTP arbitraria todavía no es un objetivo admitido.

## Compilar y preparar

`erl`, `erlc`, `escript` de Erlang/OTP **27 o posterior**, y `rebar3`, deben estar
en `PATH`. La compilación establece ese mínimo; esta ejecución no verificó otras
versiones de OTP. No hay dependencias externas de Rebar. El script no instala
paquetes del sistema.

Desde la raíz del checkout `efz/`:

```sh
escript scripts/prepare.escript
```

El [script](../../../scripts/prepare.escript) comprueba las herramientas y OTP, ejecuta
`rebar3 compile` en el perfil predeterminado, compila el
[efz_staged_parser](../../../examples/staged/efz_staged_parser.erl) existente mediante
`efz_instrument:compile/2`, comprueba el BEAM/manifiesto y `run/1`, y copia las
semillas sin procesar. Termina imprimiendo el comando completo con rutas
absolutas y entrecomilladas para el shell. El `scripts/fuzz.escript` existente
ejecuta la campaña; no hay un motor de fuzzing nuevo.

Repetir la preparación conserva los archivos de semillas idénticos, el corpus
y los hallazgos. Si una semilla con el mismo nombre tiene otro contenido, el
script devuelve un error y conserva el archivo del usuario. El objetivo
instrumentado se recompila. Ejecute preparación y fuzzing secuencialmente:
recompilar durante la campaña vulnera la identidad fijada. Los argumentos no
válidos y fallos de compilación/sistema de archivos producen un código de salida
no nulo.

```sh
escript scripts/prepare.escript --help
# Directorio de datos personalizado; las rutas relativas se resuelven desde el cwd actual:
escript scripts/prepare.escript --dir /tmp/my-efz-run
```

El script puede invocarse por su ruta absoluta desde cualquier directorio.
La salida predeterminada es `efz/_build/quickstart/`. Para ejecuciones largas,
configure `--dir` fuera de `_build` para que una limpieza manual del directorio
de compilación no elimine corpus/caídas. El script no los elimina por sí mismo.

## Corpus de prueba

Los archivos originales están en [examples/staged/corpus](../../../examples/staged/corpus)
y las copias de trabajo en `_build/quickstart/seeds/`. Las cinco entradas
completan la calibración correctamente. El corpus original no contiene una
entrada preparada que provoque una caída.

| Archivo | Bytes exactos (hex) | Propósito |
|---|---|---|
| `00-empty.seed` | vacío, 0 bytes | Cláusula de entrada vacía y mutaciones a partir de una semilla vacía |
| `01-zero.seed` | `00` | Rutas numéricas de límites/aritmética, obtención de `80` y `01` |
| `02-near-token.seed` | `55 4f 4b 45 4e` (`UOKEN`) | Cambiar un bit del primer byte produce `TOKEN`, una nueva cláusula exitosa |
| `03-near-crash.seed` | `43 4f 4f 4d 21` (`COOM!`) | Cambiar un bit o restar 1 al primer byte produce `BOOM!` |
| `04-binary.seed` | `00 ff 80 41 0d 0a` | NUL, bytes no UTF-8 y CR/LF pasan sin cambios |

Las semillas de texto no terminan en salto de línea. Los dos últimos bytes de
la semilla binaria son CR/LF deliberados. No coloque README ni diccionarios en
el directorio de semillas: la CLI lee cada archivo ordinario como una entrada.
`tokens.hex` permanece separado y lo usa el [ejemplo staged](../../../examples/staged/run.escript)
basado en diccionario; la CLI general aún no tiene opción de diccionario, por
lo que aquí se usan las etapas predeterminadas habituales.

## Iniciar fuzzing

Ejecute todos los comandos siguientes desde `efz/`, después de la preparación:

```sh
ERL_FLAGS='+S 4:4' escript scripts/fuzz.escript \
  --target efz_staged_parser \
  --seeds _build/quickstart/seeds \
  --out _build/quickstart/findings \
  --artifacts _build/quickstart/instrumented \
  --corpus-dir _build/quickstart/corpus \
  --mutation staged \
  --coverage-policy strict \
  --timeout 1000 \
  --max-input-bytes 4096 \
  --max-iterations 1000
```

Es una campaña acotada: 1000 ejecuciones de mutación más calibración.
Cuatro schedulers BEAM en `ERL_FLAGS` no significan cuatro workers de EFZ: hay
uno. `BOOM!` provoca deliberadamente `error(artificial_staged_exception)` en el
parser de aprendizaje; es un defecto de demostración, no una vulnerabilidad
descubierta de Erlang/OTP. Las caídas del objetivo por sí solas no producen un
código de salida no nulo. Un fallo de infraestructura produce salida 1, una
CLI/configuración incorrecta produce salida 2. La parada por presupuesto de
ejecuciones informa `completed`.

| Ruta | Contenido |
|---|---|
| `_build/quickstart/instrumented/` | BEAM y `.efz-manifest` del parser seleccionado |
| `_build/quickstart/seeds/` | Cinco entradas iniciales sin procesar |
| `_build/quickstart/corpus/` | Semillas iniciales y descubrimientos exitosos, identidad de contenido SHA-256 |
| `_build/quickstart/findings/report.term` | Informe ETF binario: estadísticas, corpus activo, recetas, grupos de caídas |
| `_build/quickstart/findings/crashes/` | Representantes acotados: `.input`, `.term`, `.recipe`, `.replay`; contadores persistentes |

Reutilice el corpus guardado en una VM nueva:

```sh
ERL_FLAGS='+S 4:4' escript scripts/fuzz.escript \
  --target efz_staged_parser \
  --artifacts _build/quickstart/instrumented \
  --corpus-dir _build/quickstart/corpus \
  --out _build/quickstart/restored-findings \
  --mutation staged --coverage-policy strict \
  --timeout 1000 --max-input-bytes 4096 --max-iterations 1000
```

Las entradas restauradas se calibran de nuevo. Es una campaña nueva, no una
continuación exacta del RNG/cursores/cobertura global. Se rechaza una compilación
incompatible; `--corpus-build-policy recalibrate` permite cambiar deliberadamente
a una compilación nueva. Consulte [corpus persistente](corpus.md). Un
`report.term` existente se sobrescribe al reutilizar el mismo `--out`; distintos
directorios de salida conservan ambos informes.

Reproduzca el primer representante guardado:

```sh
EFZ_CRASH_INPUT=$(find _build/quickstart/findings/crashes -name artifact.input -type f -print -quit)
test -n "$EFZ_CRASH_INPUT" && \
  ERL_FLAGS='+S 4:4' escript scripts/replay.escript \
    --input "$EFZ_CRASH_INPUT" --target efz_staged_parser \
    --artifacts _build/quickstart/instrumented --max-input-bytes 4096

test -n "$EFZ_CRASH_INPUT" && \
  ERL_FLAGS='+S 4:4' escript scripts/replay.escript \
    --recipe "${EFZ_CRASH_INPUT%.input}.recipe" --target efz_staged_parser \
    --artifacts _build/quickstart/instrumented --max-input-bytes 4096
```

Ambas variantes comprueban la identidad guardada de compilación/harness; el
veredicto exitoso es `reproduced`, salida 0. El `.input` sin procesar sigue siendo
el artefacto de referencia. Para su propio objetivo, utilice la
[CLI general y las reglas de instrumentación](cli.md).

## Trabajo pendiente para un uso más amplio

EFZ ya funciona como fuzzer guiado por cobertura para objetivos binarios
síncronos. Las tareas siguientes amplían su ámbito y la fiabilidad de campañas
largas; no implican que falte el bucle principal de realimentación.

| Prioridad | Trabajo | Limitación actual y criterio de preparación |
|---|---|---|
| P1 | Backend de VM Erlang desechable | El guardian limpia descendientes controlados, pero no una aplicación OTP arbitraria, NIF, puertos ni estado externo. El runner padre debe clasificar VM halt/caídas nativas preservando la entrada; tiempo límite/cancelación deben destruir toda la VM propiedad de la ejecución. Consulte el [contrato de ejecución](execution-isolation.md). |
| P1 | Calibración repetida y estabilidad de características | Cada semilla inicial/restaurada se ejecuta actualmente una vez (`efz_worker:handle_info/2`). Hacen falta observaciones repetidas de cobertura/resultado exactos, diagnóstico de inestabilidad y comprobaciones A→dirty→A/VM nueva. El determinismo de las recetas no garantiza el del objetivo. El [modelo propuesto](calibration-readiness.md) aún no está implementado. |
| P1 | Ampliar y verificar la instrumentación en OTP | Actualmente son sondas de cláusulas/resultados del código fuente. Las comprensiones, `maybe` y valores predeterminados de records no literales se rechazan por la transformación estricta o reciben limitaciones. Hacen falta pruebas de equivalencia semántica, harnesses de parsers reales y CI en las versiones declaradas de OTP; las sondas parciales no deben presentarse como cobertura completa de ramas/aristas. Consulte la [sintaxis admitida](coverage.md). |
| P1 | Operar campañas largas | No existe checkpoint/resume exacto; el corpus persistente solo conserva entradas reutilizables. Hacen falta contratos separados de puntos de control, recuperación/migración del almacén de caídas y cuota total de disco. El límite de representantes se aplica por firma; un bloqueo de escritor obsoleto requiere actualmente investigación del operador. [Almacenamiento de caídas](replay.md). |
| P2 | Reducción de corpus y caídas | Ya existe deduplicación por contenido; todavía no existen minimización del corpus conservando cobertura ni reducción de entradas de caídas. Validación: la entrada reducida conserva su firma en la compilación fijada; el corpus minimizado conserva la unión de sondas. |
| P2–P3 | Configuración de mutaciones en CLI y planificación posterior | Diccionario/etapas/RNG están disponibles en la configuración Erlang; la CLI general aún no los expone. Después vendrán validación cómoda de configuración, colas de entradas favorecidas y workers en VM independientes. `efz_config` solo permite actualmente `workers => 1`; un pool paralelo dentro de la VM vulneraría el modelo de aislamiento actual. |

La siguiente etapa mínima para integrar Erlang/OTP con estado es un backend
de VM desechable y una suite de regresión de su ciclo de vida. Para los parsers
síncronos actuales, la calibración repetida y la minimización son primeros pasos
más útiles. La ejecución distribuida y una interfaz de usuario no sustituyen
estas comprobaciones de corrección.

## Validación de esta preparación

Un almacén quickstart limpio produjo: `completed`, 5 calibraciones,
1000 ejecuciones, 3 descubrimientos, 8 entradas activas, 2 ocurrencias de caída
con una firma y 0 fallos de infraestructura. Primera caída:
`COOM! → BOOM!`, padre ID 4, `stage = arithmetic`,
`operations = [{add,0,8,big,-1}]`. Los contadores de una repetición arbitraria
pueden cambiar: la CLI no fija el RNG y el corpus guardado modifica el estado
inicial.

La reproducción de bytes/recetas y la restauración se comprobaron en VM Erlang
separadas. Una campaña nueva sin `--seeds` cargó 8 entradas, realizó
8 calibraciones y 100 ejecuciones de mutación sin fallos de infraestructura.
También se comprobaron la preparación repetida sin cambiar hallazgos/corpus,
la invocación desde otro directorio de trabajo, espacios/apóstrofos en rutas,
una opción desconocida, un argumento ausente, un conflicto de semilla y una
salida no disponible. Resultados locales: `_build/quickstart-checks/`.

El conjunto completo de comprobaciones —`rebar3 compile`, `rebar3 eunit`
(**186 superadas**), `rebar3 ct` (**3 superadas**), `rebar3 xref`,
`rebar3 dialyzer`— terminó con salida 0. Se ejecutaron comprobaciones adicionales
de preparación/CLI; no están incluidas en el número de pruebas EUnit.
