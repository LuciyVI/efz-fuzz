# Auditoría de preparación de EFZ para calibración y feature_stability

[English](../../calibration-readiness.md) · [Русский](../ru/calibration-readiness.md) · **Español** · [简体中文](../zh-CN/calibration-readiness.md) · [Todos los idiomas](../README.md)

Fecha: 2026-09-09. **Veredicto: READY WITH PREREQUISITES.**

Para una compilación fija, un objetivo cooperativo y un ámbito de **un solo proceso objetivo**, ya existen conjuntos completos y exactos de observaciones por ejecución. No hacen falta otro ejecutor, un backend nuevo, contadores de impactos ni buckets. Una integración fiable requiere primero una causa explícita de terminación y contratos de completitud, limpieza y gestión de la pérdida del runner; después, un recolector independiente de repeticiones que no invoque la novedad en cada repetición.

Para un árbol arbitrario de procesos, una aplicación OTP con estado, cobertura nativa/NIF o recuperación tras una caída de toda la VM, la implementación actual está **NOT READY**: esos contratos/runners no existen. Es una limitación de ámbito, no un motivo para representar su cobertura como vacía y obtener un 100%.

El mecanismo de calibración **no se implementó** en esta tarea. No cambiaron el código de producción, las API, las dependencias, los valores predeterminados ni los algoritmos de búsqueda. El único archivo nuevo permanente es este informe. Los fixtures, scripts de diagnóstico y registros están en `/tmp/efz-calibration-audit.rIBEql/`; sus fuentes figuran en el apéndice para reproducirlos después de eliminar el directorio temporal.

Notación de evidencias: **C** — encontrado en el código actual; **E** — confirmado por una ejecución nueva; **D** — afirmación de la documentación; **P** — propuesto, todavía sin implementar; **NV** — no verificado. Las mediciones históricas no se consideran resultados de esta auditoría.

## 1. Checkout, herramientas y arquitectura actual

**C/E.** Repositorio: `efz/`, rama `main`, HEAD `ac09c1f3e938c3a79b369fc6a87d61c1ae739db4` (`chore: initialize efz OTP project`). El commit no describe toda la implementación examinada: el árbol inicial ya tenía cambios en `README.md`, `rebar.config`, `src/efz.app.src`, directorios sin seguimiento `bench/`, `docs/`, `examples/`, `fixtures/`, `scripts/`, `test/` y la mayoría de los módulos `src/efz_*.erl`. El estado/diff inicial completo se conserva en [status.txt](/tmp/efz-calibration-audit.rIBEql/status.txt) y [diff.txt](/tmp/efz-calibration-audit.rIBEql/diff.txt).

Antes de ejecutar se capturaron los SHA-256 de los 78 archivos existentes enumerados por `git ls-files --cached --others --exclude-standard`. Su contenido coincidía después de los experimentos. Ninguno cambió antes de añadir este informe. No se realizaron operaciones reset/clean/stage/commit/push ni cambios en la identidad o los remotos de Git. No se encontraron archivos `AGENTS.md` aplicables en el repositorio ni en los directorios superiores comprobados.

Hash de la lista del árbol fuente (líneas UTF-8 ordenadas `path + NUL + file_sha256 + LF`): `24eafa7e45d6584b1ff2eb03021391c3e299b95df2a51ab7041726c9a612cf23`. La lista completa está en [before-sha256.json](/tmp/efz-calibration-audit.rIBEql/before-sha256.json). Archivos clave que vinculan las conclusiones al checkout modificado:

| Archivo | SHA-256 |
|---|---|
| `src/efz_executor.erl` | `c4a7802a9ac299445b5b6b50fd1ded92ae09e814ad25f4f300054503e6745f47` |
| `src/efz_cov.erl` | `2d32b0aca9c1641e40ab111e844d020004fb5cb9b743d76c40a46385fa4489d0` |
| `src/efz_cov_rt.erl` | `47e84c8f84861ff7ec7817fa34b9b1234af571ce3bf316fe3d2867428dcfb466` |
| `src/efz_cov_manifest.erl` | `4951ecc1f7104fca08928ee7dfa669cfacc8b27cac856961db06f9ea14451544` |
| `src/efz_feedback.erl` | `0be0ecc64e967b776cc990259d569539e520ba7f603e838c444cdd44e2b30bb6` |
| `src/efz_worker.erl` | `3e4f4d383f86b0bfe9af2d6a366fda848818dcb33f85652efd69d325a9e3baa4` |
| `src/efz_instrument.erl` | `c4dfbe3b9caadfc4ed60153d1a6573b152f31fc5b95e34a168a6bea730695351` |
| `src/efz_instrument_pt.erl` | `b781f83981aef57f59a79c42c099a07076002434ceecd2ecef8feb05930766cd` |

**E.** `rebar3 version`: Rebar3 3.25.0, OTP 27 / ERTS 15.0. `releases/27/OTP_VERSION` contiene `27.0`. Arquitectura: `x86_64-pc-linux-gnu`, Linux. La VM habitual de la auditoría tenía **16 schedulers, 16 en línea**; `ERL_FLAGS`, `ERL_AFLAGS`, `ERL_COMPILER_OPTIONS` no estaban definidas. El script principal de diagnóstico y sus tres VM nuevas también registraron 16 en línea. No se trasladó aquí el valor 4 de Phase 2.1. Los helpers EUnit existentes para VM nuevas usan explícitamente dos schedulers; son ajustes de pruebas independientes, no la configuración de la medición principal.

**C.** [rebar.config](../../../rebar.config), líneas 1–14: mínimo OTP 27, `debug_info,warnings_as_errors`, `src_dirs = ["src","examples/simple_parser"]`, `deps = []`; `rebar.lock` está vacío. No hay perfiles de proyecto con nombre. `compile` usa default; EUnit/CT usan el perfil test estándar de Rebar3. En el árbol actual no se encontraron configuración CI de GitHub/GitLab, Makefile independiente, módulo/controlador Go ni capa de control Python. El README enumera comandos rebar locales; no demuestra una ejecución CI. No hay formateador/linter configurado.

**C/E.** Esta es una única implementación OTP de EFZ nativa de Erlang:

```text
escript / Erlang caller
  efz:start/1 -> efz_sup -> efz_fuzzer
                              |-> efz_corpus (entries, selector RNG)
                              |-> efz_stats
                              `-> efz_worker_sup -> one efz_worker
                                       |-> prepared validation plan
                                       |-> random / staged mutation state
                                       `-> efz_executor:run/4
                                              -> coordinator -> target process
```

`src/efz.erl:start/1`, líneas 3–7; `efz_fuzzer:init/1`, líneas 17–25; `efz_worker_sup:init/1`, línea 2. La aplicación `efz`, versión 0.1.0, depende de `kernel`, `stdlib`, `crypto` (`src/efz.app.src:1–18`). Usar crypto no implica soporte de cobertura nativa.

| Término buscado | Hallazgos |
|---|---|
| EFZ/ErlFuzz, Go controller, `input_coverage` | El runtime actual usa EFZ y Erlang; no se encontraron los demás nombres/modo |
| `efz_instrument`, `efz_cov`, `efz_feedback`, `efz_executor` | Presentes |
| `efz_cov_runtime`, `efz_run_context` | La implementación real es `efz_cov_rt` y un contexto en tupla en `efz_cov`; no hay módulos con los nombres indicados |
| `efz_value_runtime`, `efz_hook_runtime`, `efz_data` | No encontrados; no existe feedback de valores/transiciones |
| `execution_ref`, `builds`, `coverage_status`, `elapsed_us`, `target_outcome` | Presentes en el resultado de `run/4`, pero la rama de fallo puede carecer de `target_outcome` |
| `input_id` | SHA-256 de la entrada en metadatos de worker/corpus, no un campo del resultado normal del ejecutor |
| `cleanup_status`, generation, layout digest, `feedback_epoch` | Ausentes; no deben atribuirse al contrato existente |
| `RunRef` | Existen un `Request` interno y un `Ref` de contexto independiente; ninguno proporciona un ID de entrada portable |

**C/E.** Valores predeterminados confirmados por `efz_config:defaults/0`, líneas 4–6, y el runtime: `coverage => automatic`, `coverage_validation => prepared`, `coverage_backend => ets`, `workers => 1`, `mutation_mode => random`, timeout de 100 ms. `ets_member` se permite explícitamente; `per_execution` es un modo alternativo de validación. Son dos ejes independientes, no cuatro espacios de features distintos. `run/4` de bajo nivel no crea por sí mismo un plan preparado: el llamador aporta `coverage_plan` o `manifests`. `run/3` usa compatibilidad manual y devuelve solo el outcome.

**C/E.** `seed_calibration` es **una ejecución de cada seed inicial**: `efz_worker:init/1`, líneas 20–24, `handle_info/2`, 26–30; `efz_feedback:evaluate/3`, 9–17. Una comprobación con dos seeds y cero mutaciones produjo `calibrations=2, executions=0, discoveries=0`, con dos motivos `seed_calibration`. Actualmente no hay R repeticiones, intersección/frecuencias ni métrica de estabilidad. “Calibrates” en el README significa este procesamiento inicial, no una evaluación repetida de estabilidad.

## 2. Recorrido real del testcase y propiedad del estado

Enlaces al código principal: [ejecutor](../../../src/efz_executor.erl), [contexto de cobertura](../../../src/efz_cov.erl), [hook](../../../src/efz_cov_rt.erl), [worker](../../../src/efz_worker.erl), [feedback](../../../src/efz_feedback.erl).

```text
Before measurement:
  config + artifacts preflight; load selected BEAM; create plan once
  take seed unchanged OR corpus selection -> mutation -> binary/recipe

For one run/4:
  caller creates Request, spawn_monitor(coordinator)
    coordinator monitor(caller)
    open: new context Ref + new public ETS         [before Started]
    Started = monotonic_time(microsecond)
    spawn_monitor(target)
      attach(Context) -> M:run(Input)
      selected module bodies -> synchronous ETS membership publications
      outcome / caught error, throw, exit
      target_result{Ref, target PID, Outcome}
    wait: result + target DOWN, or DOWN/timeout/caller DOWN
    timeout/cancel -> kill(target) + confirmed DOWN
    ordinary branch: sticky failure -> snapshot -> identity validation -> result
    send result to caller                         [still before finally cleanup]
    after: repeat kill_and_drain -> close ETS -> demonitor caller
    coordinator terminates
  caller waits for coordinator DOWN before returning from run/4

After run/4:
  worker increments calibration OR mutation execution counter
  feedback(status, outcome, builds, Observed) -> novelty/merge decision
  corpus add for new successful input; crash storage separate
  decisions/statistics; next iteration
```

**C.** `elapsed_us` comienza después de `efz_cov:open/1` e incluye el arranque del objetivo, attach, `M:run/1`, la espera de terminación y la lectura/validación del snapshot; termina antes de `builds(Options)`/el envío del resultado y la limpieza finally (`efz_executor:coordinate/6:28–59`). No es tiempo puro del objetivo ni tiempo total de pared de `run/4`. La llamada síncrona completa incluye asignación del contexto y limpieza. El deadline en `wait_target/5:62–79` se mide por separado en milisegundos tras crear el objetivo; no garantiza un límite superior de tiempo de pared si una llamada nativa queda bloqueada.

**C.** No existen decodificador común, `before_input`, reinicio del estado del objetivo, `after_input` ni callback de limpieza del objetivo. Los seeds son binarios y las mutaciones devuelven binarios; la receta staged se compone antes del ejecutor (`efz_worker:staged_iteration/1:42–52`). Las comprobaciones de tamaño y diccionario están fuera de la cobertura. `run/4` de bajo nivel acepta cualquier término Erlang como `Input` y lo pasa directamente a `M:run/1`; las tuplas de diagnóstico con PID usan este punto de conexión de bajo nivel, no una nueva API de campaña. La lectura/regeneración/preflight de replay ocurren antes de la ejecución (`efz_recipe:execute/5`, `execute_file/5`, líneas 85–114).

**C.** El ámbito de las features son los cuerpos de los módulos seleccionados llamados por el proceso después de attach. Por tanto, también se mide el decodificador/setup dentro del `M:run/1` seleccionado, si existe. El `try ... after` del objetivo se mide hasta la terminación normal/con excepción; kill forzado no garantiza la limpieza del objetivo. El propio transform excluye de la allowlist el hook EFZ, ejecutor, recolector de estadísticas y transform (`efz_instrument_pt:parse_transform/2:26–33`). La compilación/carga antes de attach y la limpieza del coordinador tras DOWN no añaden probes EFZ. Un adaptador seleccionado por el usuario puede añadir probes compartidos propios; regístrelo en la allowlist en vez de restar esas features después de calcular un porcentaje.

| Estado/recurso | Propietario y duración | Garantía / límite |
|---|---|---|
| Corpus y RNG del selector | `efz_corpus` gen_server; duración de campaña | Orden de inserción; selector aleatorio o planner staged; `src/efz_corpus.erl:5–14` |
| RNG/cursores de mutación, novedad global, decisiones | `efz_worker` | No deben cambiar por repeticiones de estabilidad; `worker:7–24,42–56,108–125` |
| Plan preparado | Worker; llamador offline de `prepare/2` | ETS protegida sin nombre; hasta release/muerte del propietario; no es un búfer de observaciones |
| Request y monitor del coordinador | Llamador de `run/4:7–24` | Respuesta vinculada a Request/PID; espera la terminación del coordinador |
| Ref de contexto y conjunto ETS público | Coordinador `coordinate/6:26–29`; `cov:open/0:11–13` | ETS sobrevive al objetivo y se destruye con su propietario; sin heir |
| Referencia de contexto en PD | Solo el objetivo después de attach | No es el único almacén de impactos; los hijos no la heredan |
| Monitores de llamador/objetivo, deadlines | Coordinador, `wait_target/5`, `kill_and_drain/2` | `receive after`, no un proceso/puerto temporizador; monitor nuevo independiente durante la limpieza |
| Lista snapshot | Coordinador, luego copia del resultado en el llamador | Lista Erlang inmutable; sobrevive a eliminar ETS; datos anteriores a la novedad |
| Puertos en el ejecutor de producción | Ausentes | Los puertos para VM nuevas en pruebas/auditoría pertenecen al escript externo de diagnóstico |
| Hijos, servidores OTP, temporizadores del objetivo, recursos externos | No gestionados por el ejecutor | Sin lista de árbol objetivo, barrera ACK de hijos ni reset común |

### Qué demuestra realmente la quiescencia

**C/E.** Un `ets:insert` síncrono completado publica presencia antes de que vuelva el hook. `target_result` no basta: el ejecutor también espera monitor DOWN. Timeout/cancel llaman a `exit(Target,kill)` y esperan el DOWN de un monitor nuevo sin pausas (`kill_and_drain/2:82–87`). Ese PID objetivo ya no puede escribir después; cada ejecución crea PID/Ref/Tid nuevos. La lista snapshot se lee antes de eliminar ETS. El llamador no puede recibir un retorno satisfactorio de `run/4` antes de terminar el coordinador.

Esto demuestra **un PID**, no un árbol. Los procesos hijo no tienen protocolo ACK ni un ámbito unido transitivamente. Los hijos creados no heredan PD; sus hooks normales están inactivos. Un hijo al que se le pase manualmente el contexto puede escribir en la tabla antigua mientras exista, incluso después de terminar el padre. No hay barrera entre snapshot y close para ese escritor no soportado. Tras close, un hook obsoleto recibe un error de tabla, no un contexto nuevo. El diagnóstico esperó explícitamente al hijo después de la raíz, inició el contexto siguiente y confirmó que este no se contaminaba. No confirma cobertura completa del árbol hijo.

**C/E.** **No existe** validación de generación en cada impacto. Ref identifica mensajes de resultado/fallo, pero no se almacena en una fila ETS ni se compara con la tabla al impactar. `attach/1:24–29` comprueba la propiedad de la tabla y los tipos referencia/PID, no el vínculo Ref–Tid. El diagnóstico aceptó reemplazar solo Ref conservando propietario/Tid. El aislamiento normal proviene de procesos y Tid nuevos, no reutilizados, no de validar generaciones. `snapshot/1:31–34` no comprueba que hayan parado los escritores: leer directamente un contexto vivo devolvió `{a}`; tras otra escritura permitida del mismo escritor devolvió `{a,b}`. La calibración debe consumir el resultado de `run/4`, no leer ETS arbitrariamente.

### Ramas de terminación: resultado actual y elegibilidad para métricas

| Rama | Datos y limpieza reales | Decisión para una serie futura |
|---|---|---|
| Retorno normal | `outcome={ok,V}`, `target_outcome` idéntico, snapshot completo de raíz si el estado es ok; DOWN precede a la lectura y close al retorno | Repetición medible cuando se cumple el contrato de raíz/reset/build |
| El objetivo devuelve `{error,invalid_input}` | Es `{ok,{error,invalid_input}}`, no una categoría invalid independiente del ejecutor; el feedback actual considera satisfactorio el retorno | No excluir por el nombre de Value; registrar el outcome aparte; U vacío da N/A |
| Configuración inválida/seed staged demasiado grande | Rechazado antes del objetivo; no se crea snapshot (`efz_config:prepare/1,prepare_mutation/1`) | Error de solicitud, no repetición vacía medible |
| `error`/`throw` del objetivo | `{crash,Class,Reason,Stack}`; impactos retenidos, DOWN del objetivo y limpieza normales | Snapshot válido de excepción terminal; no excluir crashes de la estabilidad por su outcome |
| `exit(Reason)` del objetivo | `{exit,Reason}`, el estado puede ser ok | Una excepción semánticamente completada es elegible, pero el resultado actual no la distingue de una terminación externa; hace falta el origen |
| Kill externo del objetivo | `{exit,killed}`, prefijo publicado retenido; DOWN de raíz demostrado | Prefijo completo de un PID terminado, **no un testcase completo**; generalmente incompleto, no F vacío |
| Timeout | `{timeout,T}`, el estado puede ser ok, impactos previos al kill/DOWN real retenidos | No tratar un corte por deadline como x completo; conservar el prefijo de diagnóstico aparte y marcar la serie principal incompleta |
| Carrera finalización/timeout | Si Result + DOWN llegan a tiempo: Outcome; de lo contrario vence timeout; mensajes tardíos quedan en el coordinador que termina | Comprobar la fuente terminal, no adivinar por duración o presencia de impactos |
| Muerte del llamador / cancelación | El coordinador mata/drena el objetivo y cierra la tabla, sin devolver snapshot (`cancelled -> ok`, executor:44) | Slot ausente/cancelado; incompleto. DOWN del llamador/worker no sustituye a DOWN del coordinador |
| Vence `efz:await(Timeout)` | Es un timeout de `gen_server:call`; la campaña continúa | No tratarlo como cancelación del objetivo; hace falta cancel/stop explícito independiente |
| Kill del worker | Fuzzer devuelve `status={infrastructure_failure,{worker_down,killed}}`; informe sin snapshot; el coordinador limpia el objetivo asíncronamente | Incompleto; no deducir éxito de un contador infrastructure_failures igual a cero |
| Kill del coordinador | `run/4`: infraestructura `coordinator_down`, `coverage=[]`, estado de error, builds vacíos; desaparece la tabla; el objetivo puede sobrevivir | Datos ausentes, estado de VM sucio/desconocido; detener la serie y no reutilizar la VM sin limpieza demostrada |
| Fallo de backend/plan/validación | Infraestructura, estado de error, a veces impactos de diagnóstico; el coordinador ejecuta finally en excepciones normales | No es F vacío ni un defecto del objetivo; serie incompleta/incomparable con motivo |
| DOWN anómalo del coordinador tras el resultado | `cleanup_failed` reemplaza outcome/estado (`run/4:15–18`) | Datos solo diagnósticos hasta confirmar limpieza; no admitir automáticamente |
| Caída de nodo/VM | También se pierde el controlador en la misma VM; sin resultado | Serie perdida incompleta; registrar aparte el exit status externo; no construir U a partir de un archivo ausente |

Para `halt(23)` en una **VM externa de diagnóstico**, se confirmaron exit status 23 y ausencia del archivo de resultado/snapshot. Controla la pérdida de VM; no es una prueba de segfault NIF. EFZ no tiene runner distribuido ni rama `nodedown` independiente.

`kill_and_drain` espera deliberadamente DOWN real en vez de declarar limpieza tras una demora arbitraria. Sin embargo, su espera no está limitada por otro temporizador: un NIF que nunca retorna puede exigir terminar la VM externamente. No se probó ese NIF. El estado compartido/de aplicación sucio no se limpia al morir un único PID objetivo. Sin reset/limpieza demostrados, el futuro recolector debe detener la serie con `requires_fresh_vm`, no continuar declarando fiables los contadores.

## 3. Espacio exacto de features y comparabilidad

**C/E.** Unidad de feedback automático: `{Module, BuildId_SHA256, ProbeId_integer}` — **presencia de un probe de cláusula/resultado a nivel fuente**. La fila en ambos backends es `{{probe,Id}}` en un `set` ETS:

* `ets`: inserta la misma fila en cada impacto (`efz_cov_rt:hit/1:20–26`).
* `ets_member`: primero comprueba pertenencia e inserta la misma fila si falta (`hit/1:8–19`). Las escrituras repetidas no incrementan ningún valor.
* `manual`: espacio `{manual,Id}` independiente mediante `efz_cov:hit/1:38–39`, con las mismas dos variantes de almacenamiento ETS. Es una API de compatibilidad; el llamador debe garantizar estabilidad de los ID arbitrarios del usuario. No se mezclan los espacios automático/manual.

No hay contadores, buckets, aristas CFG, features de valores, secuencias de transiciones ni bitmaps con hash. No hay desbordamiento de contador porque no existe contador. Las claves ETS exactas comparan el término completo, no un hash pequeño. El namespace de build SHA-256 no garantiza matemáticamente evitar toda colisión, pero esta implementación no introduce colisiones deliberadas de bitmap/índice. No se pierden publicaciones repetidas por caché local: no existe. Experimentalmente, multiplicidades 1 y 100 en el mismo sitio produjeron el mismo F unitario en ambos backends. Por tanto, `feature_stability` aquí equivale a estabilidad de presencia de sitios; no hacen falta otra métrica duplicada ni buckets.

`efz_cov:snapshot/1` devuelve **toda la lista ordenada de ID presentes**, no count/hash/delta. Solo después `efz_feedback:evaluate/3:10–17` calcula `Observed - Global`. `Result.coverage`, `Report.coverage` y `Decision.new_probes` son distintos: el último es el delta de retención; la cobertura del informe es la unión de ejecuciones satisfactorias. Un informe normal no guarda snapshots completos de ejecuciones satisfactorias/rechazadas; un resultado de crash conserva su cobertura completa. Un informe antiguo no permite recuperar los F_r ausentes. Hace falta reejecutar mediante `run/4` o un futuro observador antes del feedback; no proponer reconstruirlos con SHA/count/new_probes.

**C/E.** Cada cambio de entrada crea una tabla vacía nueva, en lugar de limpiar un bitmap compartido. Se verificó el aislamiento de contextos repetidos/concurrentes con ID de probe idénticos. Retorno/excepción conservan todas las publicaciones completadas de la raíz bajo un contrato de contexto inmutable. En kill/timeout son todos los impactos publicados antes de terminar ese proceso, no todas las ramas que habría ejecutado sin interrupción. Una inserción interrumpida por kill no justifica declarar observado el impacto incompleto. El snapshot está intacto, pero la completitud del testcase es otra cuestión.

**C.** La identidad la definen `efz_instrument_pt:parse_transform/2:35–53` y `probe/4:114–121`: SHA-256 de `{instrumentation_version, OTP release, compiler MD5, canonical preprocessed forms, relevant compiler options}`, seguido de índice AST ordenado determinista. Versión de esquema manifest/instrumentación = 1, métrica = `clause_outcome_probe`. El mapeo contiene M/F/arity/kind/path/file/line/column. La ruta relativa a la raíz se normaliza; literales sensibles a rutas absolutas pueden cambiar el build. No hay layout nativo independiente ni feedback_epoch. Un hash arbitrario de un mapa ETF completo no constituye un digest portable sin canonicalización: el orden de serialización de mapas no ofrece ese contrato.

`efz_instrument:preflight/1`, `load/1`, `loaded_manifest/2`, líneas 94–142, comprueban BEAM, sidecar decodificado, manifest y atributo del módulo cargado. El sidecar se compara como término exacto, no bytes (`matching_sidecar/2:111–113`). La prueba existente de orden de mapas invertido/VM nueva volvió a pasar. En tres VM nuevas un artefacto produjo **los mismos ID completos**, el mismo mapa de builds y S=100%; se comprobó equivalencia mediante listas de ID, no solo count/digest.

No se vigila continuamente el reemplazo en caliente tras preflight. En el diagnóstico, un plan antiguo válido tras cargar de forma controlada una versión **normal** del mismo módulo produjo `coverage_status=ok, coverage=[]` y el mapa antiguo de builds. Repetir preflight explícito rechazó `loaded_module_identity_mismatch`. El validador detecta un build instrumentado nuevo que publica ID nuevos; no detecta así reemplazarlo por código sin probes. El contrato de duración exige builds seleccionados y harness inmutables. Cambiar build o manifest requiere otro plan y serie; no se declara soporte de hot reload arbitrario.

**C/E.** Un plan preparado es `{efz_cov_plan,1,Tid,BuildMap}`. `prepare/2:51–68` valida esquema manifest, versión de instrumentación, unicidad, selección automática no vacía y ausencia de módulos duplicados; crea el marcador ETS protegido `{'$efz_plan',{Mode,Bs}}` y las identidades permitidas exactas. **No sustituye preflight** ni contiene entrada, Ref de ejecución, RNG o cobertura acumulada. El worker lo posee hasta stop, incluso después de completar `await`. La API de bajo nivel permite un llamador ajeno mientras vive el propietario; prohíbe escribir en el plan protegido de otro. El propietario lo libera después de todos los lectores; su muerte elimina automáticamente la tabla.

En cada ejecución se validan marcador/modo/builds y todos los ID observados, incluso el marcador con F vacío (`validate_prepared/3:72–85`). Un plan eliminado, modo incorrecto o mapa de builds sustituido no puede convertirse en snapshot vacío satisfactorio. Otra versión de tupla puede fallar además en `builds/1:70` y producir infraestructura coordinator_down. Las pruebas negativas/de duración existentes cubren esto, incluida la muerte del propietario del plan durante una ejecución activa. El plan no depende del backend; aun así se registran backend de almacenamiento y estrategia de validación en la configuración experimental porque sus costes temporales difieren.

## 4. Aplicabilidad de feature_stability y reglas de admisión

**P.** Es una métrica propia de EFZ, no la fórmula estándar de libFuzzer ni un equivalente numérico de la estabilidad AFL++. Normalización v1: deduplicación + orden canónico de identidades **completas** de probe; sin enmascarar sitios/contadores ni excluir ID exclusivos de crashes. Para el mismo x con contrato de estado fijo y R >= 2:

```text
frequency_x(f) = number of measured repeats where f appeared at least once
U_x = union of all F_r(x)
I_x = { f in U_x | frequency_x(f) == R }
V_x = U_x \ I_x
S(x) = feature_stability = 100 * |I_x| / |U_x|
S_C = 100 * sum_x |I_x| / sum_x |U_x|
```

Los impactos repetidos dentro de un F no aumentan frecuencia. No hace falta una ejecución de referencia. Si se desea, la fracción de ejecuciones completamente coincidentes puede ser una métrica independiente con referencia elegida explícitamente; no sustituir S por ella. Para comparar umbrales exactamente, conservar numerador/denominador y comparar productos enteros; redondear solo para mostrar.

**E.** Un objetivo de diagnóstico con solo cuatro probes produjo para una entrada:

```text
F1={a,b,c}; F2={a,b,d}; F3={a,b,c}
frequency={a:3,b:3,c:2,d:1}; I={a,b}; U={a,b,c,d}; V={c,d}; S=50%
```

Todos los tamaños son tres. Otra entrada que alterna en sentido inverso también tiene S=50%; el agregado correcto del corpus es 50%. Si primero se unen las dos entradas de cada ronda, `{a,b,c,d}` aparece tres veces y da un 100% falso. Se verificó con assertions, no se dedujo de registros visualmente parecidos.

**P.** Máquina de estados del resultado para una entrada:

| Condición | Estado / valor |
|---|---|
| R solicitado < 2 | N/A `insufficient_repeats`; no 100 |
| Las R observaciones son fiables y comparables, U no vacío | `complete`, S y frecuencias completas |
| Las R fiables, U vacío | N/A `empty_feature_union`; distinguir por separado bytes vacíos de snapshot vacío |
| Snapshot ausente, error de infraestructura, quiescencia/reset/limpieza sin confirmar, cancelación, pérdida de propietario/VM, testcase interrumpido | `incomplete`, sin S principal |
| Build/manifest/esquema/ámbito cambiado o ID incomparables | `incomparable`, sin S principal; no convertir automáticamente a otro namespace |
| Solo existen k<R repeticiones fiables | `incomplete`; se puede mostrar S diagnóstico separado para k>=2 real, sin admisión automática |
| Error/throw/exit capturado terminal completo o retorno invalid normal | Puede participar en estabilidad; registrar outcome aparte, no excluir solo por clase |

La comparabilidad presupone ausencia de interferencia con el estado de instrumentación. El estado ok por sí solo no lo demuestra frente a un objetivo hostil. Si se detecta interferencia o cambio de código, la serie es inválida/incompleta aunque quede un subconjunto no vacío de impactos idénticos.

Para C fijo, congelar de antemano identidad de contenido, orden/permutaciones y protocolo de repetición. El agregado pondera **pares entrada–feature**, no features únicas del corpus entero. Junto a S_C exigir filas por cada x, min S(x), número de entradas inestables (`|V_x|>0`), `selected_entries`, `unique_inputs`, `measured`, `scored`, `empty`, `incomplete`, `incomparable` y sus ID. Mapear explícitamente entradas duplicadas byte a byte a un x para esta métrica de control; no eliminar ni alterar entradas originales, orden/estado o contadores normales de calibración.

En un corpus incompleto, el agregado principal tiene estado incomplete/incomparable, no “todo estable”. Se permite un agregado `complete_subset` aparte con lista exacta de x incluidos y denominadores. Los x completos vacíos aportan cero a las sumas, pero conservan filas N/A marcadas explícitamente, en vez de convertirse en “100% verificado”. Si el denominador total es cero, S_C=N/A. No excluir silenciosamente fallos o repeticiones ausentes, sustituirlos por vacío ni reintentar hasta lograr un R conveniente. Una ejecución consistente nueva tras un fallo es otra serie con otro ID de diagnóstico.

La comparación principal de outcomes se propone aparte: valor de retorno exacto o clase/motivo de excepción; conservar stack del objetivo como evidencia, no como feature. Los valores volátiles PID/ref/port/fun no deben declararse coincidencias portables entre VM. Registrar cambios/incomparabilidad del outcome por separado; no destruir el resultado original. Igualdad completa de F no demuestra orden de ejecución idéntico, outcome idéntico ni ausencia de defectos.

Si el feedback pasa algún día a `{site,bucket}`, cambiar bucket puede crear varias features inestables para un sitio; difiere del número de celdas AFL++ estables. Actualmente no hay ese backend. Introducir un segundo esquema y una métrica independiente de presencia de sitios solo si cambia el feedback, no para esta auditoría.

Directrices internas configurables propuestas: objetivo **100%**, aviso si `S < 95%`, investigación más profunda si `S < 90%`; todos los x variables siguen visibles también por encima de 95%. Son umbrales iniciales del proyecto, no un estándar industrial ni prueba de corrección. Los datos incompletos no superan la comprobación de umbral. R mayor aumenta la probabilidad de detectar variabilidad; comparar porcentajes requiere R, C, esquema de features, builds/manifest y modo de ejecución/reset/warmup fijos.

## 5. Aislamiento BEAM y protocolos de repetibilidad

| Modo | Qué se confirma / qué debe registrar una ejecución futura |
|---|---|
| Repeticiones de x mediante `run/4` normal | PD/buzón de objetivo nuevos, contexto nuevo; schedulers principales 16; primera llamada incluida. Fixture determinista con F completos idénticos y S=100 |
| A→B→A, permutaciones fijas | Conjuntos `only_a`/`only_b` independientes disjuntos, ambos A coinciden, las permutaciones dan el mismo mapeo entrada→F |
| Violación controlada de independencia | `state_b` cambia `persistent_term`; A antes/después produce c/d, S=0. Reset explícito del fixture restaura A. Indica estado de VM compartido, no aislamiento ETS defectuoso |
| VM nueva por cada x | Tres VM independientes, mismo artefacto/manifest e ID, S=100; 16 schedulers normales. Modo de control, no garantía de aislamiento del SO |
| Warmup planificado | Esta auditoría usa W=0. No se descartó la primera llamada. W/secuencia de warmup futuros forman parte explícita del protocolo/clave; también cuentan sus fallos |

El primer experimento ETS tuvo `elapsed_us=[919,10,7]`; el posterior ets_member empezó con `[15,12,11]`; los F coinciden. El segundo grupo ya se ejecutaba en una VM caliente, así que **no compara rendimiento de backends**. Los números muestran por qué no se debe excluir silenciosamente la primera llamada ni mezclar modos frío/estable. No se midió warmup/estabilidad completos sobre una biblioteca real.

**E.** `put`, mensajes de buzón y estado implícito de rand locales al objetivo no pasaron al siguiente objetivo nuevo. Sin embargo, el ejecutor no reinicia ETS compartidas/servidores registrados/persistent_term/estado de aplicaciones. En la prueba, un gen_server ya activo, un callback OTP síncrono y un mensaje entregado por temporizador llamaron a un sitio instrumentado sin contexto adjunto: los hooks de hijos/fondo estaban inactivos. `spawn`, `spawn_link`, `spawn_monitor` dejaron vivo al hijo tras retorno normal de la raíz; ni un link ni un monitor paterno garantizan terminar todo el árbol. La liberación/ACK del hijo fueron explícitos, no tras un sleep. Los temporizadores/mensajes no transportan el diccionario de procesos; el receptor determina el proceso ejecutor. Los servidores OTP existentes no reciben contexto automáticamente.

Si el objetivo tiene estado deliberadamente, x debe incluir estado inicial, configuración y secuencia de acciones. `state_a` tras distintos estados intencionados no debe representarse como un mismo escenario x. EFZ actual acepta binary+`run/1`, sin API de escenario/reset. La primera integración mínima debe limitarse explícitamente a `fresh_target_process / unreset_shared_vm / root_probe_scope` existente y a independencia acordada del harness. No presentarlo como reset universal de aplicaciones OTP.

Límites no verificados: ETS ajenas arbitrarias, registro/estado global, aplicaciones compartidas, archivos/puertos, temporizadores/actores en segundo plano no gestionados, estado distribuido y recursos nativos compartidos. Una VM nueva aísla su estado de procesos, pero no garantiza reiniciar recursos externos del SO. Ni Ref de contexto, ETS pública ni plan preparado son una frontera de seguridad. Un objetivo en la misma VM puede cambiar runtime, matar el coordinador o corromper instrumentación. Parte de la interferencia ya se clasifica como fallo de infraestructura; no existe protección completa/detector de worker sucio.

## 6. Ejecuciones y matriz de evidencias

Todos los comandos se ejecutaron desde `efz/`. Los flags de build son los de rebar.config actual; los módulos de diagnóstico se compilaron con `debug_info,warnings_as_errors`, sin dependencias nuevas; solo `audit_sites` entró en la allowlist. Sus cuatro probes: `a/0:3`, `b/0:4`, `c/0:5`, `d/0:6` (columna 1), build `68bd7a9201c0be5e43ed13f5850558fcefe6e07493252a66204f7fe36fc7e809`. El adaptador/fixture de fondo se dejó deliberadamente sin instrumentar para no contaminar los conjuntos a/b/c/d con ramas de control compartidas. También se comprobaron los ejemplos normales de producción, no se sustituyeron por este espacio especial.

| Comando | Resultado nuevo | Registro |
|---|---|---|
| `rebar3 compile` | exit 0 | [compile.log](/tmp/efz-calibration-audit.rIBEql/compile.log) |
| `rebar3 eunit` | exit 0, **62 superadas** | [eunit.log](/tmp/efz-calibration-audit.rIBEql/eunit.log) |
| `rebar3 ct` | exit 0, **3 superadas** | [ct.log](/tmp/efz-calibration-audit.rIBEql/ct.log) |
| `escript /tmp/efz-calibration-audit.rIBEql/audit.escript /tmp/efz-calibration-audit.rIBEql` | exit 0, **54 registros de evidencia**, todas las assertions superadas | [diagnostic.log](/tmp/efz-calibration-audit.rIBEql/diagnostic.log) |
| `escript /tmp/efz-calibration-audit.rIBEql/existing_example.escript /tmp/efz-calibration-audit.rIBEql` | exit 0; `efz_example_target` con `<<0>>` y `<<255>>`, R=3 cada uno, F exactos coincidentes, S=100; excepción no excluida | [existing-example.log](/tmp/efz-calibration-audit.rIBEql/existing-example.log) |

Los resultados completos previos a novedad, con ID y metadatos exactos, están en [events.term](/tmp/efz-calibration-audit.rIBEql/events.term) y [events.txt](/tmp/efz-calibration-audit.rIBEql/events.txt). Las assertions comparan conjuntos canónicos, no solo tamaños. Registros/scripts son temporales; esta tabla y las fuentes integradas son el registro reproducible permanente. El primer script de prueba dio un aviso OTP por patrón float `0.0`; se cambió a `+0.0` solo en el script temporal y el experimento final se repitió correctamente. Los resultados anteriores se conservaron con sufijo `first`; las conclusiones usan la ejecución final.

SHA-256 de evidencias finales: `eunit.log` — `1aaf27c24e7f320e7b331d2f9e7f06dea647981627050cd53aba37c513fe8a3e`, `diagnostic.log` — `b4bc09d285bd1681b13ffbd7f4a61233ccef6ace37af8dfabf7dc32ddac3ba66`, `events.term` — `fc7773394e458dedd9f742b80c5b0d9f7c44913add1e48d79146d9e8a2ea37c9`. Después se extrajeron las fuentes incluidas **usando los propios comandos del apéndice** a `/tmp/efz-calibration-reproduce.5h0yayqu`; ambos escripts de diagnóstico volvieron a terminar con exit 0. Verifica reproducibilidad de comandos; no es otra muestra que mezclar en porcentajes/tiempos. Véase [comprobación de reproducción](/tmp/efz-calibration-audit.rIBEql/report-reproduction.txt).

| Requisito / experimento | Implementación y evidencia actuales | Carencia / cambio mínimo |
|---|---|---|
| x determinista, R=3 | Ambos backends: abc tres veces, S=100; `{B,deterministic}` | La métrica pública necesita recolector independiente |
| Conjuntos distintos de igual tamaño / alternancia conocida | abc/abd/abc, frecuencias 3/3/2/1, S=50; `{B,alternation}` | Calcular por identidad, no count/hash |
| Agregación del corpus | Dos x opuestos: correcto 50, colapsado 100 | Conservar frecuencias `(x,feature)` separadas |
| Multiplicidades distintas | 1 y 100 impactos en sitio a → un probe; `{B,multiplicity}` | No introducir contadores/buckets |
| A→B→A/permutaciones | a/b disjuntos, ambos A coinciden; `{B,aba}` | Fijar contrato de orden/reset |
| Estado compartido | persistent_term cambia A; reset del fixture lo restaura | Sin reset universal del objetivo; no equiparar proceso a VM nueva |
| Hijo diferido | Tres variantes spawn inactivas, siguiente raíz limpia; hijo con copia explícita recibió tabla inválida tras close | Sin soporte de quiescencia/cobertura de árbol; ámbito raíz explícito |
| Servidor OTP/temporizador existente | Hook de fondo inactivo, snapshot raíz solo a | Ámbito de aplicación OTP exige otro runner futuro, no esta integración |
| Contextos concurrentes, ID idénticos | Ref/Tid distintos, ambos exactamente `{a}`, sin tablas tras retorno | No deducir soporte multiworker de producción de esta prueba |
| Error/throw/exit | Todos retienen a, estado ok; `{B,exceptions}` | Excepción terminal elegible; hace falta origen de exit |
| Kill externo / timeout | ACK tras a, luego kill/deadline, a retenido, objetivo/propietario DOWN | Es un prefijo; falta completitud del testcase |
| Carrera finalización/deadline | Superadas `efz_backend_tests:boundary/1:188–198` y pruebas Phase 2 existentes | Metadatos de fuente terminal en vez de adivinar |
| Llamador/cancel/shutdown | `caller_death/1`, `cancel/1:179–210` existentes superadas en cuatro combinaciones; nueva cancelación confirmó await != cancel | Sin snapshot de cancelación; limpieza asíncrona respecto a muerte del llamador |
| Entrada/snapshot vacíos | `<<>>` que retorna invalid y ruta vacía independiente distinguibles; ambas series vacías N/A | No confundir error/ausencia con vacío válido |
| Caída de worker | Estado de infraestructura, sin snapshot en informe, stats infra=0; `worker_kill` | Observador debe leer estado; aclarar telemetría |
| Caída del coordinador | a guardada antes del kill se perdió con tabla; raíz siguió viva, harness la mató explícitamente | Incompleto + sucio; guardián de limpieza o no reutilizar/eliminar VM |
| Propiedad/dispose/foreign del plan preparado | Superada `efz_backend_tests:plan_lifetime/1:128–166`; plan eliminado + vacío causó fallo de infraestructura en ambos backends | Mantener propietario vivo hasta terminar lectores; no liberar durante ejecución |
| Manifest/sidecar ausentes o incompatibles | Superadas negativas EUnit preflight y `efz_phase2_tests:sidecar_encoding/0:229–253` | API offline debe ejecutar preflight; run/4 crudo no lo hace |
| Mismo build, VM nueva | Tres VM nuevas aceptaron un sidecar y devolvieron abc exacto + builds idénticos | Cambio de namespace significa incomparable, no merge |
| Pérdida de VM | Helper externo salió con 23; sin archivo snapshot | Sin runner nativo existente; trabajo externo debe marcar ausencia |
| Snapshot vivo / Ref | a antes de quiescencia, ab después; Ref modificado aceptado con mismo Tid | No leer snapshots directamente; Ref es correlación, no protección de generación/seguridad |
| Estado activo roto | Error de tabla capturado permanece como fallo de infraestructura sticky; contexto PD malformado capturado por objetivo dio ok+vacío | Véase F4; no confiar indiscriminadamente en estado ok |
| Reemplazo normal en caliente | Plan antiguo aceptó vacío; preflight explícito rechazó identidad cargada | Fijar builds y comprobarlos en fronteras de serie soportadas |

La cobertura EUnit existente incluye semántica del transform, sintaxis anidada/en una línea, clase/motivo de excepción, posición de cola, identidades de instrumentación, outcomes/novedad canónicos de backends/validadores, cancel/shutdown y liberación repetida de recursos. Los errores esperados de planes malformados son pruebas negativas, no fallos de compilación. `efz_backend_tests:variants/0:21` comprueba ambas implementaciones de almacenamiento con ambos validadores. Los 38/3 de informes antiguos no se usaron como resultados nuevos: la ejecución actual es 62/3.

**NV.** No se repitieron Dialyzer/xref: no hay cambios de producción, instrucciones aplicables que exijan gate ni preguntas que requieran otro análisis estático en vez de las pruebas de runtime examinadas. Sus PASS antiguos no se presentan como esta ejecución. No se probaron profiling/soak Phase 2.1, Cowboy (sin dependencia/harness), objetivos externos arbitrarios, reset/quiescencia de cobertura nativa/NIF, segfault NIF, nodedown distribuido ni aislamiento exhaustivo de recursos OTP. Estas fronteras no quedan resueltas por las pruebas a/b/c/d.

## 7. Hallazgos priorizados

### F1 — P1: outcome/estado no establecen completitud ni fuente de terminación

**C/E.** `efz_executor:coordinate/6:35–38`, `wait_target/5:64–79`, `coverage/3:89–104`. `exit(killed)` capturado y kill externo produjeron outcome, target_outcome, coverage_status, coverage y builds **idénticos**; solo variaron Ref/tiempo incidentales. Timeout también puede tener estado ok y F no vacío. Considerarlo suficiente para una repetición completa puede hacer parecer falsamente estables ejecuciones interrumpidas.

**P. Mínimo:** metadatos aditivos de origen terminal/ámbito/quiescencia/snapshot/limpieza; no renombrar tuplas outcome existentes. Derivarlos de la rama ejecutada, no de heurísticas de Reason. El validador admite excepciones terminales capturadas, no testcases incompletos por deadline/monitor-exit. **Aceptación:** el mismo `{exit,killed}` público se distingue por origen; prefijo y ausencia nunca se convierten en completo/vacío para la métrica.

### F2 — P1: la muerte no atrapable del coordinador deja un objetivo vivo no soportado

**C/E.** Se crea el objetivo con `spawn_monitor`, sin guardián de limpieza que sobreviva al propietario (`coordinate/6:31–41`). Matar al coordinador omite `after:55–60`; `run/4:20–23` devuelve infraestructura, pero el objetivo seguía vivo en la prueba. El harness lo monitorizó y mató exactamente, luego esperó DOWN; no tocó procesos ajenos.

**P. Mínimo para la métrica:** abortar serie, marcar snapshot ausente y usar `requires_fresh_vm` sin limpieza confirmada; no ejecutar x posteriores en VM sucia. Reutilizar tras ese fallo exige guardián independiente que sobreviva al propietario/limpieza del objetivo rastreado y ACK de DOWN real. Un link simple no basta con `trap_exit`; sleep no lo arregla. No cambiar outcomes ni añadir contadores por velocidad. **Aceptación:** kill forzado del propietario nunca produce puntuación; continuar solo tras demostrar parados los escritores rastreados o en otra VM externa.

### F3 — P1: un plan no demuestra que el código ejecutado no cambió

**C/E.** `efz_cov_manifest:validate_prepared/3:72–85` compara ID observados con el marcador, no código cargado. `efz_instrument:loaded_manifest/2:124–127` comprueba atributo real solo en preflight. Reemplazo normal en caliente produjo snapshot vacío válido con mapa de builds antiguo. result.builds completo viene de opciones/plan, no de una traza.

**P. Mínimo:** fijar módulos seleccionados **y adaptador objetivo** toda la serie; preflight al entrar, capturar/comprobar identidades cargadas seleccionadas en fronteras acordadas e invalidar por cambios de build/manifest/harness. No protege frente a cambios durante ejecución que luego se revierten; no prometer hot loading arbitrario. **Aceptación:** frontera incompatible rechazada; build nuevo implica serie nueva, no merge de subconjunto; build fijo inalterado puede reutilizar plan.

### F4 — P1 para violaciones del contrato runtime: se pierde el contexto malformado capturado

**C/E.** `efz_cov_rt:hit/1:16–27`: tabla incorrecta envía notificación sticky, mientras la cláusula final de contexto inválido solo lanza excepción. El fixture reemplazó contexto PD y la capturó; el ejecutor devolvió `{ok,caught}`, estado ok y cobertura vacía. RunRef no protege la instrumentación del objetivo.

**P. Mínimo:** prohibir explícitamente modificar estado de instrumentación en el harness soportado; comprobar contexto original desde wrapper antes de finalizar, fallar de forma cerrada y diagnosticar violaciones. Comprobar solo “al salir” no protege de sustitución/restauración deliberada. Un objetivo hostil requiere otra frontera de seguridad/aislamiento, no promesa de calibración. **Aceptación:** contexto inválido/borrado que permanece tras error capturado implica infraestructura/incompleto; runtime sin attach en hijo normal no medido sigue siendo no-op inactivo permitido.

### F5 — P1 para integración: los datos del informe no pueden tratarse como F_r

**C.** `efz_worker:execute/4:60–82`, `finish/2:115–118`, `efz_feedback:evaluate/3:10–20`. Snapshots satisfactorios entran en merge global y no se conservan por ejecución. `new_probes=[]` de crash es política de retención, no ausencia de features ejecutadas.

**P. Mínimo:** recolector guarda resultado completo antes de novedad o repite independientemente los bytes mediante el mismo run/4. No llamar a `feedback:evaluate/3` en cada repetición. **Aceptación:** serie idéntica no produce varios NEW, cambia corpus/RNG/cursores ni fusiona features exclusivas de crashes en global.

### F6 — P2: telemetría menos clara para pérdida del worker y fallo de fuente

**C/E.** `efz_fuzzer:handle_info/2:34–39` devuelve infraestructura worker_down sin incrementar infrastructure_failures; contador observado 0. **C:** `efz_feedback:evaluate/3:6–7,22` exige primero builds iguales; coordinator_down con builds=#{} puede convertirse en `instrumentation_build_mismatch`, ocultando la causa original de infraestructura, aunque no se clasifica como defecto del objetivo.

**P. Mínimo:** determinar estabilidad por resultado/estado estructurado, no contadores agregados. Conservar causa primaria; cualquier cambio futuro de estadísticas debe contar el fallo del worker exactamente una vez. **Aceptación:** ejecución perdida sigue ausente y el motivo real figura en la fila de calibración; nadie declara un contador infra 0 como prueba de completitud.

### F7 — P2 / ámbito: aislamiento raíz no equivale a independencia del testcase

**C/E.** El ejecutor no tiene reset/registro de hijos; pruebas de persistent_term e hijo diferido confirmaron el límite. `snapshot/1` directo y sustitución de Ref no establecen quiescencia. **P:** registrar modo raíz/VM sin reset; diagnósticos A→B→A y permutaciones fijas; escenario con estado inconsistente no soportado, no puesta a cero automática de frecuencia. **Aceptación:** medir un contrato conocido; no eliminar seeds inestables ni enmascarar probes para elevar porcentaje.

## 8. Diseño mínimo de integración — solo propuesta

### Fronteras API y propietarios

**P, no es una API existente:**

```erlang
%% Complete offline control corpus, without mutator or feedback side effects.
efz_calibration:run(Target, Entries, Artifacts, Options)
    -> {ok, CalibrationReport} | {error, ConfigurationReason}.
%% Pure aggregation, separate from storage/execution.
efz_stability:fold(Accumulator, ValidatedRun).
efz_stability:finalize(Accumulator, RequestedR).
```

Opciones propuestas: `repeats` (R>=2, ejemplo opt-in inicial acotado R=5), timeout, estrategia backend/validación, `mode=fresh_target_process`, `scope=target_process`, `warmup=0`, identidad de protocolo/orden/contrato de reset, límites de entradas/R/presupuesto temporal total y de trazas/testigos. Superar el límite de features debe terminar la entrada como incompleta, no truncar el conjunto. La funcionalidad activada no debe crear reintentos infinitos. No aceptar escenarios con estado arbitrarios como entrada binaria en la primera versión; una VM nueva es otro modo helper seleccionado explícitamente.

El iniciador recibe bytes/identidades fijos y Target/Artifacts explícitos, como replay actual. `efz_config`/`efz_instrument` validan la selección; no se aceptan objetivos invocables arbitrarios de archivos de resultado. Decodificación/regeneración ocurre una vez antes de la serie; cada medición recibe **los mismos bytes**, no otra mutación. No se reemplaza el ejecutor de bajo nivel.

Esquema de propiedad propuesto:

* El controlador/llamador del trabajo posee corpus congelado, clave de compatibilidad y agregador; recibe progreso acotado por cada índice de ejecución programado.
* Un recolector de calibración posee el plan preparado y llama a `efz_executor:run/4` secuencialmente. No hay workers de fuzzing de producción concurrentes. El plan se crea tras preflight, vive hasta terminar todas las llamadas run/4 y su propietario lo libera en `after`. Contextos, ETS y monitores por ejecución siguen perteneciendo al coordinador existente. JobRef/PID paternos solo correlacionan, no son clave de caché duradera.
* El recolector pasa RunResult completo e inmutable al controlador tras volver run/4, es decir, después de DOWN/limpieza del coordinador. El controlador incrementa frecuencia una vez por feature del slot, usando snapshot completo, no delta de decisión.
* La cancelación offline es inicialmente **cooperativa entre llamadas run/4**: espera la llamada actual sin liberar su plan y no inicia el siguiente slot. Los restantes son cancelled/not_run; resultado incompleto. No promete cancelar inmediatamente un NIF colgado. El recolector monitoriza al iniciador y comprueba stop/muerte antes de otra ejecución.
* Si muere forzosamente el recolector/propietario, el controlador conserva slots recibidos, marca el resto ausente, respeta garantías actuales y exige otra VM si no se demuestra quiescencia. DOWN del recolector no es ACK de todos los recursos. Cancelar inmediatamente y continuar en la misma VM requiere observador/guardián de limpieza explícito; es extensión aditiva del protocolo existente, no segundo ejecutor.

**P:** ampliar metadatos de `run/4` preservando outcome/coverage y wrapper antiguo `run/3`. Estructura propuesta (nombres aún sin implementar):

```erlang
#{termination_origin => returned | caught_error | caught_throw | caught_exit |
                         monitor_exit | deadline | caller_cancel | coordinator_loss,
  coverage_scope => target_process,
  writers_stopped => confirmed | unknown,
  snapshot_status => full_scope | terminated_prefix | missing | invalid,
  cleanup_status => complete | failed | unknown}.
```

`full_scope` se limita a raíz y cumplimiento del contrato de instrumentación, no a “toda la aplicación OTP”. Las ramas del ejecutor fijan campos; admisión de calibración comprueba aparte builds, ámbito, contrato de reset, origen terminal y coverage_status. Enviar resultado antes de finally solo se permite con la espera actual del llamador por DOWN; metadatos de limpieza deben reflejar esa barrera, no fijarse anticipadamente. Cancelar sin resultado sigue siendo ausencia hasta existir observador explícito. Epoch no sustituye quiescencia.

### Esquema de resultado y clave de invalidación

**P:** añadir informe/índice `calibration` versionado aparte; no renombrar corpus, recetas de mutación, tuplas crash, decisiones ni contadores existentes. Para cada x guardar:

```erlang
#{schema_version => 1, compatibility_key => Key,
  input_id => SHA256, input_size => N, corpus_ids => [...],
  requested_repeats => R, attempted => A, trusted_repeats => K,
  status => complete | incomplete | incomparable | not_applicable,
  reason => Reason, union_size => UCount, intersection_size => ICount,
  variable_features => [...], frequencies => [{ExactFeature, PresenceFrequency}],
  feature_stability => NumberOrUndefined,
  outcomes => BoundedOutcomeSummaries, outcome_changes => Changes,
  runs => BoundedRunMetadata, witness_inputs => References,
  timing => #{startup_us => ..., repetitions_us => ..., aggregation_us => ...}}.
```

Incluir también resumen del corpus, S mínimo, número inestable y selected/measured/incomplete con listas exactas de ID. No conservar indefinidamente toda receta/snapshot rechazado. Las frecuencias bastan para I/U/V; snapshots/testigos crudos son una opción acotada. Los bytes deben seguir verificables por hash/longitud en corpus o copia empaquetada; repetir binario listo no exige donante/estado RNG.

**P.** `Key = SHA256(canonical versioned structure)` con componentes obligatorios siguientes; nunca serializar un mapa no canónico como “clave portable”:

| Componente | Base real / regla |
|---|---|
| Entrada/escenario | SHA-256 de **bytes + longitud**, validación de bytes empaquetados; en escenarios futuros digest de estado inicial/config/acciones, no un mensaje |
| Objetivo/harness | `{Module,run,1}` explícito, identidad BEAM del adaptador/harness normal realmente cargado (MD5 de código/digest de objeto coincidente), versión del contrato harness/reset; BuildMap seleccionado no cubre por sí solo el adaptador |
| Código seleccionado | `{module-name-binary, BuildId, canonical manifest digest}` ordenados; versión de esquema/instrumentación, limitaciones y toolchain |
| Semántica de features | `clause_outcome_probe / exact_presence / normalization_v1 / target_process`; versión/digest de código del runtime/ejecutor/validador EFZ activo; manual usa namespace separado/contrato explícito de ID |
| Epoch de compatibilidad | Nuevo digest portable propuesto para esquemas/semánticas enumerados; **no existe feedback_epoch actualmente**; cambiar política/esquema requiere otra serie |
| Ajustes de ejecución | Timeout, implementación backend, estrategia de validación, OTP/ERTS/arquitectura, schedulers, configuración objetivo, protocolo/reset; afectan entorno/carga incluso con features comparables |
| Protocolo de ensayo | R, cantidad/entradas de warmup, política frío/estable, consecutivo frente a rondas de corpus/permutaciones fijas/VM nueva; digest de corpus de control/orden en experimentos dependientes del orden |
| Política de outcomes | Versión de normalización del outcome, sin descartar silenciosamente cambios de retorno/valores volátiles |

`ets` y `ets_member` tienen igual semántica de features y F comparables, pero no debe reutilizarse silenciosamente caché entre variantes temporales/configuraciones. `execution_ref`, PID, Tid, tiempos monotónicos e índice paterno no son identidades portables. Seed de selección/mutación no hace falta para regenerar x congelado; si definió corpus/orden de control, se conservan identidad y procedencia. Un descriptor preparado no puede guardarse como artefacto reutilizable; una VM nueva crea otro plan.

Es una clave de **compatibilidad experimental**, no prueba de que contenidos desconocidos de VM compartida sean idénticos. En modo sin reset debe desactivarse reutilización automática entre trabajos basada solo en ella. Guardar series independientes con misma clave; no combinar repeticiones en R nuevo ni sustituir ejecución nueva por “100%” antiguos. Reutilizar exige contrato inicial/reset confirmado y política de frescura seleccionada. ID/fecha distinguen trabajos pero no son identidad de entrada/feature.

Los formatos actuales son mapas Erlang de informe/`term_to_binary` y pretty-print en escript; EFZR es formato aparte de una receta concreta, no base de calibración. Un CLI nuevo mínimo `scripts/calibrate.escript` podría llamar la API propuesta y guardar informe `.term` versionado separado. No hay API/codificador JSON; no añadir dependencia para uno. Si se exige exportar JSON después, ID binarios en hex, puntuación indefinida como null + motivo y sin handles runtime; esquema equivalente al mapa. Es exportación propuesta, no funcionalidad actual.

### Iniciadores, novedad y registro exactamente una vez

**P.** Orden de implementación: primero corpus congelado offline; después iniciadores opt-in solo informativos al iniciar campaña, tras entrada interesante nueva y al comprobar snapshot explícito del corpus. Cambiar build/manifest/esquema **invalida** resultados y exige nueva preparación; no soportar hot reload vivo en la campaña actual.

La ruta offline no tiene `efz_feedback:evaluate/3`, `efz_corpus:add/2`, selector/mutador ni reinicio de estadísticas. En campaña capturar RunResult original completo en `efz_worker:execute/4` inmediatamente tras línea 60, usarlo como primera de R repeticiones y realizar R−1 repeticiones observacionales de esos bytes. Su cola separada no avanza cursores staged, RNG ni iteración, ni cambia padre/receta. Feedback/retención existentes se invocan **exactamente una vez para el resultado original**, en su orden original; observaciones de calibración no se fusionan en Global.

Seeds iniciales siguen siendo baseline; la pasada habitual con motivo `seed_calibration` permanece intacta y no se convierte en descubrimiento por mutación. Flujos históricos baseline/candidato conservan contrato con la feature desactivada. Ejecuciones extra alteran inevitablemente tiempos/efectos de VM; sin reset, la independencia tras esta inserción exige comprobación, no promesa de flujo idéntico.

Adjuntar resultados mediante índice `Report.calibration` separado por contenido/clave. `efz_corpus:add/2` actual no actualiza metadatos de entrada existente; no usarlo para reinsertar. La primera versión no necesita API nueva de actualización de corpus. Entrada/metadatos/added_at/recetas originales y contador de descubrimientos no cambian. No existe scorer ni timestamp de última cobertura nueva separado; no introducirlo por accidente ni reiniciar `stats.started_at` al medir estabilidad.

Guardar variaciones de outcome y nuevos testigos crash con procedencia `stability`, entrada cruda y resultado real; no descartarlos por S bajo ni contarlos como descubrimientos por mutación. El almacenamiento crash actual sirve para bytes/resultados de testigos con metadatos extra y contabilidad separada. Las observaciones exclusivas de crashes no suprimen la futura novedad satisfactoria.

Una decisión posterior **separada** de usar solo feedback estable requeriría transacción única diferida `G_before + original result + series + compatibility epoch -> one commit`. Evaluar R veces o merge(U) no lo logra: U puede contener features variables/exclusivas de crash. Cambios de retención/scheduler requieren ADR/pruebas propios y quedan fuera de etapa solo informativa propuesta. No se proponen borrado automático de seeds inestables, enmascarado de probes, supresión de crashes ni reevaluación de baseline.

### Coste y estadísticas independientes

**P, estimación de complejidad, no benchmark nuevo:** procesar offline N entradas únicas requiere `N*R` ejecuciones medidas (+ warmup elegido explícitamente). Al reutilizar resultado original del seed/candidato, la primera ya ocurrió: añadir `R−1` por entrada. Esta estimación no exige nueva medición de throughput Phase 2.1.

Sea P número de probes del manifest, H_r impactos únicos por repetición y T_r llamadas hook. Preparar plan usa O(P) almacenamiento una vez; publicaciones dependen de T_r. `tab2list` es O(H_r), ordenar O(H_r log H_r), validación preparada comprueba pertenencia sobre H_r; per_execution además crea conjunto permitido O(P) cada vez. Agregar frecuencias en hash-map es O(sum H_r) esperado, memoria O(|U_x|), salida final ordenada. Guardar todos los F crudos costaría O(sum H_r), por eso es opcional y acotado; frecuencias no requieren R copias. Copiar snapshots/resultados y serializar ETF es proporcional a datos y debe medirse aparte del tiempo objetivo.

En diagnósticos el plan de cuatro probes ocupaba 5 filas ETS (4 + marcador), 3,128 bytes en ambos backends. Es un plan vivo, **no memoria máxima ni total de campaña**. Tras los experimentos no quedaban tablas de cobertura/plan. Los objetivos huérfanos por kill intencional del coordinador los limpió **el harness de diagnóstico**, no el motor automáticamente; no se puede ocultar tras “sin fugas” final. Las pruebas de ciclo de vida confirman por separado limpieza normal tras caller/cancel/shutdown.

Contadores aditivos propuestos: `stability_attempts`, `stability_completed`, `stability_missing`, `stability_target_failures`, `stability_infra_failures`. No incrementar `stats.executions`/`discoveries`/`rejections` por repeticiones; conservar `calibrations` como pasada inicial por compatibilidad. Tiempo de pared: añadir `stability_us`, `stability_in_mutation_us`, `mutation_active_us = existing mutation_us - stability_in_mutation_us`. `mutation_us` puede seguir como tiempo de fase original; throughput nuevo usa **ejecuciones de mutación / mutation_active_us**, no R repeticiones en numerador. Informar por separado arranque/seeds, agregación, serialización y arranque de VM nueva. Desactivada la feature, no cambian tiempos/contadores/flujo existentes.

## 9. Plan de implementación y criterios de aceptación

Todos los cambios siguientes son **propuestos**, no existen hoy en el código.

| Etapa | Archivos/dependencias | Criterio de preparación | Desactivación y compatibilidad |
|---|---|---|---|
| 1. Prerrequisitos | `src/efz_executor.erl`, con protección `src/efz_cov_rt.erl`; `test/efz_backend_tests.erl`, casos nuevos focalizados | Origen terminal distingue exit capturado de kill; metadatos no prometen árbol completo; pérdida de propietario aborta/sucia; contexto roto capturado falla cerrado; permanecen 62/3 actuales | Se conservan outcomes y run/3; sin cambios de backend/worker predeterminados |
| 2. Contrato de admisión de snapshot | Metadatos ejecutor + propuesto `src/efz_stability.erl`; reutilizar manifest/preflight | F completo inmutable tras DOWN raíz y antes de destruir almacén; serie comprueba ámbito/build/limpieza; vacío != ausente, prefijo timeout != completo | No se reemplaza código backend; feedback existente no depende del observador |
| 3. Recolector offline | Propuestos `src/efz_calibration.erl`, `scripts/calibrate.escript`, módulos internos permitidos en denylist transform | Bytes congelados, protocolo R/estado, propietario vivo, mismo run/4; claves versionadas; cancelación/límites acotados; sin efectos de novedad | Solo llamada independiente explícita; campañas actuales no usan recolector |
| 4. Suite de regresión | Propuestas `test/efz_stability_tests.erl`, integración calibración, pruebas backend/semánticas existentes | Vector 50%, conjuntos de igual tamaño, frecuencia frente a multiplicidad, trampa de enmascarado de corpus, R<2/vacío/incompleto/incomparable; A→B→A, ámbito hijo, ID en VM nueva; excepción/kill/timeout/propietario/cancel; corrupción/build incompatible | Sin umbrales de rendimiento fijos ni cambios de conjuntos probe/outcome antiguos esperados |
| 5. Integración solo informativa | `efz_config`, `efz_worker`, `efz_stats`, documentación; índice opcional sin reinsertar corpus | Primer resultado + R−1; feedback original exactamente una vez; sin avanzar RNG/cursores; tiempos/contadores aparte; fallos testigo no ocultos | **`stability => disabled` por defecto**; activación explícita, R/95/90 configurables; baseline antiguo sin serie nueva |
| 6. Informes/medición | CLI/README/cobertura, experimento breve con presupuesto fijo | Filas por entrada, corpus ponderado/mínimo/inestables/pertenencia al subconjunto; coste real y distinción frío/caliente; JSON solo si hace falta | Informes/EFZR/CLI existentes conservados; sección aditiva versionada |

No iniciar implementación repitiendo `efz:start` por entrada: confunde inicialización de seeds con estabilidad, crea feedback separado y no reinicia toda la VM. Tampoco cambiar cuenta del scheduler/seed rand del objetivo para mejorar porcentaje. El modo principal sigue estándar; runtime alterado es experimento diagnóstico etiquetado aparte.

Preguntas externas abiertas solo sobre lo que este checkout no revela: contrato de reset/warmup/estado inicial de un objetivo real concreto y justificación de R/95/90. Faltan harness/dependencias Cowboy; no se verificó independencia universal de aplicaciones Erlang reales. En el contrato del motor raíz descrito están establecidos propietarios, snapshots, fallos y puntos iniciales de implementación; no se debe asumir un runner Go/OTP oculto.

## 10. Reproducir diagnósticos sin fixtures permanentes

Las fuentes siguientes son solo para auditoría. No forman parte de aplicación/perfiles de compilación ni implementan API de calibración de producción. Un `audit_sites` se compila con instrumentación automática normal; los demás módulos aportan entradas, estado y ACK controlados. Antes del kill se recibe mensaje tras probe completado; no se usan sleeps para demostrar publicación. Cada hijo creado se termina explícitamente y la prueba de pérdida de VM mata solo su helper externo.

Desde la raíz `efz/`:

```sh
AUDIT_DIR=$(mktemp -d /tmp/efz-calibration-audit.XXXXXX)
python3 - "$AUDIT_DIR" <<'PY'
from pathlib import Path
import re,sys
text=Path('docs/calibration-readiness.md').read_text()
blocks=re.findall(r'<!-- audit-source: ([a-z_.]+) -->\n```erlang\n(.*?)\n```',text,re.S)
assert {name for name,_ in blocks} == {'audit_sites.erl','audit_target.erl','audit_background.erl','audit.escript','existing_example.escript'}
for name,source in blocks:
    Path(sys.argv[1],name).write_text(source+'\n')
PY
rebar3 compile > "$AUDIT_DIR/compile.log" 2>&1
rebar3 eunit > "$AUDIT_DIR/eunit.log" 2>&1
rebar3 ct > "$AUDIT_DIR/ct.log" 2>&1
escript "$AUDIT_DIR/audit.escript" "$AUDIT_DIR" > "$AUDIT_DIR/diagnostic.log" 2>&1
escript "$AUDIT_DIR/existing_example.escript" "$AUDIT_DIR" > "$AUDIT_DIR/existing-example.log" 2>&1
```

No añadir silenciosamente `+S 4:4` a esta reproducción: controles principal/nuevos originales usaron configuración estándar. Comprobar exit status de cada comando; los archivos de registro no demuestran éxito por sí solos. Este script detecta intencionalmente con assertions las limitaciones actuales descritas; tras futuras correcciones hay que reconsiderar el resultado esperado, no usar el script viejo como prueba de política.

<!-- audit-source: audit_sites.erl -->
```erlang
-module(audit_sites).
-export([a/0,b/0,c/0,d/0]).
a()->a.
b()->b.
c()->c.
d()->d.
```

<!-- audit-source: audit_target.erl -->
```erlang
-module(audit_target).
-export([run/1]).
run(<<"a">>)->audit_sites:a(),audit_sites:b(),audit_sites:c(),ok;
run(<<"b">>)->audit_sites:a(),audit_sites:b(),audit_sites:d(),ok;
run(<<"only_a">>)->audit_sites:a();
run(<<"only_b">>)->audit_sites:b();
run(<<"alternate">>)->
 N=persistent_term:get({?MODULE,alternate},0),persistent_term:put({?MODULE,alternate},N+1),
 case N rem 2 of 0->run(<<"a">>);1->run(<<"b">>) end;
run(<<"state_a">>)->case persistent_term:get({?MODULE,dirty},false) of false->audit_sites:c();true->audit_sites:d() end;
run(<<"state_b">>)->persistent_term:put({?MODULE,dirty},true),audit_sites:b();
run(<<>>)->{error,invalid_input};
run(<<"empty">>)->ok;
run(<<"halt">>)->audit_sites:a(),erlang:halt(23);
run(<<"hold">>)->run({hold,persistent_term:get({?MODULE,observer}),campaign});
run({repeat,N})->lists:foreach(fun(_)->audit_sites:a() end,lists:seq(1,N)),ok;
run({fail,Kind})->audit_sites:a(),case Kind of error->error(artificial);throw->throw(artificial);exit->exit(killed) end;
run({hold,P,Tag})->audit_sites:a(),P!{published,Tag,self(),get('$efz_execution_context')},receive finish->ok end;
run({local_state})->
 Before={get(audit_user_key),process_info(self(),messages),rand:export_seed()},
 put(audit_user_key,dirty),self()!audit_old_message,rand:seed(exsplus,{1,2,3}),audit_sites:a(),Before;
run({child,Kind,P,Copy})->
 audit_sites:a(),C=get('$efz_execution_context'),
 F=fun()->Before=get('$efz_execution_context'),
   case Copy of true->efz_cov:attach(C);false->ok end,
   P!{child_ready,self(),Before},receive go->ok end,
   Result=try audit_sites:c(),ok catch error:E->{error,E} end,
   P!{child_done,self(),Result}
 end,
 Child=case Kind of spawn->spawn(F);spawn_link->spawn_link(F);spawn_monitor->{CP,_}=spawn_monitor(F),CP end,
 {child,Child};
run({background,Bg})->audit_sites:a(),gen_server:call(Bg,work);
run({background_timer,Bg,P})->audit_sites:a(),erlang:send_after(0,Bg,{work,P}),ok;
run(<<"bad_context_caught">>)->put('$efz_execution_context',bad_context),try audit_sites:a() catch error:_->caught end;
run(<<"broken_table_caught">>)->C=get('$efz_execution_context'),put('$efz_execution_context',setelement(4,C,make_ref())),try audit_sites:a() catch error:_->caught end.
```

<!-- audit-source: audit_background.erl -->
```erlang
-module(audit_background).
-behaviour(gen_server).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2]).
init([])->{ok,#{}}.
handle_call(work,_,S)->audit_sites:c(),{reply,get('$efz_execution_context'),S}.
handle_cast(_,S)->{noreply,S}.
handle_info({work,P},S)->audit_sites:c(),P!{background_done,get('$efz_execution_context')},{noreply,S}.
```

<!-- audit-source: audit.escript -->
```erlang
#!/usr/bin/env escript
-mode(compile).
main([D,"fresh",Out])->
 paths(D),{ok,AB}=file:read_file(filename:join(D,"artifact.term")),A=binary_to_term(AB),
 {ok,Ms}=efz_instrument:preflight([A]),{ok,P}=efz_cov_manifest:prepare(automatic,Ms),
 R=run(<<"a">>,options(ets,P)),ok=efz_cov_manifest:release(P),
 ok=file:write_file(Out,term_to_binary(#{result=>R,online=>erlang:system_info(schedulers_online)}));
main([D,"halt",_Out])->
 paths(D),{ok,AB}=file:read_file(filename:join(D,"artifact.term")),{ok,Ms}=efz_instrument:preflight([binary_to_term(AB)]),
 {ok,P}=efz_cov_manifest:prepare(automatic,Ms),run(<<"halt">>,options(ets,P));
main([D])->
 paths(D),put(events,[]),
 lists:foreach(fun(M)->File=filename:join(D,atom_to_list(M)++".erl"),
   {ok,M}=compile:noenv_file(File,[debug_info,warnings_as_errors,{outdir,filename:join(D,"plain")}])
 end,[audit_target,audit_background]),
 {ok,A}=efz_instrument:compile(filename:join(D,"audit_sites.erl"),
   #{modules=>[audit_sites],source_root=>D,outdir=>filename:join(D,"targets")}),
 ok=file:write_file(filename:join(D,"artifact.term"),term_to_binary(A)),
 {ok,[M]}=efz_instrument:preflight([A]),
 put(identities,maps:from_list([{maps:get(function,X),{audit_sites,maps:get(build_id,M),maps:get(probe_id,X)}}||X<-maps:get(probes,M)])),
 OTPFile=filename:join([code:root_dir(),"releases",erlang:system_info(otp_release),"OTP_VERSION"]),
 emit(environment,#{otp_file=>file:read_file(OTPFile),otp=>erlang:system_info(otp_release),erts=>erlang:system_info(version),
  architecture=>erlang:system_info(system_architecture),schedulers=>erlang:system_info(schedulers),
  online=>erlang:system_info(schedulers_online),erl_flags=>os:getenv("ERL_FLAGS"),
  compiler=>compile:module_info(md5),manifest=>M,defaults=>efz_config:defaults()}),
 lists:foreach(fun(B)->suite(B,[M]) end,[ets,ets_member]),
 campaign_cases(A),fresh_vms(D),hot_code(D,A,[M]),
 []=tables(),emit(final_resources,#{coverage_and_plan_tables=>tables()}),
 Events=lists:reverse(get(events)),
 ok=file:write_file(filename:join(D,"events.term"),term_to_binary(Events)),
 ok=file:write_file(filename:join(D,"events.txt"),unicode:characters_to_binary(io_lib:format("~tp.~n",[Events]))),
 io:format("ALL DIAGNOSTIC ASSERTIONS PASSED (~B records)~n",[length(Events)]).
paths(D)->true=code:add_patha(filename:absname("_build/default/lib/efz/ebin")),
 ok=filelib:ensure_dir(filename:join([D,"plain","x"])),true=code:add_patha(filename:join(D,"plain")).
options(B,P)->#{coverage=>automatic,coverage_backend=>B,coverage_plan=>P}.
run(I,O)->efz_executor:run(audit_target,I,1000,O).
hits(R)->ok=maps:get(coverage_status,R),maps:get(coverage,R).
ids(Names)->lists:sort([maps:get(N,get(identities))||N<-Names]).
emit(K,V)->put(events,[{K,V}|get(events)]),io:format("PASS ~tp~n",[K]).
series(Sets)->
 R=length(Sets),U=lists:foldl(fun ordsets:union/2,[],Sets),
 F=lists:foldl(fun(S,M)->lists:foldl(fun(X,A)->A#{X=>maps:get(X,A,0)+1} end,M,ordsets:from_list(S)) end,#{},Sets),
 I=lists:sort([X||{X,N}<-maps:to_list(F),N=:=R]),
 Score=case R>=2 andalso U=/=[] of true->100*length(I)/length(U);false->not_applicable end,
 #{r=>R,union=>U,intersection=>I,variable=>ordsets:subtract(U,I),frequencies=>F,score=>Score}.
suite(B,Ms)->
 {ok,P}=efz_cov_manifest:prepare(automatic,Ms),O=options(B,P),
 First=[run(<<"a">>,O)||_<-lists:seq(1,3)],[H,H,H]=[hits(X)||X<-First],H=ids([a,b,c]),
 #{score:=100.0}=Stable=series([hits(X)||X<-First]),emit({B,deterministic},#{runs=>First,series=>Stable}),
 persistent_term:erase({audit_target,alternate}),
 Alt=[run(<<"alternate">>,O)||_<-lists:seq(1,3)],As=[hits(X)||X<-Alt],
 [3,3,3]=[length(X)||X<-As],#{score:=50.0}=S=series(As),
 [F1,F2,F3]=As,F1=F3,F2=ids([a,b,d]),
 50.0=maps:get(score,series([F2,F1,F2])),
 Collapsed=series([ordsets:union(X,Y)||{X,Y}<-lists:zip(As,[F2,F1,F2])]),100.0=maps:get(score,Collapsed),
 emit({B,alternation},#{runs=>Alt,series=>S,corpus_input_feature_score=>50.0,wrong_collapsed_score=>100.0}),
 R1=run({repeat,1},O),R100=run({repeat,100},O),H1=hits(R1),H1=hits(R100),H1=ids([a]),
 emit({B,multiplicity},#{once=>R1,hundred=>R100}),
 [AA,BB,AA]=[hits(run(X,O))||X<-[<<"only_a">>,<<"only_b">>,<<"only_a">>]],
 []=ordsets:intersection(AA,BB),
 Perms=[[<<"only_a">>,<<"only_b">>],[<<"only_b">>,<<"only_a">>]],
 Rows=[lists:sort([{X,hits(run(X,O))}||X<-Order])||Order<-Perms],[Row,Row]=Rows,
 emit({B,aba},#{a=>AA,b=>BB,permutations=>Rows}),
 persistent_term:erase({audit_target,dirty}),DA1=hits(run(<<"state_a">>,O)),_=run(<<"state_b">>,O),DA2=hits(run(<<"state_a">>,O)),
 #{score:=+0.0}=Dirty=series([DA1,DA2]),persistent_term:erase({audit_target,dirty}),DA1=hits(run(<<"state_a">>,O)),
 emit({B,shared_state},#{without_reset=>Dirty,after_explicit_fixture_reset=>DA1}),
 L1=run({local_state},O),L2=run({local_state},O),{ok,{undefined,{messages,[]},undefined}}=LO=maps:get(outcome,L1),LO=maps:get(outcome,L2),
 emit({B,local_state},#{runs=>[L1,L2]}),
 E=run(<<>>,O),E2=run(<<"empty">>,O),[]=hits(E),[]=hits(E2),{ok,{error,invalid_input}}=maps:get(outcome,E),
 #{score:=not_applicable}=EmptySeries=series([[],[]]),emit({B,empty},#{invalid_return=>E,empty_snapshot=>E2,series=>EmptySeries}),
 Failures=[run({fail,K},O)||K<-[error,throw,exit]],
 lists:foreach(fun(X)->H1=hits(X) end,Failures),emit({B,exceptions},Failures),
 concurrent(O),terminations(B,O),children(B,O),background(B,O),live_snapshot(B),
 Bad=run(<<"bad_context_caught">>,O),[]=hits(Bad),{ok,caught}=maps:get(outcome,Bad),
 Broken=run(<<"broken_table_caught">>,O),{error,_}=maps:get(coverage_status,Broken),{infrastructure,_}=maps:get(outcome,Broken),
 emit({B,context_interference},#{malformed_context_caught=>Bad,invalid_table_caught=>Broken}),
 {efz_cov_plan,1,PT,_}=P,emit({B,live_plan},#{owner=>ets:info(PT,owner),protection=>ets:info(PT,protection),rows=>ets:info(PT,size),bytes=>ets:info(PT,memory)*erlang:system_info(wordsize)}),
 ok=efz_cov_manifest:release(P),undefined=ets:info(PT),
 Disposed=run(<<"empty">>,O),{error,invalid_coverage_plan}=maps:get(coverage_status,Disposed),
 emit({B,disposed_empty},Disposed).
async(I,T,O)->Parent=self(),Tag=make_ref(),{C,M}=spawn_monitor(fun()->Parent!{done,Tag,efz_executor:run(audit_target,I,T,O)} end),{C,M,Tag}.
ready(Tag)->receive {published,Tag,T,C}->{T,C} after 3000->error(no_publication_ack) end.
finished({C,M,Tag})->R=receive {done,Tag,X}->X after 4000->error(no_result) end,
 down(M,C),R.
down(M,P)->receive {'DOWN',M,process,P,_}->ok after 3000->error(missing_down) end.
table({efz_context,1,_,{ets_member,T},_})->T;table({efz_context,1,_,T,_})->T.
concurrent(O)->
 Q1=make_ref(),Q2=make_ref(),C1=async({hold,self(),Q1},3000,O),C2=async({hold,self(),Q2},3000,O),
 {T1,X1}=ready(Q1),{T2,X2}=ready(Q2),false=element(3,X1)=:=element(3,X2),false=table(X1)=:=table(X2),
 T1!finish,T2!finish,R1=finished(C1),R2=finished(C2),A=ids([a]),A=hits(R1),A=hits(R2),
 undefined=ets:info(table(X1)),undefined=ets:info(table(X2)),
 emit({maps:get(coverage_backend,O),concurrent},#{first=>R1,second=>R2,separate_refs_and_tables=>true}).
terminations(B,O)->
 lists:foreach(fun(Kind)->Q=make_ref(),H={Caller,CM,_}=async({hold,self(),Q},case Kind of timeout->1000;_->3000 end,O),
 {T,C}=ready(Q),Owner=element(5,C),TM=monitor(process,T),OM=monitor(process,Owner),
 {ok,Before}=efz_cov:snapshot(C),Before=ids([a]),
 case Kind of
  kill->exit(T,kill),R=finished(H),{exit,killed}=maps:get(outcome,R),Before=hits(R),down(TM,T),down(OM,Owner),emit({B,kill},R),
    Caught=run({fail,exit},O),Keys=[outcome,target_outcome,coverage_status,coverage,builds],
    true=maps:with(Keys,R)=:=maps:with(Keys,Caught),emit({B,exit_origin_ambiguity},#{caught_exit=>Caught,external_kill=>R});
  timeout->R=finished(H),{timeout,1000}=maps:get(outcome,R),Before=hits(R),down(TM,T),down(OM,Owner),emit({B,timeout},R);
  caller_death->exit(Caller,kill),down(CM,Caller),down(TM,T),down(OM,Owner),emit({B,caller_death},#{snapshot_returned=>false});
  coordinator_kill->exit(Owner,kill),R=finished(H),down(OM,Owner),true=is_process_alive(T),
    {infrastructure,{coordinator_down,killed}}=maps:get(outcome,R),{error,coordinator_down}=maps:get(coverage_status,R),
    []=maps:get(coverage,R),exit(T,kill),down(TM,T),emit({B,coordinator_kill},#{result=>R,target_was_alive_after_result=>true,diagnostic_harness_killed_orphan=>true})
 end,undefined=ets:info(table(C))
 end,[kill,timeout,caller_death,coordinator_kill]).
children(B,O)->
 lists:foreach(fun({Kind,Copy})->R=run({child,Kind,self(),Copy},O),{ok,{child,CP}}=maps:get(outcome,R),
 receive {child_ready,CP,undefined}->ok after 3000->error(no_child_ready) end,
 true=is_process_alive(CP),CM=monitor(process,CP),Q=make_ref(),H=async({hold,self(),Q},3000,O),{T,_}=ready(Q),
 CP!go,CR=receive {child_done,CP,V}->V after 3000->error(child_not_done) end,down(CM,CP),
 case Copy of false->ok=CR;true->{error,{efz_infrastructure,invalid_coverage_table}}=CR end,
 T!finish,Next=finished(H),A=ids([a]),A=hits(R),A=hits(Next),
 emit({B,child,Kind,Copy},#{parent=>R,next_execution=>Next,child_result=>CR,child_context_before_attach=>undefined})
 end,[{spawn,false},{spawn_link,false},{spawn_monitor,false},{spawn,true}]).
background(B,O)->
 {ok,Bg}=gen_server:start(audit_background,[],[]),
 R=run({background,Bg},O),{ok,undefined}=maps:get(outcome,R),
 Timer=run({background_timer,Bg,self()},O),receive {background_done,undefined}->ok after 3000->error(no_timer_ack) end,
 A=ids([a]),A=hits(R),A=hits(Timer),ok=gen_server:stop(Bg),emit({B,background},#{otp_call=>R,timer=>Timer}).
live_snapshot(B)->
 C=efz_cov:open(B),FakeRef=make_ref(),Copied=setelement(3,C,FakeRef),Parent=self(),
 {Writer,Mon}=spawn_monitor(fun()->efz_cov:attach(Copied),audit_sites:a(),Parent!writer_ready,
   receive write_more->audit_sites:b() end,Parent!writer_finished end),
 receive writer_ready->ok after 3000->error(no_writer_ack) end,
 {ok,First}=efz_cov:snapshot(C),First=ids([a]),
 Writer!write_more,receive writer_finished->ok after 3000->error(no_second_ack) end,down(Mon,Writer),
 {ok,Second}=efz_cov:snapshot(C),Second=ids([a,b]),ok=efz_cov:close(C),
 emit({B,unguarded_snapshot_and_ref},#{before_quiescence=>First,after_quiescence=>Second,changed_reference_accepted=>true}).
campaign_cases(A)->
 lists:foreach(fun(Kind)->
  persistent_term:put({audit_target,observer},self()),
  {ok,_}=efz:start(#{target=>audit_target,artifacts=>[A],seeds=>[<<"hold">>],max_iterations=>0,timeout=>3000}),
  {T,C}=ready(campaign),Owner=element(5,C),TM=monitor(process,T),OM=monitor(process,Owner),
  [{efz_worker,W,worker,_}]=supervisor:which_children(efz_worker_sup),
  case Kind of
   cancel->Await=catch efz:await(0),{'EXIT',{timeout,_}}=Await,true=is_process_alive(T),
     ok=efz:stop(),emit(campaign_cancel,#{await_timeout_did_not_cancel=>true,result_snapshot=>unavailable});
   worker_kill->exit(W,kill),R=efz:await(3000),{infrastructure_failure,{worker_down,killed}}=maps:get(status,R),
     emit(worker_kill,R),ok=efz:stop()
  end,down(TM,T),down(OM,Owner),[]=tables()
 end,[cancel,worker_kill]),
 {ok,_}=efz:start(#{target=>audit_target,artifacts=>[A],seeds=>[<<"only_a">>,<<"only_b">>],max_iterations=>0}),
 R=efz:await(3000),#{calibrations:=2,executions:=0,discoveries:=0}=maps:get(stats,R),
 [seed_calibration,seed_calibration]=[maps:get(retention_reason,X)||X<-maps:get(decisions,R)],
 emit(seed_initialization,R),ok=efz:stop().
fresh_vms(D)->
 Samples=[begin Out=filename:join(D,"fresh-"++integer_to_list(N)++".term"),
   {0,Text}=child_vm(D,"fresh",Out),ok=file:write_file(Out++".log",Text),
   {ok,Bytes}=file:read_file(Out),binary_to_term(Bytes)
 end||N<-lists:seq(1,3)],
 [R1,R2,R3]=[maps:get(result,X)||X<-Samples],F=hits(R1),F=hits(R2),F=hits(R3),F=ids([a,b,c]),
 B=maps:get(builds,R1),B=maps:get(builds,R2),B=maps:get(builds,R3),
 emit(fresh_vm_same_build,#{samples=>Samples,series=>series([F,F,F])}),
 Out=filename:join(D,"halt-result.term"),{23,Text}=child_vm(D,"halt",Out),false=filelib:is_file(Out),
 ok=file:write_file(filename:join(D,"halt.log"),Text),emit(vm_halt,#{exit_status=>23,snapshot_file=>missing}).
child_vm(D,Mode,Out)->
 Port=open_port({spawn_executable,os:find_executable("escript")},[binary,exit_status,stderr_to_stdout,
   {args,[filename:join(D,"audit.escript"),D,Mode,Out]}]),port_result(Port,<<>>).
port_result(P,Acc)->receive {P,{data,B}}->port_result(P,<<Acc/binary,B/binary>>);{P,{exit_status,N}}->{N,Acc}
 after 10000->port_close(P),error(child_vm_deadline) end.
hot_code(D,A,Ms)->
 {ok,P}=efz_cov_manifest:prepare(automatic,Ms),O=options(ets,P),
 {ok,audit_sites,Plain}=compile:noenv_file(filename:join(D,"audit_sites.erl"),[binary,debug_info,warnings_as_errors]),
 code:purge(audit_sites),code:delete(audit_sites),{module,audit_sites}=code:load_binary(audit_sites,"diagnostic_plain",Plain),
 R=run(<<"a">>,O),[]=hits(R),{ok,ok}=maps:get(outcome,R),
 {error,{loaded_module_identity_mismatch,audit_sites}}=Preflight=efz_instrument:preflight([A]),
 emit(hot_plain_replacement,#{old_plan_result=>R,explicit_preflight=>Preflight}),
 ok=efz_cov_manifest:release(P),code:purge(audit_sites),code:delete(audit_sites),{ok,_}=efz_instrument:preflight([A]).
tables()->[T||T<-ets:all(),lists:member(ets:info(T,name),[efz_execution_coverage,efz_coverage_plan])].
```

<!-- audit-source: existing_example.escript -->
```erlang
#!/usr/bin/env escript
-mode(compile).
main([D])->
 true=code:add_patha(filename:absname("_build/default/lib/efz/ebin")),
 {ok,A}=efz_instrument:compile("examples/simple_parser/efz_example_parser.erl",
  #{modules=>[efz_example_parser],source_root=>".",outdir=>filename:join(D,"existing-target")}),
 {ok,Ms}=efz_instrument:preflight([A]),{ok,P}=efz_cov_manifest:prepare(automatic,Ms),
 Rows=[begin Rs=[efz_executor:run(efz_example_target,B,1000,#{coverage=>automatic,coverage_backend=>ets,coverage_plan=>P})||_<-lists:seq(1,3)],
  [H,H,H]=[maps:get(coverage,R)||R<-Rs],true=H=/=[],[ok,ok,ok]=[maps:get(coverage_status,R)||R<-Rs],
  #{input=>B,runs=>Rs,exact_sets_equal=>true,feature_stability=>100.0}
 end||B<-[<<0>>,<<255>>]],
 ok=efz_cov_manifest:release(P),
 ok=file:write_file(filename:join(D,"existing-example.term"),term_to_binary(Rows)),
 io:format("~tp~n",[Rows]).
```
