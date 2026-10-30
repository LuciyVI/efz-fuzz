# Registro de rendimiento y cierre de Phase 2.1

[English](../../phase2.1-performance.md) · [Русский](../ru/phase2.1-performance.md) · **Español** · [简体中文](../zh-CN/phase2.1-performance.md) · [Todos los idiomas](../README.md)

Cerrada localmente el 2026-09-09. El valor predeterminado es **validación preparada
con el hook ETS exacto original**. Membership sigue opcional. Preparar mejora
las ejecuciones/campañas completas medidas de parser y cobertura dispersa;
membership ayuda con hits repetidos pero penaliza primeras observaciones y no
ofrece ventaja fiable en campañas dispersas. No se cambiaron sondas, timeouts,
identidades ni reglas de retención para obtener estos resultados.

## Entorno, línea base y procedencia

El repositorio es `efz/` en el espacio suministrado. No se encontraron `AGENTS.md`
aplicable ni configuración de formato/lint. El árbol ya tenía modificaciones,
con la mayoría de fuentes Phase 1/2 sin seguimiento. Comparar contra el snapshot
Phase 2 preservado `/tmp/efz-phase21-baseline` identifica los cambios de esta
fase; Git status solo no puede distinguirlos. No hubo clean/reset, staging,
commit, cambios de identidad/remoto ni push.

Al empezar Phase 2.1 pasaban compilación, 24 pruebas EUnit, tres Common Test,
Dialyzer y xref. La implementación interrumpida pasó después 36 EUnit y las
mismas restantes comprobaciones. El cierre añadió dos pruebas específicas y
corrigió un defecto de carga de artefactos; la comprobación final pasa
**38 pruebas EUnit**. No hubo bloqueos ambientales. Los resultados históricos
Phase 2 siguen en [phase2-validation.md](phase2-validation.md); son observaciones,
no constantes de prueba.

La medición final sin perfilador y todas las VM de memoria registraron:

* OTP 27.0, ERTS 15.0; Rebar3 3.25.0; JIT, palabras de 8 bytes.
* Ubuntu 24.04.4 LTS, Linux, `x86_64-pc-linux-gnu`; Intel Core i7-1260P.
* `ERL_FLAGS='+S 4:4'`: cuatro schedulers, cuatro activos, cuatro dirty CPU schedulers.
* Fixtures compilados con `compile:noenv_file/2`, `debug_info`,
  `warnings_as_errors`; instrumentación estricta, módulos permitidos explícitos,
  `source_root => "."`, directorios instrumentados separados. Sin perfilado
  durante rendimiento; sin NIF propio, runner por puertos ni motor externo.

Se repitió realmente el benchmark original de bucle estrecho al empezar Phase 2.1:
siete muestras calentadas de 200,000 iteraciones dieron medianas
**766 / 2,218 / 33,407 us** para ordinario/inactivo/activo. Difiere de los valores
anteriores 518 / 5,315 / 67,209 us; no reproduce independientemente esas cifras
exactas. Las muestras se archivan; no se registraron schedulers en ese artefacto,
por lo que no se combina con la comparación de cuatro schedulers.
El ejemplo original también completó 500 mutaciones, una calibración,
cuatro descubrimientos, 494 rechazos y dos fallos, uno único.

Los artefactos autoritativos de la ejecución completa son:

| Grupo | Contenido y evidencia de finalización | Aplicabilidad |
|---|---|---|
| `_build/performance-final/{environment,hooks,executor,campaign}.term` y `.txt`, `summary.txt` | 36 filas hook, 12 ejecutor, 24 campaña; cinco muestras cada una. El comando completo salió 0; el progreso termina tras guardar los seis casos de campaña. La auditoría recalcula medianas/mínimos/máximos y compara objetos canónicos antes de compactarlos. | Hooks, ejecutor, feedback y tiempo de mutación actuales. Las muestras históricas de inicio se reemplazan abajo. |
| `_build/performance-final/*-candidates.term` | Secuencias completas pregrabadas de candidatos loop/parser/sparse | Mismo orden entre variantes; incluidas también en evidencia persistente |
| `_build/performance-memory-{reference,member,prepared,prepared_member}/` | Cuatro VM separadas, cada una guardó entorno y memoria completos; el comando de bucle terminó 0 | Observaciones de memoria originales, anteriores a corregir preflight al cerrar |
| `_build/performance-final/profile-sparse-prepared.txt` | Tabla eprof completa y `Total: 6331`; comando salió 0 | Solo diagnóstico específico; preparación/carga fuera del perfil |
| `_build/performance-final/automatic-example.{term,txt}` | Informe completo, descubrimientos/fallos no cero e infraestructura cero; secuencia salió 0 | Ejemplo previo funcional. El comando **no** fijó `ERL_FLAGS`; no se registró cantidad de schedulers ni se presupone cuatro. |
| `_build/phase21-closeout-startup/` | Cinco muestras calentadas por fixture/variante con cero mutaciones; salida 0 | Costes actuales de inicio preflight/calibración |
| `_build/phase21-closeout-memory-*/` | Cuatro VM nuevas separadas; pruebas completas acotadas de memoria; salida 0 | Memoria actual tras corregir preflight |
| `_build/phase21-closeout-fixed/` | Registros finales, ejemplo actualizado, auditoría de artefactos | Validación actual de fuentes; el ejemplo actualizado usa explícitamente `+S 4:4` |

No quedaba ningún proceso benchmark de la sesión interrumpida al reanudar.
Existencia o fecha de modificación de un archivo no probaron finalización.

La [evidencia persistente](../../performance/phase2.1-samples.term) contiene todas las
muestras y dispersión de tiempos, inicio, ambos conjuntos de memoria incluido
`/proc/self/status`, entorno compacto, identidades completas de compilación/
fuente/entrada, SHA-256 de artefactos, tablas de perfil, registros de validación,
resultados de ejemplo/terminación y candidatos pregrabados.
Referencias/pid runtime se reemplazan explícitamente por
`runtime_reference_omitted`/`runtime_pid_omitted` en esta copia consultable.
Objetos de comprobación de campañas repetidos se sustituyen por digests
**después de comparar exactamente**; las comprobaciones completas originales
siguen en archivos de campaña ignorados. Los digests ayudan a archivar,
no son el oracle diferencial.

La limitación de procedencia es explícita: el arnés antiguo registró hashes
fixtures, opciones del compilador, build IDs y metadatos runtime, pero no un
hash completo del árbol en el momento de medir. El archivo de cierre registra
hashes retrospectivos, recompila los 22 BEAM actuales con sus opciones registradas
y compara MD5 de código y formas abstractas. También reconstruye las tres
identidades fixtures y verifica términos BEAM/sidecar guardados y hashes fuente
en todos los grupos. Los registros exitosos anteriores y las fuentes activas
sin cambios establecen continuidad; no afirman una revisión Git firmada original
ni una instantánea contemporánea de todo el árbol.

La auditoría encontró un defecto de preflight Phase 2: mapas ETF equivalentes
pueden serializarse con distinto orden de claves en otra VM. Comparar bytes
rechazaba sidecars válidos. `efz_instrument` ahora decodifica con seguridad el
sidecar y compara términos exactos con el manifiesto integrado validado.
Codificaciones inválidas y manifiestos cambiados siguen fallando.
Una prueba determinista con claves inversas y regresión preflight en VM nueva
lo cubren. Este cambio ocurre al cargar artefactos, no durante sondas,
ejecución ni mutación. Solo se actualizaron inicio/calibración, memoria y
ejemplo; no hacía falta repetir rendimiento/perfilado.

## Variantes y valores públicos predeterminados

Los nombres se definen mediante `backend/1`, `prepared/1` y opciones de campaña
en `bench/efz_perf.erl`:

| Variante | Estrategia de validación | Almacenamiento/hook de cobertura |
|---|---|---|
| `reference` | `per_execution`: reconstruir conjunto exacto permitido desde manifiestos | `ets`: inserción original en cada hit |
| `member` | `per_execution` | `ets_member`: consulta pertenencia, inserta solo si falta |
| `prepared` | `prepared`: una lista protegida, opciones compactas del ejecutor | `ets` original |
| `prepared_member` | `prepared` | `ets_member` |

`efz_config:defaults/0`, y por tanto `efz:start/1` y el ejemplo automático
ordinario, seleccionan `prepared` + `ets`. Configuraciones existentes sin esas
opciones reciben el nuevo valor de validación con la misma política feedback.
Seleccione el hook opcional añadiendo:

```erlang
coverage_backend => ets_member
```

Para configuración completa de referencia:

```erlang
coverage_backend => ets, coverage_validation => per_execution
```

`efz_cov:open/0` sigue usando ETS original. `run/4` de bajo nivel solo con
`manifests` aún valida por ejecución; no crea un plan compartido implícito.
`run/3` conserva compatibilidad manual. Ambos hooks preservan contextos esquema 1
y observaciones exactas `{Module, BuildId, ProbeId}`.

Se evaluaron dos alternativas específicas: consultar pertenencia antes de
insertar y preparar validación/evitar copiar estado completo a cada coordinador.
No se añadieron atomics, ID compactos/hash, caché local seen, publicación
asíncrona ni flush final del objetivo. Membership aún consulta tabla externa
en cada hit; una tabla eliminada no se oculta tras caché.

## Frontera de validación preparada

El preflight público valida artefactos seleccionados, esquema/versión de
instrumentación integrados, equivalencia sidecar, build ID del descriptor e
identidad del módulo cargado. El adaptador objetivo no necesita instrumentarse;
los módulos explícitamente elegidos sí. La configuración rechaza opciones
inválidas de backend/validación y varios trabajadores.

`efz_cov_manifest:prepare(Mode, Manifests)` valida aparte formato de manifiesto,
ID/rutas estructurales únicos, selección automática no vacía y módulos duplicados.
Crea `{efz_cov_plan,1,Table,BuildMap}`. El conjunto ETS sin nombre **protegido**
contiene cada identidad exacta permitida y marcador modo/compilación
`'$efz_plan'`. Preparar no carga artefactos; usuarios de bajo nivel deben hacer
preflight primero. El plan funciona con ambos hooks porque coinciden formatos.

El trabajador de campaña posee el plan. Pasa solo opciones cobertura/backend/
plan a cada coordinador, evitando tanto reconstruir conjuntos como copiar
manifiestos/estado completo. Un llamador de bajo nivel puede compartir
intencionalmente el plan mientras viva su propietario: es una capacidad
inmutable de lectura, no ID de campaña ni contexto de ejecución.
Otros procesos no pueden escribir. El propietario lo libera al terminar usuarios,
o se elimina al morir. Completar conserva trabajador, plan, corpus e informe
hasta `efz:stop/0` o cierre. Campañas separadas tienen planes separados.

Cada ejecución sigue creando referencia, proceso objetivo y conjunto ETS público
propio del coordinador. Attach verifica propiedad; cada hit activo accede a
esa tabla. Tras terminar, la validación comprueba el marcador incluso con
instantánea vacía y **cada identidad observada** contra el plan.
Feedback también compara el mapa fijado. Planes eliminados/incompatibles y tablas
activas rotas producen infraestructura, no bugs ni feedback vacío válido.
Versiones de descriptor malformadas pueden dar infraestructura
`coordinator_down` en vez de `invalid_coverage_plan` más específico; ninguno
es éxito. Las observaciones válidas sobreviven a caducar un plan con estado
de error si la forma del descriptor sigue válida.

La prueba nueva cubre escrituras extranjeras protegidas, lecturas compartidas,
uso repetido, esquemas/modos/compilaciones erróneos, muerte del propietario en
una ejecución sincronizada y rechazo tras liberar con **cero observaciones**.
Las existentes cubren compilaciones cambiadas, manifiestos inválidos, eliminación
de tabla activa y errores capturados del hook.

Las compilaciones elegidas deben ser constantes durante campaña/plan.
Preflight rechaza módulos ordinarios/otras compilaciones ya cargados; validar
observación rechaza sondas inesperadas de compilación nueva. Ninguno prueba
seguridad ante sustitución arbitraria posterior, en especial código sin hooks.
Gestionar código caliente y cachés seguras a recarga queda fuera del contrato.

## Metodología y cargas

Cinco muestras por caso tras descartar piloto o tanda completa de calentamiento.
El orden de variantes se invierte en rondas alternas. Los pilotos del ejecutor
eligen tandas próximas a 180 ms, 128–20,000 ejecuciones; las cantidades pueden
diferir y se normalizan abajo. Las campañas comparten 2,048 mutaciones por
muestra más una calibración temporizada por separado. El límite hace práctica
la referencia lenta: las tandas rápidas todavía duran decenas de milisegundos,
no menos de uno. Sin umbrales por máquina ni intervalos de confianza;
dispersión significa mínimo–máximo observado.

| Fixture | Sondas del manifiesto | Observaciones del ejecutor | Entrada/trabajo y resultado comprobado |
|---|---:|---:|---|
| `efz_bench_fixture` | 6 | 6 | `run(1024) = 2304`; bucle de cola de 20,000,000 iteraciones y checksum 45,000,000 |
| `efz_perf_parser` | 20 | 10 | 32 copias de `<<0,0,7,1,35,2,2,97,98,3,2>>`; 352 bytes, resultado `{ok,128,1888}` |
| `efz_perf_sparse` | 2,051 | 2 | `<<0,7>>`, resultado 22; 2,048 cláusulas explícitas más fallback y sondas de entrada |

Build IDs, sin cambios tras el cierre:

```text
loop    943bea4cf9695048788654bbe520185c78611ad26733a1066989d28e4b0fd80d
parser  c966463003a8d5244d58710e533634f4003faeece71c7a9d61fdfa2559df2351
sparse  bf27f5190ec9b6744e8d20179a0c9110ae265238ac22fe4d70b2add7645f5534
```

Los fixtures ordinarios/instrumentados se cargan controladamente sin llamadas
activas; se comparan valores. No se aproxima renombrando módulos.
Las muestras de ejecutor completo miden `run/4` hasta terminación/limpieza del
coordinador: asignación de contexto, procesos/monitores, objetivo, snapshot,
validación y eliminación. Se comprueban resultado/estado/sondas canónicas contra
referencia. Preparar planes queda fuera y se registra aparte: sparse 603 us
prepared, 431 us prepared-member, observaciones únicas, no benchmark estable
de preparación.

Los relojes de mutación de campaña incluyen selección, mutación real, ejecutor,
feedback, retención, estadísticas y escritura de fallos. Excluyen compilar
fixtures, calibrar y construir/imprimir informe final. Inicio API y cierre/
limpieza se registran aparte. Se fijan RNG de mutación `{17,23,41}` y selección
del corpus `{101,109,113}`. Este último es opción nueva; la selección
predeterminada sin semilla no cambia.

Replay recorre cíclicamente listas guardadas; solo es benchmark, no mutador
nuevo de producción. El modo real usa `efz_mutator_random` existente.
Cobertura saneada exacta, entradas, decisiones/sondas nuevas, fallos y estadísticas
coinciden en las cuatro variantes y cinco repeticiones de cada carga/modo.
Campañas loop calibran seis sondas y no retienen más entradas. Parser replay/real
retienen 5/10 entradas totales y observan 15/19 sondas exitosas;
sparse replay/real retienen 9/538 y observan 10/540.
Por ello las campañas incluyen cargas distintas de retención/metadatos,
no solo escrituras repetidas.

## A. Costes de hooks

Las observaciones repetidas usan 2,000,000 llamadas directas al hook,
identidades reales completas del manifiesto disperso de 2,051 sondas y un
conjunto ya publicado. Son **ms por tanda**, mediana [mín–máx]; el modo inactivo
sigue ejecutando el mismo bucle llamador.

| Sondas distintas | Inactivo | Referencia ETS | Membership | Ratio tiempo referencia/member |
|---:|---:|---:|---:|---:|
| 1 | 15.208 [14.648–17.336] | 182.385 [179.183–185.007] | 118.594 [114.060–123.957] | 1.54x |
| 8 | 9.673 [8.811–10.222] | 176.121 [174.143–179.749] | 111.413 [110.601–115.619] | 1.58x |
| 64 | 8.670 [8.553–8.829] | 177.991 [176.712–180.876] | 112.828 [112.526–113.132] | 1.58x |
| 1,024 | 8.595 [8.534–8.792] | 189.348 [186.503–194.945] | 125.183 [124.630–128.117] | 1.51x |

Recorrer el bucle/lista contribuye al tiempo, explicando variación inactiva
según agrupación de sondas distintas. También se conservan todos los resultados
de 500,000 llamadas. Mide la ruta real `hit/1` sin atribuir todo al lookup del
diccionario del proceso.

Las primeras observaciones usan contextos nuevos preasignados; se mide attach
y primeras publicaciones, no asignación/snapshot/eliminación.
Después se comprueba cada conjunto esperado. Se usan muchos contextos vivos
para aislar escrituras; producción sigue con un trabajador y una ejecución viva.

| Llamadas hook | Sondas/contexto | Contextos | ETS ms [rango] | Member ms [rango] | Tiempo adicional member |
|---:|---:|---:|---:|---:|---:|
| 131,072 | 64 | 2,048 | 15.168 [14.983–16.831] | 20.565 [20.091–22.281] | 35.6% |
| 524,288 | 64 | 8,192 | 87.746 [87.056–92.194] | 112.473 [110.292–121.294] | 28.2% |
| 131,072 | 1,024 | 128 | 20.230 [19.191–20.427] | 25.031 [24.558–25.196] | 23.7% |
| 524,288 | 1,024 | 512 | 91.261 [90.249–91.978] | 113.625 [111.488–115.044] | 24.5% |

El fixture de bucle existente a 20,000,000 iteraciones:

| Modo | Mediana ms [mín–máx] | Respecto a ordinario |
|---|---:|---:|
| Ordinario | 35.087 [32.072–35.191] | 1.00x time |
| Instrumentado inactivo | 227.358 [220.167–229.080] | 6.48x time |
| Instrumentado ETS | 4,046.383 [3,962.962–4,088.383] | 115.32x time |
| Instrumentado membership | 2,593.771 [2,503.256–2,614.029] | 73.93x time |

Aparecen las seis sondas; hay 40,000,002 llamadas de hook. Membership es 1.56x
más rápido que ETS en este bucle sintético, aunque queda un coste considerable
de instrumentación. La preparación no participa. Ningún ratio de hooks se
presenta como rendimiento de campaña.

## B. Ejecutor completo

Tiempos en **us/ejecución**, mediana [mín–máx]. `N` es tamaño medido de tanda
por variante en orden reference/member/prepared/prepared-member.
Cada fila usa igual entrada y conjunto exacto de resultado/sondas.

| Fixture; N | Reference | Member | Prepared (predeterminado) | Prepared-member |
|---|---:|---:|---:|---:|
| Loop; 808/1,260/860/1,335 | 230.853 [221.092–235.197] | 149.522 [142.960–157.459] | 221.483 [213.171–231.353] | 142.897 [138.843–144.178] |
| Parser; 4,105/4,974/4,975/6,386 | 50.392 [48.179–50.662] | 40.454 [37.910–41.297] | 37.471 [37.168–39.381] | 27.998 [27.633–29.012] |
| Sparse; 132/129/17,311/20,000 | 1,331.235 [1,241.583–1,623.515] | 1,624.434 [1,409.581–1,770.605] | 7.405 [7.234–7.943] | 7.582 [7.034–7.607] |

Preparar da ratios medianos referencia/default de 1.04x / 1.34x / 179.76x.
El cambio pequeño de loop tiene rangos solapados; su ventaja aislada es débil.
El gran cambio sparse elimina trabajo proporcional a 2,051 sondas por cada
ejecución de dos hits. No es aceleración general de Erlang.
La mediana sparse de membership en referencia es **22% más lenta**, con rangos
amplios solapados; preparado, es 2.4% más lenta, tampoco concluyente para
una distinción fina.

## C. Campañas completas

Cada muestra contiene **2,048 mutaciones y una calibración separada**.
Son **ms/tanda** de mutación, mediana [mín–máx]. Cantidades de sondas de
manifiesto/exitosas están en metodología; no deben promediarse modos distintos.

| Fixture / modo | Reference | Member | Prepared (predeterminado) | Prepared-member |
|---|---:|---:|---:|---:|
| Loop / replay | 140.439 [130.715–150.496] | 114.871 [104.974–124.499] | 124.164 [121.846–134.971] | 94.616 [87.827–102.950] |
| Loop / real | 157.566 [149.826–177.073] | 120.003 [112.035–142.344] | 139.574 [128.366–141.977] | 106.589 [99.934–111.639] |
| Parser / replay | 162.143 [147.937–163.049] | 138.111 [133.298–174.021] | 111.907 [109.947–115.914] | 99.370 [85.961–111.084] |
| Parser / real | 122.444 [115.189–129.781] | 111.796 [107.400–115.664] | 95.287 [91.475–99.000] | 85.973 [81.385–91.675] |
| Sparse / replay | 2,842.573 [2,738.130–2,892.657] | 2,910.044 [2,882.867–3,023.839] | 33.266 [31.554–33.738] | 34.619 [31.641–40.462] |
| Sparse / real | 3,939.023 [3,409.309–4,382.920] | 3,750.131 [3,152.201–4,191.928] | 49.230 [46.300–78.594] | 47.972 [39.963–75.125] |

| Fixture / modo | Referencia mutaciones/s | Predeterminado mutaciones/s | Ratio predeterminado |
|---|---:|---:|---:|
| Loop / replay | 14,583 | 16,494 | 1.13x |
| Loop / real | 12,998 | 14,673 | 1.13x |
| Parser / replay | 12,631 | 18,301 | 1.45x |
| Parser / real | 16,726 | 21,493 | 1.29x |
| Sparse / replay | 720 | 61,564 | 85.45x |
| Sparse / real | 520 | 41,601 | 80.01x |

Añadir membership al default preparado mejora medianas loop en 1.31x y parser
en 1.13x replay / 1.11x real. Sparse replay es 4.1% más lento; sparse real
2.6% más rápido con rangos solapados y grandes atípicos. Respalda optimización
opcional para repeticiones, no cambio universal de backend.
No hay aceleración agregada inexplicada. La referencia sigue útil para
comparación diferencial, incluidos costes originales de construir/copiar
conjuntos por ejecución.

Las observaciones actuales de **inicio** vienen de campañas con cero mutaciones
tras corregir sidecar, calentamiento completo y cinco muestras alternas.
Compilar tres fixtures ordinarios/instrumentados tardó 1,174,788 us en esa VM,
una observación fría; la compilación original final tardó 575,889 us.
Incluyen inicio/carga del compilador y no comparan su velocidad.
Mediana de inicio antes de calibrar / calibración / parada, en us:

| Fixture | Reference | Member | Prepared | Prepared-member |
|---|---:|---:|---:|---:|
| Loop | 220 / 148 / 650 | 210 / 132 / 640 | 215 / 125 / 640 | 232 / 115 / 653 |
| Parser | 349 / 178 / 646 | 366 / 162 / 651 | 344 / 156 / 655 | 357 / 139 / 643 |
| Sparse | 19,318 / 3,392 / 1,378 | 20,327 / 4,129 / 1,629 | 22,710 / 156 / 1,765 | 21,215 / 152 / 2,685 |

Son muestras cortas diagnósticas, no la comparación principal de rendimiento.
Los rangos de inicio sparse son 18,864–20,533 / 19,100–22,979 / 20,341–24,678 /
19,610–27,023 us. Se archivan todas las muestras/rangos de inicio/calibración/
inicio API/limpieza. `api_start_us` se solapa con inicialización/calibración;
no debe sumarse a `startup_us + calibration_us`.
Los valores históricos permanecen archivados, pero este run los sustituye
como medición actual.

## Memoria y limpieza

La memoria se muestrea aparte. Cada variante corre en VM nueva: compilar/cargar,
snapshot tras GC, asignar opcionalmente plan de 2,051 ID, asociar contexto y
hacer 80,000 hits sobre ocho ID distintos, snapshot vivo, cerrar/liberar y GC,
luego campaña replay sparse acotada de 5,000 mutaciones con muestreador y parada.
Se registran picos VM/ETS/procesos a intervalos nominales de 2 ms; leer memoria
cuesta tiempo y el espaciado real es mayor. Son **picos muestreados**, no
absolutos ni rendimiento sin perfilador.

Observaciones originales guardadas, MB decimales para totales VM:

| Variante | Antes | Con plan | Contexto vivo | Tras limpiar contexto/plan | Tras limpiar campaña | Pico VM muestreado / muestras |
|---|---:|---:|---:|---:|---:|---:|
| Reference | 57.143 | 56.191 | 61.645 | 56.205 | 54.809 | 81.542 / 2,315 |
| Member | 57.124 | 56.169 | 56.202 | 56.165 | 54.775 | 87.575 / 2,367 |
| Prepared | 59.509 | 58.720 | 64.187 | 58.448 | 57.104 | 77.915 / 34 |
| Prepared-member | 59.335 | 58.680 | 64.137 | 56.810 | 56.963 | 76.673 / 34 |

Tras corregir preflight al cerrar, el mismo protocolo acotado produjo:

| Variante | Antes | Con plan | Contexto vivo | Tras limpiar contexto/plan | Tras limpiar campaña | Pico VM muestreado / muestras |
|---|---:|---:|---:|---:|---:|---:|
| Reference | 56.129 | 56.154 | 61.597 | 56.135 | 54.749 | 84.452 / 4,534 |
| Member | 57.339 | 57.356 | 57.389 | 57.387 | 55.924 | 91.795 / 4,429 |
| Prepared | 58.326 | 58.640 | 64.107 | 58.371 | 57.007 | 84.378 / 76 |
| Prepared-member | 56.274 | 56.579 | 62.062 | 54.741 | 54.926 | 79.588 / 71 |

Todas las comprobaciones nuevas vuelven a **41 procesos, cero tablas de
observación y cero de planes** tras cada limpieza.
El almacenamiento vivo de observaciones vuelve a 3,656 bytes; el plan añade
300,072–300,096 bytes a ETS total. Picos ETS nuevos: 517,624 / 517,912 / 820,288 /
818,016 bytes; picos de procesos siguen 52. Totales finales ETS: 515,976 /
515,872 / 515,968 / 516,264 bytes. Son observaciones, no umbrales ni requisitos
para otras máquinas.

Por ejemplo, `VmRSS` prepared nuevo es 125,952 kB con plan y 125,476 kB tras
limpieza; `VmHWM` permanece en su máximo anterior de 240,416 kB.
RSS prepared-member sube de 133,776 a 137,428 kB pese a liberar todas sus tablas
EFZ. Ilustra por qué RSS o total VM solos no prueban ni refutan fugas.
Estos runs incluyen el cambio de asignación de inicio; no se atribuyen distintos
máximos a mejora de velocidad/memoria del backend.

Todas las variantes originales tenían una tabla viva, **3,656 bytes para ocho
sondas**, y después cero. Las preparadas mantenían además un plan; su aumento
ETS observado al asignar fue 300,072 bytes para 2,051 identidades y marcador.
Es un conjunto exacto de términos, no un bitmap empaquetado.
Memoria VM incluye heap/asignador y calentamiento del compilador; restar columnas
VM no aísla coste del plan. La tabla antigua de loop con seis hits tenía
3,352 bytes, coherente con otro conjunto observado.

Los picos ETS originales fueron 517,424 / 517,624 / 817,464 / 817,752 bytes.
Las cuatro VM volvieron a 41 procesos y cero tablas cobertura/plan en ambas
fronteras de limpieza; los picos de procesos fueron 52.
ETS total final quedó unos 18 KB por encima del inicio por otro estado VM/app.
No demuestra fuga de tablas de ejecución EFZ.

Ya hay grandes fluctuaciones VM entre `before` y `with_plan` aunque no se asigne
plan. Son observaciones de arranque/calentamiento y GC/asignador.
Las campañas preparadas duran mucho menos y recibieron menos muestras;
máximos menores no prueban picos absolutos menores. `/proc/self/status` registra
RSS y máximo histórico `VmHWM` por separado. Ninguno equivale a
`erlang:memory(total)` ni palabras de tablas ETS.

Liberar recursos es evidencia más fuerte que totales VM parecidos: las pruebas
esperan terminación monitorizada de objetivo/coordinador, comprueban inventarios
exactos de tablas, repiten 50 pares deadline/siguiente ejecución por variante,
matan objetivos que publican continuamente y ejercitan muerte de llamador y
propietario del plan, cancelación, cierre y reinicio.
Las campañas completadas retienen intencionalmente corpus, cobertura exitosa,
decisiones, fallos únicos y plan hasta parar. No son fugas locales de ejecución.
Esta evidencia acotada respalda limpieza bajo el ciclo documentado, no una
garantía de prueba infinita ni de fugas arbitrarias de estado VM.

## Hallazgos del perfilado y decisión

El eprof loop original atribuye 47.97% del tiempo de funciones a 100,002
inserciones ETS, 30.38% a `efz_cov_rt:hit/1` y 21.52% al bucle.
El parser atribuye 26.52% a inserciones y 17.76% a hooks. Motivó consultar
pertenencia antes de insertar; medir primeros hits revela el coste adicional.
La entrada del perfil parser son 32 copias de `<<0,0,7,1,35,3,2>>`, siete sondas,
distinta de la entrada de rendimiento de diez sondas. No compare directamente
sus duraciones.

El perfil sparse original, 100 ejecuciones con dos observaciones y manifiesto
2,051 sondas, hace 205,100 inserciones en conjuntos permitidos y 3,591,131
llamadas trazadas. Dominan actualizar/añadir/rehash de buckets y hashing;
`spawn_opt` cuesta también 7.51%, consistente con copiar opciones/manifiestos
completos al coordinador. Inspeccionar fuentes confirma que las campañas pasaban
todo el estado creciente del trabajador. Preparar quita reconstrucción repetida
y pasa opciones compactas. Las medidas no reparten por separado ambos beneficios.
No existía un escaneo completo por hit que eliminar.

El perfil posterior guardado `sparse prepared` completó **6,331 llamadas trazadas**,
100 ejecuciones, 200 hits/inserciones y 200 consultas al plan.
Ya no reconstruye el conjunto. Mayores costes: `spawn_opt` 14.71%, snapshot ETS
`match_object` 13.68%, coordinador 13.42%, `run/4` 12.71%, información ETS 7.87%
y espera 7.74%. El total perfilado 1,550 us es diagnóstico de tiempo atribuido
a funciones, **no** duración de tanda sin perfilador.

Asignar/eliminar contexto, crear procesos/monitores y snapshots siguen como
costes fijos visibles. Las identidades completas aún se construyen/guardan;
novedad global y metadatos retenidos consumen trabajo. No se afirma que cada
uno sea cuello en toda carga. Se podría medir preparación/snapshot restantes
o representación exacta más ligera; no se investigó al cerrar.
Se conservaron terminaciones correctas, sin necesitar flush del objetivo.

La decisión admitida más simple no cambia: **validación preparada por defecto;
hook ETS original por defecto; membership opcional**. Los grandes beneficios
sparse vienen de validar/copiar mejor. Membership solo no da beneficio fiable
en ejecutor/campañas dispersas.

## Corrección y resultados reales de comandos

La secuencia final tras corregir sidecar terminó con salida 0:

```sh
rebar3 compile
rebar3 eunit
rebar3 ct
rebar3 dialyzer
rebar3 xref
```

| Comprobación | Resultado real |
|---|---|
| Compile | Pasa, avisos tratados como errores |
| EUnit | 38 passed: pruebas semánticas/de ciclo originales, 13 grupos backend y prueba sidecar entre VM |
| Common Test | Pasan los 3 casos de integración |
| Dialyzer | Pasa, 22 archivos de proyecto; PLT de 278 comprobado; sin avisos |
| xref | Pasa las comprobaciones configuradas de indefinidos/obsoletos |
| Auditoría de artefactos | Las 360 muestras originales son coherentes internamente; comparaciones canónicas exactas iguales; identidades fixtures y BEAM/fuentes actuales verificados |
| Ejemplo automático, `+S 4:4` | Completó 500 mutaciones, 1 calibración, 4 descubrimientos, 494 rechazos, 2 fallos / 1 único, 0 timeouts o fallos de infraestructura |
| `git diff --check` | Pasa |

La salida negativa esperada incluye diagnósticos estrictos de sintaxis y errores
del coordinador para versiones deliberadamente incompatibles de planes.
Las pruebas comprueban infraestructura y limpieza; no son regresiones inexplicadas.
La primera comprobación de cierre, 37 pruebas, pasó antes de descubrir el
defecto entre VM. La auditoría rechazó primero bytes sidecar no canónicos;
ese fallo fue evidencia de la corrección precisa, no fallo de pruebas iniciales.

Las pruebas diferenciales exactas cubren retornos, cláusulas anidadas, llamadas
entre módulos, repeticiones, error/throw/exit, kill externo y timeout sincronizados,
fronteras de finalización/plazo, contextos aislados, almacenamiento roto,
instrumentación ausente/incompatible y decisiones deterministas de corpus/fallos.
Las pruebas previas de semántica ordinaria/instrumentada y posición de cola
no cambian y pasan. No se debilitaron expectativas para aceptar un backend.

Evidencia actual concreta: tras semilla `<<0>>`, el ejemplo del mutador real
retuvo `<<>>` como entrada 3, padre 2, `new_coverage`, sonda 2.
Su correspondencia es `efz_example_parser:classify/1`,
`examples/simple_parser/efz_example_parser.erl:7`, compilación
`5f11a3a9df248ba517a1ae78cfad9462d6c6453bc0565bfe27089fa4a8239b6a`.
La prueba determinista de cinco candidatos demuestra aparte rechazo de
repeticiones y retención después de fallo artificial; esos ID/entradas no
están en el núcleo.

El fallo artificial guardado de `<<255,0>>` contiene sonda 7 con
`coverage_status => ok`, mientras la decisión lleva `target_failure` y
`new_probes => []`. La cobertura exitosa es `{2,3,4,5,8,9}`.
Estos campos significan cosas distintas: observaciones incluyen hits de fallo;
novedad del corpus y global exitosa excluyen lo exclusivo de fallos.
La campaña siguió y retuvo `<<0,0>>` después del primer fallo.
No hizo falta cambiar política de informes.

Los snapshots finales conservan sondas exactas `{30,66}` para error,
`{30,65}` para throw, `{30,67}` para exit y `{58}` para kill/timeout, con
compilación `19b2e8635273c78d98eb79d7bb4c2b11d1b94e4da9608e217d5636864fd80096`.
Todos tienen `coverage_status => ok`. Se comparan tuplas completas módulo/
compilación/sonda entre variantes. Las pruebas kill/timeout esperan mensaje
explícito posterior a publicación; timeout solo retorna tras terminar el objetivo.

## Reproducción

Ejecute desde la raíz `efz/`. Use un **directorio nuevo de salida** al medir de
nuevo; conserve los archivos anteriores. Los comandos usan directorios
`reproduce-*` distintos y la referencia retenida actual:

```sh
rebar3 compile
rebar3 eunit
rebar3 ct
rebar3 dialyzer
rebar3 xref

ERL_FLAGS='+S 4:4' escript bench/run.escript all _build/reproduce-performance
escript bench/report.escript _build/reproduce-performance

for EFZ_VARIANT in reference member prepared prepared_member; do
  ERL_FLAGS='+S 4:4' escript bench/run.escript memory \
    "_build/reproduce-memory-$EFZ_VARIANT" "$EFZ_VARIANT" || exit
done

ERL_FLAGS='+S 4:4' escript bench/run.escript startup _build/reproduce-startup
ERL_FLAGS='+S 4:4' escript bench/profile.escript sparse
ERL_FLAGS='+S 4:4' escript bench/profile.escript sparse prepared
ERL_FLAGS='+S 4:4' escript bench/profile.escript parser
ERL_FLAGS='+S 4:4' escript bench/profile.escript loop
ERL_FLAGS='+S 4:4' escript examples/automatic/run.escript
```

`all` ejecuta hooks, ejecutor y campañas reales/replay. Etapas individuales y
argumento opcional de variante seleccionan subconjuntos acotados.
`startup` tiene explícitamente cero mutaciones; no mide throughput.
Los perfiles se ejecutan separados de los tiempos finales.
`escript scripts/coverage_bench.escript` reproduce el arnés pequeño antiguo
de siete muestras, cuyas tandas ordinarias duran menos de un milisegundo.

El comando de archivo específico de cierre lee grupos originales/actualizados
nombrados, los comprueba y escribe evidencia nueva consultable:

```sh
ERL_FLAGS='+S 4:4' escript bench/archive.escript \
  _build/performance-final _build/phase21-closeout-evidence.term
```

Requiere esos directorios guardados; audita este registro, no es una etapa
portable de benchmark. El entregable incluye el resultado en `docs/performance/`
para inspeccionar muestras/metadatos sin archivos `_build` ignorados.
No se añade ningún directorio de compilación a Git.

## Archivos cambiados y límites restantes

Respecto al estado guardado Phase 2, los cambios runtime/integración son
`efz_cov`, `efz_cov_rt`, `efz_cov_manifest`, `efz_executor`, `efz_worker`,
`efz_config`, `efz_corpus`, `efz_fuzzer` y la corrección de cierre en
`efz_instrument`. Las pruebas añaden `test/efz_backend_tests.erl` y regresión
sidecar en `test/efz_phase2_tests.erl`. Herramientas de benchmark/replay/perfil/
archivo están en `bench/`; fixtures ordinarios parser/sparse en
`fixtures/performance/`. La documentación cambiada es README, arquitectura,
cobertura, este informe y su evidencia pequeña persistente.
Se conservaron configuración Rebar, transformación, mutaciones, reglas feedback
y fuente del ejemplo ordinario durante Phase 2.1.

La aceptación está completa para el contrato local probado; no queda ningún
resultado requerido bloqueado. Límites: solo OTP 27.0, un trabajador de producción,
cobertura del proceso explícitamente asociado, compilaciones fijas por campaña,
sondas de cláusula/resultado a nivel fuente y sintaxis omitida documentada.
Instrumentar cambia tiempos/asignación. Trabajo arbitrario creado por spawn,
recarga caliente, aplicaciones OTP con estado y aislamiento completo VM/SO
no se admiten. Cinco muestras en una máquina no dedicada no establecen
aceleraciones universales ni picos absolutos. Preparar usa memoria proporcional
al manifiesto; membership conserva coste del primer hit y dependencia de carga.
