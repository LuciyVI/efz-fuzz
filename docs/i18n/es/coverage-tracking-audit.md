# Seguimiento de cobertura EFZ: auditoría y comparación con AFL++

[English](../../coverage-tracking-audit.md) · [Русский](../ru/coverage-tracking-audit.md) · **Español** · [简体中文](../zh-CN/coverage-tracking-audit.md) · [Todos los idiomas](../README.md)

Fecha: 15 de septiembre de 2026. Snapshot de producción revisado:
[`205e18ba172d74bd6c652a68abfc73e02e4a1f86`](https://github.com/LuciyVI/efz-fuzz/commit/205e18ba172d74bd6c652a68abfc73e02e4a1f86).
Entorno: OTP 27 / ERTS 15.0, Linux x86_64, `+S 4:4`.
No se cambió la implementación productiva. Los targets diagnósticos y runner
nuevos están en [coverage-audit-2026-09-15](../../coverage-audit-2026-09-15).

El documento describe ese snapshot y semántica presence predeterminada.
El prototipo posterior opt-in de contadores y medidas separadas está en el
[experimento hit-count](hit-count-experiment.md); los resultados históricos no
describen el modo nuevo.

## 1. Conclusión ejecutiva

**RESULTADO B — semántica feedback similar a AFL++ implementada, representación distinta.**

Respuestas a dos preguntas distintas:

* **¿Existe feedback de cobertura? SÍ.** Hooks automáticos registran cobertura de
  una ejecución; worker la compara con acumulada y añade
  descubrimientos correctos al corpus real disponible al scheduler posterior.
* **¿Existe bitmap/hit-count map estilo AFL++? NO.** No hay trace bitmap
  indexado por byte, hit counter, bucket, `virgin_bits`, edge previo ni hashing de contexto.

El nombre correcto es **execution coverage set / exact probe set**.
Se admite «mapa sparse de presencia de sondas» si la semántica de conjunto es explícita.
Llamarlo bitmap o edge-hit-count map es incorrecto.

La representación no equivale a AFL++ en sensibilidad: **detecta sonda
nueva; no multiplicidad nueva de sonda conocida ni combinaciones nuevas de
sondas conocidas**. IDs indican puntos fuente clause/outcome, no aristas CFG.

Evidencia: [hook](../../../src/efz_cov_rt.erl#L43), [snapshot](../../../src/efz_cov.erl#L31),
[novedad](../../../src/efz_feedback.erl#L16), [retención](../../../src/efz_worker.erl#L122),
[scheduler](../../../src/efz_mutation_plan.erl#L54), experimentos independientes de sección 13
y [test real de reutilización de padre](../../../test/efz_feedback_loop_tests.erl).

## 2. Modelo de referencia AFL++

Referencia fijada a AFL++ `stable` commit
[`dbaf11913c1b2702dee5b4d3dcfffd52f1defe50`](https://github.com/AFLplusplus/AFLplusplus/commit/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50),
fecha 2026-09-02. AFL++ no se compiló ni ejecutó: comparación con
fuentes oficiales. Modela modo normal guiado por cobertura; canales extra
value-profile/CmpLog/path/sanitizer y crash-only no lo sustituyen.

```text
ejecución del target
  → instrumentación compiler/runtime
  → edge/guard mapeado a slot numérico
  → contador byte de hits en trace_bits compartido
  → clasificación de counts
  → comparar virgin bits y borrar bits feature recién observados
  → save_if_interesting / add_to_queue
  → vaciar trace actual antes del siguiente run
```

| Concepto | Significado en referencia |
|---|---|
| Edge coverage | Transiciones de flujo de control; colocación depende de compiler/backend. No solo conjunto de líneas fuente. |
| Bitmap slot | Posición numérica del trace buffer. No tiene por qué corresponder a única arista. |
| Hit counter | Normalmente byte actualizado en cada hit; no recuento exacto ilimitado. |
| Count bucket | Clase de valor counter. Bucket nuevo de slot conocido puede dar novedad. |
| Traza por ejecución | `fsrv.trace_bits`, observaciones actuales en memoria compartida. |
| Virgin map | Bits de bucket features no vistas; acumulación lógica en forma inversa. |
| Novedad | Intersección current clasificado con virgin bits. Distingue slot nuevo de bucket nuevo del slot anterior. |
| Reset | Vaciar traza actual entre runs conservando virgin state. |
| Colisiones | En instrumentación hash, edges pueden compartir slot y mezclar counts. LTO/PCGUARD pueden usar IDs sin solapamiento. |
| Contexto | Edge normal no incluye cadena de llamadas. Modos extra consideran caller/context; ajuste separado. |

AFL histórico indexa `cur_location XOR prev_location`, actualizando
`prev_location` con punto actual. Esto **no describe universalmente
todos los backends AFL++ modernos**. PCGUARD actualiza
`__afl_area_ptr[*guard]`; LTO documenta IDs únicos y requisitos de rangos para
varias bibliotecas instrumentadas. [Modelo histórico](https://aflplus.plus/docs/technical_details/),
[runtime PCGUARD](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/instrumentation/afl-compiler-rt.o.c#L2692),
[LTO](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/instrumentation/README.lto.md).

**Detalle de versión:** `count_class_lookup8` activo de esta revisión tiene
estas clases; tabla tradicional con clase separada para 3 permanece
comentada como `OLD`:

| Count byte raw | Bit clasificado |
|---|---:|
| 0 | 0 |
| 1 | 1 |
| 2–3 | 2 |
| 4–7 | 4 |
| 8–15 | 8 |
| 16–31 | 16 |
| 32–63 | 32 |
| 64–127 | 64 |
| 128–255 | 128 |

`classify_counts` transforma counts; `discover_word` comprueba
`current & virgin` y aplica `virgin &= ~current`. `has_new_bits` retorna 0
sin novedad, 1 por count-class nueva de slot conocido y 2 por slot nuevo.
No retiene cada vector completo único de traza.
[Tabla y has_new_bits](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/src/afl-fuzz-bitmap.c#L46),
[classify_counts/discover_word](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/include/coverage-64.h#L77).

Counters byte pueden desbordarse. PCGUARD mostrado usa NeverZero:
tras 255 viene 1. **No es saturación**. Thread-safe instrumentation es modo
separado; incremento normal no garantiza exactitud
concurrente. Hilos/descendientes fork instrumentados pueden compartir buffer,
pero fronteras de input requieren lifecycle coordinado.
[Contadores y thread safety](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/instrumentation/README.llvm.md#L200),
[mapping runtime](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/instrumentation/afl-compiler-rt.o.c).

El tamaño trace-buffer es fijo durante uso de mapa concreto, pero capacidad
se elige/negocia con target. No todo mapa AFL++ es
siempre 64 KiB. Forkserver normal pone `trace_bits` a cero antes de ejecutar.
[Redimensión y run/reset](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/src/afl-forkserver.c#L2410).

`save_if_interesting` añade candidatos a cola. Dedup crash/hang usa
`virgin_crash`/`virgin_tmout` separados tras simplificar traza quitando
counts; difiere de novedad de cola correcta.
[Rutas queue/crash/hang](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/src/afl-fuzz-bitmap.c).

## 3. Arquitectura real de cobertura EFZ

Ruta staged/prepared predeterminada real:

```text
efz_cli:launch/1 → efz:start/1
  → supervisor:start_child/2 (efz_sup) → efz_fuzzer:start_link/1
  → efz_config:prepare/1
  → efz_instrument:preflight/1 → efz_cov_integrity:pin/2
  → efz_fuzzer:init/1 → efz_corpus:start_link/4
  → efz_worker_sup:start_link/1 → efz_worker:start_link/1
  → efz_worker:init/1
       efz_cov_manifest:prepare/2       % allowlist de campaña, no cobertura actual
       efz_feedback:new/1               % conjunto acumulado vacío de sondas correctas
  → efz_worker:staged_iteration/1
  → efz_corpus:mutation_entries/0
  → efz_mutation_plan:next/2
       → attempts/6 → efz_mutation:apply_operation/3
  ← {candidate, Binary, Provenance, NextPlan}
  → efz_recipe:make/4
  → efz_worker:execute/4 → execute_checked/4
  → efz_executor:run/4 → run_checked/4 → run_pinned/4
  → spawn_monitor guardian → efz_guardian:run/6 → start/6
       efz_cov:open/1; efz_cov_integrity:open/2
       coordinator = efz_executor:coordinate/1
       root = efz_guardian:admit/2
  → root: efz_cov:attach/1 → efz_executor:invoke/4
  → HarnessModule:run(Binary) → funciones instrumentadas seleccionadas
  → efz_cov_rt:hit({Module, BuildId, ProbeId})
       → publish/2 → insert/4 → ets:insert_new/2
  → cleanup guardian + DOWN de procesos + barreras trace
  → efz_guardian:finish/2
       → efz_executor:coverage/3 → efz_cov:snapshot/1
       → efz_cov_manifest:validate_prepared/3
       → efz_cov:close/1
  ← resultado; efz_executor espera guardian DOWN
  → efz_worker:execute_result/6 → efz_feedback:evaluate/3
  → efz_worker:retain/2 → efz_corpus:add/2
  → accepted/5; worker guarda siguiente estado feedback; self() ! iterate
  → siguiente efz_corpus:mutation_entries/0 incluye input retenido
```

Anclas fuente: [worker](../../../src/efz_worker.erl#L47), [planner](../../../src/efz_mutation_plan.erl#L54),
[executor](../../../src/efz_executor.erl#L11), [guardian](../../../src/efz_guardian.erl#L33).
Modo random usa `efz_corpus:select/0 → Mu:mutate/2`, seguido de la misma
ruta de ejecución, cobertura y feedback. `coverage_validation => per_execution`
llama `validate_observed/3` en lugar de membership preparado. No se creó
motor nuevo para el experimento.

Mensajes interproceso principales:

| Mensaje | Emisor → receptor | Significado |
|---|---|---|
| `{coordinate,Root,Context}` / `{coordinator_ready,Coordinator}` | guardian ↔ coordinator | Instalar monitor raíz antes del código |
| `{start_owned,Capability}` | guardian/helper → target | Abrir compuerta tras registrar propiedad |
| `{target_result,Ref,Root,Outcome}` | root → coordinator | Clasificación de return/exception |
| `{coordinator_done,Coordinator,Outcome}` | coordinator → guardian | Entrar en cleanup |
| `{efz_cov_observed,Ref,Identity}` | first insert hook → guardian | Evidencia independiente del primer hit |
| `{efz_cov_failure,Ref,Reason}` | integrity/hook → guardian | Error de observación sobrevive excepción capturada |
| `DOWN`, `trace_delivered` | runtime → guardian | Confirmación de terminación y procesamiento trace |
| `{Request,Guardian,Result}` | guardian → executor caller | Snapshot completo y estado lifecycle |
| `gen_server:call(...,{add,Binary,Meta},infinity)` | worker → corpus | Inserción confirmada |

Argumentos input son `binary()`. `Provenance`/`Recipe` contiene primary bytes/hash,
ID padre, operaciones y output hash. `Result` es map con `outcome`,
`coverage` (lista de identidades), `coverage_status`, `coverage_observation`,
`builds`, `cleanup`. El set global recibe la lista; input bytes
siguen en worker/corpus.

## 4. Estructuras de datos de cobertura

| Estado | Representación física | Dueño / vida útil |
|---|---|---|
| Hits por ejecución | ETS `set` público sin nombre, nombre interno `efz_execution_coverage` | Guardian; una ejecución hasta snapshot/close |
| Contexto target | Clave process dictionary `'$efz_execution_context'` → tuple contexto | Raíz/hijo controlado; hasta morir |
| Evidencia independiente | Estado guardian `observed_probes => sets:set()` | Misma ejecución; primer hit de cada identidad |
| Registro attachment/integrity | ETS protegido con nombre `efz_coverage_observers`, `{Pid,Context}`, `{identities,Pins}` | Guardian; una ejecución activa en VM |
| Identidades permitidas | ETS protegido `efz_coverage_plan` | Worker; campaña hasta release/muerte dueño |
| Cobertura global correcta | `S.feedback.global`, Erlang `sets:set()` | Worker; campaña |
| Diagnósticos campaña | `coverage_seen`, recuentos empty/broken/unstarted | Worker; campaña; **no** estado novelty |
| Marca dirty | `persistent_term` `{efz_guardian,dirty_runner}` | VM; **no** coverage map |
| Persistencia | Manifiestos fuente; metadata histórica corpus/crash/report | Filesystem; no trace buffer por ejecución |

Formato exacto de contexto y filas:

```erlang
{efz_context, 1, ExecutionRef, Table, GuardianPid}
{efz_context, 1, ExecutionRef, {ets_member, Table}, GuardianPid}

%% Objeto ETS completo: tuple de un elemento.
{{probe, {Module, BuildId, ProbeId}}}
%% Su clave ETS (keypos predeterminado = 1):
{probe, {Module, BuildId, ProbeId}}
```

Una fila significa presencia de una sonda exacta. No hay campo separado value/counter.
Sin espacio fijo de slots, bitmap binario, array byte compartido
ni backend coverage `counters`/`atomics`. `ProbeId` es número dentro de
clave tuple, no índice array. ETS resuelve colisiones hash internas
comparando claves; no combina identidades distintas en un bit.
[open/attach/snapshot](../../../src/efz_cov.erl), [insert](../../../src/efz_cov_rt.erl#L43).

En **OTP 27 probado**, `sets:new()` devuelve tuple versión-1 `{set,...}` con
segmentos hash, no native map. EFZ usa API `sets` sin depender de
layout privado. `map` en `S.feedback` no demuestra bitmap:
es mapa Erlang normal que contiene un set.

La tabla preparada contiene `{Identity}` y filas de servicio
`{'$efz_plan',{Mode,Builds}}`, `{'$efz_identities',PinsResult}`. Conoce todas las sondas
permitidas, incluidas no ejecutadas. Es **allowlist de validación**, no
cobertura acumulada. [make_plan/2](../../../src/efz_cov_manifest.erl#L60).

## 5. Identidad de sonda

Unidad: **sonda fuente clause/outcome**, metric manifest `clause_outcome_probe`.
`efz_instrument_pt:body/5` coloca hook al inicio del cuerpo tras seleccionar
cláusula. Tipos reales: `function_clause`, `case_clause`, `if_clause`,
`receive_clause`, `receive_after`, `try_body`, `try_of_clause`, `catch_clause`,
`try_after`, `fun_clause`, `named_fun_clause`. Guards/patterns no se
instrumentan aparte; operandos short-circuit no reciben automáticamente
sondas true/false individuales. No es cobertura completa de ramas ni instrumentación
de todos los basic blocks BEAM.
[body/probe](../../../src/efz_instrument_pt.erl#L106), [recorrido AST](../../../src/efz_instrument_pt.erl#L129).

Identidad: `{Module :: atom(), BuildId :: binary(32), ProbeId :: pos_integer()}`.
Transform empieza `next => 1`, asigna IDs en orden de recorrido AST
e incrementa `next` por punto. Hook contiene triple como
literal de compilación. Manifest mapea ID a module/function/arity, kind,
source_file, line/column y structural_location. Línea es metadata,
**no clave coverage**.

BuildId es SHA-256 de `{1, OTPRelease, CompilerModuleMd5, CanonicalForms,
IdentityOptions}`. Paths dentro de `source_root` se normalizan relativos a raíz.
Otro módulo tiene namespace separado; otro build también.
Validación rechaza IDs/structural paths duplicados.
[Cálculo build](../../../src/efz_instrument_pt.erl#L36), [validación](../../../src/efz_cov_manifest.erl#L4).

Estabilidad: ejecuciones del mismo build usan identidad igual; fuentes/opciones/toolchain
canónicos iguales producen IDs reproducibles en entorno probado.
Reordenar/añadir puntos AST puede desplazar ID numéricos; cambios en fuentes,
annotations/options/toolchain pueden modificar BuildId. No se garantizan IDs estables
entre ediciones arbitrarias/OTP. `determinism/1`, `build_options/0`
y fresh replay prueban fronteras concretas.

Límite de contrato: constante inicial `1` es versión schema;
contenido del propio transform no entra automáticamente en hash BuildId.
Cambiar semántica de instrumentación requiere subir versión explícita.
BEAM/attributes/harness pinning añade check independiente de código actual.
Colisiones SHA-256 son teóricamente posibles, pero no es compresión normal
de slots como bitmap hash.

**EFZ ProbeId no es índice edge/slot AFL++.** Identifica punto AST en
namespace módulo/build. No hay tuple `(previous,current)`, mapeo XOR
o contribución caller/call-stack. `ExecutionRef` controla vida útil,
no identidad de feature sensible al contexto.

## 6. Ciclo de vida por ejecución

1. `efz_executor:run_pinned/4` crea guardian independiente monitorizado.
2. Guardian valida módulos fijados, crea ETS nuevo por `efz_cov:open/1`
   y referencia nueva. Posee ETS, no root/coordinator.
3. `admit/2` registra raíz/hijo antes de abrir compuerta; `attach/1` coloca
   referencia de tabla compartida del caso en diccionario.
4. Hook comprueba contexto esperado contra registro externo y hace insert/member.
5. Tras outcome raíz, timeout o caller/coordinator DOWN, guardian termina
   raíz, descendientes y coordinator, espera monitores/barreras trace.
6. `finish/2` valida identidades, toma snapshot/allowlist validation, comprueba
   sondas independientes y attachment, cierra ETS/registro/trace.
7. Worker recibe resultado; caller espera también guardian DOWN.
   Feedback recibe lista independiente tras cerrar tabla por ejecución.
8. Caso siguiente crea tabla/referencia nueva; no hay memset/reset bitmap explícito.

[Guardian start/admit/loop](../../../src/efz_guardian.erl#L33),
[finish](../../../src/efz_guardian.erl#L163), [protocolo resultado executor](../../../src/efz_executor.erl#L33).

Crash raíz no destruye tabla: guardian es dueño.
Timeout conserva sondas previas a kill. Fallo coordinator genera
infraestructura; snapshot puede contener hits, pero no entran en
global. Muerte caller provoca cleanup aunque nadie
reciba resultado. Perder guardian no es limpieza confirmada:
executor marca dirty y prohíbe reuse; fallo tardío guardian
conserva causa primaria de infraestructura.

**Dentro del modelo, hits del input anterior no entran en siguiente.**
Contextos distintos, ausencia de ETS tras resultado y A→B→A lo confirman.
Contexto antiguo cerrado no se redirige a tabla nueva.
Sin embargo, cambios globales VM pueden alterar *conducta* del input siguiente:
es otra fuente de no determinismo, no mezcla coverage-map.
Persistent-term/env se diagnostican; escritura ETS preexistente,
servicios externos y procesos background arbitrarios no están totalmente aislados.
Runner cooperativo, no sandbox de seguridad. [Política](execution-isolation.md).

API manual/bajo nivel sola no aporta todas las garantías guardian.
`reset_local/0` no limpia bitmap global reutilizado: crea contexto o
rechaza si ya está attached. `snapshot/0` y `{manual,Id}` son
superficies compatibles; campañas automáticas usan `snapshot/1` y prohíben IDs
manuales en allowlist automática.

## 7. Cobertura global

Estado autoritativo:

```erlang
%% estado efz_worker
#{feedback => #{builds => Builds, global => GlobalSet}}

%% efz_feedback:evaluate/3, outcome válido correcto
New = lists:sort(sets:to_list(
    sets:subtract(sets:from_list(Observed), Global))),
NextGlobal = efz_cov:merge(Global, Observed).
%% efz_cov:merge/2 = sets:union(Global, sets:from_list(Observed))
```

Así `New = Current − Global`, `Global' = Global ∪ Current` **sí está
implementado**, con identidades exactas y solo outcome apto.
[evaluate/3](../../../src/efz_feedback.erl#L16).

| Ejecución | ¿Cambia global? | Decisión / retención |
|---|---|---|
| Mutación correcta, cobertura válida | Unión con actual | `new_coverage` con delta no vacío; si no `equivalent_coverage` |
| Calibración correcta | Unión | Siempre `seed_calibration`; seed ya está en corpus |
| `error` / `throw` / `exit` / kill externo raíz | No | `target_failure`, `new_probes => []`; crashes aparte |
| Timeout | No | `target_failure`; artifact/count timeout |
| Infraestructura / cobertura inválida / build mismatch | No | `{error,Reason}`, campaña se detiene |
| Éxito sin hits válido | Unión con vacío | No discovery; distinto de observación rota |

Retornar normalmente `{error,invalid_input}` sigue siendo ejecución correcta:
executor envuelve en `{ok,Value}`. Excepción y term retornado son diferentes.

`coverage_seen`/`coverage_diagnostics` incluyen observación de fallos;
no equivalen al set global correcto. Strict rechaza
campaña sin ninguna sonda observada; no es criterio de novedad nuevo.

Global pertenece a worker y no se restaura en restart. Durable corpus
restaura bytes/historial, después recalibra inputs y construye nueva
cobertura acumulada. Fallo filesystem al retener detiene campaña;
`accepted/5` no confirma estado feedback hasta retención correcta.

## 8. Análisis hit-count

`efz_cov_rt:insert/4` llama `ets:insert_new(Table,{{probe,Id}})`:
primer hit añade fila/notifica guardian; repetir devuelve
`false` sin cambiar fila. `ets_member` comprueba membership primero, pero
inserción final también es atómica `insert_new`. Hijos controlados concurrentes
pueden ver ausencia a la vez; solo una inserción es nueva.

Búsqueda en fuentes productivas:

```sh
rg -n 'counter|count_class|bucket|bitmap|update_counter|atomics|counters:|array:|prev_loc|edge' src
```

Resultados `counter` se refieren a **almacenamiento crash occurrences**, no hits.
No se encontró contador entero/saturado/8-bit, tabla lookup buckets ni feature
sensible a frecuencia en ruta productiva. `next` del transform cuenta
IDs asignados al compilar; stats cuenta executions/discoveries:
son contadores distintos.

| Llamadas a un x/0 | Filas EFZ | Snapshot | ¿Novedad count-only tras primer hit? |
|---:|---:|---|---|
| 1 | 1 | `{X}` | Primer X puede ser nuevo |
| 2 | 1 | `{X}` | No |
| 3 | 1 | `{X}` | No |
| 8 | 1 | `{X}` | No |
| 10 | 1 | `{X}` | No |
| 1000 | 1 | `{X}` | No |

Se comprobó con **hooks automáticos**, no manual `efz_cov:hit/1`. Target
lleva contador diagnóstico propio en process dictionary para
confirmar 1000 llamadas reales. No participa en cobertura
EFZ. No puede desbordarse contador coverage por ejecución porque no existe.

## 9. Semántica de novedad

Lo siguiente se refiere a mutación correcta con cobertura válida. En AFL++,
A/B/C son slots/features sin colisión; sin counts especificados,
se supone bucket sin cambios.

| Escenario | EFZ `new_probes` | Resultado EFZ | Referencia AFL++ solo cobertura |
|---|---|---|---|
| A: actual `{A,B}`, global `{}` | `{A,B}` | `new_coverage`, unión `{A,B}`, retener | Slots nuevos, clase 2 |
| B: actual `{A,B}`, global `{A,B}` | `{}` | `equivalent_coverage`, sin retención | 0 si buckets intactos |
| C: actual `{A,B,C}`, global `{A,B}` | `{C}` | `new_coverage`, retener, unión `{A,B,C}` | Slot C nuevo, clase 2 |
| D: A conocida corre 100 veces | `{}` | Count solo no interesa | Puede dar clase 1 si bucket no visto |
| E: combinación nueva de puntos conocidos | `{}` | No cobertura nueva | Combinar slot/bucket conocidos no es novedad; nuevos edges/counts pueden cambiar resultado |

Set pierde orden: `AB` y `BA` iguales si instrumentación da
mismos puntos. En AFL++, reordenar *basic blocks* puede crear **edges** nuevos;
no es reordenar features de edge conocidas. No se debe atribuir
unicidad total de firma de ejecución a AFL++ solo por conservar
hashes trace para calibration/scheduling.

## 10. Integración feedback del corpus

`efz_worker:execute_result/6 → efz_feedback:evaluate/3 → retain/2` llama
`efz_corpus:add(Input,Meta)` **solo** con `new_coverage`.
`efz_corpus:add_checked/3` compara bytes, guarda durable record
si store activo, añade `#{id,input,metadata,added_at}` a entries.
Siguiente `mutation_entries/0` devuelve también `#{id,input}` compacto de entrada nueva.
Planner lee corpus real actual, mantiene cursors por contenido y
reinicia observaciones idle anteriores al crecer. Donors también
proceden de él.
[Worker retain](../../../src/efz_worker.erl#L122), [corpus](../../../src/efz_corpus.erl#L36),
[scheduler creciente](../../../src/efz_mutation_plan.erl#L54).

No es pipeline solo telemetría. `efz_feedback_loop_tests:feedback_loop/0`
ejecuta campaña real con staged dictionary y solo tokens A/B/C:

```text
ID 1: <<>>
  → ID 2: <<"A">>,   parent 1
  → ID 3: <<"AB">>,  parent 2
  → ID 4: <<"ABC">>, parent 3
```

Test comprueba sondas nuevas reales, entrega por execution ref, primary
bytes/hash de receta y fresh-VM replay. Run: **30 mutation
executions, 31 entregas harness, 3 discoveries**. Sin mutator scripted.
El experimento extra de auditoría alimenta AB retenido al planner real
y comprueba `parent => 2, primary => <<"AB">>`.

Entrada nueva no tiene que ser la siguiente inmediata: planner termina
ronda snapshot actual. Es fairness, no ruptura del feedback loop.

## 11. Límites entre procesos

| Variante | Cobertura | Lifecycle/admission |
|---|---|---|
| Raíz llama instrumentada | Escribe ETS ejecución | Admitido |
| `efz_target:spawn/1` | Contexto automático antes de usuario; set exacto compartido | Admitido; guardian espera cleanup |
| `efz_target:spawn_link/1` | Igual | Admitido; enlace no define identidad |
| Hijo controlado anidado | Igual, mismo guardian | Dentro del límite admission |
| `erlang:spawn` normal | No hereda contexto automáticamente | Trace detecta spawn no controlado; infraestructura/dirty |
| Proceso background previo | Normalmente sin contexto, hook inactivo | Fuera del alcance |
| `efz_cov:attach/1` manual en hijo arbitrario | No concede propiedad lifecycle | No hace spawn normal compatible |

Así, **usuarios de API controlada no necesitan attach manual**. Pero
cobertura no se extiende a todo proceso Erlang. Los diccionarios
no se heredan por spawn; hook instrumentado nativo fuera de proceso
admitido queda inactivo sin contexto. [API target](../../../src/efz_target.erl),
[admisión](../../../src/efz_guardian.erl#L51), [detección no controlada](../../../src/efz_guardian.erl#L143).

Excepción de hijo sin enlace no determina outcome raíz: harness
debe esperar/reflejarlo. Sondas de hijo controlado
entran en snapshot antes de cleanup; outcome raíz decide si
snapshot entra en feedback correcto. ETS compartido no crea
features sensibles a caller ni PID.

## 12. Matriz EFZ frente a AFL++

`YES` indica propiedad concreta igual, no compatibilidad binaria.
`FUNCTIONALLY SIMILAR` indica mismo papel con otra implementación.

| Mecanismo | AFL++ | EFZ | Equivalencia |
|---|---|---|---|
| Instrumentación | Hooks compiler/runtime | Parse transform Erlang + runtime hook | FUNCTIONALLY SIMILAR |
| Granularidad | Normalmente edges CFG; depende modo | Cláusulas AST/outcomes seleccionados | PARTIAL |
| Cobertura por ejecución | Array byte compartido | ETS exact set público nuevo | FUNCTIONALLY SIMILAR |
| Bitmap tamaño fijo | Buffer slot numérico | Ausente | NO |
| Slot coverage | Índice numérico | Clave tuple ETS exacta | NO |
| Edge ID | Edge/guard según modo | Punto fuente, no edge previo/actual | NO |
| Hit counter | Incremento byte, overflow según modo | Ausente | NO |
| Count buckets | Clases de contador | Ausente | NO |
| Global/virgin | Bits feature no observados | IDs de sondas correctas observadas | FUNCTIONALLY SIMILAR |
| Novedad | Slot o bucket nuevo | Solo identidad nueva | PARTIAL |
| Reset entre runs | Vaciar/reiniciar trace | Destruir ETS, crear contexto/tabla | FUNCTIONALLY SIMILAR |
| Colisiones | Hash colisiona; LTO/PCGUARD pueden ser exactos | Sin alias slot; claves exactas | PARTIAL |
| Crash coverage | Trace + mapas separados crash/hang | Snapshot conservado, dedup firma crash normalizada | PARTIAL |
| Corpus feedback | Novedad → cola → mutaciones | Novedad → corpus → scheduler → mutaciones | YES |
| Build identity | Slots vinculados a binary/mapping; sin BuildId por byte | Module + BuildId en cada identidad, harness/BEAM fijado | NO |
| Cobertura multiproceso | Mapping compartido entre procesos/hilos participantes | Una ETS raíz + descendientes controlados | PARTIAL |

Usa fuentes sección 2 y rutas reales secciones
3–11. `NO` en Build identity no significa ausencia de target checks AFL++:
se refiere al namespace integrado en cada elemento.

## 13. Experimentos runtime

Reproducir desde raíz EFZ:

```sh
ERL_FLAGS='+S 4:4' rebar3 compile
escript docs/coverage-audit-2026-09-15/run.escript
ERL_FLAGS='+S 4:4' rebar3 eunit
ERL_FLAGS='+S 4:4' rebar3 ct
ERL_FLAGS='+S 4:4' rebar3 xref
ERL_FLAGS='+S 4:4' rebar3 dialyzer
```

[Sites](../../coverage-audit-2026-09-15/efz_cov_audit_sites.erl) se compilan con
`efz_instrument:compile/2` real. El
[harness](../../coverage-audit-2026-09-15/efz_cov_audit_harness.erl) usa compiler
normal. Excluye deliberadamente sondas dispatch/loop-control: si no,
LOOP1/LOOP10 podrían diferir por sonda nueva en otra cláusula, sugiriendo falsamente
sensibilidad a count.

El [runner](../../coverage-audit-2026-09-15/run.escript) usa executor,
validación prepared, feedback y corpus reales. Driver diagnóstico da inputs
para álgebra; **no afirma que mutator los generara**. La campaña
productiva de `efz_feedback_loop_tests` demuestra aparte mutación
real→ejecución→reutilización padre. No se añadieron mocks coverage/corpus ni mutator propio.

Mapping del target: A=probe 1, B=2, C=3, X=4; mismo par
module/build. Primeras entradas diagnósticas: inicial vacía ID 1 y
AB retenida ID 2.

| Input en orden | Sondas actuales | Nuevas | Razón | Global posterior | Tamaño corpus |
|---|---|---|---|---|---:|
| AB | A,B | A,B | new_coverage | A,B | 2 |
| AB repeat | A,B | — | equivalent_coverage | A,B | 2 |
| ABC | A,B,C | C | new_coverage | A,B,C | 3 |
| BA | A,B | — | equivalent_coverage | A,B,C | 3 |
| AC | A,C | — | equivalent_coverage | A,B,C | 3 |
| LOOP1 | X | X | new_coverage | A,B,C,X | 4 |
| LOOP2 | X | — | equivalent_coverage | A,B,C,X | 4 |
| LOOP3 | X | — | equivalent_coverage | A,B,C,X | 4 |
| LOOP8 | X | — | equivalent_coverage | A,B,C,X | 4 |
| LOOP10 | X | — | equivalent_coverage | A,B,C,X | 4 |
| LOOP1000 | X | — | equivalent_coverage | A,B,C,X | 4 |

Resultados idénticos con `ets` y `ets_member`. En cada LOOP, ETS raw
contenía **un objeto**, counter diagnóstico de x coincidía 1/2/3/8/10/1000,
y snapshot seguía `{X}`. ETS consumió 324 machine words por input
(2592 bytes con wordsize 8), incluido overhead tabla, excluidos
heaps guardian/registro/plan/resultado. Para 2 y 3 sondas hubo 343 y 362 palabras.
Es muestra local de storage, no throughput benchmark ni
fórmula universal de memoria.

Assertions extra comprobaron:

* todos contextos distintos, dueño guardian y ETS cerrada tras resultado;
* A→B→A: cobertura exacta primera/tercera igual; B excluye A;
* éxito legítimo sin hits → `valid_empty_coverage`;
* calibration A actualiza global conservando `seed_calibration`;
* crash/timeout tras X conservan `{X}`, feedback deja global vacío intacto;
* erase context + excepción hook capturada → infraestructura, feedback la rechaza;
* child/linked/nested: sonda C única, contexto compartido, 2/2/3 procesos
  conocidos respectivamente, muertos al recibir resultado;
* spawn normal en VM aparte: cobertura vacía, infrastructure/dirty-runner,
  dos procesos terminados, input siguiente no inicia;
* planner `efz_mutation_plan:next/2` selecciona realmente AB retenida con parent ID 2.

Raw records/logs: `_build/coverage-audit-2026-09-15/`.
Resultados compactos preservados: [results.txt](../../coverage-audit-2026-09-15/results.txt),
[validation.json](../../coverage-audit-2026-09-15/validation.json).

Validación: compile — exit 0; EUnit — **186 aprobados**, exit 0;
Common Test — **3 aprobados**, exit 0; xref/dialyzer — exit 0.
Assertions nuevas corren aparte sin aumentar casos EUnit.
SHA-256 de todos los fuentes productivos comprobados antes/después; sin cambios.

Suite completa también comprueba rutas no duplicadas:

| Test | Área |
|---|---|
| `efz_phase2_tests` | Semántica AST, identidades manifest, repetibilidad, contextos separados, excepciones/timeouts, opciones compiler |
| `efz_backend_tests` | Equivalencia, validación prepared/per-execution, lifecycle/observaciones rotas |
| `efz_integrity_tests` | Hot reload plain/build distinto, harness fijado, contexto perdido/corrupto, excepciones capturadas, vacío legítimo |
| `efz_isolation_tests` | Muerte caller/coordinator, descendientes en timeout, anidación, dirty state/fallo guardian |
| `efz_crash_retention_tests` | Fallo guardian tardío conserva causa primaria infraestructura |
| `efz_feedback_loop_tests` | Descubrimiento staged real→retención→padre reutilizado y fresh replay |
| `efz_durable_tests` | Discovery restaurada en otra VM, recalibrada y usada de padre |
| `efz_coverage_SUITE` | Campaña automática, observaciones crash/timeout |

## 14. Clasificación final

**RESULTADO B — semántica feedback similar a AFL++ implementada, representación distinta.**

Cada enlace demostrado: instrumentación automática → observaciones propias de ejecución →
snapshot validado → set global worker → delta exacto → inserción corpus real →
futuro padre de mutación. Por eso C/D no describen EFZ actual.

Resultado A descartado: trace físico es ETS set y multiplicidad
se pierde en `insert_new/2`. Llamarlo «bitmap» en docs
no cambia esto. B describe arquitectura global feedback,
**no poder de observación equivalente AFL++ para edges/counts/context**.

## 15. Siguiente paso recomendado

**No hace falta reescribir el sistema actual para parecerse a AFL++.** Primero
separar tres cambios independientes: (1) representación, (2) sensibilidad count,
(3) granularidad edge/context. Buffer denso solo no crea edges ni buckets.

| Aspecto | Conclusión para EFZ |
|---|---|
| Velocidad lookup/update | ETS ofrece hash lookup/inserción atómica, pero cada hit valida registro/contexto. Medir aparte hook, integrity tracing y executor completo. Nombre bitmap no garantiza rapidez. |
| Memoria | Set sparse crece con hits, overhead tabla/tuple y evidencia duplicada. Buffer denso reserva todo rango, incluidas sondas no ejecutadas. |
| Número de sondas | Sparse puede favorecer N grande/K pequeño; cobertura densa puede favorecer representación numérica compacta. Hacen falta cargas con N/K distintos. |
| Overhead ETS | Evaluar claves/lookup mapping compactos exactos conservando presence. Snapshot usa tab2list + sort y copia terms. |
| Sensibilidad hit-count | Opción independiente útil en bucles. Prototipo con contadores exactos sin colisiones ni reescritura bitmap total. |
| Colisiones | Modulo/hash aliasing sin necesidad demostrada pierde precisión. Preferir índice denso sin colisión preparado de manifests. |
| Identidad determinista | Conservar `{M,Build,Probe}` público; slots numéricos internos mapean build set seleccionado. |
| Workers paralelos | VM actual permite una ejecución. Cambiar storage no arregla singleton registro/guardian ni aislamiento compartido. |
| Fuzzing distribuido | Empezar VM independientes, identity/metric versionadas e intercambio raw inputs con calibración local. No mezclar slot maps de builds distintos. |
| Corpus compatible | Bytes reutilizables; `new_probes` antiguos son metadata presence histórica. Bucket discoveries necesitan versión metric/schema separada, no reinterpretar viejo. |
| Replay | Receta reconstruye bytes sin depender de storage. Permanecen checks build/harness; expectativas coverage requieren metric/version. |
| Retrocompatibilidad | Presence predeterminado/referencia; modo nuevo opt-in. Diferenciales deben conservar outcomes/identidades existentes. |

Arquitectura mínima **propuesta**, no implementada, si se confirma necesidad:

```text
instrumentación existente → {Module,BuildId,ProbeId}
  → mapping preparado inmutable exacto identidad↔slot denso
  → array de contadores propio de ejecución / backend sparse exacto
  → política explícita de saturación/overflow
  → clasificación bucket versionada
  → novedad de (ProbeIdentity,Bucket) contra features globales de campaña
  → ruta de retención existente → corpus/scheduler existente
```

Para comparar calidad, mantener `coverage => [Identity]` y añadir
`coverage_features` / `new_features` separados; discovery count-only no debe
fingir sonda fuente nueva. Snapshot debe conservar lifetime guardian,
incrementos atómicos de hijos, integrity checks, cleanup, build
validation y reset correcto. Bitmap compartido persistente sin dueño de ámbito
violaría garantías ya demostradas.

`efz_mutation`, `efz_mutation_plan`, raw input/recipe regeneration, selección
corpus y mayoría de `efz_worker`, `efz_executor`, `efz_guardian`,
`efz_instrument_pt` siguen sin reescribir. Cambios centrados en `efz_cov`,
`efz_cov_rt`, mapping/validation preparados, `efz_feedback`, config y metadata
versionada corpus/crash/replay. La evidencia de integridad debe adaptarse a
contadores: set first-observation actual no confirma exactitud count.

Aceptación siguiente: presence da resultados previos;
count retiene LOOP1 y luego LOOP10 con bucket nuevo; repeats mismo bucket
no se retienen; A→B→A limpio; incrementos controlados concurrentes no perdidos;
cleanup crash/timeout no corrompe snapshot; build/metric mismatch
rechazado. Decidir bitmap productivo después de medir coste end-to-end y
discoveries útiles en targets reales, no solo velocidad array aislado.
