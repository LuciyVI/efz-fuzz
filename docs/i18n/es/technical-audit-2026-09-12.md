# Auditoría técnica de EFZ — 12 de septiembre de 2026

[English](../../technical-audit-2026-09-12.md) · [Русский](../ru/technical-audit-2026-09-12.md) · **Español** · [简体中文](../zh-CN/technical-audit-2026-09-12.md) · [Todos los idiomas](../README.md)

## 1. Resumen ejecutivo

**EFZ ya funciona como fuzzer guiado por cobertura para un objetivo binario síncrono en un único proceso Erlang. El ciclo mutación → ejecución → cobertura → corpus activo → siguiente mutación está cerrado. Lo confirma una ejecución real, no solo la existencia de una API.**

En otro experimento, efz_mutation_plan, efz_worker, efz_executor, la instrumentación automática y efz_corpus estándar construyeron esta cadena:

~~~text
corpus id=1: <<>>          initial seed from file
    dictionary_insert "A"
corpus id=2: <<"A">>       new coverage; parent=1
    dictionary_insert "B" at position 1
corpus id=3: <<"AB">>      new coverage; parent=2
    dictionary_insert "C" at position 2
corpus id=4: <<"ABC">>     new coverage; parent=3
~~~

Se ejecutaron 40 mutaciones reales, 41 entradas se entregaron exactamente a un harness independiente y 40 recetas reconstruyeron los bytes originales. Hubo tres descubrimientos y un crash. La entrada CRASH guardada reprodujo error(test_crash), también en otra VM. Evidencias: [e2e.txt](../../audit-2026-09-12/e2e.txt), [fuente del experimento](../../audit-2026-09-12/run.escript), [informe ETF completo](../../audit-2026-09-12/e2e-report.term), [replay nuevo](../../audit-2026-09-12/fresh-replay.log).

**Límite operativo:** el corpus satisfactorio existe en memoria de una campaña. No hay lector integrado de directorio de seeds, persistencia en disco de nuevas entradas satisfactorias, restauración de cola ni CLI fuzz universal. Tras stop/start, el experimento conservó el conjunto original de un seed. Los escripts existentes guardan el informe final por su cuenta; no es persistencia del servicio de corpus.

**El mutador staged está integrado.** El modo random sigue predeterminado y también usa el corpus creciente. Afirmar que “el mutador nuevo existe aparte” o “el scheduler solo ve seeds iniciales” no coincide con el código actual.

Los tres problemas principales:

1. El ciclo de vida de campaña para el usuario está incompleto: launcher común, archivos seed, corpus duradero y reinicio.
2. El aislamiento se limita al proceso objetivo raíz; la ejecución de hijos no se mide automáticamente, los hijos pueden seguir vivos y el estado global afecta casos posteriores. Validar el manifest no demuestra que el objetivo seleccionado haya ejecutado código instrumentado.
3. El scheduler staged puede detenerse antes de mutaciones disponibles: 256 seeds válidos, etapas dictionary_overwrite/bitflip, diccionario inadecuado y max_idle_visits predeterminado dan cero ejecuciones de mutación. Las pruebas estándar no cubren esto ni afirman explícitamente reutilizar un padre descubierto por cobertura.

La fase siguiente debe convertir el ciclo de un worker existente en herramienta reproducible: establecer ascendencia con prueba end-to-end, corregir parada prematura, añadir entrada/salida y restauración del corpus y formalizar límites de ejecución/cobertura y errores de almacenamiento. No exige motor de mutación nuevo, otro backend de cobertura, planificación distribuida ni UI.

## 2. Arquitectura actual

### Checkout auditado y ámbito

Repositorio principal: /home/anonymous_usr/erl:fuzz/efz, rama main, HEAD ac09c1f3e938c3a79b369fc6a87d61c1ae739db4, “chore: initialize efz OTP project”. El workspace superior no es repositorio Git de trabajo.

HEAD no describe la implementación auditada: la mayoría de src/*.erl, test/, docs/, examples/, fixtures/, bench/ y scripts/ ya estaban sin seguimiento; README.md, rebar.config y src/efz.app.src estaban modificados. Se registraron [estado inicial](../../audit-2026-09-12/status-before.txt) y [SHA-256 de los 83 archivos originales](../../audit-2026-09-12/before-sha256.json). El vecino efz.worktrees/agents-condemned-silverfish contiene los mismos 83 archivos con bytes idénticos: es otro checkout, no un segundo motor runtime.

Tras la auditoría siguen coincidiendo los SHA-256 de los 83 archivos. Solo se añadieron este informe y audit-2026-09-12/ con evidencias y fuentes diagnósticas; no cambiaron código de producción ni pruebas estándar, y no hubo commit/push. El paquete guardado se ejecutó desde otro directorio temporal: pasaron assertions diagnósticas y replay nuevo. [Verificación de integridad y estructura](../../audit-2026-09-12/verification.json).

Se estudiaron todos los módulos src, componentes de prueba, scripts de lanzamiento/replay, ejemplos, fixtures, funciones de drivers de benchmark y documentación de arquitectura, cobertura, mutación, replay y fases previas. No se recalcularon cifras históricas de rendimiento ni se usan como evidencia nueva. calibration-readiness.md contiene auditoría y propuestas; no está implementado el recolector de calibración/estabilidad de producción de su plan.

Entorno: OTP 27.0 / ERTS 15.0, Rebar3 3.25.0, Linux. rebar.config fija minimum_otp_vsn=27, debug_info, warnings_as_errors, src_dirs=[src,examples/simple_parser], deps=[]. La aplicación depende de kernel, stdlib y crypto. No se encontraron runtime Go/Python, cobertura NIF, provider rebar para CLI fuzz, workflow CI ni perfiles de proyecto adicionales.

### Mapa de directorios

| Directorio / archivo | Función real |
|---|---|
| src/ — 24 módulos Erlang y efz.app.src | Única implementación de producción |
| examples/simple_parser/ | Dos módulos, parser normal y adaptador; incluidos en compilación normal |
| examples/automatic/run.escript | Campaña random concreta con objetivo/seeds escritos en el script |
| examples/staged/ | Parser staged, diccionario hex y campaña concreta con replay |
| examples/cowboy/ | Harness síncrono parse_qs, launcher y 14 comprobaciones adicionales; dependencia externa |
| test/ | EUnit, Common Test y mutador scripted de pruebas |
| fixtures/ | Semántica de instrumentación, AST no soportado, casos include/record/tail y objetivos de rendimiento |
| scripts/replay.escript | CLI solo para receta → bytes |
| scripts/coverage_bench.escript, bench/ | Benchmarks, profiling, informes y archivo; no servicios de campaña |
| docs/ | Contratos, comprobaciones históricas y planes; no son implementaciones |
| _build/ | BEAM compilados y manifests/informes/artefactos crash generados; no fuente de verdad |

### Árbol de procesos real

~~~text
application controller
└── efz_sup                    supervisor: one_for_all, intensity=0, period=1
    └── efz_fuzzer             temporary dynamic child, gen_server
        ├── efz_corpus         start_link; linked child, NOT a separate efz_sup child spec
        ├── efz_stats          start_link; linked child
        └── efz_worker_sup     linked supervisor: one_for_one, 5/10
            └── efz_worker     one temporary child
                └·· coordinator  spawn_monitor per input; not a supervised child
                    └·· target   spawn_monitor per input; M:run(Input)
~~~

Las relaciones punteadas indican creación/monitorización, no links. efz_fuzzer también monitoriza el worker. Implementación: [efz_fuzzer:init/1](../../../src/efz_fuzzer.erl), líneas 17–25; [efz_worker_sup:init/1](../../../src/efz_worker_sup.erl), línea 2; [efz_executor:coordinate/6](../../../src/efz_executor.erl), líneas 25–60.

Tras excepción normal del objetivo, el worker continúa la campaña. No se reinicia: el fuzzer devuelve infrastructure_failure/worker_down. Fallar corpus/stats/supervisor del worker detiene al fuzzer mediante EXIT atrapado; terminate/2 para supervisor del worker y después stats/corpus. Cobertura global y cursores no se restauran al caer el worker. Al completar campaña sigue vivo sin otro iterate: liberar corpus, plan ETS y servicios requiere efz:stop/0.

### Propiedad del estado

| Estado | Propietario / mecanismo | Duración |
|---|---|---|
| Corpus activo, siguiente ID entero, PRNG de selección aleatoria | Estado gen_server efz_corpus; PRNG en su diccionario de proceso | Una campaña |
| Cobertura global satisfactoria, builds | efz_worker.feedback: mapa + conjuntos | Una campaña |
| Plan de mutación, RNG explícito, cursores, ID pendientes | efz_worker.mutation_state | Una campaña |
| Conjunto preparado de probes permitidos | ETS protegida sin nombre efz_coverage_plan; propietario worker | Hasta morir el worker |
| Cobertura de ejecución actual | ETS pública sin nombre efz_execution_coverage; propietario coordinador | Una entrada |
| Puntero a cobertura actual | Diccionario del objetivo, '$efz_execution_context' | Un proceso objetivo |
| Decisiones, ID crash, traza acotada de recetas | Estado del worker | Una campaña |
| Contadores | efz_stats gen_server | Una campaña |
| Informe final, esperas await | Estado efz_fuzzer | Hasta stop |
| BEAM instrumentado + sidecar manifest | Sistema de archivos; módulos cargados usan code server compartido | Más allá de una entrada |
| Crash .input/.term/.recipe | Sistema de archivos, efz_crash:save/4 | Entre ejecuciones |

El src de producción no usa persistent_term. Lo usa efz_perf_replay solo para benchmarks y puede usarlo el objetivo, pero el ejecutor no lo limpia.

## 3. Inventario de componentes

El estado evalúa la función afirmada del componente, no solo compilación. PARTIAL también señala parte ausente del flujo del usuario, indicando explícitamente que no existe módulo correspondiente. STUB indicaría un placeholder existente; no se encontró ninguno en la ruta principal. UNUSED significa sin llamadas del runtime principal, no permiso de borrado inmediato.

En la tabla, “Implementación / finalidad” combina Purpose y Current implementation; I/O cubre Inputs y Outputs. Módulo X está en src/X.erl salvo otra ruta explícita.

| Componente | Módulos/archivos; implementación / finalidad | Entradas → Salidas | Propiedad del estado | Llamado por → Llama a | Estado |
|---|---|---|---|---|---|
| Entrada pública | efz:start/1, stop/0, stats/0, await/1; API OTP | Mapa config → {ok,Pid} / error; await → mapa informe | Aplicación / fuzzer | Llamador Erlang, ejemplos → application, supervisor, fuzzer | IMPLEMENTED |
| CLI genérico | Sin efz_cli separado ni comando común run TARGET CORPUS; examples/*/run.escript contienen campañas concretas | Argumentos de ejemplo → config API | Escript principal | shell → efz:start | PARTIAL — falta launcher genérico |
| Configuración | efz_config:prepare/1; defaults, callbacks, preflight; esquema de mutación aparte | map → {ok,prepared map}/{error,...} | Llamador, luego worker | fuzzer → instrument, mutation_plan, code | PARTIAL — esquema superior permisivo |
| Contrato harness | efz_target; -callback run(binary()) -> term(); runtime no exige behavior | binary → cualquier término / excepción | Proceso objetivo | executor → M:run/1 | IMPLEMENTED |
| Selección harness / objetivo | Atom target en config; callback fijo run/1; export comprobado | target atom, artifacts → callbacks cargados | Code server | config → ensure_loaded/function_exported | PARTIAL — sin MFA/arity/cargador fuente en API común |
| Invocación objetivo | efz_executor:run/4, coordinate/6 | Módulo, entrada, timeout, opciones → mapa resultado | Coordinador por caso | worker, recipe → M:run/1 | IMPLEMENTED en un proceso |
| Entrega de entrada | worker execute/4 → executor; no decodifica binario | binary + padre → mismo binary en harness | Worker/coordinador/objetivo | corpus/planner → executor/harness | IMPLEMENTED |
| Worker | efz_worker gen_server, mensajes iterate | Config/corpus preparados → ejecuciones/informe | Worker | worker_sup → mutator, executor, feedback, corpus, crash, stats | IMPLEMENTED |
| Gestión timeout | executor wait_target/5, kill_and_drain/2; deadline + DOWN | Timeout entero ms → {timeout,T} | Coordinador | executor → monitor/exit/receive | PARTIAL — limpieza raíz; descendientes no rastreados |
| Gestión excepciones | executor try/catch; infraestructura separada de fallo objetivo | Excepción/exit → tupla outcome, stack para error/throw | Coordinador + worker | objetivo → feedback/crash | IMPLEMENTED con reservas de origen |
| Fachada compilador cobertura | efz_instrument:compile/2, preflight/1, load/1 | .erl, allowlist, opciones → BEAM/manifest/mapa artefacto | Archivos/code server | Llamador/config/replay → compiler/PT/manifest | IMPLEMENTED |
| Instrumentación cobertura | efz_instrument_pt:parse_transform/2 | Formas abstractas → formas con hooks, atributo manifest | Estado local compilación | compile → efz_cov_rt:hit/1 generado | PARTIAL — AST limitado, strict predeterminado |
| Hook cobertura | efz_cov_rt:hit/1; ETS insert / member+insert | Identidad probe → ok o error etiquetado | ETS por caso vía contexto PD | Objetivo instrumentado → ETS | IMPLEMENTED para proceso adjunto |
| Contexto/recolección | efz_cov:open/attach/snapshot/close | Backend/contexto → identidades exactas ordenadas | Coordinador posee ETS | executor → ETS/runtime | IMPLEMENTED |
| Identidad/validación | efz_cov_manifest; mapeo fuente, allowlist exacta, plan preparado | manifest/hits → ok/error, mapa builds | ETS worker / mapas inmutables | config/executor/recipe → ETS/sets/beam_lib | PARTIAL — valida ID observados, no integridad continua de código cargado |
| Estado/feedback cobertura | efz_feedback:new/1,evaluate/3 | Conjunto previo + resultado + fase → conjunto nuevo + decisión | Worker | worker → efz_cov:merge/2 | IMPLEMENTED |
| Corpus | efz_corpus; lista entradas, dedup al añadir, ID | [binary], add(binary,meta) → entry/list/{ok,id}/{existing,binary} | Corpus gen_server | fuzzer/worker → rand | PARTIAL — solo RAM, duplicados iniciales permanecen |
| Cola | Mismas entradas; sin servicio separado | Entradas ordenadas → seleccionables | Corpus | worker/planner → corpus API | IMPLEMENTED cola básica |
| Selección seed | corpus:select/0 random; mutation_plan:visit/2 round-robin staged | Entradas → padre | RNG corpus / plan worker | worker → rand o cursor | PARTIAL — corte idle puede preceder etapa productiva |
| Mutador random | Callback efz_mutator; efz_mutator_random:mutate/2, cuatro operaciones | binary, #{iteration=>N} → binary | PRNG proceso worker | rama random → rand/list operations | IMPLEMENTED, ruta legacy/predeterminada |
| Mutación staged | efz_mutation_plan:new/1,next/2 | Plan + entradas actuales → candidate/skip/done/error | Worker | rama staged → efz_mutation, dictionary, rand:*_s | PARTIAL — integrada, agotamiento prematuro |
| Etapas deterministas | mutation_plan:deterministic/4, det_op/4 | Etapa, binario, índice, config → operation/done | Cursores contenido/config | Planner → primitivas | IMPLEMENTED |
| Primitivas de mutación | efz_mutation:apply_operation/3,apply_operations/3 | Binario + operaciones concretas + límites → ok/skip/error | Sin estado mutable | Planner/recipe/tests → binary/crypto | IMPLEMENTED |
| Havoc | mutation_plan:random_attempts/5,stack/7 | Primary, entradas activas, RNG explícito → pila realizada | Plan worker | Planner → primitives/random_operation | IMPLEMENTED |
| Diccionario | efz_dictionary:normalize/2,load/2; formato hex EFZ | Tokens binarios o archivo hex → tokens normalizados + hash | Config preparada | mutation_plan:prepare → lectura acotada | IMPLEMENTED |
| Splicing | mutation_plan:random_operation/6; operación splice | Primary + donantes de todas las entradas → binario prefijo/sufijo, bytes/hash donante | Plan worker | Havoc/splice → mutation:apply_operation | IMPLEMENTED |
| Recetas | efz_recipe:make/4, encode/decode, regenerate | Primary + operaciones realizadas → EFZR / salida exacta | Metadatos corpus/crash; traza opcional acotada | worker/replay → mutation, hash | IMPLEMENTED para staged |
| Replay | recipe:execute/5, execute_file/5; scripts/replay.escript | Objetivo/builds explícitos + entrada → resultado; CLI receta → archivo | Plan preparado nuevo | Llamador/scripts → preflight/executor | PARTIAL — sin CLI ejecución genérico, identidad harness no fijada |
| Almacenamiento crash | efz_crash:fingerprint/3,save/4 | Entrada/resultado/meta/directorio → .input/.term/[.recipe], registro | Archivos + crash_ids worker | worker → file/crypto/recipe | PARTIAL — escritura no atómica, errores tiran worker |
| Estadísticas | efz_stats:inc/get; tiempos/cuentas worker | Clave contador → contadores/mapa | Stats gen_server | Worker/fuzzer/API → gen_server | PARTIAL — worker_down no incrementa contador de infraestructura |
| Supervisión | efz_app, efz_sup, efz_fuzzer, efz_worker_sup | Inicio/parada/muerte → ciclo/informe | Procesos OTP | efz/application → links/monitors/supervisors | PARTIAL — coordinador por caso no supervisado |
| Workers paralelos | config valid acepta solo workers=1 | workers>1 → configuración inválida | Ninguno | config rechaza | PARTIAL — función ausente, no pool latente |
| Estado persistente | Sin restaurar corpus/cobertura global/cursores/RNG | — | Ninguno | — | PARTIAL — solo artefactos crash e informes externos |
| Compatibilidad manual | efz_cov:hit/1, executor:run/3; ejecutor común | ID manual → {manual,Id}; run/3 → outcome | Mismo contexto | Llamadores legacy/pruebas → runtime | LEGACY, disponible explícitamente |
| Helpers antiguos | cov:interesting/2, reset_local/0, snapshot/0 | Helpers manuales directos | PD/contexto | Sin llamadas en src/test/examples actual | UNUSED en ruta principal |
| Mutador pregrabado de prueba | test/efz_scripted_mutator | Iteración → binario pregrabado; ignora padre | Ninguno | Phase2/CT/backend → lists:nth | UNUSED en producción |
| Replay / medición benchmark | bench/efz_perf*, *.escript, scripts/coverage_bench | Entradas/cargas → tiempos/ETF/texto | VM benchmark; replay usa persistent_term | Scripts explícitos → API pública EFZ | UNUSED en producción |

## 4. Flujo real de ejecución end-to-end

### Arranque común

~~~text
Erlang caller / examples/.../run.escript:main
  -> efz_instrument:compile(SourceFile, CompilerConfig)           % explicit preliminary step
  -> efz:start(ConfigMap)
  -> application:ensure_all_started(efz)
  -> supervisor:start_child(efz_sup, efz_fuzzer child spec)
  -> efz_fuzzer:start_link(ConfigMap)
  -> efz_config:prepare(ConfigMap)
       -> efz_mutation_plan:prepare(MutationOptions, Seeds)       % staged only
            -> efz_dictionary:normalize/2, load/2
       -> efz_instrument:preflight(Artifacts)                    % automatic
            -> load/1 -> loaded_manifest/2
       -> code:ensure_loaded(Target), function_exported(Target,run,1)
  -> efz_fuzzer:init(PreparedConfig)
       -> efz_corpus:start_link([binary()], SelectionSeed)
       -> efz_stats:start_link()
       -> efz_worker_sup:start_link(Config#{coordinator=>FuzzerPid})
            -> efz_worker:init(Config)
                 -> efz_cov_manifest:prepare(Mode, Manifests)     % default
                 -> efz_feedback:new(Builds)
                 -> efz_mutation_plan:new(MutationConfig)        % staged
                 -> self() ! iterate
~~~

El descriptor de artefacto contiene atom de módulo, ruta BEAM absoluta, ruta manifest, build_id SHA-256 binario y avisos. Config preparada es mapa normal, no application env ni persistent_term. Los artefactos se cargan antes del worker. El cargador no compila un harness separado sin instrumentar de una ruta recibida: debe estar disponible para code server.

### Calibración y dos rutas de mutación

El worker copia primero efz_corpus:all() a pending_seeds. Cada entrada inicial se ejecuta una vez con Phase=calibration; inicializa GlobalCoverage, no calibra estabilidad repetidamente.

~~~text
random:
  efz_worker:handle_info(iterate, State)
    -> efz_corpus:select()
       gen_server:call(efz_corpus, select)
       <- #{id:=integer(), input:=binary(), metadata:=map(), added_at:=integer()}
    -> MutatorModule:mutate(Input, #{iteration => N+1})
       <- binary()

staged:
  efz_worker:staged_iteration(State)
    -> efz_corpus:mutation_entries()
       gen_server:call(efz_corpus, mutation_entries)
       <- [#{id:=integer(), input:=binary()}]                     % entire current corpus
    -> efz_mutation_plan:next(PlanMap, Entries)
       <- {candidate, Binary, ProvenanceMap, NextPlan}
        | {skip, Reason, NextPlan}
        | {done, Reason, NextPlan}
        | {error, Reason, NextPlan}
    -> efz_recipe:make(Provenance, Binary, MutationConfig, Builds)
       <- RecipeMap
    -> efz_worker:execute(Binary, #{id=>ParentId}, mutation, State)
~~~

skip solo programa el siguiente iterate. iteration/max_iterations cuenta candidatos generados y ejecutados; no incluye skips ni calibración inicial.

### Ejecución, mensajes y retorno

~~~text
efz_worker:execute(Input, ParentEntry, Phase, State)
  -> efz_executor:run(TargetModule, Input, TimeoutMs, ExecutorOptions)
       Request = make_ref()
       spawn_monitor(coordinate(Caller, Request, ...))
         monitor(Caller)
         efz_cov:open(Backend)
           <- {efz_context,1,Ref,TableOrBackendTable,OwnerPid}
         spawn_monitor(target fun)
           efz_cov:attach(Context)
             put('$efz_execution_context', Context)
           TargetModule:run(Input)
             -> synchronous target calls
             -> instrumented clause: efz_cov_rt:hit({Module,BuildId,ProbeId})
                  ets:insert(Table, {{probe, Identity}})
           Parent ! {target_result, Ref, self(), Outcome}
         receive target_result / DOWN / caller DOWN / timeout
         wait for target DOWN; on timeout kill_and_drain/2
         efz_cov:snapshot(Context) -> {ok,SortedHits} / {error,...}
         efz_cov_manifest:validate_prepared(...) -> ok / error
         Caller ! {Request, CoordinatorPid, ResultMap}
         after: kill_and_drain(Target), close(Context), demonitor(Caller)
       caller waits for coordinator DOWN, then returns ResultMap
~~~

ResultMap contiene execution_ref, outcome, target_outcome, coverage, coverage_status, elapsed_us y builds. El fallback coordinator_down no tiene target_outcome, tiene coverage=[], builds=#{} y error de infraestructura; no es snapshot vacío satisfactorio normal.

Mensajes adicionales: {'DOWN',Monitor,process,Pid,Reason} estándar; si falla ETS, el hook envía al propietario {efz_cov_failure,Ref,Why}. Al completar campaña, worker envía {campaign_done,WorkerPid,Report}; fuzzer responde a llamadores gen_server await guardados. La entrada no pasa por descriptor de archivo, stdin, puerto, socket ni buzón compartido del worker: la capturan closures de spawn_monitor.

### Feedback y generación siguiente

~~~text
ResultMap
  -> efz_feedback:evaluate(FeedbackState, ResultMap, Phase)
       successful: New = Observed \ Global
                   Global1 = Global union Observed
       <- {ok,NewFeedback,#{new_probes=>New,retention_reason=>Reason}}
  -> efz_worker:retain(Input, Metadata)
       if Reason = new_coverage:
         efz_corpus:add(Input, Metadata)
           gen_server:call(efz_corpus,{add,Input,Metadata})
           entries := entries ++ [NewEntry]
           next := next + 1
           <- {ok,Id} / {existing,Input}
  -> efz_worker:record_failure(...)                              % separate artifact branch
  -> self() ! iterate
  -> corpus:select() or corpus:mutation_entries()              % see NewEntry
  -> next mutation, where NewEntry can be Parent
~~~

Conexión concreta: worker líneas 42–49, 58–90; corpus 12–14; mutation_plan 63–76. No hay hueco entre retener con éxito y seleccionar de nuevo. No hay operación de archivos en este tramo.

## 5. Harness y entrega de entrada

### Cómo selecciona un objetivo el usuario

**Hoy se puede ejecutar un run(Input) when is_binary(Input) mínimo sin cambiar internos de EFZ.** Basta exportar run/1, compilar/cargar el módulo con herramientas Erlang normales y pasar target => Module a efz:start/1. Solo hace falta adaptador separado si el objetivo existente no encaja en run/1 o se necesita controlar clasificación de errores. Existe behavior efz_target formal; runtime comprueba la función pero no exige atributo -behaviour.

El modo automatic también necesita artefactos instrumentados de módulos que realmente se llamarán. Puede instrumentarse el módulo de run/1, como ejemplo staged, o un parser separado dejando harness normal, como ejemplos automatic/Cowboy/auditoría.

| Pregunta | Respuesta real / evidencia |
|---|---|
| Módulo objetivo | Clave config target, atom; config:valid/1 líneas 29–33 |
| Función y aridad | Fijas run/1. Opciones function/arity no implementadas; claves superiores arbitrarias pueden conservarse silenciosamente |
| Contrato | efz_target: -callback run(binary()) -> term() |
| Carga | Primero preflight de artefactos; luego ensure_loaded(Target); sin API compile_harness separada |
| Comprobación export | erlang:function_exported(M,run,1), config líneas 42–48 |
| Proceso | Proceso objetivo nuevo por entrada; misma VM BEAM |
| Invocación | M:run(Input), executor línea 34; sin apply/3 explícito |
| Éxito | Cualquier retorno normal, incluidos {error,...}, false o {invalid,...}, envuelto en {ok,ReturnValue} |
| Error/throw | {crash,Class,Reason,Stack} |
| exit/1 | {exit,Reason}, no conserva stack |
| Exit anómalo por link | Puede terminar raíz → monitor DOWN → {exit,Reason}; si raíz atrapa exits y procesa señal, retorno normal cuenta como éxito |
| Timeout | Solo raíz se mata y espera por DOWN; hijos no registrados |
| Callbacks de limpieza | before_input/reset/after_input/cleanup no existen |
| Ciclo de aplicación | EFZ no gestiona inicialización/parada de aplicación objetivo |

Para objetivos que esperan list, iolist, término arbitrario o MFA, el usuario escribe conversión/adaptador. En audit_harness, la entrada pasaba inalterada a audit_target:parse/1. En Cowboy los bytes van a #{qs=>Input}; request_error qs/limit_reached normales se convierten en {invalid,...}, mientras las excepciones inesperadas se propagan.

### Un seed desde archivo al objetivo

La API de producción acepta lista no vacía de binarios ya preparada. Ni config ni corpus leen archivos seed. La ruta disponible es:

~~~erlang
{ok, Seed} = file:read_file(SeedPath),       % caller, not an EFZ function
efz:start(#{target => Harness, seeds => [Seed], artifacts => Artifacts, ...}).
~~~

El binario queda en entry.input, se selecciona directamente o pasa al planner y el resultado sigue execute → run/4 → M:run/1 → parser. Eso hace el script de auditoría; file:read_file y escrituras fixture quedan fuera de cobertura. Estos preparativos no sustituyen el núcleo por mocks.

| Tipo / límite | Runtime random | Runtime staged |
|---|---|---|
| Entradas iniciales | Solo binary(); lista no vacía | Igual; máximo 4096 entradas iniciales |
| Límite superior | Sin límite común en config/worker/executor | max_input_bytes predeterminado 4096, permitido 0…1048576 |
| Tipo generado | Worker comprueba is_binary | Primitivas devuelven binary; planner trata error/skip |
| Binario vacío | Permitido; delete puede dar <<>>, mutate(<<>>) da <<0>> | Permitido; delete/splice pueden dar <<>> |
| Seed demasiado grande | Aceptado con memoria suficiente | prepare rechaza oversized_initial_seed |
| Candidato demasiado grande | Sin comprobación común | Operaciones comprueban tamaño; skip(size_limit)/error |
| Conversión de bytes | binary_to_list y list_to_binary completos para entrada no vacía | Operaciones binarias; lista solo al generar bytes literales |
| Receta exacta | Ninguna | Bytes Primary + operaciones concretas + tokens/donantes literales + hash |
| Persistencia de entrada satisfactoria | Solo entrada RAM | Solo entrada RAM con receta |

La entrada pasa como término Erlang entre corpus, worker, coordinador y objetivo. No es API zero-copy: mapas/listas y datos heap cruzan procesos; binarios refcounted pueden compartir almacenamiento. No cambia la semántica binaria. En staged, mutation_entries/0 transfiere toda la lista de corpus cada vez; snapshots/informe también copian estructuras. Es cuestión posterior de rendimiento, no ruptura del feedback loop.

efz_executor:run/4 de bajo nivel no comprueba is_binary(Input) y recibe tuplas/atoms en pruebas. Es útil para probar ejecutor pero no amplía contrato binario del fuzz loop. execute/execute_file de replay limita entrada cruda a un MiB; random no tiene límite común equivalente.

### Aislamiento de casos y efecto de entradas anteriores

| Recurso | Limpieza real / influencia posible |
|---|---|
| Diccionario raíz | Desaparece con raíz; la siguiente es nueva. EFZ añade una clave interna de contexto |
| Buzón raíz | Desaparece; mensajes resultado/monitor quedan en coordinador separado y no llegan al siguiente caso |
| ETS cobertura | Tabla nueva por caso, eliminada por coordinador; terminar raíz normalmente no la destruye |
| ETS del objetivo | Tablas normales del propietario desaparecen con raíz; EFZ no limpia transferencias heir ni tablas ajenas/de hijos |
| Nombre raíz registrado | Se libera al morir raíz; permanecen nombres de hijos vivos |
| Hijos creados | Sin registro/kill-tree; hijos con o sin link pueden sobrevivir al retorno normal de raíz |
| Temporizadores | Sin cancelación/reset común; mensajes/acciones hacia procesos supervivientes pueden ejecutarse después |
| Monitores/links raíz | Raíz termina; EFZ drena monitores propios. No recorre procesos ajenos ni relaciones |
| Application env, persistent_term, code server | No se limpian y se comparten entre casos |
| Archivos, servicios externos, sockets, estado NIF | Sin reset/aislamiento universal |

Escenario A→B→A confirmado: entrada state llama path_a; dirty escribe persistent_term; state idéntica llama después path_ab con otro conjunto de probes. Véase [cross_case_state.txt](../../audit-2026-09-12/cross_case_state.txt).

Se confirmó que hijos con y sin link ejecutaban path_abc instrumentado sin contexto definido: cobertura raíz vacía y el hijo sobrevivía al retorno. Otro hijo sobrevivió al timeout raíz. El script diagnóstico terminó sus propios hijos tras registrar resultados; **esta limpieza no se atribuye a EFZ**.

Por tanto, aislar ETS/PD raíz correctamente no garantiza reproducir una aplicación OTP arbitraria. erlang:halt, caídas VM/NIF y consumo ilimitado de memoria compartida tampoco se aíslan con un proceso separado.

## 6. Pipeline de cobertura

### Mecanismo y granularidad

EFZ usa parse_transform fuente propio y conjunto ETS exacto. La implementación principal no tiene cobertura OTP nativa, cover, contadores, buckets hit-count ni bitmap. La instrumentación ocurre previamente en compile:noenv_file/2, no en cada iteración.

La métrica manifest es clause_outcome_probe. Se añade hook al inicio del cuerpo de cláusula/outcome seleccionado. Tipos reales:

~~~text
function_clause
case_clause
if_clause
receive_clause
receive_after
try_body
try_of_clause
catch_clause
try_after
fun_clause
named_fun_clause
~~~

No es cobertura de aristas, ramas completa ni líneas. Dos outcomes en misma línea tienen ID distintos; las líneas sirven para mapear fuente. Entrar en una cláusula no muestra cada transición entre cláusulas ni cada resultado de guard. andalso/orelse se recorren como nodos op normales: no se crean probes true/false separados del operador. Patterns y guards quedan sin hooks.

Comprehensions list/binary/map, maybe, AST desconocido y defaults ejecutables de record no reciben probes internos. strict=true rechaza instrumentación incompleta; strict=false conserva construcción, registra limitaciones y avisa. Pruebas semánticas en phase2_tests:semantics/1, manifest/1, tail/1 y skipped/0. Código nativo/NIF y módulos no seleccionados fuera de medición.

### Identidad y mapeo fuente

Identidad completa:

~~~erlang
{ModuleAtom, BuildIdSHA256, ProbeIdInteger}
~~~

ProbeId empieza en 1 por módulo y crece al recorrer AST determinísticamente. BuildId es SHA-256 de tupla con versión de instrumentación, OTP release, MD5 de compilador, formas preprocesadas normalizadas y opciones relevantes. [efz_instrument_pt:parse_transform/2](../../../src/efz_instrument_pt.erl), líneas 35–55; probe/4, 109–118.

| Propiedad | Hallazgo |
|---|---|
| Recompilar fuente/opciones/toolchain idénticos | Identidad estable; verificado por determinismo phase2 |
| Orden de compilación de módulos distintos | No afecta numeración local: sin asignador mutable compartido |
| Reordenar/añadir nodos AST | Puede renumerar probes; cambia namespace build |
| Builds distintos | No se trasladan mecánicamente ID antiguos a otro epoch de cobertura |
| Colisiones | Se rechazan enteros/rutas estructurales duplicados en manifest válido. Sin aliasing bitmap entre módulos. SHA-256 sigue siendo hash criptográfico, no garantía matemática de unicidad |
| Reubicación | Rutas dentro de source_root normalizadas, prueba relocated-build superada; rutas include absolutas externas/cambio toolchain pueden cambiar hash |
| Mapeo | Cada probe contiene function, arity, kind, structural_location, source_file, line y column |

BEAM contiene atributo efz_manifest; sidecar, el mismo término. El cargador compara sidecar con manifest BEAM y módulo ya cargado con manifest esperado. Prohibir otros parse transforms, usar allowlist, excluir internos EFZ/OTP y outdir separado protegen consistencia de compilación normal.

### Local → snapshot → global

~~~text
local coverage:
    fresh public unnamed ETS set, execution coordinator owner
    row = {{probe, {Module,BuildId,ProbeId}}}
    duplicate hit overwrites the same key

local context:
    {efz_context,1,FreshRef,TableOr{ets_member,Table},Owner}
    target PD '$efz_execution_context'

snapshot:
    ets:tab2list → sorted list of full probe identities
    after root DOWN; observations survive crash/kill/timeout

validation:
    allowed exact identities in protected worker-owned ETS plan
    alternative per_execution: build allowed set from manifests

global coverage:
    worker.feedback.global, Erlang sets
    only successful input coverage is unioned

reset:
    next execution receives a different table, reference and root process
    previous table is deleted; global set is not reset until campaign ends
~~~

ets_member comprueba primero ets:member y luego inserta si falta. Optimiza impactos repetidos en mismo conjunto; no es otra métrica. Prepared/per_execution son estrategias de validación, no recolectores distintos. La suite diferencial comprueba las cuatro combinaciones.

### Semántica exacta de interesting

[efz_feedback:evaluate/3](../../../src/efz_feedback.erl), líneas 5–22:

~~~text
require Result.builds == Feedback.builds
require coverage_status == ok

if outcome == {ok, _}:
    New = set(Observed) - Global
    Global := Global union Observed
    calibration -> retention_reason = seed_calibration
    mutation and New == [] -> equivalent_coverage
    mutation and New != [] -> new_coverage
else if infrastructure/coverage error:
    stop campaign as infrastructure failure
else:
    target_failure; Global unchanged; new_probes=[]
~~~

**Cobertura nueva = identidad completa de probe nunca observada antes en ejecución satisfactoria.** No cuenta nuevo, combinación nueva de probes conocidos, firma hash ni bit bitmap nuevo. El mismo conjunto con otras multiplicidades no es interesante. Un conjunto distinto que es subconjunto de Global tampoco.

La fórmula comprobada C_new = C_current − C_global está implementada, con condiciones de éxito y fase. Crashes/throws/exits/timeouts pueden tener cobertura no vacía pero no amplían conjunto global satisfactorio ni corpus. Esta política explícita evita que un probe solo de crash suprima una futura mutación satisfactoria útil.

Calibración fusiona seeds iniciales satisfactorios sin reinsertarlos ni incrementar discoveries. Tras evaluate, el snapshot completo satisfactorio no se guarda en corpus: quedan new_probes, builds, outcome, identidad y procedencia. Report.coverage es unión de campaña entera, no cobertura de una entrada concreta.

### Límites de fiabilidad del feedback

1. **Artefactos sin usar.** Una campaña automática con audit_target válido y harness que no lo llama completó con coverage=[], infrastructure_failures=0. Se validan los ID observados; lista vacía válida. Preflight correcto no demuestra conexión harness/objetivo seleccionado. [Evidencia](../../audit-2026-09-12/disconnected_artifacts.txt).
2. **Hot reload.** Tras preflight se reemplazó módulo por build normal sin instrumentar. El caso siguiente devolvió path_a, coverage=[], coverage_status=ok y mapa builds antiguo. Plan preparado es allowlist fijada, no comprobación por caso del código ejecutado. [Evidencia](../../audit-2026-09-12/hot_reload.txt). README prohíbe recargar así, runtime no detecta violación.
3. **Hijos.** spawn no hereda contexto del diccionario. Hijo instrumentado sin attach ejecuta hook como no-op. API permite transferir contexto manualmente, sin añadir quiescencia/limpieza de árbol al ejecutor.
4. **Corrupción de contexto.** Error ETS envía fallo sticky, pero cláusula malformed-context en cov_rt solo lanza excepción. El objetivo reemplazó contexto, capturó excepción y devolvió éxito con cobertura vacía. [Evidencia](../../audit-2026-09-12/caught_malformed_context.txt). Código normal que limpia todo PD también puede desactivar hook.
5. **Pérdida del coordinador.** Objetivo sigue vivo; fallback contiene builds=#{}. evaluate puede sustituir coordinator_down primario por instrumentation_build_mismatch. No es crash objetivo, pero se pierde causa primaria en informe.

No invalida cobertura en su ámbito declarado: proceso raíz nuevo y build instrumentado inalterado. Limita aplicabilidad a objetivos con estado/asíncronos y exige diagnóstico explícito.

## 7. Pipeline de corpus y cola

**Feedback loop de corpus: WORKING en una campaña. Persistencia/reinicio: PARTIAL, no implementados.**

Módulo clave [efz_corpus.erl](../../../src/efz_corpus.erl), solo 15 líneas; su brevedad oculta limitaciones importantes, no ausencia de cola.

| Concepto | Qué existe realmente |
|---|---|
| Corpus inicial | Config.seeds = [binary()]; se crea entrada por elemento sin deduplicación inicial |
| Cola activa | State.entries; primero seeds, luego todas las entradas satisfactorias con cobertura nueva |
| Entrada interesante | Mutación con outcome {ok,_} y NewProbes ≠ [] |
| Entrada guardada | Ruta satisfactoria: entry.input en RAM. Ruta crash: archivo .input |
| Entrada favorecida | Sin concepto/puntuación/flag |
| Donante | Cualquier entry.input del corpus activo con contenido distinto de Primary |
| ID de cola | Entero secuencial 1…N asignado por corpus gen_server serial |
| ID de contenido | SHA-256 en metadatos worker y planner/recipe; metadatos iniciales vacíos |

### Inserción y reutilización

retain/2 llama add/2 con new_coverage. Corpus compara igualdad binaria secuencialmente sobre lista. Si no hay coincidencia, añade al final e incrementa siguiente ID. Binario existente devuelve {existing,Binary}, no ID; worker cambia retention_reason a existing_input.

Random select/0 llama rand:uniform(length(Entries)) sobre **toda la lista actual**. Una entrada recién añadida tiene probabilidad no nula de elección. Random no garantiza determinísticamente seleccionarla antes de terminar presupuesto finito.

En staged, cada next recibe mutation_entries/0 actuales; snapshot de ID por ronda sigue inserción. Entrada nueva es primary en siguiente ronda. Donantes de random_operation(splice,...) salen de todas las Entries actuales, aunque los primary pendientes sean del inicio de ronda. Por tanto puede ser donante antes de su primer turno primary.

El experimento confirmó parent=2 para AB y parent=3 para ABC. Además, el ejemplo random estándar creó entry <<>> con parent=2, donde 2 era mutación <<"@">> descubierta antes. Random predeterminado también reutiliza padres descubiertos; esa secuencia concreta no tiene que repetirse sin selection_seed.

### Metadatos, deduplicación y planificación

| Propiedad | Estado |
|---|---|
| Mutaciones satisfactorias duplicadas | Igualdad binaria completa, búsqueda lineal; SHA no es índice dedup |
| Seeds iniciales duplicados | Conservados con distintos ID; dos <<"noop">> en prueba nueva dieron corpus size=2 y calibrations=2 |
| Padre | Mutación retenida tiene ID entero padre |
| Profundidad/generación | Sin campos explícitos; con ancestros guardados se deriva de links parent |
| Orden de inserción | Lista, añadido al final |
| Firma cobertura | Sin firma/snapshot satisfactorio completo separado; solo delta de descubrimiento y namespace build |
| Estado seed por entrada | Sin cuarentena para seeds crash/timeout/inestables; fallos iniciales permanecen en corpus activo |
| Favored/power/energy | No implementado |
| Límite global corpus/memoria | Sin cuota común; staged limita cantidad inicial y tamaño de entrada, no entradas acumuladas |
| Inanición random | Posible en campaña finita; probabilidad uniforme no garantiza atención |
| Equidad staged | Snapshots de ronda protegen entradas frente a crecimiento continuo hasta corte idle |
| Estado staged de contenido idéntico | Cursores por hash contenido + ID config; ID duplicados iniciales comparten avance |

### Disco y reinicio

Corpus no llama file, DETS, disk_log, Mnesia ni persistent_term. Sin API load/save/resume. No interpreta corpus_dir. Descubrimientos satisfactorios no reciben archivo de entrada/sidecar en disco.

Los ejemplos escriben report.term completo tras await. El usuario puede extraer binarios y pasarlos como seeds a otra campaña; EFZ no los importa ni restaura ID, cursores, PRNG, cobertura global o índice crash. Recalibrar seeds tampoco equivale a continuar campaña interrumpida.

En el experimento, iniciar de nuevo con misma Config redujo corpus de 4 a 1. El feedback loop runtime no se rompe entre retain y select, pero **el progreso no sobrevive stop/restart**.

## 8. Pipeline de mutación

### Operadores funcionales

“Etapa determinista” significa enumerar sin elecciones aleatorias. Toda operación efz_mutation concreta es determinista. “Reproducible” se refiere abajo a recetas staged registradas normalmente; legacy random no crea recetas.

| Mutación | Implementación | Etapa determinista | Reproducible | Uso runtime |
|---|---|---|---|---|
| Bit flip | flip_bits: 1/2/4 bits contiguos, MSB-first; legacy random: un bit | Sí, todos los offsets válidos | Sí, staged | Random; staged bitflip/havoc |
| Byte flip | invert_bytes: 1/2/4 bytes | Sí | Sí | Staged byteflip/havoc |
| Aritmética | add: 8/16/32 bits, delta con signo, módulo 2^W; endian big/little multibyte | Sí, ±1…±max_delta | Sí | Staged arithmetic/havoc |
| Enteros interesantes | set_integer: 0,1,2,half−2,half−1,half,half+1,max−1,max | Sí, boundary | Sí | Staged boundary/havoc |
| Inserción | Bloque binario concreto, incluido límite append | Sin etapa literal separada | Sí | Havoc; legacy inserta un byte aleatorio |
| Borrado | Elimina bloque no vacío, hasta salida vacía | Sin etapa separada | Sí | Havoc; legacy un byte |
| Sobrescritura | Bloque literal conservando tamaño | Sin etapa literal separada | Sí | Havoc; legacy un byte aleatorio |
| Duplicación | Copia bloque a posición de inserción | Sin etapa separada | Sí | Havoc |
| Inserción diccionario | Inserta token en cada frontera byte | Sí | Sí, bytes token en receta | dictionary_insert/havoc |
| Sobrescritura diccionario | Token en cada offset donde cabe | Sí | Sí | dictionary_overwrite/havoc |
| Splice | prefix(Current,CutA) ++ suffix(Donor,CutB) | No; cortes/donante aleatorios | Sí, bytes/hash donante en operación | Etapa splice y havoc |
| Havoc | Pila de operaciones realizadas, profundidad 1…havoc_depth | No; RNG explícito | Sí | Lane staged havoc |

Operaciones en [efz_mutation:operation/3](../../../src/efz_mutation.erl); selección/enumeración en [efz_mutation_plan](../../../src/efz_mutation_plan.erl), líneas 81–187. Orden de anchos/offsets comprobado por modelos independientes de bits/bloques y pruebas de enumeración.

### Orden real de ejecución staged

Etapas predeterminadas:

~~~text
bitflip, byteflip, arithmetic, boundary,
dictionary_insert, dictionary_overwrite, havoc, splice
~~~

Son **lanes round-robin intercalados**, no “acabar todas las etapas deterministas de cada seed, luego havoc y después splice”.

Cada visita selecciona siguiente ID corpus. Para su clave contenido/config, lane elige etapa módulo length(Stages). Lane aumenta; etapa realiza máximo attempts_per_visit intentos y emite como máximo un candidato. Siguiente visita usa lane siguiente aunque barrido actual no termine. Havoc puede ejecutarse mucho antes de acabar barrido bitflip.

El cursor de etapa guarda siguiente índice entero. skip/no_change avanza índice determinista. Agotada una etapa, permanece completa; no se materializan candidatos previamente. El Plan retornado sirve al siguiente next/2: reanudación en memoria funciona y está probada. No hay API de persistencia del plan cursores/RNG.

### Límites y recursos

| Parámetro | Predeterminado | Rango permitido / significado |
|---|---:|---|
| max_input_bytes | 4096 | 0…1048576 |
| max_block_bytes | 128 | 1…65536 |
| max_token_bytes | 128 | 1…65536; token también limitado por max_block_bytes |
| max_tokens | 256 | 0…4096 |
| max_dictionary_bytes | 16384 | 0…1048576 |
| max_delta | 8 | 1…128 |
| attempts_per_visit | 8 | 1…1024; máximo intentos, no salidas |
| havoc_depth | 8 | 1…32 |
| random_retries | 4 | 1…128, también limitados por presupuesto de intentos |
| max_idle_visits | 256 | 1…100000 visitas vacías consecutivas en TODA la campaña |
| trace_limit | 0 | 0…10000 recetas |
| max_iterations para staged | 1000 si falta | 0…1000000; infinity prohibido |

Sin máximo de mutaciones por seed separado. Limita presupuesto de ejecución, búsqueda determinista finita o corte idle. Seeds ≤4096 solo se comprueba en staged prepare. Opciones de mutación estrictas rechazan claves desconocidas, a diferencia del config superior.

El diccionario se carga una vez con lectura acotada: un token hex de longitud par por línea, comentarios # de línea completa y líneas vacías. No es parser de diccionario AFL. Tokens vacíos prohibidos; duplicados ordenados/usort; límites de cantidad/bytes totales antes de dedup. Tokens y dictionary_id fijos por campaña.

Primitivas sin cambio se omiten; pila havoc que vuelve a Primary original también, pudiendo reintentar. Pero binarios idénticos de etapas/padres distintos no se filtran antes de ejecutar. Corpus solo deduplica bytes retenidos; ejecuciones con cobertura equivalente siguen útiles para corrección pero consumen presupuesto.

### Donantes

random_operation(splice,...) recibe Entries directamente de efz_corpus:mutation_entries(). Donantes son lists:usort de todos los binarios distintos de Primary. No se limita a seeds iniciales. Procedencia conserva hash y binario donante; operación comprueba hash. Splice puede dar vacío; donante idéntico y salida sin cambio producen skip.

### Agotamiento prematuro — defecto reproducido

Condición de next/2:

~~~erlang
Idle >= maps:get(max_idle_visits,C) orelse complete(State,Entries)
~~~

Ambos motivos devuelven el mismo done mutation_exhausted. Con 256 seeds únicos de un byte, stages=[dictionary_overwrite,bitflip] y dictionary=[<<"AB">>], ningún seed admite overwrite en primer lane. Tras 256 visitas la campaña para **antes del primer bitflip**, aunque solo los seeds iniciales tienen 5120 candidatos bitflip.

La ejecución real dio calibrations=256, executions=0, generated_candidates=0, infrastructure_failures=0, status={mutation_exhausted,mutation_exhausted}. [edge-cases.log](../../audit-2026-09-12/edge-cases.log), [reproductor](../../audit-2026-09-12/edge-cases.escript), mutation_plan líneas 51–77.

mutations.md advierte que corte idle no demuestra agotamiento matemático. No es implementación de etapa oculta ausente, sino defecto práctico de política de planificación: una configuración normal puede no ejecutar ninguna etapa disponible. Diferenciar motivos de parada y evaluar progreso sobre recorrido completo de lanes relevantes.

### Determinismo de recetas

Seed + Recipe → Input mutado exacto **funciona** para candidato staged realizado. La receta contiene bytes Primary, hash, ID padre, etapa, operaciones concretas, límites, tamaño/hash salida, ID config/diccionario, target_builds, versiones esquema/motor/operación y seed RNG original.

Las decisiones aleatorias ya son offsets, anchos, deltas, tokens literales y bytes donantes. regenerate/1 no selecciona al azar, consulta corpus ni ejecuta objetivo. Comprueba hash Primary, límites, operaciones, tamaño/hash salida. Envoltorio EFZR tiene magic/versión, longitud, SHA-256, escáner ETF acotado y binary_to_term(...,[safe]); rechaza ETF comprimido y objetos runtime.

Reproduce candidato individual exactamente, no reinicia schedule de campaña. No contiene corpus entero, posiciones de otros seeds ni estado completo PRNG/cursores al parar. Hash config es procedencia, no config original serializado. Legacy random se reproduce fijando seeds RNG de mutación/selección en mismo entorno, pero no hay recetas random individuales.

## 9. Gestión de crashes/timeouts

### Clasificación

| Evento objetivo | Outcome | Conducta worker |
|---|---|---|
| Retorno normal de cualquier término | {ok,Term} | Puede fusionar cobertura y retener entrada |
| error(Reason) | {crash,error,Reason,Stack} | Guarda entrada/metadatos exactos y continúa |
| throw(Reason) | {crash,throw,Reason,Stack} | Igual |
| exit(Reason), incluido normal/kill | {exit,Reason} | Guarda, cuenta fallo objetivo; sin stack |
| Exit enlazado no capturado / kill externo | {exit,Reason} desde DOWN | Guarda; origen no distinguido de exit capturado |
| function_clause/case_clause/badmatch/badarg/badarith/undef | Clase error → crash con Reason correspondiente | Sin whitelist especial de excepciones |
| system_limit como error Erlang | Clase error → crash | Agotar memoria VM compartida puede terminar toda la VM; no aislado |
| Deadline | {timeout,TimeoutMs} | Guarda entrada/cobertura parcial; timeouts++, global inalterado |
| Error etiquetado efz_infrastructure / cobertura inválida | {infrastructure,...} o fallo cobertura | Detiene campaña; no cuenta como bug objetivo |
| Error del mutador usuario/salida no binaria | Fallo de infraestructura antes de ejecutar | No se guarda como crash objetivo |

Véase executor líneas 32–39, 62–85; worker 58–107. [Diagnósticos de excepciones](../../audit-2026-09-12/exception_classes.txt) comprueban clasificación catch de motivos lanzados explícitamente; no es agotamiento real de recursos para system_limit. Semántica natural de pattern/guard/try se prueba aparte con fixtures.

Deadline espera target_result y DOWN raíz. Si raíz envió resultado pero no terminó, sigue el timeout restante. Si vence rama timeout, conserva timeout aun con mensaje en carrera. kill_and_drain crea monitor nuevo, espera DOWN real y elimina monitor original con flush. Separa correctamente mensajes tardíos entre casos.

Pero deadline no limita tiempo de pared total de run/4 si bloquea código nativo; receives de limpieza sin watchdog externo independiente. No abarca procesos hijo arbitrarios.

### Fingerprint, deduplicación y archivos

[efz_crash:save/4](../../../src/efz_crash.erl), líneas 6–25:

~~~text
crash ID = SHA256(term_to_binary({Class,Reason,first_3_stack_frames}))
exit ID  = fingerprint(exit,Reason,[])
timeout ID = fingerprint(timeout,deadline,[])

base = crash_dir / hex(crash ID) + "-" + hex(SHA256(Input))
base.input   = exact input bytes
base.term    = ETF #{result=>Result, metadata=>Metadata}
base.recipe  = EFZR, only if metadata contains a staged mutation
~~~

Cobertura exclusiva de crash queda en result. new_probes=[] en metadatos refleja política, no ausencia de cobertura. Crashes en calibración inicial normalmente sin receta: aún no hubo mutación.

Niveles dedup distintos: cada encuentro incrementa crashes/timeouts; unique_crashes viene del conjunto de firmas worker. save ocurre **antes** de comprobar firma, por eso entradas distintas con misma firma reciben archivos distintos, mientras report.crashes solo contiene primer registro de cada firma. Repetir misma entrada/firma sobrescribe mismas rutas. Timeouts de distintas entradas comparten firma pero guardan entradas separadas.

Firma no normaliza rutas, líneas, términos reason ni argumentos stack. Reasons con PID/ref o dependientes de datos pueden dividir un bug en muchas firmas. Mover directorio fuente cambia ruta stack y puede cambiar ID crash del mismo fallo lógico. Identidad build no es componente separado de firma.

### Errores de almacenamiento y reproducibilidad

Escrituras .input, luego .term y .recipe secuenciales, sin temporary+rename/transacción. Caer entre ellas deja conjunto parcial. Errores filelib:ensure_dir/file:write_file/recipe:save tratados con ok=..., tirando worker.

Diagnóstico con crash_dir=/dev/null/efz-audit dio worker_down con {{badmatch,{error,enotdir}},...efz_crash:save/4 line 17...}. infrastructure_failures final siguió 0; entrada desencadenante no guardada en artefacto, informe emergencia solo status/stats/corpus. [Registro](../../audit-2026-09-12/edge-cases.log).

Entrada cruda guardada se ejecuta con recipe:execute_file/5 eligiendo objetivo, artefactos y builds esperados explícitamente. CLI scripts/replay.escript regenera bytes sin ejecutar objetivo. Pasó replay en VM nueva del CRASH de auditoría real y excepción staged estándar.

Garantizar entrada exacta no garantiza mismo crash con estado. Replay comprueba builds seleccionados, no fingerprint de harness separado sin instrumentar, su entorno/dependencias ni estado externo. Replay continuo de campaña entera no implementado.

### Aislamiento de fallos y concurrencia

Al matar abruptamente **llamador/worker**, el coordinador normalmente recibe DOWN y limpia raíz/ETS; probado por phase2/backend. “Owner death cleans target and table” mata llamador, no coordinador dueño de ETS; no confundir escenarios.

Matar **al propio coordinador** impide su after. En auditoría run/4 devolvió {infrastructure,{coordinator_down,killed}}, pero objetivo seguía vivo; lo detuvo el script. [Evidencia](../../audit-2026-09-12/coordinator_kill.txt).

Varios workers hoy imposibles: config exige workers=1, un child spec y servicios singleton. No hay carrera A/B “ambos vieron probe nuevo, ambos retienen” en campaña soportada. Compare/merge e inserción son secuenciales en worker; add y asignación ID son operaciones gen_server seriales. ID crash es hash, sin asignador separado.

No demuestra preparación para workers>1. Cada worker tendría GlobalCoverage propio; compare/merge no es transacción compartida con corpus y escrituras crash no sincronizadas. Plan preparado y contextos admiten lecturas concurrentes/ejecuciones separadas, como prueban tests, pero no existe planificación/feedback concurrente compartido.

## 10. Matriz de integración de componentes

“Funciona” se refiere a conexión concreta. Dos extremos sin llamada runtime no cuentan como integración.

| Productor | Salida | Consumidor | Conexión | Funciona | Evidencia |
|---|---|---|---|---|---|
| CLI / llamador | Mapa config | efz_config | Escript → efz:start → fuzzer:start_link → config:prepare | PARTIAL: ejemplos/API sí, sin CLI común | efz.erl:3–7; fuzzer:6–10; examples/* |
| Config | Atom objetivo, artefactos | Cargador harness / ejecutor | preflight + ensure_loaded + valida export run/1 | SÍ en contrato fijo | config:35–48 |
| Archivo seed | Binario | Corpus inicial | Llamador file:read_file → seeds | PARTIAL: glue externo, sin importador integrado | audit run.escript:e2e/2; corpus:init/1 |
| Corpus | Entrada completa / entradas id,input | Mutador | select/0 random; mutation_entries/0 staged | SÍ | worker:33–49 |
| Mutador | Binario + procedencia staged | Worker | Mu:mutate/2 / mutation_plan:next/2 | SÍ | worker:35–52; EUnit phase3 |
| Worker | Binario, módulo, timeout, opciones | Ejecutor | Llamada síncrona efz_executor:run/4 | SÍ | worker:58–60 |
| Ejecutor / worker | Binario exacto | Harness | Raíz nueva monitorizada → M:run(Input) | SÍ | executor:31–40; 41 entregas exactas |
| Harness | Binario / argumentos específicos | Objetivo | Llamada Erlang síncrona normal | SÍ para harness funcional; config no verifica vínculo | audit_harness:run/1; adaptador Cowboy |
| Ejecución objetivo | Identidad probe | Cobertura | efz_cov_rt:hit/1 generado → ETS adjunta | SÍ, ámbito raíz | PT:probe/4; cov_rt:hit/1 |
| Ejecución hijo | Evento probe | Cobertura de entrada paterna | Contexto no heredado automáticamente | NO | Diagnósticos child/linked_child |
| Cobertura | Snapshot exacto + estado/builds | Feedback | Resultado ejecutor → evaluate/3 | SÍ | worker:60–65; pruebas diferenciales |
| Feedback | new_coverage + delta | Corpus | worker retain → corpus:add | SÍ, RAM | worker:87–91; e2e A/AB/ABC |
| Corpus | Entrada recién insertada | Scheduler | Entradas actuales disponibles a select/siguientes rondas | SÍ, hasta corte idle / stop | corpus:12–14; plan:63–76; evidencia ascendencia |
| Scheduler | Padre + lane/índice/conjunto donantes | Mutador | plan visit/attempts o random select | PARTIAL: funciona, agotamiento idle prematuro | edge-cases.log |
| Corpus acumulado | Binario/hash donante | Splice | entries → usort donantes salvo Primary | SÍ | mutation_plan:152–157 |
| Entrada satisfactoria interesante | Binario/meta/receta | Corpus en archivos | Ausente | NO | corpus:13 solo append en estado |
| Corpus en archivos | Seeds/cola/estado | Reinicio | Ausente | NO | corpus:init/1; restart size=1 |
| Excepción/timeout | Outcome, stack, entrada | Almacenamiento crash | worker:record_failure → crash:save | SÍ con almacenamiento operativo | Archivos/replay; fallo almacenamiento es defecto separado |
| Receta | Primary + operaciones concretas | Replay | recipe:regenerate → mutation:apply_operations | SÍ | 40/40 recetas auditadas; pruebas recipe |
| Crash crudo + artefactos compatibles | Binario/conjunto builds | Replay ejecución | recipe:execute_file → executor:run/4 | SÍ en build fijo | fresh-replay.log |
| Informe worker | Mapa | Llamador API | campaign_done → gen_server:reply await | SÍ | fuzzer:26–39 |

La matriz muestra un sistema funcional con ciclo duradero ausente y aislamiento limitado. No se encontró ruptura separada de mutador → ejecutor → cobertura → corpus activo en modo soportado.

## 11. Resultados de validación end-to-end

### Comandos ejecutados

Todos desde efz/. Las comprobaciones estándar usaron el árbol fuente modificado actual; no cambió código de producción.

| Comando | Resultado actual | Evidencia |
|---|---|---|
| erl -noshell con system_info; rebar3 version | OTP 27, ERTS 15.0; Rebar3 3.25.0 | Salida diagnóstica del entorno |
| rebar3 compile | PASS | Aplicación compilada, exit 0 |
| rebar3 eunit | PASS: 62 pruebas | [eunit.log](../../audit-2026-09-12/eunit.log) |
| rebar3 ct | PASS: 3 pruebas | [ct.log](../../audit-2026-09-12/ct.log) |
| rebar3 xref | PASS, exit 0 | [xref.log](../../audit-2026-09-12/xref.log) |
| rebar3 dialyzer | PASS, exit 0; 26 archivos analizados | [dialyzer.log](../../audit-2026-09-12/dialyzer.log) |
| escript examples/automatic/run.escript | PASS: completed, 500 ejecuciones, 4 descubrimientos, 2 crashes, 1 único, 0 infra/timeouts | [Resumen archivado y vínculos padre](../../audit-2026-09-12/random-example-summary.txt); _build/example-report.term |
| escript examples/staged/run.escript | PASS: completed, 200 ejecuciones, 5 descubrimientos, 7 crashes, 1 único; replay real | [staged-example.log](../../audit-2026-09-12/staged-example.log) |
| escript /tmp/efz-audit-20260912/run.escript /tmp/efz-audit-20260912 | PASS assertions diagnósticas; incluye confirmar defectos existentes | e2e.txt y *.txt vecinos |
| escript /tmp/efz-audit-20260912/fresh-replay.escript /tmp/efz-audit-20260912 | PASS, VM nueva, CRASH exacto, un probe automático | [fresh-replay.log](../../audit-2026-09-12/fresh-replay.log) |
| escript /tmp/efz-audit-20260912/edge-cases.escript /tmp/efz-audit-20260912 | Defectos de agotamiento prematuro, config ignorada y almacenamiento reproducidos; exit diagnóstico 0 | [edge-cases.log](../../audit-2026-09-12/edge-cases.log) |
| escript examples/cowboy/run.escript ../cowboy check | BLOCKED prerrequisito, exit 1; NO se ejecutaron 14 comprobaciones objetivo | [cowboy-check.log](../../audit-2026-09-12/cowboy-check.log) |

Error exacto del launcher Cowboy:

~~~text
Missing build artifact: /home/anonymous_usr/erl:fuzz/efz/../cowboy/ebin/cowboy_req.beam
Run make in COWBOY_DIR first.
~~~

No se realizó compilación externa de Cowboy con descarga de dependencias en esta auditoría. No hace falta para demostrar ciclo EFZ propio: un objetivo audit normal real se compiló, instrumentó y ejecutó mediante harness separado. Las 14 comprobaciones Cowboy históricas y cifras de rendimiento documentadas no se presentan como resultados actuales.

### Comprobación de cada paso solicitado

| Paso | Estado | Observación |
|---|---|---|
| 1. Arranca EFZ | PASS | efz:start/1 aceptó audit_harness y artefactos automáticos |
| 2. Carga corpus inicial | PASS vía API existente | Llamador leyó seed.input; corpus id=1, input=<<>> |
| 3. Mutador cambia seed | PASS | dictionary_insert estándar; sin mutador personalizado de prueba |
| 4. Entrada llega al harness | PASS | Observador recibió 41 eventos delivered; igualdad byte a byte para seed + 40 candidatos regenerados |
| 5. Harness llama objetivo | PASS | audit_harness:run/1 → audit_target:parse/1 normal |
| 6. Cambia cobertura | PASS | Probes function_clause distintos para unknown/A/AB/ABC/CRASH |
| 7. Detecta nueva cobertura | PASS | Tres descubrimientos satisfactorios |
| 8. Entrada añadida a corpus | PASS en RAM; sin parte disco | ID 2,3,4 con metadatos new_coverage; núcleo no escribe corpus satisfactorio |
| 9. Entrada nueva elegida como seed | PASS, evidencia directa | AB.parent=2 (A); ABC.parent=3 (AB), confirmado por recetas |
| 10. Crash guardado | PASS | CRASH exacto de cinco bytes, .term y .recipe |
| 11. Replay crash | PASS | regenerate + execute_file; ejecución aparte en VM nueva devolvió error(test_crash) |
| 12. Corpus tras reinicio | FAIL de persistencia requerida | Nueva campaña solo conservó seed inicial: size=1 |

No hubo mock saver ni inserción manual de descubrimiento para suplir persistencia ausente. Se probó ciclo dentro de campaña aparte porque no depende de almacenamiento duradero. Escribir informe final auditado no implementa persistencia de corpus.

La campaña terminó con {mutation_exhausted,mutation_exhausted}, executions=40: **este** experimento agotó realmente todos los dictionary_insert de cuatro entradas (4+8+12+16). Terminación normal, a diferencia del caso separado que dio mismo estado con candidatos bitflip sin ejecutar.

### Pruebas por componente

| Componente | Pruebas existentes | Demostrado / ausente |
|---|---|---|
| Mutador legacy | efz_mutator_tests | Salida binaria/seed vacío; pruebas muy superficiales |
| Primitivas | efz_mutation_tests:operators, limits, bit_model, block_model, boundaries | Vectores concretos, modelos independientes, endian/overflow/límites |
| Plan staged | enumeration, fairness, finite, random_state, noop_stack, growing_corpus, duplicate_donors | Cursores lazy, orden determinista, independencia PRNG, lista crecida manualmente |
| Replay recetas | efz_recipe_tests, phase3 fresh_replay/replay_boundaries | Roundtrip, datos inválidos, VM nueva, crash real |
| Corpus | Campañas Phase2/phase3, smoke, variantes backend | Inserción/informes; sin suite unitaria corpus ni prueba de persistencia |
| Compilador / semántica cobertura | efz_phase2_tests | Tipos de cláusula, mapeo, probes distintos en misma línea, AST strict, outcomes normal/instrumentado, builds |
| Runtime cobertura | efz_backend_tests, ciclo phase2, CT | Variantes ETS, preparado/referencia, contextos simultáneos, kill objetivo/llamador, timeout |
| Errores worker / mutador | phase3:mutator_failure, exhaustion; smoke | Clasificación infraestructura, cuentas de presupuesto/skip |
| Harness | Adaptadores ejemplo + campañas; validación efz_config | run/1 real; sin CLI/cargador fuente genérico |
| Timeout | executor_tests, phase2, backend, CT | DOWN raíz, cobertura conservada, tabla limpiada; sin limpieza árbol |
| Crashes | Campaña Phase2; campaña/replay phase3; CT | Almacenamiento crudo, excepciones, continuación, política de cobertura crash |
| Ciclo completo | Campaña staged real Phase3; scripted phase2/CT | Hay ciclo real, sin assertion estándar explícita “entrada descubierta luego es padre” |

Diferencia clave: phase2/CT usan efz_scripted_mutator que ignora padre y toma candidato predeterminado por iteración. Demuestran feedback/inserción, no ascendencia. Phase3 usa planner real y comprueba descubrimiento/receta/replay; growing_corpus_test añade entradas manualmente sin objetivo/feedback. **La suite no tiene prueba independiente que afirme descubrimiento y posterior uso de esa entrada exacta.** El reproductor auditado ya contiene tal prueba, pero no integra rebar3 eunit/ct.

### Reproducción de diagnósticos auditados

Fuentes diagnósticas guardadas en docs/audit-2026-09-12. No están en src_dirs, no modifican EFZ ni son feature nueva. run.escript comprueba intencionadamente limitaciones actuales y limpia sus procesos de prueba fugados.

~~~sh
rebar3 compile
EFZ_AUDIT_DIR=$(mktemp -d /tmp/efz-full-audit.XXXXXX)
cp docs/audit-2026-09-12/audit_*.erl "$EFZ_AUDIT_DIR/"
cp docs/audit-2026-09-12/*.escript "$EFZ_AUDIT_DIR/"
escript "$EFZ_AUDIT_DIR/run.escript" "$EFZ_AUDIT_DIR"
escript "$EFZ_AUDIT_DIR/fresh-replay.escript" "$EFZ_AUDIT_DIR"
escript "$EFZ_AUDIT_DIR/edge-cases.escript" "$EFZ_AUDIT_DIR"
~~~

Cada escript usa VM separada. Tras arreglar defectos deben actualizarse assertions negativas; PASS diagnóstico actual no significa “sin bugs”.

## 12. Código muerto / implementaciones paralelas

| Implementaciones de un concepto | Conexión runtime | Decisión posterior |
|---|---|---|
| efz_mutator_random / efz_mutation_plan + efz_mutation | Ambas usadas: random predeterminado y staged opt-in | KEEP ambas ahora; MIGRATE recomendación a staged verificado después de P0; no retirar compatibilidad abruptamente |
| efz_executor:run/3 / run/4 | run/3 envuelve run/4 con cobertura manual; no otro runner | KEEP; documentar pérdida de metadatos en wrapper |
| Manual efz_cov:hit / hooks PT automáticos | Runtime/ETS común; namespace manual distinto | KEEP como compatibilidad explícita; DEPRECATE manual en nuevas campañas automáticas |
| ETS insert / ets_member | Selector backend dentro de mismo cov_rt/context/executor | KEEP; ya hay diferenciales |
| Validación por ejecución / preparada | Igual contrato whitelist; preparada predeterminada | KEEP referencia para corrección diferencial |
| efz_cov:interesting/2 / efz_feedback:evaluate/3 | Primer helper no llamado, decisión autoritativa en segundo | DEPRECATE helper no usado; DELETE solo tras comprobar externos |
| efz_cov:reset_local/0, snapshot/0 | Helpers legacy sin uso en campañas/pruebas actuales | DEPRECATE. reset_local no limpia contexto existente: repetir lanza context_already_attached |
| efz_stats:handle_cast({inc,...}) / inc público por call | Hay handler cast, API usa call síncrono | DELETE o documentar tras revisar consumidores; no afecta ciclo actual |
| efz_scripted_mutator / bench:efz_perf_replay / mutadores producción | Scripted/replay pregrabado solo en tests/bench | KEEP para medición/fixtures exactos; no presentar como búsqueda real de mutaciones |
| bench/efz_perf*, scripts de informes/profile | Cargados explícitamente por escripts, no servicios OTP | KEEP separados del núcleo |
| Propuesta documental de recolector calibración/estabilidad | Sin módulos de producción correspondientes | KEEP como diseño; no contar como componente implementado |
| efz.worktrees/agents-condemned-silverfish | Misma copia snapshot, no otro runtime | KEEP según propietario; no borrar en auditoría |

No se encontraron varios corpus, pool antiguo oculto, segundo recolector ni otro lenguaje de orquestación. UNUSED se limita al repositorio actual; un export permite llamadores externos teóricos.

## 13. Defectos y carencias arquitectónicas

### Tres carencias principales

**G1. Ciclo de campaña utilizable incompleto.** La API recibe bytes y conserva progreso satisfactorio en RAM; no implementa flujo común objetivo/config + directorio seed → corpus duradero → reinicio. Retain→reuse runtime ya funciona. Lugares: efz.erl, efz_config.erl, efz_corpus.erl, launchers de ejemplo.

**G2. Contrato de integridad ejecución/cobertura incompleto.** Aislamiento raíz correcto en ruta normal, pero hijos asíncronos, pérdida de coordinador, estado compartido e instrumentación desconectada/reemplazada impiden atribución fiable a entrada. Importa especialmente en Erlang/OTP, con trabajo útil frecuente en otros procesos. Lugares: executor, cov_rt, cov_manifest, instrument, contrato harness.

**G3. Progreso scheduler y prueba de regresión.** Motor staged integrado y reproducible, pero corte idle global puede detener antes de lanes útiles. Las pruebas estándar no afirman ascendencia seed descubierto → siguiente mutación y omiten defecto. Lugares: mutation_plan:next/visit, ruta staged worker, pruebas phase3/mutación.

### Hallazgos concretos

| ID / prioridad | Hallazgo y consecuencia | Evidencia / confianza |
|---|---|---|
| F01 / P0 | Corpus satisfactorio no sobrevive reinicio; resultado principal se pierde sin informe/export externo | corpus:9–14; reinicio real tamaño 4→1 |
| F02 / P0 | Corte idle global detiene etapas disponibles; 256 seeds válidos dan 0 mutaciones | mutation_plan:51–77; campaña real edge-cases |
| F03 / P1 | Kill del coordinador deja raíz viva tras devolver infraestructura | executor:9–23,31–60; coordinator_kill.txt |
| F04 / P1 | Sin cobertura/limpieza hijos; hijo sobrevive timeout | executor:31–85; child_timeout.txt, linked_child.txt |
| F05 / P1 | Estado compartido cambia cobertura al repetir entrada idéntica | Sin reset ejecutor; cross_case_state.txt |
| F06 / P1 | Artefactos válidos no llamados dan completed/vacío sin diagnóstico de desconexión | config:35–48; validador manifest; disconnected_artifacts.txt |
| F07 / P1 | Reemplazo normal en caliente no invalida builds preparados; harness separado no fijado | instrument:115–127; manifest:72–85; recipe:97–108; hot_reload.txt |
| F08 / P1 | Contexto malformado capturado puede dar cobertura vacía satisfactoria | cov_rt:26–27; caught_malformed_context.txt |
| F09 / P1 | Error almacenamiento tira worker; sin grupo atómico; desencadenante puede perderse | crash:17–23; edge-cases enotdir |
| F10 / P1 | function/arity/max_input_bytes/corpus_dir superiores aceptados pero ignorados | config:7–15,29–33; edge-cases IGNORED_CONFIG |
| F11 / P1 | Tamaño random sin límite contractual común; entrada guardada >1MiB no pasa API execute_file | config:29–33, worker:37 vs recipe:87,113–114; solo código |
| F12 / P2 | Informe worker_down con infra=0; build mismatch puede ocultar coordinator_down | fuzzer:34–39; feedback:5–7,22; evidencia enotdir / código |
| F13 / P2 | Sin deduplicación inicial; ID duplicados comparten cursor staged de contenido | corpus:9–14; plan:68; duplicate_initial_seeds.txt |
| F14 / P2 | Decisiones de fallo crecen con cada repetición, incluso una firma única; presupuesto random predeterminado infinity | worker:75–79,94–105; defaults config; solo código |
| F15 / P2 | Firma incluye rutas stack/reasons inestables; mismo bug puede tener ID distintos | crash:fingerprint/3; solo código |
| F16 / P1 carencia de prueba | Sin assertion E2E directa de ascendencia, persistencia/reinicio ni regresión árbol/kill propietario estándar | Revisión de todos los módulos; nuevo reproductor auditado |

No toda limitación contradice documentación: ámbito raíz, build fijo, launcher manual y corte idle acotado están descritos. Siguen siendo límites reales respecto al pipeline completo solicitado. Las conclusiones vienen del recorrido de llamadas y la ejecución actual.

No hay evidencia CI para árbol actual; 62+3 comprobaciones locales satisfactorias no demuestran CI remoto correcto ni aptitud para objetivos OTP arbitrarios.

## 14. Evaluación de madurez

Escala: 0 — ausente; 1 — fragmento mínimo; 2 — parcialmente funcional; 3 — MVP con límites importantes; 4 — subsistema funcional verificado en ámbito declarado; 5 — contrato completo requerido con regresiones y ciclo robusto. Las notas no son benchmarks.

| Componente | Nota 0–5 | Motivo |
|---|---:|---|
| API harness | 3 | Behavior run/1 real, validación y adaptadores; sin launcher/cargador fuente genérico/reset, selección solo módulo |
| Entrega entrada | 4 | Binarios exactos confirmados por 41 entregas; sin límites uniformes/replay ni importación de archivos |
| Aislamiento ejecución | 1 | Solo raíz/coordinador nuevos; hijos/estado compartido/fallos VM no aislados, kill propietario deja raíz |
| Recolección cobertura | 4 | Probes fuente exactos por ejecución, mapeo manifest, pruebas backend/ciclo; solo raíz y AST limitado |
| Feedback cobertura | 4 | Diferencia/unión exactas y política fallo funcionan; sin validación de estabilidad ni detección de código desconectado |
| Gestión corpus | 2 | Append/dedup/select/metadatos RAM; sin persistencia, reinicio, dedup inicial ni metadatos de ciclo |
| Feedback loop corpus | 4 | A→AB→ABC demostrado; nota de ciclo RAM activo, no flujo duradero; corte scheduler limita otras campañas |
| Motor mutación | 3 | Primitivas/etapas/havoc/splice/recetas amplios y modelos; defecto importante de agotamiento |
| Gestión crash | 3 | Almacenamiento/continuación error/throw/exit/timeout funcionan; escritura no atómica, fallos más débiles, caída VM no cubierta |
| Reproducibilidad | 4 | Mutación staged exacta y crash replay en VM nueva; sin recetas random/reanudación/fijación harness |
| Seguridad concurrencia | 3 | Ruta serial un worker y ETS acotada probadas; varios workers rechazados, ciclo árbol sin resolver |
| Integración end-to-end | 3 | Ciclo núcleo cerrado; empaquetado, persistencia y aislamiento OTP amplio pendientes |

Madurez actual: MVP de investigación integrado para objetivos síncronos acotados. Es incorrecto describir EFZ como prototipos desconectados; también es prematuro declararlo fuzzer universal de aplicaciones OTP listo.

## 15. Dirección recomendada

**Fase siguiente: campaña fiable, duradera y verificable de un worker sobre motor existente.**

P0 debe establecer el feedback loop funcional y eliminar casos donde config válida impide trabajar: ascendencia E2E, agotamiento prematuro, importación real de seeds, retención duradera y reutilización tras reinicio. Hace falta launcher universal mínimo sobre run/1, no framework harness nuevo.

P1 trata corrección de fronteras: límites byte uniformes, almacenamiento atómico con errores explícitos, limpieza raíz/descendientes, violaciones de instrumentación, builds objetivo/harness fijados y replay reproducible. Primer modelo soportado debe definir harness binario síncrono; no pasar implícitamente a OTP arbitrario con spawn sin contexto.

Calibración repetida puede ser siguiente feature de corrección útil, pero completar el ciclo no requiere recolector nuevo grande. Primero identidad fuente fiable, ámbito por entrada y limpieza. calibration-readiness.md sirve de requisitos, no prueba de estabilidad implementada.

Trabajo de rendimiento P2 — índice corpus, coste mutation_entries/0, conversiones binarias, ajuste hooks ETS — después del gate de corrección. Schedules avanzados P3 y distribuido/UI P4 fuera de fase propuesta.

## 16. Plan de implementación priorizado

Solo propuesta de fase siguiente. Esta auditoría no cambió implementación de producción.

| Tarea | Problema resuelto | Archivos/módulos | Conducta esperada | Prueba/evidencia | Prioridad |
|---|---|---|---|---|---|
| T1. Gate estándar de linaje end-to-end | Pruebas no demuestran reutilizar descubrimiento | test/efz_phase3_tests.erl o suite nueva; fixture/harness sencillo | Mutador staged real obtiene A, lo retiene y ese A produce AB; AB puede producir ABC; bytes fijos hasta harness y cobertura real | Assert ID padre + bytes/hash primary + salida receta; sin scripted; replay nuevo separado | P0 |
| T2. Corregir criterio sin progreso | max_idle_visits para antes de lane útil | src/efz_mutation_plan.erl; test/efz_mutation_tests.erl; integración | Etapa no disponible no impide visitar disponible; agotamiento real y presupuesto idle con motivos distintos; búsqueda vacía finita acotada | Reproductor 256 seeds ejecuta bitflip; casos corpus/diccionario vacío/sin donante y barrido realmente agotado | P0 |
| T3. Launcher común mínimo + esquema estricto | Usuario no especifica normalmente fuente/code path harness, directorio seeds/outdir; claves ignoradas | Nuevo scripts/fuzz.escript o efz_cli; src/efz_config.erl, README, ejemplos | CLI/config elige módulo run/1, paths/artefactos, seeds, mutación, límites, timeout, salida; bytes sin transformar; rechaza desconocidos | Black-box VM nueva con run/1 externo mínimo; módulo/export/archivo ausente, config inválida y sin artefactos | P0 |
| T4. Retención/restauración duradera corpus | Descubrimientos perdidos con stop/restart | src/efz_corpus.erl, src/efz_worker.erl, config; almacén acotado nuevo si precisa | .input exacto direccionado por contenido + metadatos versionados antes de ACK duradero; inserción activa; reinicio carga descubrimientos sin duplicados | Kill/restart tras descubrir A → cargado y padre; corrupción/parciales detectados; política builds explícita | P0 |
| T5. Contrato uniforme entrada/fallo almacenamiento | Random sin límite; escritura crash pierde contexto; artefactos parciales | config, worker, crash, recipe, corpus store | Máximo igual seeds/mutaciones/replay; registros atómicos; errores estructurados con entrada/hash y operación/ruta; informe no muestra 0 infra como éxito | Fronteras 0/max/max+1; enotdir/solo lectura/fallo; crash exacto con almacén funcional; recuperación de interrupción | P1 |
| T6. Confirmar limpieza | Pérdida coordinador/timeout deja raíz/hijos | executor, contrato objetivo; pruebas ciclo; runner/guardián separado si precisa | Propiedad de limpieza sobrevive; DOWN confirmado de raíz y descendientes soportados. Sin limpieza segura no se reutiliza runner sucio; ámbito async general exige VM aislada destruida al perder control | Kill propietario, root trap_exit, hijos con/sin link, timeout/cancel; sin objetivos vivos tras completar/abortar; A→B→A con política estado definida | P1 |
| T7. Aclarar validez cobertura/harness | Vacío oculta desconexión; hot reload/corrupción PD invisibles | config, instrument, cov_manifest, cov_rt, executor; pruebas/docs | Identidad harness/builds fijados; violación detectada; ausencia total de feedback diagnosticada. Vacío legítimo distinto de snapshot ausente/roto; metadatos de ámbito/terminación/limpieza | Artefacto sin usar, reemplazo normal, contexto borrado/malformado, vacío válido; fail closed de instrumentación inválida | P1 |
| T8. Completar contrato crash/replay/informe | Firmas dinámicas, decisiones ilimitadas, orígenes distintos | crash, worker, fuzzer, stats, recipe, scripts/replay.escript | Entrada cruda autoritativa; firma separada de ocurrencia/procedencia; fallos acotados/agregados; causa primaria y contadores conservados; CLI replay verifica objetivo+harness | Repetir firma con entradas distintas; replay mismo build/rechazo mismatch; contador/motivo worker_down; prueba larga de informe acotado | P1 |
| T9. Gate reproducible release | Checks locales no automáticos, carencias reaparecen | CI de plataforma elegida, rebar.config si precisa, docs | compile/EUnit/CT/xref/Dialyzer + T1/T2/storage/restart/lifecycle en OTP declarado; suite Cowboy auxiliar aparte | Logs/artefactos CI con identidad fuente/build, comandos exactos, testigo ascendencia y replay nuevo | P1 |

En T4, restauración mínima correcta carga entradas persistidas y recalibra otra campaña. No llamarla “continuación exacta del schedule anterior” sin serializar/versionar por separado cobertura global, ID, cursores y RNG. Checkpoint completo puede ser paso posterior tras demostrar corpus reutilizable en disco.

En T6, no se acepta limpieza de árbol solo diciendo “hijos fuera de ámbito”. Antes de runner async general puede limitarse explícitamente objetivos y rechazar violaciones; si versión siguiente promete continuar en misma VM tras timeout async, debe implementar y probar esa limpieza.

## 17. Criterios de aceptación de fase siguiente

Esta checklist es gate de release siguiente. Algunos puntos ya se cumplen en ámbito síncrono RAM actual, pero todos deben confirmarse automáticamente sobre implementación final.

- [ ] EFZ acepta objetivo/harness por CLI/config común; contrato explícito, módulo/export y artefactos comprobados.
- [ ] Archivo seed inicial leído como binario y presente en corpus; duplicados/rutas inválidas tratados determinísticamente.
- [ ] Seed del corpus pasa al motor de mutación estándar.
- [ ] Binario mutado coincide byte a byte con recibido por harness.
- [ ] Harness llama objetivo instrumentado real; desconexión completa diagnosticada.
- [ ] Cobertura separada por entrada con identidad build/fuente validada.
- [ ] Cobertura no contamina otras entradas; ámbito/estado compartido comprobados; ausente/roto no aceptado como vacío válido.
- [ ] Cobertura nueva = CurrentCoverage − GlobalCoverage para outcomes satisfactorios; global actualizado determinísticamente.
- [ ] Entrada de cobertura nueva guardada en disco y añadida al corpus con metadatos padre/contenido/build.
- [ ] **Esta entrada nueva descubierta por cobertura se selecciona realmente como padre de siguiente mutación; la prueba comprueba ID, bytes primary exactos y resultado.**
- [ ] Reinicio carga descubrimiento y lo deja disponible como padre; restauración distinta de reanudación exacta.
- [ ] Scheduler no declara agotamiento antes de visitar etapa productiva disponible; regresión 256 seeds ejecuta mutaciones reales.
- [ ] Crash guarda entrada exacta; fallo de almacenamiento da infraestructura explícita y conserva explicación.
- [ ] Crash guardado reproducido en VM nueva con builds objetivo/harness compatibles.
- [ ] Receta reconstruye determinísticamente entrada sin corpus vivo ni RNG; rechaza mismatch/corrupción.
- [ ] Timeout/cancel/pérdida coordinador no deja objetivos vivos en modelo soportado incluidos descendientes; limpieza no probada prohíbe reutilizar runner.
- [ ] Instrumentación inválida, fallo mutación, objetivo e infraestructura diferenciados en informe/contadores.
- [ ] Integración confirma ciclo entero, disco, reutilización tras reinicio y replay nuevo sin mocks objetivo/mutador/cobertura/corpus.

**Criterio de cierre:** una prueba reproducible pasa archivo seed → mutación real → harness/objetivo real → cobertura por entrada → descubrimiento satisfactorio → corpus duradero + activo → mutación desde padre descubierto; otra ejecución usa la misma entrada persistida. La auditoría ya demostró la parte interna, por lo que la fase siguiente debe conservarla y resolver las carencias identificadas.
