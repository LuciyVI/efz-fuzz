# Corpus persistente reutilizable

[English](../../corpus.md) · [Русский](../ru/corpus.md) · **Español** · [简体中文](../zh-CN/corpus.md) · [Todos los idiomas](../README.md)

La persistencia se activa mediante `corpus_dir` en el mapa de campaña o
`--corpus-dir` en el lanzador. Sin esa opción se mantiene el comportamiento
existente en memoria. El almacén conserva las entradas iniciales y los
descubrimientos exitosos de cobertura nueva entre `efz:stop/0`, la terminación
del proceso y los reinicios de la VM. Los fallos y tiempos de espera de entradas
mutadas siguen yendo únicamente al almacenamiento de fallos existente.
Las semillas iniciales se guardan antes de calibrarlas, incluidas las que
posteriormente resulten provocar un fallo.

```erlang
{ok, _} = efz:start(#{target => my_harness, artifacts => Artifacts,
    seeds => [<<>>], corpus_dir => "findings/corpus",
    mutation_mode => staged, max_iterations => 1000}).
First = efz:await(infinity),
ok = efz:stop().

%% A later VM loads the same compatible harness and artifacts.
{ok, _} = efz:start(#{target => my_harness, artifacts => Artifacts,
    seeds => [], corpus_dir => "findings/corpus",
    mutation_mode => staged, max_iterations => 1000}).
Second = efz:await(infinity).
```

En la CLI, añada `--corpus-dir ./findings/corpus` al primer lanzamiento. Después:

```sh
escript scripts/fuzz.escript \
  --target my_harness --code-path ./harness-ebin \
  --artifacts ./instrumented --out ./findings \
  --corpus-dir ./findings/corpus --mutation staged --max-iterations 1000
```

## Almacenamiento y publicación

```text
CORPUS_DIR/
  <64 lowercase hex SHA-256 of input>/
    input       exact raw binary, including zero-length inputs
    metadata    checksummed EFZC envelope containing versioned metadata
  .tmp-<random transaction suffix>/   unpublished transaction, if interrupted
```

El hash del contenido es la identidad. Las entradas confirmadas son inmutables
y un duplicado conserva su primera procedencia registrada. Antes de deduplicar,
un guardado valida cualquier entrada existente; nunca repara ni sobrescribe
silenciosamente datos confirmados corruptos. Los nuevos ID enteros del corpus
pertenecen a la campaña actual. Los ID históricos en los metadatos son únicamente
procedencia, no instrucciones para reconstruir la cola.

Los metadatos contienen:

| Campo | Significado |
|---|---|
| `schema_version` | `1` para entradas iniciales/de presencia; `2` para descubrimientos por recuento de aciertos |
| `content_hash`, `input_size` | SHA-256 y longitud exacta en bytes |
| `queue_id` | ID histórico en la cola de la campaña de origen |
| `origin` | `initial` o `discovery` exitoso de cobertura nueva |
| `parent` | `none` para semillas iniciales; SHA-256 del contenido e ID histórico de cola del padre para descubrimientos |
| `discovery` | Fase e identidades de sondas recién observadas; v2 también almacena `coverage_feedback`, `retention_reason`, `new_count_features` |
| `identity` | Nombre del módulo del arnés, `run/1` canónico, MD5 del código cargado del arnés, modo de cobertura e identidades SHA-256 de los módulos/compilaciones seleccionados |
| `recipe` | Receta EFZR codificada cuando está disponible; de lo contrario, `none` |

Los nombres de módulos de sondas automáticas y compilaciones se almacenan como
binarios, por lo que cargar metadatos no puede crear átomos arbitrarios.
Los ID de cobertura manual son binarios ETF opacos para inspección histórica;
nunca se decodifican durante la restauración. Las referencias de ejecución,
los valores devueltos por el objetivo, PID, identificadores ETS y diccionarios
de procesos no forman parte de los metadatos persistentes. Las semillas RNG de
las recetas y los deltas de sondas son procedencia histórica; ninguno inicializa
el nuevo planificador ni su cobertura global.

El [modo opcional de recuento de aciertos](hit-count-experiment.md) escribe
registros v2 para descubrimientos: `retention_reason` es `new_probe` o
`new_hit_count`, y `new_count_features` contiene pares
`{PortableProbeIdentity, BucketLowerBound}`. Los descubrimientos únicamente de
recuento tienen una lista `new_probes` vacía y un delta de características no
vacío. La versión del envoltorio EFZC sigue siendo 1; los lectores validan la
versión del registro y su estructura específica. Los registros v1 existentes
siguen cargándose sin cambios. Los binarios antiguos rechazan explícitamente
entradas v2; use un directorio de corpus separado si debe leerlo un EFZ anterior.

El modo de retroalimentación no forma parte de la compatibilidad del objetivo/
compilación: las entradas originales son reutilizables en ambos modos y cada
entrada restaurada se recalibra. Los deltas históricos de intervalos de recuento
no se importan al conjunto global de características de la nueva campaña.

Un archivo EFZC contiene la marca `EFZC`, versión de envoltorio 1, longitud de
carga de 32 bits, SHA-256 de la carga de 32 bytes y metadatos ETF sin comprimir.
La carga comprueba tamaño/suma de verificación del envoltorio, gramática ETF
acotada de solo datos, esquema, campos obligatorios, tamaño/hash de la entrada,
identidad de contenido del directorio y coherencia de la receta con la entrada,
el padre y las compilaciones registradas. Las entradas originales se limitan a
1 MiB y los metadatos a 64 MiB por entrada. Las versiones de esquema no admitidas
son errores, no intentos de migración.

El orden de publicación es:

1. Crear un directorio temporal único dentro del directorio del corpus.
2. Escribir la entrada original mediante creación exclusiva; sincronizarla con fsync y cerrarla.
3. Escribir el archivo completo de metadatos; sincronizarlo con fsync y cerrarlo.
4. Sincronizar el directorio temporal y renombrarlo atómicamente al hash del contenido.
5. Sincronizar el directorio del corpus antes de confirmar el guardado.

Los directorios antecesores recién creados también se sincronizan a través de
su padre. Los archivos y el directorio temporal están en el mismo sistema de
archivos, por lo que los lectores ven una entrada completa al publicarla.
Un segundo publicador del mismo contenido valida la entrada ya publicada en vez
de sustituirla. La implementación nativa en Erlang usa `file:sync/1`, incluidos
identificadores de directorio abiertos con `[read,raw,directory]`. Esto se ha
probado en el entorno actual Linux/OTP 27. Un sistema de archivos sin fsync de
directorios falla explícitamente; no se reduce silenciosamente la durabilidad.
No se ha probado aquí una recuperación tras un corte real de alimentación.

El gen_server del corpus serializa la persistencia y la inserción.
Un descubrimiento exitoso se confirma antes de entrar en la cola activa o
incrementar `discoveries`. Ante un error de escritura/fsync, la entrada no se
inserta y el trabajador informa un fallo de infraestructura de persistencia del
corpus. Si el renombrado tuvo éxito pero falló el fsync final, la entrada puede
ser visible; aun así la campaña informa el fallo y una restauración posterior
valida esa entrada. No se confirma ningún éxito antes de la sincronización.

## Restauración y política de compilaciones

`efz_config` restaura entradas solo después de validar el objetivo/artefactos
actuales. Combina las semillas suministradas, en orden de inserción, con las
entradas persistidas, en orden de hash, y deduplica por SHA-256. El propietario
del corpus asigna ID nuevos y expone las entradas restauradas mediante las rutas
habituales `mutation_entries/0` y `select/0`. Los metadatos históricos están en
`metadata.persistence` de cada entrada; las entradas restauradas también llevan
`metadata.restored => true`.

El trabajador existente calibra **cada** entrada inicial, incluidas las
restauradas. Crea un conjunto global de cobertura, un RNG y un plan de mutación
perezoso nuevos. No se reanudan cursores del planificador, estado PRNG, cobertura
global anterior, ID exactos de cola ni orden de planificación. Esto reutiliza
entradas; no es una reanudación exacta de campaña ni un punto de control.

Las entradas restauradas deben cumplir el `max_input_bytes` actual de la campaña
en ambos modos de mutación; las entradas excesivas hacen fallar la configuración
con su ruta direccionada por contenido, una cota inferior de tamaño y el límite
activo. Nada se trunca ni excluye silenciosamente. El límite existente de 4,096
semillas iniciales suministradas sigue aplicándose después de deduplicar en modo
persistente; la cola activa restaurada puede ser mayor porque pudo crecer en
campañas anteriores. El almacén se carga de una vez, de modo que todas sus
entradas/metadatos deben caber en la memoria disponible de la VM.

| `corpus_build_policy` | Comportamiento |
|---|---|
| `reject` (predeterminado) | Fallar la restauración si difieren nombre/código del arnés, callback, modo de cobertura o identidades de compilaciones seleccionadas |
| `recalibrate` | Reutilizar entradas exactas entre identidades cambiadas; conservar procedencia histórica, emitir diagnósticos y calibrar con la compilación actual |

En ambos modos nunca se combinan los deltas antiguos de cobertura en la nueva
campaña. Los errores de esquema, suma de verificación, entrada y receta siguen
siendo fatales incluso con `recalibrate`.

## Entradas parciales y diagnósticos

Una entrada confirmada corrupta, la ausencia de `input` o `metadata`, truncamiento,
hash de contenido/nombre de directorio inválido o esquema incompatible hacen
fallar la restauración con ruta y motivo. No se acepta silenciosamente un
subconjunto parcial. Las entradas del sistema de archivos que no correspondan
al formato específico del almacén también producen un error.

Las entradas `.tmp-*` son escrituras sin publicar. Nunca se cargan como entradas
y se dejan para inspección. La restauración informa cada una como
`{interrupted_corpus_write,Path}` mientras carga las entradas confirmadas válidas.
Este diagnóstico y cualquier discrepancia de compilación permitida aparecen en
los avisos de inicio y en el informe final `corpus_restore.diagnostics`.
`corpus_restore` también informa directorio, política de compilación seleccionada
y cantidad de entradas restauradas. Elimine una entrada temporal abandonada solo
tras confirmar que ningún escritor la está usando.

## Evidencia

```sh
rebar3 eunit --module=efz_corpus_store_tests,efz_durable_tests,efz_cli_tests
```

La prueba de integración ejecuta mutaciones reales de diccionario por etapas e
instrumentación automática en VM Erlang separadas:

- VM 1: la entrada inicial `<<>>` con ID 1 produce `<<"A">>` con ID 2, alcanza cobertura nueva y la confirma.
- VM 1 termina. Una invocación separada verifica la deduplicación del contenido inicial/persistido.
- VM 2: con `seeds => []`, restaura y calibra ambas entradas. `<<"A">>` ahora tiene ID 1 y se convierte en la entrada principal/padre real de una mutación que produce `<<"AB">>`.
- Más VM nuevas verifican el rechazo predeterminado de compilaciones, la recalibración explícita entre compilaciones, los límites de entradas y la exclusión de fallos mutados de este almacén.

La prueba comprueba ID/hash del padre, regeneración exacta de recetas, resultados
del objetivo, sondas nuevas y procedencia guardada. Los registros e informes se
conservan bajo la ruta registrada en `_build/durable-e2e-latest.txt`.
Las pruebas unitarias cubren publicación duplicada, archivos corruptos/ausentes/
truncados, versiones de esquema, nombres de contenido, política de compilaciones
y fallos de escritura sin inserción en la cola. La prueba de escritura
interrumpida mata un proceso real tras escribir/sincronizar la entrada temporal
pero antes de publicarla; verifica que la transacción parcial se diagnostica
y no se restaura.
