# Correcciones de aceptación P0 — 2026-09-21

[English](../../runtime-diagnostics-acceptance-fixes.md) · [Русский](../ru/runtime-diagnostics-acceptance-fixes.md) · **Español** · [简体中文](../zh-CN/runtime-diagnostics-acceptance-fixes.md) · [Todos los idiomas](../README.md)

## Veredicto: ACCEPT

P0-01, P0-02, P0-03, P0-04: PASS. Compilación canónica, EUnit dos veces, CT,
Dialyzer y xref: salida 0. Sin cambios en los arneses existentes ni en el modelo
de propiedad. Sin funciones P1/P2, commits, reset/clean/pull ni eliminación de
cambios preexistentes. HEAD sigue en `205e18ba172d74bd6c652a68abfc73e02e4a1f86`.
Entorno: OTP 27.0 / ERTS 15.0 / rebar3 3.25.0, `ERL_FLAGS='+S 4:4'`.

## Correcciones y causas raíz

### P0-02: validar antes del trabajo costoso

`efz_stability:bounded_return/1` antes ordenaba claves arbitrarias de mapas antes
de comprobar el presupuesto. Ahora valida mediante un iterador no ordenado,
acceso elemento a elemento a tuplas y recursión de listas consciente del
presupuesto. Límites independientes: 1024 nodos visitados, 1024 bytes binarios,
1024 elementos de contenedores, profundidad 64. Se comprueban tamaños de
contenedores y byte_size de binarios antes de recorrer/acceder al contenido.
Sin conversión de mapas a listas, ordenación, reconstrucción ni serialización
sin validar. ETF/hash deterministas solo se calculan tras aprobar el término
completo. Los términos no admitidos devuelven not_comparable; la comparación
predeterminada sigue deshabilitada.

Las pruebas cubren mapas pequeños, orden equivalente de inserción en mapas,
referencias/PID/funciones, claves/valores binarios enormes, claves enormes con
prefijo común, mapas excesivos, presupuesto binario agregado y profundidad.
Una traza de llamadas que registra solo aridades acota las visitas de validación
y demuestra que los términos rechazados nunca invocan term_to_binary/2,
maps:to_list/1 ni lists:sort/1; los argumentos enormes no se copian a los
mensajes de traza. Sin aserciones absolutas de tiempo real.

### P0-01: observación separada de memoria tras la limpieza

El crecimiento dentro de una ejecución sigue siendo una observación existente
separada. Una observación nueva mide la memoria binaria global de la VM antes
de ejecutar y después del DOWN normal del guardian, limpieza confirmada y
reposo acotado. Se ejecuta fuera del guardian con auxiliares monitorizados y
plazos limitados. Un fallo da incomplete/unavailable; el resultado del objetivo
no cambia. Una limpieza fallida sigue siendo fallo de infraestructura y omite
esta observación. Sin mutación del objetivo/estado compartido, GC ajeno ni
cambios de propiedad.

La evidencia almacena baseline_memory, sampled peak_memory,
post_execution_memory, residual_delta, units, threshold, scope, completeness,
cleanup_status, quiescence, deadline y una limitación explícita de atribución.
La memoria posterior propiedad del objetivo es not_applicable tras terminar
sus propietarios. `vm_memory_growth_suspected` tiene ámbito vm_global tanto
en evidencia como en identidad de artefacto/deduplicación; nunca es una fuga
probada del objetivo. Los mapas de política antiguos schema-v1 se normalizan
con los valores predeterminados nuevos al cargarse.

El fixture nuevo devuelve un binario nuevo de 16 MiB mediante run(binary())
ordinario. EFZ conserva ese valor tras limpiar la raíz: una asignación residual
de VM admitida con límites de atribución conocidos. La reproducción de campaña
es 3/3. Replay descarta valores originales entre ejecuciones, por lo que recoger
binarios anteriores puede compensar una asignación nueva; informa el M/N real,
no un 3/3 forzado ni un veredicto de fuga. La ejecución de evidencia obtuvo 1/3.
Una asignación temporal de 16 MiB tiene pico observado pero ningún hallazgo
residual: delta 40 bytes en la ejecución específica, inferior al umbral de
8 MiB del fixture.

Se probó por separado un auxiliar de observación posterior suspendido: timeout
del objetivo 60 ms, limpieza del guardian completada a 66 ms, retorno del
llamador a 167 ms con evidencia de memoria incompleta, auxiliar muerto,
ejecutor reutilizable. El plazo de observación de 100 ms venció **después** de
la limpieza; no retrasó la terminación del objetivo.

### P0-03: timeout desconocido explícito

La rama de bloqueos deshabilitados antes no devolvía categoría. Ahora los
diagnósticos activos siempre clasifican el timeout como desconocido si los
bloqueos están deshabilitados. Las rutas existentes de muestras ausentes,
antiguas o evidencia insuficiente también devuelven desconocido. Busy/waiting
no cambian y las clasificaciones son mutuamente excluyentes por ejecución.
El resultado principal `{timeout, TimeoutMs}` no cambia.

### P0-04: corrección separada de infraestructura de pruebas

El timeout original EUnit de 5s envolvía dos campañas de límites de
300 ejecuciones, cuatro variantes independientes de backend (~400 ejecuciones)
o una prueba de planificador de 512 ejecuciones. Las campañas ya tenían límites
de espera de 10s. Esto convertía una prueba de corrección en un filtro
involuntario de rendimiento agregado del host.

Una ejecución nueva específica anterior a los cambios reprodujo un timeout de
límites. Las ejecuciones ordinarias nuevas de HEAD limpio también fallaron por
su límite anterior de espera de agotamiento y un fallo posterior de smoke en
la ejecución completa, pero no reprodujeron consistentemente los tres timeouts
cortos. Por eso un experimento diagnóstico de contención, acotado y etiquetado
por separado, ejecutó las tres funciones originales con el mismo límite EUnit
de 5s tanto en el árbol guardado anterior como en HEAD limpio: se cancelaron
los seis casos. Son FAIL diagnósticos, no resultados PASS canónicos, aunque
el propio controlador terminó normalmente.

Sin esa carga competidora, las aserciones sin cambios completaron tres veces
cada una: límites 2.61–2.64s, planificador 2.17–2.26s, backend 1.94–2.04s.
Cada una volvió a processes=41, ETS=19, guardian=undefined, runner=ready.
La evidencia respalda una carga finita y un timeout agregado sensible al
planificador, no procesos filtrados, limpieza perdida ni receive sin límite.

Corrección: separar casos independientes de límites y variantes de backend en
casos EUnit individuales. Alinear el plazo externo de límites/planificador
(12s) con los 10s existentes de espera de campaña más limpieza. Conservar todas
las iteraciones, variantes, aserciones y el escenario completo de 256 padres.
Sin omisiones, reducción de carga ni captura general de errores. Se conservó
la prueba de agotamiento preexistente de 75s y su límite de campaña de 60s.

Esta corrección puede revisarse por separado en
[test-infrastructure.patch](../../runtime-fixes-validation/test-infrastructure.patch),
respecto al checkout inicial modificado, excluyendo cambios previos del usuario.

## Archivos de implementación y pruebas cambiados

- `src/efz_stability.erl`: comparador acotado.
- `src/efz_runtime.erl`: observaciones previas/posteriores, contexto de muestras
  VM, timeout_unknown, consulta final más barata de existencia ETS.
- `src/efz_runtime_config.erl`: validación de umbral residual/reposo/plazo.
- `src/efz_executor.erl`: medición previa e integración tras DOWN normal del guardian.
- `src/efz_worker.erl`: ámbito vm_global del artefacto para la categoría nueva.
- `src/efz_runtime_store.erl`: firma con ámbito, validación de categoría, valores
  predeterminados para políticas antiguas.
- `src/efz_runtime_replay.erl`: completitud de la observación residual en la revisión.
- `fixtures/runtime/efz_runtime_memory_fixture.erl`: fixture nuevo; sin cambios de arneses existentes.
- `test/efz_runtime_acceptance_tests.erl`: regresiones de comparador/configuración/memoria/timeout.
- `test/efz_limits_tests.erl`, `test/efz_backend_tests.erl`, `test/efz_phase3_tests.erl`:
  cambios separados de infraestructura de pruebas.
- `docs/runtime-diagnostics.md`, este informe y `docs/runtime-fixes-validation/`:
  documentación de políticas y evidencia nueva.

## Resultados de regresión

Todos los comandos siguientes se ejecutaron desde el proyecto con `ERL_FLAGS='+S 4:4'`.

| Comando | Exit | Aprobados | Fallidos / omitidos | Segundos |
|---|---:|---:|---:|---:|
| rebar3 compile | 0 | — | — | 1 |
| rebar3 eunit, run 1 | 0 | 223 | 0 / 0 | 117 |
| rebar3 eunit, run 2 | 0 | 223 | 0 / 0 | 123 |
| rebar3 ct | 0 | 3 | 0 / 0 | 6 |
| rebar3 dialyzer | 0 | — | — | 8 |
| rebar3 xref | 0 | — | — | 1 |
| rebar3 eunit --module=efz_runtime_acceptance_tests,efz_runtime_tests | 0 | 20 | 0 / 0 | 8 |

Una ejecución específica combinada anterior, runtime más los tres módulos con
antiguos timeouts, pasó 59 pruebas; el caso posterior de validación de
configuración está en ambas ejecuciones finales de 223 pruebas y en la final
de 20 pruebas runtime. Registros:
[run 1](../../runtime-fixes-validation/final-eunit-1.log),
[run 2](../../runtime-fixes-validation/final-eunit-2.log),
[estados de comandos](../../runtime-fixes-validation/results.txt).

## Aceptación específica

| ID | Antes | Después | Evidencia |
|---|---|---|---|
| P0-01 | FAIL | PASS | medición VM posterior a limpieza; negativo de solo pico; campaña 3/3; M/N real guardado/reproducido; plazo del auxiliar suspendido |
| P0-02 | FAIL | PASS | presupuestos antes de recorrido/serialización; la traza prueba rechazo antes de llamadas costosas; benchmark calentado de claves enormes |
| P0-03 | FAIL | PASS | muestreador deshabilitado, intervalo mayor que timeout, muestras cero/antiguas/incompletas, casos busy y waiting |
| P0-04 | FAIL | PASS | funciones originales diagnosticadas en ambos árboles; EUnit canónico completo dos veces, 223/223 |

Comprobación adicional: la CLI existente efz_example_target con P0 activo salió
con 0. Ejemplos y arnés runtime existente son idénticos byte a byte al árbol
anterior guardado. Coinciden 25 mutaciones aleatorias y por etapas entre
antes-de-correcciones/off/on en entradas generadas, trazas/contadores por etapas,
cobertura y contenido del corpus, excluyendo metadatos volátiles. Pasan las
pruebas existentes de aislamiento de verificación, fallo solo en verificación,
ejecutor contaminado, fallo del guardian y muestreador suspendido.
Un artefacto guardado antes de estas correcciones también se reprodujo en una
CLI VM nueva: compatibilidad verificada, child_abnormal_exit observado 3/3,
salida 0 ([registro](../../runtime-fixes-validation/old-runtime-replay.log)).

## Rendimiento

Tres campañas de 300 mutaciones por modo tras un calentamiento de 50, mismas
entradas/semillas, un trabajador, +S 4:4; VM secuenciales. Antes es el **árbol
modificado anterior a las correcciones**, no HEAD limpio; así se mantienen
constantes los cambios ajenos de hit-count. Fila mediana por rendimiento de
mutaciones; calibration=1 en todas las filas.

| Serie inicial | Mutaciones | Verificación | Wall s | Mutation/s | Total/s |
|---|---:|---:|---:|---:|---:|
| before fixes, off | 300 | 0 | 1.749 | 171.52 | 172.09 |
| after fixes, off | 300 | 0 | 2.003 | 149.76 | 150.26 |
| resources only | 300 | 0 | 2.005 | 149.60 | 150.10 |
| full | 300 | 4 | 2.065 | 145.28 | 147.70 |

El delta off inicial fue -12.7%; no se ocultó. El control en orden inverso dio
before=202.48, after=206.45 mutation/s (+2.0%). Una serie CPU/reductions adicional
dio before=206.47, after=205.82 (-0.3%). Mediana de tiempo CPU de cada tres runs:
4358 -> 4333 ms (-0.6%); reducciones en las ejecuciones de rendimiento mediano:
27,963,230 -> 27,965,219 (+0.007%). Los controles no reprodujeron una regresión
off considerable. La planificación/frecuencia del host no estaban fijadas;
estos datos no garantizan rendimiento universal. Las filas iniciales y de
control se conservan en [bench-summary.log](../../runtime-fixes-validation/bench-summary.log).

Comparador calentado, 100 llamadas, mapa con dos claves binarias con prefijo
común, construcción fuera de la medición, todos los resultados not_comparable:

| Bytes/clave | Antes, us | Después, us |
|---:|---:|---:|
| 1025 | 46 | 31 |
| 1048577 | 6533 | 74 |
| 16777217 | 183717 | 44 |

Esto corrobora el límite estructural; no afirma un límite de tiempo real.
No se añade ninguna llamada al comparador con compare_return=false.

## Nota ETS y limitaciones restantes

La comprobación final de desaparición ahora consulta únicamente
ets:info(Tab,owner), evitando asignar la lista completa de información de tabla,
incluidos metadatos ajenos. No cambian la semántica de enumeración ni el filtrado
por propietario. ets:all sigue enumerando todas las tablas VM antes del límite
de inspección: limitación documentada O(VM table count), fuera del guardian.
100 llamadas de enumeración midieron 3210 us con 100 tablas adicionales y
17313 us con 1000. No se afirma un rediseño de propiedad ni un límite de
enumeración global VM no admitido.

Las métricas residuales globales de VM no pueden establecer deliberadamente
atribución a una entrada; el M/N de replay puede variar por recoger retornos
anteriores. El reposo es una espera acotada, no una afirmación de que toda la VM
esté inactiva. Sin afirmaciones de fuga/deadlock/livelock confirmados.
No quedan MAJOR/BLOCKER ni MINOR conocidos de corrección en estas correcciones.

## Comandos adicionales ejecutados y evidencia original

```sh
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_runtime_acceptance_tests,efz_runtime_tests,efz_limits_tests,efz_phase3_tests,efz_backend_tests
ERL_FLAGS='+S 4:4' escript /tmp/efz-p0-fixes/debt_probe.escript /home/anonymous_usr/erl:fuzz/efz
ERL_FLAGS='+S 4:4' timeout 50s escript /tmp/efz-p0-fixes/debt_contention.escript /tmp/efz-acceptance-20260921/baseline
ERL_FLAGS='+S 4:4' timeout 50s escript /tmp/efz-p0-fixes/debt_contention.escript /tmp/efz-p0-fixes/before-tree
ERL_FLAGS='+S 4:4' escript /tmp/efz-p0-fixes/short_bench.escript /tmp/efz-p0-fixes/before-tree before-off off
ERL_FLAGS='+S 4:4' escript /tmp/efz-p0-fixes/short_bench.escript /home/anonymous_usr/erl:fuzz/efz off off
ERL_FLAGS='+S 4:4' escript /tmp/efz-p0-fixes/short_bench.escript /home/anonymous_usr/erl:fuzz/efz resources resources
ERL_FLAGS='+S 4:4' escript /tmp/efz-p0-fixes/short_bench.escript /home/anonymous_usr/erl:fuzz/efz full full
ERL_FLAGS='+S 4:4' escript /tmp/efz-p0-fixes/post_bound.escript /home/anonymous_usr/erl:fuzz/efz
```

Los controladores/instantáneas temporales permanecen en `/tmp/efz-p0-fixes/` y
`/tmp/efz-acceptance-20260921/baseline/`. Los registros nuevos se conservan en
`docs/runtime-fixes-validation/`; ningún registro histórico de aceptación se
contó como PASS.
