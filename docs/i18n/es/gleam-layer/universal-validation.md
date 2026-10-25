# Gleam Layer: implementación y resultados verificables

[English](../../../gleam-layer/universal-validation.md) · [Русский](../../ru/gleam-layer/universal-validation.md) · **Español** · [简体中文](../../zh-CN/gleam-layer/universal-validation.md) · [Todos los idiomas](../../README.md)

**Estado actual al 13 de octubre de 2026: P5 PASS dentro del contrato declarado.**
Las comprobaciones se reanudaron y completaron a petición del usuario; consulte
[p5-validation.md](p5-validation.md). El informe histórico del 10 de octubre
conserva el estado y las limitaciones de entonces.

Estado al 10 de octubre de 2026: contrato común, adaptador term/API, plugins
QS y XML-RPC, harness con estado e integración de persistencia/reproducción
implementados. Las llamadas reales y comprobaciones principales se hicieron
antes de la última instrucción «No ejecutar pruebas». Después solo hubo
revisión estática, cambios de script de reproducción/documentación e inspección
de artefactos existentes.

La aceptación completa sigue abierta: no se ejecutó la nueva CLI general de
reproducción y las mediciones comparativas son de instantáneas anteriores.
No se ejecutó serie aislada nueva para fuentes finales siguiendo la instrucción.
Las medidas guardadas no son aceptación de rendimiento ni evidencia de mejora
de velocidad/detección.

## Estado inicial y conservación del trabajo

Referencia: `e4c0244c403d74b041df7e0e2f0dd4465a977453`, rama `feat/gleam-layer`.
HEAD intacto. Antes de editar se guardaron
[baseline.json](../../../../artifacts/gleam-layer/20261010-universal/baseline.json),
[user-before.status](../../../../artifacts/gleam-layer/20261010-universal/user-before.status)
y `user-before.patch`. Ya existían los no seguidos `artifacts/`,
`efz_socket_regression_pack/`, `fuzz/` del usuario; sin reset/clean/stash ni
reemplazar corpus/hallazgos. Los resultados se añadieron a
`artifacts/gleam-layer/20261010-universal/`.

La capa antigua usó checkout fuente separado por `git archive HEAD` en
`/tmp/efz-universal-baseline-e4c0244`, sin cambiar la copia principal. Es otro
checkout, no Git worktree. Ajustes: OTP 27.0 / ERTS 15.0, Rebar3 3.25.0,
`ERL_FLAGS='+S 2:2'`, Gleam 1.10.0 de `/tmp/efz-gleam-toolchain/gleam`.
No se completó obtener dependencias de referencia por red; se usó caché
local fijada existente. Compilaciones ordinaria/opcional de referencia pasan.
EUnit completo no: 269 superadas, 1 fallida y pruebas canceladas; log en
[baseline-eunit-prior.log](../../../../artifacts/gleam-layer/20261010-universal/baseline-eunit-prior.log).
El fallo incluye esperas antiguas de pared en pruebas de corrupción/planificador.
Los wrappers actuales recibieron más tiempo; presupuestos y aserciones intactos.
No es una corrección de rendimiento de referencia.

## Arquitectura y contrato público

[efz_semantic_adapter.erl](../../../../src/efz_semantic_adapter.erl) es el behaviour
público; [efz_gleam_adapter.erl](../../../../src/efz_gleam_adapter.erl) ofrece preflight
fuera del bucle, dispatch y validación común. No hay lista central de
bibliotecas/objetivos nuevos. Cada adaptador comprueba metadatos del harness
en `prepare/3` propio. Un adaptador se selecciona explícitamente por campaña.

Firmas y límites exactos en [adapter-contract.md](adapter-contract.md):

```erlang
descriptor() -> DescriptorMap.
prepare(Target, Options, Limits) -> {ok, ImmutableContext} | {error, Reason}.
code_dependencies(Context) -> #{semantic => [Module], target => [Module]}.
generate(Index, Context) -> {ok, Raw} | {skip, Atom} | {error, Reason}.
mutate(Raw, OperationId, #{choice => Integer}, Context) ->
    {ok, Raw, RecipeDataMap} | {skip, Atom} | {error, Reason}.
observe(Raw, PrimaryOutcome, Context) ->
    {ok, LocalFeatureIds} | {skip, Atom} | {error, Reason}.
oracle(Raw, PrimaryOutcome, Context) ->
    {pass, {PropertyId, Version}} | {fail, {PropertyId, Version}} |
    {inconclusive, Atom} | {error, Reason}.
shrink(Raw, Context) -> {ok, [RawCandidate]} | {skip, Atom} | {error, Reason}.
```

Solo `descriptor/0` y `prepare/3` son obligatorios; `code_dependencies/1` es
opcional. Los operativos se exigen por capacidad declarada. El descriptor
contiene ID binario estable, API 1, versiones de modelo/observador/receta/
catálogo, capacidades, IDs de operaciones, módulos y propiedades/versiones.
Índice generador 0..4095; único parámetro mutador `choice` 0..65535; catálogo
hasta 256 IDs únicos 0..65535. Observador hasta 64 IDs locales 0..255.
El dispatcher crea `{AdapterId, ObserverVersion, LocalId}` y deduplica.
Shrink devuelve hasta 64 binarios acotados. Todas las versiones 1..65535.

EFZ conserva bucle, RNG, planificador, plan de mutación, feedback y corpus.
Callbacks inline BEAM con contexto inmutable. Sin motor/NIF nuevo, servicio
de modelo, worker obligatorio ni proceso por callback. API 1 pasa resultado
completado de única ejecución principal; observación/oráculo no repiten.
Catch captura excepciones, no detiene callback infinito: el plugin debe
implementar algoritmos y presupuestos finitos.

`skip`, sin cambios y límite recurren a alternativa de bytes existente.
`inconclusive` no crea hallazgo. Callback inválido/excepción es error de
infraestructura que termina campaña, no defecto de biblioteca. Solo vulnerar
explícitamente una propiedad declarada en su subconjunto crea hallazgo.
Rechazo esperado fuera de ese predicado no es hallazgo semántico.

Con `gleam_layer => false` no hay dispatch/decode semántico ni extracción RNG
adicional. Fracción 0 no selecciona rama ni decodifica mutación; observador/
oráculo activados aparte funcionan. `observation_only` no guía corpus/
planificador. `guided` admite entradas solo semánticas en corpus ordinario
y selección estándar de padres.

## Integraciones term/API, dominio y con estado

[efz_term_codec.erl](../../../../src/efz_term_codec.erl) guarda argumentos en códec
binario determinista propio `EFZT`, esquema 1. No cambia entradas XML/QS
originales. Admite enteros con signo 64 bits, flotantes finitos, booleanos,
binarios, charlist Unicode escalar, listas propias, tuplas, mapas y
combinaciones anidadas acotadas. Átomos solo de conjunto finito existente en
configuración fiable; bytes no crean átomos. Tipo de retorno no define
argumentos. El observador clasifica de forma acotada resultado/árbol y no
prueba corrección de API arbitraria.

[efz_term_api_adapter.erl](../../../../src/efz_term_api_adapter.erl) usa primitivas
Gleam comunes `efz_term_model`; sin paquete nuevo por biblioteca. Oráculo
genérico desactivado por defecto. Una propiedad personalizada define aparte
`(DecodedArgs, PrimaryOutcome) -> true | false | inconclusive`, ID
`generic_custom_property` versión 1 e identidad propia de código.
Cinco operaciones cambian escalar, insertan/eliminan elemento, reemplazan
subárbol o transforman contenedor acotado respetando restricciones. EFZ decide
RNG y registra procedencia.

Integraciones validadas con el mismo adaptador:

| API | Harness/configuración | Argumentos y resultado |
| --- | --- | --- |
| `lists:reverse/1` | `efz_term_reverse_target`, [lists_reverse.term](../../../../examples/semantic_configs/lists_reverse.term) | Lista de enteros → lista |
| `maps:find/2` | `efz_term_maps_target`, [maps_find.term](../../../../examples/semantic_configs/maps_find.term) | Clave/mapa → `{ok, Value}` o `error` |
| `efz_term_tuple_library:combine/2` | `efz_term_tuple_target`, [tuple_api.term](../../../../examples/semantic_configs/tuple_api.term) | Mapa/tupla → término Erlang |
| Contador con estado | `efz_stateful_target`, [stateful.term](../../../../examples/semantic_configs/stateful.term) | Comandos/handles de recurso → traza acotada |
| XML-RPC | `efz_xmlrpc_target`, [xmlrpc.term](../../../../examples/semantic_configs/xmlrpc.term) | Bytes XML originales → término del decoder |
| cow_qs | `efz_qs_target`, [cow_qs.term](../../../../examples/semantic_configs/cow_qs.term) | Bytes QS originales → pares/rechazo |

Ruta estándar de una hipotética `example_library`: añadir harness con `run/1`
y `semantic_contract/0`, configurar `{Module, Function, Arity}` y argumentos,
elegir `efz_term_api_adapter`. Para restricciones de formato especiales,
añadir adaptador/modelo de dominio con el mismo behaviour. No cambian worker,
configuración, corpus, planificador ni reproducción. Un fixture independiente
de longitud prefijada solo usa objetivo/adaptador/configuración; los de solo
observación/generación no necesitan modelo XML/QS, mutación ni oráculo.
Dos adaptadores con ID local 1 reciben espacios distintos.

Defaults: bytes 4096, depth 8, nodes 128, collection 32, operations 1;
máximos: 1 MiB, profundidad 16, nodos 4096, colección 256. Por defecto un
argumento binary/charlist también se limita a 32, no 4096 bytes. Charlist
guarda puntos como enteros etiquetados; el harness convierte a codificación
API. Aridad 0..min(collection,255). El ámbito de decode de campaña no puede
superar `semantic_contract.input_limits` del harness. Otro fixture comprueba
collection 64 con lista mayor de 32.

PID/ref/port/fun no se guardan como literales portables. El simbólico
`{'$efz_resource', Handle}` usa enumeración finita; el harness recrea recurso
para ejecución/reproducción y limpia en `after`. El contador permite hasta
16 comandos get/put/add/reset, estado cero y gen_server nuevo no registrado
por entrada. El guardian exige hijos admitidos; usa `efz_target:spawn_link/1`,
metadatos proc_lib OTP 27 y `gen_server:enter_loop/3` público. Se documenta
el vínculo a OTP 27; spawn/recursos arbitrarios no gestionados no se admiten
automáticamente. La traza separa `scenario_executions => 1` y
`library_operations => N`; preparación/limpieza excluidas de N. Se comprobaron
resultados independientes, ausencia de estado heredado y limpieza ante
excepción/tiempo límite.

## Persistencia, identidades y compatibilidad

Se usa el mecanismo BEAM/ejecución existente, no otro almacén. Identidad
semántica incluye descriptor, identidades de adaptador/modelo/helper/objetivo,
opciones deterministas opacas, límites efectivos y SHA-256 del contexto
preparado portable. Metadatos guardan ID/versión de propiedad,
observador/catálogo y procedencia RNG.

Recetas nuevas, esquema 4/operación 3, contienen reemplazo binario acotado y
RecipeData opacos. Carga/regeneración/reproducción de bytes no necesitan
adaptador/modelo; harness genérico necesita BEAM ordinario del códec.
`regenerate_semantic/2` es comprobación opcional separada de mutación con
identidad exacta. Artefactos de propiedad esquema 2 necesitan configuración
fiable explícita e identidades coincidentes. El artefacto no elige código.
Reiniciar conserva bytes canónicos y recalcula feedback por calibración;
diferencias siguen `reject | recalibrate` y no reutilizan características
ajenas silenciosamente.

Minimización conserva ID/versión/contexto/predicado y cuenta reproducción
inicial, todos los candidatos y verificación final. Shrink estructural solo
propone candidatos al predicado existente; después reduce bytes. Corpus
y grupos originales no se sobrescriben. Se informa agotamiento de
presupuesto/plazo; no se promete mínimo global.

Se conserva `efz_qs_model`. Operaciones, límites, resultados, características
y `query_model_agreement` pasaron a `efz_qs_adapter`. `efz_qs_legacy` solo
contiene configuración implícita vieja para dos objetivos históricos;
no es ruta para bibliotecas nuevas. Firmas directas antiguas, recetas 1/2/3
y hallazgos QS esquema 1 mantienen garantías. Mutación antigua mantiene
extracciones RNG previas; el adaptador explícito también registra `choice`,
por lo que trazas nuevas/antiguas no tienen que coincidir.

Una sonda fija antes/después comparó 24 generaciones, 11 fixtures,
66 operaciones, decode/resultados/características/oráculo. Igualdad exacta,
SHA-256 `daa8274871c75cc0a611e9509b5154b9d1a335d6ac986694f103ada30cd6c87e`.
Consulte [qs-compatibility.json](../../../../artifacts/gleam-layer/20261010-universal/qs-compatibility.json).
La evidencia complementa regresiones reales, no su diff.

`scripts/gleam_replay.escript` general acepta `--config`, `--finding`,
`--budget`, `--out` y `--code-path` repetido. Preflight fuera del bucle compara
límites/identidad fiables antes de ejecutar; el presupuesto incluye
reproducción y minimizador. La salida se crea tras reproducir; directorio/
enlace existente se rechaza. El cuerpo QS de cinco argumentos pasó a
`gleam_replay_legacy.escript`. **El wrapper/reenvío nuevo tuvo revisión
estática, pero no verificación ejecutada después de prohibir pruebas.**
Las API Erlang principales se comprobaron antes.

## XML-RPC: ámbito real

Se usó commit etnt/xmlrpc `fb46463b2acadf164ec534d9e2033e194341c507`, con
preparación de identidad/artefactos en `_build/xmlrpc-example/`.
`efz_xmlrpc_target:run/1` convierte binario a charlist y llama una vez al
`xmlrpc_decode:payload/1` real. No usa HTTP/TCP, métodos de aplicación ni
encoder.

Modelo Gleam independiente v1: methodCall, parámetros, int32 explícito,
boolean 0/1, string y array/struct anidados. ASCII imprimible U+0020..U+007E
y cinco entidades XML predefinidas; gramática exacta limitada. Límites de
ejemplo: 4096 bytes, profundidad 8, nodos 128, colección 16, string/nombre
128 bytes. Nombres desde átomos existentes o charlists a binarios sin crear
átomos. Los valores semánticos del modelo se comparan con decoder real,
no los bytes XML.

Oráculo/generación/mutación no admiten response/fault, i4, double, date,
base64, nil, strings implícitos, UTF-8 no ASCII, gramática XML amplia,
espacios entre etiquetas, atributos, etiquetas autocerradas, entidades
numéricas, DTD, CDATA ni espacios de nombres. El observador puede clasificar
response/fault; no es oráculo de su corrección. Propiedades de encoder e
ida y vuelta semántica tampoco implementadas. Sus requisitos de nombres
atómicos/salida iolist no amplían el predicado del decoder.

Cobertura: solo `xmlrpc_decode`/`xmlrpc_util` preparados. `xmerl_scan` participa
en identidad de ejecución, sin medir cobertura interna. `strict => false`
necesario por valores record de xmerl.hrl; cláusulas ejecutables sí tienen
sondas. Adaptador/modelo/observador/oráculo/helpers no cuentan. API stdlib
sin artefactos usan `none`.

## Comprobaciones ya realizadas

Los comandos siguientes registran ejecuciones completadas. No se repitieron
tras la prohibición. Logs en `artifacts/gleam-layer/20261010-universal/`.

| Comando / comprobación | Resultado guardado | Log/artefacto |
| --- | --- | --- |
| `ERL_FLAGS='+S 2:2' rebar3 compile` | PASS; predeterminada sin Gleam/modelo | `compile-final.log` |
| `ERL_FLAGS='+S 2:2' rebar3 eunit` | 300/300 PASS antes de añadir pruebas CLI | `eunit-off-final.log` |
| `ERL_FLAGS='+S 2:2' rebar3 eunit --module=efz_semantic_cli_tests` | 3/3 PASS | `semantic-cli-off-final.log` |
| `ERL_FLAGS='+S 2:2' rebar3 ct` | 3/3 PASS | `ct-final.log` |
| `ERL_FLAGS='+S 2:2' rebar3 xref` | Salida 0, sin avisos | `xref-final.log` |
| `ERL_FLAGS='+S 2:2' rebar3 dialyzer` | Salida 0, sin avisos | `dialyzer-final.log` |
| `ERL_FLAGS='+S 2:2' GLEAM_BIN=/tmp/efz-gleam-toolchain/gleam rebar3 as gleam compile` | PASS | `optional-compile-final.log` |
| `ERL_FLAGS='+S 2:2 -pa /home/fbogoslavskii/efz-fuzz/_build/xmlrpc-example/dependency-ebin' GLEAM_BIN=/tmp/efz-gleam-toolchain/gleam rebar3 as gleam eunit` | 368/368 PASS, salida 0 | `eunit-optional-final.log` |
| Siete configuraciones por `scripts/fuzz.escript --config … --max-iterations 2` | Salida 0; adaptador desconocido salida 2 | `cli-final/results.json` |
| Generadores genérico/dominio, compilar `-Werror`, llamada de semilla, CLI; repetir creación | PASS; repetir salida 2 y hashes originales intactos | `scaffold-final.json` |
| Sonda QS antes/después | Igualdad exacta | `qs-compatibility.json` |

Las comprobaciones cubren dispatch BEAM directo, distintas API/aridades,
límites anidados de códec/mutación, átomos/recursos finitos, reset/limpieza,
callbacks ausentes/opcionales, adaptador/opciones/capacidades desconocidos,
ABI del modelo, errores de capa, malformados/rechazo/alternativa, procedencia
RNG determinista, admisión/selección de padres solo semánticas,
reinicio/recalibración, reproducción en VM separada sin BEAM de modelo/
adaptador, identidades distintas, regeneración normal/semántica,
minimización que conserva predicado y presupuesto/plazo. XML comprueba
18 llamadas generadas reales, 216 mutaciones y concordancia independiente.
Fixtures QS antiguos también se conservan.

Se conservaron logs tempranos fallidos, incluida selección incorrecta de
prueba específica, directorio de salida antiguo y expected_harness ausente
corregido en prueba XML de reproducción. No se presentan como PASS; la suite
opcional completa pasó tras corregir. Suite predeterminada 300 y CLI específica
3 no se representan como una ejecución completa de 303.

## Mediciones comparativas guardadas: preliminares

En el mismo Intel i7-1260P, afinidad CPU 0/1, OTP 27 y `+S 2:2`:

* QS antiguo/nuevo/off: 3 repeticiones, mismas seis semillas, RNG `{17,18,19}`,
  300 mutaciones + 6 calibraciones = 306 ejecuciones principales/totales por
  muestra. Calentamiento separado de 20 mutaciones excluido de 306.
  Backend `otp_native_public`, BEAM objetivo compartido SHA-256
  `c407d6be5bb023b5ea907ff2bfc69820fe90dc9f39932caf688bcba7ea07464f`,
  tiempo límite objetivo 1000 ms, plazo campaña 120000 ms y driver 135 s.
* Genérico/XML/con estado off/on: 3 repeticiones, una semilla idéntica por API,
  RNG `{17,23,41}`, 100 mutaciones + 1 calibración = 101 principales/totales,
  extras 0; ETS solo del objetivo, timeout 1000 ms, plazo 30000 ms,
  driver 45 s, calentamiento 0. Genérico es combine/2 de biblioteca de tuplas.

Las 9/9 QS y 18/18 demás muestras completaron presupuesto, salida 0 y sin
agotamiento del driver. Son instantáneas completadas, no tiempos límite
prematuros llamados finalizados. Medianas de pared incluyen preparación/
calibración; tiempo del driver con arranque VM guardado aparte en runs.json.

| Instantánea / modo | Mediana de pared, ms | Rango, ms | Principales/s | Cobertura | Novedad solo semántica | Éxito / alternativa del proveedor |
| --- | ---: | --- | ---: | ---: | ---: | --- |
| QS old | 739.309 | 713.198..753.390 | 413.900 | 47 | 1 | 11 / 16* |
| QS new explicit | 723.828 | 722.336..729.559 | 422.752 | 48 | 1 | 9 / 22 |
| QS off | 756.010 | 742.380..771.641 | 404.757 | 46 | 0 | 0 / 0 |
| Generic off | 1332.773 | 495.633..1693.731 | 75.782 | 1 | 0 | 0 / 0 |
| Generic on | 314.443 | 307.972..370.118 | 321.203 | 1 | 1 | 7 / 4 |
| XML-RPC off | 1740.152 | 461.274..1854.316 | 58.041 | 26 | 0 | 0 / 0 |
| XML-RPC on | 1923.890 | 1865.013..2250.691 | 52.498 | 37 | 1 | 5 / 5 |
| Stateful off | 524.489 | 327.623..1620.321 | 192.568 | 6 | 0 | 0 / 0 |
| Stateful on | 337.611 | 334.484..389.764 | 299.161 | 6 | 1 | 3 / 5 |

La alternativa se lee de contadores originales, no del agregado previo
incorrecto. `*` QS viejo no tenía contador común: 27 intentos − 11 éxitos =
16, también 3 límites + 11 no admitidos + 2 sin cambios. En resúmenes antiguos
XML/con estado/QS nuevo, sin cambios se añadía de nuevo a alternativas que
ya lo incluían; contienen 6/6/26 en lugar de 5/5/22. No se reescribieron los
artefactos; se corrigieron drivers para una serie futura.

El coste con estado es de todas las entradas, incluido rechazo del códec,
no coste aislado de escenario aceptado. Reconstruido de paquetes canónicos:
off 1 escenario válido/3 comandos/100 paquetes rechazados; on 5/14/96.
Reconstruye operaciones planeadas, no agregado runtime de gen_server
completadas. `primary_scenarios=101` antiguo nombraba incorrectamente
101 ejecuciones principales. El fixture distingue 1 escenario/N operaciones;
medir completamente escenarios aceptados y operaciones reales sigue pendiente.

Microbenchmark separado: 3×1000 llamadas por ruta, 100 calentamiento, una
llamada objetivo de preparación fuera de tiempo, 0 llamadas medidas.
Medianas adaptador directo / fachada validada, µs:

| Callback | Genérico | QS | XML-RPC |
| --- | --- | --- | --- |
| Generación | 0.943 / 1.003 | 0.211 / 0.270 | 0.499 / 0.560 |
| Mutación | 1.935 / 2.394 | 2.539 / 3.552 | 1.494 / 1.890 |
| Observación | 0.479 / 1.251 | 0.250 / 0.491 | 0.187 / 0.490 |
| Oráculo | 0.024 / 0.060 | 1.531 / 1.672 | 0.581 / 0.669 |

Aquí el oráculo genérico es `inconclusive,no_property`, no el coste de
comprobar una API. Es coste con entrada fija, no todos los tamaños/formatos.
Características de distintos adaptadores no se comparan como escala común.

Evidencias:
[manifiesto performance-final](../../../../artifacts/gleam-layer/20261010-universal/performance-final/manifest.json),
[ejecuciones](../../../../artifacts/gleam-layer/20261010-universal/performance-final/runs.json),
[manifiesto QS](../../../../artifacts/gleam-layer/20261010-universal/qs-performance-final/manifest.json),
[ejecuciones QS](../../../../artifacts/gleam-layer/20261010-universal/qs-performance-final/runs.json),
summary.json individuales y *-callbacks.json.

Motivo del estado preliminar: hashes performance-final ya difieren del
núcleo/códec/worker y driver actuales; el manifiesto QS registra objetivo
compartido y parte limitada de identidades, no plugin/dispatcher final
completo. La serie anterior también solapó preparación de artefactos con otra
medición. Con n=3, trazas RNG idénticas y variación de pared observada, no
pueden afirmarse aceleración, mejor detección ni aceptación de rendimiento.
La primera preparación QS fallida (`cow_inline.hrl` ausente) se guarda
separada y no produjo resultados inventados.

## Archivos cambiados y validación pendiente

| Grupo | Archivos/directorios | Propósito |
| --- | --- | --- |
| Frontera pública/plugins | `src/efz_semantic_adapter.erl`, `efz_gleam_adapter.erl`, `efz_term_api_adapter.erl`, `efz_term_codec.erl`, `efz_qs_adapter.erl`, `efz_qs_legacy.erl`, `efz_xmlrpc_adapter.erl` | Contrato, códec genérico, preflight, dispatch acotado y semántica privada |
| Integración del núcleo | `efz_mutation_plan.erl`, `efz_mutation.erl`, `efz_worker.erl`, `efz_semantic.erl` | Catálogo, procedencia RNG, callbacks de resultado único y admisión semántica |
| API persistentes | `efz_recipe.erl`, `efz_replay.erl`, `efz_semantic_replay.erl`, `efz_corpus_store.erl`, `efz_semantic_corpus.erl` | Identidad/reinicio/reproducción/reducción/minimización versionados |
| CLI/compilación | `efz_cli.erl`, `rebar.config`, `scripts/build_gleam.sh`, `gleam_replay*.escript`, `semantic_scaffold.escript` | Configuración fiable, modelos opcionales y generador reutilizable |
| Modelos/ejemplos | `gleam/efz_semantic/src/efz_term_model.gleam`, `efz_xmlrpc_model.gleam`, `examples/{term_api,stateful,xmlrpc,semantic_configs}`, metadatos QS | Integraciones reales reutilizables; modelo QS original preservado |
| Evidencias de comportamiento | `test/efz_{plugin_*,semantic_api,semantic_cli,semantic_portability,term_api,xmlrpc_adapter}*`, regresiones | Frontera, ciclo de vida, identidad, persistencia y compatibilidad |
| Evidencias comparativas | `scripts/{run_semantic_bench.py,run_qs_semantic_bench.py,semantic_bench.escript,gleam_bench.escript,qs_compatibility_probe.escript}` | Drivers finitos secuenciales, manifiestos y sonda antes/después |
| Documentación | `adapter-contract.md`, `connecting-erlang-libraries.md`, `user-guide.md`, este informe, README XML | Contrato público, guía de 8 pasos, configuración/límites y validación |

La revisión CLI y contabilidad de resultados se completó sin nuevas
ejecuciones. Verificar runtime/sintaxis de CLI y reenvío antiguo, serie
comparativa final aislada y costes reales de escenarios/operaciones aceptados
siguen pendientes. Comandos preparados, **no ejecutados** aquí:

```sh
python3 scripts/run_semantic_bench.py --out /tmp/efz-semantic-verified
python3 scripts/run_qs_semantic_bench.py \
  --baseline /tmp/efz-universal-baseline-e4c0244/_build/gleam \
  --out /tmp/efz-qs-verified
```

Guía práctica, plantillas y configuraciones:
[Conectar una biblioteca Erlang a Gleam Layer](connecting-erlang-libraries.md).
El ámbito se limita a ruta de código disponible, ciclo EFZ permitido, harness
reproducible y cobertura realmente preparada. Servicios externos, dispositivos,
puertos/NIF personalizados, procesos no gestionados y otros recursos necesitan
adaptadores/harnesses/comprobaciones del entorno separados. Un contrato común
no infiere automáticamente semántica de biblioteca arbitraria.
