# Plan de implementación del backend de cobertura bitmap

[English](../../../plans/coverage-bitmap-implementation-plan.md) · [Русский](../../ru/plans/coverage-bitmap-implementation-plan.md) · **Español** · [简体中文](../../zh-CN/plans/coverage-bitmap-implementation-plan.md) · [Todos los idiomas](../../README.md)

Estado: P1–P7 implementados y verificados el 2 de octubre de 2026; P0 baseline de rendimiento y P8 rollout incompletos. Resultados en el [informe](../coverage-bitmap-implementation-report.md). Base: [arquitectura](../coverage-bitmap-architecture.md), contrastada con fuentes actuales. Primera versión: `automatic` + `presence`, un worker EFZ, OTP normal y sondas estructurales existentes. `ets` sigue predeterminado/referencia; `ets_member` y ETS `hit_count` funcionan. Se excluyen parches OTP/ERTS, DWARF, NIF, edge coverage, buckets hit-count para bitmap, cambios de harness o motor de mutaciones.

## Punto de partida verificado y correcciones de arquitectura

| Contrato | Evidencia en código |
| --- | --- |
| `efz_instrument:compile_target/2` activa `efz_instrument_pt`; `probe/4` inserta `efz_cov_rt:hit({Module,BuildId,ProbeId})` en cuerpos clause/outcome. `ProbeId` empieza en 1 por build de módulo. | [`efz_instrument.erl`](../../../../src/efz_instrument.erl), [`efz_instrument_pt.erl`](../../../../src/efz_instrument_pt.erl) |
| La entrada hit valida PID/contexto y envía first-hit; ETS conserva identidades exactas. `efz_cov` ofrece API pública compatible, `efz_coverage` ya despacha y `efz_cov_ets` implementa almacenamiento y operaciones de sets. | [`efz_cov_rt:hit/1`](../../../../src/efz_cov_rt.erl), [`efz_cov.erl`](../../../../src/efz_cov.erl), [`efz_coverage.erl`](../../../../src/efz_coverage.erl), [`efz_cov_ets.erl`](../../../../src/efz_cov_ets.erl) |
| Guardian crea contexto/tabla por ejecución; raíz y `efz_target:spawn[_link]/1` entran por compuerta y conexión explícita. Varios escritores usan una tabla. Tras timeout/fin, cierra admisión, mata supervivientes, espera `DOWN`/barreras y toma snapshot. Cleanup fallido marca dirty. | [`efz_guardian:start/6`, `admit/2`, `cleanup/2`, `finish/2`](../../../../src/efz_guardian.erl), [`efz_target.erl`](../../../../src/efz_target.erl), [`efz_cov_integrity.erl`](../../../../src/efz_cov_integrity.erl) |
| `efz_feedback:evaluate/3` compara `Observed − Global` y mezcla **solo** `coverage_status=ok`, `outcome={ok,_}`. Calibration actualiza global sin duplicar seed. Crash/exit/timeout no lo actualizan. Worker retiene por `retention_reason`; crashes aparte. | [`efz_feedback.erl`](../../../../src/efz_feedback.erl), [`efz_worker:execute_result/6`, `retain/2`, `record_failure/4`](../../../../src/efz_worker.erl), [`efz_corpus.erl`](../../../../src/efz_corpus.erl) |
| `rebar.config` exige OTP 27 mínimo y `warnings_as_errors`; verificado OTP 27.0 / ERTS 15.0, x86_64, Rebar3 3.25.0. `atomics` exporta `compare_exchange/4`, no OR; unsigned array acepta/devuelve `1 bsl 63` y `2^64−1`. CAS retorna `ok` con éxito y valor anterior con mismatch. Comprobación local API, no prueba de rendimiento. | [`rebar.config`](../../../../rebar.config); comandos abajo |
| Tests: `rebar3 eunit --module=efz_coverage_layer_tests,efz_backend_tests`, `rebar3 ct`, `rebar3 eunit` completo, xref/dialyzer. Integración: `efz_coverage_SUITE`, `efz_feedback_loop_tests`, `efz_isolation_tests`, `efz_backend_tests`. Bench: `scripts/coverage_bench.escript`, `bench/run.escript` (`hooks`, `executor`, `campaign`, `memory`, `startup`), `bench/profile.escript`. | [`test/`](../../../../test), [`bench/run.escript`](../../../../bench/run.escript), [`bench/efz_perf.erl`](../../../../bench/efz_perf.erl), [`scripts/coverage_bench.escript`](../../../../scripts/coverage_bench.escript) |

Comprobación de esta sesión: `ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_coverage_layer_tests,efz_backend_tests` — **18/18 PASS**. Es baseline ETS existente, no validación bitmap. El árbol ya era dirty; baselines lógicos/temporales necesitan commit/diff exactos y directorios separados.

Reproduzca la comprobación de primitivas en este OTP sin cambiar archivos:

```sh
erl -noshell -eval 'A=atomics:new(1,[{signed,false}]), M=1 bsl 63, ok=atomics:compare_exchange(A,1,0,M), M=atomics:get(A,1), ok=atomics:compare_exchange(A,1,M,16#ffffffffffffffff), 16#ffffffffffffffff=atomics:get(A,1), io:format("~p~n",[atomics:module_info(exports)]), halt().'
```

Se corrigió arquitectura original: config rechaza bitmap + `hit_count` inicialmente; se precisaron signedness/CAS en OTP 27.0 probado. Otro detalle importante: `efz_coverage:unseen/2` y `merge/2` usan sets/listas Erlang y `Result.coverage` es lista exacta. La comparación por bits necesita snapshot **interno** junto a la lista pública; cambiar solo `hit/2` no basta. Guardian actual puede formar Hits incluso con dirty cleanup, pero marca `coverage_status` como error; bitmap tampoco debe tratarlo como estable/apto para commit.

## Decisiones finales de la primera versión

### A. Schema y slot

Única clave: `{Module, BuildId, ProbeId}` de manifiestos validados. En preparación, [`efz_cov_manifest:prepare/2`](../../../../src/efz_cov_manifest.erl) sigue siendo fuente de allowlist/build-pin; bitmap construye **descriptor schema inmutable** independiente vinculado al plan. Ordenar por nombre UTF-8, los 32 bytes BuildId y ProbeId positivo; verificar unicidad; asignar `0..N−1`. Worker posee ETS protegido `FullId → Slot`; array/tuple inverso `Slot → FullId` solo para snapshot/report. Conservar identidad completa en lookup: `ProbeId` iguales de módulos/builds distintos reciben slots distintos. Build map y SHA-256 de secuencia canónica versionada forman fingerprint. Mismatch schema/build es infraestructura antes de comparar; no ignorar sondas nuevas/desconocidas.

Calcular fingerprint desde versión explícita de formato, métrica `clause_outcome_probe`, versiones manifest/instrumentation, capacidad y secuencia canónica; no depender del orden ETF map no especificado. Configuración `coverage_bitmap_bits`: **65536 bits** por defecto, entero múltiplo de 64; `N > capacity` es error claro previo con `required_bits` y `configured_bits`. Sin crecimiento automático en campaña. Elegir mapa mayor **antes** de iniciar. Slots sin uso siguen cero. Sin `rem MapSize`, truncación ni mezcla BuildId. Corpus input bytes pueden recalibrarse con build nuevo; bitmaps no pasan automáticamente entre builds. Primera versión no añade formato de global bitmap persistente.

### B. Mapa mutable y bit 63

Mapa de ejecución: `atomics:new(Capacity div 64,[{signed,false}])`, palabras unsigned 64-bit. Para `Slot ∈ [0,Capacity)`, `Word = Slot div 64 + 1` (API base 1), `Mask = 1 bsl (Slot rem 64)`. En slot 63 la máscara es `2^63`, válida unsigned; slot 64 usa word 2, mask 1. Comprobar límites/schema antes de CAS: `Old=atomics:get`; si `(Old band Mask) /= 0`, terminar; si no, `compare_exchange(Ref,Word,Old,Old bor Mask)`; `ok` indica first hit, valor actual devuelto exige retry. En `badarg`, notificar fallo backend al guardian. Enviar `efz_cov_observed` **después** del CAS 0→1 correcto, una vez por bit. Nunca sustituir por `get` + `put`. Lectura/merge deben considerar máscaras unsigned y última palabra; `Slot >= N`/bit fuera de schema no es sonda.

### C. Aislamiento, snapshot, reset

Guardian posee **mapa separado por ejecución** y mantiene `{efz_context,1,Ref,Storage,Owner}` externo; `Storage` será handle tagged opaco. Pasar contexto solo por `efz_guardian:admit/2` y `efz_coverage:attach/1` existentes. No depender de herencia de process dictionary. Conservar registro PID/checks en `efz_cov_rt:hit/1`. Tras timeout cerrar admisión y terminar todos los escritores controlados, incluidos hijos; esperar `DOWN` y barreras, después snapshot. También drenar/comprobar first-hit/error events contra snapshot.

Flag/epoch puede rechazar rápido hit tardío, pero comprobar `active` antes de CAS **no cierra** ventana check/write. Seguridad: mapa único, no reutilizar antes de quiescencia demostrada y no aceptar snapshot/commit válido con cleanup no confirmado. Tras close, hit tardío debe dar infraestructura diagnosticable; aunque una carrera permita CAS en mapa **viejo**, no alcanza iteración siguiente. Con cleanup no confirmado no limpiar/reutilizar mapa; retirar runner sin tratarlo como cobertura correcta. Primera implementación libera mapa tras snapshot confirmado; siguiente iteración asigna otro: reset productivo seguro. Implementar/medir **full clear** (`atomics:put(...,0)` en todas las palabras) solo en mapa probadamente quiescente de test/benchmark; reutilizar en producción solo si lifecycle prueba propiedad exclusiva. Dirty-word tracking y epochs después de P8.

### D. Global y feedback

Worker sigue siendo único dueño de política. [`efz_feedback:evaluate/3`](../../../../src/efz_feedback.erl) valida status/outcome **antes** de compare/merge bitmap. Para presence correcto, `Local & ~Global` produce identidades nuevas exactas para `new_probes`/`retention_reason`; tras decisión global pasa a `Global | Local`. Global inicial: binary inmutable con fingerprint en worker; nuevo valor **por iteración**, no hit, instalado solo después de decisión correcta. Crash/exit/timeout e infraestructura no cambian global. No dar al backend función que decida retención. `efz_worker:retain/2` y `record_failure/4` siguen activos. Futuro multiworker exigiría serializar compare-and-commit; actualmente `workers=1`.

### E. API, metadatos, compatibilidad

Conservar `efz_cov_rt:hit/1`, `efz_cov:open/0,/1,/2`, `attach/1`, `detach/0`, `snapshot/1`, `close/1`, API manual, `efz_executor:run/4`, `Result.coverage` (IDs exactos ordenados), `efz_feedback:evaluate/3` e informe público. Ampliar **interno** `efz_coverage:open/3` con schema validado, dejar `open/2` para ETS; añadir `prepare_schema/2`, `snapshot_bits/1`, `new_global/1`, `unseen_bits/2`, `merge_bits/2`, `decode_new/2` (nombres ajustables en P1, semántica no). Nuevos `-opaque bitmap_schema()` / `bitmap_context()` / `bitmap_snapshot()` ocultan atomics handle y fingerprint; validar versión del descriptor en cada frontera. Resultado bitmap correcto lleva `coverage_bits` inmutable interno con fingerprint al worker, y `coverage` normal se decodifica al terminar para validar/informar. Campo extra de `run/4` bajo nivel no es formato persistido: worker lo retira antes de crash/runtime artifacts, failure context e informes; crash/timeout no lo llevan. No confundir con `coverage_observation` (mapa clasificación). Comparar fingerprint obligatorio para `unseen_bits/merge_bits`. Diagnóstico traduce bits mediante reverse mapping a probe IDs/posiciones fuente; informes/crash reciben la misma lista.

Rechazar bitmap + `hit_count` y bitmap + `manual` en `efz_config:prepare/1` y `open/3` bajo nivel antes de ejecutar. `ets`/`ets_member` mantienen ambos modos. Elegir backend no modifica manifiesto ni transfiere global anterior a campaña nueva.

## Etapas y condiciones de aceptación

Ejecutar desde raíz `efz`; fijar `ERL_FLAGS='+S 4:4'` en tests/benchmarks. En cada etapa, commit solo sus archivos tras validar; fallback elimina/desactiva ruta añadida, restaura `coverage_backend => ets` sin migrar cobertura persistida. Nombres de archivos nuevos abajo son propuestas; módulos existentes se indican por funciones reales.

| Etapa | Trabajo concreto y API | Depende de | Comprobación / resultado observable / aceptación | Rollback |
| --- | --- | --- | --- | --- |
| **P0 Baseline** | Registrar commit/diff, OTP y `erl:system_info`, manifiestos, historial exacto y decisiones seeded. Añadir fixture/event recording baseline en `test/efz_backend_tests.erl` y nuevo `test/efz_bitmap_contract_tests.erl` sin rama bitmap. Guardar raw benchmarks en `_build/bitmap-baseline/`, no docs históricos. Sin cambios API. | Nada | `rebar3 compile`; `ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_coverage_layer_tests,efz_backend_tests`; `ERL_FLAGS='+S 4:4' rebar3 ct`; `ERL_FLAGS='+S 4:4' escript bench/run.escript all _build/bitmap-baseline reference`. IDs, global/decisiones, comandos y raw samples registrados sin afirmar aceleración. | Retirar solo nuevas fixtures/artifacts; producción intacta. |
| **P1 Frontera backend** | Afinar dispatch en `src/efz_coverage.erl` y adaptador legacy `src/efz_cov_ets.erl`; conservar delegación de `open/2`, `attach/1`, `hit/2`, `snapshot/1`, `close/1`, `unseen/2`, `merge/2`. Añadir tipos internos/`open/3` rechazando `bitmap` sin schema. No cambiar `efz_cov_rt:hit/1`/`efz_cov`. | P0 | Focused EUnit + `rebar3 xref`; contexto legacy, eventos, error/status y decisiones iguales a P0 byte a byte/estructuralmente. | Restaurar dispatch actual. |
| **P2 Mapping** | `src/efz_cov_manifest.erl`: conservar `prepare/2`/`validate_prepared/3`; preparar schema desde manifiestos/plan validados. Si procede `src/efz_cov_bitmap.erl` para mapping inmutable; capacidad en `src/efz_config.erl` después, primero argumento interno. Implementar `FullId→Slot`, inverso, fingerprint y errores overflow/unknown/mismatch. | P1 | `ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_bitmap_contract_tests,efz_backend_tests`; biyección, ID local igual entre módulos, BuildId, 0/last/overflow. Sin colisiones. | Retirar módulo/rama mapping sin cambiar plan ETS. |
| **P3 Storage** | `src/efz_cov_bitmap.erl`, `src/efz_coverage.erl`: unsigned atomics map, slot lookup acotado, CAS hit, first-hit, `snapshot_bits/1`, full clear tras quiescencia. Handle interno opaco; `efz_cov_rt:hit/1` intacto. | P2; spike CAS acotado correcto abajo | Focused EUnit, dos escritores sincronizados por palabra, slots 0/63/64/last, hit repetido, bit alto unsigned, handle malformado. Bits/eventos exactos; OTP no compatible detiene preparación. | Retirar dispatch bitmap; ETS intacto. |
| **P4 Lifecycle** | `src/efz_guardian.erl:start/6,admit/2,cleanup/2,finish/2`, `src/efz_executor.erl:coverage/3`, `src/efz_worker.erl:executor_reference_options/1`, `src/efz_cov_integrity.erl`: pasar schema a `open/3` también con `coverage_validation=per_execution`, esperar quiescencia, validar first-hit, prohibir reuse tras dirty y diagnosticar hits tardíos. No cambiar API `efz_target`. | P3 | `ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_backend_tests,efz_isolation_tests,efz_bitmap_contract_tests`; barreras hit/timeout, child admission, cleanup failure, A→B→A. Solo resultados confirmados tienen snapshot estable; dirty nunca commit. | Desactivar bitmap; guardian ETS intacto. |
| **P5 Comparación** | `src/efz_coverage.erl`: bitmap `new_global/1`, `unseen_bits/2`, `merge_bits/2`, `global_snapshot/1`, fingerprint checks; `src/efz_feedback.erl:new/3,evaluate/3`: inicializador interno con schema, conservar `new/1,/2`; presence compara/mezcla solo snapshots inmutables correctos; `src/efz_worker.erl:init/1,execute_checked/4,execute_result/6,record_failure/4`: crear schema/global, usar bits internos y retirarlos de metadatos persistidos/report/failure-context. `Result.coverage`, `new_probes`, retention_reason públicos intactos. | P4 | Mismo historial sintético ETS/bitmap, `efz_feedback_loop_tests`; global no cambia crash/timeout, mismas decisiones calibration/mutation, error snapshot mismatch, sin bits internos en crash/replay. | Presence vuelve a ETS-set sin tocar corpus API. |
| **P6 Config/integración** | `src/efz_config.erl:valid_field/2,prepare_coverage/1`, `src/efz_worker.erl:init/1,executor_reference_options/1`, `src/efz_guardian.erl:start/6`, `docs/cli.md`: admitir config **API** `bitmap` y `coverage_bitmap_bits`, rechazar manual/hit_count y exceso capacidad antes de ejecutar. CLI no tiene flag backend; no hace falta añadirlo. Default `ets`. `efz_recipe:execute/5` y `efz_replay_cli` conservan ETS replay de referencia con mismas identidades. Harness/mutator intactos. | P5 | `ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_config_tests,efz_backend_tests,efz_cli_tests,efz_phase3_tests`; `ERL_FLAGS='+S 4:4' rebar3 ct`. API elige bitmap, CLI/replay ETS conserva resultados, pares inválidos dan errores estables. | Restaurar allowlist `ets,ets_member`; replay intacto. |
| **P7 Aceptación diferencial** | `test/efz_bitmap_contract_tests.erl`, `test/efz_backend_tests.erl`, `test/efz_coverage_SUITE.erl`, `test/efz_feedback_loop_tests.erl`: historial prescrito storage/feedback y luego fixtures/campañas seeded iguales. Comparar coverage exacta, estados, novedad, IDs/contenido corpus, crash/timeout evidence. | P6 | `ERL_FLAGS='+S 4:4' rebar3 eunit`; `ERL_FLAGS='+S 4:4' rebar3 ct`; `rebar3 xref`; `rebar3 dialyzer`. Cero diferencias de contrato; harness real no determinista se compara por invariantes/repeticiones, no trace carácter a carácter. | ETS predeterminado; desactivar bitmap experimental. |
| **P8 Benchmark/rollout** | Ampliar `bench/efz_perf.erl`/`bench/run.escript` con bitmap y cargas `hit/clear/snapshot/compare/merge/full-cycle` separadas; `bench/profile.escript` para atribuir. Medir con protocolo siguiente. Dirty words/epochs solo por decisión aparte tras demostrar beneficio. Actualizar `README.md`, `docs/coverage.md`, estado de arquitectura. | P7 | Raw samples, entorno, parser/sparse/dense/repeat/multiwriter; correctness obligatorio. Default solo por decisión separada tras gates; si no, opt-in. | `coverage_backend => ets`; conservar bitmap opt-in o retirarlo por defecto de corrección. |

Comandos por gate (nuevo `efz_bitmap_contract_tests` y variante bitmap aparecen en etapa correspondiente):

```sh
# P0
ERL_FLAGS='+S 4:4' rebar3 compile
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_coverage_layer_tests,efz_backend_tests
ERL_FLAGS='+S 4:4' rebar3 ct
ERL_FLAGS='+S 4:4' escript bench/run.escript all _build/bitmap-baseline reference
# P1
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_coverage_layer_tests,efz_backend_tests
ERL_FLAGS='+S 4:4' rebar3 xref
# P2, P3 and spike correctness
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_bitmap_contract_tests,efz_backend_tests
# P4
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_bitmap_contract_tests,efz_backend_tests,efz_isolation_tests,efz_integrity_tests
# P5
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_bitmap_contract_tests,efz_backend_tests,efz_feedback_loop_tests
# P6
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_config_tests,efz_backend_tests,efz_cli_tests,efz_phase3_tests
# P7
ERL_FLAGS='+S 4:4' rebar3 eunit
ERL_FLAGS='+S 4:4' rebar3 ct
ERL_FLAGS='+S 4:4' rebar3 xref
ERL_FLAGS='+S 4:4' rebar3 dialyzer
# P8 (after adding the bitmap variant to bench/run.escript)
ERL_FLAGS='+S 4:4' escript bench/run.escript all _build/bitmap-compare reference
ERL_FLAGS='+S 4:4' escript bench/run.escript all _build/bitmap-compare-bitmap bitmap
```

Para P8 ejecutar además etapa nueva que separe reset/snapshot/compare/merge con seed y número de escritores especificados; registrar nombre/parámetros en benchmark README antes de comparar. No ejecutar tests/variantes bitmap inexistentes en P0.

### Spike acotado antes de P3

En archivo/script separado de `bench/`, comparar CAS-loop unsigned `atomics` con alternativa de dueño ETS/counter serializado **solo** en corrección y coste de contención por palabra. Comprobar 0, `2^63`, `2^64−1`, éxito/fallo `compare_exchange`, límites base 1; iniciar 1/2/4/8 escritores tras barrera en bits vecinos, 10 repeticiones y palabras finales exactas. Ganador conserva cada bit y tiene coste medible; con corrección igual conservar CAS, ruta más simple. Si CAS unsigned falla en OTP admitido, P3 bloqueado hasta otra primitiva BEAM; no usar `get+put`. Spike no cambia API productiva.

## Matriz de tests

`B` es bitmap, `E` referencia ETS. Para storage/feedback alimentar **la misma secuencia exacta de identidades hit y finales de iteración** a ambos. En integración fijar bytes, seeds y manifests/builds; algunos harness reales son no deterministas, comparar invariantes admitidos outcome/coverage y repeticiones, no orden de scheduling idéntico.

| Escenario | Método / resultado esperado |
| --- | --- |
| Cobertura vacía | Conexión confirmada: `[]`, `valid_empty_coverage`, `New=[]`; broken/unstarted aparte, no vacío válido. E=B. |
| Hit repetido | Slot sigue 1, un first-hit event, snapshot un ID. E=B. |
| Dos bits en palabra | Dos escritores leen 0 mediante barrera antes de CAS; liberados ambos, existen ambos bits. Repetir con CAS retry. |
| Slots 0, 63, 64, último | Dirección `(0→word1,bit0)`, `(63→word1,bit63)`, `(64→word2,bit0)`, `(capacity−1→last)`; bit alto unsigned no negativo. |
| Exceso capacidad | `N=capacity+1` rechazado en preparación con required/configured; slot `capacity` rechazado sin wrap. |
| ID local coincidente | `{M1,B1,1}` y `{M2,B2,1}` reciben slots distintos; otro BuildId del mismo módulo no merge. |
| Schema/build mismatch | Sustituir BuildId/fingerprint, plan o código cargado: error antes de merge; no usar bitmap guardado de otro build. |
| Sin novedad; uno/varios bits nuevos | `[A]→[A]→[A,B]→[B,C,D]`; listas nuevas `A, [], B, C/D`; decisiones/orden IDs coinciden E/B. |
| Acumulación global | Tras éxitos `A`, `B`, global=`{A,B}`; repetir no cambia; calibration actualiza global sin duplicar corpus. |
| A→B→A | Mapas independientes; tercer local=`{A}`, global=`{A,B}`. Full clear viejo solo quiescente, nunca global. |
| Crash/timeout | Barrera garantiza hit previo; resultado contiene ID, global/corpus correctos intactos, artifacts/counters iguales antes. |
| Hit tardío/cleanup fallido | Retrasar escritor tras active check, iniciar timeout/close y liberarlo. No escribe mapa B; sin terminación probada A no tiene snapshot válido y runner dirty. Barreras, no solo estrés. |
| Hits concurrentes misma palabra | N hijos controlados comparten contexto, barrera antes primer CAS, fijan vecinos/idénticos; popcount exacto y first-hit evidence completa. Añadir stress 10⁴ ciclos. |
| Cambio backend | Campañas ETS→B→ETS separadas con mismo schema/inputs dan decisiones iguales; sin transferir global por defecto. |
| Decisión corpus | Integración seeded/replay de stream: `retention_reason`, `new_probes`, adición/dedup, crash/timeout iguales E/B. Bitmap `hit_count` da error config sin target. |

## Protocolo benchmark y gates de rendimiento

1. P0 primero: `ERL_FLAGS='+S 4:4' rebar3 compile`, después `ERL_FLAGS='+S 4:4' escript bench/run.escript all _build/bitmap-baseline reference` y `ERL_FLAGS='+S 4:4' escript scripts/coverage_bench.escript`. Este último es microbenchmark histórico de hooks, no coste total. Guardar raw `.term`, SHA-256 source/fixture, `git rev-parse HEAD`, `git diff --stat`, OTP/ERTS, `system_architecture`, wordsize, `schedulers_online`, JIT/flags y hardware. No comparar cifras publicadas sin entorno coincidente.
2. Tras P7 usar manifiestos y streams seeded idénticos: sets sparse/dense, 1/8/64/1024+ sondas distintas, variación de hits por ejecución, 90%+ repetidos, 1/2/4/8 escritores controlados con/sin contención. Medir mapping preparation aparte de steady state; memoria incluye atomics, mapping ETS, inverso, context, manifest/plan, global y process heap.
3. Separar `hit` (primero/repetido), full clear/reset, quiescence+snapshot, decode, comparación, merge, ciclo `reset→execute→collect→compare→commit` y mutation exec/s end-to-end en parser/loop/sparse/harness real. Separar calibration, startup y steady mutation. Normalizar comprobando corpus/outcomes; no excluir silenciosamente errores/timeouts del denominador.
4. Mismos schedulers/warmup, al menos 10 pares alternando E/B, VM separadas cuando se necesite limpiar estado. Publicar todos samples, mediana, min/max, ratios emparejados y bootstrap 95%; reductions, GC, memoria asignada/proceso y `atomics:info(memory)`/ETS si disponible. `bench/profile.escript` explica coste, no throughput. Registrar procesos vecinos/deriva térmica como límites.
5. **Correctness gate:** P7/matriz completa, cero bits perdidos, cero schemas mezclados, cero decisiones corpus cambiadas. **Opt-in performance gate:** ninguna degradación mediana end-to-end sostenida >5% en cada carga representativa preelegida; si no, experimental y perfilar. **Default-switch gate:** además, límite inferior del intervalo 95% emparejado bitmap/ETS exec/s >1.0 en carga principal preelegida y ≥0.95 en las demás; publicar memoria completa y p95 de latencia, dentro de límites de campaña escritos de antemano. Son reglas, no resultados esperados. Con medidas inestables ETS predeterminado. Regresión de corrección restaura ETS inmediatamente.
6. Reset inicial hace full clear de todas las palabras solo tras quiescencia. Dirty words/epochs en experimento opt-in nuevo si desglose demuestra impacto material de clear; repetir matriz concurrente/lifecycle y benchmark tras cambiarlo.

## Definición de terminado y rollout

Estado real: P0 **partial** (226 EUnit baseline y 3 CT pasaron, `bench/run.escript all` histórico interrumpido después de más de tres minutos sin resultado); P1–P7 **implementados** con checks secuenciales aprobados; P8 **partial** (micro/campaign benchmark emparejado completado con `bench/bitmap_bench.escript` separado, no alcanzado gate parser, default intacto). Driver separado en vez de variante `bench/run.escript` es desviación limitada deliberada; aún hace falta benchmark antiguo para cargas históricas. Véase [informe](../coverage-bitmap-implementation-report.md).

- [x] Identidades exactas/source mapping intactos; bitmap solo automatic/presence.
- [x] Mapping inyectivo, fingerprint versionado/capacidad comprobados; builds incompatibles no mezclados.
- [x] CAS bit63/bordes/control de escritores concurrentes probado; integridad first-hit conservada en escenarios verificados.
- [x] Snapshot solo tras quiescencia confirmada; hit tardío/dirty no produce commit/reuse válido en descendientes controlados.
- [x] `Result.coverage`, feedback, global, corpus y decisiones crash/timeout coinciden con ETS en matriz implementada.
- [x] `rebar3 compile`, `rebar3 eunit` completo, `rebar3 ct`, `rebar3 xref`, `rebar3 dialyzer` pasan con OTP admitido.
- [ ] P8 completo: raw samples publicados, pero faltan baseline histórico, harness productivo, RSS/p95 completo e intervalos.
- [x] ETS predeterminado hasta decisión aparte por gates; rollback con un selector sin migración de cobertura.

Rollout recomendado: test interno bajo nivel → opt-in `coverage_backend => bitmap` para campaña automatic presence → CI diferencial en ambos → medidas harness real → decisión default aparte. Discrepancia: volver inmediatamente a `ets`, guardar historial fallido y metadatos map/schema para reproducir. Inputs corpus reutilizables con recalibración; bits guardados solo con fingerprint exactamente igual, si no, no importarlos.

## Primeras tareas del agente de implementación

1. **P0:** registrar historial reproducible y baseline ETS en `test/efz_backend_tests.erl`/test contrato nuevo, guardar benchmark raw/entorno; ruta productiva intacta.
2. **P1:** fijar contrato interno dispatch/tipos `efz_coverage` con ETS intacto y EUnit focused.
3. **P2:** implementar mapping + fingerprint + errores capacidad con tests biyección/límites; aún sin conectar hit path.
4. **Spike/P3:** comprobar CAS unsigned en OTP 27 e implementar bit set atómico con test concurrente controlado; después integrar mapa.

Cada tarea da resultado verificable independiente; la siguiente empieza tras aprobar gate previo.
