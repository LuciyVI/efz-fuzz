# Ocurrencias de fallos, firmas y reproducción verificada

[English](../../replay.md) · [Русский](../ru/replay.md) · **Español** · [简体中文](../zh-CN/replay.md) · [Todos los idiomas](../README.md)

El `.input` original es el binario autoritativo que desencadenó el fallo.
Una receta reconstruye bytes; una firma agrupa fallos; ninguno sustituye la
entrada original ni el diagnóstico completo Reason/pila. Replay usa el ejecutor
instrumentado existente con el contrato explícito `Module:run(binary())`.
No crea un segundo motor de fuzzing.

## Identidades y límites del informe

| Campo | Identidad / finalidad |
|---|---|
| `occurrence_id` | ID aleatorio nuevo de 128 bits por cada fallo detectado del objetivo, incluidas repeticiones de la misma entrada |
| `input_hash` | SHA-256 de los bytes exactos que desencadenaron el fallo, independiente de su clasificación |
| `signature_id` | SHA-256 de la firma de fallo normalizada y versionada |
| `group_id` | Grupo único de fallo, actualmente igual a `signature_id` |
| `id` | Alias de compatibilidad para la firma de grupo; **no es ID de ocurrencia** |
| `crash_signature` | Descriptor normalizado legible; no sustituye los diagnósticos originales |

Configuración de campaña mediante `efz:start/1`:

```erlang
crash_policy => #{reason => category, max_frames => 5, max_representatives => 3}
```

Se rechazan claves de política desconocidas. `max_frames` y
`max_representatives` aceptan 1..32. La política Reason predeterminada `category`
conserva un motivo átomo o el primer átomo de una tupla; por ejemplo,
`{badmatch, Bytes}` pasa a `{tag,badmatch}`. De lo contrario conserva el tipo
del término. `exact` conserva valores, pero sustituye identidades
pid/reference/port/fun por marcadores tipados. `ignore` omite Reason de la
clasificación. Son heurísticas de agrupación: `category`/`ignore` pueden unir
bugs distintos con la misma pila, mientras `exact` separa deliberadamente
motivos dependientes de datos. Las rutas dentro de un Reason `exact` son datos
y no se reescriben.

El esquema de firma v2 incluye clase, política de motivo, Reason normalizado
y como máximo `max_frames` marcos del objetivo. Los marcos son
`{Module,Function,Arity}`: listas de argumentos se convierten en aridad;
se excluyen archivo/línea/columna y marcos de ejecutor/guardian/cobertura.
El hash usa un orden explícito de campos de tupla y los mapas de Reason se
convierten en pares ordenados. No se usa el orden predeterminado ETF de mapas,
dependiente de VM. Rutas originales, listas de argumentos y **Reason original
completo** permanecen en `artifact.term`. Los artefactos antiguos de huellas
no se alteran ni se reagrupan automáticamente.

`Report.crashes` contiene una entrada por firma con `occurrences`,
`first_occurrence_id`, `last_occurrence_id` y `representatives`. Conserva
entrada/resultado/metadatos/ruta del primer representante como campos de
compatibilidad. Solo los primeros N **hashes distintos de entrada** entran en
la lista de representantes y en las `decisions` de fallos; las repeticiones
incrementan contadores sin añadir decisiones. `crash_occurrences` incluye
crashes, exits y timeouts; `crashes` y `timeouts` siguen como contadores
separados. `unique_crashes` cuenta grupos, incluidos los no guardados.
Estos contadores describen la campaña actual. Cada grupo también expone
`durable_occurrences`, `disk_representatives` y `group_path`, obtenidos del disco.

El mismo límite `max_representatives` se aplica a **disco e informe por firma**.
El disco conserva los primeros N hashes distintos entre campañas/reinicios VM.
Una ocurrencia nueva de una entrada seleccionada devuelve
`storage => duplicate`, incrementa el contador y reutiliza su artefacto inmutable.
Entonces `path` nombra ese representante; `representative_occurrence_id`
identifica la ocurrencia realmente guardada allí, mientras `occurrence_id`
identifica el evento actual. Sus bytes originales coinciden; los Reason/receta/
metadatos de compilación guardados pertenecen al representante original.

Una entrada nueva que exceda el límite en disco devuelve
`storage => limit_reached`, incrementa el contador persistente y **no tiene ruta
de artefacto**. No se escribe ningún archivo para ella. La campaña actual puede
conservarla entre sus representantes acotados en memoria con bytes/Reason exactos
y disposición explícita de almacenamiento. Reducir el límite por debajo de la
cantidad ya almacenada falla; no se eliminan hallazgos silenciosamente.
Aumentarlo permite que entradas nuevas posteriores sean representantes.

Es un límite de recuento por firma, no una cuota global de bytes ni límite del
número de firmas distintas. Se conserva Reason completo en los artefactos
seleccionados; las ocurrencias no seleccionadas se cuentan, no se archivan
individualmente. Una traza de mutaciones solicitada tiene su propio `trace_limit`.

## Estructura atómica de artefactos y política de interrupciones

```text
CRASH_DIR/SIGNATURE_SHA256/
  summary               EFZG v1 durable counter and representative IDs/hashes
  OCCURRENCE_ID/         only for selected representatives
    artifact.input      exact binary, no term encoding
    artifact.term       schema v2 complete raw result/Reason, metadata and policy
    artifact.replay     EFZX v1 compatibility expectation
    artifact.recipe     optional EFZR v1 concrete mutation provenance
    manifest            file sizes and SHA-256 hashes
  .lock/                exclusive writer; absence required before another save
  .tmp-*                uncommitted writes; not findings
```

`efz_crash_store` serializa escritores con un bloqueo exclusivo de directorio,
incluidos escritores de VM independientes. Valida el resumen existente y todos
los manifiestos de artefactos seleccionados antes de aceptar otra ocurrencia.
Primero confirma los artefactos mediante fsync/cierre de archivos, sincronización
de directorio y renombrado atómico. Después un reemplazo atómico de archivo
sincronizado publica `summary`; eliminar el bloqueo también va seguido de sync
del directorio. No hay diario de eventos append-only ni archivo por ocurrencia
para entradas descartadas. Repetir el **último ID de ocurrencia confirmado**
es idempotente; las llamadas normales siempre asignan un ID nuevo.

EFZG v1 usa un envoltorio de 41 bytes `EFZG`/versión/longitud/SHA-256 y ETF
seguro sin comprimir, limitado a 16 KiB. El esquema de siete claves contiene
versión, firma, contador de ocurrencias sin signo de 64 bits, ID primero/último,
último hash de entrada y como máximo 32 pares distintos ID/hash de
representantes. No hace falta decodificar átomos derivados del objetivo ni
Reason original. `efz_crash_store:read(GroupDirectory)` devuelve el índice validado.

Un escritor interrumpido puede dejar un bloqueo, archivos temporales o un
artefacto confirmado aún no referenciado por summary. Causan **errores explícitos
de infraestructura**, no reinicio a un índice vacío. El bloqueo se informa como
`writer_active_or_interrupted`; EFZ no adivina si otra VM ha muerto.
Un fallo posterior a publicar el artefacto conserva el original e informa
`saved_artifact` cuando se conoce. Los contadores reflejan actualizaciones
confirmadas del resumen; un evento interrumpido no confirmado no tiene garantía
de reanudación exacta. Los bytes que provocaron el fallo permanecen en el
contexto runtime del error si falla el almacenamiento.

Los grupos antiguos sin `summary` se rechazan al escribir como
`unindexed_crash_group`. Siguen siendo reproducibles y no se eliminan ni migran
automáticamente. Use un directorio nuevo para un almacén acotado nuevo y conserve
el antiguo como archivo histórico. Ante almacenes interrumpidos, compruebe que
no quedan escritores e inspeccione artefactos confirmados antes de recuperar;
quitar solo el bloqueo no evita validar el índice. Estas protecciones impiden
que los reinicios excedan silenciosamente el límite en disco.

La reproducción original sigue requiriendo solo `.input` y `.replay` confiable;
`.recipe`/`.term` opcionales corruptos o ausentes no bloquean la recuperación.
Las **escrituras** posteriores rechazan representantes corruptos.
`efz_fs:validate_group/1` sigue disponible para validar explícitamente el grupo completo.

Una receta malformada no puede impedir guardar un representante original
seleccionado: EFZ guarda entrada/resultado/expectativa sin receta y devuelve
`operation => encode_recipe`. En el límite informa error de receta y disposición
explícita de retención; no afirma haber guardado una entrada descartada.
Incluye `saved_artifact` si existe un representante de entrada exacta.
Los fallos principales de archivos/receta no se sustituyen por errores al
liberar el bloqueo o escribir después el informe.

Ante un fallo tardío del guardian **después** de su respuesta, el ejecutor
conserva un resultado previo de infraestructura y registra el secundario
`guardian_failure`. El resultado original de la respuesta, diagnósticos de
cobertura y evidencia de limpieza quedan en `execution_evidence`; la limpieza
final pasa a `unconfirmed` y se retira la VM. Retroalimentación/informe/estadísticas
conservan la causa principal. `efz_crash_retention_tests` inyecta este fallo tras
la respuesta real en una VM privada, sin opción de inyección en producción.

## Ejecutar el ejemplo y reproducir en una VM nueva

Desde la raíz del repositorio:

```sh
rebar3 compile
escript examples/staged/run.escript
escript scripts/replay.escript --input _build/staged-example.input \
  --target efz_staged_parser --artifacts _build/staged-targets
escript scripts/replay.escript --recipe _build/staged-example.recipe \
  --target efz_staged_parser --artifacts _build/staged-targets
```

El ejemplo copia su expectativa guardada a `_build/staged-example.replay`.
Para un adaptador externo añada `--code-path /path/to/harness/ebin`, repetible.
`--expect FILE.replay` sustituye el archivo hermano predeterminado de expectativa.
`--timeout MS` usa 100 por defecto; `--max-input-bytes N` usa el límite registrado
de la campaña para ejecutar. `--help` enumera ejecución y reconstrucción.

| Exit | Significado |
|---|---|
| 0 | `reproduced`: arnés/compilación compatibles y misma firma normalizada de fallo |
| 3 | `not-reproduced`: ejecución compatible devolvió normalmente o falló de otra manera |
| 2 | Argumentos/datos inválidos, hash de entrada distinto, identidad esperada ausente o incompatibilidad de compilación/arnés |
| 1 | Fallo de infraestructura de archivos/ejecutor; nunca se informa como simple no reproducción |

La ejecución verifica primero SHA-256 exacto, hace preflight de los artefactos
suministrados y compara el conjunto **completo** esperado de compilaciones.
Compara nombre del módulo del arnés guardado, MD5 BEAM, SHA-256 de atributos
deterministas e ID instrumentado opcional. Las rutas de compilación de fuentes
se excluyen del registro portátil; código BEAM, atributos e identidad de
compilación instrumentada todavía deben coincidir. Nuevas fijaciones de identidad
protegen después contra sustitución entre preflight y ejecución. La reproducción
original **no** carga `.term` ni `.recipe`; diagnósticos o receta corruptos/
ausentes no bloquean recuperar una entrada válida. Replay de receta comprueba
los bytes regenerados contra el mismo hash esperado. Las discrepancias se
rechazan antes de llamar al objetivo; no hay fallback sin verificar ni opción
para forzar incompatibilidad.

Reproducir significa igual firma normalizada, no igualdad de términos Reason
no deterministas ni rutas de fuentes de pila. Un objetivo no determinista puede
legítimamente devolver `not-reproduced`. Los fallos del ejecutor son errores
de infraestructura.

## Expectativa de reproducción (EFZX v1)

`artifact.replay` tiene cabecera de 41 bytes: `EFZX`, byte de versión 1,
longitud big-endian de 32 bits, SHA-256 y ETF sin comprimir de longitud exacta.
Las lecturas se limitan a 2 MiB. La decodificación segura no crea átomos derivados
del objetivo: los nombres de módulos son binarios y solo hacen falta átomos
fijos del esquema EFZ. El esquema listo tiene exactamente ocho claves:
`schema_version`, `status`, `harness`, `target_builds`, `input_hash`,
`signature_id`, `crash_policy`, `max_input_bytes`. Las compilaciones contienen
nombres binarios únicos y hashes de 32 bytes; se validan campos y tamaños del
arnés antes de ejecutar. Estos datos no eligen ningún objetivo invocable.

Los resultados de bajo nivel/manuales sin arnés fijado más compilaciones
instrumentadas seleccionadas escriben `status => unavailable`. La reproducción
verificada rechaza esas expectativas. Una receta antigua por sí sola no puede
demostrar la identidad original del arnés. El llamador debe suministrar una
expectativa confiable separada; seleccionar el arnés actual y afirmar que era
el anterior no verifica compatibilidad. Las sumas detectan corrupción, no
manipulación deliberada ni autenticidad.

## API Erlang y reconstrucción de bytes

```erlang
[Crash | _] = maps:get(crashes, Report),
Path = maps:get(path, Crash),
{ok, Expected} = efz_replay:load(Path ++ ".replay"),
{ok, Verdict} = efz_replay:run(raw, Path ++ ".input", my_harness,
    Artifacts, Expected, #{timeout => 1000}),
maps:get(status, Verdict).
```

`efz_recipe:execute/5` y `execute_file/5` siguen siendo API de ejecución de bajo
nivel. Sus Options ahora **requieren `expected_harness`**, obtenido de metadatos
guardados confiables, además de objetivo/artefactos/compilaciones esperadas
explícitos. Devuelven el resultado del ejecutor sin decidir si se reprodujo
la firma. Aceptan `timeout`, `coverage_backend`, `max_input_bytes`; rechazan
identificadores de planes preparados. Se crea y libera un plan nuevo en cada
reproducción. `efz_replay:run/6` usa esa misma ruta y compara la firma resultante.
`harness_identity/1` captura una identidad portátil al descubrir;
`pin/3` la verifica antes de ejecutar.

Reconstruir bytes sigue siendo independiente del código compatible:

```sh
escript scripts/replay.escript _build/staged-example.recipe _build/regenerated.input
cmp _build/staged-example.input _build/regenerated.input
escript scripts/replay.escript docs/examples/staged-crash.recipe _build/from-docs.input
cmp docs/examples/staged-crash.input _build/from-docs.input
```

La CLI posicional histórica solo regenera bytes: límite predeterminado 4096,
`--max-input-bytes N` opcional. No verifica compatibilidad del objetivo ni afirma
reproducir un fallo. Entradas de calibración y mutaciones aleatorias pueden no
tener receta. Para entradas por etapas, `efz_recipe:load/1` + `regenerate/1`
reconstruyen bytes exactos a partir de los bytes principales/donantes y las
operaciones concretas, sin corpus, RNG ni plan activo. Las entradas retenidas
del corpus guardan su receta en `metadata.mutation`.

## Formato de artefacto EFZR, versión 1

Todos los enteros multibyte del envoltorio usan orden big-endian:

```text
"EFZR" (4 bytes)
format version = 1 (1 byte)
payload length (4 bytes)
SHA-256 of payload (32 bytes)
uncompressed Erlang external-term payload (exact length)
```

La carga es un mapa de datos validado con exactamente estos campos:

| Campo | Significado |
|---|---|
| `schema_version`, `engine_version`, `operation_version` | Todos 1 en esta fase; versiones desconocidas se rechazan |
| `primary`, `primary_id`, `parent` | Bytes originales de entrada, SHA-256 e ID diagnóstico en el corpus |
| `operations` | Tuplas concretas ordenadas, como máximo 32; incluyen bytes/hash de donantes y bytes reales de diccionario/literales |
| `stage` | Etapa responsable de este candidato |
| `config_id`, `dictionary_id` | Identidades SHA-256 de configuración/diccionario normalizados originales |
| `limits` | Límites de entrada, bloque, token y aritmética necesarios para validar las operaciones |
| `output_size`, `output_hash` | Longitud esperada en bytes y SHA-256 del candidato |
| `target_builds` | Nombres binarios de módulos e ID fijados de compilación; sin referencia invocable de módulo |
| `rng` | Algoritmo diagnóstico `exsplus` y tupla inicial de semillas enteras; sin estado interno/manejadores |

La receta no necesita diccionario, corpus, archivos, índices de cola, checkpoints
RNG ni plan activo originales. La identidad de configuración nombra las decisiones
originales; la lista concreta de operaciones, no otra ejecución del planificador,
determina los bytes de replay. Se omiten intentos saltados porque no alteraron
bytes intermedios. Los offsets se aplican secuencialmente al resultado intermedio,
según la semántica especificada en [mutations.md](mutations.md).

Los archivos de receta se limitan a 40 MiB. Entradas/donantes deben cumplir el
límite registrado de campaña, cuyo máximo es 1 MiB. `regenerate/1` usa ese límite;
`regenerate/2` acepta además el límite actual de campaña, por ejemplo
`#{max_input_bytes => 4096}`, y también comprueba tamaños intermedios.
El escript usa 4096 por defecto y acepta `--max-input-bytes N`.
El decodificador comprueba el envoltorio de longitud/hash y explora la estructura
ETF **antes** de decodificar. Permite enteros acotados, etiquetas de átomos
existentes, binarios, listas, tuplas y mapas. Rechaza compresión, objetos
process/reference/port/fun, datos sobrantes, anidamiento excesivo superior a 24,
más de 20,000 términos, listas de más de 4,096 entradas y campos binarios
excesivos. La decodificación segura no crea átomos derivados de tokens.
Después la validación de operaciones/esquema comprueba campos permitidos,
versiones, hashes principales/donantes, límites, resultados realizados de
operaciones y longitud/hash final.

Codificaciones malformadas devuelven `{error,invalid_recipe_encoding}`;
otros fallos incluyen `incompatible_recipe`, `recipe_size_limit`,
`output_hash_mismatch`, `output_size_mismatch`, `{invalid_recipe,Reason}` y
`{recipe_operation,Reason}`. Una operación que sería omitida, incluido un offset
que no encaja, es inválida en una receta realizada. Ninguna tupla se evalúa
como fuente Erlang ni se despacha a un módulo arbitrario. El análisis de archivos
no usa un evaluador de expresiones.

Las sumas detectan corrupción; no son autenticación. El formato existente de
resultados de fallos `.term` es independiente y puede contener referencias
diagnósticas runtime; no es el formato acotado de importación EFZR ni dependencia
de replay.
## Verificación

`efz_crash_tests` usa un parser instrumentado real, arnés binario normal,
mutaciones por etapas y CLI VM nuevas. Demuestra ocurrencias separadas para
entradas distintas, firmas estables tras reubicar fuentes, motivos dependientes
de datos configurables, reproducción original y de recetas, rechazo de
incompatibilidad de compilación/arnés, gestión de corrupción y salidas distintas
para no reproducción e infraestructura, incluidas entrada ilegible y directorios
de artefactos ausentes. Una campaña de 1000 ocurrencias conserva un grupo,
tres representantes y tres decisiones de fallo, preservando tres artefactos
de entrada y un resumen con contador 1000. Pruebas reales de muerte de
coordinador/trabajador verifican informe del fallo principal, estadísticas y
limpieza. Las pruebas existentes de límites, recetas, cobertura, corpus
persistente y reutilización de padres por etapas cubren la ruta runtime compartida.

Validado en el toolchain OTP 27 del proyecto. Recompilar con otros fuentes/
opciones/toolchain puede cambiar la identidad y rechazar intencionalmente
expectativas antiguas de ejecución. Reconstruir bytes de recetas tiene su propio
contrato versionado.

## Hallazgos runtime

El esquema runtime v1 es independiente de expectativas/recetas de fallos.
Reproduzca con `efz_replay:runtime(Directory, LocalTarget, Artifacts, #{runs=>3})`
o `scripts/replay.escript --runtime-finding DIRECTORY --target MODULE --artifacts DIR
--runs 3`. Las comprobaciones de identidad/hash/política preceden al mismo
ejecutor; la salida distingue `observed`, `not_observed`, `inconclusive`, incluidos
número de muestras y repetibilidad. Una repetición exitosa no refuta inestabilidad.
[Formato y límites completos](runtime-diagnostics.md).
