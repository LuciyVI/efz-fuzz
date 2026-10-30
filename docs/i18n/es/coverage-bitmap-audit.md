# Auditoría técnica del backend de cobertura bitmap de EFZ

[English](../../coverage-bitmap-audit.md) · [Русский](../ru/coverage-bitmap-audit.md) · **Español** · [简体中文](../zh-CN/coverage-bitmap-audit.md) · [Todos los idiomas](../README.md)

Esta es la auditoría original de bitmap-v1. Las correcciones y nuevas medidas están en
el [informe bitmap-v2](coverage-bitmap-v2-results.md); se conservan los resultados originales siguientes.

Fecha: 2026-10-02. Alcance: copia actual en `8b5cb05b5b57231b9133be13c883f25863e05d11`, con cambios previos sin commit. No se corrigió el backend. Se leyeron [arquitectura](coverage-bitmap-architecture.md), [plan](plans/coverage-bitmap-implementation-plan.md), [informe de implementación](coverage-bitmap-implementation-report.md), fuentes y pruebas. Abajo se enumeran tests nuevos y benchmark separado de auditoría.

## 1. Conclusión

En `automatic` + `presence` admitido, bitmap representa sin pérdida **los mismos puntos estructurales** que ETS: clave completa `{Module,BuildId,ProbeId}`, slots únicos y resultados ETS/bitmap coincidentes con historiales idénticos y campaña seeded. Con varios procesos admitidos, el bucle CAS conserva bits distintos de una palabra. Producción asigna mapa nuevo por ejecución; un escritor tardío no alcanza el siguiente. Es evidencia dentro de *descendientes controlados* de EFZ, no garantía para procesos remotos/externos arbitrarios.

**No se confirmó aceleración.** En el run emparejado repetido de una campaña real example-parser, bitmap dio menos exec/s: razón mediana bitmap/ETS `0.893`, intervalo bootstrap 95% `[0.851,0.949]`. El ciclo completo sparse de storage/feedback es particularmente caro. No debe cambiar `ets` predeterminado; `bitmap` solo es admisible como opt-in experimental para perfiles y tests diferenciales. No se encontraron bloqueantes P0 de corrección en la ruta comprobada; aún no se ha inyectado fallo dirty-cleanup específico de bitmap.

## 2. Arquitectura real y ruta del testcase

| Paso | Función y datos | Estado, propietario y concurrencia |
| --- | --- | --- |
| Preparación de campaña | [`efz_config:prepare_coverage/1`](../../../src/efz_config.erl#L85) comprueba manifiestos/capacidad; [`efz_worker:init/1`](../../../src/efz_worker.erl#L7) llama `efz_coverage:prepare_schema/2`, crea feedback/global. | Worker posee ETS protegido `FullId→Slot`, tuple inverso y binary global inmutable. Hay un worker (`workers=1`), commit serial. |
| Input/iteración | [`efz_worker:execute_checked/4`](../../../src/efz_worker.erl#L93) pasa input binary, backend/schema y plan fijado a [`efz_executor:run/4`](../../../src/efz_executor.erl#L11). | Estado mutable worker, corpus y selección de mutaciones; backend no elige input. |
| Contexto | [`efz_guardian:start/6`](../../../src/efz_guardian.erl#L33) abre `{efz_context,1,Ref,{bitmap,Schema,Words,Active},Owner}` mediante `efz_coverage:open/3`. | Guardian posee array atomics unsigned y flag activo separados por ejecución. |
| Conexión de procesos | [`efz_guardian:admit/2`](../../../src/efz_guardian.erl#L53) y [`efz_target:spawn_owned/2`](../../../src/efz_target.erl#L9) inician raíz/hijos por compuerta; [`efz_cov_bitmap:attach/1`](../../../src/efz_cov_bitmap.erl#L84) guarda contexto explícito en diccionario. | Varios escritores controlados comparten mapa. `spawn` normal no hereda contexto; trace lo detecta y marca dirty. |
| Target/hit instrumentado | [`efz_instrument_pt:body/5`, `probe/4`](../../../src/efz_instrument_pt.erl#L112) inserta `efz_cov_rt:hit({M,B,Id})`; [`efz_cov_rt:hit/1`](../../../src/efz_cov_rt.erl#L6) valida PID/contexto y pasa clave completa a `efz_coverage:hit/2` → `efz_cov_bitmap:hit/2`. | Ruta caliente modifica palabra de 64 bits por CAS; primer hit envía evento guardian. Posibles escritores concurrentes. |
| Finalización | [`efz_guardian:cleanup/2`, `loop/1`](../../../src/efz_guardian.erl#L72) cierra admisión, mata escritores restantes, espera `DOWN` y barreras; deadline produce unconfirmed/dirty. | Un `DOWN` raíz no basta. La estabilidad depende de terminar todo el grupo registrado y drenar trace. |
| Observación | [`efz_guardian:finish/2`](../../../src/efz_guardian.erl#L172) llama [`efz_executor:coverage/3`](../../../src/efz_executor.erl#L123) para lista/validación exacta; con éxito confirmado toma aparte `snapshot_bits/1` inmutable, después cierra mapa. | Dos snapshots solo tras quiescencia. `Result.coverage` público sigue siendo lista; `coverage_bits` interno. |
| Novedad/global | [`efz_feedback:evaluate/3`, `bitmap_success/5`](../../../src/efz_feedback.erl#L21) valida status/outcome, calcula `Local & ~Global`, decodifica IDs nuevos y construye `Global | Local`. | Global es binary inmutable de 8 KiB en worker; comparación/commit secuenciales. Crash/timeout no merge. |
| Corpus/fallos | [`efz_worker:execute_result/6`, `retain/2`, `record_failure/4`](../../../src/efz_worker.erl#L101) usa `retention_reason` existente; cobertura nueva correcta añade input vía `efz_corpus:add/2`, fallos aparte. | Como ETS, global se actualiza **antes** de escribir corpus. Error de escritura detiene; es orden existente, no conducta bitmap nueva. |
| Reset/liberación | Siguiente `efz_guardian:start/6` crea mapa nuevo; [`efz_cov_bitmap:close/1`, `reset/1`](../../../src/efz_cov_bitmap.erl#L151) no ponen global a cero. [`efz_worker:terminate/2`](../../../src/efz_worker.erl#L345) borra schema ETS. | Mapa mutable viejo no se reutiliza. GC recupera atomics al desaparecer referencias al contexto. |

Legacy sigue las mismas etapas executor/guardian/feedback/worker. Diferencias: [`efz_cov_ets:open/2`, `hit/2`, `snapshot/1`](../../../src/efz_cov_ets.erl#L7) usan tabla ETS pública nueva con `insert_new`; [`efz_coverage:unseen/2`, `merge/2`](../../../src/efz_coverage.erl#L40) operan sobre sets/listas Erlang exactos. Bitmap cambia almacenamiento/comparación y conserva identidades públicas y decisiones worker.

## 3. Identidad, slots e instrumentación

[`efz_instrument_pt:parse_transform/2`, `probe/4`](../../../src/efz_instrument_pt.erl#L7) inicia `ProbeId` local en 1 e inserta llamada con `{Module,BuildId,ProbeId}`; BuildId depende de formas canónicas, OTP/compiler y opciones identity (líneas 37–55). [`efz_cov_manifest:identities/1`, `validate/1`](../../../src/efz_cov_manifest.erl#L4) conserva identidad completa y rechaza ID locales no positivos/duplicados. La ubicación en function/case/if/receive/try/fun aparece en [`body/5`, `expr/3`](../../../src/efz_instrument_pt.erl#L107) y se prueba con [`efz_phase2_tests:manifest/1`](../../../test/efz_phase2_tests.erl#L70); bitmap no cambió el recorrido. [`efz_phase2_tests:determinism/1`](../../../test/efz_phase2_tests.erl#L195) comprueba BuildIds iguales para builds equivalentes y diferentes al cambiar macro.

[`efz_cov_bitmap:validate_manifests/1`, `prepare/2`](../../../src/efz_cov_bitmap.erl#L23) valida manifiestos, rechaza módulos repetidos/IDs duplicados, ordena identidades *completas* y asigna slots `0..N−1`. ETS protegido guarda `FullId→Slot`; un tuple `Slot→FullId`. No hay `ProbeId rem MapSize`, máscara hash ni truncación. Módulos distintos con ID local igual tienen slots distintos. Dos builds de un módulo **no se admiten simultáneamente**; fingerprint incluye la secuencia ID completa y capacidad. Build canónico idéntico produce slots iguales; BuildId/schema nuevo necesita campaña nueva y rechaza snapshots viejos (`unseen_bits/2`, `merge_bits/2`, líneas 177–191). Los **bytes input** pueden repetirse y recalibrarse tras recompilar; bits previos no se importan automáticamente.

Capacidad: `N > Bits` devuelve `{bitmap_capacity_exceeded,#{required_bits,configured_bits}}` antes de campaña ([`check_capacity/2`](../../../src/efz_cov_bitmap.erl#L14), [`efz_config:prepare_coverage/1`](../../../src/efz_config.erl#L90)). `MapSize` no puede ser slot en schema validado; ID desconocido, negativo/enorme o BuildId ajeno produce `unexpected_probe_or_build` explícito en [`hit/2`](../../../src/efz_cov_bitmap.erl#L93). Manifiesto corrupto se rechaza. Tests: [`mapping_and_capacity_test/0`, `boundary_test/0`, `default_last_slot_test_/0`](../../../test/efz_bitmap_contract_tests.erl#L4), [`invalid_identity_test/0`](../../../test/efz_bitmap_audit_tests.erl#L7) y [`wide_differential/0`](../../../test/efz_bitmap_audit_tests.erl#L39).

## 4. Representación, ruta caliente y concurrencia

Por defecto `coverage_bitmap_bits=65536`: 65,536 **bits**, 8,192 bytes payload, 1,024 palabras de 64 bits. [`efz_cov_bitmap:open/1`](../../../src/efz_cov_bitmap.erl#L74) asigna `atomics:new(Bits div 64,[{signed,false}])` y flag activo separado. Slot `s` se direcciona como `Word=s div 64+1` (atomics base 1), `Mask=1 bsl (s rem 64)`. Así `0,1,63,64,65,65535` corresponde a `word/bit` `1/0,1/1,1/63,2/0,2/1,1024/63`. Slot `65536` no existe. Bit alto unsigned; [`cas_word/4`](../../../src/efz_cov_bitmap.erl#L119) reintenta CAS tras lectura obsoleta, conservando bits vecinos. El determinista [`cas_stale_read_test/0`](../../../test/efz_bitmap_contract_tests.erl#L95) retrasa escritores tras leer el mismo `Old=0`, luego comprueba bits 0, 1 y 63; [`shared_writers_and_late_context_test/0`](../../../test/efz_bitmap_contract_tests.erl#L107) comprueba contexto compartido. No hay `get→OR→put` inseguro simple.

Un hit: [`efz_cov_rt:hit/1`](../../../src/efz_cov_rt.erl#L6) consulta pertenencia al registro PID mediante [`efz_cov_integrity:expected/0`](../../../src/efz_cov_integrity.erl#L70), valida diccionario, después [`efz_coverage:hit/2`](../../../src/efz_coverage.erl#L20) llama [`efz_cov_bitmap:hit/2`](../../../src/efz_cov_bitmap.erl#L93). Esta lee flag activo dos veces, hace lookup ETS exacto, calcula palabra/máscara y CAS; en primer 0→1 envía mensaje guardian. No lee config ni crea bitmap binary/list/set/map por hit ni decodifica diagnóstico/fuentes. Pero `ets:lookup` en registro y tabla de slots devuelve terms; **la ruta caliente no está libre de asignaciones**. En hits repetidos, el benchmark consume más tiempo que `ets:insert_new`.

Snapshot productivo solo es estable cuando [`efz_guardian:loop/1`](../../../src/efz_guardian.erl#L72) tiene alive/barriers vacíos y coordinator parado, después [`finish/2`](../../../src/efz_guardian.erl#L172). `snapshot_bits/1` lee palabras secuencialmente y no es snapshot atómico con escritores vivos ([`efz_cov_bitmap:snapshot_bits/1`](../../../src/efz_cov_bitmap.erl#L139)). `Active=0` tampoco cierra carrera check/CAS. Producción evita escribir en siguiente iteración con mapa nuevo; dirty cleanup prohíbe reutilización. [`efz_isolation_tests`](../../../test/efz_isolation_tests.erl#L17) comprueba descendientes/timeout, [`shared_writers_and_late_context_test/0`](../../../test/efz_bitmap_contract_tests.erl#L107) hit tardío en contexto viejo tras close/reset. Mensajes nuevos/viejos llevan `Ref`; guardian solo acepta su propio `Ref` ([`loop_event/2`](../../../src/efz_guardian.erl#L138)); al terminar, el dueño no transfiere mensajes a otro mapa.

`reset/1` asigna array nuevo; no hay listas dirty-word ni epochs. Full clear existe como [`clear_quiescent/1`](../../../src/efz_cov_bitmap.erl#L163) solo para benchmarks. Su check `Active=0` **no prueba** que un escritor no pasara antes y espere CAS: [`closed_clear_stale_cas_test/0`](../../../test/efz_bitmap_audit_tests.erl#L28) reproduce escritura después de clear. No es fuga productiva porque no se reutiliza array. Nombre/API necesita precondición join explícita o retirarse de la interfaz accesible.

## 5. Novedad, global y feedback de fuzzing

[`efz_cov_bitmap:wordwise/4`](../../../src/efz_cov_bitmap.erl#L193) calcula `Local band bnot Global` y `Local bor Global` en palabras de 64 bits sin convertir a sets. [`efz_feedback:bitmap_success/5`](../../../src/efz_feedback.erl#L42) decodifica bits **nuevos** para `new_probes` y `retention_reason`, luego obtiene global nuevo. La comparación no modifica global anterior. No hay *salida temprana* al primer word nuevo: siempre construye binary diferencia completo; API requiere lista exacta de todas las sondas nuevas. Aun sin novedad, recorre todo, crea binary y decodifica todos los ID del manifiesto. Es coste fijo medible descrito abajo.

Para historial `{} → {1,2} → {1,2} → {1,2,3} → {3} → {64,65} → {65}`, novedad debe ser `new, none, new, none, new, none`; el operador implementado produce esa secuencia y [`wide_differential/0`](../../../test/efz_bitmap_audit_tests.erl#L39) compara otro historial por la misma regla, incluidos vacío, 63/64/65/65535, hits repetidos, dos módulos, crash y timeout. [`efz_feedback:evaluate/3`](../../../src/efz_feedback.erl#L13) permite merge solo con `coverage_status=ok` y `{ok,_}`; crash/exit/timeout producen `target_failure` sin cambiar global. Calibrar seed correcto actualiza global sin añadirlo de nuevo. [`efz_worker:retain/2`](../../../src/efz_worker.erl#L245) decide retención después de feedback; [`record_failure/4`](../../../src/efz_worker.erl#L256) guarda/clasifica fallos aparte. ETS tiene mismas fronteras (`efz_feedback:evaluate/3`, líneas 30–39). `Result.coverage` externo sigue siendo lista exacta; [`public_result/1`](../../../src/efz_worker.erl#L352) elimina `coverage_bits` de informe/failure context.

## 6. Comprobaciones y benchmark

Los comandos Rebar3 corrieron **secuencialmente** para evitar compilar simultáneamente el mismo `_build`:

| Comando | Resultado |
| --- | --- |
| `ERL_FLAGS='+S 4:4' rebar3 eunit` | PASS, **241** tests tras añadir auditoría (véase `_build/bitmap-audit-eunit-final.log`) |
| `ERL_FLAGS='+S 4:4' rebar3 ct` | PASS, 3 tests |
| `ERL_FLAGS='+S 4:4' rebar3 xref` | PASS |
| `ERL_FLAGS='+S 4:4' rebar3 dialyzer` | PASS |
| `ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_bitmap_audit_tests` | PASS, 3 tests de auditoría |
| `ERL_FLAGS='+S 4:4' escript bench/bitmap_bench.escript _build/bitmap-audit-benchmark` | PASS; [samples raw](../../performance/bitmap-audit-2026-10-02-existing-bench.txt) |
| `ERL_FLAGS='+S 4:4' escript bench/bitmap_audit_bench.escript docs/performance/bitmap-audit-2026-10-02-samples.term` | PASS; [samples raw](../../performance/bitmap-audit-2026-10-02-samples.term) |

OTP 27.0 / ERTS 15.0, Linux x86_64, i7-1260P, `+S 4:4`, Rebar3 3.25.0. Ambos benchmarks calentaron 2 pares y alternaron orden ETS/bitmap en 10 pares repetidos. Manifiesto sintético: 1,024 sondas, 65,536 bits; campaña parser: `efz_example_target` seeded, 50 ejecuciones, corpus 4 y cobertura 5 en cada sample. Abajo medianas microsegundos, min/max en raw artifacts. Benchmark integrado recoge reductions y minor GC por separado; auditoría emparejada hace lo mismo. SHA-256: `bench/bitmap_bench.escript` `975240e42d32a96228d7c177f33053492904c2c9a3aaca1a71d766168e95266b`, `bench/bitmap_audit_bench.escript` `fdde7eea1345717f69e41863458b5f68f9970c06e41a35db19fb0c3511def29e`. Una máquina; no prueba otros harness/OTP.

| Etapa del benchmark existente | ETS | Bitmap |
| --- | ---: | ---: |
| 5,000 hits repetidos | 824 | 1 413 |
| 64 hits sparse | 18 | 23 |
| 1,024 hits distintos | 629 | 768 |
| Snapshot 64 / 1,024 | 13 / 293 | 39 / 38 |
| Decode 1,024 IDs | 312 | 88 |
| Compare / merge 256 | 84 / 58 | 30 / 28 |
| Full clear tras close | 0* | 19 |
| 10 ciclos completos sparse | 135 | 7 451 |
| 5 ciclos completos densos | 34 379 | 13 013 |
| 1 / 2 / 4 / 8 escritores, una palabra | 4 367 / 8 345 / 12 169 / 26 675 | 4 377 / 8 656 / 11 904 / 32 422 |
| Campaña parser, wall de 50 ejecuciones | 116 842 | 125 835 |

`*` ETS crea tabla nueva en vez de borrarla; 0 µs está bajo resolución útil. Wall mediano de 50 ejecuciones equivale a **428 exec/s ETS** y **397 exec/s bitmap**. Razón exec/s emparejada mediana `0.893`; bootstrap percentil 95% `[0.851,0.949]`, 10,000 remuestreos, seed `20261002`. Mide example parser, no harness productivo. Los ciclos completos de auditoría separada incluyen contexto nuevo, hits, observación exacta pública, bitmap snapshot, novedad y merge:

| Hits/ejecución | Mediana ETS (min–max), µs | Mediana bitmap (min–max), µs |
| --- | ---: | ---: |
| 1 | 4 (3–4) | 402 (347–452) |
| 100 | 97 (92–227) | 400 (286–546) |
| 1 000 | 3 054 (2 115–3 948) | 1 546 (725–2 125) |
| 10 000, ciclo de 1 024 IDs | 8 509 (6 471–9 730) | 7 374 (6 338–9 449) |
| 10 000 hits de un ID | 6 045 (4 951–6 885) | 7 796 (7 309–8 219) |

El ciclo de auditoría excluye deliberadamente cleanup de procesos guardian reales, mutación y E/S de corpus; la campaña parser los incluye. Con cobertura sparse dominan costes fijos de abrir mapa, dos snapshots/decodes y recorridos de mapa/manifiesto; `hit/1` no es el único límite. Con muchos hits repetidos se ve su coste: bitmap es 1.7× más lento que ETS en el microbenchmark de 5,000 hits. Bitmap mejora con cargas densas únicas porque compare/merge por palabras es barato. El perfil depende de densidad; no justifica investigar cobertura OTP-native/JIT antes de abordar coste fijo y medir harness productivo.

Memoria real de `efz_cov_bitmap:memory/1` con 1,024 sondas: atomics words **8,232 B**, active **48 B**, mapping ETS **20,084 palabras VM** (8 B cada una en esta VM ≈160,672 B), tuple inverso `external_size` **58,633 B**. Global binary y un snapshot inmutable ocupan **8,192 B** cada uno; manifests/plan/context/allocator son adicionales. Tabla ETS de ejecución tras 1,024 hits: **22,071 palabras VM**. `external_size` no es RSS y no se suman componentes sin más como memoria total de campaña. RSS y retención tras muchas campañas **NO SE COMPROBARON** aquí.

## 7. Problemas y evaluación

| Categoría | Estado | Evidencia y límite |
| --- | --- | --- |
| Corrección | **PASS** | Mapping sin colisiones, límites, bit alto y builds distintos comprobados; ninguna pérdida silenciosa dentro del alcance. |
| Seguridad concurrente | **PARTIAL** | **Medio:** CAS productivo conserva vecinos, pero [`clear_quiescent/1`](../../../src/efz_cov_bitmap.erl#L163) exportado solo comprueba `Active=0`; auditoría reprodujo escritor obsoleto tras close/clear. No reutilizar sin join. |
| Aislamiento | **PARTIAL** | **Medio:** mapa/Ref nuevos y timeout de descendientes probados, pero no cleanup no confirmado/muerte guardian específicos bitmap en VM nueva. [`efz_guardian:finish/2`](../../../src/efz_guardian.erl#L172) comparte lifecycle ETS, pero hace falta variante bitmap de [`efz_isolation_tests:fresh_vm/2`](../../../test/efz_isolation_tests.erl#L27) con deadline/kill forzado y sin commit/reutilización. |
| Compatibilidad semántica | **PASS** | Historiales idénticos y campañas seeded dan mismas decisiones observed/new/global/corpus/crash/timeout. |
| Rendimiento | **FAIL** | **Alto:** razón exec/s parser `0.893`; ciclo completo 1-hit `402` frente a `4` µs. [`efz_guardian:finish/2`](../../../src/efz_guardian.erl#L172) decodifica exacto y toma segundo snapshot; [`efz_cov_bitmap:wordwise/4`, `decode/2`](../../../src/efz_cov_bitmap.erl#L193) recorren todo mapa/schema; [`efz_feedback:bitmap_success/5`](../../../src/efz_feedback.erl#L42) incluso sin novedad. Perfilar/simplificar antes de hacerlo predeterminado. |
| Eficiencia de memoria | **PARTIAL** | **Medio:** payload 8 KiB, pero mapping ETS ~160 KiB en palabras VM y tamaño externo inverso ~58 KiB ya con 1,024 sondas; [`prepare/2`, `memory/1`](../../../src/efz_cov_bitmap.erl#L23). Sin RSS/retención completos. Medir pico/RSS en campañas repetidas antes de rollout. |
| Mantenibilidad | **PARTIAL** | **Medio:** [`snapshot_bits/1`](../../../src/efz_cov_bitmap.erl#L139) admite escritores vivos; su guard `Active=1` no estabiliza resultado. Guardian productivo cumple condición, pero API debe exigir quiescencia explícita o exponer snapshot solo por dueño lifecycle. |
| Observabilidad/depuración | **PARTIAL** | **Bajo:** [`efz_worker:finish/2`](../../../src/efz_worker.erl#L306) publica IDs exactos, pero faltan tiempos mapping/open, snapshot/decode, compare/merge y RSS total. Reproducir parser benchmark y añadir contadores antes de optimizar. |

Otra brecha de robustez (**media**): [`efz_config:valid_field/2`](../../../src/efz_config.erl#L69) acepta `coverage_bitmap_bits` positivos arbitrariamente grandes; [`efz_cov_bitmap:check_capacity/2`](../../../src/efz_cov_bitmap.erl#L14) solo comprueba sondas `<= Bits`. Un `1 bsl 60` pasa, pero [`efz_cov_bitmap:new_global/1`, `open/1`](../../../src/efz_cov_bitmap.erl#L74) intentará asignar objetos binary/atomics enormes al iniciar worker/ejecución. Es fallo explícito de recursos, no colisión silenciosa; limitar a máximo admitido o probar asignación/liberación antes de empezar con error claro.

## 8. Prioridades de mejora

**Bloqueantes P0 de corrección:** ninguno encontrado en automatic/presence comprobado. Antes de ampliar opt-in hace falta fault injection bitmap de cleanup no confirmado. Si divergen historiales o dirty cleanup no da infraestructura, volver inmediatamente a `coverage_backend => ets`.

**P1 rendimiento/arquitectura:** (1) añadir tiempos a [`efz_guardian:finish/2`](../../../src/efz_guardian.erl#L172) y [`efz_feedback:bitmap_success/5`](../../../src/efz_feedback.erl#L42), perfilar parser sparse y harness real; (2) confirmado coste fijo, obtener lista ID/bytes en una pasada estable y evitar full `NewBits` decode cuando se pruebe novedad cero, manteniendo `new_probes`/orden commit; (3) evaluar aparte dos lookups ETS/active checks/CAS en hits repetidos. No añadir dirty words/epochs antes de medir y pasar gate concurrente nuevo.

**P2 robustez/observabilidad:** (1) aclarar contrato o retirar `clear_quiescent/1` exclusivo benchmark; (2) explicitar frontera snapshot estable; (3) comprobar máximo de capacidad antes de asignar y tratar errores; (4) inyectar fallo dirty-cleanup bitmap; (5) publicar pico RSS, mapas activos/número schema ETS en campañas repetidas. No cambian instrumentación ni harness API.

## 9. Respuestas principales

- **¿Conserva semántica EFZ previa?** Sí, en automatic/presence probado, incluido merge global solo en éxito y política corpus/fallos.
- **¿Pérdida silenciosa?** No encontrada: lookup exacto de identidad completa, overflow/BuildId desconocido dan error, CAS preserva vecinos.
- **¿Varios procesos seguros?** Sí para descendientes controlados y mapa nuevo productivo; `clear_quiescent/1` solo no basta para reutilizar.
- **¿Iteraciones aisladas?** Sí en timeout controlado comprobado: A y B usan arrays diferentes; hit tardío A no alcanza B. Pendiente fault injection bitmap de cleanup no confirmado.
- **¿Bitmap más rápido?** No en parser medido y sparse cycles; fases densas únicas a veces mejoran.
- **¿Límite nuevo?** Con input sparse, trabajo fijo snapshot/decode/mapa; con hits repetidos muy frecuentes, también Erlang `hit/1` con checks/lookup ETS. No hay límite único demostrado para todos los harness.
- **¿Listo como predeterminado?** No. Mantener opt-in experimental; ETS sigue default/reference/rollback.
