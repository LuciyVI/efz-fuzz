# P4: oráculo y realimentación del corpus — PASS

[English](../../../gleam-layer/p4-feedback.md) · [Русский](../../ru/gleam-layer/p4-feedback.md) · **Español** · [简体中文](../../zh-CN/gleam-layer/p4-feedback.md) · [Todos los idiomas](../../README.md)

La aceptación P5 actual está en [p5-validation.md](p5-validation.md).
Las notas de traspaso y estado pendiente describen la fase histórica.

Requisitos **2.0-native**; vector contrato/modelo/códec/mutador/característica/
propiedad **{1,1,1,1,1,1}**. Paquete **1.1.0**, generador fuera del bucle **2**,
esquemas **1/2/3** intactos. Fecha: 2026-10-08. Herramientas: OTP **27.0** /
ERTS **15.0**, Rebar3 **3.25.0**, Gleam **1.10.0**. Locks intactos.

Evidencias: `artifacts/gleam-layer/20261008-p4-feedback/`; consulte `gates.json`,
`proofs-complete/proofs.json`, nueve pruebas originales `.term` y
`p4-changes.patch`. HEAD sigue en `79d76221c6bc5df30b80e6b0de947f3860f4fa4b`.
Se conservaron HEAD inicial, parches del árbol/índice y 65 huellas de archivos.
Se leyeron [requisitos comunes](../../../../efz_gleam_native_subagent_prompts/01_COMMON_CONTEXT.txt),
[ruta P0](execution-path.md), [contrato P1](contracts.md),
[P2](p2-integration.md) y [P3](p3-provider.md) antes de cambiar.

El checkout inicial ya tenía observador/oráculo puros y selección guiada de
worker/corpus. Esta pasada verifica la ruta completa, refuerza la frontera
exacta de metadatos y añade una consulta de representantes del corpus de solo
lectura. El responsable posee cambios y fixtures; no se atribuyen subagentes
ni revisión independiente. Sin planificador, corpus, motor, puente nativo ni
instrumentación nuevos.

## Mapa real de fuentes

| Responsabilidad | Archivo:función real |
| --- | --- |
| Ejecución completada / captura inmutable | `src/efz_guardian.erl:finish/2`, `src/efz_executor.erl:run_pinned/4` |
| Predicado estructural existente | `src/efz_feedback.erl:evaluate/3`, `native_success/5` |
| Resultado completado → callbacks | `src/efz_worker.erl:execute_result/6`, `semantic_callbacks/4`, `semantic_observe/5`, `semantic_oracle/5` |
| Frontera BEAM directa comprobada | `src/efz_gleam_adapter.erl:observe/3`, `summary/1`, `oracle/3`, `oracle_model/3` |
| Callbacks tipados compilados reales | `gleam/efz_semantic/src/efz_qs_model.gleam`; BEAM `efz_qs_model:observe/4`, `check/2` |
| Admisión actual / propietario serial | `src/efz_worker.erl:retain_layer/4`, `src/efz_corpus.erl:semantic_admission/6`, `add_checked/3` |
| Persistencia / restauración compatible | `src/efz_corpus_store.erl:save/4`, `restore/3`; `src/efz_corpus.erl:init/1` y calibración del worker |
| Representantes activos / reducción conservadora | `src/efz_corpus.erl:semantic_representatives/0`; `src/efz_semantic.erl:representatives/1`, `cover/1` |
| Selección existente de padres | `src/efz_corpus.erl:select/0`, `mutation_entries/0`; `src/efz_mutation_plan.erl:next/2`, `visit/2` |
| Hallazgo / huella | `src/efz_worker.erl:record_failure/4`, `src/efz_crash.erl:signature/2`, `save/4` |
| Reproducción / minimización de propiedad desde bytes | `src/efz_semantic_replay.erl:run/5`, `minimize/6`, `src/efz_recipe.erl:execute/5` existente |
| Parser real intacto | `examples/query_string/efz_qs_target.erl:run/1` → `cow_qs:parse_qs/1` fijado |

## Contrato de propiedad y resultados

**query_model_agreement / 1** compara campos ordenados del parser real
completado con el decodificador separado de consultas admitidas.
Precondiciones: binario ≤4096 bytes, forma canónica admitida, ≤32 campos
explícitos con nombre no vacío, nombre/valor ≤128 bytes, sin escape
incorrecto deliberado. Bytes arbitrarios se aceptan como bytes. Es propiedad
de resultado esperado, no oráculo diferencial independiente ni
`decode(encode(model))`.

| Resultado | Predicado / política |
| --- | --- |
| Pass | `{ok,{accepted,Pairs}}` completado coincide con campos binarios ordenados admitidos |
| Fail | Resultado aceptado distinto o parser rechaza consulta canónica admitida |
| Inconclusive | Consulta no admitida, límite modelo/bytes, excepción/tiempo límite o presupuesto agotado; conserva motivo |
| expected_rejection | Errores enumerados del harness devuelven `rejected`; por sí solos no son hallazgos |
| target_exception / target_timeout | Clasificación existente de hallazgos y limpieza del ciclo de vida |
| semantic_layer_error | Diagnóstico/contador acotado; detener como fallo de infraestructura, nunca alternativa ordinaria ni defecto objetivo |
| infrastructure_error | Política existente de fallo de cobertura/ciclo de vida/configuración/almacenamiento |

El predicado minimizable es la misma propiedad versionada devolviendo **Fail**
para objetivo/build intactos. No admitido, timeout e Inconclusive no conservan
fallo. Las huellas usan política EFZ existente de clase/categoría/frames;
ID/versión, builds y resultado original permanecen en el auxiliar semántico.
Los hallazgos del objetivo se guardan antes del observador, así que un fallo
posterior de capa no los borra. Los fallos de oráculo entran independientemente
en el mismo pipeline. EFZ continúa ante hallazgos y se detiene ante
infraestructura; `crash_policy` controla huellas/representantes, no otra
opción de parada.

## Vocabulario semántico finito

Feature = `{<<"cow_qs">>,1,Id}`. Los IDs son tuplas exactas ordenadas,
sin hashes, colisiones probabilísticas, átomos dinámicos, cadenas ilimitadas
ni identidades runtime. Las unidades estructurales siguen siendo nativas
módulo/build/línea del esquema existente.

| IDs | Significado |
| --- | --- |
| 0 / 1 / 2 / 3 | Aceptado / rechazo esperado / tiempo límite / excepción del objetivo |
| 4 / 5 / 6 / 7 | Recuento de pares aceptados: 0 / 1 / 2 / ≥3 |
| 8 / 9 | Valor binario vacío presente / ausente |
| 10 / 11 | Byte ≥128 en nombre/valor devuelto presente / ausente |

Una ejecución aceptada emite cuatro características; las demás una. El
observador resume el resultado completado sin decodificar entrada ni ejecutar
objetivo. La validación acepta listas propias de hasta 100 pares, componentes
binarios ≤4096 bytes y representación `true` de Cowlib para nombre sin valor.
Cowlib fijado limita claves a 100. Salida malformada es error de capa. Entrada
excesiva cuenta como observación omitida sin inferir características.

CurrentFeatures es lista local nueva; SeenSemantic pertenece al corpus.
Seen y cada conjunto combinado tienen hasta 12 IDs. En esta VM de 64 bits,
los tamaños planos medidos son 288 bytes para cuatro características,
864 para 12 y 896 para mapa derivado de 12 representantes. Son tamaños
conservadores de términos, no memoria total ni tamaño del corpus. Sin caché,
cola, ETS semántico ni índice activo persistente. Los metadatos crecen con
el corpus existente; no se introduce límite global nuevo de capacidad.

## Admisión, persistencia y retención

Para resultados principales exitosos (incluido `{ok,rejected}`), conservar
motivo estructural y añadir:

```text
SemanticNew = CurrentFeatures minus corpus.semantic_seen
KeepNewInput = ExistingStructuralKeep OR nonempty(SemanticNew)
```

Semillas/calibración y otros motivos existentes permanecen. Excepciones y
tiempos límite usan hallazgos; sus IDs no admiten ejecuciones fallidas, como
P1 acordó. Desactivado y solo observación usan admisión ordinaria.
Solo observación no guarda historial visto; guiado lo inicia/reconstruye en
el corpus al arrancar.

El gen_server existente serializa novedad, persistencia y confirmación.
Bytes/metadatos nuevos se guardan antes de añadir entradas/visto.
Fallo/rechazo deja visto intacto; sin almacenamiento, la inserción en memoria
es confirmación. Anotaciones existentes unen evidencia sin duplicar bytes ni
perder motivo original. Entradas solo semánticas usan almacenamiento,
`select/0` y `mutation_entries/0` normales; energía intacta.

Reiniciar valida versiones EFZC/registro/espacio y calibra explícitamente
entradas actuales para reconstruir anotaciones/visto antes de mutar.
Se informan como calibraciones, aparte de mutaciones. Registros EFZC 1/2 y
semántico 3 siguen admitidos. Esquemas incompatibles fallan al restaurar.
Ningún índice global persistido sobrevive a borrado manual entre campañas;
la recalibración refleja representantes restantes.

El corpus online solo añade entradas. `cover/1` fuera del bucle conserva
uniones registradas de sondas/recuentos y todos los representantes semánticos,
protegiendo iniciales/no calibradas. Pruebas aplican el subconjunto a un
almacén **nuevo** y lo reinician; el original se preserva. Sin eliminación
online/transacción de referencias ni reductor global óptimo. Editar archivos
durante campaña no se admite. La consulta de solo lectura deriva un ID de
trabajo por característica y verifica representación de todas las vistas.

## Intervalo de cobertura y oráculo

`reset → objetivo → barreras de finalización/limpieza del árbol controlado → captura sellada
→ observador/oráculo puro → tratamiento de admisión/hallazgos`.

Los contadores nativos son por módulo. El guardian existente rechaza ejecución
local concurrente con `runner_busy`, recoge descendientes, vacía barreras de
traza y publica solo tras limpiar; el llamador espera DOWN. Pruebas confirman
hijo retrasado muerto, contadores invariables después del plazo y cobertura
base en la siguiente iteración. Solo `cow_qs` está seleccionado; helpers/
Gleam/oráculo no añaden unidades. Llamadas no gestionadas en la misma VM
quedan fuera del contrato.

El oráculo de producción es directo, acotado, puro y añade **cero** ejecuciones.
Presupuesto predeterminado 64, máximo 10000, incluida calibración. Comprueba
cada ejecución hasta agotar, independientemente de novedad; el resto es
Inconclusive/budget explícito y cuenta como omitido. Este prefijo determinista
no afirma validar todas las entradas ni muestreo estadístico. Sin oráculo
costoso/diferido, protocolo worker, cola o reproducción paralela; deferred
falla al arrancar. Reproducción/minimización explícitas fuera del bucle usan
intervalos EFZ serializados separados e informan ejecuciones. No se afirma
cancelación nativa.

## Evidencias de aceptación ejecutadas

| Comprobación | Comandos / resultado (todas las salidas listadas 0) |
| --- | --- |
| Regresión on completa | `rebar3 as gleam eunit`: **313** pruebas; `full-on-tests.json` |
| Prueba nativa final específica | `rebar3 as gleam eunit --module=efz_gleam_feedback_tests`: **11**; `snapshot-test-build.json` |
| Pruebas originales finales exportadas | `export_proofs.escript`: repite **11** en su VM, decodifica seguro/copia **9** pruebas; `export-proofs-final.json` |
| Off limpio sin compilador | Privado solo fuentes `/tmp/efz-p4-off-vg8psokv`, inicialmente sin paquete/compilador/BEAM; `rebar3 compile` y EUnit específico **55**, `clean-off-compile.json`, `clean-off-tests-r2.json` |
| Runtime off / compatibilidad de términos | `off_check.escript`: sin Gleam/helper/aplicación/estado, pasan campaña ordinaria y objetivo con términos; `off-runtime-check-r2.json` |
| Otros backends / llamadas estáticas | `rebar3 ct`: **3**; `rebar3 as gleam xref`; `ct-regression.json`, `on-xref.json` |
| Neutralidad de observación | Dos campañas staged reales, semilla 17, fracción 0, **200** mutaciones: hash/etapa/padre idénticos, mismo corpus/cobertura; `observation-sequence-proof.json` |
| CLI de hallazgos | `scripts/gleam_replay.escript … efz_qs_defect_target 64 …`: reproducido en **1** ejecución, minimizado a `bug=` en **34**; `finding-cli-replay.json` |

En A, entradas `613d31` (`a=1`) y `613dff` (`a=` + byte 255) tienen exactamente
las mismas **14** unidades nativas. Las **9** capturas principales selladas
trazadas son `67041a2c00000300000000`, con mismas unidades decodificadas.
Características respectivas `[0,5,9,11]` y `[0,5,9,10]`. Guiado admite segunda
entrada como `new_semantic`, `new_probes` vacío y corpus 2. Los padres reales
del planificador son `[1,2,1,1,2,1,1,1]`. Off/solo observación mantienen 1.
Repetir no acredita de nuevo. La traza confirma nueve observe Gleam compilados
y cero decode; el mutador controlado de bytes se limita al fixture.

B prueba fallo/reintento de escritura, 1000 reintentos duplicados, dos llamadores
simultáneos al corpus que reciben un solo crédito, reconstrucción/esquema
incompatible al arrancar, reinicio de subconjunto conservador y recuperación
tras quitar entre campañas. Otro fixture hace 10000 intentos de admisión,
alcanza 12 IDs vistos y solo ocho entradas; ejecuta cero objetivos y no prueba
campaña/detección.

C prueba cobertura solo objetivo, intervalos siguientes intactos y limpieza
de hijo retrasado. Reproducción explícita separada no cambia la captura
principal ya devuelta. No se afirma PASS paralelo de cobertura nativa.

D usa `efz_qs_defect_target` claramente artificial: añadir NUL a valor `bug`.
Una calibración y dos mutaciones normales repetidas producen tres fallos del
oráculo, un grupo, cero descubrimientos de corpus y características intactas.
Se guardan bytes originales `bug=11&x=2`, propiedad/versión y metadatos build.
Los artefactos copiados del hallazgo/nativos permiten reproducción CLI real
exitosa. Prueba conexión; no se afirma defecto Cowlib real ni detección
independiente.

## Contadores y muestras de coste

`gleam_stats` informa llamadas/omisiones/us de observador, comprobaciones/pass/
fail/inconclusive/omisiones/us de oráculo, rechazo esperado, timeout/excepción
y errores de capa. El oráculo informa cero ejecuciones extra. Fixture de
presupuesto: siete ejecuciones principales/observaciones, dos Pass incluidas
entradas estructuralmente equivalentes y cinco omisiones explícitas. Los
hallazgos se tratan sin depender de admisión. EFZ no tiene opción de capacidad
de corpus; una condición separada de lleno no es aplicable.

Sonda finita de componentes: 10000 repeticiones, resultados derivados del
modelo, sin objetivo ni traza de producción. Medias en microsegundos
(`component-costs.json`):

| Bytes de entrada / campos | Observador | Oráculo puro | Diferencia de conjuntos exacta | Índice de 12 características fuera del bucle |
| --- | ---: | ---: | ---: | ---: |
| 3 / 1 | 0.28 | 1.34 | 0.46 | 3.31 |
| 4096 / 16 | 14.71 | 304.70 | 0.50 | 3.44 |

Cuatro campañas breves reales del mismo motor usan semilla 17, fracción 10%,
seis semillas tipadas, 500 mutaciones cada una y traza desactivada:

| Modo | Llamadas principales | Observador | Comprobaciones / omitidas de oráculo | Corpus / solo semánticas | Unidades estructurales |
| --- | ---: | ---: | ---: | ---: | ---: |
| Estructurado, feedback desactivado | 506 | 0 | 0 / 0 | 14 / 0 | 48 |
| Solo observación | 506 | 506 | 0 / 0 | 14 / 0 | 48 |
| Guiado | 506 | 506 | 0 / 0 | 15 / 1 | 48 |
| Guiado + oráculo inline | 506 | 506 | 64 / 442 | 15 / 1 | 48 |

Hubo 19 Pass y 45 Inconclusive, sin fallos. Todas terminaron sin errores de
infraestructura; rechazo del objetivo se cuenta aparte. Tasas individuales
(177–226 ejecuciones/s) son muestras breves, no superioridad ni óptimo.
Sobrecoste worker/mensajes no aplica a callbacks directos; el coste existente
de ejecución queda fuera de muestras por componente.

## Diff, límites de revisión y traspaso a P5

Cambios de producción: `src/efz_semantic.erl` y `src/efz_corpus.erl`, para
validación exacta y derivación/consulta fuera del bucle. Nuevos archivos:
tres módulos de pruebas/fixtures, `scripts/gleam_feedback_probe.escript` y
este informe. Dos modos explícitos amplían el driver de benchmark; contrato,
guía, responsabilidades y decisiones se actualizan. `p4-changed-files.json`
y `p4-changes.patch` distinguen los cambios del árbol previamente modificado.
AGENTS, archivo/textos de prompts, objetivo/modelo/paquete, locks, cobertura,
mutación, worker, hallazgos y reproducción quedan intactos en esta pasada.

Se archivan intentos fallidos: aserción de estadísticas sensible al tiempo,
nombres de módulos inexistentes, exportación segura antes de cargar átomos
runtime y configuración diagnóstica none/manual no válida. La primera prueba
de traza comparó listas vacías; la corregida usa bits nativos sellados/unidades
no vacías. La preparación solo fuentes chocó inicialmente con su archivo de
prueba; repetir conserva separados comando y evidencia fuente. Ninguno de
esos intentos se usa como aceptación final.

P5 debe revisar independientemente contrato/código, ejecutar regresión final
entre fases y experimentos reales de detección, y medir varias semillas del
mismo motor incluyendo persistencia final. Mantener valores conservadores y
representantes originales. Checkpoint exacto, poda online, oráculos diferidos
y ejecución paralela no gestionada siguen sin admitirse. No hubo push/PR/
commit; P4 PASS no cierra P5 ni todos los prompts de orquestación.
