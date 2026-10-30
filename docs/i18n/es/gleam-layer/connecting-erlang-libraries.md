# Conectar una biblioteca Erlang a Gleam Layer

[English](../../../gleam-layer/connecting-erlang-libraries.md) · [Русский](../../ru/gleam-layer/connecting-erlang-libraries.md) · **Español** · [简体中文](../../zh-CN/gleam-layer/connecting-erlang-libraries.md) · [Todos los idiomas](../../README.md)

La integración usa ejecución, corpus, planificador, cobertura, RNG y reproducción
existentes de EFZ. Cada campaña selecciona un adaptador. El harness mantiene
`run(binary()) -> term()`; la función real puede tener otra aridad y aceptar
términos Erlang. El adaptador genérico no necesita un modelo Gleam por API.
Los plugins de protocolo conservan bytes originales del formato y no tienen
que usar el códec genérico de términos.

[Resultados y límites de validación](universal-validation.md) contiene comandos/
logs guardados, compatibilidad y mediciones preliminares. La CLI general nueva
de reproducción pasó revisión estática; aún no se ejecutaron ni ella ni la
serie final comparativa aislada. La última instrucción del usuario prohíbe
nuevas ejecuciones de pruebas/mediciones.

## 1. Elegir API y nivel de integración

| Método | Cuándo usarlo | Ejemplo real |
| --- | --- | --- |
| Term/API genérico | Argumentos describibles como términos Erlang acotados | `lists:reverse/1`, `maps:find/2`, `efz_term_tuple_library:combine/2` |
| Dominio/protocolo | Hace falta gramática de formato, campos correlacionados o modelo independiente | `efz_xmlrpc_adapter`, `efz_qs_adapter` |
| Harness con estado | Se necesitan preparación/reset/limpieza y lista de comandos | `efz_stateful_target`, `efz_stateful_counter` |

Ámbito validado: módulo disponible en la ruta, llamada local BEAM mediante
harness reproducible y EFZ gestiona tiempo límite/limpieza. El harness aporta
recursos. Tener `-spec` o nombre de módulo no prueba que un resultado arbitrario
sea correcto. Sockets, drivers, servicios externos, hardware y dependencias
especiales de SO requieren harness propio y validación separada del entorno.

## 2. Crear un harness

Si la API tiene `-spec` y BEAM compilado con `debug_info`, harness,
configuración y semilla pueden [generarse automáticamente](connector-generation.md)
con `semantic_scaffold.escript from-beam OUT HARNESS LIBRARY.beam FUNCTION ARITY`.
Los tipos admitidos se convierten al esquema compartido, sin descripción
manual de argumentos.


Ejemplo genérico listo para usar:

```erlang
-module(example_library_target).
-export([run/1, options/0, semantic_contract/0]).
options() -> #{entrypoint => {lists, reverse, 1},
              arguments => [#{kind => list, item => #{kind => integer}}]}.
semantic_contract() -> (options())#{kind => term_api}.
run(Raw) -> efz_term_codec:execute(Raw, options()).
```

Para su `example_library`, cambie `entrypoint`, `arguments` y harness; no se
edita el núcleo EFZ. `prepare/3` comprueba función, aridad e igualdad entre
metadatos y opciones. No necesita paquete especializado nuevo. Se admiten
aridades exportadas 0 a `min(collection, 255)`: `collection => 32` por defecto
permite 32 argumentos; 255 es límite BEAM. Aridad cero usa `arguments => []`.
El resultado se describe independientemente de restricciones de argumentos.

`efz_term_codec:execute/2` decodifica el paquete canónico y llama
`apply(Module, Function, Args)` sin dispatch semántico ni modelos.
`efz_term_api_adapter:execute/2` anterior queda como delegado compatible.
Paquete no admitido/malformado devuelve `{efz_term_input_rejected, Reason}`.
Valores `{error, Reason}` normales de la biblioteca siguen siendo resultados
normales. El harness define excepciones esperadas y las convierte
explícitamente cuando lo exige el contrato de API elegido.

El harness tiene su propio ámbito fijo de decodificación. Sin
`semantic_contract().input_limits`, rigen defaults del códec. Los límites de
campaña `bytes`, `depth`, `nodes`, `collection` no deben superarlos; se rechaza
antes de arrancar con `term_api_input_limits_mismatch`. Se permiten límites
más estrictos como subconjunto estructurado si los argumentos siguen válidos.
La mutación de bytes aún puede alcanzar el dominio más amplio del harness.

Para ampliar el ámbito, pase los mismos límites al códec y declárelos en
metadatos, por ejemplo:

```erlang
input_limits() -> #{bytes => 4096, depth => 8, nodes => 256,
                    collection => 64, operations => 1}.
semantic_contract() -> (options())#{kind => term_api,
                                   input_limits => input_limits()}.
run(Raw) -> efz_term_codec:execute(Raw, (options())#{limits => input_limits()}).
```

Opciones del adaptador: `entrypoint`, `arguments` y `property` opcional;
`input_limits` pertenece al contrato del harness. Los metadatos solo aceptan
claves comunes en rangos finitos documentados; si no, producen
`invalid_term_api_input_limits`. La misma identidad de harness/código conserva
su ámbito al reproducir, mientras la semántica también comprueba límites
efectivos. El fixture `efz_term_custom_limits_target` comprueba por separado
collection 64 con una lista mayor de 32.

El generador crea fuentes compilables, configuración y semilla sin sobrescribir:

```sh
ERL_FLAGS='+S 2:2' rebar3 compile
escript scripts/semantic_scaffold.escript generic /tmp/new-api efz_example_target
escript scripts/semantic_scaffold.escript domain /tmp/new-domain efz_protocol_target
```

Los defaults genéricos usan `lists:reverse/1` real. Para otra biblioteca,
pase `options.term` de confianza como cuarto argumento con exactamente
`#{entrypoint => {Module, Function, Arity}, arguments => Specs}`.
El generador rechaza recursos con `resource_harness_required`: el ciclo de
vida debe escribirse explícitamente. El esqueleto de dominio implementa mensaje
independiente con longitud prefijada y plugin solo observador; modelo ausente
no produce oráculo aprobado. El `README.md` generado da compilación y CLI.

## 3. Describir argumentos, escenarios y capacidades

El esquema 1 del códec usa su propio envoltorio binario, no ETF:
`<<"EFZT", 1, ArgumentCount:16, TaggedArguments/binary>>`. Enteros big-endian.
Conserva lista de argumentos, etiquetas, tamaños acotados y orden determinista
de claves. Las etiquetas átomo/recurso son índices en un conjunto finito
ordenado de la configuración de confianza. Los bytes no crean átomos.

| `kind` | Campos adicionales y límites |
| --- | --- |
| `integer` | 64 bits con signo, `min`/`max`; defaults −1000000..1000000 |
| `float` | Flotante finito 64 bits, `min`/`max` flotantes finitos; defaults −1000000.0..1000000.0 |
| `boolean` | `true`/`false` |
| `binary` | Bytes arbitrarios, `min_length`/`max_length` |
| `charlist` | Lista propia de enteros escalares Unicode, sin sustitutos; codificación definida por API |
| `atom` | `values => [existing_atom, ...]` finito no vacío obligatorio |
| `list` | `item => Spec`, `min_length`/`max_length`, listas propias |
| `tuple` | `items => [Spec, ...]`, aridad fija |
| `map` | `key => Spec`, `value => Spec`, tamaño acotado, claves duplicadas rechazadas por códec |
| `term` | Combinaciones anidadas admitidas de escalar/lista/tupla/mapa; átomos solo de `atoms => [...]` |
| `resource` | `values => [handle_name, ...]`, guardado como `{'$efz_resource', Handle}` |

`min_length` es 0 y `max_length` es `collection` por defecto (32, máximo 256),
también para binary/charlist. Un argumento binario queda así limitado a 32 bytes
aunque el paquete completo permita 4096. Charlist cuenta puntos de código
Unicode: cada uno se guarda como entero etiquetado de 64 bits con signo, no
UTF-8. El harness convierte a codificación exigida por API. Cada enumeración
de átomos/recursos tiene como máximo 256 átomos existentes.

Defaults comunes: `bytes => 4096`, `depth => 8`, `nodes => 128`,
`collection => 32`, `operations => 1`; preflight permite hasta 1 MiB,
profundidad 16, nodos 4096 y collection 256. `bytes` incluye cabecera/etiquetas.
Raíces de argumentos tienen profundidad 1; cada elemento lista/tupla,
clave/valor de mapa y punto de charlist consume nodos. El envoltorio de la lista
de argumentos no cuenta aparte. Configuración y datos se validan por separado.
PID/ref/port/fun no son entradas literales portables. El observador puede
informar su clase finita sin guardar valores.

El ejemplo con estado codifica un argumento: lista de hasta 16 tuplas
`{ResourceHandle, Command, Integer}`. Comandos `get`, `put`, `add`, `reset`
pertenecen a conjunto finito. `semantic_contract/0` declara
`resource_lifetime => execution, resource_handles => [counter]`.
`efz_stateful_target:scenario/1` crea gen_server nuevo no registrado mediante
`efz_target:spawn_link/1` permitido, fija metadatos OTP 27 `proc_lib`
(`'$ancestors'`, `'$initial_call'`) y entra en `gen_server:enter_loop/3` público.
No llama funciones internas de `proc_lib`, pero esas claves de diccionario
están ligadas al ciclo OTP 27 validado. Es fixture de arranque validado en
OTP 27, no promesa de ciclos arbitrarios: `gen_server:start_link/3` ordinario
no gestionado dentro de EFZ se rechaza. Fuera de EFZ, usa `start_link` normal.
Resuelve handle simbólico a PID, ejecuta comandos y detiene en `after`;
`semantic_contract/0` declara `execution_modules => [efz_stateful_counter]`.
Cada ejecución/reproducción empieza de cero. Una entrada es una ejecución
principal; resultado acotado contiene `scenario_executions => 1`,
`library_operations => N`, `trace => [...]` separados. `N` cuenta comandos;
preparación/cierre excluidos. Para otros recursos se amplía harness, no
planificador ni worker.

## 4. Elegir adaptador estándar o plugin propio

La interfaz pública exacta está en [adapter-contract.md](adapter-contract.md).
Son obligatorios `descriptor/0` y `prepare/3` fuera del bucle; contexto inmutable.
El descriptor fija ID/API/modelo/observador/receta/operaciones, capacidades,
IDs, módulos de modelo y propiedades. El opcional
`code_dependencies(Context) -> #{semantic => [module()], target => [module()]}`
vincula helpers/propiedades y dependencias objetivo adicionales al mecanismo
existente de identidad. El descriptor ya vincula adaptador y modelos.
Ser dependencia de identidad no añade cobertura por sí mismo.
El genérico añade `efz_term_codec` como dependencia semántica: cambiar decode/
normalización rechaza reproducción antigua como cambiar modelo. Su preparación
comprueba exportaciones reales Gleam `scalar/4` y `observe/6`; modelo ausente
o ABI incompatible se rechazan antes de campaña. Ejecución sin modelo y
creación de semillas por códec no necesitan esa comprobación.

Callbacks operativos solo obligatorios para capacidades declaradas:

```erlang
generate(Index, Context) -> {ok, Raw} | {skip, Reason} | {error, Reason}.
mutate(Raw, Operation, #{choice := Choice}, Context) ->
    {ok, Raw, RecipeData} | {skip, Reason} | {error, Reason}.
observe(Raw, PrimaryOutcome, Context) ->
    {ok, LocalFeatureIds} | {skip, Reason} | {error, Reason}.
oracle(Raw, PrimaryOutcome, Context) ->
    {pass, Property} | {fail, Property} | {inconclusive, Reason} | {error, Reason}.
shrink(Raw, Context) -> {ok, Candidates} | {skip, Reason} | {error, Reason}.
```

`Reason` de skip/inconclusive es átomo; `Property` es exactamente `{Id, Version}`
del descriptor. Características: hasta 64 IDs locales 0..255. El dispatcher
añade `{AdapterId, ObserverVersion, LocalId}`; IDs locales iguales de adaptadores
distintos no se mezclan con cobertura estructural ni entre sí.
Generación/mutación deterministas; `choice` 0..65535 viene del RNG EFZ y se
guarda. El adaptador no crea RNG, registro, worker ni proceso por callback.

Para `example_library` de formato especial, use esqueleto de dominio:
sustituya llamada objetivo, metadatos y observador; si precisa, añada modelo
Gleam propio, su nombre en `model_modules`, generación/mutación acotadas y
propiedad independiente. El dispatcher central no ramifica por nombre de
biblioteca. Un descriptor solo observador puede tener `model_modules => []`,
`operations => []`, `properties => []`; su configuración usa
`structured_fraction => 0`, `oracle => disabled`. También se permite plugin
solo generador sin observador/oráculo, feedback desactivado y fracción 0.

Un modelo Gleam puede venir como dependencia Erlang/rebar3 separada: compile/
exporte BEAM antes, añada su `ebin` y dependencias runtime necesarias a la ruta
de la campaña opcional y declare modelos en descriptor. La compilación ordinaria
EFZ no debe descargar/compilar el paquete. La opcional del repositorio fija
Gleam 1.10.0; runtime off y compilaciones ordinarias no llaman modelos.

## 5. Configurar semillas, mutación, observador y oráculo

Mapas funcionales en [examples/semantic_configs](../../../../examples/semantic_configs):
`lists_reverse.term`, `maps_find.term`, `tuple_api.term`, `stateful.term`,
`xmlrpc.term`, `cow_qs.term`, `cow_qs_legacy.term`. Las semillas se crearon
con el códec real y especificaciones de cada harness; XML/QS conservan binarios
originales del formato. Usan `coverage_backend => none` para comprobar
brevemente ejecución/semántica. No afirman cobertura estructural medida de
API stdlib.

```erlang
gleam_layer => #{adapter => efz_term_api_adapter,
    adapter_options => #{entrypoint => {lists, reverse, 1},
        arguments => [#{kind => list, item => #{kind => integer}}]},
    structured_fraction => 10, feedback => guided, oracle => disabled,
    oracle_budget => 64,
    limits => #{bytes => 4096, depth => 8, nodes => 128,
                collection => 32, operations => 1}}
```

El observador genérico clasifica resultado y árbol acotado; no prueba
corrección de biblioteca. El oráculo permanece desactivado hasta configurar
`adapter_options.property => #{callback => {Module, Function}}` y
`oracle => inline`. El callback recibe `(DecodedArgs, PrimaryOutcome)` y
devuelve `true`, `false` o `inconclusive`; predicado ID
`{generic_custom_property, 1}`, identidad de código registrada por separado.
`stateful.term` selecciona explícitamente propiedad independiente de traza
del contador.

`guided` admite novedad semántica al corpus/selección ordinarios.
`observation_only` informa sin guiar corpus/planificador. `disabled` desactiva
observador. `structured_fraction => 0` no extrae RNG de rama ni decodifica
mutación; callbacks de observador/oráculo activados siguen funcionando.
`gleam_layer => false` desactiva todo y conserva RNG ordinario.

`skip`, sin cambios y límite usan alternativa ordinaria de bytes. Excepción/
resultado inválido de capa termina como error de infraestructura del adaptador;
no es hallazgo de biblioteca ni alternativa exitosa. `inconclusive` indica
falta de veredicto justificado. Rechazo esperado no es hallazgo sin vulnerar
propiedad explícita admitida. Los callbacks son inline; capturar excepciones
no detiene uno infinito. Un plugin debe usar algoritmos finitos y comprobar
presupuestos antes de asignación/recursión costosas.

Para QS, configuración antigua sin `adapter` solo funciona por shim heredado
para `efz_qs_target`/`efz_qs_defect_target`. No participa al conectar objetivos
nuevos. `efz_qs_adapter` explícito comprueba metadatos
`#{kind => query_string, outcome => accepted_pairs}`. `fields` y `component`
específicos van en `adapter_options`, no límites comunes.

XML-RPC usa [preparación etnt/xmlrpc fijada](../examples/xmlrpc/README.md).
`efz_xmlrpc_target` llama `xmlrpc_decode:payload/1` sobre charlist. Modelo
independiente v1 comprueba methodCall ASCII imprimible, int/boolean/string
y array/struct anidados, con límites de bytes/profundidad/nodos/colección/
string. Nombres se normalizan desde átomos existentes o charlists a binarios
sin crear átomos. Corrección response/fault, i4/double/date/base64/nil,
strings implícitos, UTF-8 no ASCII y gramática XML amplia no están admitidos
por v1. Observación puede clasificar response/fault; no prueba corrección.

## 6. Preparar artefactos de cobertura solo del objetivo

Use `efz_instrument:compile/2` o `efz_cov_native_public:compile/3` existentes
y preflight estándar. Seleccione módulos de la biblioteca; excluya
adaptador/modelo/helpers de propiedad. Harness y códec de infraestructura no
sustituyen cobertura de biblioteca. Para API integradas OTP sin backend
preparado, use sinceramente `none`/diagnostic y registre la limitación.

XML-RPC instrumenta `xmlrpc_decode` y `xmlrpc_util`. xmerl OTP queda como
dependencia sin cobertura interna medida. Valores record de `xmerl.hrl`
requieren `strict => false` documentado; cláusulas ejecutables conservan
sondas. Por ejemplo, para el contador:

```erlang
{ok, A} = efz_instrument:compile("examples/stateful/efz_stateful_counter.erl",
    #{modules => [efz_stateful_counter], outdir => "/tmp/counter-artifacts",
      source_root => ".", erl_opts => [debug_info, warnings_as_errors]}).
```

Después, cambie configuración a `coverage_backend => ets, artifacts => [A]`
o pase `--artifacts /tmp/counter-artifacts`. Tener una dependencia en la ruta
no basta para afirmar que se midió su cobertura. Las sondas ETS en el hijo
admitido del contador y limpieza sin procesos restantes se comprobaron aparte.
Cubre `efz_stateful_counter` propio, no módulos internos OTP
`gen_server`/`proc_lib`.

## 7. Ejecutar validación y campaña

Desde raíz EFZ:

```sh
ERL_FLAGS='+S 2:2' rebar3 compile
GLEAM_BIN=/path/to/gleam-1.10.0 ERL_FLAGS='+S 2:2' rebar3 as gleam compile
ERL_FLAGS='+S 2:2' rebar3 eunit --module=efz_term_api_tests
ERL_FLAGS='+S 2:2' escript scripts/fuzz.escript \
  --config examples/semantic_configs/lists_reverse.term \
  --code-path _build/gleam/lib/efz/ebin --out /tmp/reverse-run
ERL_FLAGS='+S 2:2' escript scripts/fuzz.escript \
  --config examples/semantic_configs/stateful.term \
  --code-path _build/gleam/lib/efz/ebin --out /tmp/counter-run
```

`--config` lee exactamente un mapa Erlang de confianza mediante `file:consult`.
Las rutas se cargan antes de consult/preflight. Opciones CLI explícitas
sobrescriben configuración; `--seeds DIR` importa archivos originales y
`--artifacts DIR` sobrescribe artefactos. `--out` sigue obligatorio.
La configuración no guarda closures ejecutables, PID de recurso ni secretos.
Una configuración de confianza puede especificar átomos; es una frontera
separada de bytes no fiables. Opciones anteriores no cambian de nombre.

Arranque detecta adaptadores desconocidos, callbacks/modelos ausentes,
metadatos/opciones incompatibles, capacidades y cobertura no admitidas.
`--gleam-layer` sin adaptador explícito sigue siendo compatibilidad QS antigua;
integraciones nuevas usan configuración con `adapter`.

Para XML-RPC ejecute primero `examples/xmlrpc/prepare.escript` y añada
`_build/xmlrpc-example/dependency-ebin` y `_build/xmlrpc-example/harness-ebin`
mediante `--code-path`. Para QS añada `_build/default/lib/cowlib/ebin`.
Validar un cambio incluye compilaciones ordinaria/opcional, runtime off,
EUnit/CT pertinentes, xref/Dialyzer y campañas finitas con evidencias.
Los resultados comparativos deben informar por separado tiempo de pared,
presupuesto, calibración/mutaciones/ejecuciones extra, resultados del proveedor,
cobertura y novedad semántica local. Los recuentos de distintos adaptadores no
son escala común. Un microbenchmark de callbacks no sustituye rendimiento ni
evidencias de detección de campañas.

## 8. Comprobar persistencia, reproducción y minimización

El corpus canónico guarda binarios originales. Reiniciar recalibra con
adaptador actual, no confía en características guardadas de otro modelo.
`corpus_build_policy => reject | recalibrate` define diferencias. Metadatos
existentes incluyen adaptador/modelo/opciones/límites, versiones de
observador/propiedad/catálogo, identidades de código/ejecución y procedencia
RNG. La identidad también registra SHA-256 del contexto preparado portable
determinista; debe ser reproducible o la reproducción obtiene diferencia.

Reconstruir entrada y ejecutarla son operaciones separadas.
`efz_recipe:load/1` y `efz_recipe:regenerate/1` de esquema 4 reconstruyen bytes
de reemplazo y validan receta/procedencia RNG con el núcleo. No cargan
adaptador/modelo, ejecutan objetivo ni decodifican opciones/RecipeData opacos.
Los esquemas QS históricos conservan garantías anteriores de reproducción.

Ejecutar entrada reconstruida requiere artefactos de objetivo/harness/
dependencias, sin dispatch semántico, adaptador ni BEAM de modelos.
Los harnesses genéricos de esta guía usan `efz_term_codec:execute/2` sin modelo:
el BEAM del códec se necesita como dependencia ordinaria. Harnesses de formato
llaman directamente a biblioteca. Los personalizados también deben separar
dependencias de ejecución y callbacks opcionales.

`efz_recipe:regenerate_semantic(Recipe, PreparedLayer)` vuelve a ejecutar
mutación estructurada con operación/parámetros guardados y verifica bytes y
RecipeData. Esta comprobación opcional necesita contexto nuevo preparado de
configuración fiable, identidad exacta de adaptador y BEAM disponibles.
Tampoco ejecuta objetivo. La reproducción de propiedades siguiente comprueba
el resultado de ejecución real y requiere su propio contrato.

```erlang
{ok, Expected} = efz_semantic_replay:load("finding.semantic"),
ReplayOptions = #{timeout => 1000, coverage_backend => none,
                  gleam_layer => TrustedLayerConfig},
efz_semantic_replay:run(Raw, Target, TargetArtifacts, Expected, ReplayOptions),
efz_semantic_replay:minimize(Raw, Target, TargetArtifacts, Expected,
    ReplayOptions#{minimization_timeout_ms => 30000}, 64).
```

`none` coincide con configuraciones breves anteriores. Para artefactos
ETS/nativos guardados, seleccione `coverage_backend` original y suminístrelos
exactamente.

El contrato también está en CLI general sin ramas específicas de bibliotecas:

```sh
ERL_FLAGS='+S 2:2' escript scripts/gleam_replay.escript \
  --config trusted-campaign.term --finding /path/to/finding-prefix \
  --budget 64 --out /tmp/new-replay-result \
  --code-path _build/gleam/lib/efz/ebin --code-path /path/to/harness/ebin
```

La configuración fiable fija `target`, `artifacts`, `coverage_backend`,
`gleam_layer`, `timeout` y `max_input_bytes` opcional; esta CLI no ejecuta
semillas ni corpus. Admite `ets`, `ets_member`, `otp_native_public`, `none`;
`bitmap` de campaña aún no se admite por la API de reproducción y se rechaza
antes del objetivo. Errores de opciones/configuración salen con 2.
La CLI primero valida fuera del bucle con límites efectivos fiables y compara
identidad completa. Aumentar o disminuir límites frente al hallazgo produce
diferencia antes de ejecutar; el límite registrado de bytes no sustituye un
límite mayor elegido explícitamente. Ni validar ni leer hallazgo llama al
objetivo.
El hallazgo no selecciona código: solo se leen `.input` y `.semantic`;
`.term` diagnóstico innecesario. El directorio de salida no debe existir,
tampoco como enlace simbólico; resultados solo se crean tras reproducción
real. `not_reproduced` e `inconclusive` salen con 1 antes de minimizar y sin
salida. Presupuesto 1..10000 incluye reproducción inicial y todas las llamadas
del minimizador: 1 guarda solo `replay.*`; mayor también
`minimized.input`, `minimized.semantic`, `minimization.term`.
Se guardan estado real de plazo/presupuesto y total de ejecuciones.
El minimizador usa plazo 30000 ms: después no programa candidatos nuevos;
una ejecución iniciada tiene `timeout` separado del objetivo. Si omite
verificación final por presupuesto/plazo, registra `{skipped,budget}` o
`{skipped,deadline}`. La entrada guardada reprodujo el predicado en la última
comprobación del candidato (o inicial si no cambió); no se afirma comprobación
final adicional en ese caso.

El comando anterior de cinco argumentos queda como helper QS antiguo
explícitamente limitado y delega en `scripts/gleam_replay_legacy.escript`.
Sus nombres históricos, artefacto nativo `cow_qs` y JSON diagnóstico permanecen
solo allí; integraciones nuevas usan `--config`.

Reproducir propiedades exige configuración fiable explícita, identidades
coincidentes de adaptador/modelo/propiedad/objetivo y ruta. El artefacto no
elige adaptador ni callback. Se rechaza incompatibilidad; no se sustituye
silenciosamente predicado. Minimizar usa mismo ID/versión y predicado, cuenta
cada ejecución, reproducción inicial y verificación final. No promete mínimo
global e informa agotamiento. Resultados separados; corpus canónico y grupos
originales no se sobrescriben.
