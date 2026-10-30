# API 1 del adaptador semántico

[English](../../../gleam-layer/adapter-contract.md) · [Русский](../../ru/gleam-layer/adapter-contract.md) · **Español** · [简体中文](../../zh-CN/gleam-layer/adapter-contract.md) · [Todos los idiomas](../../README.md)

Este contrato se fija antes de implementar. EFZ posee ejecución, RNG,
planificación, cobertura, corpus y reproducción. Se prepara exactamente un
adaptador explícito por campaña. Los callbacks se ejecutan inline en la VM EFZ
y deben usar algoritmos finitos. Capturar excepciones no interrumpe un bucle;
el código de plugin de confianza debe aplicar sus límites documentados.

Callbacks obligatorios:

```erlang
descriptor() -> #{id := binary(), api_version := 1, model_version := pos_integer(),
    observer_version := pos_integer(), recipe_version := pos_integer(),
    operations_version := pos_integer(), capabilities := [capability()],
    operations := [non_neg_integer()], model_modules := [module()],
    properties := [{atom() | binary(), pos_integer()}]}.
prepare(Target :: module(), Options :: map(), Limits :: map()) ->
    {ok, ImmutableContext :: term()} | {error, Reason :: term()}.
```

Las capacidades son `generation`, `mutation`, `observation`, `oracle`, `shrink`.
Solo las declaradas requieren su callback. Los plugins mínimos solo de
observación o generación no necesitan parser, mutador ni oráculo. Los IDs del
descriptor tienen como máximo 64 bytes; las versiones son enteros positivos.
Los IDs de operación son enteros únicos 0..65535. Los módulos de modelo y
adaptador se excluyen de la cobertura del objetivo. Un harness puede exponer
`semantic_contract/0`; el plugin valida los metadatos en prepare/3, nunca por
una lista central de nombres permitidos. Los objetivos con la capa desactivada
no necesitan nada de ello.

Callbacks operativos opcionales (obligatorios si se declaran):

```erlang
generate(Index :: non_neg_integer(), Context) ->
    {ok, binary()} | {skip, atom()} | {error, term()}.
mutate(Raw :: binary(), Operation :: non_neg_integer(), Params :: map(), Context) ->
    {ok, binary(), RecipeData :: map()} | {skip, atom()} | {error, term()}.
observe(Raw :: binary(), PrimaryOutcome :: term(), Context) ->
    {ok, [LocalFeatureId :: 0..255]} | {skip, atom()} | {error, term()}.
oracle(Raw :: binary(), PrimaryOutcome :: term(), Context) ->
    {pass, Property} | {fail, Property} | {inconclusive, atom()} | {error, term()}.
shrink(Raw :: binary(), Context) ->
    {ok, [binary()]} | {skip, atom()} | {error, term()}.
```

Property es exactamente `{Id, Version}` y debe aparecer en `properties` del
descriptor. El observador devuelve como máximo 64 IDs locales; se permiten
duplicados que elimina el dispatcher. Este añade
`{AdapterId, ObserverVersion, LocalId}`; los espacios de nombres no incluyen
cadenas dependientes de la entrada. `PrimaryOutcome` es el resultado existente
del executor EFZ (`{ok, Value}`, timeout, crash o exit). Los adaptadores validan
y resumen su subconjunto admitido antes de llamar a Gleam. Observación y
oráculo nunca vuelven a ejecutar el objetivo en API 1.

Params de mutación es exactamente `#{choice => Integer}` (0..65535), extraído
por el RNG EFZ y registrado; claves adicionales son un error de frontera.
Shrink devuelve como máximo 64 candidatos binarios, cada uno limitado por
el límite efectivo de bytes.
La fachada admite índices de generación 0..4095. Las versiones son 1..65535;
los catálogos de operaciones tienen como máximo 256 entradas, y model_modules/
properties 32 cada uno. Las claves del descriptor son exactamente las listadas;
capacidades e IDs de operación son únicos, y declarar mutación/oráculo requiere
un catálogo/lista de propiedades no vacío. Valores predeterminados: bytes 4096,
depth 8, nodes 128, collection 32, operations 1; rangos comunes admitidos:
bytes 0..1048576, depth 1..16, nodes 1..4096, collection 1..256 y operations
exactamente 1. El límite efectivo también respeta max_input_bytes de campaña.
Los adaptadores no tienen RNG independiente. RecipeData son datos acotados,
no código ejecutable. Las recetas nuevas registran identidad de API/modelo/
catálogo de operaciones, opciones/límites, operación, parámetros y estados RNG
EFZ. La reproducción ordinaria usa bytes guardados y nunca carga un plugin.
La regeneración de recetas es una operación separada que se activa explícitamente.

`skip` indica formato/tamaño/límite no admitidos y la mutación usa la alternativa
ordinaria de bytes; una mutación sin cambios también recurre a ella.
`inconclusive` indica que no se justifica un veredicto de oráculo. `error` o
una excepción capturada de callback es error de capa, nunca hallazgo del
objetivo. El rechazo esperado de un parser es un resultado del objetivo,
no automáticamente fallo del oráculo. Solo fallar una propiedad explícita
admitida crea un hallazgo. El dispatcher valida todos los tipos y tamaños
de salida. Límites comunes: `bytes`, `depth`, `nodes`, `collection`,
`operations` (uno en API 1); los específicos del plugin se validan en
adapter_options. El contexto es inmutable y se prepara una vez.
Opciones/contexto/RecipeData portables admiten átomos finitos, enteros acotados,
flotantes finitos, binarios, listas propias, tuplas y mapas; se rechazan valores
runtime PID/ref/port/fun. El recorrido admite profundidad máxima 24 y 8192
nodos, tupla/mapa de como máximo 256 elementos y binarios individuales de
hasta 1 MiB. Opciones codificadas: hasta 65536 bytes; contexto: 1 MiB;
RecipeData: 4096 bytes; detalle de error: 1024 bytes. Estos límites de datos
fuera del bucle/frontera son distintos de los de representación de entrada
del plugin.

Los artefactos de propiedades fijan descriptor, identidades BEAM de adaptador/
modelo, configuración efectiva, compilaciones de objetivo/harness y versión
de propiedad. La reproducción debe recibir configuración explícita de
adaptador de confianza; el artefacto nunca selecciona código. Una diferencia
rechaza reproducción. Reiniciar corpus recalibra bytes guardados con callbacks
actuales; nunca se confía en espacios semánticos persistidos como calibración.
La reducción debe usar el mismo predicado y contar cada ejecución del objetivo;
entradas originales y grupos de hallazgos no cambian.

Las firmas históricas de fachada QS y artefactos QS esquema 1 permanecen como
interfaz aislada de compatibilidad. Las configuraciones sin `adapter` solo se
aceptan por la capa QS antigua. Las nuevas integraciones deben seleccionarlo
explícitamente.

El callback opcional fuera del bucle
`code_dependencies(Context) -> #{semantic := [module()], target := [module()]}`
declara hasta 32 módulos por categoría. EFZ fija su código mediante el mecanismo
BEAM existente. Los helpers/propiedades semánticos se excluyen de cobertura;
las dependencias objetivo declaradas pueden seleccionarse. Este callback
identifica reproduciblemente propiedades y API configuradas dinámicamente sin
que el dispatcher conozca nombres de opciones. Ausencia significa sin módulos
adicionales. La identidad persistente guarda opciones efectivas como bytes ETF
opacos sin comprimir; la reproducción de bytes nunca las decodifica ni crea
átomos específicos del plugin. Nombres de módulos/propiedades del descriptor
son binarios portables. La reproducción semántica compara con una configuración
nueva y de confianza del llamador. La misma identidad fija también SHA-256
del contexto preparado portable determinista (codificado de hasta 1 MiB).
Cambiar contexto fuera del bucle no puede cambiar silenciosamente un predicado
registrado. prepare/3 debe ser reproducible desde objetivo/opciones/entorno
declarados; una configuración ambiental no reproducible produce diferencia
explícita de identidad.

La procedencia estructurada nueva guarda RecipeData del callback como bytes
ETF deterministas opacos (hasta 4096), evitando átomos específicos al decodificar
recetas originales. La regeneración del esquema 4 usa bytes de reemplazo
guardados; otra API explícita requiere configuración compatible del adaptador
de confianza.
