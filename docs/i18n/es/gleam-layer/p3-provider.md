# P3: proveedor estructurado — PASS

[English](../../../gleam-layer/p3-provider.md) · [Русский](../../ru/gleam-layer/p3-provider.md) · **Español** · [简体中文](../../zh-CN/gleam-layer/p3-provider.md) · [Todos los idiomas](../../README.md)

La aceptación P5 actual está en [p5-validation.md](p5-validation.md).
Las notas de traspaso y estado pendiente siguientes son de la fase histórica.

Requisitos **2.0-native**; vector contrato/modelo/códec/mutador/característica/
propiedad **{1,1,1,1,1,1}**. Generador fuera del bucle **2**, paquete **1.1.0**.
Esquema nuevo de receta estructurada **3**, operación **2**, envoltura EFZR
**1**; esquemas antiguos **1/2** siguen legibles. Fecha: 2026-10-08.

Evidencias: `artifacts/gleam-layer/20261008-p3-provider/`. HEAD sigue en
`79d76221c6bc5df30b80e6b0de947f3860f4fa4b`. `head.txt`, `status-before.txt`,
`dirty-before.patch`, `dirty-index-before.patch`, `inputs.json` y `before-files/`
conservan el checkout inicial. Esta pasada amplía el proveedor ya presente
en P2; no afirma aceptación entonces de todas las fases anteriores.
Se revisaron [P0](baseline.md), [ruta de ejecución](execution-path.md),
[contrato P1](contracts.md) y [P2](p2-integration.md) antes de editar.

## Ejecución real y responsabilidades

| Responsabilidad | Archivo:función real |
| --- | --- |
| Bucle/ciclo de vida existente | `src/efz_worker.erl:staged_iteration/1`, `src/efz_fuzzer.erl:handle_info/2` |
| Corpus de trabajo / padres | `src/efz_corpus.erl:mutation_entries/0`, `src/efz_mutation_plan.erl:next/2`, `visit/2` |
| Etapa, presupuesto, RNG y selección de familia existentes | `src/efz_mutation_plan.erl:attempts/6`, `structured/3`, `ordinary_attempts/6`, `uniform/2` |
| Frontera nativa | `src/efz_gleam_adapter.erl:mutate/3`, `decode/2`, `encode/2` |
| Núcleo tipado compilado real | `gleam/efz_semantic/src/efz_qs_model.gleam`; BEAM `efz_qs_model:decode/2`, `mutate/3`, `encode/2`, `generate/2` |
| Objetivo real intacto | `examples/query_string/efz_qs_target.erl:run/1` → `cow_qs:parse_qs/1` fijado |
| Ejecución / captura del objetivo | `src/efz_executor.erl:run/4`, `src/efz_guardian.erl:finish/2`, `src/efz_cov_native_public.erl:collect/1` |
| Admisión estructural / persistencia | `src/efz_feedback.erl:evaluate/3`, `src/efz_corpus.erl:add_checked/3`, `src/efz_corpus_store.erl:save/4` |
| Preparación / importación normal de semillas | `scripts/gleam_seeds.escript:main/1`, `src/efz_cli.erl:read_seeds/2`, `src/efz_corpus.erl:init/1` |
| Receta acotada / regeneración de bytes | `src/efz_recipe.erl:make/4`, `validate_structured/2`, `regenerate/1` |

EFZ visita primero un padre del corpus y etapa existente y luego selecciona
familia. Ordinario llama a sus funciones existentes. Estructurado invoca
BEAM directo decode → mutate → encode; los callbacks puros no ejecutan
objetivo ni eligen padres. No admitido/límite/sin cambios usa
`ordinary_attempts/6` una vez, sin volver a seleccionar estructurado.
Error de capa devuelve diagnóstico separado, incrementa `errors` y detiene
por el canal de infraestructura EFZ. El controlador sigue disponible para
informar/detener. No se infiere defecto del objetivo.

Desactivado/fracción cero omite RNG de rama y decode. Fracción positiva
consume `uniform_s(100)` y elegir estructurado añade `uniform_s(6)` para
operación. Éxito devuelve R2; alternativa empieza ordinario en R2; error
registra R2 sin reintentar. Solo procedencia estructurada registra palabras
exsplus exactas antes/después, fracción, operación, versiones y límites.
Candidatos/recetas ordinarios conservan forma. Binario original es la entrada
persistente canónica; modelos transitorios.

No se sustituyen propietarios de objetivo, executor, corpus, energía, admisión,
cobertura, hallazgos ni reproducción. Sin motor externo, callback de fuzzer,
NIF/puente C nuevo, transporte, VM por mutación, caché, aprendizaje asíncrono
ni worker nuevo. Lanzador nativo/backends ajenos existentes permanecen.
Los contadores OTP por módulo conservan serialización del guardian; llamadas
paralelas no gestionadas siguen fuera del aislamiento. P3 desactiva feedback
semántico y oráculo.

## Modelo, límites, operaciones y semillas

ADT concretos: `Query(List(Field),Canonical|BadEscape)` y
`Field(BitArray,BitArray)`. Subconjunto: nombres binarios no vacíos, `=`
explícito, campos ordenados/duplicados, delimitadores `&`, escapes porcentuales
y plus como espacio. Valores vacíos/NUL/no UTF8 permitidos. Campos solo con
nombre, nombres vacíos, separadores redundantes y escapes malformados no se
admiten por el modelo; acceso al objetivo por bytes originales sigue disponible.
Es un subconjunto del lenguaje aceptado por el parser real.

Límites: 4096 bytes de formato, 32 campos, 128 bytes/componente, profundidad
fija 2 y una operación/candidato. Se comprueba capacidad antes de asignar
prepend/append/catálogo. Mutator usa comprobación previa de tamaño en vez
de asignar codificación descartada; encoder comprueba por separado la salida.
BEAM P2 archivado y actual dan resultados idénticos en **264** casos de
modelo/operación/límite.

| ID de operación | Efecto |
| --- | --- |
| 0 | Anteponer campo `x={0,255}` dentro de límites de campos/componentes/bytes |
| 1 | Vaciar primer valor; consulta vacía crea `a=` |
| 2 | Eliminar primer campo, incluida transición a consulta vacía |
| 3 | Invertir campos manteniendo identidad de pares y semántica del orden de nombres duplicados |
| 4 | Añadir byte 255 al primer valor o crear `a=%FF`; el límite evita desbordamiento |
| 5 | Sufijo deliberadamente inválido `&x=%`; encoder lo conserva |

Las pruebas cubren `decode(encode(M)) == normalize(M)` en modelos canónicos
admitidos, normalización idempotente, matriz explícita campo/valor, seis
fixtures de formato esperados y resultados Cowlib reales. `BadEscape`
inválido se excluye de la ley de ida y vuelta válida. No se afirma igualdad
de bytes para entradas arbitrarias.

El catálogo determinista tiene 12 posiciones distintas: consulta/valor vacíos,
bytes binarios, duplicados/reservados, variante de campo con nombre, escape
inválido, valores 127/128 bytes, 31/32 campos, formato de 4096 bytes exactos
y clave máxima. Salida predeterminada: **12 archivos / 5349 bytes**, con
**11 aceptados / 1 rechazo esperado** del parser intacto. Preparación limita
64 archivos y 65536 bytes, rechaza salidas existentes y registra índices,
versiones de generador/runtime, límites y SHA-256 por archivo en manifiesto
esquema 2 fuera de las semillas. Comprueba versión del generador antes de
crear el directorio.

`seed-import-r2/proof.json` verifica hashes, importación CLI ordinaria e
identidad de bytes en corpus de trabajo. La compilación sin compilador/paquete
hace 12 calibraciones; otra campaña ordinaria ejecuta 50 mutaciones. Gleam
sigue sin cargar y sin contadores. Doce sondas independientes del parser son
comprobaciones adicionales fuera de los intervalos de cobertura de campaña.
No se modifica in situ ningún corpus original.

## Comandos y comprobaciones ejecutadas

Herramientas fijadas: OTP **27.0**, ERTS **15.0**, Rebar3 **3.25.0**,
Gleam **1.10.0**; `+S 2:2`. Commits/locks ordinarios intactos.
`runtime.json` registra ruta real de módulo, exportaciones y paquete 1.1.0;
la aplicación opcional no se carga. Cada comando tiene `.json` con argumentos,
cwd, ajustes seleccionados, salida y duración, y `.log`. Runner:
`run_command.py` en la ejecución.

| Criterio | Comando / raíz de evidencia | Salida / resultado |
| --- | --- | --- |
| Compilación on real | `GLEAM_BIN=/tmp/efz-gleam-toolchain/gleam rebar3 as gleam compile` / `on-compile-final` | 0 |
| Suite específica callback/contrato/receta/proveedor | `rebar3 as gleam eunit --module=efz_gleam_provider_tests,efz_gleam_layer_tests,efz_gleam_contract_tests,efz_gleam_beam_tests,efz_recipe_tests` / `focused-tests-r4` | 0 / 46 superadas |
| Regresión completa | `rebar3 as gleam eunit` / `full-on-tests` | 0 / 302 superadas, incluidos objetivos con términos y operaciones staged antiguas |
| Nombres finales nuevos de fixtures | `rebar3 as gleam eunit --module=efz_gleam_provider_tests` / `provider-tests-final` | 0 / 10 superadas |
| Off solo de fuentes | `PATH=/home/fbogoslavskii/.asdf/installs/erlang/27.0/bin:/usr/bin:/bin GLEAM_BIN=/nonexistent/gleam rebar3 compile` en `/tmp/efz-p3-off-0c0joh3_` / `clean-off-compile` | 0 |
| Compatibilidad off | `rebar3 eunit --module=efz_gleam_provider_tests,efz_gleam_layer_tests,efz_gleam_contract_tests,efz_gleam_beam_tests,efz_recipe_tests,efz_mutation_tests,efz_phase2_tests,efz_smoke_tests` allí / `clean-off-tests` | 0 / 57 superadas |
| Regresión cobertura | `rebar3 as gleam ct` / `ct-regression` | 0 / 3 superadas |
| Llamadas estáticas | `rebar3 as gleam xref` / `on-xref` | 0 |
| Compilación ordinaria raíz | `GLEAM_BIN=/nonexistent/gleam rebar3 compile` / `root-off-compile` | 0 |
| Preparación/importación semillas | `escript scripts/gleam_seeds.escript RUN/generated-seeds`; `escript scripts/gleam_seed_import_check.escript OFF_BUILD RUN/generated-seeds RUN/seed-import-r2 ROOT` | 0 / identidades originales, 12 calibraciones, 50 mutaciones posteriores |
| Conexión real del bucle | `real-loop/proof.term`, emitido por pruebas finales | 200 mutaciones + 3 calibraciones; llamadas Gleam reales en worker EFZ; llamadas al objetivo igualan ejecuciones contadas; sin observe/check ni estado semántico |
| Secuencia off/cero | `python3 RUN/run_campaigns.py` / `raw-{baseline,off,fraction0}-{17,43}` | Seis salidas 0; trazas hash/etapa/padre de 100 candidatos coinciden con P0 por semilla |
| Reproducción sin Gleam | `escript /tmp/efz-p3-off-0c0joh3_/scripts/replay.escript RUN/real-recipes/{current,old}.recipe RUN/replayed-{current,old}.input` | Ambas 0; resultados de esquemas 3/2 coinciden con bytes esperados |
| Reproducir estado registrado | `escript RUN/verify_recipe.escript BUILD RUN/real-recipes/current.recipe RUN/recipe-state-proof-result.json` | 0; callback nativo y plan EFZ desde R0 registrado reproducen bytes, operación y R2; cero ejecuciones objetivo |
| Componentes separados | `escript scripts/gleam_provider_probe.escript BUILD RUN/p2-model-original.beam RUN/provider-samples.json` | 0 / 264 casos equivalentes, 40 lotes, 36 muestras ordinales |
| Selección desactivada | `escript scripts/gleam_dispatch_bench.escript RUN/dispatch-samples.json` | 0 / 5 ensayos × 1M llamadas por selección |

`RUN` abrevia directorio de evidencias; `BUILD` es `_build/gleam`, `OFF_BUILD`
el `_build/default` privado y `ROOT` el repositorio. La copia off contiene
**fuentes** ordinarias fijadas, cero BEAM iniciales, sin directorio Gleam ni
compilador en PATH. `clean-off-final-isolation.json` confirma fuentes de
producción iguales al árbol final y ausencia de BEAM/app de capa;
`off-runtime.json` prueba además que no se descubren en la ruta de VM.
Rebar solo reescribe el lock temporal para overrides checkout.

Los fixtures ejecutados incluyen frontera/resultados malformados/versiones
distintas, límite/no admitido, estados siguientes éxito/alternativa/error,
mutación determinista repetida, estado exacto off/cero, contadores operaciones/
bytes, manipulación de recetas, esquema antiguo 2, persistencia/reinicio
normales y separación de fallos de callback. Stubs controlados prueban
contratos de errores; bucle/campañas/códec reales usan Gleam compilado y
Cowlib intacto. Ningún mock cierra la integración.

Se conservan fallos iniciales: pruebas comparaban mapas de configuración en
vez de estado, longitud incorrecta de fixture, suponían intento al 1% en
100 visitas, aridad errónea de traza, esperaban ausencia de contador de rechazo,
comparaban orden de reinicio y trazaban más allá de la barrera. Las corregidas
pasan. El primer diagnóstico de importación recargó dos veces un harness ya
cargado y devolvió `not_purged` (127); se quitó la precarga innecesaria y se
purgó la versión vieja entre campañas detenidas del driver. La repetición
pasa. CLI de producción intacta. Directorios finales incluyen tiempo e ID
único para evitar reutilización.

## Diagnósticos por fracción y coste

Cada porcentaje usa dos semillas explícitas (17,43), mismo motor/backend,
entrada inicial `a=1`, 2000 mutaciones por semilla, una calibración y campaña
separada de calentamiento de 20 ejecuciones. Traza desactivada. Sin callbacks
semánticos/oráculo ni llamadas adicionales. Se permite evolución del corpus.

| Fracción | Intentos | Éxitos | No admitidos | Sin cambios | Bytes generados | Callback µs | Exec/s principales de pared, semillas 17 / 43 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1% | 41 | 11 | 29 | 1 | 335 | 607 | 229.9 / 231.5 |
| 5% | 224 | 80 | 130 | 14 | 4962 | 4357 | 173.5 / 183.0 |
| 10% | 391 | 168 | 194 | 29 | 7952 | 7345 | 199.3 / 179.7 |
| 20% | 794 | 324 | 415 | 55 | 15400 | 14568 | 177.5 / 198.1 |

Los recuentos suman ambas campañas por fila. Límites/errores son cero aquí;
fixtures explícitos cubren esas rutas por separado. Los recuentos por
operación 0..5 están en `fractions/SEED/fractionN/summary.json`; suman los
intentos. El porcentaje es probabilidad de rama, no porcentaje de éxito.
Las 16000 mutaciones medidas terminan sin fallos de capa/infraestructura.
Las unidades estructurales van aparte; sin suma de cobertura semántica.
Una ejecución del 20% termina con menos líneas; no se infiere ventaja de guía.

Medianas de deltas de lotes separados, cinco ensayos, con validación incluida:

| Entrada / operación | Decode µs | Mutate núcleo µs | Encode µs | Proveedor completo µs |
| --- | ---: | ---: | ---: | ---: |
| 8 bytes / añadir 255 | 1.310 | 0.380 | 0.512 | 2.322 |
| 4096 bytes / vaciar primer valor | 363.530 | 52.238 | 165.260 | 488.940 |

Los lotes independientes no forman identidades aditivas de tiempo. Producción
conserva tiempo agregado; el driver ofrece muestras finitas por etapa y ordinales
sin muestreo RNG ni objetivo. El delta mediano desactivado es **+0.941 ns**
para planificador y **−0.657 ns** para worker frente a controles diagnósticos.
El negativo es ruido de medición/disposición de código, no optimización.
export_all temporal queda en VM diagnóstica. No se afirma sobrecoste cero,
aceleración, fracción óptima ni rendimiento final P5.

## Archivos cambiados, decisiones y traspaso

`p3-changes.patch` y `p3-changed-files.json` comparan solo P3 con su árbol
inicial guardado, incluidos fuentes no seguidos. Cambios de producción:
catálogo tipado/comprobación de tamaño y versión, procedencia/contadores del
planificador, receta esquema 3, generador de semillas y un modo de benchmark
fracción cero. Nuevos archivos: pruebas de proveedor, drivers de evidencia
de componentes/importación e informe. Se actualizan contratos, guía y
responsabilidades/decisiones. Sin cambios P3 en compilación/configuración
compartidas, adaptador, corpus, executor, objetivo ni locks.
`preserved-inputs.json` comprueba esos archivos, AGENTS.md y directorio/zip
de prompts; no se elimina corpus ni hay escritura/publicación Git.
Revisión del autor, no independiente ni delegada.

P4: usar contrato intacto de resultados normalizados/características finitas y
admisión serializada; cerrar independientemente selección guiada del corpus,
reintento de persistencia, política histórica visto/reinicio/esquema y
separación oráculo/hallazgos. P3 prueba mutación con feedback desactivado,
no guía completa.

P5: validar predicados completos de reproducción/minimización y conservación
de representantes; después, comparaciones más largas del mismo motor con
semillas/presupuesto/backend controlados, finalización persistente y ensayos
repetidos. Preservar trazas off/cero y fixtures 1/2. El RNG actual reproduce
una mutación concreta; reiniciar corpus es reutilizar/calibrar, no checkpoint
PRNG. Llamadas directas acotadas no garantizan cancelar bloqueos arbitrarios.
Las medidas actuales no justifican caché de producción.
