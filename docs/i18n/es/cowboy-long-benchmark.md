# Benchmark largo de Cowboy: ETS, bitmap-v2 y OTP-public

[English](../../cowboy-long-benchmark.md) · [Русский](../ru/cowboy-long-benchmark.md) · **Español** · [简体中文](../zh-CN/cowboy-long-benchmark.md) · [Todos los idiomas](../README.md)

## Objetivo y límites del target

El benchmark ejecuta una campaña EFZ normal durante 900 segundos. El input son
los bytes de una petición HTTP/1.x. `efz_cowboy_long_target:run/1` los entrega a un
`cowboy_http:init/6` real mediante el transporte en memoria `efz_cowboy_transport`;
`cowboy_http:loop/1` y sus funciones internas `parse_request/3`, `parse_header/4`,
`request/*`, `parse_body/2` analizan la línea, método, URI, versión, cabeceras,
`Content-Length` y codificación chunked. `efz_cowboy_stream:init/3`
llama a `cowboy_router:execute/2` y `cowboy_req:parse_qs/1`; para el cuerpo,
acepta `cowboy_stream:data/4` hasta `fin`. No hay listener de red, acceptor Ranch
ni TCP. Es la ruta real de parser/stream de Cowboy, pero no el pipeline completo de
handlers HTTP ni un benchmark de red.

Los errores de parser y peticiones incompletas devuelven el normal `{ok,rejected}`.
El sink del stream pasa excepciones inesperadas a la clasificación estándar de crashes
de EFZ. Cada input se ejecuta en un proceso objetivo; el transporte en memoria
se cierra y el marcador de resultado se limpia en `after`.
El harness no llama a la API de cobertura.

La dependencia Cowboy se fija en `rebar.config`/`rebar.lock`: Cowboy 2.19.0,
Cowlib 2.20.0, Ranch 1.8.1. El proyecto admite OTP 27+. Cada ejecución compila
e instrumenta automáticamente solo esta lista permitida:

| Módulo | Sondas |
| --- | ---: |
| `cowboy_http` | 485 |
| `cowboy_req` | 282 |
| `cowboy_router` | 101 |
| `cowboy_stream` | 19 |
| **Total** | **887** |

Los recuentos se verificaron en OTP 27.0 con la versión Cowboy indicada; el
runner imprime y guarda el recuento real. El bitmap tiene 65,536 **bits**.
Superar su capacidad detiene el run antes de la campaña. Se necesita `strict => false`
por algunos valores predeterminados de records/comprehensions que
`efz_instrument_pt` conserva sin sondas internas. Su lista se
imprime al compilar y se guarda en el `.efz-manifest` de cada módulo.
Esta limitación de instrumentación afecta a ambos backends.

El experimental `otp_native_public` compila la misma lista de Cowboy con
`line_coverage` y lee cobertura mediante `code:get_coverage(line, Module)`.
Para Cowboy 2.19.0, este entorno produjo 1089 slots de líneas nativas. Son
líneas ejecutables OTP, por lo que no pueden compararse 1089 con las 887 sondas estructurales EFZ
como unidades equivalentes. El modo se elige antes de cargar el objetivo.

Los seeds están en `test/targets/cowboy/seeds/`: 12 peticiones pequeñas con CRLF,
incluidos GET, query, POST con longitud, varias cabeceras, HEAD, OPTIONS,
URI absoluto, HTTP/1.0, cuerpo chunked y dos peticiones malformadas.

## Ejecución

Desde la raíz `efz/`:

```sh
./scripts/run_cowboy_long_bench.sh --backend ets --duration 900 --seed 424242
./scripts/run_cowboy_long_bench.sh --backend bitmap --duration 900 --seed 424242
./scripts/run_cowboy_long_bench.sh --backend otp_native_public --duration 900 --seed 424242
```

Los modos experimentales para perfilar el coste del motor incluyen `--backend none` (Cowboy
sin instrumentación), `--backend none_instrumented` (Cowboy con instrumentación OTP de líneas
pero sin reset/read/feedback), además de `--target noop` y `--profile`.
Las mediciones cortas, interpretación del coste y comandos para ver
`profile.term` se describen en el
[perfil del motor](engine-performance-profile.md). `none` no está guiado por cobertura
ni cambia el valor predeterminado ETS.
Resultados del siguiente paso con runs de 15 minutos, secuencias idénticas de inputs
(`--fixed-replay`) y perfil temporal:
[engine-performance-profile-v2.md](engine-performance-profile-v2.md).

Cada comando inicia una VM Erlang nueva. Para otro par en orden inverso,
ejecute después bitmap → ETS con los mismos argumentos. Para otro corpus inicial,
indique `--corpus DIR` (directorio plano de archivos normales); para un directorio nuevo
explícito de resultados, `--out DIR`. Un `--out` existente no se sobrescribe.
`--duration` se expresa en segundos. `--seed` se usa para mutación aleatoria EFZ y selección
de padres. Seeds iguales significan el mismo estado inicial, no un historial idéntico
garantizado: distintas velocidades durante un tiempo fijo producen
recuentos de mutaciones distintos y pueden llevar a corpora diferentes. Para comprobaciones
estrictas de semántica de cobertura, use pruebas diferenciales con igual historial de eventos EFZ.

Los equipos donde Rebar3 no pueda descargar dependencias necesitan acceso GitHub o una
caché Rebar3 poblada. En el entorno local restringido, Rebar3 no pudo
resolver el proxy configurado; se clonaron manualmente los repositorios fijados en
`_build/default/lib/` para validar. No cambia el bloqueo de versiones.

Los resultados se escriben en un directorio nuevo:

```text
artifacts/cowboy-long-bench/<UTC timestamp>-ets/
artifacts/cowboy-long-bench/<UTC timestamp>-bitmap/
```

Cada uno contiene `config.term`, `environment.txt`, `samples.csv`, `summary.term`,
`summary.csv`, `coverage.term`, `cleanup.term`, `corpus/`, `crashes/` y
`target-beams/`. Git ignora los directorios de resultados. `environment.txt`
contiene commit/status Git, OTP/ERTS, Cowboy, SO/CPU/arquitectura, schedulers,
backend, tamaño bitmap, configuración EFZ, duración y seed.

Compare un par completado:

```sh
python3 scripts/compare_cowboy_long_bench.py \
  artifacts/cowboy-long-bench/<ETS_RUN> \
  artifacts/cowboy-long-bench/<BITMAP_RUN> \
  artifacts/cowboy-long-bench/<OTP_PUBLIC_RUN>
```

El script acepta 2–4 directorios, comprueba la configuración inicial e imprime
exec/s y dispersión, primeros/últimos 60s, cobertura/corpus, memoria y procesos; para un
run largo también imprime memoria RSS/VM/ETS cerca de 0/5/10/15 minutos. Los recuentos
absolutos de puntos EFZ y líneas OTP se muestran advirtiendo sus unidades diferentes.
Las diferencias entre runs independientes son descriptivas: por sí solas no
demuestran cambios en la semántica de un backend.

## Experimento separado: `erlang-fuzzer(1)`

`./scripts/run_cowboy_long_bench.sh --backend erlang_fuzzer` invoca el
`scripts/run_erlang_fuzzer_cowboy_bench.py` independiente. Ejecuta los fuentes
`erlang-fuzzer(1)` proporcionados contra **el mismo Cowboy 2.19.0, los mismos cuatro módulos
objetivo, la misma ruta harness y los mismos seeds**. Compila Cowboy con
`line_coverage`, mientras `fuzzer.erl` externo selecciona OTP `line_counters` y
registra contadores con libFuzzer mediante el NIF `core.c`. Los fuentes proceden de
`~/test/erlang-fuzzer(1)/erlang-fuzzer/fuzzer` (o `--source DIR`), no se copian
a Git ni cambian EFZ. Se compila una copia en un directorio `/tmp`
separado: el Makefile original usa GDB para obtener offsets del
`beam.smp` actual; el wrapper solo desactiva la inicialización GDB del usuario (`gdb -nx`), sin
sustituir offsets precalculados. Los hashes SHA256 de `core.c`, driver y
`beam.smp` se guardan en `environment.txt`.

```sh
./scripts/run_cowboy_long_bench.sh --backend erlang_fuzzer \
  --source "$HOME/test/erlang-fuzzer(1)/erlang-fuzzer/fuzzer" \
  --duration 900 --seed 424242
```

Se usa una VM Erlang independiente. El runner rechaza el resultado si algún módulo Cowboy
no está registrado en cobertura nativa o libFuzzer no recibe características.
Están disponibles `--corpus DIR` y `--out NEW_DIR`. Los resultados van a
`artifacts/cowboy-long-bench/<timestamp>-erlang_fuzzer/`:
`samples.csv`, `summary.csv`, `environment.txt`, `fuzzer.log`, copia del corpus,
artefactos de crashes y logs de compilación. Después, compárelo con los tres modos EFZ:

```sh
python3 scripts/compare_cowboy_long_bench.py \
  artifacts/cowboy-long-bench/<ETS_RUN> \
  artifacts/cowboy-long-bench/<BITMAP_RUN> \
  artifacts/cowboy-long-bench/<OTP_PUBLIC_RUN> \
  artifacts/cowboy-long-bench/<ERLANG_FUZZER_RUN>
```

Es una **comparación de motores de fuzzing completos**, no una medida de una
única operación de recogida de cobertura: libFuzzer ejecuta el input en un proceso
sin guardian EFZ, usa otras mutaciones y sus propias reglas de retención
del corpus. Las secuencias divergen aun con igual seed. `ft` y
`cov` de libFuzzer no equivalen a sondas estructurales EFZ ni a líneas OTP únicas. En el
`core.c` proporcionado, el NIF registra bytes de `line_counters` y construye una tabla PC
sintética a partir de índices; su recuento no puede compararse con
`code:get_coverage/2`. En la tabla común, recuentos de cobertura externa, descubrimientos
y métricas VM/procesos no disponibles aparecen como `n/a`; `ft` y `NEW/REDUCE` se
muestran por separado. Exec/s no demuestra la velocidad del collector de cobertura
por sí mismo. Para ello hace falta replay aislado de inputs idénticos con ciclos de ejecución
comparables.

Este NIF usa estructuras ERTS privadas y un puntero al buffer de cobertura sin
protección de vida útil demostrada durante reload/purge. Úselo solo en VM desechable;
es investigación, no un backend EFZ. Un resultado no sirve si cambia OTP,
faltan símbolos DWARF/debug o falla el registro. El script no
recarga módulos ni incorpora el NIF externo al runtime principal EFZ.

Comprobación corta de 2026-10-03: `--duration 2 --seed 424242` terminó con 0, el
log confirmó `coverage on` en los cuatro módulos Cowboy, `ft` creció desde su
valor inicial y aumentó el corpus. Salida raw:
`artifacts/cowboy-long-bench/20261003T172502Z-erlang_fuzzer/` (local, fuera de Git).
`rebar3 eunit`: 256 PASS. El run externo de 900 segundos **NO SE EJECUTÓ**;
la comprobación corta no estima throughput sostenido.

## Muestreo y resumen

`samples.csv` contiene una muestra inicial y otra cada 10 segundos, sin
recoger telemetría en cada iteración. Los contadores EFZ, tamaño del corpus y cobertura
global se leen coherentemente mediante el read-only
`efz_fuzzer:benchmark_snapshot/0` / `efz_worker:handle_call/3`. El
`coverage.term` exacto se crea una vez al terminar el muestreo. Columnas:
elapsed, exec/s total/ventana, corpus, cobertura global, descubrimientos,
crashes/timeouts/errores, procesos, memoria total/procesos/binary/ETS,
RSS Linux, run queue, reductions, número GC, arms/asignaciones del mapa y observaciones
de cobertura rotas. `execution_maps_allocated` cuenta solo el mapa
preasignado por el worker, no todos los mapas temporales posibles.
`summary.term` y `summary.csv` contienen total/media,
mediana, p10/p90 de exec/s por ventana, primeros/últimos 60s, cobertura/corpus final,
crashes/timeouts y cambios de memoria/número de procesos.
`total_executions` incluye calibración; las velocidades por intervalo se miden desde
la primera muestra después de `efz:start/1`.

`cleanup.term` se escribe tras `efz:stop/0`. Se comprueba la ausencia de procesos EFZ
por sus nombres registrados; el número absoluto de procesos y la memoria tras detener
se guardan para diagnóstico manual. Bitmap-v2 expone un contador arms y un
mapa de ejecución preasignado en el worker. El número de mapas retirados no es observable
mediante la API pública actual, por lo que no se afirma esa métrica. Toda conclusión de memoria
requiere la serie completa de 15 minutos y repeticiones.

## Comprobaciones antes del run largo

Completadas el 2026-10-02 con OTP 27.0:

- `rebar3 compile` — PASS;
- `rebar3 eunit` — 255 PASS, incluidos 12 casos del harness Cowboy;
- `rebar3 ct` — 3 PASS;
- `./scripts/run_cowboy_long_bench.sh --backend ets --duration 30 --seed 424242`
  — 3582 ejecuciones, 119.36 exec/s, 266 puntos finales de cobertura, 56 inputs
  de corpus, 0 crashes/timeouts/errores;
- el mismo comando con `--backend bitmap` — 1992 ejecuciones, 66.36 exec/s,
  259 puntos finales, 49 inputs de corpus, 0 crashes/timeouts/errores.

Los resultados raw de 30 segundos se guardan localmente en
`artifacts/cowboy-long-bench/20261002T190436Z-ets/` y
`artifacts/cowboy-long-bench/20261002T190514Z-bitmap/`. La media bitmap/ETS de
este par es ≈0.556. Bitmap sigue siendo experimental opt-in; ETS sigue
predeterminado. Estos datos no sustituyen cuatro runs de 15 minutos en orden
ETS → bitmap → bitmap → ETS: 30 segundos no bastan para concluir saturación de cobertura,
estabilidad del throughput o crecimiento de memoria.
