# Límites de entrada y fallos de almacenamiento

[English](../../input-and-storage.md) · [Русский](../ru/input-and-storage.md) · **Español** · [简体中文](../zh-CN/input-and-storage.md) · [Todos los idiomas](../README.md)

`max_input_bytes` es una opción de campaña, predeterminada **4096**, con rango
inclusivo **0..1048576**. Cero permite solo `<<>>`. El máximo se permite;
máximo más uno se rechaza. Ninguna capa trunca ni convierte los bytes de entrada.

```erlang
{ok, _} = efz:start(#{target => my_harness, artifacts => Artifacts,
    seeds => [<<>>], mutation_mode => staged, max_iterations => 100,
    max_input_bytes => 4096,
    mutation => #{stages => [dictionary_insert, bitflip], dictionary => [<<"A">>]}}).
```

La opción anidada anterior `mutation.max_input_bytes` ahora devuelve
`{error,{campaign_level_option,max_input_bytes}}`. El plan interno normalizado
de mutación y las recetas guardadas siguen conteniendo el límite derivado para
reproducción determinista. La API independiente del planificador conserva su
propio mapa explícito de opciones.

| Límite | Comportamiento |
|---|---|
| Semillas iniciales | La configuración valida todos los tamaños binarios antes de calibrar, en ambos modos |
| Semillas CLI | Lectura de como máximo límite + 1 bytes; los archivos sobredimensionados fallan con ruta y cota inferior de tamaño |
| Corpus restaurado | Lectura acotada al límite actual de campaña antes de calibrar; no se omite silenciosamente |
| Inserción en corpus activo | Comprueba el mismo límite antes de insertar/persistir |
| Mutación aleatoria | Recibe el límite en opciones del callback; el mutador integrado sustituye inserción por sobrescritura al alcanzar capacidad; con cero devuelve entrada vacía |
| Worker / executor | Validan antes de invocar el harness; un callback aleatorio personalizado que incumple produce un fallo de infraestructura conservando su candidato exacto |
| Mutación staged | Todas las operaciones, valores intermedios y donantes usan el límite derivado |
| Entrada de caída | `save/4` valida el límite de campaña antes de trabajar con el sistema de archivos |
| Reproducción | La ejecución de bytes de bajo nivel usa `Opts.max_input_bytes`, predeterminado 4096; la CLI de reproducción verificada usa por defecto el límite registrado de campaña |

La API histórica de bajo nivel del executor sigue admitiendo experimentos de
instrumentación basados en términos si no se proporciona la opción de límite
de bytes. Las ejecuciones de campaña y reproducción siempre pasan explícitamente
el límite y requieren entrada binaria.

## Reproducción

`efz_recipe:regenerate(Recipe)` valida con el límite de campaña registrado en
la receta. `regenerate(Recipe, #{max_input_bytes => Max})` también aplica el
límite actual al principal, donantes, todos los valores intermedios y salida;
no relaja el límite registrado. `regenerate(Recipe, #{})` usa 4096 por defecto.

```erlang
{ok, Input} = efz_recipe:regenerate(Recipe, #{max_input_bytes => 4096}),
{ok, Expected} = efz_replay:load(ExpectationPath),
{ok, Result} = efz_recipe:execute_file(InputPath, my_harness, Artifacts, Builds,
    #{timeout => 1000, max_input_bytes => 4096,
      expected_harness => maps:get(harness, Expected)}).
```

```sh
escript scripts/replay.escript finding.recipe exact.input --max-input-bytes 4096
```

Los contenedores de metadatos de recetas y corpus conservan límites separados
de tamaño de *metadatos*; no permiten entradas de fuzzing mayores. Los binarios
en memoria sobredimensionados informan SHA-256 y tamaño exacto. Los lectores
de archivos acotados informan una cota inferior de tamaño y la ruta, sin
presentar el hash de un prefijo como identidad de la entrada.

## Transacción de caída y errores

`efz_crash:save(Input, Result, Metadata, #{crash_dir => Dir, max_input_bytes => Max})`
devuelve `{ok, Crash}` o `{error, ErrorMap}`. El cuarto argumento que solo es
un directorio usa 4096 por defecto. Un mapa de error de sistema de archivos
incluye:

```erlang
#{kind => filesystem, operation => open, path => Path, reason => eacces,
  input_hash => InputSHA256, signature_id => Signature, group_id => Signature,
  occurrence_id => Occurrence, crash_fingerprint => Signature,
  artifact_group => Group, staging_path => Staging}
```

`operation`, `path` y `reason` describen el fallo principal. Los opcionales
`close_error` / `cleanup_error` conservan fallos secundarios sin sustituirlo.

Disposición publicada:

```text
crash_dir/
  SIGNATURE_SHA256/
    summary                  (recuento persistente acotado / índice de representantes)
    .lock/                   (escritor exclusivo; ausente entre guardados)
    OCCURRENCE_ID/            (solo el representante seleccionado)
      artifact.input
      artifact.term          (Reason/pila originales completos y metadatos)
      artifact.replay        (compilación/harness/entrada/firma esperados)
      artifact.recipe        (cuando hay procedencia staged válida)
      manifest               (versión, tamaños de archivo y hashes SHA-256)
    .tmp-RANDOM/              (staging sin confirmar tras matar al escritor)
```

Cada archivo se escribe exclusivamente, se sincroniza con fsync y se cierra
en un directorio temporal. Después del fsync de ese directorio, un rename
publica el grupo completo y se sincroniza el padre. Los directorios padres
ausentes se crean y sincronizan. Ante fallos ordinarios se elimina el staging
no publicado; un fallo de limpieza informa su ruta. Un escritor interrumpido
puede dejar un directorio reconocible `.tmp-*`; no tiene identidad de grupo
confirmada y no debe usarse como hallazgo. No busque globalmente `.input` sin
excluir staging. Si se mata después de rename, el grupo publicado está completo.
Un fallo de fsync del padre tras rename informa error aunque pueda existir
un grupo completo. La publicación del artefacto y la actualización de summary
son confirmaciones separadas: un huérfano tras interrupción se diagnostica,
nunca se descarta silenciosamente ni se cuenta como almacén vacío.

`efz_crash_store` aplica `crash_policy.max_representatives` entre campañas y
reinicios de VM. Conserva los primeros N hashes distintos de entrada, cuenta
cada ocurrencia confirmada en un `summary` atómico sincronizado y excluye
escritores concurrentes mediante bloqueo de directorio. Valida summary y
manifiestos de representantes antes de guardar. Solo el último ID de ocurrencia
confirmada puede reintentarse de forma idempotente. Un escritor matado puede
dejar `.lock`, `.tmp-*` o un artefacto no indexado; todos bloquean nuevas
escrituras con error estructurado hasta investigarlos. Esto no es reanudación
exacta de campaña.

`storage => saved` identifica un artefacto inmutable nuevo; `duplicate` reutiliza
un representante de entrada exacta identificado por
`representative_occurrence_id`. Su Reason/receta originales pertenecen a esa
ocurrencia guardada. `limit_reached` no proporciona ruta ni escribe un artefacto
individual para esa entrada. El informe contiene recuentos de campaña actual,
además de `durable_occurrences` y `disk_representatives`. Son límites por firma,
no una cuota global de bytes. Los representantes seleccionados conservan el
Reason original completo.

Los archivos de representante ausentes/truncados/no coincidentes fallan la
validación. Los grupos antiguos sin `summary` rechazan explícitamente la
escritura y siguen siendo reproducibles; use un directorio de salida nuevo
para almacenamiento acotado y conserve el archivo original. Reducir el límite
por debajo del número guardado de representantes también se rechaza sin
eliminar hallazgos. `Crash.path`, cuando existe, sigue siendo un prefijo que
termina en `artifact`.

Una receta malformada/no coincidente no impide guardar una entrada original
seleccionada: se publica sin receta, con diagnóstico completo y `recipe_error`.
`save/4` devuelve entonces el error principal de receta, la disposición de
retención y `saved_artifact` cuando existe un representante de entrada exacta.
Al alcanzar el límite, el error sigue conservando los bytes desencadenantes
en el contexto de ejecución; no afirma que estén en disco. La reproducción
sin procesar solo necesita `.input` y `.replay` de confianza, independientemente
de receta/diagnósticos originales opcionales. Consulte
[caídas/reproducción/informe](replay.md).

Un fallo de almacenamiento detiene la campaña con
`{infrastructure_failure, ErrorMap}`, incrementa `infrastructure_failures` una
vez y conserva el contador de caídas del objetivo. `unique_crashes` cuenta
firmas detectadas, incluidas las no guardadas. `crash_occurrences` cuenta todos
los fallos del objetivo, incluidas repeticiones y tiempos límite. El informe
conserva resultado/pila de caída y bytes exactos en `crashes` y
`failure_context`, junto con receta, hash y motivo principal de almacenamiento.
No hace falta una caída del worker para comunicar el fallo. Un fallo de
huella repetida siempre está en `failure_context`, aunque `crashes` ya contenga
un representante anterior.

El informe final CLI y escrituras independientes de recetas/salida también usan
publicación write/fsync/close/rename de archivo temporal. Si falla el propio
almacenamiento del informe, la CLI incrementa el contador de infraestructura
e incluye el informe en memoria en el diagnóstico, conservando cualquier fallo
principal anterior de campaña. La muerte del worker también incrementa
`infrastructure_failures`; el fuzzer conserva el último contexto recibido de
entrada exacta. `primary_infrastructure_failure` en estadísticas se establece
solo con el primer fallo.

Este protocolo presupone un sistema de archivos con rename atómico en el mismo
directorio y fsync de archivos/directorios. Las operaciones no admitidas
devuelven errores de infraestructura.

## Verificación

`test/efz_limits_tests.erl` prueba ejecución instrumentada real, límites
aleatorios y staged, corpus retenido/restaurado, reproducción y límites de
caídas originales. Comprueba un antecesor que es archivo ordinario (equivalente
a `/dev/null/invalid-dir`), `eacces` Unix real, padres ausentes, fallo en el
segundo artefacto tras sincronizar el primero, datos confirmados corruptos y
un escritor staging matado. El caso de permisos requiere un proceso de prueba
sin privilegios para ejercer la denegación de permisos Unix. Las pruebas
existentes de CLI en VM nueva, reproducción de recetas, corpus persistente
y linaje staged siguen validando la integración.
