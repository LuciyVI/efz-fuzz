# P2: integración BEAM nativa opcional

[English](../../../gleam-layer/p2-integration.md) · [Русский](../../ru/gleam-layer/p2-integration.md) · **Español** · [简体中文](../../zh-CN/gleam-layer/p2-integration.md) · [Todos los idiomas](../../README.md)

La aceptación P5 actual está en [p5-validation.md](p5-validation.md).
Las notas de traspaso y estado pendiente describen la fase histórica.

Requisitos **2.0-native**; contrato **v1**, vector `{1,1,1,1,1,1}`.
**Criterio funcional P2: PASS.** Las evidencias están en
`artifacts/gleam-layer/20261008-p2-native/`; `gates.json` indexa comandos,
códigos, hashes de fuentes y fallos conservados. Esto no cierra aceptación
P3/P4, revisión independiente ni benchmarks finales P5.

## Ámbito y responsabilidades

Se leyeron contexto común, referencia/mapa P0 real y contratos P1. HEAD sigue
en `79d76221c6bc5df30b80e6b0de947f3860f4fa4b`; se registraron cambios existentes
antes de editar. Un único responsable posee paquete/API, adaptador/pruebas y
compilación/configuración compartidas. No hubo subagentes ni revisor independiente.

El perfil opcional, paquete, hook EFZ y código P3/P4 ya estaban presentes al
iniciar. P2 añade validación completa de exportaciones al arrancar, diagnósticos
etiquetados acotados, fixtures reales de alcanzabilidad/ciclo de vida BEAM,
driver diagnóstico finito y evidencias. No añade política estructurada de
producción ni guía semántica. Modelo/núcleo, planificador, worker, corpus,
configuración y hook de compilación no cambian respecto a la entrada P2.
Prompts del usuario, ZIP, AGENTS.md y locks conservan hashes. No hubo commits,
push, PR, eliminación de corpus ni cambios globales.

Archivos de esta pasada: `src/efz_gleam_adapter.erl`,
`test/efz_gleam_beam_tests.erl`, `test/efz_gleam_layer_tests.erl` (exportaciones
del stub de fallo), `scripts/gleam_beam_bench.escript`, este informe,
`contracts.md`, `architecture.md`, `user-guide.md`, `baseline.md` (rutas de
herramientas), `agent-plan.md` y `decision-log.md`. El diff acotado es
`p2-changes.patch`; los artefactos generados no son cambios de fuente.

## Herramientas, perfil y artefactos

Herramientas reales: **OTP 27.0 / ERTS 15.0**, **Rebar3 3.25.0**,
**Gleam 1.10.0**, Linux x86_64, `+S 2:2`. Compilador local:
`/tmp/efz-gleam-toolchain/gleam`, SHA-256
`5d86c226aad4fb32e501bc1a6c5c90394e3bd3e462476b1552f4b734e74f7906`.
No requiere instalación/actualización global. `gleam.toml` fija `== 1.10.0`,
target `erlang`; `manifest.toml` contiene cero paquetes. Rebar/Cowboy/Cowlib/
Ranch fijados no cambian; se comprobaron HEAD reales de dependencias
(`toolchain.json`). La raíz runtime principal es
`/home/fbogoslavskii/.asdf/installs/erlang/27.0`. Una compilación desactivada
inicial con PATH mínimo eligió OTP 27.3.4.13 / ERTS 15.2.7.9 del sistema.
Ese éxito adicional se conserva en `system-otp-off/`; la aceptación final off
independiente elige explícitamente bin de OTP 27.0 principal, sin Gleam en
PATH (`toolchain-paths.json`).

`rebar.config` activa `scripts/build_gleam.sh` solo en el perfil `gleam`:

```sh
ERL_FLAGS='+S 2:2' rebar3 compile
GLEAM_BIN=/tmp/efz-gleam-toolchain/gleam ERL_FLAGS='+S 2:2' rebar3 as gleam compile
```

El hook invoca `gleam export erlang-shipment` y copia `efz_qs_model.beam` y
`efz_semantic.app` normalizado a `_build/gleam/lib/efz/ebin/`
(`gleam+test` para EUnit). Los metadatos runtime solo enumeran `efz_qs_model`,
sin dependencias de aplicaciones. El lanzador CLI generado no usado se excluye.
No se necesita ni se observó arranque/carga de aplicación opcional.

La versión 1.10.0 fijada realmente emite tres fuentes Erlang generadas en su
árbol; la integración Rebar solo consume BEAM/.app. No compila ni busca `.erl`
generados. Dos compilaciones archivando entre ellas la caché Gleam privada
produjeron SHA-256 idénticos de modelo y `.app` (`reproducibility.json`). No se
afirma identidad entre rutas absolutas distintas; las rutas de compilador/
depuración pueden cambiar hashes.

Se comprobaron referencias primarias: [externals Gleam](https://gleam.run/documentation/externals/),
[API públicas de cobertura OTP](https://www.erlang.org/doc/apps/kernel/code.html)
y [anuncio del compilador Gleam 1.19](https://gleam.run/news/gleam-doesnt-compile-to-erlang-source-anymore/).
Fuentes OTP 27 instaladas y salida real del compilador fijado establecen esta
aceptación; el anuncio nuevo no prueba artefactos 1.10.0 ni indica actualizar.

## Ruta real y frontera de ejecución

Cadena trazada:

`efz_config:prepare/1 → efz_gleam_adapter:prepare/2 → ciclo de vida/worker EFZ existente`

`efz_qs_target:run/1 → efz_cov_native_public:collect/1 → efz_gleam_adapter:oracle/3`

`→ efz_gleam_adapter:decode/2 → efz_qs_model:decode/2 → efz_qs_model:check/2 → informe EFZ`.

El plugin nativo es el adaptador/dispatcher fijo P1, no otra plataforma.
Exportaciones reales del núcleo compilado: `versions/0`, `decode/2`, `encode/2`,
`normalize/1`, `generate/2`, `mutate/3`, `observe/4`, `check/2`.
`prepare/2` las carga/comprueba una vez, primero las versiones. Una exportación
ausente devuelve
`{gleam_configuration,{gleam_callback_unavailable,Function,Arity}}`.
Los callbacks frecuentes usan `apply(efz_qs_model,Function,Args)` BEAM ordinario,
sin búsqueda de módulo, carga dinámica, arranque ni serialización de transporte.

`hook_trace/0` ejecuta campaña EFZ real de cobertura nativa con fracción cero,
feedback desactivado, una comprobación inline pura y cero iteraciones de
mutación. La traza confirma objetivo → captura principal → adaptador → Gleam
compilado real; callbacks de datos van en el worker existente. El modelo se
busca una vez al arrancar. Resultado: un Pass, cero llamadas extra, sin
contadores estructurados ni estado semántico.
`beam-proofs-complete/hook/trace.json` registra directamente la secuencia
comprobada; `proof.term` conserva el informe sin argumentos de traza.
`runtime-root.json` registra exportaciones/importaciones/disposición reales.
El núcleo importa solo builtins Erlang; su única FFI declarada es
`erlang:bit_size/1`.

El adaptador valida binarios alineados frente a texto/bitstring, etiquetas/
aridad de tuplas, listas propias, enteros, límites/modelos/resultados/
características acotados y etiquetas fijas de error. No hay Dynamic inseguro
ni átomos derivados de entrada. Se prueban vacíos, no UTF8, 4096 bytes exactos,
entrada excesiva, resultados malformados, versiones erróneas y exportaciones
ausentes. No admitido/límite se distingue de error de capa. Los motivos
diagnósticos permanecen acotados; hallazgos del objetivo se guardan antes de
un fallo posterior de capa.

## Comprobaciones ejecutadas

Comandos secuenciales con `ERL_FLAGS='+S 2:2'`. Argv/cwd/env/salida exactos
constan en `.json` correspondientes; los logs conservan resultados completos.

| Comando/comprobación | Salida | Resultado / artefacto |
| --- | --- | --- |
| `rebar3 compile` privado solo de fuentes, bin OTP principal + `/usr/bin:/bin`, GLEAM_BIN inexistente | 0 | `pinned-off-build`: sin directorio/compilador/artefactos Gleam, cero BEAM antes de compilar |
| EUnit off privado: smoke, BEAM/contrato/capa, phase2, módulos de mutación | 0 | **52 superadas**, `pinned-off-tests-final` |
| EUnit off raíz: módulos BEAM/contrato/capa | 0 | **9 superadas**, `off-focused-final` |
| `rebar3 as gleam compile` privado, dos veces | 0 / 0 | `clean-on-first`, `clean-on-second`; hashes idénticos del paquete |
| `rebar3 as gleam compile` raíz | 0 | `on-build`; distribución opcional real |
| EUnit on raíz: BEAM/contrato/capa | 0 | **32 superadas**, `on-focused-final` |
| EUnit módulo BEAM tras mejorar traza de captura/JSON | 0 | **7 superadas**, `beam-trace-json-corrected` |
| `rebar3 as gleam xref` | 0 | `on-xref-final`, sin llamadas runtime no definidas |
| Inspección exportaciones/disposición en VM nueva, privado dos veces y raíz | 0 | `runtime-first`, `runtime-second`, `runtime-root` |
| Campañas nuevas baseline/off/on-runtime-off, semillas 17 y 43 | 0 cada una | 100 candidatos de mutación/modo/semilla; trazas exactas iguales, `complete-raw-equivalence/` comparado con trazas P0 inmutables |
| Drivers diagnósticos dispatcher y BEAM | 0 | `dispatch-overhead`, `beam-overhead-complete`; muestras abajo |

Las compilaciones privadas usan copias de fuentes de dependencias
**ordinarias** fijadas, no BEAM en caché, mediante `_checkouts` de Rebar.
Solo se reescribe el lock temporal; los locks del repositorio no cambian.
No se afirma descarga nueva de dependencias de red. `prepare_scratch.py` /
`prepare_on.py` y JSON de preparación registran rutas y hashes. Off sigue
físicamente sin paquete/artefactos después de comprobar todo
(`clean-off-final-isolation.json`). El lanzador C ajeno existente compila
normalmente; no es un puente Gleam.

Runtime off en compilación on se traza por separado en el fixture de contrato:
cero callbacks de datos y estado semántico. Las campañas nuevas de bytes tampoco
cargan modelo/aplicación ni contadores. Los hashes de candidatos/etapas/padres
coinciden con P0 y off limpio; `determinism/0` y `fallback_rng/0` siguen cubriendo
igualdad explícita de RNG. Pasan semántica de executor con términos y pruebas
ordinarias de mutación.

`repeated_calls/0` realiza 1000 pares decode/encode sin cambiar diccionario de
proceso; después dos campañas independientes con presupuestos nuevos de
oráculo y limpieza de propietarios. Los fixtures de fallo verifican que
callbacks malformados/que lanzan mantienen vivo el fuzzer controlador según
la política definida, conservan un hallazgo anterior y permiten otra campaña
sana. Los mocks solo cierran esos contratos de errores.

Fallos intermedios conservados: aviso de variable sombreada del stub (salida 1),
`fixtures/` temporal ausente que canceló preparación antigua (1), y trazar
`collect_profiled/1` cuando la campaña sin perfil llamaba `collect/1` (1).
Tanto el stub como las comprensiones JSON tuvieron variables sombreadas;
warnings-as-errors las rechazó antes de las pruebas; las ejecuciones
corregidas pasan. Un helper opcional de resumen en VM nueva rechazó átomos
desconocidos con ETF seguro; se abandonó sin decodificación insegura y el
fixture escribe JSON directamente. `unused-proof-summary.json` indica que
ese helper no es criterio de aceptación. Corregir no convierte comandos
fallidos en exitosos. Las repeticiones finales anteriores pasan. Las pruebas
canceladas y la aserción de traza incorrecta no cuentan como evidencia.

## Observabilidad y costes medidos

Los informes de producción conservan contadores y tiempos agregados de
oráculo/observador/estructurado/resultados. Los contadores detallados de
llamadas/motivos/bytes y tiempos muestreados son solo diagnósticos, recogidos
por `gleam_beam_bench.escript`, sin estado de producción ni extracciones RNG.
Sus 48 llamadas reales al adaptador dan 16 éxitos, 8 no admitidos, 8 límites,
16 rechazos de frontera y cero excepciones de capa; 32 decode / 16 encode,
32912 bytes binarios de entrada y 64 de salida codificada. Seis muestras
temporales seleccionan ordinalmente cada séptima llamada, con máximo seis.
No se registran cargas completas; pruebas acotadas aparte ejercitan excepciones.

Cinco ensayos alternos secuenciales: dispatcher usa 1M llamadas/ensayo,
componentes BEAM pequeños 20K y decode de entrada máxima 500. Medianas con
control restado:

| Componente | Mediana | Rango de cinco ensayos |
| --- | --- | --- |
| Incremento de dispatcher de plan desactivado | 0.546 ns | 0.189–0.622 ns |
| Incremento de dispatcher de worker desactivado | −0.282 ns | −1.958–−0.022 ns |
| Validación de frontera entrada + modelo, entrada de 8 bytes | 26.7 ns | 25.85–27.05 ns |
| Decode núcleo real / adaptador | 667.85 / 735.65 ns | 660.0–686.2 / 729.35–766.9 ns |
| Encode núcleo real / adaptador | 193.6 / 236.5 ns | 184.85–196.65 / 235.8–248.0 ns |
| Oráculo puro del adaptador | 882.85 ns | 872.75–895.45 ns |
| Decode núcleo / adaptador, entrada de 4096 bytes | 171.974 / 173.088 μs | 170.902–173.252 / 172.176–174.044 μs |

El delta negativo y el diminuto de comprobación directa quedan por debajo de
una interpretación fiable de coste incremental; no prueban aceleración ni
sobrecoste cero. Los componentes se miden independientemente; restar medianas
no da un desglose aditivo exacto. Las muestras diagnósticas incluyen coste del
reloj y se ejecutan aparte del lote. export_all temporal solo en VM diagnósticas.
No existe sobrecoste de worker/mensajes de capa. No se afirma ventaja de
rendimiento de campaña.

## Límites y traspaso

Los callbacks de producción siguen siendo funciones BEAM directas acotadas,
sin workers semánticos extra, cola, caché, ETS, NIF nuevo, puerto, socket/RPC,
transporte JSON/ETF, motor externo, destino JavaScript ni parche OTP.
Aislamiento y serialización de cobertura de VM existentes no cambian;
llamadas concurrentes no gestionadas siguen fuera del contrato. No hay
protocolo de respuestas asíncronas.

El fixture bloqueado mata un worker Erlang monitorizado **solo de prueba**
tras 30 ms y confirma DOWN/limpieza. No prueba cancelación de callbacks
arbitrarios directos/nativos ni añade mecanismo de worker/plazo en producción.
Un oráculo costoso futuro requiere aprobar por separado un contrato EFZ
acotado de supervisión/ejecución.

P3 debe auditar proveedor tipado, preparación de semillas, recetas y
transiciones RNG existentes sin cambiar silenciosamente representación.
P4 debe auditar consumidor/admisión y canal separado de hallazgos frente a P1.
P5 debe cerrar reproducción/minimización/regresión y benchmarks finales del
mismo motor. No se afirma completar todo el paquete ni revisión independiente.
