# Mapa del repositorio EFZ: directorios y archivos

[English](../../repository-map.md) · [Русский](../ru/repository-map.md) · **Español** · [简体中文](../zh-CN/repository-map.md) · [Todos los idiomas](../README.md)

La función de cada archivo se contrastó con el árbol de trabajo el **15 de septiembre de 2026**.
La raíz de este documento es el directorio `efz/`; los checkouts adyacentes, como `../cowboy/`,
no forman parte de EFZ. La descripción abarca **186 archivos del proyecto**, incluido este
documento, y **21 subdirectorios**. Incluye archivos fuente aún no añadidos a Git,
pruebas, ejemplos, documentación y evidencias de validación guardadas.

Para cada archivo, el mapa indica su finalidad y función implementada o, en el caso de
los datos, su contenido y consumidor. Los detalles internos de Git y los resultados de compilación variables
se describen por separado, por categorías: los nombres de directorios de pruebas, registros y archivos BEAM
se regeneran y no se incluyen en los 186 archivos del proyecto.

Las relaciones entre componentes, la propiedad del estado y los diagramas UML se explican en la
[descripción de la arquitectura](architecture.md). Este mapa responde a «dónde están
las cosas», mientras que la arquitectura explica «cómo funcionan juntas».

## Navegación

- [Árbol de directorios y archivos raíz](#root)
- [src — ejecución y compilación de instrumentación](#src)
- [scripts — comandos de usuario](#scripts)
- [test — comprobaciones automatizadas](#test)
- [fixtures — objetivos y datos de prueba](#fixtures)
- [examples — integraciones de demostración](#examples)
- [bench — mediciones de rendimiento](#bench)
- [docs — documentación, UML y archivos históricos](#docs)
- [Archivos generados e internos](#generated)
- [Cómo encontrar dónde modificar una funcionalidad](#changes)

<a id="root"></a>
## Árbol de directorios y archivos raíz

```text
efz/
├── src/                      ejecución, contratos e instrumentación
├── c_src/                    auxiliar Linux del ciclo de vida del worker externo
├── priv/                     supervisor/controlador externo con límites
├── scripts/                  preparación, CLI de campañas/replay y benchmark de cobertura
├── test/                     EUnit y Common Test
├── fixtures/                 objetivos artificiales de prueba
│   ├── include/              archivo include para comprobar la compilación
│   ├── external/             BEAM independiente y fixtures P1-01 de fallos nativos
│   ├── hit_count/            objetivos para pruebas y benchmarks de conteo
│   └── performance/          parser y objetivo disperso para benchmarks
├── examples/                 ejemplos de uso independientes
│   ├── automatic/            campaña aleatoria con cobertura automática
│   ├── simple_parser/        parser ordinario y harness mínimo
│   ├── staged/               campaña por etapas, diccionario y replay de fallos
│   │   └── corpus/           cinco semillas sin procesar para la guía rápida
│   └── cowboy/               integración con Cowboy/Cowlib externos
├── bench/                    controladores de medición, perfilado e informes
├── docs/                     arquitectura y contratos de subsistemas
│   ├── adr/                  decisiones de arquitectura
│   ├── diagrams/             fuentes UML Mermaid y SVG renderizados
│   ├── examples/             pareja guardada de entrada de fallo + receta
│   ├── performance/          resultados de mediciones registrados
│   ├── coverage-audit-2026-09-15/  objetivos diagnósticos y evidencias de auditoría de sondas
│   └── audit-2026-09-12/     diagnósticos históricos y sus resultados
├── _build/                   compilaciones, datos de prueba y registros generados
└── .git/                     estado interno de Git
```

| Archivo | Responsabilidad | Contenido y uso |
|---|---|---|
| [.gitignore](../../../.gitignore) | Exclusiones de Git | Excluye `_build`, BEAM, PLT, registros, volcados de fallos, cookies de Erlang y archivos del editor. Son reglas de seguimiento de archivos, no configuración de campañas de fuzzing. |
| [LICENSE](../../../LICENSE) | Licencia del proyecto | Texto de Apache License 2.0; coincide con el identificador de licencia de `efz.app.src`. |
| [README.md](README.md) | Entrada principal a la documentación | Compilación, lanzador, harness, instrumentación, mutación por etapas, replay y enlaces a contratos detallados. |
| [rebar.config](../../../rebar.config) | Compilación y comprobaciones de Rebar3 | Requiere OTP 27 o posterior, `debug_info`, advertencias como errores, EUnit, Xref y Dialyzer. `src_dirs` incluye `src` y `examples/simple_parser`; el pre-hook de Linux compila `c_src/efz_vm_launcher`. No hay dependencias Erlang externas. |
| [rebar.lock](../../../rebar.lock) | Fijación de dependencias | Actualmente contiene `[]`: no hay dependencias Rebar externas fijadas. Rebar3 gestiona este archivo. |

<a id="src"></a>
## src — ejecución y compilación de instrumentación

El directorio [src/](../../../src) contiene **35 archivos** de la aplicación principal. Un archivo de módulo
no implica necesariamente un proceso independiente: los módulos `gen_server` se indican explícitamente;
los auxiliares de mutación, feedback, recetas y sistema de archivos se llaman como funciones ordinarias.

### Inicio, configuración y control de campañas

| Archivo | Responsabilidad | Funcionalidad implementada y papel durante la ejecución |
|---|---|---|
| [efz.app.src](../../../src/efz.app.src) | Descriptor de aplicación OTP | Nombre y versión de la aplicación, callback `efz_app`, servicios registrados y dependencias `kernel`, `stdlib`, `crypto`. Rebar3 genera `efz.app` a partir de él. |
| [efz.erl](../../../src/efz.erl) | API pública de Erlang | `start/1` inicia la aplicación y la campaña; `await/1` espera el informe, `stats/0` lee estadísticas y `stop/0` detiene la campaña y la aplicación. |
| [efz_app.erl](../../../src/efz_app.erl) | Ciclo de vida de la aplicación OTP | El callback `start/2` crea `efz_sup`; `stop/1` finaliza el callback de la aplicación. No contiene un bucle de mutación. |
| [efz_sup.erl](../../../src/efz_sup.erl) | Supervisor raíz | Comienza con una lista vacía de hijos; `efz:start/1` añade un `efz_fuzzer` temporal. La estrategia `one_for_all`, con intensidad de reinicios cero, no recupera el estado de la campaña. |
| [efz_cli.erl](../../../src/efz_cli.erl) | Lanzador universal | `main/1` analiza opciones, lee semillas sin procesar con límites, comprueba rutas y artefactos, llama a `efz:start/1`, guarda `report.term` y devuelve un código de salida. No tiene motor de fuzzing propio. |
| [efz_external.erl](../../../src/efz_external.erl) | Frontera de CLI supervisada | Antes de buscar el objetivo, inicia un controlador basado solo en archivos mediante `spawn_executable`, pasa un argv explícito y gestiona el ACK de muerte del padre. Devuelve un error claro fuera de Linux. |
| [efz_external_worker.erl](../../../src/efz_external_worker.erl) | Entrada del worker y barrera obligatoria | Solo se ejecuta en la BEAM hija: verifica la identidad, inicia la CLI/campaña ordinaria e implementa un protocolo HELLO/READY/PREPARE/RUN/RESULT con límites. El executor heredado llama directamente al closure. |
| [efz_config.erl](../../../src/efz_config.erl) | Esquema estricto de campaña | `prepare/1` comprueba claves conocidas, `run/1`, workers, límites, configuración de mutación y artefactos de cobertura; restaura el corpus persistente y produce una configuración normalizada. No admite `function` ni `arity`. |
| [efz_fuzzer.erl](../../../src/efz_fuzzer.erl) | Coordinador de campaña, `gen_server` | Crea procesos enlazados para corpus, estadísticas y supervisor del worker; monitoriza el worker, atiende `await`, reúne el informe final y detiene los servicios. El executor procesa entradas individuales. |
| [efz_worker_sup.erl](../../../src/efz_worker_sup.erl) | Supervisión del worker | Crea un único `efz_worker` temporal bajo `one_for_one`. El nombre no implica un pool paralelo implementado: el esquema de campaña solo permite `workers => 1`. |
| [efz_worker.erl](../../../src/efz_worker.erl) | Bucle principal de fuzzing, `gen_server` | Calibración de todas las semillas → planificación → mutación → executor → feedback → almacenamiento de corpus/fallos. Posee la cobertura global, cursores/RNG por etapas, grupos/contadores de fallos y representantes limitados, traza de mutación y decisiones; gestiona errores de infraestructura. |
| [efz_stats.erl](../../../src/efz_stats.erl) | Contadores, `gen_server` | `inc/1`, `failure/1` y `get/0` gestionan ejecuciones, calibraciones, descubrimientos, rechazos, ocurrencias/grupos de fallos, timeouts y errores de infraestructura; la primera causa de infraestructura se guarda por separado. Los contadores específicos de mutación pertenecen al planificador/worker. |

### Harness, entrada y ejecución

| Archivo | Responsabilidad | Funcionalidad implementada y papel durante la ejecución |
|---|---|---|
| [efz_target.erl](../../../src/efz_target.erl) | Contrato del harness | Behaviour con callback `run(binary()) -> term()`. El módulo del usuario implementa el callback; la configuración comprueba la exportación. También ofrece `spawn/1`, `spawn_link/1` para descendientes controlados y `dirty/1` para declarar efectos externos. |
| [efz_input.erl](../../../src/efz_input.erl) | Límite común del tamaño de entrada | `check/3` verifica el binario y el límite inclusivo; `read_file/3` limita la lectura de archivos. Valor predeterminado 4096, límite permitido 0..1048576; no trunca bytes. Se usa en ingesta, corpus, executor, mutaciones, replay y almacenamiento de fallos. |
| [efz_executor.erl](../../../src/efz_executor.erl) | Ejecución de una entrada | `run/4` cruza primero la barrera externa si está registrado el broker supervisado y después crea el guardian existente. Retorna tras el resultado final de limpieza y el DOWN del guardian; perder el guardian marca la VM como contaminada. `run/3` es un wrapper de compatibilidad. |
| [efz_guardian.erl](../../../src/efz_guardian.erl) | Propiedad del ciclo de vida | Posee la raíz/descendientes controlados, puertas de inicio, monitores, ETS de observación y barreras de traza. Limpia con independencia del caller/coordinador, verifica violaciones de estado compartido e impide reutilizar una VM contaminada. |

### Cobertura: compilación, hooks de ejecución y feedback

| Archivo | Responsabilidad | Funcionalidad implementada y papel durante la ejecución |
|---|---|---|
| [efz_instrument.erl](../../../src/efz_instrument.erl) | Compilación y carga de artefactos instrumentados | `compile/2` compila las fuentes seleccionadas en un outdir independiente; `discover/1`, `load/1` y `preflight/1` localizan y verifican BEAM/sidecar, identidad de compilación y código cargado. Se ejecuta antes de la campaña, no en cada mutación. |
| [efz_instrument_pt.erl](../../../src/efz_instrument_pt.erl) | `parse_transform` del compilador | Recorre el AST de Erlang, inserta sondas de cláusula/resultado y crea el ID de compilación y el manifiesto fuente. Comprueba la lista permitida, instrumentación repetida y sintaxis no admitida; el modo estricto rechaza cobertura incompleta. |
| [efz_cov_manifest.erl](../../../src/efz_cov_manifest.erl) | Manifiesto y espacio de cobertura permitido | Valida esquema e identidades de sondas, extrae el manifiesto incorporado y relaciona las sondas observadas con las compilaciones. `prepare/2` crea un plan reutilizable de validación con ETS protegida; `release/1` lo libera. |
| [efz_cov_integrity.erl](../../../src/efz_cov_integrity.erl) | Integridad de observación de cobertura | Fija identidades del harness/compilaciones cargadas, mantiene un registro protegido independiente de PID/contexto y trazas de contexto/carga de código, y distingue observación vacía válida de observación dañada. |
| [efz_cov_rt.erl](../../../src/efz_cov_rt.erl) | Hook de ejecución de sondas insertadas | `hit/1` contrasta el contexto con el registro PID. Presence usa un conjunto ETS; hit-count opcional usa un contador ETS atómico por identidad exacta. Los errores de contexto/tabla y el primer hit notifican al guardian. |
| [efz_cov_count.erl](../../../src/efz_cov_count.erl) | Características experimentales de conteo | Valida el snapshot de contadores y contrasta sus claves con la cobertura exacta; clasifica los conteos en ocho buckets. No posee proceso/tabla ni sustituye al backend de presencia. |
| [efz_cov.erl](../../../src/efz_cov.erl) | Contexto de cobertura de ejecución | `open`, `attach`, `snapshot`, `detach` y `close` gestionan la tabla de una ejecución. Incluye unión de conjuntos y auxiliares de compatibilidad manual `hit/1`, `reset_local/0`, `snapshot/0`, `interesting/2`; `efz_feedback` toma la decisión de ejecución. |
| [efz_feedback.erl](../../../src/efz_feedback.erl) | Novedad de cobertura | `evaluate/3` comprueba builds/status y calcula `Observed − Global`. Hit-count opcional también compara características exactas de buckets, distinguiendo `new_probe`/`new_hit_count`. Los fallos del objetivo no amplían el estado global. |

### Corpus y almacenamiento persistente

| Archivo | Responsabilidad | Funcionalidad implementada y papel durante la ejecución |
|---|---|---|
| [efz_corpus.erl](../../../src/efz_corpus.erl) | Corpus activo, `gen_server` | Posee entradas binarias, IDs enteros y metadatos. `add/2` deduplica descubrimientos y, con almacenamiento habilitado, los persiste antes de confirmar la inserción; `select/0` elige un padre aleatorio, `mutation_entries/0` entrega entradas al planificador por etapas. |
| [efz_corpus_store.erl](../../../src/efz_corpus_store.erl) | Corpus persistente reutilizable | `save/4` guarda la entrada exacta y metadatos con checksum bajo el hash SHA-256 del contenido. `restore/3,4` valida esquema, integridad, límite de entrada y política de compilación; devuelve entradas para una nueva calibración. No restaura cursores, RNG, cobertura ni IDs enteros anteriores. |
| [efz_crash.erl](../../../src/efz_crash.erl) | Identidad y artefactos de fallo | `identify/3` separa ID aleatorio de ocurrencia, hash del contenido y firma normalizada v2; `remember/3` mantiene conteos y representantes limitados. `save/4` almacena entrada sin procesar/Reason/receta/expectativa de los representantes seleccionados; cada ocurrencia confirmada se cuenta en el resumen persistente. Una receta defectuosa no impide guardar la entrada seleccionada. Devuelve errores estructurados con identidades y causa primaria. |
| [efz_crash_store.erl](../../../src/efz_crash_store.erl) | Almacén de fallos en disco con límite | Primeras N entradas distintas por firma, artefactos inmutables y resumen EFZG con conteo persistente. Un bloqueo exclusivo de directorio impide escritores simultáneos desde distintas VMs; el límite sobrevive al reinicio. El estado corrupto/no indexado/interrumpido genera un error explícito. |
| [efz_fs.erl](../../../src/efz_fs.erl) | Primitivas compartidas del sistema de archivos | Lecturas acotadas, creación de directorios, write/sync/close, `atomic_file/2` y `atomic_group/3`. Staging temporal + rename publica los datos; el manifiesto de grupo valida la integridad. Los errores contienen operación/ruta/motivo; la limpieza secundaria no reemplaza el fallo primario. |

### Mutación y replay

| Archivo | Responsabilidad | Funcionalidad implementada y papel durante la ejecución |
|---|---|---|
| [efz_mutator.erl](../../../src/efz_mutator.erl) | Contrato de callback del mutador | Behaviour `mutate(binary(), map()) -> binary()` para la vía aleatoria/callback. El worker llama al motor por etapas mediante una API de planificación separada. |
| [efz_mutator_random.erl](../../../src/efz_mutator_random.erl) | Mutador aleatorio incorporado | Flip, sobrescritura, inserción y borrado con límite de tamaño; admite RNG con semilla. Es la API Erlang predeterminada activa, no código muerto. Si la entrada está llena, elige una operación permitida sin generar bytes sobredimensionados. |
| [efz_mutation_plan.erl](../../../src/efz_mutation_plan.erl) | Planificador diferido por etapas | `prepare/2`, `new/1` y `next/2` mantienen cursores de padre/etapa, RNG, donantes, omisiones y protección de progreso; generan un candidato cada vez. Incorpora el corpus creciente y distingue agotamiento real de parada por inactividad; no materializa todo el espacio de mutaciones. |
| [efz_mutation.erl](../../../src/efz_mutation.erl) | Operaciones deterministas sobre bytes | Aplica operaciones concretas flip/integer/block/dictionary/splice, valida offsets y límites y devuelve bytes, skip o error. Lo usan el planificador y el replay de recetas; no toma decisiones aleatorias propias. |
| [efz_dictionary.erl](../../../src/efz_dictionary.erl) | Ingesta de diccionario | `normalize/2` valida, ordena y deduplica tokens binarios y calcula la identidad; `load/2` lee con límites un archivo hexadecimal con comentarios. Es el formato propio de EFZ, no un parser de expresiones Erlang ni de diccionarios AFL. |
| [efz_recipe.erl](../../../src/efz_recipe.erl) | Procedencia exacta de mutación y replay | `make/4` registra bytes y hashes primarios/donantes, padre, operaciones, límites y compilaciones. Encode/decode/load/save gestionan el sobre EFZR; regenerate reconstruye bytes, execute/execute_file los ejecuta mediante el executor con objetivo/compilaciones explícitos e identidad esperada obligatoria del harness. |
| [efz_replay.erl](../../../src/efz_replay.erl) | Replay de ejecución verificado | Codec de expectativas EFZX, identidad portátil del harness, validación del hash de entrada, conjunto completo de compilaciones y harness; raw/receta se ejecutan en el executor existente, y la firma determina reproduced/not-reproduced. |
| [efz_replay_cli.erl](../../../src/efz_replay_cli.erl) | CLI de replay | Analiza `--input/--recipe`, objetivo/artefactos/rutas/expectativa explícitos; imprime el veredicto y distingue códigos de salida 0/3/2/1. Conserva el modo antiguo de solo regeneración de bytes. |

<a id="scripts"></a>
## scripts — comandos de usuario

El directorio [scripts/](../../../scripts) contiene **4 escripts**. El lanzador y el replay localizan
EFZ compilado respecto de sus propias rutas; el benchmark de cobertura está pensado
para ejecutarse desde la raíz del repositorio. `prepare.escript` compila por sí mismo; los demás
scripts requieren que la compilación ya se haya completado.

| Archivo | Responsabilidad | Comportamiento al ejecutarse |
|---|---|---|
| [fuzz.escript](../../../scripts/fuzz.escript) | Comando universal de fuzzing | Localiza el ebin de la aplicación, carga `efz_cli`, pasa argumentos a `main/1` y termina la VM con su código de salida. Imprime un error claro si no existe compilación. |
| [prepare.escript](../../../scripts/prepare.escript) | Compilación y preparación inicial | Comprueba OTP/Rebar3, compila EFZ, instrumenta el parser por etapas y copia el corpus sin procesar sin sobrescribir semillas diferentes; imprime un comando para la CLI común. No inicia la campaña. |
| [replay.escript](../../../scripts/replay.escript) | Wrapper fino de la CLI de replay | Añade el ebin de EFZ compilado relativo al script y llama a `efz_replay_cli:main/1`; ni la receta ni un artefacto diagnóstico eligen el objetivo. |
| [coverage_bench.escript](../../../scripts/coverage_bench.escript) | Microbenchmark original de cobertura | Compara el objetivo ordinario, hooks instrumentados inactivos y hooks ETS activos en `efz_bench_fixture`; guarda muestras, memoria y tiempos de compilación en `_build/coverage-benchmark.*`. No es un lanzador. |

<a id="test"></a>
## test — comprobaciones automatizadas

El directorio [test/](../../../test) contiene **21 archivos**. `*_tests.erl` se ejecuta mediante
`rebar3 eunit`; `efz_coverage_SUITE.erl`, mediante `rebar3 ct`. Los auxiliares con `run/1`
dentro de las pruebas actúan como harness de prueba; exportarlos no los convierte en servicios de ejecución.

| Archivo | Funcionalidad comprobada | Distinción / escenario principal |
|---|---|---|
| [efz_config_tests.erl](../../../test/efz_config_tests.erl) | Esquema estricto y contrato del objetivo | Claves desconocidas, valores inválidos, ausencia de `run/1`, corpus vacío y capacidad de iniciar desde entradas persistentes. |
| [efz_cli_tests.erl](../../../test/efz_cli_tests.erl) | Lanzador en VMs Erlang nuevas | Harness externo, semillas sin procesar, etapas/aleatorio, corpus persistente, ayuda, módulos/rutas/artefactos/opciones inválidos, límites de entrada, fallos, timeouts y códigos de salida por errores de infraestructura. |
| [efz_crash_tests.erl](../../../test/efz_crash_tests.erl) | Ocurrencias, firmas y replay verificado | Entradas distintas con la misma firma, política de Reason, reubicación, 1000 ocurrencias con informe acotado, raw/receta en VMs nuevas, incompatibilidad de compilación/harness, artefactos corruptos/ilegibles, fallo primario de coordinador/worker y estadísticas. |
| [efz_crash_retention_tests.erl](../../../test/efz_crash_retention_tests.erl) | Retención en disco y fallo tardío del guardian | Comprueba límite de disco/duplicados/Reason original, dos campañas en distintas VMs, replay de entrada retenida, resumen corrupto, commit fallido y escritor concurrente/interrumpido. Una puerta AST de prueba tras la respuesta real del guardian demuestra preservación del fallo primario en informe/estadísticas e impide reutilización. |
| [efz_integrity_tests.erl](../../../test/efz_integrity_tests.erl) | Integridad de cobertura | 22 escenarios de regresión: cero hits/desconectado/no usado, política estricta, corrupción de diccionario/ETS, hooks capturados, hijo, recarga/restauración, fijación del harness, plan preparado y carga directa de ERTS. |
| [efz_isolation_tests.erl](../../../test/efz_isolation_tests.erl) | Guardian y descendientes controlados | Ciclo de vida raíz/hijo/anidado, timeout/trap_exit, muerte de caller/coordinador, registros/ETS, políticas de VM contaminada en VMs nuevas, pérdida del guardian e impedimento de reutilización. |
| [efz_executor_tests.erl](../../../test/efz_executor_tests.erl) | Contrato básico de ejecución | Comprobaciones breves de `run/3`: retorno, error, exit y timeout. Es una vía de compatibilidad; otras suites comprueban la cobertura automática con mayor detalle. |
| [efz_phase2_tests.erl](../../../test/efz_phase2_tests.erl) | Instrumentación automática y executor | Compara semántica ordinaria/instrumentada, tipos de sonda, manifiestos/IDs de compilación, includes/opciones, llamadas de cola, sintaxis estricta, contextos, cobertura ante crash/kill/timeout y cancelación de campaña. |
| [efz_backend_tests.erl](../../../test/efz_backend_tests.erl) | Equivalencia de variantes de cobertura | Compara `ets`/`ets_member` y validación preparada/por ejecución: sondas exactas, resultados, novedad, duración del plan, fallos del backend, muerte del caller y limpieza. |
| [efz_hit_count_tests.erl](../../../test/efz_hit_count_tests.erl) | Integración del feedback de conteo | Todos los buckets, multiplicidad/namespace, delta multisonda, hijos controlados, contadores con crash/timeout/corrupción, independencia de mutación, reutilización real de padres por etapas, restauración persistente y replay de fallos en VMs nuevas. |
| [efz_coverage_SUITE.erl](../../../test/efz_coverage_SUITE.erl) | Integración de Common Test | Tres escenarios: campaña automática, cobertura ante fallo y ante timeout. La campaña usa un fixture guionizado; la prueba de reutilización real de padres en varios pasos está en una prueba separada del bucle de feedback. |
| [efz_mutator_tests.erl](../../../test/efz_mutator_tests.erl) | Mutador aleatorio básico | Comprueba el binario devuelto para entradas primarias vacías y no vacías. `efz_limits_tests` comprueba el límite común de campaña. |
| [efz_mutation_tests.erl](../../../test/efz_mutation_tests.erl) | Operadores de bytes y planificador por etapas | Modelos de operación, diccionario, límites, enumeración, equidad, agotamiento finito, RNG, corpus creciente, donantes y protección de progreso. Incluye una regresión con 256 semillas y primera vía de diccionario no disponible. |
| [efz_phase3_tests.erl](../../../test/efz_phase3_tests.erl) | Ejecución por etapas y replay de fallos | Descubrimientos reales mediante operadores, persistencia de recetas, continuación tras fallo, independencia de traza, replay en VM nueva e incompatibilidad de compilación. Una regresión de campaña demuestra ejecución tras omitir una vía de diccionario y motivos de parada distinguibles. |
| [efz_feedback_loop_tests.erl](../../../test/efz_feedback_loop_tests.erl) | Cierre del bucle de feedback | Mutaciones reales de diccionario `<<>> → A → AB → ABC`; comprueba IDs/padre del corpus, entrega exacta al harness por referencia de ejecución, hash/bytes primarios y replay en una VM nueva. No usa mutador guionizado. |
| [efz_recipe_tests.erl](../../../test/efz_recipe_tests.erl) | EFZR y reconstrucción determinista | Todas las operaciones, corrupción de recetas, validación de esquema/hash/límite, regeneración en VM nueva y límites de tamaño al invocar el script de replay. |
| [efz_corpus_store_tests.erl](../../../test/efz_corpus_store_tests.erl) | Almacén persistente e integridad | Roundtrip, duplicados, forma/hash/esquema de metadatos, archivos ausentes/truncados, política de compilación y escritura interrumpida. Verifica que un fallo de persistencia no añade una entrada sin confirmar a la cola activa. |
| [efz_durable_tests.erl](../../../test/efz_durable_tests.erl) | Reutilización del corpus tras reiniciar VM | Varias VMs separadas: el descubrimiento `A` se persiste, se restaura, se calibra y pasa a ser padre de `AB` con un nuevo ID de cola. Comprueba también duplicados, incompatibilidad de compilación y límite de entrada. |
| [efz_limits_tests.erl](../../../test/efz_limits_tests.erl) | Límite común de entrada y fallos de almacenamiento | Límites 0/max/max+1, aleatorio/etapas/restauración/replay/executor/fallo; rechazo de callback con resultado sobredimensionado; errores de sistema de archivos, rollback, grupos corruptos y staging interrumpido. Comprueba entrada exacta y motivo primario en el informe cuando falla la escritura. |
| [efz_smoke_tests.erl](../../../test/efz_smoke_tests.erl) | Ciclo mínimo de campaña | Diez ejecuciones aleatorias en modo manual explícito y parada correcta. No demuestra cobertura automática ni expansión real del corpus. |
| [efz_scripted_mutator.erl](../../../test/efz_scripted_mutator.erl) | Fixture de secuencia fija | El callback devuelve bytes predeterminados por iteración para aceptación de Phase 2/backend/CT. Solo lo usan pruebas; no es mutador de producción ni prueba de planificación por etapas. |
| [efz_external_tests.erl](../../../test/efz_external_tests.erl) | Puerta de compatibilidad heredada | Demuestra que la ausencia de broker externo no cambia la vía de retorno del executor, cuarentena ni disponibilidad. |
| [external_supervisor_test.py](../../../test/external_supervisor_test.py) | Aceptación nativa P1-01 | VMs BEAM secundarias y NIF reales: puerta persistente, recuperación/replay de SIGSEGV/SIGABRT, timeout duro, reciclado de VM contaminada, corrupción de protocolo, fallos de almacenamiento, presupuesto de reinicios y limpieza por muerte del padre. |
| [external_bench.py](../../../test/external_bench.py) | Comparación heredado/supervisado | Tres ejecuciones alternas del mismo objetivo seguro; mide por separado rendimiento de mutaciones/total y preparación persistente sin desactivar fsync. |

<a id="fixtures"></a>
## fixtures — objetivos y datos de prueba

El directorio [fixtures/](../../../fixtures) contiene **23 archivos incluidos los subdirectorios**.
Son objetivos artificiales que tests/bench compilan con el compilador ordinario o
mediante `efz_instrument`. No forman parte del `src_dirs` principal de la aplicación.

| Archivo | Responsabilidad | Funcionalidad y consumidor |
|---|---|---|
| [efz_fixture.erl](../../../fixtures/efz_fixture.erl) | Amplia sintaxis Erlang para instrumentación | Cláusulas/guards, case/if, fun, try/catch/after, receive, binarios, records, macros y recursión de cola. La sincronización con el observador permite probar kill/timeout tras una sonda real. Las pruebas de bajo nivel pasan términos Erlang. |
| [efz_fixture_helper.erl](../../../fixtures/efz_fixture_helper.erl) | Llamada entre módulos del objetivo | `classify/1` distingue zero/other; se llama desde `efz_fixture` para comprobar instrumentación de varios módulos seleccionados. |
| [efz_skipped.erl](../../../fixtures/efz_skipped.erl) | Límites de sintaxis admitida | Comprensiones de listas/binarios/mapas y expresión `maybe` comprueban rechazo estricto y preservación semántica con limitaciones en `strict => false`. |
| [efz_record_default.erl](../../../fixtures/efz_record_default.erl) | Expresión en valor predeterminado de record | El valor depende del diccionario del proceso mediante `case`; Phase 2 verifica diagnósticos de posición no admitida de expresión y equivalencia ordinaria/instrumentada en modo no estricto. |
| [efz_bench_fixture.erl](../../../fixtures/efz_bench_fixture.erl) | Sondas repetidas con frecuencia | Bucle numérico de recursión de cola con pequeña rama sobre `N band 3`. Los benchmarks de cobertura/rendimiento miden sobrecoste por hits repetidos. |
| [efz_cli_harness.erl](../../../fixtures/efz_cli_harness.erl) | Harness externo mínimo | `run/1` acepta un binario y llama a `efz_cli_parser:parse/1`; las pruebas CLI compilan el harness separado del parser instrumentado. |
| [efz_cli_parser.erl](../../../fixtures/efz_cli_parser.erl) | Objetivo de pruebas CLI | Distingue binarios que empiezan con byte 128 de otras entradas; invertir el primer bit produce cobertura nueva alcanzable. Exporta `parse/1`, por lo que comprueba también el error de ausencia de `run/1`. |
| [efz_lineage_parser.erl](../../../fixtures/efz_lineage_parser.erl) | Objetivo de regresión de reutilización de padres | `parse/1` ordinario con cláusulas separadas para `A`, `AB`, `ABC` y fallback. El compilador añade hooks; lo usan pruebas del bucle de feedback y persistencia. |
| [efz_durable_harness.erl](../../../fixtures/efz_durable_harness.erl) | Harness para varias VMs | `run(binary())` estable llama al parser de linaje; demuestra restauración y reutilización de padres independientemente del proceso de prueba de la VM anterior. |
| [efz_integrity_target.erl](../../../fixtures/efz_integrity_target.erl) | Objetivo instrumentado de pruebas de integridad | Cláusulas A/B reales y compilación alternativa; binarios sin coincidencia no entran en el cuerpo de sonda. |
| [efz_integrity_harness.erl](../../../fixtures/efz_integrity_harness.erl) | Harness ordinario de pruebas de integridad | Casos binarios de desconexión/cero hits, corrupción de contexto, hook capturado, contexto de hijo, recarga sincronizada y compilación alternativa separada del harness. |
| [efz_isolation_target.erl](../../../fixtures/efz_isolation_target.erl) | Objetivo de aislamiento de ejecución | Escenarios binarios con hijos reales enlazados/no enlazados/anidados, timeout, registros/ETS y mutaciones globales de VM. Se compila con instrumentación automática para la suite de aislamiento. |
| [efz_limits_target.erl](../../../fixtures/efz_limits_target.erl) | Entrega exacta y fallo artificial | Envía el binario recibido a un observador registrado, lo devuelve o lanza error para `CRASH`. Se usa para límites y preservación de entrada causante ante fallo de E/S. |
| [efz_crash_target.erl](../../../fixtures/efz_crash_target.erl) | Fixture de fallo de parser instrumentado | Devuelve ok para `OK`, espera con `WAIT` y, en otro caso, falla con Reason dependiente de datos. Una macro crea una compilación incompatible; reubicar fuentes comprueba normalización de firmas. |
| [efz_crash_harness.erl](../../../fixtures/efz_crash_harness.erl) | Harness binario externo ordinario | Llama al parser real. Una macro cambia identidad del harness; el entorno solo de pruebas selecciona retorno normal, otro error o fallo de infraestructura en una VM nueva de replay. |

### fixtures/external

`efz_external_target` y `efz_external_startup` definen las vías SAFE, contaminada, timeout,
salida ordinaria e inicio. `efz_native_fixture` es un NIF solo de pruebas con
SIGSEGV, SIGABRT y bloqueos controlados; solo se carga en la VM hija de aceptación.

### fixtures/include

El directorio [fixtures/include/](../../../fixtures/include) prueba resolución de rutas include
y preprocesamiento al compilar un objetivo instrumentado.

| Archivo | Finalidad y funcionalidad |
|---|---|
| [efz_fixture.hrl](../../../fixtures/include/efz_fixture.hrl) | Macro `INCLUDED` con `case` y record `item`. La macro usa `MAGIC`, suministrado por opción del compilador; prueba preservación de ubicaciones fuente y comportamiento del código expandido. |

### fixtures/hit_count

Cinco objetivos/auxiliares ordinarios para comprobar multiplicidad de llamadas y comparar
feedback de forma controlada. La prueba/benchmark elige explícitamente el alcance instrumentado.

| Archivo | Finalidad |
|---|---|
| [efz_count_sites.erl](../../../fixtures/hit_count/efz_count_sites.erl) | Tres funciones x/a/b; el compilador añade una sonda a cada una. Separa multiplicidad de hits de sondas de despacho/control del bucle. |
| [efz_count_harness.erl](../../../fixtures/hit_count/efz_count_harness.erl) | Adaptador binario no instrumentado para conteos L, pares de sondas, hijos controlados, crash/timeout y corrupción de contador de prueba. |
| [efz_count_repeat.erl](../../../fixtures/hit_count/efz_count_repeat.erl) | Prefijo de bytes idénticos; cláusula profunda separada al llegar a 16 repeticiones. |
| [efz_count_records.erl](../../../fixtures/hit_count/efz_count_records.erl) | Parser de records cortos completos; cláusula profunda a los ocho records. |
| [efz_count_machine.erl](../../../fixtures/hit_count/efz_count_machine.erl) | Máquina de estados con tick/ack repetido y commit tras ocho transiciones. |

### fixtures/performance

El directorio [fixtures/performance/](../../../fixtures/performance) contiene cargas reproducibles
de benchmark que no requieren aplicaciones de terceros.

| Archivo | Finalidad y funcionalidad |
|---|---|
| [efz_perf_parser.erl](../../../fixtures/performance/efz_perf_parser.erl) | Parser artificial de records binarios: campos numéricos, flags, payload de longitud variable, records truncados/inválidos y error artificial. Aporta carga mixta para benchmarks de executor/campaña. |
| [efz_perf_sparse.erl](../../../fixtures/performance/efz_perf_sparse.erl) | Fuente generada conservada en el proyecto: 2048 cláusulas `choose/1` y fallback. Un manifiesto grande con pocas sondas alcanzadas mide coste de cobertura/validación dispersa; el generador está en `bench`. |

<a id="examples"></a>
## examples — integraciones de demostración

El directorio [examples/](../../../examples) contiene **15 archivos**. Sus campañas eligen
objetivos/semillas/opciones concretos para demostrar; el lanzador común para usuarios
es `scripts/fuzz.escript`.

### examples/simple_parser

El directorio [examples/simple_parser/](../../../examples/simple_parser) es una pareja mínima:
objetivo ordinario + harness. Es el único ejemplo incluido en `src_dirs` de Rebar3,
por lo que ambos módulos están disponibles tras una compilación ordinaria de EFZ.

| Archivo | Finalidad y funcionalidad |
|---|---|
| [efz_example_parser.erl](../../../examples/simple_parser/efz_example_parser.erl) | Clasifica entrada vacía, prefijos binarios y texto; falla deliberadamente con prefijo `255`. No contiene llamadas a EFZ. `run/1` mantiene compatibilidad; la entrada principal es `classify/1`. |
| [efz_example_target.erl](../../../examples/simple_parser/efz_example_target.erl) | Harness con behaviour `efz_target`: `run/1` pasa la entrada a `efz_example_parser:classify/1`. Se usa en ejemplos shell, smoke tests y aceptación de cobertura automática. |

### examples/automatic

El directorio [examples/automatic/](../../../examples/automatic) demuestra cobertura automática
con la vía existente de mutación aleatoria.

| Archivo | Finalidad y funcionalidad |
|---|---|
| [run.escript](../../../examples/automatic/run.escript) | Instrumenta el parser sencillo, ejecuta 500 mutaciones aleatorias desde `<<0>>`, guarda `_build/example-report.term` y fallos, y detiene EFZ. Se ejecuta desde la raíz tras compilar. |

### examples/staged

El directorio [examples/staged/](../../../examples/staged) demuestra operadores por etapas,
descubrimientos por diccionario y reproducción de un fallo real.

| Archivo | Finalidad y funcionalidad |
|---|---|
| [efz_staged_parser.erl](../../../examples/staged/efz_staged_parser.erl) | Distingue `TOKEN`, valores límite/aritméticos y entrada vacía; el prefijo `BOOM!` provoca un error artificial. Objetivo ordinario sin hooks manuales de cobertura. |
| [run.escript](../../../examples/staged/run.escript) | Instrumenta el parser, ejecuta 200 mutaciones por etapas, extrae una receta de fallo, comprueba regeneración exacta y otro fallo mediante executor; guarda informe/entrada/receta/expectativa de replay bajo `_build`. |
| [tokens.hex](../../../examples/staged/tokens.hex) | Dos líneas hexadecimales para los tokens binarios `TOKEN` y `BOOM!`, más un comentario. Lo lee el `efz_dictionary` estándar; son datos de la etapa de mutación. |

### examples/staged/corpus

Cinco archivos de semillas sin procesar para `scripts/prepare.escript` y el lanzador común.
La documentación queda fuera de este directorio para que la CLI no la interprete como semilla.

| Archivo | Finalidad y contenido exacto |
|---|---|
| [00-empty.seed](../../../examples/staged/corpus/00-empty.seed) | Binario vacío, 0 bytes; comprueba la vía de entrada vacía. |
| [01-zero.seed](../../../examples/staged/corpus/01-zero.seed) | Un byte cero, padre inicial para descubrimientos de límites/aritmética. |
| [02-near-token.seed](../../../examples/staged/corpus/02-near-token.seed) | `UOKEN` sin salto de línea; mutar el primer byte descubre la cláusula `TOKEN`. |
| [03-near-crash.seed](../../../examples/staged/corpus/03-near-crash.seed) | `COOM!` sin salto de línea; bitflip/aritmética del primer byte genera el fallo artificial `BOOM!`. |
| [04-binary.seed](../../../examples/staged/corpus/04-binary.seed) | Hex `00 ff 80 41 0d 0a`; ingesta binaria con NUL, bytes no UTF-8 y CR/LF. |

### examples/cowboy

El directorio [examples/cowboy/](../../../examples/cowboy) adapta un checkout externo
de Cowboy/Cowlib. No añade estas bibliotecas como dependencias de EFZ ni inicia un listener
HTTP: el objetivo analiza síncronamente una query string.

| Archivo | Finalidad y funcionalidad |
|---|---|
| [README.md](examples/cowboy/README.md) | Comandos de preparación, comprobación y ejecución con Cowboy externo; describe el alcance `parse_qs`, límites de instrumentación y resultados históricos de una compilación concreta. |
| [efz_cowboy_target.erl](../../../examples/cowboy/efz_cowboy_target.erl) | Entrega bytes de consulta sin procesar a `cowboy_req:parse_qs/1` mediante un mapa Req mínimo. Convierte `request_error` esperados para `qs`/`limit_reached` en retornos; las excepciones inesperadas siguen siendo fallos. |
| [efz_cowboy_checks.erl](../../../examples/cowboy/efz_cowboy_checks.erl) | Comprobaciones EUnit adicionales de decodificación porcentual, bytes binarios, repeticiones y número de claves; compara backends de cobertura y confirma descubrimiento por una mutación real de diccionario. El runner del ejemplo las invoca en modo `check`. |
| [run.escript](../../../examples/cowboy/run.escript) | Comprueba BEAM externos, compila el harness, instrumenta `cowboy_req` y `cow_qs`, y ejecuta comprobaciones o campaña por etapas. Usa instrumentación explícitamente no estricta para Cowboy y muestra limitaciones. |

<a id="bench"></a>
## bench — mediciones de rendimiento

El directorio [bench/](../../../bench) contiene **13 archivos** de infraestructura auxiliar
de medición. No se ejecutan durante el inicio normal de EFZ. Los resultados se guardan en
`_build`; las muestras históricas registradas están en `docs/performance`.

| Archivo | Responsabilidad | Funcionalidad implementada |
|---|---|---|
| [run.escript](../../../bench/run.escript) | Lanzador de benchmarks | Compila auxiliares locales `efz_perf*`, selecciona carga `hooks/executor/campaign/memory/startup` o `all` y variantes de backend/validación. Admite la ruta `EFZ_PERF_EBIN`. |
| [efz_perf.erl](../../../bench/efz_perf.erl) | Controlador principal de medición | Compila fixtures, verifica semántica, mide hooks/executor/campaña/inicio/memoria y guarda entorno y muestras. `canonical/1` normaliza resultados para comparar variantes. |
| [efz_perf_loop_target.erl](../../../bench/efz_perf_loop_target.erl) | Adaptador binario para bucle numérico | Convierte el primer byte en número de repeticiones de `efz_bench_fixture` y comprueba el checksum con una fórmula. Lo requiere el contrato binario del benchmark de campaña. |
| [efz_perf_replay.erl](../../../bench/efz_perf_replay.erl) | Flujo fijo de candidatos para benchmark | `install/1` coloca entradas tuple en `persistent_term`, `mutate/2` selecciona por iteración y `clear/0` limpia. Aísla el coste de mutación; no es replay EFZR ni planificador de producción. |
| [generate_sparse.escript](../../../bench/generate_sparse.escript) | Generador de fixture disperso | Escribe reproduciblemente `fixtures/performance/efz_perf_sparse.erl` con 2048 cláusulas numéricas. Modifica el archivo fuente; no es necesario antes de cada ejecución de fuzzing. |
| [profile.escript](../../../bench/profile.escript) | Perfilado con `eprof` | Compila objetivo de bucle/parser/disperso, precarga la vía de ejecución y perfila hooks o executor; admite validación preparada. El perfilado no se considera muestra de rendimiento. |
| [report.escript](../../../bench/report.escript) | Lectura de resultados de benchmark | Lee filas binarias locales `.term` de hooks/executor/campaña e imprime medianas, muestras originales, coste por operación y rendimiento. No repite la carga. |
| [archive.escript](../../../bench/archive.escript) | Archivo de evidencias de Phase 2.1 | Comprueba número de muestras, comparaciones canónicas, hashes de fuentes/BEAM/compilación y memoria/perfiles; produce un término Erlang textual compacto para documentación. Está pensado para la estructura histórica concreta de artefactos. |
| [mutations.escript](../../../bench/mutations.escript) | Benchmark de mutaciones por etapas | Mide entradas cortas/medias/máximas, diccionario, splice y havoc; verifica aplicación de operaciones. Compara campañas aleatorias/por etapas finitas y registra memoria, reducciones, entorno y hashes. |
| [hit_count.escript](../../../bench/hit_count.escript) | Lanzador del nuevo experimento | Ejecuta mediciones de almacenamiento/executor/campaña/aleatorio/bucles grandes y exporta muestras a JSON. |
| [efz_hit_count_micro.erl](../../../bench/efz_hit_count_micro.erl) | Microbenchmark de almacenamiento | Conjunto/contador ETS, contadores/atomics densos con mapeo exacto; 100–100000 sondas, hit/snapshot/reset/memoria/ciclo de vida y escritores concurrentes. |
| [efz_hit_count_experiment.erl](../../../bench/efz_hit_count_experiment.erl) | Comparación controlada de extremo a extremo | Campañas reales por etapas/aleatorias con iguales presupuestos/RNG, primera entrada profunda, crecimiento de corpus/solo conteo, sobrecoste de executor con entradas fijas y saturación. |
| [efz_count_bench_harness.erl](../../../bench/efz_count_bench_harness.erl) | Observación del resultado profundo | Llama al objetivo instrumentado elegido y envía la hora de `deep` al observador. No selecciona mutaciones ni recoge cobertura por sí mismo. |

<a id="docs"></a>
## docs — documentación, UML y archivos históricos

El directorio [docs/](../..) contiene **70 archivos incluidos los subdirectorios**. Los contratos
describen el uso de los subsistemas actuales. Los registros de auditoría/validación/rendimiento
capturan estado y resultados en su fecha; sus fallos, conteos y comandos antiguos
no son afirmaciones sobre el checkout actual.

### Documentos principales

| Archivo | Finalidad y contenido |
|---|---|
| [architecture.md](architecture.md) | Arquitectura actual: módulos, procesos, propietarios del estado, inicio, feedback, ejecución, cobertura, corpus, mutación, errores y fronteras de integración OTP. Incluye cuatro SVG UML. |
| [repository-map.md](repository-map.md) | Este mapa por archivos: finalidad de todos los directorios/archivos del proyecto, fronteras de ejecución/prueba/ejemplo, artefactos generados y lugares para modificar funcionalidades. |
| [cli.md](cli.md) | Lanzador universal, harness externo mínimo, artefactos de compilación, parámetros y esquema de mapa de campaña. |
| [execution-isolation.md](execution-isolation.md) | Contrato binario admitido del harness, protocolo guardian, API de spawn controlado, política de VM contaminada, fronteras de estado compartido y futuro backend de VM desechable. |
| [coverage-integrity.md](coverage-integrity.md) | Fijación de harness/compilaciones, evidencia independiente de observación, estados de contexto, sustitución de código, política diagnóstica/estricta de campaña y fronteras admitidas. |
| [coverage.md](coverage.md) | Contrato de cobertura automática de fuentes: sintaxis admitida, granularidad, identidades de manifiesto/compilación, APIs de compilación y ejecución, variantes de backend/validación y limitaciones. |
| [coverage-tracking-audit.md](coverage-tracking-audit.md) | Auditoría de representación exacta de sondas, duración de ejecución/feedback global, comparación con bitmap/contadores de AFL++ fijado, 15 secciones y resultados experimentales reales. |
| [hit-count-experiment.md](hit-count-experiment.md) | Contrato de feedback de conteo opcional, elección de contadores ETS tras benchmarks, resultados pareados de fuzzing, sobrecoste, crecimiento del corpus, compatibilidad y comandos de reproducción. |
| [quickstart.md](quickstart.md) | Preparación de compilación y corpus de prueba, comandos exactos de fuzz/replay/restauración, limitaciones actuales y prioridades antes de un uso más amplio. |
| [mutations.md](mutations.md) | Motor por etapas: valores predeterminados, formato de diccionario, enumeración diferida, progreso/agotamiento, operadores de bytes, havoc, procedencia y contabilidad. |
| [replay.md](replay.md) | Contrato de ocurrencia/firma/grupo de fallos, informe acotado, políticas de Reason, esquemas EFZR/EFZX, autoridad de los bytes originales, CLI/APIs de replay verificado, compatibilidad y evidencia de regresión. |
| [corpus.md](corpus.md) | Registros persistentes de corpus v1/v2: estructura por contenido, publicación atómica, procedencia de sondas/conteos, restauración, políticas de duplicados/compilación y diagnósticos de corrupción/parcialidad. Corpus reutilizable, no reanudación exacta. |
| [input-and-storage.md](input-and-storage.md) | `max_input_bytes` común, fronteras de replay/fallos, grupos atómicos de artefactos, errores de E/S estructurados y preservación de entrada causante en contexto de ejecución. |
| [calibration-readiness.md](calibration-readiness.md) | Auditoría del 9 de septiembre sobre prerrequisitos de calibración repetida/estabilidad de características. Analiza integridad de snapshots, terminación y estado entre casos e incluye scripts diagnósticos; el modelo propuesto no significa que la estabilidad esté implementada. |
| [phase2-validation.md](phase2-validation.md) | Finalización histórica de instrumentación automática: comandos, retención/continuación, cobertura tras terminar, baseline y limitaciones de Phase 2. |
| [phase2.1-performance.md](phase2.1-performance.md) | Metodología y resultados del trabajo de rendimiento: variantes ETS, validación preparada, costes de executor/campaña, memoria, perfiles y elección de valores predeterminados. |
| [phase3-validation.md](phase3-validation.md) | Validación histórica de mutación por etapas y replay: descubrimientos, fallos, costes medidos, memoria, comandos y fronteras de Phase 3. |
| [technical-audit-2026-09-12.md](technical-audit-2026-09-12.md) | Auditoría completa del 12 de septiembre: inventario de componentes, llamadas reales, matriz de integración, experimentos, errores, madurez y plan. Las carencias de planificador/CLI/persistencia/E/S detectadas deben compararse con el código actual y nuevas regresiones. |
| [p1-01-external-supervisor.md](p1-01-external-supervisor.md) | Contrato y evidencias de P1-01 | Frontera de proceso, protocolo/máquina de estados, diario persistente previo a ejecución, recuperación timeout/contaminación/nativa, replay, límites Linux y evidencias de regresión y benchmark. |

### docs/coverage-audit-2026-09-15

Fixtures diagnósticos reproducibles y evidencias de auditoría del seguimiento de cobertura.
No son instrumentación de producción ni un motor nuevo de fuzzing.

| Archivo | Finalidad y contenido |
|---|---|
| [efz_cov_audit_sites.erl](../../coverage-audit-2026-09-15/efz_cov_audit_sites.erl) | Cuatro funciones ordinarias a/b/c/x para instrumentación automática. Un contador diagnóstico local en x confirma llamadas reales sin participar en cobertura. |
| [efz_cov_audit_harness.erl](../../coverage-audit-2026-09-15/efz_cov_audit_harness.erl) | Despachador binario no instrumentado: A/B/AB/ABC, LOOP1…1000, crash/timeout/borrado de contexto e hijos controlados/nativos. Evita que sondas adicionales de despacho/bucle distorsionen la comparación semántica del conteo. |
| [run.escript](../../coverage-audit-2026-09-15/run.escript) | Compila fixtures, ejecuta ambos backends ETS reales y feedback/corpus/planificador, comprueba filas/limpieza/novedad; verifica hijos nativos en VM separada. Guarda registros originales en `_build`. |
| [results.txt](../../coverage-audit-2026-09-15/results.txt) | Snapshots/novedad/tamaños de corpus reales guardados, multiplicidad de llamadas, resultados de hijos y linaje de campaña real por etapas. |
| [validation.json](../../coverage-audit-2026-09-15/validation.json) | Revisiones de EFZ/AFL++, comandos y códigos de salida, conteos EUnit/CT y SHA-256 de fuentes de producción sin modificar. |

### docs/adr

El directorio [docs/adr/](../../adr) conserva decisiones de arquitectura: qué enfoque
se eligió y por qué. Cada baseline se refiere al momento de la decisión.

| Archivo | Finalidad y contenido |
|---|---|
| [0002-automatic-coverage.md](adr/0002-automatic-coverage.md) | ADR que elige sondas de cláusula/resultado fuente y ETS propiedad de ejecución. Compara parse transforms, cobertura OTP y reescritura de bajo nivel; registra contrato de aislamiento/feedback y alternativas. |

### docs/diagrams

El directorio [docs/diagrams/](../../diagrams) contiene **10 archivos UML**. Los `.mmd` son
fuentes Mermaid editables; los `.svg` son imágenes guardadas para consultar
sin renderizador Mermaid. Estos SVG se incluyen en el documento de arquitectura.

| Archivo | Finalidad y contenido |
|---|---|
| [README.md](diagrams/README.md) | Explica estereotipos UML de Erlang, significado de flechas y comandos locales para renderizar los cuatro diagramas. |
| [mermaid-config.json](../../diagrams/mermaid-config.json) | Tema, fuentes y ajustes de seguridad/diseño Mermaid compartidos; etiquetas HTML desactivadas para SVG portátiles. No está relacionado con configuración de campaña. |
| [modules.mmd](diagrams/modules.mmd) | Fuente UML estructural: módulos principales de ejecución y dependencias de la vía por etapas. |
| [modules.svg](diagrams/modules.svg) | Imagen renderizada de dependencias de módulos, generada desde `modules.mmd`. |
| [processes.mmd](diagrams/processes.mmd) | Fuente UML estructural: hijos del supervisor, links, monitores, worker/guardian/coordinador/objetivo/descendientes y propietarios ETS. |
| [processes.svg](diagrams/processes.svg) | Imagen renderizada de procesos y recursos desde `processes.mmd`. |
| [feedback-loop.mmd](diagrams/feedback-loop.mmd) | Fuente UML de secuencia: obtención de entradas del corpus, mutación diferida, ejecución, feedback y retención que pone un descubrimiento a disposición de mutaciones futuras. |
| [feedback-loop.svg](diagrams/feedback-loop.svg) | Imagen renderizada del bucle completo de feedback por etapas. |
| [executor.mmd](diagrams/executor.mmd) | Fuente UML de secuencia para una entrada: caller/guardian/coordinador/raíz/descendientes, puertas, hooks, DOWN/barreras, timeout y limpieza de ejecución contaminada. |
| [executor.svg](diagrams/executor.svg) | Protocolo de ejecución renderizado y resultados alternativos. |

### docs/examples

El directorio [docs/examples/](../../examples) guarda una pequeña pareja real de artefactos
para documentación de replay. Estos archivos son datos, no fuentes del objetivo.

| Archivo | Finalidad y contenido |
|---|---|
| [staged-crash.input](../../examples/staged-crash.input) | Binario exacto del ejemplo por etapas: seis bytes `<<"BOOM!", 0>>`. Puede compararse con la reconstrucción de receta; es entrada de un parser artificial que falla deliberadamente. |
| [staged-crash.recipe](../../examples/staged-crash.recipe) | Receta EFZR v1 de la misma entrada: primario, operaciones, hashes, límites y procedencia de compilación de la ejecución histórica. Regenerar bytes no requiere objetivo; ejecutarlos exige compilación compatible explícita. |

### docs/performance

El directorio [docs/performance/](../../performance) almacena **términos Erlang textuales**
con mediciones históricas y muestras JSON del nuevo experimento de conteo.
Aunque tengan extensión `.term`, estos términos no son ETF binario:
su contenido se destina a inspección o `file:consult/1`.

| Archivo | Finalidad y contenido |
|---|---|
| [phase2.1-samples.term](../../performance/phase2.1-samples.term) | Archivo de entorno, filas de muestras, comprobaciones canónicas de campaña, memoria, perfilado y hashes de fuentes/BEAM para el informe Phase 2.1. |
| [phase3-mutations.term](../../performance/phase3-mutations.term) | Mediciones de cargas de mutación y campañas aleatorias/por etapas, entorno, identidades de compilador/compilación, memoria/reducciones y hashes fuente. Base de tablas de rendimiento de Phase 3. |
| [phase3-validation.term](../../performance/phase3-validation.term) | Archivo de evidencia de aceptación de Phase 3: hashes fuente, resultados de campañas/comprobaciones y enlace al entorno de medición. Captura esa ejecución, no un informe actualizado automáticamente. |
| [hit-count-samples.json](../../performance/hit-count-samples.json) | Muestras originales de almacenamiento/executor, configuraciones/compilaciones y resultados de campañas pareadas, control aleatorio, bucles grandes, entorno y validación del prototipo nuevo. |

### docs/audit-2026-09-12

El directorio [docs/audit-2026-09-12/](../../audit-2026-09-12) contiene **30 archivos**
de diagnósticos y evidencias de la auditoría antigua. Los scripts conservan API/estructura antigua y
aserciones de defectos detectados: por ejemplo, límite anidado de mutación, `mutation_exhausted`
prematuro y archivos de fallo planos. **No son la suite de regresión
actual**; tras corregir errores, algunas aserciones/rutas son naturalmente incompatibles.
Las regresiones actuales están en `test/`.

| Archivo | Finalidad y contenido registrado |
|---|---|
| [audit_target.erl](../../audit-2026-09-12/audit_target.erl) | Parser artificial con vías `A`, `AB`, `ABC`, error para `CRASH` y fallback; fuente para instrumentación automática de auditoría. |
| [audit_harness.erl](../../audit-2026-09-12/audit_harness.erl) | Harness binario real: envía al observador los bytes exactos entregados y llama a `audit_target:parse/1`. |
| [audit_faults.erl](../../audit-2026-09-12/audit_faults.erl) | Objetivos diagnósticos de `persistent_term`, hijos creados/enlazados, timeout, muerte del coordinador, corrupción de contexto y clases de excepción. Crea escenarios de fallo controlados. |
| [run.escript](../../audit-2026-09-12/run.escript) | Controlador histórico: compila objetivos, ejecuta campaña de linaje y diagnósticos de fallo y escribe informes/snapshots en el directorio indicado. Requiere adaptar configuración antigua a la API actual. |
| [edge-cases.escript](../../audit-2026-09-12/edge-cases.escript) | Reproductor de agotamiento prematuro con 256 semillas, claves ignoradas silenciosamente y fallo al guardar crashes. Las aserciones describen defectos antiguos; el planificador corregido no debería satisfacerlas. |
| [fresh-replay.escript](../../audit-2026-09-12/fresh-replay.escript) | Comprobación histórica de reconstrucción de `CRASH` y ejecución en nueva VM. Busca los antiguos `crashes/*.recipe` planos; los artefactos actuales se almacenan en grupos. |
| [before-sha256.json](../../audit-2026-09-12/before-sha256.json) | Baseline de hashes previo a auditoría para demostrar fuentes sin cambios durante la investigación. |
| [status-before.txt](../../audit-2026-09-12/status-before.txt) | Snapshot de `git status` anterior a auditoría: modificaciones registradas e implementación no registrada. No describe el estado de Git actual. |
| [verification.json](../../audit-2026-09-12/verification.json) | Verificación de integridad de archivos originales y estructura/enlaces del informe final de auditoría. |
| [e2e-report.term](../../audit-2026-09-12/e2e-report.term) | Informe completo **ETF binario** de campaña de auditoría: corpus, cobertura, recetas/traza, decisiones y evidencia de fallos. A diferencia de `docs/performance/*.term`, no es texto para `file:consult/1`. |
| [e2e.txt](../../audit-2026-09-12/e2e.txt) | Extracto legible de linaje: IDs del corpus, ascendencia, conteos de entrega/regeneración y vía de fallo. La falta de restauración persistente se refiere a la implementación antigua. |
| [child.txt](../../audit-2026-09-12/child.txt) | Snapshot de hijo creado normalmente: raíz terminada, hijo vivo y sin contexto automático. |
| [linked_child.txt](../../audit-2026-09-12/linked_child.txt) | Snapshot de hijo enlazado tras retorno normal de raíz; muestra que un link por sí solo no garantiza terminar al hijo. |
| [child_timeout.txt](../../audit-2026-09-12/child_timeout.txt) | Snapshot tras timeout de raíz: un hijo separado no enlazado sigue vivo y no recibe automáticamente contexto de cobertura. |
| [coordinator_kill.txt](../../audit-2026-09-12/coordinator_kill.txt) | Muerte forzada del coordinador: resultado de infraestructura con objetivo aún vivo. Evidencia de la frontera de aislamiento de fallos. |
| [cross_case_state.txt](../../audit-2026-09-12/cross_case_state.txt) | Dos ejecuciones del mismo escenario lógico antes/después de escribir `persistent_term`; el estado global cambia resultado y cobertura. |
| [caught_malformed_context.txt](../../audit-2026-09-12/caught_malformed_context.txt) | El objetivo captura una excepción tras sustituir contexto del diccionario del proceso; el snapshot muestra pérdida de diagnósticos de contexto malformado. |
| [hot_reload.txt](../../audit-2026-09-12/hot_reload.txt) | Sustitución de código instrumentado por compilación ordinaria tras preflight: retorno correcto con cobertura vacía. Evidencia de dependencia del código cargado estable. |
| [disconnected_artifacts.txt](../../audit-2026-09-12/disconnected_artifacts.txt) | Campaña con artefactos que no proporcionan la vía requerida: ejecuciones/fallos sin descubrimientos ni cobertura. Artefactos válidos no prueban por sí solos que se alcance código instrumentado. |
| [exception_classes.txt](../../audit-2026-09-12/exception_classes.txt) | Compara clases/motivos como function_clause, badarg, throw y exit con resultados reales del executor y trazas de pila. |
| [duplicate_initial_seeds.txt](../../audit-2026-09-12/duplicate_initial_seeds.txt) | Ejecución histórica en memoria de dos semillas iniciales idénticas con IDs enteros diferentes y dos calibraciones. No es prueba de deduplicación persistente por contenido. |
| [random-example-summary.txt](../../audit-2026-09-12/random-example-summary.txt) | Resumen del ejemplo aleatorio: conteos de ejecuciones/descubrimientos/fallos y enlaces de padres en corpus ampliado. |
| [edge-cases.log](../../audit-2026-09-12/edge-cases.log) | Salida del reproductor: en ese checkout, 256 visitas inactivas produjeron 0 candidatos/ejecuciones; registra también diagnósticos antiguos de configuración/almacenamiento. |
| [fresh-replay.log](../../audit-2026-09-12/fresh-replay.log) | Confirmación del replay histórico en VM nueva: `CRASH`, 5 bytes, cobertura presente. |
| [staged-example.log](../../audit-2026-09-12/staged-example.log) | Conteos y resultado de replay del ejemplo independiente por etapas en el momento de auditoría. |
| [cowboy-check.log](../../audit-2026-09-12/cowboy-check.log) | **Fallo de lanzamiento** registrado: faltaba `cowboy_req.beam` externo. No es un resultado satisfactorio de pruebas Cowboy. |
| [eunit.log](../../audit-2026-09-12/eunit.log) | Salida de `rebar3 eunit` del checkout histórico; lista de pruebas y resultados de esa ejecución. |
| [ct.log](../../audit-2026-09-12/ct.log) | Salida de Common Test: tres escenarios de cobertura automática superados en el momento de auditoría. |
| [xref.log](../../audit-2026-09-12/xref.log) | Salida de análisis de referencias cruzadas del checkout antiguo. |
| [dialyzer.log](../../audit-2026-09-12/dialyzer.log) | Salida de Dialyzer y conteos de archivos PLT/proyecto usados entonces. |

<a id="generated"></a>
## Archivos generados e internos

### _build

`_build/` se excluye de Git. Contiene resultados de Rebar3, objetivos instrumentados,
artefactos de fallo/corpus y evidencias locales de validación. A diferencia de archivos
fuente, su contenido depende de comandos ejecutados. Por ejemplo, las pruebas en VM nueva crean
directorios con sufijos aleatorios; algunas pruebas los eliminan al terminar.

| Directorio / familia de rutas | Finalidad y contenido |
|---|---|
| `_build/default/lib/efz/` | Compilación de perfil ordinario: `ebin/*.beam`, `ebin/efz.app`, caché del compilador y enlaces a fuentes. El lanzador usa este ebin. |
| `_build/test/lib/efz/` | Compilación de perfil de prueba y módulos de prueba compilados; no reemplaza el ebin predeterminado de la CLI universal. |
| `_build/test/logs/` | Ejecuciones Common Test: informes HTML, registros de suite, resúmenes y CSS/JS para consulta local. |
| `_build/plt/`, `_build/default/*plt`, `*.dialyzer_warnings` | PLT base y del proyecto de Dialyzer y salida diagnóstica del análisis. Caché de análisis de tipos, no corpus de fuzzing. |
| `_build/*targets/`, `*-target/`, `instrumented-example/` | Parejas BEAM/manifiesto creadas por la fachada de compilación para pruebas, ejemplos y benchmarks. Los `target/` e `instrumented/` anidados cumplen la misma función. |
| `_build/*crashes/`, `crashes/` anidados | Artefactos de fallo de la ejecución correspondiente. Experimentos antiguos pueden contener archivos planos; `efz_crash` actual publica los grupos descritos abajo. |
| `_build/feedback-loop-test/` | `report.term`, `lineage.txt`, recetas de entradas retenidas y evidencia de replay nuevo de la cadena real `A → AB → ABC`; `target/` guarda su parser instrumentado. `checks/` y registros de padres negativos adicionales son comprobaciones locales de regresión. |
| `_build/durable-e2e-*/` | Fases VM separadas: descriptor, objetivos ordinarios/instrumentados/v2, `corpus/` persistente, informes/registros por fase y `lineage.txt`. `durable-e2e-latest.txt` identifica el último directorio. |
| `_build/cli-test-*/`, `cli-acceptance/`, `cli-checks/` | Fixtures/copias del lanzador temporales, resultados de VM nueva y evidencia local de CLI. La limpieza de pruebas suele eliminar `*-test-*`. |
| `_build/quickstart/`, `quickstart-checks/` | Semillas preparadas, parser instrumentado, corpus/hallazgos reutilizables y registros de validación del script de preparación, CLI común, restauración y replay. |
| `_build/coverage-audit-2026-09-15/` | Objetivo diagnóstico compilado, registros experimentales completos, registros de validación y fuentes de referencia AFL++ fijadas descargadas. |
| `_build/limits-test-*/`, `limits-checks/`, `limits-storage-failure.term` | Entradas/objetivos y artefactos de inyección de fallos para pruebas de límites, registros de comandos e informe que preserva entrada causante al fallar almacenamiento. |
| `_build/scheduler-checks/`, `scheduler-progress.term` | Evidencia local de corrección de progreso/agotamiento por etapas, incluida una campaña con 256 semillas. |
| `_build/isolation-test/`, `isolation-checks/` | Fixture instrumentado de ciclo de vida, registros de políticas de contaminación en VM nueva y validación de suite de regresión del guardian. |
| `_build/architecture-checks/` | Validación local de Markdown/UML, PNG de vista previa e informe de validación. Las fuentes UML y SVG publicados están en `docs/diagrams`. |
| `_build/performance*/`, `perf-*/`, `phase21-*/`, `phase3-performance*/` | Variantes de experimentos de rendimiento: fixtures compilados, muestras originales, salida de memoria/perfil y comparaciones. Las conclusiones guardadas se publican en `docs/performance`. |
| `_build/phase2-*/`, `phase3-*/`, `backend-test-*/`, `fixture-check/`, `relocated/` | Directorios de aceptación: código recompilado/reubicado, corrupción de manifiesto, sintaxis estricta, replay y diagnósticos de terminación. Para localizar el productor concreto, busque la ruta en tests/bench. |
| `_build/*report.term`, `*.term`, `*.txt`, `*.log`, `*.json` | Informes y evidencia local. La extensión `.term` no especifica por sí sola codificación: el productor escribe ETF binario o un término Erlang textual. |
| `_build/*.input`, `*.recipe`, `*.hex` | Bytes y recetas de replay, fixtures negativos corruptos y archivos de prueba de diccionario. Su significado depende de la prueba/script productor, no solo de la extensión. |

### Formatos de artefactos de ejecución

Estas rutas se configuran en la campaña/CLI. Pueden estar fuera de `_build/` y persistir
entre ejecuciones si el usuario selecciona un directorio permanente.

| Ruta / archivo | Responsabilidad | Productor / lector |
|---|---|---|
| `ARTIFACTS/Module.beam` | Código Erlang instrumentado cargable con manifiesto incorporado | `efz_instrument:compile/2`; carga/preflight mediante `efz_instrument`. |
| `ARTIFACTS/Module.efz-manifest` | Metadatos sidecar: compilación, sondas y ubicaciones fuente; debe coincidir con BEAM | Fachada de compilación y validación de preflight/manifiesto. |
| `OUT/report.term` | Informe final ETF binario de campaña, con estadísticas/corpus/decisiones/fallos | `efz_cli` mediante auxiliar de archivo atómico. No es por sí solo checkpoint de campaña. |
| `CORPUS/<sha256>/input` | Entrada binaria exacta reutilizable de corpus | `efz_corpus_store`; la identidad SHA-256 del contenido es independiente del ID anterior de cola. |
| `CORPUS/<sha256>/metadata` | Sobre de metadatos EFZC v1: contenido/padre/compilación/descubrimiento y receta disponible | `efz_corpus_store:save/4` y restauración; comprueban integridad/compatibilidad. |
| `CRASHES/<signature>/<occurrence>/artifact.input` | Entrada causante exacta del representante inmutable elegido | `efz_crash` mediante `efz_fs:atomic_group/3`; replay de ejecución lee los bytes. |
| `CRASHES/<signature>/<occurrence>/artifact.term` | Esquema ETF binario v2: Reason/pila originales completos, resultado/metadatos, identidades y límite de entrada de campaña | Almacenamiento de fallos; usado para analizar causa y procedencia. |
| `CRASHES/<signature>/<occurrence>/artifact.replay` | EFZX v1: compilaciones/harness esperados, hash de entrada, firma, política y límite | Creado por `efz_crash`, cargado de forma segura y comprobado por `efz_replay` antes de ejecutar. |
| `CRASHES/<signature>/<occurrence>/artifact.recipe` | Receta EFZR si hay procedencia por etapas; puede faltar en la vía aleatoria | `efz_crash` verifica correspondencia de entrada; receta malformada produce error y publicación solo de bytes originales; `efz_recipe` reconstruye bytes. |
| `CRASHES/<signature>/<occurrence>/manifest` | Esquema de grupo e identidades de archivos para validar publicación completa | `efz_fs:validate_group/1` valida todo el grupo; replay raw no depende deliberadamente de diagnósticos ni receta opcional. |
| `CRASHES/<signature>/summary` | Conteo persistente EFZG v1 y parejas limitadas de ID/hash de representantes | `efz_crash_store`: decode ETF seguro y acotado, validación de grupo, sustitución atómica + fsync. El conteo persiste entre VMs; el estado del planificador no. |
| `CRASHES/<signature>/.lock/` | Bloqueo exclusivo de escritor | El almacén lo crea antes de cambios y lo elimina con sincronización del directorio tras escribir. Un escritor competidor o bloqueo restante produce `writer_active_or_interrupted`; no adivina automáticamente si murió el propietario. |
| `.tmp-*` en directorio de almacenamiento | Escritura staging incompleta antes de rename atómico; no es entrada confirmada de corpus/fallo | Auxiliares de almacén/sistema de archivos. Fallos ordinarios limpian; la interrupción de VM puede dejar restos, comunicados por diagnósticos de restauración de corpus. |

### .git y volcados de fallos

Git gestiona `.git/`, que no participa en fuzzing. Ningún archivo suyo es fuente
de EFZ ni configuración de campaña.

| Archivo / directorio | Finalidad |
|---|---|
| `.git/HEAD`, `refs/`, `objects/`, `index` | Referencia actual, refs de ramas/tags, objetos históricos e índice de staging. |
| `.git/config`, `description`, `info/` | Configuración local y descripción interna del repositorio. |
| `.git/logs/`, `ORIG_HEAD`, `FETCH_HEAD`, `AUTO_MERGE`, `COMMIT_EDITMSG` | Reflogs y estado temporal de operaciones Git. Su presencia/valores cambian independientemente de EFZ. |
| `.git/hooks/`, `branches/`, `worktrees/`, `gk/` | Hooks, directorios internos Git/worktree y datos locales del cliente Git; no son ejecución de EFZ. |
| `erl_crash.dump` en raíz | Volcado ERTS creado al fallar la VM. No es `.input` de fallo del objetivo ni receta; existe en este checkout y se excluye de Git. |
| `rebar3.crashdump`, `.rebar3/`, `.eunit/`, `_checkouts/` y otras exclusiones de `.gitignore` | Posibles archivos generados/de herramientas enumerados en reglas de exclusión. La regla no implica que el archivo o directorio exista actualmente. |

<a id="changes"></a>
## Cómo encontrar dónde modificar una funcionalidad

| Tarea | Código principal | Dónde verificar comportamiento |
|---|---|---|
| Añadir opción CLI / campo de campaña | `efz_cli`, `efz_config` | `efz_cli_tests`, `efz_config_tests`; después `docs/cli.md`. |
| Cambiar invocación del harness / timeout | `efz_target`, `efz_executor`, `efz_guardian`, `efz_worker` | Pruebas de executor, Phase 2/backend y UML de ejecución. |
| Cambiar sintaxis cubierta / identidades de sonda | `efz_instrument_pt`, `efz_instrument`, `efz_cov_manifest` | Pruebas de Phase 2, `fixtures/efz_fixture`, fixtures estrictos y contrato de cobertura. |
| Cambiar hooks o validación de snapshots | `efz_cov_rt`, `efz_cov`, `efz_cov_manifest` | Pruebas diferenciales de backend y escenarios de terminación/aislamiento Phase 2. |
| Cambiar novedad / retención | `efz_feedback`, `efz_worker`, `efz_corpus` | `efz_feedback_loop_tests`: la entrada descubierta debe convertirse realmente en padre. |
| Cambiar planificación / protección de progreso | `efz_mutation_plan` | Regresiones de mutación/Phase 3 con 256 semillas, corpus creciente y prueba completa del bucle de feedback. |
| Añadir operador de bytes | `efz_mutation_plan`, `efz_mutation`, `efz_recipe` | Pruebas de modelos de mutación, roundtrip de recetas/VM nueva y ejecución por etapas. |
| Cambiar esquema persistente / restauración | `efz_corpus_store`, `efz_corpus`, `efz_config` | Pruebas de corrupción/duplicados del almacén e integración persistente en VM nueva. |
| Cambiar límite de entrada / contrato de E/S | `efz_input`, `efz_fs`, `efz_crash` y fronteras llamantes | `efz_limits_tests`, ingesta CLI y pruebas de recetas. |
| Cambiar descripción arquitectónica | `docs/architecture.md`, `docs/diagrams/*.mmd` | Contrastar llamadas con fuentes, regenerar SVG y actualizar este mapa al añadir archivos. |

Al añadir o mover un archivo, actualice la tabla correspondiente y el número
de archivos. Conserve diagnósticos archivados como evidencia de su época; la
corrección actual la confirman pruebas vigentes y nuevas ejecuciones, no registros antiguos.

## Incorporaciones de diagnósticos de ejecución

| Ruta | Finalidad |
|---|---|
| `src/efz_runtime_config.erl` | Validador común de políticas anidadas y límites |
| `src/efz_stability.erl` | Comparación acotada de retornos, métricas de repetibilidad y repetición de replay |
| `src/efz_runtime.erl` | Muestreador propiedad del guardian, observaciones de hijos/timeouts |
| `src/efz_runtime_store.erl` | Artefactos independientes de ejecución con límites e índice con checksum |
| `src/efz_runtime_replay.erl` | Recomprobaciones compatibles con objetivo explícito |
| `fixtures/runtime/`, `test/efz_runtime_tests.erl` | Regresiones instrumentadas de recursos/ciclo de vida/verificación |
| `bench/efz_runtime_bench.erl` | Medición baseline/desactivado/estabilidad/recursos/completo con el mismo controlador |
| `docs/runtime-diagnostics.md`, `docs/runtime-diagnostics-validation.md` | Contrato y validación real |

## Incorporaciones del supervisor externo P1-01

| Ruta | Finalidad |
|---|---|
| `c_src/efz_vm_launcher.c`, `c_src/Makefile` | Ciclo de vida Linux pidfd/PDEATHSIG/sesión/subreaper y estado wait autoritativo |
| `priv/efz_external.py` | Protocolo acotado, diario persistente, máquina de estados, política de reinicio y replay externo |
| `src/efz_external.erl`, `src/efz_external_worker.erl` | Delegación CLI antes de cargar y puerta de ejecución del worker |
| `fixtures/external/` | Fixtures seguros/de fallo nativo/bloqueo/contaminación/inicio cargados solo por workers de integración |
| `test/efz_external_tests.erl`, `test/external_supervisor_test.py` | Puerta heredada y aceptación con procesos reales del SO |
| `test/external_bench.py` | Medición del coste de persistencia heredado/supervisado sobre el mismo objetivo |
| `docs/p1-01-external-supervisor.md` | Contrato, comandos, evidencias y limitaciones |
