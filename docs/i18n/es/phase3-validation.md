# Validación Phase 3: mutación por etapas y replay exacto

[English](../../phase3-validation.md) · [Русский](../ru/phase3-validation.md) · **Español** · [简体中文](../zh-CN/phase3-validation.md) · [Todos los idiomas](../README.md)

Phase 3 está completa para el contrato local probado: OTP 27.0, un trabajador,
un proceso instrumentado objetivo, compilaciones seleccionadas fijas y cobertura
exacta de cláusulas/resultados a nivel de fuentes. La mutación por etapas es
opcional. Añade mutación de bytes y replay sin cambiar la implementación de
cobertura ni reiniciar su estudio de rendimiento. Las medidas siguientes son
observaciones, no constantes de aceptación.

## Línea base y procedencia

Se inspeccionó el repositorio antes de modificarlo: configuración, mutador/
corpus/trabajador, almacenamiento de fallos, ejecutor, validación preparada y
documentos Phase 2/2.1. No había `AGENTS.md` aplicable. El árbol ya contenía
archivos seguidos modificados y abundante implementación/evidencia Phase 1–2.1
sin seguimiento. Se preservó todo. No se hizo reset, clean, staging, commit,
push ni cambios de remoto/identidad Git.

La línea base pasó `rebar3 compile`, `rebar3 eunit` (38 pruebas), `rebar3 ct`
(3 casos), `rebar3 dialyzer`, `rebar3 xref` y `git diff --check`.
No había fallos iniciales que arrastrar. Los registros están en
`_build/phase3-baseline`; las salidas completas se conservan también en el
registro persistente siguiente. Los resultados finales son 62 pruebas EUnit
y los mismos 3 casos Common Test.

Entorno: Ubuntu 24.04.4 LTS, Linux 6.8.0-nyx+, x86_64-pc-linux-gnu,
Intel Core i7-1260P, OTP 27.0 / ERTS 15.0, Rebar3 3.25.0. Opciones del compilador
del proyecto/ejemplo: `[debug_info,warnings_as_errors]`; la fachada añade sus
opciones existentes de transformación estricta y ubicación por columnas.
No se afirman probadas otras versiones OTP. No se añadió ninguna dependencia.

Evidencia persistente apta para `file:consult/1`:

* [performance/phase3-mutations.term](../../performance/phase3-mutations.term): las
  cinco muestras originales por carga/modo de campaña; configuraciones
  normalizadas, hashes de entradas/donantes, entorno, opciones de compilación,
  descriptor de artefacto/compilación, identidades SHA-256 actuales de fuentes,
  instantáneas de memoria de proceso/VM y reducciones.
* [performance/phase3-validation.term](../../performance/phase3-validation.term):
  salidas de comprobaciones iniciales/finales, hashes de 41 archivos relevantes
  fuente/configuración/prueba/script, identidades antes/después de Phase 3,
  informes de aceptación/ejemplo, manifiesto completo, receta exacta y salida
  de replay en VM nueva. Las referencias runtime son cadenas diagnósticas;
  esta copia persistente omite la traza acotada de aceptación. Ninguna receta
  depende de esas referencias.
* [examples/staged-crash.recipe](../../examples/staged-crash.recipe) y
  [examples/staged-crash.input](../../examples/staged-crash.input): receta EFZR de
  629 bytes y los seis bytes originales autoritativos del ejemplo verificado.

Se compararon hashes fuente del benchmark sin perfilador con fuentes finales
de runtime, planificador y benchmark al exportar evidencia. El último cambio
posterior a medir fue una aserción de prueba que compara niveles de registro,
seguida de otra EUnit completa exitosa y solo documentación/evidencia.
Compilador, hook de cobertura, propiedad del contexto, ejecutor, feedback y
validador de manifiestos son idénticos a la línea base. La transformación solo
añadió cuatro módulos internos a la lista de exclusión; no cambian algoritmo
ni versión de generación de sondas.

El directorio final es `_build/phase3-performance-verified`.
Se conservan ejecuciones anteriores `_build/phase3-performance` y
`_build/phase3-performance-final`, pero se excluyen de la comparación: precedían
a la procedencia fuente final o se solapaban con otra actividad local de ejemplos.
La ejecución verificada terminó con salida 0, sin perfilador ni solapamiento con
otra tarea Erlang iniciada por el asistente. No se controló actividad ajena del host.

## Compatibilidad pública e implementación

El valor predeterminado sigue siendo `mutation_mode => random`, con behaviour
aleatorio y selector anterior existentes. Validación preparada y backend ETS
original siguen predeterminados. `coverage_backend => ets_member` continúa
explícito y funciona en campañas y replay. El ejemplo automático anterior no
cambia. Excepciones/retornos no binarios del mutador antiguo ahora terminan
como infraestructura, sin contarse como bugs del objetivo.

`mutation_mode => staged` habilita el nuevo mapa `mutation`. Rechaza callbacks
anteriores personalizados y opciones de mutación suministradas accidentalmente
en modo aleatorio. Omitir `max_iterations` por etapas fija 1,000, con máximo
1,000,000; infinity explícito se rechaza. La calibración se cuenta aparte.
Los demás límites, semántica y orden están en [mutations.md](mutations.md).

Los operadores nativos son cambios contiguos de 1/2/4 bits; inversión alineada
de 1/2/4 bytes; aritmética de 8/16/32 bits con desbordamiento explícito y elección
de endian; patrones versionados de fronteras enteras; sobrescritura/inserción
literal; eliminación no vacía y duplicación de bloques; sobrescritura/inserción
de diccionario; empalme identificado por contenido; y pilas acotadas de esas
operaciones concretas, havoc.

Aplicación pura, elección de operaciones, estado de etapas por contenido,
selección de donante/semilla y ejecución están separados. Las etapas deterministas
son cursores enteros perezosos. Rondas del corpus y carriles son explícitos y
acotados; crecer el corpus no aplaza indefinidamente las entradas antiguas.
Omitir operaciones avanza cursores o RNG; límites finitos de intentos/inactividad
impiden reintentos sin progreso. Diccionario/configuración permanecen fijos
en campaña. `exsplus` usa API de estado explícito; registros y aleatoriedad del
objetivo no lo consumen.

La retención añade una receta versionada a metadatos existentes de corpus/fallos.
El manejo predeterminado de rechazos no guarda recetas completas indefinidamente;
la traza opcional está acotada. Las recetas contienen bytes principales/
donantes/tokens reales y operaciones ordenadas, no solo RNG. La importación
EFZR valida datos acotados antes de decodificar ETF. Regenerar bytes no necesita
objetivo ni plan. Ejecutar replay requiere artefactos/objetivo elegidos por el
llamador y compilaciones compatibles, prepara un plan nuevo y usa el ejecutor
existente. Consulte [replay.md](replay.md).

## Evidencia concreta de cobertura y replay

El `examples/staged/efz_staged_parser.erl` ordinario tiene siete sondas de cláusula
de función tras compilarlo seleccionado, sin llamadas EFZ en su fuente.
Todas las observaciones siguientes usan esta compilación:

```text
4c53c8d203bf5fca774d78fee2122a75419b86ba8f807cc3ffbb5d96339e0a5e
```

La prueba determinista usa las etapas reales de producción
`[dictionary_insert,boundary,arithmetic]`, semilla `{17,23,41}`, entrada principal
`<<0>>` y presupuesto de 200 ejecuciones. No usa el antiguo mutador de guion.
La calibración observa inicialmente la sonda 5 y no cuenta como descubrimiento
de mutación.

| Bytes retenidos | Padre | Operación realizada | Sonda nueva / fuente | Decisión |
|---|---:|---|---|---|
| `<<"TOKEN",0>>` | Entry 1, `<<0>>` | `{dictionary_insert,0,<<"TOKEN">>}` | 1, `run/1`, line 4, column 1 | `new_coverage` |
| `<<128>>` | Entry 1, `<<0>>` | `{set_integer,0,8,big,128}` | 3, `run/1`, line 6, column 1 | `new_coverage` |

El informe completó 1 calibración, 200 mutaciones, 4 descubrimientos,
191 rechazos por cobertura equivalente, 5 observaciones de fallo, un grupo de
huella y cero fallos de infraestructura/timeouts. Las pruebas también aseguran
un descubrimiento después del primer fallo artificial y regeneran bytes exactos
de entradas retenidas desde sus recetas. Los números son observaciones de
manifiesto; ni ID de fixtures ni excepciones de retención están codificados
en el núcleo del fuzzer.

El ejemplo completo habilita además havoc/splice. Completó 200 ejecuciones con
5 descubrimientos, 188 rechazos, 7 fallos observados, un grupo de huella y cero
infraestructura/timeouts. Distingue 243 visitas, 233 intentos de mutación,
320 intentos de operaciones integrantes, 72 operaciones omitidas, 43 visitas
sin candidato y 200 candidatos generados/ejecutados. Los totales de motivos
también incluyen pilas finales canceladas; no igualan el recuento de operaciones
omitidas.

Los bytes guardados del fallo artificial son `<<"BOOM!",0>>`, hex `424f4f4d2100`,
con SHA-256:

```text
1732ef36d864988423a5275aec30b90b55e3405cc798c709e318c867797ad64b
```

La regeneración en VM nueva y `cmp` reprodujeron los seis bytes. Otra VM nueva
compiló el objetivo explícito, cargó las compilaciones esperadas de la receta,
ejecutó la entrada original y devolvió
`{crash,error,artificial_staged_exception,Stack}`, con `coverage_status => ok`
y sonda exacta 2. La pila señala la línea 5. Esto confirma reconstrucción de
bytes y resultado determinista real del ejemplo, no promete lo mismo para
objetivos sensibles al tiempo.

La sonda 2 sobrevive a la terminación en el resultado del fallo. La decisión
lleva `retention_reason => target_failure, new_probes => []`; la cobertura del
corpus exitoso excluye la sonda 2. Es la política existente: observar fallos no
suprime novedad exitosa futura. Los grupos son huellas, no bugs independientes
probados.

El ejemplo automático antiguo también terminó sin cambios en modo aleatorio:
500 ejecuciones, 1 calibración, 5 descubrimientos, 493 rechazos, 2 fallos
observados, un grupo y cero infraestructura/timeouts. Son observaciones de esta
ejecución; su selección sin semilla predeterminada no tiene que coincidir con
informes anteriores.

## Coste acotado de mutaciones

Reproducción desde la raíz del repositorio:

```sh
rebar3 compile
ERL_FLAGS='+S 4:4' escript bench/mutations.escript _build/phase3-performance-reproduce
```

La ejecución verificada usó `+S 4:4`, cuatro schedulers activos. El controlador
calienta cada caso con una tanda completa de 5,000 candidatos y valida toda
secuencia realizada contra su resultado. Cada una de cinco tandas medidas
inicia un planificador nuevo con la misma configuración normalizada y valida
cantidad, visitas y secuencia CRC32 consumida contra el calentamiento.
Normalizar configuración/diccionario y construir fixtures queda fuera del tiempo
de solo mutación. Hash de candidatos, planificación/aplicación, procedencia y
consumo CRC están dentro. Codificar EFZR completo y ejecutar el objetivo quedan
fuera. No hay umbral de rendimiento por máquina en las pruebas.

Cada carga tiene dos entradas estáticas distintas: bytes `0,1,2,3` repetidos
al tamaño indicado y un donante con primer byte invertido. El límite es 4,096;
otros predeterminados son bloque 128, profundidad 8, delta 8, tokens
`TOKEN`/`BOOM!` y semilla `{17,23,41}`. Todas las muestras generaron realmente
5,000 candidatos. Corta/media/cercana al máximo usan bitflip/arithmetic/havoc;
diccionario usa ambas etapas de diccionario; empalme y havoc usan su etapa
única respectiva. Estas ejecuciones no tienen observaciones del objetivo/sondas
ni exploración de manifiestos.

| Carga de mutación | Bytes de entrada | Mediana µs / 5,000 | Min–max µs | Candidates/s |
|---|---:|---:|---:|---:|
| Corta | 4 | 37,396 | 36,364–39,283 | 133,704 |
| Media | 1,024 | 32,538 | 30,792–34,778 | 153,667 |
| Cerca del máximo configurado | 4,095 | 55,712 | 55,276–57,220 | 89,747 |
| Inserción/sobrescritura de diccionario | 1,024 | 17,950 | 16,884–22,325 | 278,552 |
| Empalme | 1,024 | 25,986 | 25,224–27,787 | 192,411 |
| Havoc | 1,024 | 51,818 | 48,236–51,889 | 96,492 |

La carga mixta corta no es más rápida que la media en esta muestra: difieren
operaciones aplicables, reintentos y redimensionados intermedios. Son resultados
de cargas, no afirmaciones de escalado solo por tamaño. Las duraciones originales
están en la evidencia `.term`.

## Comparación integral acotada

Ambos modos usan el mismo ejemplo ordinario de siete sondas, semilla `<<0>>`,
timeout 100 ms, hook ETS original, validación preparada y **500 ejecuciones
objetivo de mutaciones**, con una calibración. El controlador descarta un piloto
de 100 ejecuciones por modo y alterna orden durante cinco rondas. Compilar,
una observación de 8,921 µs, e imprimir al final quedan fuera del tiempo de
mutación. Compilar es una observación única de inicio, no estimación repetida
de rendimiento.

Aleatorio antiguo usa `random_seed => {17,23,41}` y
`selection_seed => {101,109,113}`. Por etapas usa esa semilla de mutación,
las cinco etapas del ejemplo, entrada máxima 64, bloque/token 16, profundidad
havoc 4 y dos tokens inline. Se evita intencionalmente imponer al modo anterior
los límites nuevos.

| Modo | Tiempos originales de mutación µs | Mediana µs | Min–max µs | Executions/s | Descubrimientos | Sondas exitosas | Fallos / grupos |
|---|---|---:|---:|---:|---:|---:|---:|
| Aleatorio existente | 9169, 9916, 7503, 7786, 7257 | 7,786 | 7,257–9,916 | 64,218 | 4 | 5 / 7 | 0 / 0 |
| Por etapas | 14965, 17455, 15749, 16198, 15339 | 15,749 | 14,965–17,455 | 31,748 | 5 | 6 / 7 | 14 / 1 |

Los recuentos fueron estables en las cinco muestras de cada modo. Por etapas
alcanzó además la rama de diccionario; la sonda de fallo permaneció fuera de
cobertura exitosa. Ambos tuvieron cero infraestructura/timeouts.
Medianas de calibración: 55 µs aleatorio y 56 µs por etapas. Medianas completas
API `start`/`await`/`stop`, incluidas preparación/entrega de informe/limpieza:
8,883 y 17,127 µs, respectivamente. Muestras originales API y duraciones de
calibración se registran separadas.

La mutación por etapas tardó **2.02 veces** el tiempo de fase de mutación del
aleatorio en este fixture pequeño, aproximadamente 49.4% de su rendimiento.
Incluye secuencia distinta de candidatos, trabajo más rico de mutación/
procedencia, más visitas de planificación y 14 observaciones de fallos con
escritura de artefactos. No compara ejecutores/backends con entradas iguales.
El descubrimiento extra del ejemplo no demuestra superioridad universal;
no hay objetivo de rendimiento ni garantía de cobertura adicional.
Ninguna medida Phase 2.1 de hook o ejecutor completo se reinterpreta desde
este experimento.

## Observaciones de memoria y limpieza

El benchmark registra memoria de proceso y VM total antes de cada tanda,
después de medir y después de GC explícito, con lecturas fuera del intervalo.
También registra reducciones; no son bytes asignados. Las muestras tras GC
retienen controlador, entradas/configuraciones y resúmenes anteriores, mientras
estado/candidatos del planificador terminado ya no se retienen. La memoria del
proceso sola no incluye todos los binarios referenciados fuera de heap.

| Carga | Bytes de proceso tras tanda (rango) | Bytes de proceso tras GC (rango) | Mediana reducciones / tanda |
|---|---:|---:|---:|
| Corta | 29,552–42,416 | 8,816 | 3,935,059 |
| Media | 47,184–68,056 | 13,704 | 5,853,867 |
| Cerca del límite | 47,184–62,992 | 13,704–21,608 | 16,006,728 |
| Diccionario | 101,368–142,760 | 21,608 | 3,815,738 |
| Empalme | 89,720–123,048 | 21,608–34,400 | 5,981,997 |
| Havoc | 76,096–110,048 | 34,400 | 8,022,823 |

Los totales VM tras GC oscilaron entre 51,106,240 y 51,261,888 bytes según carga.
No tienen que volver al mismo valor. Estas instantáneas no son picos absolutos
ni estudio completo de memoria retenida por campaña. No se infiere fuga de los
totales VM. Las pruebas de ciclo de vida demuestran aparte liberar tablas/
procesos tras terminar, timeout, cancelación, muerte del llamador y cierre.
Una campaña terminada aún posee plan, corpus, recetas, decisiones y traza
opcional hasta `efz:stop/0`; las observaciones se asignan y limpian aparte como
en Phase 2.1.

El planificador copia la vista mínima del corpus y calcula hashes durante
planificación; el empalme explora/ordena contenidos distintos de donantes.
Corpus y donantes embebidos grandes pueden costar más tiempo y almacenamiento
de recetas. No se introdujo optimización ni reutilización de búfer sin medir
para ocultar esos costes.

## Comandos y resultados de regresión

Todos los comandos siguientes terminaron con estado 0 en este árbol:

```sh
rebar3 compile
rebar3 eunit
rebar3 ct
rebar3 dialyzer
rebar3 xref
git diff --check
ERL_FLAGS='+S 4:4' escript examples/staged/run.escript
escript scripts/replay.escript _build/staged-example.recipe _build/staged-regenerated.input
cmp _build/staged-example.input _build/staged-regenerated.input
escript examples/automatic/run.escript
ERL_FLAGS='+S 4:4' escript bench/mutations.escript _build/phase3-performance-verified
escript scripts/replay.escript docs/examples/staged-crash.recipe _build/from-docs.input
cmp docs/examples/staged-crash.input _build/from-docs.input
```

* Compilación: pasa, avisos tratados como errores.
* EUnit: **62 passed**, incluidas 15 pruebas de mutación, 3 de receta y 6 grupos
  de aceptación Phase 3. Pasan semántica de transformación existente,
  diferencial canónico exacto, negativos de planes, error/throw/exit,
  supervivencia de cobertura ante kill/timeout sincronizados, separación de
  contextos, frontera de plazo, muerte del llamador, cancelación/cierre y
  comprobaciones repetidas de vida de recursos.
* Common Test: **3 passed**.
* Dialyzer: pasa, 26 módulos analizados y 278 archivos PLT comprobados.
* Xref y espacios: pasan. No hay formatter/linter configurado.
* El fragmento README con diccionario inline, campaña/guardar/regenerar/ejecutar,
  también se ejecutó y pasó en una VM nueva. El script de diccionario de archivo
  anterior cubre la otra configuración pública.

Las pruebas negativas existentes registran intencionalmente errores de proceso
por planes malformados y diagnósticos AST no admitidos; comprueban clasificación
de infraestructura/error y pasan. No son comprobaciones nuevas fallidas.
La última EUnit siguió a añadir la prueba de niveles de registro; las demás
comprobaciones finales siguen aplicándose porque no cambió ningún fuente runtime
relevante después. No se ocultó ningún fallo inicial cambiando conjuntos
esperados de cobertura/resultados.

Para ejecutar independientemente los bytes persistentes del fallo en una VM nueva:

```sh
erl +S 4:4 -noshell -pa _build/default/lib/efz/ebin -eval '
{ok, A} = efz_instrument:compile("examples/staged/efz_staged_parser.erl",
    #{modules => [efz_staged_parser], source_root => ".", outdir => "_build/replay-target"}),
{ok, R} = efz_recipe:load("docs/examples/staged-crash.recipe"),
{ok, Result} = efz_recipe:execute_file("docs/examples/staged-crash.input",
    efz_staged_parser, [A], maps:get(target_builds,R), #{timeout => 100}),
{crash,error,artificial_staged_exception,_} = maps:get(outcome,Result),
ok = maps:get(coverage_status,Result),
io:format("~tp~n",[Result]),halt(0).'
```

El ejemplo ordinario y comandos de regeneración sin `ERL_FLAGS` anteriores usaron
opciones ambientales, no una configuración supuesta de cuatro schedulers.
La medición registra explícitamente cuatro. Las pruebas replay EUnit en VM
nueva usan explícitamente dos; todas las medidas de rendimiento son sin perfilador.

## Archivos cambiados en esta fase y límites

Módulos runtime nuevos: `efz_mutation`, `efz_mutation_plan`, `efz_dictionary`,
`efz_recipe`. Integrados mediante `efz_config`, `efz_corpus`, `efz_worker`,
`efz_crash`; se amplió la exclusión interna de la transformación.
Pruebas nuevas: `efz_mutation_tests`, `efz_recipe_tests`, `efz_phase3_tests`.
Añadidos parser ordinario por etapas, diccionario/script de ejemplo, CLI de
regeneración de bytes y benchmark acotado. Actualizados README/arquitectura y
añadidas documentación mutación/replay/validación y evidencia compacta.
Fuentes/configuración ajenos y evidencia Phase 2.1 se conservan.

Los límites restantes son intencionados: mutación solo de bytes, un trabajador
de producción, estado por etapas en memoria, sin checkpoint completo,
planificación adaptativa, extracción automática de tokens, minimización ni
fuzzing gramatical/con estado. Presupuestos de entrada, diccionario, pila y
campaña acotan el trabajo, pero máximos elevados aún pueden ser caros.
Las recetas son datos acotados, no archivos autenticados. Se necesitan
compilaciones seleccionadas fijas por campaña; regenerar no demuestra reproducir
resultado y replay no permite sustitución arbitraria en caliente.
Hijos arbitrarios, estado VM compartido y efectos nativos/SO quedan fuera del
contrato de cobertura/limpieza de proceso objetivo. Ningún resultado requerido
de validación está bloqueado o no disponible en este entorno.
