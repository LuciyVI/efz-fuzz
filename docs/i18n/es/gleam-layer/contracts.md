# Contrato Erlang/Gleam nativo v1

[English](../../../gleam-layer/contracts.md) · [Русский](../../ru/gleam-layer/contracts.md) · **Español** · [简体中文](../../zh-CN/gleam-layer/contracts.md) · [Todos los idiomas](../../README.md)

Requisitos: **2.0-native**. Contrato: **1**. Tanto
`efz_gleam_adapter:versions/0` como `efz_qs_model:versions/0` compilado devuelven
`{Contract,Model,Codec,Mutator,FeatureSchema,Property} = {1,1,1,1,1,1}`.
El arranque exige igualdad exacta; la reproducción de propiedades comprueba
ese vector y `{query_model_agreement,1}`. Ningún artefacto incompatible se
convierte silenciosamente. [architecture.md](architecture.md) identifica los
propietarios EFZ reales y aislamiento P0.

## Núcleo tipado y frontera Erlang

Primer parser: Cowlib `cow_qs:parse_qs/1` fijado, commit
`c768a804565ff5b8178ed968a5921e469d6bd7b2`. Harness:
`examples/query_string/efz_qs_target.erl:run/1`. El separado
`efz_qs_defect_target` es fixture artificial de aceptación, no defecto de
producción. `<<"cow_qs">>` identifica la familia; los artefactos fijan también
el harness.

Los ADT Gleam concretos están en
`gleam/efz_semantic/src/efz_qs_model.gleam`. Estas representaciones compiladas
reales se prueban mediante llamadas BEAM:

| Tipo | Representación Erlang / frontera comprobada |
| --- | --- |
| Bytes / `BitArray` | Solo `binary()`; se rechazan bitstrings no alineados a bytes y listas de texto; sin suposición UTF-8 |
| `Field` | `{field,KeyBinary,ValueBinary}`, clave no vacía, componentes acotados |
| `Query` | `{query,ProperFieldList,canonical | bad_escape}`, forma exacta de tupla/etiqueta |
| `Limits` | `{limits,Bytes,Fields,Component,1}`, enteros acotados |
| Resultado Gleam | `{ok,Value}` / `{error,unsupported | limit}` |
| Hechos de observación | Enteros y `true | false` construidos por el adaptador tras comprobar resultado principal |
| Versiones | Tupla fija anterior de seis enteros |

Los records son tuplas etiquetadas; configuración/metadatos externos EFZ son
mapas. El adaptador valida listas propias, etiquetas, binarios, alineación,
enteros y límites antes del núcleo. No hay Dynamic/cast inseguro ni creación
de átomos desde bytes. Las llamadas son directas sin JSON/ETF/IPC por llamada.
ETF se limita a códecs existentes versionados de artefactos.

API concreta restringida, no un behaviour propuesto:

```erlang
prepare(false | OptionsMap, PreparedEFZConfig) -> {ok,Config} | {error,Reason}.
decode(Binary, Limits) -> {ok,Query} | {skip,unsupported | limit} | {error,Reason}.
encode(Query, Limits) -> {ok,Binary} | {skip,limit} | {error,Reason}.
normalize(Query, Limits) -> {ok,Query} | {error,Reason}.
generate(Index, Limits) -> {ok,Binary} | {skip,limit} | {error,Reason}.
mutate(Binary, OperationId, Limits) -> {ok,Binary,RecipeData}
                                      | {skip,unsupported | limit} | {error,Reason}.
observe(Binary, PrimaryOutcome, Limits) -> {ok,SemanticSet}
                                          | {skip,limit} | {error,Reason}.
oracle(Binary, PrimaryOutcome, Limits) -> {pass,query_model_agreement}
  | {fail,query_model_agreement} | {inconclusive,Reason} | {error,Reason}.
```

EFZ posee la selección RNG explícita alrededor del núcleo puro: mutate recibe
ID de operación, no RNG oculto. Generate usa índice determinista 0..4095;
el script de preparación usa índices consecutivos y máximo 64 archivos.
Ninguno consume estado RNG del llamador. La generación es offline, no familia
online. El catálogo tiene `generator_version/0 = 2` comprobado por separado y
12 posiciones (índices módulo 12); paquete versión 1.1.0. Semillas persisten
archivos originales y manifiesto esquema 2 con rango de índices, versiones,
límites, hashes y total, máximo 64 semillas / 65536 bytes. El arranque sigue
comprobando ocho callbacks v1; la versión de generador es capacidad fuera del
bucle que comprueba la preparación. EFZ compone por tanto la operación semántica
modelo-y-siguiente-RNG con el callback puro; las transiciones se especifican
abajo.

Un candidato EFZ es `{candidate,Binary,PlanMetadata,NextPlanState}`;
`input` del corpus sigue siendo el binario original. El modelo decodificado
es transitorio, nunca entrada persistente. Los contratos existentes de términos
del executor/objetivo no cambian.

## Leyes del códec, operaciones y límites

Los modelos canónicos admitidos conservan orden y nombres duplicados.
Decode admite nombres no vacíos con `=` explícito, `&`, escapes porcentuales,
plus como espacio y bytes arbitrarios incluidos NUL/no ASCII. Campos solo
con nombre, nombres vacíos, separadores redundantes y escapes incorrectos
devuelven unsupported y mantienen alcanzabilidad por bytes originales.

Para modelos canónicos, `decode(encode(M)) == normalize(M)` y
`normalize(normalize(M)) == normalize(M)`; normalizar es identidad. No se
promete identidad de bytes originales. `bad_escape` deliberado añade `&x=%`
sin reparar y se excluye de la ley decode/encode de modelos válidos.

| Límite | Valor v1 / rango configurable |
| --- | --- |
| Bytes estructurados de entrada/salida | 0..4096; limitado por `max_input_bytes` EFZ existente |
| Campos / máximo de bytes por componente | 1..32 / 1..128; consulta/valor vacíos permitidos |
| Anidación | Query → Field de profundidad fija 2; sin variante recursiva |
| Operaciones estructuradas por candidato | Exactamente 1 |
| Resultado principal del parser para observador | ≤100 pares, ≤4096 bytes por componente |
| Características por ejecución / vocabulario de campaña | ≤4 / 12 IDs permitidos |
| Comprobaciones de oráculo | 0..10000 por campaña, predeterminado 64; incluye calibración |
| Caché/cola/workers semánticos adicionales | Ninguno (tamaño 0) |

Los límites de bytes preceden la recursión de decode; los de campos/componentes
frenan el recorrido. Encoder calcula tamaño antes de asignar bytes codificados.
Mutator comprueba capacidad antes de asignar prepend/append y calcula tamaño
de formato sin una codificación descartada. Encoder comprueba tamaño de forma
independiente antes de asignar. Componentes/listas grandes del catálogo tienen
protecciones de asignación. Los callbacks son llamadas BEAM puras acotadas.
Contabilizar tiempo no interrumpe un callback bloqueado.

Operaciones fijas: 0 anteponer `x={0,255}`; 1 vaciar primer valor;
2 eliminar primer campo; 3 invertir campos; 4 añadir byte 255 al primer valor;
5 elegir `bad_escape`. 0..4 conservan validez dentro de límites; 5 vulnera
deliberadamente la sintaxis de escape. No admitido/límite/sin cambios usan
alternativa ordinaria controlada.

## PRNG y recetas

`efz_mutation_plan:new/1` usa `rand:seed_s(exsplus,mutation.seed)` explícito.
Semilla ausente conserva derivación criptográfica única existente. Reproducir
requiere bytes padres, semilla/estado, plan, versiones y límites. La política
rand local del modo aleatorio/selección heredados se conserva; la capa nunca
la usa implícitamente. EFZ tiene un worker, así que orden de finalización no
es fuente de aleatoriedad. Después de seleccionar padre y etapa existentes:

| Caso | Transición de estado |
| --- | --- |
| Desactivado / fracción cero | Sin extracción adicional; ordinario empieza en R0 |
| Fracción >0 | `{Branch,R1}=rand:uniform_s(100,R0)` |
| Branch supera fracción | Ordinario empieza en R1 |
| Rama estructurada elegida | `{OpPlusOne,R2}=rand:uniform_s(6,R1)`, Op=OpPlusOne−1 |
| Éxito | Candidato y plan siguiente usan R2; núcleo puro no extrae nada |
| No admitido / límite / sin cambios | Ordinario empieza en R2 y progresa normalmente |
| Error de capa | Devolver diagnóstico con R2 y detener; sin rollback/reintento/alternativa |

La operación de receta es solo datos:
`{structured_replace,1,{1,1,1,1,1,1},OperationId,OutputBinary}`, salida ≤4096
bytes. Usa `efz_recipe:make/4` / `efz_mutation:apply_operation/3` existentes.
La envoltura EFZR sigue v1; nuevo esquema estructurado 3, operación versión 2.
El estructurado 2 / operación 2 y ordinario 1 / operación 1 siguen legibles.
Solo los metadatos del plan estructurado añaden `source_kind=>structured` y
`structured=>#{schema_version=>1,versions=>V,operation=>Op,limits=>Limits,
fraction=>F,rng_before=>[A,B],rng_after=>[NextA,NextB]}`. Son las dos palabras
exactas de estado exsplus de 58 bits inmediatamente antes de elegir rama y
después de elegir operación, como listas propias; ninguna función runtime
entra en artefactos. La validación fuera del bucle reconstruye estado con
`rand:seed_s({exsplus,[A|B]})` y verifica rama, operación, siguiente estado,
límites y forma exacta de metadatos. La regeneración aplica bytes guardados;
no vuelve a ejecutar mutación tipada. Las operaciones no pueden despachar
módulos, funciones ni términos ejecutables. Regenerar reemplazos funciona
sin Gleam; reproducir propiedades lo requiere. Se registran bytes principales,
identidad semilla/configuración, hash de salida e IDs de compilación. No hay
pistas adaptativas/caché/cambio de energía.

## Configuración y capacidades

`efz_config` / `efz_cli` existentes poseen el análisis. `gleam_layer=>false`
es predeterminado; un mapa activa un adaptador fijo, sin registro ni CLI
paralela. `target` de primer nivel selecciona harness admitido/fixture etiquetado.

| Campo de capa | Valores / predeterminado |
| --- | --- |
| `structured_fraction` | Entero 0..100 / 10; positivo requiere staged |
| `feedback` | disabled, observation_only, guided / disabled |
| `oracle` | disabled, inline / disabled; deferred rechazado |
| `oracle_budget` | Entero 0..10000 / 64 |
| `limits` | bytes, fields, component, operations / 4096,32,128,1 |

`mutation.seed`, `random_seed`, `selection_seed` mantienen papeles separados;
`artifacts`, `corpus_dir`, `crash_dir` sus ubicaciones. Nuevas opciones CLI:
`--gleam-layer`, `--structured-fraction`, `--semantic-feedback`,
`--semantic-oracle`, `--oracle-budget`; límites anidados por API Erlang.
La cobertura nativa usa preparación/API nativas existentes, no backend CLI
nuevo. Preparar solo semillas no activa callbacks runtime.

El arranque comprueba claves, tipos/rangos, objetivo/modo, manifiestos solo
del objetivo, paquete, versiones exactas y ocho funciones completas del núcleo
en [p2-integration.md](p2-integration.md). No se repiten comprobaciones de
exportación/módulo en ruta de datos. Una ausencia devuelve
`{gleam_configuration,{gleam_callback_unavailable,Function,Arity}}`;
versiones se comprueban antes del resto. Paquete ausente da
`{error,{gleam_configuration,{gleam_package_unavailable,Reason}}}`.
Otros motivos: `unsupported_gleam_oracle_policy`,
`structured_requires_staged_mode`, `unsupported_gleam_target`,
`invalid_gleam_limits`, `incompatible_gleam_versions`; son átomos fijos acotados,
no badmatch opacos. La cobertura explícita nunca cambia silenciosamente.
No se comprueba capacidad de fuzzer externo. Preparar desactivado devuelve
configuración intacta sin cargar módulos/aplicaciones opcionales, estado/
workers/cargas semánticos ni extracciones RNG nuevas. Compilar off nunca
invoca Gleam.

## Realimentación y admisión serializada

StructuralFeedback permanece en unidades existentes: sondas de presencia
`{Module,BuildId,ProbeId}`, módulo/línea nativos bajo esquema fijado o buckets
de recuento existentes. No sumarlos con características semánticas como
«cobertura».

SemanticFeature es exactamente `{<<"cow_qs">>,1,Id}`, Id 0..11. SemanticSet es
lista propia única ordenada por ejecución. Metadatos:
`#{schema_version=>1,namespace=><<"cow_qs">>,feature_version=>1,features=>Fs}`.
Tuplas/listas exactas no tienen colisiones de representación hash/bitmap.
IDs: 0 aceptado, 1 rechazado, 2 timeout, 3 excepción; 4..7 recuentos 0,1,2,≥3;
8/9 valor vacío presente/ausente; 10/11 byte ≥128 presente/ausente.
Son hechos acotados, no validación UTF-8.

CampaignSemanticState es `semantic_seen` del corpus: conjunto histórico exacto
admitido/anotado con éxito, ≤12 características. No es índice activo de
referencias. Corpus append-only conserva representantes de todo lo confirmado.
Reset por ejecución no borra historial.

Para resultados principales exitosos `{ok,_}` (incluido rechazo esperado):

```text
structural_keep = existing reason in {new_coverage,new_probe,new_hit_count}
semantic_new = execution_features minus corpus.semantic_seen
keep_new_input = structural_keep OR semantic_new is nonempty
```

La calibración anota semillas conservadas; motivos iniciales y otros de
retención siguen intactos. Los fallos usan el canal existente de hallazgos;
IDs observados de timeout/excepción no admiten esos fallos por este predicado.
Los hallazgos son independientes de novedad y retención.

`efz_corpus:admit_semantic/4` serializa la decisión en su gen_server. Calcular
novedad no muta visto. Bytes/metadatos nuevos persisten por `add_checked/3`
antes de confirmar entradas/visto. Fallo de persistencia/rechazo lo deja
intacto para reintentar. Sin almacén, insertar en memoria es la confirmación.
La política sync/rename existente se conserva; P1 no añade regla fsync.
Las anotaciones de entradas existentes unen evidencia semántica/estructural
y mantienen motivo original de admisión sin duplicados.

Entradas solo semánticas tienen `retention_reason=>new_semantic`, se exponen
a `mutation_entries/0` / `select/0` ordinarios y no reciben política de energía
nueva. Solo observación emite metadatos/contadores sin cambiar admisión.
Un log separado de observación no demuestra guía.

No hay poda en línea ni actualizaciones de referencias.
`efz_semantic:cover/1` propone subconjunto que conserva sondas/recuentos y
uniones semánticas registrados, protegiendo entradas iniciales/no calibradas;
no elimina. Un futuro merge/prune debe preservar representantes y reconstruir
atómicamente visto/índice activo antes de reanudar selección para evitar que
el historial suprima reemplazar un representante eliminado.

`efz_corpus:semantic_representatives/0` es consulta serializada de solo lectura
fuera del bucle. Devuelve `{ok,#{Feature=>ExistingEntryId}}`, hasta 12 claves,
y rechaza características vistas sin representante activo. Desactivado/solo
observación devuelve `disabled`. El índice se deriva de entradas reales,
sin referencias guardadas, caché ni extracciones RNG. Los metadatos exigen
esquema exacto de cuatro claves y conjunto canónico acotado; tamaños excesivos,
listas impropias e IDs desconocidos se rechazan antes de ordenar.
Las [pruebas P4](p4-feedback.md) aplican el subconjunto a otro almacén, lo
reinician y verifican conservación estructural/semántica. Editar online no se
admite; cambios entre campañas reconstruyen visto del corpus actual durante
calibración explícita, sin índice global persistido obsoleto.

El reinicio valida metadatos y calibra todos los bytes para reconstruir
anotaciones/visto compatibles antes de mutar. Envoltura EFZC v1 y registros
antiguos v1/v2 siguen aceptados; descubrimientos semánticos usan v3.
Diferencias de espacio/esquema/características fallan al restaurar;
diferencias de build siguen reject/recalibrate existentes. Restaura corpus
reutilizable, no punto de control PRNG exacto.

## Observador, oráculo, errores y reproducción

El intervalo y aislamiento por módulo se fijan en architecture.md. El
observador usa resumen acotado comprobado del resultado principal sin
decodificar ni ejecutar objetivo. El oráculo activado/con presupuesto compara
campos canónicos ordenados del modelo con resultado completado del parser.
Coincidir da Pass; diferencia o rechazo de modelo canónico admitido da Fail.
Rechazo genérico por sí solo no es defecto. No admitido/límite/timeout/
excepción/presupuesto agotado da Inconclusive con motivo, nunca Pass.
El oráculo puro hace cero llamadas adicionales. No hay implementación
asíncrona/diferida. Repetir objetivo en el futuro debe usar intervalo EFZ
separado controlado, IDs, presupuesto finito y contadores de llamadas.

| Taxonomía | Política real |
| --- | --- |
| expected_rejection | Errores enumerados por harness devuelven rejected; resultado ordinario |
| target_exception / target_timeout | Hallazgos y limpieza existentes de excepción/exit/timeout |
| oracle_failure | Almacén independiente existente; bytes/resultado originales y auxiliar de propiedad/versión |
| semantic_layer_error | Contador/diagnóstico separado, detener como infrastructure_failure; nunca defecto del objetivo ni alternativa |
| infrastructure_error | Política existente de errores de ciclo de vida/cobertura/persistencia/configuración |
| VM/native crash | Solo resultado externo aplicable existente; sin nuevo capturador nativo |

Frontera códec/mutador/generador malformada devuelve `{error,boundary}`.
No admitido/límite esperados devuelve skip; errores de frontera del observador
y resultados inesperados/excepciones se convierten en
`{error,{semantic_layer_error,Class,BoundedReason}}`. Los fallos del objetivo
se guardan antes de callbacks; un fallo de observador no los borra.
Comprobar tiempo no es cancelar; matar Erlang no garantiza interrumpir nativo.

`efz_crash:signature/2` mantiene versión/clase/política de motivo. Hallazgos
del oráculo usan clase oracle_failure, motivo `{query_model_agreement,1}` y
pila vacía. Las huellas predeterminadas por categoría clasifican por etiqueta
de propiedad; propiedad/versión completas y entrada original siguen en
artefactos. La reproducción exige EFZS v1, vector/propiedad compatibles,
SHA256 original y harness/builds fijados elegidos por el llamador. Los términos
del artefacto no eligen callbacks ejecutables. La minimización conserva el
mismo fallo v1; otras excepciones/timeouts/entradas no admitidas no lo
satisfacen. Presupuesto finito 1..10000 cuenta llamadas incluidas reproducción
inicial; hallazgos originales inmutables. El resultado afirma mínimo por
eliminación de un byte o presupuesto agotado, no mínimo global.

Fixtures, códigos de salida, límites de revisión y traspaso:
[p1-validation.md](p1-validation.md).
