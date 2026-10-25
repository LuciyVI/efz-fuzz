# Backend de cobertura bitmap: informe de implementación

[English](../../coverage-bitmap-implementation-report.md) · [Русский](../ru/coverage-bitmap-implementation-report.md) · **Español** · [简体中文](../zh-CN/coverage-bitmap-implementation-report.md) · [Todos los idiomas](../README.md)

Referencia histórica bitmap-v1. La ruta actual de campaña reutiliza un mapa
sellado; consulte la [continuación bitmap-v2](coverage-bitmap-v2-results.md).
Las mediciones y afirmaciones de no reutilización siguientes describen v1 en
la fecha de este informe.

Fecha: 2026-10-02. Checkout: `8b5cb05b5b57231b9133be13c883f25863e05d11` más
cambios existentes sin commit. Este trabajo no sobrescribió archivos con cambios
ajenos ni modificó el backend predeterminado. La
[arquitectura](coverage-bitmap-architecture.md) y el
[plan](plans/coverage-bitmap-implementation-plan.md) definen el contrato previsto.

## Implementado

| Límite | Archivos y API |
| --- | --- |
| Mapeo/almacenamiento | [`efz_cov_bitmap.erl`](../../../src/efz_cov_bitmap.erl): `prepare/2`, `open/1`, `hit/2`, `snapshot_bits/1`, `reset/1`, `close/1`, `release/1`, `unseen_bits/2`, `merge_bits/2`, `decode/2`. |
| Selección | [`efz_coverage.erl`](../../../src/efz_coverage.erl): `open/3`, `prepare_schema/2`, `new_global/1`, `snapshot_bits/1` internos, comparación/combinación bit a bit y decodificación diagnóstica. La API ETS existente permanece. |
| Selección/ciclo de vida | [`efz_config.erl`](../../../src/efz_config.erl) valida bitmap solo para presencia automática y capacidad antes de la campaña; [`efz_worker.erl`](../../../src/efz_worker.erl) posee esquema/global y elimina bits internos de resultados persistidos; [`efz_guardian.erl`](../../../src/efz_guardian.erl) recoge bits después de limpiar escritores controlados; [`efz_executor.erl`](../../../src/efz_executor.erl) valida fijaciones de esquema/compilación; [`efz_feedback.erl`](../../../src/efz_feedback.erl) aplica la política existente de confirmar solo éxitos. [`efz_instrument_pt.erl`](../../../src/efz_instrument_pt.erl) excluye el módulo interno nuevo de la instrumentación de objetivos. |
| Pruebas/mediciones | [`efz_bitmap_contract_tests.erl`](../../../test/efz_bitmap_contract_tests.erl), casos bitmap en [`efz_isolation_tests.erl`](../../../test/efz_isolation_tests.erl), [`bitmap_bench.escript`](../../../bench/bitmap_bench.escript) emparejado, [muestras originales](../../performance/bitmap-2026-10-02-samples.txt). |

La instrumentación sigue emitiendo `efz_cov_rt:hit({Module,BuildId,ProbeId})`;
los harnesses y operadores de mutación no acceden al backend. El worker prepara
una tabla ETS protegida `FullId → Slot` desde manifiestos validados y ordena
las identidades completas por nombre de módulo UTF-8, los 32 bytes de BuildId
y ProbeId. Rechaza duplicados y `N > coverage_bitmap_bits`. Una huella SHA-256
versionada incluye métrica, versiones de esquema/instrumentación, capacidad e
identidades canónicas. Los aciertos desconocidos y huellas incompatibles fallan
explícitamente. Los **65.536 bits** predeterminados requieren **8 KiB de datos**,
más sobrecoste de atomics, mapeo, tupla inversa, contexto y asignador. No hay
módulo aritmético, hashing ni importación de bitmap entre compilaciones.

Cada ejecución controlada recibe un array exclusivo de palabras `atomics`
sin signo y una bandera activa. Un proceso admitido recibe explícitamente el
contexto mediante la barrera existente del guardian. La ranura `s` usa el
índice atomics `s div 64 + 1` y máscara `1 bsl (s rem 64)`;
`compare_exchange/4` reintenta lecturas obsoletas, incluido el bit 63.
El guardian ya detiene la admisión, termina los descendientes controlados y
espera `DOWN`/barreras de traza antes de capturar. Una sola comprobación de
bandera activa no elimina la carrera entre comprobación y CAS; por ello,
producción nunca reutiliza un mapa mutable antiguo. Los resultados confirmados
reciben una instantánea inmutable de 8 KiB; una limpieza no confirmada es
fallo de infraestructura y no puede confirmar. `reset/1` asigna un mapa nuevo.
`clear_quiescent/1` es solo una primitiva medida para llamadores que hayan
demostrado por separado que todos los escritores terminaron. El worker posee
la instantánea global inmutable y la comparación/confirmación serializada.
Solo un resultado válido `{ok,_}` la cambia; caída, exit y tiempo límite
conservan su clasificación/artefactos sin combinación global. Las observaciones
públicas e informes mantienen IDs exactos; la decodificación diagnóstica queda
fuera de la ruta de aciertos.

## Validación

Antes de implementar: `ERL_FLAGS='+S 4:4' rebar3 compile`, `eunit` completo
(**226 superadas**), `ct` (**3 superadas**), `xref` y `dialyzer` se superaron.
El antiguo `bench/run.escript all _build/bitmap-baseline reference` permaneció
más de tres minutos en su etapa larga `hooks` y fue interrumpido; **no tiene
un resultado completo de referencia**. El histórico
`ERL_FLAGS='+S 4:4' escript scripts/coverage_bench.escript` se ejecutó después
de implementar y pasó, pero es un microbenchmark de hooks de instrumentación,
no una comparación completa de bitmap. Una ejecución Rebar3 paralela inicial
tras los cambios falló en 20 casos EUnit de VM nueva con `undef` mientras
varios comandos compilaban en el mismo árbol; Dialyzer informó un aviso de
spec de excepción explícita. Tras ejecutar secuencialmente y añadir una spec
`no_return()`, los resultados fueron:

| Comando | Resultado |
| --- | --- |
| `ERL_FLAGS='+S 4:4' rebar3 compile` | PASS |
| `ERL_FLAGS='+S 4:4' rebar3 eunit` | PASS, 238 pruebas |
| `ERL_FLAGS='+S 4:4' rebar3 ct` | PASS, 3 pruebas |
| `ERL_FLAGS='+S 4:4' rebar3 xref` | PASS |
| `ERL_FLAGS='+S 4:4' rebar3 dialyzer` | PASS |

Las pruebas de contrato cubren observaciones vacías y repetidas, ranuras
0/63/64/última, desbordamiento, mismo ID local en dos módulos,
compilaciones/instantáneas incompatibles, uno/varios/ningún bit nuevo, A→B→A,
aislamiento global, realimentación de éxito/caída/tiempo límite, reintento CAS
determinista con lectura obsoleta, escritores compartidos y contextos tardíos.
Las pruebas de descendientes controlados y tiempo límite usan mensajes/barreras,
no solo esperas. Las campañas ETS→bitmap→ETS con semillas comparan corpus y
decisiones exactas de cobertura; las pruebas del executor de bajo nivel
comparan historias de eventos iguales. No prueban aislamiento de `spawn`
arbitrarios ni procesos remotos que el guardian de EFZ existente no posee.

## Benchmark

Comando: `ERL_FLAGS='+S 4:4' escript bench/bitmap_bench.escript _build/bitmap-benchmark`.
Tiempo, reducciones y datos de GC menor por muestra:
[bitmap-2026-10-02-samples.txt](../../performance/bitmap-2026-10-02-samples.txt).
El driver calienta dos veces, toma 10 muestras alternas emparejadas por etapa
y guarda un término binario en `_build/bitmap-benchmark/bitmap-benchmark.term`.
Entorno: OTP 27.0, ERTS 15.0, Rebar3 3.25.0, Linux x86_64, Intel i7-1260P,
`+S 4:4`; bitmap de 65.536 bits, 1.024 sondas sintéticas de manifiesto.
SHA-256 del script `975240e42d32a96228d7c177f33053492904c2c9a3aaca1a71d766168e95266b`;
SHA-256 del módulo bitmap `e1e5d44bc248c031b8724bb99c1d8bd34109cb1a3a048989e8e2b31398b1fa99`;
SHA-256 del fixture parser `c834f09eb2bbeabf54c2948ad849ab0f9294e2e455f35ead54d75f589be35747`.

| Etapa (mediana de microsegundos) | ETS | Bitmap |
| --- | ---: | ---: |
| 5.000 aciertos repetidos | 825 | 1,401 |
| 64 aciertos dispersos | 18 | 23 |
| 1.024 aciertos distintos | 650 | 775 |
| Instantánea de 64 aciertos | 15 | 37 |
| Instantánea de 1.024 aciertos | 284 | 41 |
| Decodificar 1.024 IDs | 324 | 85 |
| Borrado completo en reposo | 1* | 18 |
| Comparar 256 bits/IDs | 84 | 29 |
| Combinar 256 bits/IDs | 58 | 28 |
| Diez ciclos completos dispersos | 124 | 6,826 |
| Cinco ciclos completos densos | 23,418 | 11,310 |
| 1/2/4/8 escritores en una palabra | 3,925 / 7,758 / 16,061 / 28,523 | 4,499 / 7,825 / 16,324 / 29,044 |
| Tiempo de pared de campaña parser de 50 ejecuciones | 116,580 | 129,445 |

`*` La comparación ETS crea una tabla nueva, no la borra; 0–1 µs queda por debajo
de una resolución temporal útil. La carga del parser usa `efz_example_target`,
mutador aleatorio con semilla, 50 ejecuciones fijas, igual tamaño de corpus 4
y cobertura informada 5 en cada muestra. La razón exec/s bitmap/ETS desde los
tiempos medianos es aproximadamente **0.90**; la mediana de 10 razones emparejadas
es **0.887**, con intervalo bootstrap percentil del 95% **[0.825, 0.985]**
(10.000 remuestreos, semilla `20261002`). El p95 de tiempo del parser (rango más
próximo de 10 muestras) es **145,333 µs ETS** y **144,728 µs bitmap**.
El ciclo disperso completo es considerablemente peor; comparación/instantánea
bitmap densas son mejores. No se desprende una aceleración general.
`atomics:info(memory)` informa 8.232 bytes para palabras y 48 para la bandera;
el mapeo ETS informa 20.084 palabras de VM y el tamaño externo de la tupla
inversa es 58.633 bytes. La tabla de ejecución ETS con 1.024 aciertos informa
22.071 palabras de VM. Son tamaños parciales por componente, no una comparación
del RSS total de campaña. El benchmark no aísla ruido externo del scheduler o
temperatura, y no se ejecutó un segundo harness de producción. Por ello, el
criterio de rendimiento opcional del plan falla en este parser medido y el
criterio para cambiar el predeterminado **NO SE CUMPLE**. Bitmap sigue siendo
experimental opcional; no se añadieron optimizaciones de reset ni ruta crítica
tras las mediciones.

## Selección, reversión y trabajo pendiente

En una configuración API, use
`#{coverage => automatic, coverage_feedback => presence, coverage_backend => bitmap, coverage_bitmap_bits => 65536, ...}`;
pase los artefactos instrumentados habituales. Para revertir, configure
`coverage_backend => ets` o quite esa clave. `ets_member` y ETS `hit_count`
siguen disponibles. La CLI no expone la selección de backend de campaña;
no se requieren cambios de API del harness. Recompilar/recargar exige campaña
nueva y manifiestos revalidados. Los bytes de entrada del corpus pueden
recalibrarse; los bits guardados requieren la huella exacta y no se importan
entre compilaciones.

Pendiente: completar sin interrupción el benchmark histórico P0; repetir el
rendimiento con harnesses de producción representativos, intervalos de
confianza emparejados, p95 y memoria/RSS completos; decidir si el coste de mapas
dispersos justifica otra disposición. El predeterminado de producción sigue
siendo ETS. Cobertura nativa OTP, aristas, buckets, NIF y parches OTP quedan
fuera de esta implementación.
