# P5: aceptación final de reproducción, regresión y mismo motor

[English](../../../gleam-layer/p5-validation.md) · [Русский](../../ru/gleam-layer/p5-validation.md) · **Español** · [简体中文](../../zh-CN/gleam-layer/p5-validation.md) · [Todos los idiomas](../../README.md)

Este informe sustituye las notas históricas de traspaso P5 de P1–P4 y el
informe universal-validation del 10 de octubre. El criterio cubre el flujo
Linux síncrono y acotado admitido. Superioridad de rendimiento y descubrimiento
de una vulnerabilidad independiente son preguntas separadas, no condiciones
para completar la aceptación de implementación.

## Cambios durante la aceptación final

- La carga segura del esquema 1 registra ahora el vocabulario fijo antiguo
  antes de decodificar ETF. `[safe]` sigue activado; los artefactos no pueden
  introducir átomos ni seleccionar módulos ejecutables.
- La reproducción antigua requiere `.input` original y `.semantic` con
  checksum. `.term` diagnóstico local de VM es una ruta opcional, no requisito.
- El diagnóstico de escript no disponible de la CLI genérica usa el formato
  correcto. Pruebas de subprocesos cubren reproducción genérica, minimización,
  presupuestos exactos, argumentos no válidos, entrada corrupta, negativa a
  reemplazar salida existente, reenvío y reproducción nativa antigua exitosa
  sin `.term` diagnóstico.
- Los drivers comparativos aceptan varias semillas/repeticiones RNG, miden
  admisión persistente al corpus y registran identidades fuente/runtime/objetivo.
- Los recuentos con estado se verifican mediante resultados reales del
  objetivo protegido en otra VM nueva, fuera del tiempo de campaña. Las
  operaciones completadas igualan la longitud de traza devuelta. Rechazar
  paquete es distinto de aceptar escenario; una ejecución principal de
  entrada no se etiqueta como operación de biblioteca.

## Reproducción

Use OTP 27, Rebar3 3.25.0, Gleam 1.10.0 y `ERL_FLAGS='+S 2:2'`.
Ejecute compilación/pruebas/CT/xref/Dialyzer predeterminados y opcionales antes
de medir. Prepare la dependencia XML-RPC fijada según
`examples/xmlrpc/README.md`. EUnit opcional completo necesita su directorio
ebin en la ruta de código.

Prepare dos archivos de fuentes sin modificar el checkout activo: main en
`79d76221c6bc5df30b80e6b0de947f3860f4fa4b` (compilación predeterminada) y la
capa QS histórica en `e4c0244c403d74b041df7e0e2f0dd4465a977453` (Gleam).
Compílelos con las mismas herramientas y commits fijados. Cada tarea cloud
ya tiene un checkout aislado; no hace falta Git worktree.

```sh
python3 scripts/run_semantic_bench.py --out /workspace/scratch/p5-semantic-verified
python3 scripts/run_qs_semantic_bench.py \
  --baseline /workspace/scratch/p5-legacy-baseline/_build/gleam \
  --raw-baseline /workspace/scratch/p5-main-baseline/_build/default \
  --out /workspace/scratch/p5-qs-verified
python3 scripts/verify_p5_evidence.py \
  /workspace/scratch/p5-semantic-verified /workspace/scratch/p5-qs-verified
```

Cada directorio de salida debe ser nuevo. Preparación, campañas y diagnósticos
de callbacks/con estado se ejecutan secuencialmente. Ninguna suite ni
compilación se solapa con la serie medida. El criterio canónico usa tres
semillas (17, 29, 43), dos repeticiones, 500 mutaciones, VM/corpus nuevos,
dos schedulers CPU y tiempo límite fijo del objetivo.
QS usa un artefacto nativo compartido entre todos los motores/modos. Su campaña
medida sigue un calentamiento separado de 20 mutaciones, con corpus nuevo
para medir. La serie API/XML/con estado no calienta la campaña.

El tiempo de campaña incluye preparación/calibración y escrituras persistentes
de admisión; el tiempo de VM/driver se registra aparte. El diagnóstico con
estado fuera del bucle incluye executor y preparación/limpieza del escenario;
no afirma latencia aislada por operación.

Estado final: **P5 PASS, 13 de octubre de 2026.** Los intentos preliminares se
conservan fuera del checkout y no se usan como evidencia final PASS.

## Ámbito de aceptación y revisión

La revisión final volvió a comprobar frontera de callbacks, entradas originales
de referencia, selección explícita de adaptador/objetivo, presupuestos finitos,
neutralidad RNG desactivada, neutralidad del observador, identidad/recalibración
persistente y conservación del predicado. Las pruebas nuevas reproducen dos
fallos antiguos fuera del bucle, en lugar de confiar en notas PASS previas del
autor. No se usó revisor separado ni subagente, y no se afirma auditoría externa
independiente.

Cancelación arbitraria de callbacks nativos, llamadas paralelas no gestionadas
al objetivo, recursos externos sin harness propio, entradas globalmente
mínimas, puntos de control PRNG exactos y oráculos diferidos quedan fuera de
v1. Son exclusiones documentadas, no comprobaciones P5 sin ejecutar.

## Comprobaciones finales ejecutadas

| Comprobación | Resultado |
| --- | --- |
| Compilación predeterminada / EUnit | PASS / 308 superadas |
| Compilación Gleam / EUnit completo con XML-RPC fijado | PASS / 374 superadas |
| Common Test | 3 superadas |
| xref / Dialyzer predeterminados y Gleam | PASS en ambas compilaciones |
| CLI genérica y nativa antigua en VM nueva | 2 superadas en suite opcional; ruta genérica también en la predeterminada |
| Campañas API/XML/con estado desactivadas/activadas secuenciales | 36/36 completadas, 500 mutaciones cada una |
| QS main / antiguo / desactivado / semillas / estructurado / observación / guiado explícito / oráculo | 48/48 completadas, 500 mutaciones cada una |
| Equivalencia de traza original desactivada y cobertura estructural con main | 6/6 pares semilla/repetición |
| Neutralidad de traza de mutaciones en solo observación | 6/6 pares semilla/repetición |
| Diagnósticos de carga real con estado | 12/12 completados, 501 ejecuciones protegidas de entrada cada uno |
| Hashes de fuentes / presupuestos / sin errores de infraestructura / corpus persistente presente | PASS |

La serie comparativa realizó 42.000 mutaciones medidas. Cada campaña medida
usó un corpus persistente nuevo. La regresión completa existente verifica
aparte restauración/recalibración, rechazo de identidad distinta, admisión
solo semántica y conservación de representantes. Persistir corpus reutiliza
entradas, no es un punto de control PRNG.

### Resumen de mediciones

Cada fila tiene seis muestras (tres semillas RNG, dos repeticiones). Las tasas
incluyen calibración y admisión medidas. Son mediciones finitas, no afirmaciones
de significación ni umbrales de superioridad de rendimiento.

| Serie/modo | Mediana de ejecuciones principales/s | Entradas solo semánticas, rango de muestras |
| --- | ---: | ---: |
| QS baseline | 398.4 | 0–0 |
| QS old | 388.7 | 0–1 |
| QS new | 380.3 | 1–1 |
| QS off | 405.0 | 0–0 |
| QS seeds | 412.3 | 0–0 |
| QS structured | 385.9 | 0–0 |
| QS observation | 374.8 | 0–0 |
| QS oracle | 377.9 | 0–1 |
| API generic-off | 388.7 | 0–0 |
| API generic-on | 390.3 | 1–1 |
| API xmlrpc-off | 320.0 | 0–0 |
| API xmlrpc-on | 303.0 | 3–4 |
| API stateful-off | 382.7 | 0–0 |
| API stateful-on | 390.8 | 1–1 |

La ruta desactivada conserva comportamiento determinista de bytes y no carga
el modelo Gleam. Los modos activados consiguen admisiones solo semánticas
reales; esto confirma integración, no detección independiente de defectos.
Las muestras no establecen aceleración, fracción estructurada óptima ni
sobrecoste nulo.

### Operaciones reales con estado

Estos recuentos provienen de ejecuciones protegidas completadas de la carga
de paquetes registrada en VM diagnósticas separadas. Coinciden con la
reconstrucción canónica de paquetes. El tiempo del escenario incluye executor
y preparación/limpieza de hijos; no es un benchmark aislado de latencia de
llamadas gen_server.

| Modo | Escenarios aceptados, seis cargas | Operaciones completadas de biblioteca | Paquetes rechazados |
| --- | ---: | ---: | ---: |
| off | 12 | 36 | 2994 |
| on | 178 | 562 | 2828 |

### Ensayos controlados de detección

Tres ejecuciones adicionales en VM nueva, de 1.000 mutaciones, usaron
`efz_qs_defect_target` explícitamente artificial, bytes iniciales `abc=1`
idénticos, diccionario existente `bug` y semillas 17, 29 y 43. Las semillas
17 y 29 detectaron el fallo de propiedad inyectado; 43 terminó sin hallazgo
(censurado al agotar presupuesto). Todas terminaron sin errores de
infraestructura. La prueba CLI antigua separada reproduce y minimiza esa
propiedad en otra VM. No se presenta ningún resultado como vulnerabilidad
nueva ni superioridad de detección en una biblioteca real.

## Evidencias y conclusión

[validation.json](../../../gleam-layer/p5-evidence/validation.json) registra herramientas, hashes de
fuentes/logs, hashes de artefactos originales y resultados de detección.
[gates.json](../../../gleam-layer/p5-evidence/gates.json) registra comprobaciones de presupuesto/
traza/estado y resúmenes finales. Los manifiestos de ambas series se conservan
junto a ellos. Los logs completos, entradas, recetas, informes y corpus
persistentes permanecen en las raíces de evidencia listadas en validation.json;
no se incluyen BEAM generados en commits.

Todos los puntos P5 ejecutables antes abiertos están cerrados para el contrato
indicado. No queda ningún comando P5 obligatorio pendiente. La revisión de
merge puede usar comprobaciones conservadas e instrucciones de reproducción;
no se afirma superioridad de rendimiento.
