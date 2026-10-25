# EFZ: perfil de rendimiento del motor v2 (2026-10-04)

[English](../../engine-performance-profile-v2.md) · [Русский](../ru/engine-performance-profile-v2.md) · **Español** · [简体中文](../zh-CN/engine-performance-profile-v2.md) · [Todos los idiomas](../README.md)

## 1. Resumen ejecutivo

Las ejecuciones Cowboy guardadas de 900 segundos muestran 269.54 exec/s para
`none`, 107.87 para ETS, 64.74 para bitmap-v2 y 103.36 para OTP public.
Por tanto, la cobertura por sí sola no explica la distancia al `erlang_fuzzer`
externo, ~19k exec/s, con otra política de ejecución interna y fuzzing.
Aquí no se realizó una ejecución nueva de 900 segundos.

Dos **replays fijos de las mismas 1000 entradas**, cortos y en orden inverso,
sitúan una campaña EFZ no-op completa en 490.69 exec/s, 2037.9 µs/entrada, y
Cowboy/none en 461.66–496.88 exec/s, 2166.1–2012.6 µs/entrada.
Los intervalos de ETS, bitmap y OTP public son 214.87–220.21, 89.64–91.75 y
364.67–416.51 exec/s. Todas las ejecuciones tienen SHA256 de entradas
`16FD09EF19D76F70ECC4E2000038632E30186175A3A6CA85F9FDC7A107B5F814`.
Orden y carga del host cambiaron tiempos absolutos; las diferencias siguientes
son rangos de dos runs, no costes aislados precisos de primitivas.

En el replay OTP inverso, `code:get_coverage/2` ocupa 5.4 µs/entrada, 0.228%;
conversión 14.8 µs, 0.629%; y el pipeline medido
reset+read+conversion+novelty+merge 24.0 µs, 1.022%.
Solo preparar trazas tarda ~942 µs, 40.1%. Una API OTP de cobertura compacta/
opaca tendría una cota teórica de ~1.01× para ese pipeline. El primer experimento
de ingeniería debe examinar ciclo de vida de trazas y alternativas que preserven
el aislamiento, no el interior de OTP. ETS sigue predeterminado; bitmap-v2
experimental/de referencia.

## 2. Resultados guardados de 15 minutos

Fuente: `artifacts/cowboy-long-bench/engine-20261004T063922Z-{none,ets,bitmap,otp_native_public}/summary.csv`
y `samples.csv`. Misma versión Cowboy y corpus inicial; historias evolutivas
independientes **no** son comparaciones de entradas iguales.

| Modo | Ejecuciones | Media exec/s | Mediana | P10–P90 | Primeros/últimos 60 s | Corpus final | Unidades de cobertura |
|---|---:|---:|---:|---:|---:|---:|---|
| none | 242589 | 269.54 | 276.10 | 222.10–287.90 | 315.73/220.78 | 12 | deshabilitada |
| ETS | 97081 | 107.87 | 108.10 | 105.10–110.20 | 106.18/106.13 | 82 | 296 sondas EFZ |
| bitmap-v2 | 58265 | 64.74 | 64.90 | 61.40–68.00 | 63.40/64.83 | 82 | 296 sondas EFZ |
| OTP public | 93030 | 103.36 | 59.10 | 20.00–196.80 | 195.12/176.88 | 64 | 336 líneas OTP |

ETS y bitmap acabaron con igual recuento estructural y tamaño de corpus,
pero eso no prueba que ejecutaran las mismas entradas. Líneas OTP no equivalen
a sondas estructurales. La ejecución externa se describe en
[benchmark Cowboy largo](cowboy-long-benchmark.md); sus ~19k exec/s miden otro
motor y otra política de feedback.

## 3. Techo del motor no-op y Cowboy sin cobertura

El `efz_noop_target:run/1` real está en
[test/targets/engine/efz_noop_target.erl](../../../test/targets/engine/efz_noop_target.erl).
`--target noop --backend none` usa los mismos [trabajador](../../../src/efz_worker.erl),
[ejecutor](../../../src/efz_executor.erl), [guardian](../../../src/efz_guardian.erl), corpus y
limpieza que Cowboy. `none` omite almacenamiento/reinicio/lectura/novedad de
cobertura; es modo de benchmark/depuración. En replay fijo de 1000 entradas
con `+S 2:2` y perfilado, no-op obtuvo 490.69 exec/s, tiempo total de
2037.9 µs/entrada y **media de iteración medida 1988.2 µs**.
Un microbenchmark por capas de campaña completa dio 418.39 exec/s en
300 repeticiones; variación de planificación corta explica por qué no son
techos idénticos. Cowboy/none incluso alcanzó 496.88 exec/s bajo otras
condiciones momentáneas. Así, 490.69 es un resultado medido, no una cota estricta.

Cowboy/none en orden directo dio 496.88 exec/s y 2012.6 µs/entrada con los mismos
bytes; el inverso dio 461.66 y 2166.1. En el inverso, el cuerpo Cowboy promedió
unos 40 µs/iteración para `none`; no-op casi no trabaja. Restar medias de ciclos
completos también incluye planificación del host, carga de código y trabajo
por entrada, por lo que `Cowboy minus no-op` solo aproxima el coste del objetivo.

## 4. Flujo de datos de iteración y ciclo de procesos

`efz_worker:handle_info/2` elige entrada del corpus e invoca mutador en una campaña
evolutiva. `execute_allowed/4` calcula hash y comprueba; `execute_checked/4`
llama `efz_executor:run/4`. `efz_executor:run_pinned/4` crea un guardian monitorizado
por testcase. `efz_guardian:start/6` crea sesión de traza, estado compartido
inicial, coordinador y raíz monitorizados. `efz_executor:invoke/4` invoca objetivo
en la raíz y envía resultado al coordinador. `efz_guardian:cleanup/2` mata el
árbol controlado; `loop/1` drena `DOWN` y barreras de traza.
`efz_guardian:finish/2` sella cobertura, destruye traza y comprueba estado
compartido. Después el trabajador llama `efz_feedback:evaluate/3`, `retain/3`
y registra la decisión.

```text
persistent EFZ worker
  -> spawn_monitor guardian -> trace session / coordinator / root
  -> root invokes target -> coordinator classifies -> guardian cleans/drains
  -> guardian result + DOWN -> worker feedback/corpus -> next iteration
```

Se crean al menos tres procesos, `guardian`, `coordinator`, `root`, y tres
`spawn_monitor` por testcase normal en [ejecutor](../../../src/efz_executor.erl) y
[guardian](../../../src/efz_guardian.erl), además de monitores explícitos para llamador,
guardian y raíz. El trabajador es persistente. Los enlaces de supervisión de
aplicación/trabajador son de campaña, no enlaces nuevos por testcase.
Ocurren al menos mensajes coordinate, ready, start, target-result,
coordinator-done, guardian-result, guardian-DOWN y next-iteration; eventos
adicionales `DOWN`, trace-delivered, execution-context y descendientes impiden
fijar una cantidad exacta. Los bucles receive del guardian comprueban plazo de
iteración y de limpieza acotada. Las asignaciones por iteración incluyen mapas
de contexto/metadatos, hashes, conjuntos, trazas, monitores y heaps de tres
procesos. Reutilizar trabajador/corpus/cobertura global no elimina este ciclo.

## 5. Perfilado de etapas y contabilidad

`performance_profile` es false por defecto en
[efz_config:defaults/0](../../../src/efz_config.erl). Con `--profile`,
[efz_perf_profile](../../../src/efz_perf_profile.erl) registra llamadas, total, media,
mediana, p90 y p99; su ruta deshabilitada no lee el reloj. Trabajador, guardian
y [recolector OTP nativo](../../../src/efz_cov_native_public.erl) publican tiempos
anidados separados. Se exponen mediante `profile.term` y
`scripts/print_engine_profile.escript`. La tabla usa el run **actual de replay
fijo inverso OTP public**, `v2-current-reverse-otp_native_public`.
Su media medida de iteración es 2351.0 µs; el tiempo incluyendo inicio/informe
es 2400.9 µs/entrada.

El resumen correspondiente se conserva en
[engine-otp-fixed-profile-v2-2026-10-04.term](../../performance/engine-otp-fixed-profile-v2-2026-10-04.term).

La media `none` de 900 segundos, 269.54 exec/s, equivale a unos 3710 µs/ejecución,
pero ese run no tenía perfilado. Los porcentajes del replay corto **no pueden**
asignarse exactamente a esa línea base larga: difieren evolución de mutaciones/
corpus, condiciones del planificador y muestreo. Hace falta una campaña larga
perfilada manual para descomponer con precisión la observación de 270 exec/s.

| Etapa | µs/iteración | % iteración | Frontera |
|---|---:|---:|---|
| Mutación | 0 | 0 | deshabilitada en replay fijo; run evolutivo 20 s: ~3.9 µs |
| Preparación de entrada | 1.4 | 0.06 | SHA256/comprobación/metadatos |
| Trabajador/ejecutor inclusivo | 2162.0 | 91.96 | contiene guardian y objetivo |
| Guardian inclusivo | ~1908 | ~81.2 | preparación + objetivo + limpieza + finalización + huecos |
| Preparación de traza del guardian | 942.3 | 40.08 | sesión de traza por iteración |
| Reinicio de cobertura | 0.5 | 0.02 | `code:reset_coverage/1` en cuatro módulos |
| Cuerpo objetivo | 33.7 | 1.44 | ruta de parser Cowboy |
| `code:get_coverage/2` | 5.4 | 0.23 | cuatro módulos |
| Conversión de cobertura | 14.8 | 0.63 | términos Erlang a bitset |
| Novedad | 3.1 | 0.13 | bitset nativo |
| Combinación global | 0.28 amortizado | 0.012 | 34 llamadas de combinación |
| Feedback inclusivo | 129.0 | 5.49 | incluye novedad/combinación y decodificar descubrimientos |
| Decisión de corpus | 0.1 | 0.005 | replay fijo suprime inserción |
| Almacén del corpus | 0 | 0 | deshabilitado en replay fijo; medido aparte al descubrir |
| Espera de limpieza | 108.1 | 4.60 | guardian espera reposo |
| Finalización inclusiva guardian | 583.8 | 24.83 | destruye traza, revisa estado compartido, lee cobertura |
| Trabajador sin contabilizar | 58.4 | 2.49 | mensajes/planificación y código sin temporizar |

**No sume filas anidadas.** Etapas superiores del trabajador más
`worker_unaccounted` igualan el total por construcción. El guardian tiene media
propia no contabilizada de 111.3 µs, ~4.7%; `executor_outer_us` es 253.6 µs,
~10.8%, que incluye preflight, entrega llamador/guardian, espera de resultado/
`DOWN` y planificación externa a la vida medida del guardian. Se identifica,
no se esconde como «otros»; esos componentes no se midieron individualmente.
La fracción superior no contabilizada queda bajo 10%, pero los relojes de
etapas incluyen pausas de planificación y coste de perfilado.

## 6. Capas sintéticas de trabajador/guardian

El [microbenchmark reproducible del ciclo](../../../bench/engine_lifecycle.escript)
usó OTP 27, `+S 2:2`; resultado original:
`docs/performance/engine-lifecycle-v2-2026-10-04.term`.

| Capa | Iteraciones | µs/llamada | Notas |
|---|---:|---:|---|
| Llamada no-op directa | 100000 | 0.006 | cota inferior JIT/bucle estrecho; posibles efectos del compilador |
| Ida/vuelta de actor persistente | 10000 | 0.636 | un actor, sin aislamiento |
| Spawn+monitor de proceso no-op | 1000 | 1.195 | un proceso; sin guardian/trazas |
| `efz_executor:run/4` real | 300 | 2456 | guardian completo, sin bucle trabajador/corpus |
| Campaña fija EFZ completa | 300 | 2390 | incluye trabajador/feedback; variación de planificación impide restar |

El salto entre mensaje o spawn y ejecutor completo es muy superior a la propia
llamada al objetivo. Las capas tienen contratos diferentes; no pueden restarse
sus tiempos mecánicamente para asignar coste a una garantía EFZ. Reducciones
del llamador y deltas GC de VM están en el term original. **No se midieron**
recuentos dinámicos exactos de todos los mensajes de traza, asignaciones heap
BEAM y operaciones de monitor; las cotas estáticas anteriores vienen del fuente.

## 7. Costes de mutación y corpus

`bench/engine_mutation_micro.escript` con entrada fija de 51 bytes y `+S 2:2`:
1000 mutaciones aleatorias, mediana 631 µs; 10k, 6529 µs; 100k, 65605 µs,
~1.52 millones de mutaciones/s. El tamaño medio resultante de las tandas 100k
fue ~51.0 bytes. Una mutación queda bajo la resolución de 1-µs.
Diccionario por etapas: 1000 visitas, mediana 601 µs, con 398 candidatos en este
fixture. Repeticiones, reducciones, deltas de memoria y totales de bytes están
en `docs/performance/engine-mutation-v2-2026-10-04.term`; el delta de memoria no
cuenta asignaciones exactas. La mutación sola no explica un motor limitado a
pocas centenas de exec/s para esta carga.

`bench/engine_corpus_micro.escript` con `+S 2:2`: selección/obtención 1.21 µs,
SHA256 0.18 µs, codificación de metadatos 0.25 µs, comprobación duplicada en
memoria 1.03 µs, inserción 2.74 µs. Treinta escrituras iniciales persistentes
`efz_corpus_store:save/4` con fsync promediaron 2543 µs; un duplicado en disco
187 µs. Datos: `docs/performance/engine-corpus-v2-2026-10-04.term`.
Dependen del sistema `/tmp` y caché. En la ruta normal sin novedad,
[efz_worker:retain/3](../../../src/efz_worker.erl) **no** llama `efz_corpus:add/2`;
el replay fijo además prohíbe crecer. Los descubrimientos pueden tener coste
persistente de milisegundos, pero no se escribe en cada iteración.

En el smoke OTP evolutivo posterior de 10 segundos,
`v2-current-otp-timeseries-10s`, 4152 ejecuciones hicieron crecer el corpus
12→45. El temporizador anidado `corpus_store` registró 155716 µs totales,
37.5 µs/iteración amortizados, 1.56%; mediana y p90 son cero porque la mayoría
no guarda. `corpus_decision` incluye ese tiempo. Este calentamiento corto no
es la meseta de 900 segundos sin novedad.

Las muestras de etapas cada 1 segundo están guardadas en
[engine-otp-stage-samples-v2-2026-10-04.csv](../../performance/engine-otp-stage-samples-v2-2026-10-04.csv).

## 8. Replay fijo: entradas iguales y coste de backends

`--fixed-replay N` en el [runner Cowboy](../../../scripts/cowboy_long_bench.escript)
crea una secuencia determinista de las mismas 12 semillas y semilla aleatoria,
guarda `replay-inputs.term` exacto y SHA256, y la entrega directamente al
trabajador persistente. La rama de benchmark de
[efz_worker:handle_info/2](../../../src/efz_worker.erl) omite calibración/mutación y
avanza por orden de lista; [execute_result/6](../../../src/efz_worker.erl) aún calcula
feedback/cobertura global pero suprime inserción del corpus, de modo que el
feedback no elige la entrada siguiente. Se comprueban exactamente `N`
ejecuciones y `completed`, manteniendo corpus 12. Esta rama solo es benchmark
y no cambia fuzzing ordinario. Las pruebas cubren entradas duplicadas,
perfilado deshabilitado por defecto y decisiones iguales al alternarlo.

Las dos series actuales de 1000 entradas usaron `ERL_FLAGS='+S 2:2'`, `--profile`
y el mismo SHA256 anterior. Directorios:
`artifacts/cowboy-long-bench/v2-current-forward-*` y `v2-current-reverse-*`.
El tiempo total empieza justo antes de `efz:start/1` e incluye inicio/informe;
los porcentajes usan iteraciones medidas. Las entradas son iguales **dentro de
cada serie y entre series**, pero BEAM del objetivo difieren por instrumentación;
carga/orden de código y carga externa afectan resultados. Los runs exploratorios
anteriores `v2-fixed-*` iniciaban el reloj después de `efz:start/1`;
los `v2-final-*` preceden al temporizador separado `corpus_store`.
Se excluyen ambos de esta tabla.

Resumen compacto con rutas y hashes:
[engine-fixed-replay-v2-2026-10-04.term](../../performance/engine-fixed-replay-v2-2026-10-04.term).

| Modo | Directo exec/s | Directo µs/entrada | Inverso exec/s | Inverso µs/entrada |
|---|---:|---:|---:|---:|
| No-op + none, ejecución separada | — | — | 490.69 | 2037.9 |
| Cowboy + none | 496.88 | 2012.6 | 461.66 | 2166.1 |
| Cowboy + ETS | 220.21 | 4541.1 | 214.87 | 4654.1 |
| Cowboy + bitmap | 91.75 | 10899.1 | 89.64 | 11155.5 |
| Cowboy + OTP public | 364.67 | 2742.2 | 416.51 | 2400.9 |
| Cowboy + OTP native no read | 473.53 | 2111.8 | 448.82 | 2228.1 |

Restar tiempos emparejados `mode - none` da ETS aproximadamente
**+2.53/+2.49 ms/entrada**, bitmap **+8.89/+8.99 ms**, OTP public
**+0.73/+0.23 ms**, directo/inverso. Native no-read añade +0.10/+0.06 ms respecto
a none. El par OTP varía mucho más que su tiempo `get_coverage` medido; estos
runs no aíslan la causa. ETS sigue ~2.1–2.2× más lento que none y bitmap
~5.1–5.4×. Son diferencias totales de modo, **no coste puro de primitivas de
cobertura**. En particular, preparar trazas del guardian difiere entre
compilaciones estructurales/nativas y cambian política feedback/estado global.

Bitmap sigue más lento que ETS con entradas idénticas: varios milisegundos de
su media de iteración inversa están en el cuerpo instrumentado frente a ~0.1 ms
ETS. Finalizar guardian también cuesta más. No se intentó bitmap-v3;
bitmap-v2 continúa experimental/de referencia.

## 9. Desglose OTP nativo y control sin lectura

`otp_native_no_read` es alias de benchmark de `none_instrumented`: Cowboy se
compila con `line_coverage` OTP, pero EFZ usa `coverage_backend => none` en
iteraciones. Preflight puede inspeccionar cobertura una vez al preparar;
la iteración no reinicia, lee, convierte, compara ni combina cobertura nativa.
Objetivo y preparación de semillas/mutación coinciden con OTP public.
Esto separa aproximadamente presencia de instrumentación y extracción/feedback,
sin alterar el backend de producción.

En replay fijo inverso, public frente a no-read difiere **172.8 µs/entrada**
en total; en directo, **630.4 µs**. Reinicio+lectura+conversión+novedad+combinación
medidos son 24.0 µs/iteración inversa, feedback inclusivo 129.0 µs.
El resto incluye validar esquemas, decodificar diagnósticos/líneas nuevas,
contexto/resultados y planificación; no es automáticamente coste de
`code:get_coverage`. Solo `get_coverage` ocupa 5.4 µs, 0.228%;
`get_coverage+conversion` 20.2 µs, 0.857%. La dispersión limita atribución integral.

## 10. Variabilidad OTP y tamaños de entradas

La serie OTP de 900 segundos guardada mantuvo ~180–200 exec/s al principio,
bajó a ~17–26 entre ~300–660 s y volvió a ~180 sin retroceso correspondiente
de corpus/cobertura. Durante gran parte de la caída, corpus 61–62 y cobertura
333–334. Procesos permanecieron 52, cola VM 1, memoria VM ~46–48 MB.
Crucialmente, reducciones/ejecución siguieron ~83k y recolecciones GC/ejecución
~3.1 antes, durante y después. Debilita explicaciones por entradas complejas,
más líneas, descubrimientos o frecuencia GC. El run antiguo **no** registró
tamaños ni tiempos de etapas, CPU steal/throttling ni uso por scheduler.
Una ralentización de planificación host/VM es plausible pero **no probada**;
el mecanismo preciso sigue abierto.

El nuevo run OTP de 20 segundos con `+S 2:2`, `v2-otp-timeseries-20s`,
completó 7445 ejecuciones, media 372.18 exec/s. `samples.csv` y
`stage-samples.csv` registran cada 1 segundo rendimiento, corpus, cobertura,
descubrimientos, GC, cola, tamaño medio y costes por ejecución.
El rendimiento creció de ~255 a ~380–399 exec/s durante calentamiento.
Preparar traza cayó de ~1518 a ~975–1044 µs/ejecución; `get_coverage` siguió
~5.6–7.3 µs y conversión ~15–19 µs. Este run corto **no reprodujo** la caída larga.
La correlación durante calentamiento está confundida por descubrimientos y
costes de scheduler/trazas cambiantes; no identifica causalidad.
Si reaparece, hace falta un diagnóstico largo manual con
`--profile --sample-interval 10`.

```sh
./scripts/run_cowboy_long_bench.sh --backend otp_native_public \
  --duration 900 --seed 424242 --profile --sample-interval 10
```

El comando está preparado para ejecución **manual**; no se ejecutó aquí.
Si se repite, alinee `stage-samples.csv` con throttling/steal del SO, uso por
scheduler y pausas GC. La telemetría actual no distingue esas causas.

Los intervalos de tamaño solo se recogen al perfilar en
[efz_worker:finish_iteration/1](../../../src/efz_worker.erl). Replay OTP inverso actual:

| Bytes de entrada | Cantidad | Media objetivo µs | Media iteración µs |
|---|---:|---:|---:|
| 0–64 | 583 | 20.9 | 2344.9 |
| 65–256 | 334 | 57.8 | 2356.9 |
| 257–1024 | 83 | 27.2 | 2370.3 |
| 1025–4096 | 0 | no probado | no probado |
| >4096 | 0 | rechazado por límite de campaña | rechazado por límite de campaña |

La media de iteración cambia poco pese a diferencias de tiempo del objetivo.
La correlación histórica de tamaños de entrada largos se desconoce.

## 11. Huecos de instrumentación

Los manifiestos EFZ en `v2-fixed-1000-ets/target-beams/*.efz-manifest` enumeran
`preserved_without_internal_probes` para estas construcciones. Para la columna
nativa se cargaron los BEAM exactos OTP 27 `line_coverage` del run fijo y se
consultaron líneas ejecutables con `code:get_coverage(line, Module)`.

| Módulo / línea fuente | Construcción | Sonda interna EFZ | Línea ejecutable OTP | Consecuencia |
|---|---|---|---|---|
| `cowboy_http:121` | valor predeterminado de registro | no | no | Ninguno ofrece punto interno allí; pueden activarse sondas de funciones circundantes |
| `cowboy_http:1499` | comprensión de listas | no | sí | OTP ve alcance de línea; ninguno necesariamente cada resultado de comprensión |
| `cowboy_req:488,1056` | comprensiones de listas | no | sí | EFZ puede perder una distinción interna de comportamiento |
| `cowboy_router:66,90,328,330` | comprensiones de listas | no | sí | EFZ puede perder una distinción interna de comportamiento |

Es una diferencia semántica, no prueba de que líneas OTP sean globalmente más
ricas: las sondas estructurales distinguen resultados de una misma línea que
OTP combina. En esta tarea no se cambió dónde instrumentar.

## 12. erlang_fuzzer externo y ejecución persistente

| Propiedad | EFZ | erlang_fuzzer externo | Consecuencia de coste/seguridad |
|---|---|---|---|
| Ejecución / invocación | objetivo en raíz controlada nueva | llamada persistente en proceso | Menos preparación externa; EFZ aísla árbol BEAM |
| Mutación | Erlang aleatorio/por etapas | libFuzzer | Secuencia y presión del corpus diferentes |
| Trabajador/guardian | trabajador persistente, nuevos guardian/coordinador/raíz | sin guardian EFZ | EFZ paga trazas, monitores y barreras |
| Cobertura/feedback | estructura EFZ o líneas OTP, novedad EFZ | contadores/características nativas | Distintas unidades y aceptación |
| Planificación corpus | cola EFZ y entradas persistentes | política corpus libFuzzer | Diferente crecimiento e I/O |
| Fallo/timeout | árbol controlado y limpieza clasificada | runtime libFuzzer/NIF | Otro contrato de seguridad |
| IPC/ciclo de procesos | mensajes, procesos monitorizados por testcase | bucle directo interno | Gran diferencia esperable de rendimiento |

El suelo no-op completo medido de EFZ es ~2.1 ms con `+S 2:2`; el resultado
externo es ~52 µs/iteración, pero **no son cargas equiparadas**.
Preparar/destruir trazas y procesos/IPC controlados son cuellos EFZ; también
difieren mutación/feedback libFuzzer e invocación. No se justifica descomponer
numéricamente de forma causal la distancia de 19k a 270.

Un modo EFZ de raíz persistente necesitaría diseño de seguridad separado:
imponer plazos si bloquea el objetivo, reiniciar tras fallo, quitar mensajes
antiguos, reiniciar diccionario/ETS y estado objetivo, propiedad de descendientes,
retirar generaciones de cobertura y verificar reposo real de todos los escritores.
Un pool puede mantener retorno seguro retirando trabajadores contaminados;
un modo rápido interno tendría aislamiento más débil y debe etiquetarse.
**No se implementó rediseño.** El paso siguiente es un experimento acotado del
ciclo de trazas con pruebas deterministas de fallo/timeout/escritor tardío,
no quitar comprobaciones del guardian por un microbenchmark.

## 13. Análisis Amdahl y decisión de backend predeterminado

En el replay OTP inverso, `get_coverage+conversion` es 0.857% de la iteración;
la aceleración teórica máxima sería `1/(1-0.00857) ≈ 1.009×` si fueran gratis.
El pipeline nativo entero medido es 1.022%, con `≈1.010×`.
Incluso quitar todo feedback inclusivo, 5.49%, limitaría a `≈1.058×` para este
replay. Estas cotas dependen de la carga y no explican la variabilidad larga
de 20–200 exec/s.

El próximo paso con mayor potencial medido es perfilar/prototipar un **ciclo de
trazas más barato que preserve aislamiento**, después medir con entradas idénticas
y validar limpieza de fallos/timeouts/descendientes. Reducir revisiones de
estado compartido o IPC requiere sus propias medidas y prueba de seguridad.
Optimizar o parchear la API OTP de cobertura tiene poca prioridad; no se retomó
trabajo DWARF/punteros. ETS sigue predeterminado por fidelidad semántica de
sondas. `otp_native_public` es alternativa opcional con otras líneas y
variabilidad larga sin resolver. Bitmap-v2 sigue experimental/de referencia
porque tanto campañas largas como replay fijo lo muestran más lento que ETS.

## 14. Reproducción y validación

Replay fijo corto:

```sh
for backend in none ets bitmap otp_native_public otp_native_no_read; do
  ERL_FLAGS='+S 2:2' ./scripts/run_cowboy_long_bench.sh \
    --backend "$backend" --fixed-replay 1000 --seed 424242 --profile \
    --out "artifacts/cowboy-long-bench/my-fixed-$backend"
done
```

No-op y benchmarks de componentes:

```sh
ERL_FLAGS='+S 2:2' ./scripts/run_cowboy_long_bench.sh --backend none \
  --target noop --fixed-replay 1000 --seed 424242 --profile \
  --out artifacts/cowboy-long-bench/my-fixed-noop
ERL_FLAGS='+S 2:2' escript bench/engine_lifecycle.escript /tmp/efz-engine-lifecycle.term
ERL_FLAGS='+S 2:2' escript bench/engine_mutation_micro.escript /tmp/efz-mutation.term
ERL_FLAGS='+S 2:2' escript bench/engine_corpus_micro.escript /tmp/efz-corpus.term
```

Comprobaciones tras cambios: `ERL_FLAGS='+S 1:1' rebar3 eunit` **260 PASS**;
CT **3 PASS**; xref y Dialyzer **PASS**. El nuevo caso EUnit comprueba replay fijo,
modo sin cobertura, perfilado deshabilitado por defecto, comportamiento de
perfilado e intervalos de tamaños. Runs fijos `none`/OTP public/OTP no-read
terminaron sin fallos/timeouts; los términos escritos con `~w` pueden consultarse
incluso con bytes mutados arbitrarios. Un run temprano de telemetría de
45 segundos terminó el objetivo pero falló al escribir etapas por `zip` de
listas desiguales; se corrigió exportación y pasó el run posterior de 20 segundos.
El fallido no cuenta como resultado exitoso de telemetría. No se verificaron
fugas en campañas largas ni el mecanismo de ralentización OTP a mitad del run.
