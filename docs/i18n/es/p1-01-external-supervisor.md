# P1-01 Supervisor externo

[English](../../p1-01-external-supervisor.md) · [Русский](../ru/p1-01-external-supervisor.md) · **Español** · [简体中文](../zh-CN/p1-01-external-supervisor.md) · [Todos los idiomas](../README.md)

Estado: **DONE** en Linux. Fecha de validación: 2026-09-21. Línea base de
implementación: `9303c6e0734cc135700e62b0774f4a0011e97d48`.

El backend supervisado es opcional. La ejecución anterior y el contrato público
del arnés `Module:run(binary())` no cambian.

## Línea base y arquitectura real

Entorno: Linux 6.8.0 x86_64, OTP 27, ERTS 15.0, rebar3 3.25.0. El proyecto
requiere como mínimo OTP 27. El código existente admite el modo anterior donde
funcionen OTP 27 y sus supuestos de sistema de archivos; las garantías de ciclo
de vida P1-01 son explícitamente exclusivas de Linux porque usan `pidfd`,
`PR_SET_PDEATHSIG`, subreaping, credenciales de pares Unix y enumeración de
descendientes mediante `/proc`.

El checkout tenía cambios antes de P1-01. Los cambios preexistentes de
hit-count/corpus figuran en `_build/p1-validation/before.status` y se preservaron
por separado. No se hizo reset, clean, checkout, cambio de arnés objetivo ni
eliminación.

Ruta real de llamadas del modo anterior:

```text
scripts/fuzz.escript
  -> efz_cli:main/1
  -> efz:start/1 -> efz_fuzzer:init/1
  -> efz_worker (seed calibration / mutation / feedback / corpus / P0 verification)
  -> efz_executor:run/4
  -> efz_guardian:run/6
  -> efz_executor:invoke/4 -> Harness:run(Binary)
  -> guardian cleanup/coverage/runtime result
  -> efz_feedback:evaluate/3 -> efz_corpus / crash and runtime stores
```

`efz_guardian` es propietario de la raíz objetivo y sus descendientes controlados
en la VM trabajadora, del plazo del objetivo, limpieza y decisión de contaminación
del ejecutor. `efz_runtime` muestrea esos procesos propios. `efz_corpus_store`
es la ruta persistente del corpus exitoso; `efz_runtime_store` y `efz_crash`
publican hallazgos. Replay está en `efz_replay_cli`, `efz_replay` y
`efz_runtime_replay`. Se recalibra el corpus restaurado, pero este checkout no
tiene minimizador. La validación del callback del objetivo y `on_load` ocurren
mediante `efz_config`/`code:ensure_loaded` dentro de la VM de campaña; la carga
instrumentada de BEAM pasa por `efz_instrument`. Por tanto, se debe situar en el
trabajador externo el bucle completo de campaña, no solo `run/1`.

Línea base canónica antes de P1-01:

| Comando (`ERL_FLAGS='+S 4:4'`) | Exit | Resultado |
|---|---:|---|
| `rebar3 compile` | 0 | PASS |
| `rebar3 eunit` | 0 | 223 tests PASS |
| `rebar3 ct` | 0 | 3 tests PASS |
| `rebar3 dialyzer` | 0 | PASS |
| `rebar3 xref` | 0 | PASS |

Registros originales: `_build/p1-validation/baseline-*.log`.

## Frontera de procesos implementada

`--supervised` delega en `efz_cli:main/1` antes de buscar el objetivo, iniciar
la aplicación, reproducir o validar callbacks. El proceso CLI original inicia
el controlador Python, que solo opera con archivos, mediante
`open_port({spawn_executable, Python}, ...)` y un vector explícito de argumentos.
El controlador nunca importa, carga ni llama código objetivo, de arnés o NIF.
Calcula hashes de archivos locales EFZ, artefactos, sidecars, arnés y `.so`,
y de la configuración acotada del comando.

En cada generación inicia `priv/efz_vm_launcher` con un vector de argumentos,
sin shell. El lanzador C hace fork y `execv` de `erl`; el nuevo BEAM invoca
`efz_external_worker:main/0`, que ejecuta la CLI `efz_cli` ordinaria y la campaña
real. La carga del objetivo/arnés/NIF queda confinada al espacio de direcciones
del trabajador. El guardian permanece igual dentro de él.

El lanzador:

- obtiene un `pidfd` para el controlador e instala `PR_SET_PDEATHSIG` con una
  comprobación posterior del padre;
- convierte BEAM en líder de una nueva sesión/grupo de procesos, con su propia
  comprobación de carrera SIGKILL por muerte del padre;
- actúa como subreaper de hijos y mata/recoge descendientes adoptados antes de
  informar `cleanup_confirmed=true`;
- devuelve el estado original de `waitpid`, señal y código de salida separados,
  y si el propio lanzador inició la terminación;
- drena continuamente stdout/stderr, cuenta todos los bytes y conserva solo
  una cola final de 4096 bytes; los volcados de fallos y cores están desactivados;
- nunca inicia un reemplazo antes de confirmar la limpieza del trabajador anterior.

El controlador también mantiene un `pidfd` de la CLI llamadora y realiza un
reto ACK en vivo por el puerto heredado. Así, SIGKILL de la CLI o del controlador
hace que el lanzador mate y recoja un trabajador bloqueado en un NIF.
Es contención del ciclo de vida, no un sandbox de seguridad: el código nativo
aún accede al sistema de archivos, red y host con las credenciales del trabajador.

## Barrera obligatoria de ejecución

El único hook de integración es la primera operación de `efz_executor:run/4`:

```text
efz_worker selects/generates Input
  -> efz_executor:run/4
  -> efz_external_worker:execution/4
  -> PREPARE(Input, digest, phase, timeout, bounded recipe)
  -> controller validates the fixed schema
  -> fsync artifact.input, artifact.external.json, optional artifact.recipe,
     and manifest.json in a private staging directory
  -> fsync staging directory
  -> rename the whole directory to CAMPAIGN/RUN and fsync campaign directory
  -> atomically write/fsync authorized.json and fsync the run directory
  -> COMMITTED/RUN(RunId, digest)
  -> worker verifies generation, RunId and digest
  -> existing executor -> guardian -> Harness:run(Input)
  -> bounded RESULT -> atomic checksummed result.json -> RESULT ACK
```

El hook cubre calibración de semillas, recalibración del corpus, mutaciones y
verificación/reproducción P0 porque todas usan `efz_executor:run/4`.
La reproducción de hallazgos externos es una campaña real de una entrada y
pasa la misma barrera. No hay implementación de minimización que cubrir.
En modo anterior la puerta es una llamada directa sin IPC ni trabajo de archivos.

No se permite ejecutar el objetivo tras fallar escritura/fsync/renombrado/
autorización. El diario tiene una ejecución en curso, límite de entrada de
1 MiB, límites de receta y metadatos de 64 KiB, presupuesto total configurable
de bytes y como máximo 100000 registros explorados/de ejecución. La entrada
original es autoritativa. Se incluye la receta de mutación EFZR existente si
está disponible y es válida; la ausencia o el límite de metadatos son explícitos.

La publicación hace visible atómicamente el grupo de entrada y metadatos en el
mismo sistema de archivos. Los fsync de archivos y directorios pertinentes
proporcionan la garantía práctica más fuerte de sistema local usada en otras
partes de EFZ. No promete comportamiento del hardware más allá del fsync exitoso
del SO. `authorized.json` distingue una ejecución PREPARED confirmada pero no
emitida de otra cuyo permiso se registró persistentemente. No puede demostrar
que el trabajador alcanzó el código objetivo. Por tanto:

- la preparación sin confirmar no se atribuye a un objetivo;
- PREPARED sin autorización se convierte en `interrupted_prepared`;
- autorizada sin RESULT se convierte en `interrupted_unknown`, salvo evidencia
  de terminación más fuerte del lanzador activo;
- no se afirma ejecución exactamente una vez frente a fallos.

La finalización es atómica, verificada por suma y idempotente por campaña/RunId.
El inicio valida todos los manifiestos/resultados acotados y finaliza registros
incompletos sin inventar un fallo nativo. Una entrada confirmada sigue siendo
reproducible si posteriormente falla la publicación del resultado o índice.

## Protocolo y máquina de estados

El socket de control Unix es independiente de stdout/stderr. Linux `SO_PEERCRED`
debe coincidir con el PID del trabajador comunicado por el lanzador y con el uid
actual. Las tramas son longitud `u32` big-endian seguida de un esquema primitivo
fijo. Se rechaza la longitud tras los primeros cuatro bytes, antes de acumular
la carga. Tamaño máximo de trama: entrada + receta de 64 KiB + 59 bytes.
Las lecturas son de 4096 bytes, las tramas parciales tienen plazo de un segundo
y el decodificador maneja varias tramas.

No hay ETF/JSON/compresión en el canal de control. RESULT son cuatro bytes.
La receta opcional conserva el formato de datos EFZR con suma de verificación;
se comprueban tamaño, versión ETF y etiqueta de compresión antes de almacenarla,
y el controlador nunca la decodifica.

Los mensajes v1 son HELLO, READY, PREPARE, RUN, RESULT, DONE/SHUTDOWN y ACK.
Cada trama valida tipo, estado, generación, RunId, identidad y longitud exacta
de carga. HELLO contiene marca de protocolo, identidad combinada de archivos,
identidad de configuración del trabajador, PID del SO, OTP y ERTS.
Los resultados inesperados, antiguos, duplicados o posteriores al estado terminal
son fallos de protocolo.

Los estados son STARTING, SETUP, READY, PREPARING, EXECUTING, FINALIZING,
RECYCLING y STOPPING. RESULT se acepta persistentemente antes de su ACK y elimina
el registro en curso; una salida posterior no puede reescribirlo como fallo
nativo. Si vence antes el plazo duro absoluto, se ignora un RESULT posterior y
la terminación del lanzador sigue siendo la única clasificación terminal.
EOF y estado de espera se manejan independientemente, drenando una última trama
completa antes de clasificar la muerte.

La clasificación usa evidencia original:

| Observación | Clasificación |
|---|---|
| señal con ejecución autorizada en curso, sin terminación del controlador | `native_vm_crash` |
| código de salida sin señal | `worker_unexpected_exit` |
| plazo absoluto/terminación del controlador | `worker_hard_timeout` |
| IPC inválido | `worker_protocol_failure` |
| resultado finalizado no reutilizable del guardian | `dirty_recycle` |
| muerte antes de READY/en reposo | inicio/infraestructura, sin hallazgo de testcase |
| parada del usuario/padre | parada de campaña, nunca fallo nativo |

La señal demuestra terminación de VM, no culpabilidad del objetivo ni causa raíz.
`exit(139)` se registra como código 139 y señal 0. SIGKILL del lanzador registra
`launcher_kill=true` y nunca se llama fallo nativo.

## Plazo, reciclaje y recuperación

El plazo externo por ejecución es monotónico y absoluto:

```text
target timeout + guardian cleanup (1000 ms)
+ CLI P0 post-memory allowance (100 ms when enabled)
+ configured IPC grace (default 1000 ms)
```

El tráfico y los registros nunca lo amplían. Inicio/reposo están acotados por
separado, 10000 ms por defecto; la terminación del lanzador a cinco segundos y
la limpieza de hijos adoptados a dos. Una limpieza no confirmada aborta sin reiniciar.

Fallo nativo, timeout duro y resultado contaminado conservan/finalizan la
ejecución actual, ponen su digest en cuarentena, esperan la muerte del proceso
anterior, incrementan generación, revisan identidad de archivos, restauran el
corpus persistente y lo recalibran. Cada recalibración pasa la misma barrera.
Se omiten entradas en cuarentena para evitar un ciclo de semillas que fallan.
Presupuesto de reinicios (8), espera creciente lineal acotada, plazo de campaña,
límite de ejecuciones, resto de mutaciones y verificaciones P0 y bytes del diario
pertenecen al controlador. Un fallo de inicio/identidad anterior a READY no se
reinicia sin fin.

El estado recuperado es el corpus persistente y los presupuestos globales
configurados. Cobertura, retroalimentación, RNG y cursores locales del trabajador
se reconstruyen; no se afirma reanudación exacta de campaña.

## CLI y artefactos

Ejemplo:

```sh
ERL_FLAGS='+S 4:4' rebar3 compile
ERL_FLAGS='+S 4:4' escript scripts/fuzz.escript \
  --supervised --target my_harness --code-path harness-ebin \
  --artifacts instrumented --seeds seeds --corpus-dir out/corpus \
  --out out --timeout 1000 --max-iterations 10000 \
  --restart-budget 8 --supervised-runs 20000 \
  --campaign-ms 3600000 --ipc-grace-ms 1000 --journal-bytes 268435456
```

`OUT/external-runs/CAMPAIGN/RUN/` contiene `artifact.input`,
`artifact.external.json`, `artifact.recipe` opcional, `manifest.json`,
`authorized.json` y `result.json` con suma de verificación. La identidad de
configuración y lista exacta de archivos se guardan bajo el directorio de campaña.
Los hallazgos externos también se indexan en el espacio existente
`OUT/crashes/external/`. Informes del trabajador y hallazgos normales de
fallos/runtime permanecen en `OUT/worker-GENERATION/`.

La reproducción selecciona código objetivo localmente y verifica identidad de
archivos/arnés:

```sh
escript scripts/replay.escript \
  --external-finding OUT/external-runs/CAMPAIGN/RUN \
  --target my_harness --code-path harness-ebin --artifacts instrumented \
  --out recheck --reproduce-runs 3
```

Realiza un número acotado de generaciones aisladas e informa observed N/M,
no un booleano de una sola ejecución.

## Evidencia de aceptación nativa

Comando final:

```sh
python3 -m unittest discover -s test -p '*supervisor_test.py' -v
```

Salida 0, 13/13 pruebas. Registro original:
`_build/p1-validation/posthook-native.log`. Raíz de evidencia:
`_build/p1-native-68udkvqj`.

La campaña real de CLI SAFE -> SIGSEGV -> restart -> SAFE registró:

- campaña `119e4f3df348420e98488ed25bde3cc4`;
- PID supervisor 739219, PID CLI 738777;
- generación 1, PID trabajador 739271; RunId 1 SAFE completado;
- RunId 2 original `SEGV`, SHA-256
  `8f243e33082126167daac18a24f576245ff332a18dc217093bc6cf9d6bbcdc1b`;
- `waitpid` autoritativo: señal 11, salida -1, estado original 139,
  `launcher_kill=false`, `cleanup_confirmed=true`;
- hallazgo:
  `_build/p1-native-68udkvqj/SEGV-61938280703258/out/external-runs/119e4f3df348420e98488ed25bde3cc4/2`;
- generación 2, PID trabajador 740096; corpus restaurado de 3 entradas,
  SAFE1 recalibrado y RunId 4 ejecutó SAFE2 correctamente;
- estado final completed, dos generaciones, cuatro ejecuciones con barrera.

SIGABRT produjo independientemente señal 6 con `launcher_kill=false`, reinició
y completó. Dos revisiones aisladas de cada hallazgo nativo informaron
`observed 2/2`. El NIF del fixture se cargó solo en VM hijas trabajadoras;
los volcados de fallos y cores estaban deshabilitados.

Resultados finales adicionales de aceptación:

- NIF bloqueado: `worker_hard_timeout`, señal 9 del lanzador,
  `launcher_kill=true`, limpieza confirmada, generación 2 alcanzó SAFE2;
- DIRTY: resultado original guardado como `dirty_recycle`; generación cambiada
  antes de SAFE2; ningún hallazgo nativo;
- `exit(139)`: `worker_unexpected_exit`, salida 139, señal 0;
- WAIT/BUSY internos: resultados del guardian conservados con `timeout_waiting`
  y `timeout_busy`, respectivamente;
- 8,389,639 bytes de salida del objetivo drenados sin bloquear; la cola
  conservada se mantuvo en 4096 bytes;
- SIGABRT de `on_load` durante inicio antes de READY: cero ejecuciones y hallazgos;
- fallo de presupuesto de escritura persistente: salida no cero y una marca
  demuestra que no se entró al objetivo;
- prueba de RUN retenido: BEAM hijo real emitió PREPARE pero no tocó el objetivo
  hasta confirmar el diario y el permiso ligado al digest;
- se rechazaron tramas malformadas/excesivas/con apariencia comprimida,
  parciales/múltiples, generación antigua, identidad incorrecta y RESULT duplicado;
- EIO en finalización conservó la entrada original confirmada y se recuperó una vez;
- evidencia SIGKILL CLI: trabajador 744649, lanzador 744647, controlador 744618
  desaparecieron de `/proc`; SIGKILL controlador: trabajador 744920, lanzador
  744919 y controlador 744894 desaparecieron; la recuperación clasificó
  incertidumbre, no un fallo nativo del objetivo;
- presupuesto de reinicio cero paró tras el primer fallo con
  `restart_budget_exhausted`; fallo persistente de inicio paró antes de READY.

## Regresión y rendimiento

Resultados canónicos finales, todos con `ERL_FLAGS='+S 4:4'`:

| Comando | Exit | Resultado |
|---|---:|---|
| `rebar3 compile` | 0 | PASS; auxiliar Linux compilado por pre-hook |
| `rebar3 eunit` | 0 | 224 tests PASS (línea base 223) |
| `rebar3 ct` | 0 | 3 tests PASS |
| `rebar3 dialyzer` | 0 | PASS, sin avisos |
| `rebar3 xref` | 0 | PASS |

Registros: `_build/p1-validation/release2-*.log`. Una segunda ejecución canónica
EUnit también completó las 224 pruebas.

El árbol exacto preparado solo de P1 se exportó además con `git checkout-index`
y se validó independientemente del trabajo hit-count previo: pasaron compile,
211 EUnit, 3 Common Test, Dialyzer y Xref; las 13 pruebas nativas pasaron en
33.649 s. El menor recuento EUnit es esperado porque la instantánea excluye
intencionalmente pruebas ajenas sin confirmar.

El benchmark diagnóstico realizó tres repeticiones alternadas del mismo objetivo
seguro con 300 mutaciones más una calibración. Fsync estaba activo:

| Mediana | Anterior | Supervisado |
|---|---:|---:|
| tiempo total | 2.246 s | 6.062 s |
| mutaciones por segundo | 133.6/s | 49.5/s |
| ejecuciones totales por segundo | 134.0/s | 49.7/s |
| preparación persistente total | n/a | 2.441 s |

El tiempo supervisado fue 2.70x el anterior; el rendimiento fue 62.9% menor.
Publicación y autorización persistentes costaron unos 8.11 ms/entrada.
El resto incluye VM adicional, IPC y finalización. Filas originales en
`_build/p1-validation/benchmark-final.log`; artefactos por ejecución en
`_build/p1-bench-i_u4wnm7/`.

## Límites

- Garantías completas solo en Linux. El lanzamiento supervisado falla
  explícitamente en otros sistemas; el modo anterior sigue disponible.
- Es contención y recuperación de fallos, no sandbox para código nativo hostil.
- No pueden revertirse efectos externos sobre archivos/red/servicios.
- Se confía en fsync/rename exitosos; la pérdida de alimentación depende en
  última instancia de que sistema de archivos y hardware respeten las operaciones.
- El diario demuestra preparación y permiso, no entrada exacta al código objetivo.
  No se afirma exactamente una vez.
- El corpus se restaura y recalibra. No se afirma reanudación exacta de puntos
  de control RNG, cursores por etapas ni cobertura global.
- Se admite un trabajador y un testcase en curso; planificación multitrabajador/
  distribuida queda fuera de P1-01.
