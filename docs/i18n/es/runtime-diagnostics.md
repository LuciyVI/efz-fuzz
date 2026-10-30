# Diagnóstico automático en ejecución (P0)

[English](../../runtime-diagnostics.md) · [Русский](../ru/runtime-diagnostics.md) · **Español** · [简体中文](../zh-CN/runtime-diagnostics.md) · [Todos los idiomas](../README.md)

P0 se activa mediante configuración EFZ. El existente
`Target:run(Input) when is_binary(Input)` y el target instrumentado no requieren cambios.
Por defecto `enabled=false`. `run/3` conserva la API tuple previa;
`run/4` recibe además `runtime_observations` schema v1. El worker de campaña
organiza repeticiones; un `run/4` independiente ejecuta un input.

El modelo admitido sigue siendo **harness binario síncrono con descendientes controlados**.
Monitorizar no convierte en compatibles `spawn` arbitrario, aplicaciones OTP de fondo, mensajes
externos, cambios compartidos ni E/S. Siguen vigentes las reglas
[guardian/aislamiento](execution-isolation.md). Aquí no hay backend VM desechable
de producción.

## Configuración

Valores predeterminados completos (solo hay que proporcionar los modificados):

```erlang
runtime_oracles => #{
  enabled => false,
  stability => #{enabled => true, seed_runs => 3, interesting_runs => 3,
    suspicious_runs => 3, failure_runs => 3, compare_return => false,
    max_extra_executions => 1000},
  resources => #{enabled => true, sample_interval_ms => 20, max_samples => 64,
    max_sampled_processes => 128, ets_interval_ms => 100, max_ets_tables => 256,
    memory_bytes => 67108864, mailbox_messages => 1000,
    ets_memory_bytes => 16777216, residual_memory_bytes => 67108864,
    quiescence_ms => 1, memory_observation_timeout_ms => 50},
  hangs => #{enabled => true, max_stack_frames => 8,
    busy_reductions => 1000, max_sample_age_ms => 100},
  storage => #{max_groups => 128, max_representatives => 3,
    max_metadata_bytes => 1048576, max_total_metadata_bytes => 16777216}}
```

`efz_runtime_config:prepare/1` es el validador común de API, executor, CLI
y replay. Rechaza todos los campos desconocidos/tipos inválidos, incluso en secciones
desactivadas.

| Campo | Rango / unidad |
|---|---|
| `*_runs` | 1..16, **incluida la ejecución inicial** |
| `max_extra_executions` | 0..1 000 000 por campaña, incluida verificación de seeds |
| `sample_interval_ms` | 1..10 000 ms; intervalo tras finalizar el sondeo anterior |
| `max_samples` | 2..256, muestras más recientes, no primeras |
| `max_sampled_processes` | 1..256; producto con `max_samples` ≤32768 |
| `ets_interval_ms` | 10..60 000 ms; primer escaneo ETS solo tras pasar el intervalo |
| `max_ets_tables` | 1..4096 IDs de tablas VM comprobados por escaneo |
| Umbrales de recursos | 1..2^40; memoria proceso/ETS en bytes, buzón en mensajes |
| `residual_memory_bytes` | 1..2^40 bytes, umbral de delta de memoria binaria global VM tras limpiar |
| `quiescence_ms` | 0..100 ms, espera fija tras guardian DOWN |
| `memory_observation_timeout_ms` | 1..1000 ms, mayor que quiescencia; deadline total por medida, incluida espera |
| `max_stack_frames` | 0..32, solo MFA, sin argumentos/locales |
| `busy_reductions` | 1..10^9 en último intervalo, no uso CPU |
| `max_sample_age_ms` | 1..60 000, al menos intervalo de muestreo con hangs activos |
| `max_groups` / `max_representatives` | 1..1024 / 1..16 |
| `max_metadata_bytes` | 4096..4 MiB por payload de hallazgo |
| `max_total_metadata_bytes` | 4096..64 MiB, al menos cuota individual |

La sección hangs puede recoger muestras de procesos con `resources.enabled=false`.
Se desactivan entonces hallazgos por umbrales de recursos. Si ambas secciones están
desactivadas no hay muestras; la evidencia de lifecycle sigue disponible.

CLI:

```sh
escript scripts/fuzz.escript \
  --target my_harness --code-path ./harness-ebin --artifacts ./instrumented \
  --seeds ./corpus --out ./findings --max-iterations 1000 --timeout 1000 \
  --runtime-diagnostics --runtime-runs 3 --verification-budget 1000 \
  --sample-interval 20
```

`--runtime-runs` fija los cuatro recuentos de repeticiones. Los demás flags requieren
`--runtime-diagnostics`. El core valida límites numéricos; la CLI no
crea atoms desde texto de nombres: resuelve el target solo desde artefactos
seleccionados o un BEAM local en code path. La CLI sigue sin ejecutar
expresiones Erlang de argumentos.

## Calibración y verificación

Se repiten seeds, descubrimientos correctos nuevos de cobertura/count, fallos del target e inputs
runtime sospechosos. `descendant_activity` por sí solo no provoca
comprobaciones extra. Cada repetición es un **executor/guardian/root estándar nuevo**
con limpieza completa. No hay verificación recursiva. Las repeticiones no
invocan mutator, selección de corpus, staged planner, feedback ni retención.
El resultado inicial pasa por feedback existente y sigue siendo la única
fuente de retención del candidato.

Con `M` mutation executions y `S` seed executions, el total
es como máximo `M + S + max_extra_executions`. Un límite más estricto de
runs adicionales es `min(budget, sum(requested_runs_for_selected_input - 1))`.
`max_iterations` no incluye verificación. Timeout y limpieza se aplican por separado
a cada run; limita ejecuciones, no wall time de campaña.

Un fallo de infraestructura detiene inmediatamente repeticiones y campaña. La
causa original permanece en failure context, incluidos dirty-runner y fallo
guardian. Un crash, exit o timeout que aparece primero en una repetición se guarda
mediante crash storage normal con `metadata.origin=verification` y una occurrence
nueva. Cada ejecución se cuenta una vez. Una categoría runtime no
incrementa contadores crash.

La firma de outcome compara `ok`, clase de excepción y categoría acotada de razón,
categoría exit o timeout. Retornos correctos arbitrarios **no se comparan**.
El comparador opcional acepta atoms, enteros signed 64-bit, binaries,
listas, tuples/maps con presupuestos independientes de 1024 nodos, 1024 bytes binarios,
1024 elementos y profundidad 64. Recorre maps con iterador sin orden y
sin ordenar/copiar claves; comprueba byte_size antes de leer el contenido binary.
Solo un term completamente validado se serializa como ETF
determinista. PID, refs, ports, funciones, floats y términos grandes/profundos reciben
`not_comparable`. No deduce la semántica de timestamps enteros: al activar
compare_return, tales valores pueden variar.

Métricas propias de EFZ, **no equivalentes a estabilidad AFL++**:

- Repetibilidad outcome = `100 * max_frequency(normalized_outcome) / completed`.
- Repetibilidad cobertura = `100 * max_frequency({builds, exact_probe_set}) / valid`.
  Para serie utilizable completa, `valid=completed`. Snapshot inválido/no iniciado
  se excluye, no se sustituye por conjunto vacío.
- Sondas estables = intersección de conjuntos válidos. Variables = unión − intersección.
- Ratio de sondas estables = `100 * |intersection| / |union|`.
- Varios conjuntos vacíos válidos: ambas métricas son 100%, `valid_empty_coverage=true`.
- Menos de dos runs utilizables: `insufficient_samples`, aunque el único sea correcto.

`requested` incluye run inicial; `attempted=completed+failed`; `completed`
son runs sin fallo de infraestructura; `valid` excluye además cobertura no
iniciada; `failed` son fallos infraestructura; `skipped=requested-attempted`.
Cada fila incluye duración, identidad coverage/build, estado cleanup y resumen
runtime. La verificación tiene contadores requested/executions/completed/valid/failed/skipped
separados. Errores de integridad nunca pasan a `unstable_coverage`.

## Observaciones y alcance

| Categoría | Qué se mide / deduce | Qué no demuestra |
|---|---|---|
| `unstable_outcome` | Outcomes normalizados distintos en la serie | Vulnerabilidad de seguridad |
| `unstable_coverage` | Diferencia de conjunto/build exacto válido | Bug del target o causa de inestabilidad |
| `unstable_return` | Valores correctos comparables distintos, solo opt-in | Defecto semántico |
| `memory_pressure` | Suma observada de memoria de procesos ≥ umbral bytes | Fuga; memoria VM/binary-resource total |
| `memory_growth_suspected` | Crecimiento entre primera/última muestra retenida ≥ umbral | Crecimiento residual entre inputs / fuga |
| `vm_memory_growth_suspected` | Memoria binaria global VM tras cleanup/quiescencia menos baseline ≥ umbral residual | Atribución al target o fuga confirmada |
| `mailbox_pressure` | Suma observada message_queue_len ≥ umbral | Mensajes perdidos |
| `ets_growth_suspected` | Pico observado de memoria ETS propia ≥ umbral | Fuga de tabla tras limpiar |
| `descendant_activity` | Recuento admission guardian y pico observado vivo | Fuga de procesos |
| `child_abnormal_exit` | DOWN hijo anormal recibido durante running | Defecto incondicional o cambio del outcome raíz |
| `timeout_busy` | Delta considerable de reductions para PID propios coincidentes | Utilización CPU, livelock o falta de progreso |
| `timeout_waiting` | Muestras completas recientes: waiting y delta pequeño | Deadlock |
| `timeout_unknown` | Datos insuficientes, antiguos, incompletos o ambiguos | Causa de timeout |

Todos los umbrales son diagnósticos: no cambian límites heap ni introducen nuevas
causas para matar procesos. `thresholds` guarda baseline, observado,
umbral, interpretación y `defect=unproven`. `reproductions` indica el número
de runs con esa categoría. No se oculta el primer fallo como warmup. No hay
GC forzado de otros procesos ni rollback persistent_term/env/shared ETS.

El sampler recibe solo PID admitidos por guardian mediante una tabla
separada acotada. `processes()` no determina propiedad. Se excluyen guardian/coordinator,
sampler y ETS coverage/corpus/reporting. Se observan memoria, longitud de buzón,
reductions, status, current_function y stack acotado durante
la ejecución. No se leen contenidos de buzón/ETS/diccionario. Los ID de procesos en
el resumen persistido se reemplazan por placeholders portátiles;
`process_id`/`owner_id` son ordinales de admisión.

El baseline se captura **antes de admisión**: procesos/ETS del target son
cero; contadores VM tienen `scope=vm_global`. No es snapshot de memoria de
un target ya activo.

Una ruta posterior separada mide `erlang:memory(binary)` antes de ejecutar
y tras limpieza confirmada **y guardian DOWN normal**, con quiescencia acotada.
Las medidas usan helpers monitorizados de vida breve con deadline propio; no
corren dentro del guardian ni retrasan kill/cleanup. Fallar una medida
produce `incomplete`, no cero. Cleanup fallido conserva infraestructura
y no continúa a observar residuales. P0 off y resources off
no llaman esta ruta.

`post_execution_memory` contiene scope=vm_global, metric=binary_memory, units=bytes,
baseline_memory, sampled peak_memory (o not_sampled), post_execution_memory,
residual_delta, threshold, completeness, cleanup_status, quiescence y deadline.
`owned_memory` conserva aparte el pico propio; después de destruir
los dueños, post memory/residual son not_applicable en vez de inventar
medidas exactas. No se usan GC ajeno, escrituras compartidas ni cambios de
propiedad.

La atribución se limita explícitamente: el delta VM incluye retornos retenidos por EFZ
y otra actividad VM. Retornar normalmente un binary grande con referencias
es una fixture admitida de asignación residual VM tras limpiar raíz. No
es fuga del target. La verificación guarda M/N real; replay puede producir otro
M/N por liberación de retornos anteriores retenidos por EFZ/actividad VM que compensan
nuevo crecimiento. La ausencia de hallazgo residual en una asignación temporal se
comprueba aparte del pico. Tales hallazgos también tienen scope=vm_global en
artefacto/firma; schema-v1 antiguos siguen legibles y los campos policy
faltantes reciben defaults. Snapshots durante ejecución miden picos
observados; muestras recientes se guardan aparte de evidencia lifecycle tras cleanup.
Sin ningún PID vivo sondeado, resulta `not_sampled`, no
consumo cero.

ETS `memory` en OTP 27 se mide en palabras y se multiplica por
`erlang:system_info(wordsize)`:
[documentación oficial ETS info](https://www.erlang.org/docs/27/apps/stdlib/ets.html#info/2).
El escaneo ETS corre en sampler con frecuencia y cap independientes. Enumera
IDs de tablas VM mediante `ets:all()`, pero comprueba solo los primeros
`max_ets_tables`, filtrando por dueño. Muestra tablas VM conocidas / escaneadas /
propias observadas, y `partial=true` si el recorrido es incompleto o desaparece
un recurso. Se desconoce el total propio con escaneo truncado.
No afirma que suma parcial equivalga al consumo del target. Las comprobaciones
de desaparición solicitan solo `ets:info(Tab, owner)`, sin construir lista completa
de metadatos. `ets:all()` sigue siendo O(número de tablas VM); el cap
limita comprobaciones posteriores, no esa enumeración. Los snapshots compartidos previos
del guardian (`ets:all()` antes/después de caso) siguen siendo parte del
contrato cleanup; el sampler nuevo no añade escaneo a cada iteración rápida.

El sampler conserva un ring de las últimas `max_samples`; el pico se preserva
independientemente. Monitoriza guardian, y guardian monitoriza
sampler. Cleanup destruye primero procesos target y luego sampler. El
guardian no solicita un último `process_info` ni espera snapshot «ideal»
antes de matar procesos. Sampler DOWN forma parte del lifecycle cleanup acotado.
Su muerte independiente se marca failed/partial sin sustituir
outcome. Perder guardian conserva política dirty-runner.

Child DOWN durante running registra categoría de causa y fase; el iniciador
suele desconocerse: monitor no prueba que el padre detuviese al hijo.
Cleanup marca kill_requested; DOWN recibido en cleaning tiene
classification=unknown por carrera con muerte natural. Las muertes de cleanup
no crean child_abnormal_exit. `after_cleanup` informa terminación de dueños confirmada
y supervivientes conocidos; ETS escapado/estado compartido aún produce el fallo de
infraestructura existente, no hallazgo de recursos.

Timeout conserva outcome/deadline original. Clasifica con las dos últimas
muestras, empareja PID y registra edad, intervalo, recuentos de procesos
matched/observed, delta reductions, estados, buzón y stacks acotados. Actividad
parcial puede demostrar busy observado; waiting requiere muestras completas. No se
reconstruye información de todo proceso terminado entre muestras.

## Almacenamiento, informe y replay

Storage está junto a `crash_dir`: `dirname(crash_dir)/runtime-findings/`;
para CLI es `OUT/runtime-findings/`. Es independiente de crash groups.

```text
runtime-findings/
  index                       índice EFZO v1 con suma de comprobación
  SIGNATURE_HASH-INPUT_HASH/
    artifact.input            bytes raw exactos
    artifact.term             ETF acotado schema v1
    manifest                  hashes y tamaños de ambos archivos
```

El registro contiene input SHA-256, category/scope/origin, identidad portable harness/build,
outcome original normalizado, policy/thresholds, evidencia acotada con todas las
comprobaciones y la **receta original exacta de mutación**, si existe. Siempre se preserva raw input
para un representante elegido, sin depender de disponibilidad de receta.

Signature = SHA-256 de version/category/scope/harness/builds. PID, refs, timestamps
y deltas concretos de memoria no participan. Agrupar así puede unir causas
distintas. `max_representatives` limita inputs distintos por grupo; `max_groups` limita
grupos del store; suppressions/drops se cuentan aparte. La cuota de metadatos
incluye payloads, manifests e índice; raw bytes están además limitados por
`max_groups * max_representatives * max_input_bytes`. Payload demasiado grande
produce representative drop, no serialización/escritura ilimitada.
Existe límite fijo de 128 report checks y cuota bytes; `checks_dropped`
registra truncación. El store conserva counters/caps entre campañas.

Un grupo se publica atómicamente con fsync/manifest, seguido de actualización atómica
del índice. Intervalo interrumpido, entrada comprometida corrupta, writer/index obsoleto o
`.writer-lock` restante son fallo explícito de storage que detiene campaña.
No hay borrado/«reparación» automática; use directorio nuevo tras
investigar. El lock de escritor único no permite campañas diferentes
concurrentes con índices en memoria obsoletos.

Fragmento de informe (schema, no promesa de medidas concretas):

```erlang
#{runtime_diagnostics => #{
    verification_executions => 2,
    checks => [#{requested => 3, completed => 3, valid => 3, failed => 0,
                 skipped => 0, origin => calibration,
                 outcome_repeatability => 100.0,
                 reproductions => #{timeout_waiting => 3}}],
    findings => #{groups => #{}, suppressed => 0, dropped => 0}},
  stats => #{executions => 0, calibrations => 1, verification_executions => 2}}.
```

Compruebe un directorio representante seleccionado **con target local explícito**:

```sh
escript scripts/replay.escript \
  --runtime-finding ./findings/runtime-findings/SIGNATURE_HASH-INPUT_HASH \
  --target my_harness --code-path ./harness-ebin --artifacts ./instrumented --runs 3
```

API: `efz_replay:runtime(Directory, LocalTarget, Artifacts, #{runs=>3})`.
Policy/timeout/input limit proceden del hallazgo; `runs` es 1..16 y por defecto
usa interesting_runs guardado. Target/artefactos solo vienen del caller.
Se comprueban SHA-256 raw, manifest, build y harness antes de ejecutar. Safe ETF
decoding no crea atoms del target. `observed` da exit 0;
`not_observed` o `inconclusive`, exit 3; incompatibilidad/invocación inválida,
exit 2; infraestructura, exit 1. Siguen admitidos crash `.replay`, recipes
y raw-input CLI anteriores.

Para categorías unstable, un run da inconclusive; se informa recuento de muestras,
repeatability y variable fraction. Incluso `not_observed` describe solo
una muestra finita. Para recursos, faltar muestras completas da
inconclusive, no prueba ausencia de problema. Repite con el mismo executor
y se detiene en fallo de infraestructura. Replay no escribe nuevos crash groups de
campaña: un fallo en repetición se incluye en el resumen devuelto.
La verificación de campaña sí lo guarda en disco.

## Coste y limitaciones

`stats` separa mutation executions, calibrations y verification. Hay
medidas independientes de tiempo de verificación, post-execution
`runtime_diagnostic_us` (wall worker incluidas verificación y storage,
excluido executor inicial), trabajo sampler, ejecuciones sampled/missed
y máximo de bytes del buffer ETS diagnóstico medido al terminar el run.
La última métrica **no incluye heap sampler/guardian/report**; sample slots,
registros hijos, informe y metadatos disco tienen límites propios. Copiar
snapshots/comparar worker/storage también cuesta; `sampling_us` no es el coste P0
total. Son diagnósticos BEAM cooperativos, no garantía de scheduling en
tiempo real.

P0 no demuestra memory safety, fugas arbitrarias, race conditions,
deadlock/livelock como causa, fallos nativos, corrección semántica ni efectos
externos. No hay detector de fuga FD/socket, NIF/ASan/UBSan/LSan, perturbación del scheduler,
fuzzing stateful/secuencias, distribución, power scheduling ni
enmascarado de sondas inestables. No se mide todo off-heap binary.
El muestreo omite picos rápidos e hijos/tablas de terminación breve. Crecimiento dependiente
de estado puede requerir historial o VM nueva; no se garantiza que un solo input raw
lo reproduzca.

Comandos reales, resultados y limitaciones: [informe de validación](runtime-diagnostics-validation.md).
