# EFZ: perfil de coste de una iteración

[English](../../engine-performance-profile.md) · [Русский](../ru/engine-performance-profile.md) · **Español** · [简体中文](../zh-CN/engine-performance-profile.md) · [Todos los idiomas](../README.md)

La siguiente etapa, con resultados de 15 minutos, replay fijo y análisis de la
no estacionariedad OTP: [engine-performance-profile-v2.md](engine-performance-profile-v2.md).

## 1. Resumen ejecutivo

El experimental `coverage_backend => none` conserva mutación, corpus, worker, guardian, timeout y limpieza normales de EFZ, pero no recoge cobertura. En este host, un run Cowboy corto de 30 segundos logró **60.70 exec/s** sin instrumentación; el objetivo no-op logró **63.13 exec/s** con perfil y **63.70 exec/s** sin él. El coste medio no-op con 16 schedulers fue **15.82 ms**. Es el techo de *esta configuración y carga del host*, no un límite arquitectónico de EFZ: con `+S 1:1`, otro run no-op de 10 segundos logró **163.88 exec/s**, con media de **6.09 ms** por iteración. No se midió la iteración individual mínima como característica fiable.

En el perfil `otp_native_public`, `code:get_coverage/2` consumió **15.25 µs/iteration (0.081%)**. La suma de reset, get, conversión, novedad y merge fue **74.77 µs (0.398%)**. Los costes principales medidos eran del ciclo guardian: crear/destruir trazas y comprobar estado compartido. No se justifica actualmente un parche API OTP de cobertura compacta/opaca como siguiente paso para acelerar EFZ. Es un perfil local por etapas; conclusiones de throughput estable requieren pares repetidos.

## 2. Contexto y reproducibilidad

Resultados de 15 minutos del usuario: ETS 54.66, bitmap-v2 27.56, `otp_native_public` 96.59, `erlang_fuzzer` externo 19019.08 exec/s. Los raw runs están respectivamente en `artifacts/cowboy-long-bench/20261003T065733Z-ets/`, `20261003T065741Z-bitmap/`, `20261003T065750Z-otp_native_public/`, `20261004T053054Z-erlang_fuzzer/`. El último usa mutación libFuzzer, bucle en proceso y características propias de feedback/corpus. La razón ~197 frente a OTP public **no es** una estimación del coste de cobertura.

Los runs cortos siguientes usaron OTP 27.0, ERTS 15.0, Linux x86_64, 16 schedulers online, Cowboy 2.19.0, los mismos 12 seeds, seed 424242, duración 30 s y `--profile`, salvo indicación. El host tenía carga (load average ~18–22). Los primeros no-op/none solo lograron 17.60/19.57 exec/s con trace setup 35.4/31.1 ms; los repetidos 63.13/60.70. Un solo par y porcentajes absolutos no se trasladan a otra carga/schedulers. No se inició ningún run de 900 segundos durante esta etapa.

| Carga corta | Run | Ejecuciones | exec/s | Media por iteración |
|---|---|---:|---:|---:|
| No-op, none, profile | `20261004T061445Z-noop-none` | 1895 | 63.13 | 15,819 µs |
| No-op, none, sin profile | `20261004T061406Z-noop-none` | 1912 | 63.70 | — |
| Cowboy, none | `20261004T061152Z-none` | 1822 | 60.70 | 16,455 µs |
| Cowboy, none_instrumented | `20261004T061050Z-none_instrumented` | 1799 | 59.93 | 16,676 µs |
| Cowboy, ETS | `20261004T061244Z-ets` | 1172 | 39.03 | 25,606 µs |
| Cowboy, bitmap-v2 | `20261004T061324Z-bitmap` | 734 | 24.43 | 40,916 µs |
| Cowboy, OTP public | `20261004T061001Z-otp_native_public` | 1598 | 53.23 | 18,768 µs |

`none_instrumented` compila Cowboy con `line_coverage`, pero no llama a reset/get/feedback. La diferencia con `none` raw en un par corto es pequeña y no se ha separado del ruido. Estos runs no deben compararse por corpus/cobertura como historiales de fuzzing idénticos.

## 3. Arquitectura de iteración e IPC

`efz_worker:handle_info/2` selecciona y muta un input del corpus; `execute_allowed/4` calcula el hash y valida; `execute_checked/4` llama a `efz_executor:run/4`. `efz_executor:run_pinned/4` crea y monitoriza un guardian **en cada iteración**, esperando resultado y `DOWN`. `efz_guardian:start/6` crea sesión de trazas, captura baseline compartido, crea coordinator y raíz monitorizados e instala contexto; `efz_executor:invoke/4` ejecuta el objetivo en la raíz. El coordinator clasifica el resultado, el guardian termina el árbol y espera `DOWN`/barreras de traza; después `efz_guardian:finish/2` recoge cobertura, destruye la sesión y comprueba estado compartido. El worker llama a `efz_feedback:evaluate/3`, luego a `retain/2` y `accepted/5`. El worker persiste entre iteraciones; guardian, coordinator y raíz se recrean. El objetivo solicita descendientes adicionales.

La ruta mínima normal incluye 3 llamadas `spawn_monitor` (guardian, coordinator, raíz), llamadas adicionales `monitor` (caller/root/guardian), mensaje worker→guardian a través del closure spawn, `coordinate`, `coordinator_ready`, `start_owned`, `target_result`, `coordinator_done`, resultado guardian→worker y eventos `DOWN`/barreras correspondientes. El número exacto depende del sampler runtime, trazas y descendientes; **no se ha demostrado** un IPC fijo por testcase. `efz_guardian:cleanup/2` termina el árbol admitido incluso en no-op; es parte de seguridad, no coste de cobertura. `efz_cov_integrity:trace_setup/3` y `efz_cov_integrity:close/0` siguen funcionando en `none` para comprobar lifecycle.

## 4. Techo sin cobertura y harness no-op

`none` requiere `automatic + presence`, no carga schema de cobertura ni abre almacenamiento ni llama a `code:reset_coverage/1` o `code:get_coverage/2`. `efz_feedback:evaluate/3` no devuelve puntos nuevos, pero conserva motivos de retención de calibración/fallo. Selección, mutación y retención siguen la ruta normal. `none` es baseline de rendimiento/debug, no modo productivo guiado por cobertura. `none_instrumented` sirve para estimar aproximadamente el coste de instrumentación OTP de líneas. No-op `test/targets/engine/efz_noop_target.erl` ejecuta `run(_Input) -> ok` mediante el motor EFZ real.

No-op con 16 schedulers: 63.13 exec/s y 15,819 µs/iteration con perfil. Con `ERL_FLAGS='+S 1:1'`, el run de 10 segundos `20261004T062318Z-noop-none` logró 163.88 exec/s y 6093 µs/iteration, trace setup 2479 µs. Demuestra la sensibilidad de trace setup a schedulers/carga. En `none`, Cowboy consumió media 104 µs dentro del guardian y no-op 2.25 µs; la diferencia del ciclo completo no puede atribuirse solo al objetivo, porque no se emparejaron los runs.

Comandos de reproducción corta:

```sh
./scripts/run_cowboy_long_bench.sh --backend none --target noop --duration 30 --seed 424242 --profile
./scripts/run_cowboy_long_bench.sh --backend none --duration 30 --seed 424242 --profile
./scripts/run_cowboy_long_bench.sh --backend none_instrumented --duration 30 --seed 424242 --profile
./scripts/run_cowboy_long_bench.sh --backend otp_native_public --duration 30 --seed 424242 --profile
escript scripts/print_engine_profile.escript artifacts/cowboy-long-bench/RUN_DIR
```

## 5. Tiempos y contabilidad por etapa

El perfil solo se activa con `performance_profile => true`/`--profile`. `efz_perf_profile:measure/2` no consulta reloj si está desactivado; el resumen guarda como máximo 20,000 samples por etapa, mientras siguen acumulándose totales/llamadas. Mediana/p90/p99 están en `profile.term`; véalos con `scripts/print_engine_profile.escript`. Las cifras siguientes son medias de runs de 30 segundos, como porcentaje de `iteration_total`. Las etapas anidadas **no deben sumarse**.

| Etapa | No-op none µs | OTP public Cowboy µs | OTP % |
|---|---:|---:|---:|
| Selección de corpus | 32.6 | véase `profile.term` | — |
| Mutación | 12.8 | véase `profile.term` | — |
| Executor completo | 15,472 | 17,909 | 95.4% |
| Guardian completo | 15,074 | 16,753 | 89.3% |
| Guardian prepare | 9,416 | véase `profile.term` | — |
| Trace setup (dentro de prepare) | 8,924 | 8,507 | 45.3% |
| Guardian finish | véase `profile.term` | 5,677 | 30.2% |
| Trace destroy (dentro de finish) | 3,039 | véase `profile.term` | — |
| Comprobación compartida (dentro de finish) | 1,736 | véase `profile.term` | — |
| Espera de limpieza | 595 | 1,152 | 6.1% |
| Cuerpo del objetivo | 2.25 | 92.9 | 0.50% |
| Feedback completo | véase `profile.term` | 389.7 | 2.1% |
| Decisión/guardado de corpus | véase `profile.term` | 86.1 | 0.46% |

La contabilidad worker divide `iteration_total` en selección, mutación, preparación, executor, feedback, decisión corpus y `worker_unaccounted`; la de guardian divide el total en prepare, target, cleanup wait, finish y no contabilizado. Ambas suman 100% **por definición del cálculo**, no como prueba de ausencia de coste oculto. En no-op, `worker_unaccounted` es 293 µs y `guardian_unaccounted` 122 µs. Incluyen intervalos entre medidas, IPC/scheduling, creación de metadatos, mensajes y código sin timer propio. `executor_outer` es la diferencia entre duración del executor y total guardian; ~1156 µs/iteration en OTP. Un análisis más preciso debería medir por separado espera `DOWN`, espera scheduler, reductions y GC en vez de llamarlo todo «other».

Para ilustrar variabilidad: no-op `executor` mediana/p90/p99 = 15,112/21,497/27,289 µs; `trace_setup` = 8,598/13,546/18,487 µs. En OTP, `get_coverage` = 14/17/44 µs, conversión = 38/51/79 µs y `feedback` = 324/540/1645 µs. Son cuantiles de etapas individuales, no percentiles síncronos de una iteración.

## 6. Desglose nativo OTP

En `20261004T061001Z-otp_native_public`, las 1599 llamadas nativas read/reset incluyen calibración. Media por llamada: reset 1.82 µs, `code:get_coverage(line, M)` en cuatro módulos 15.25 µs, conversión 41.26 µs, novedad 15.88 µs. Merge se ejecutó 34 veces a 26.4 µs por llamada; amortizado ~0.56 µs/iteration. Las cinco etapas sumaron 74.77 µs/iteration, 0.398% wall time. `native_read`, 20.5 µs, ya incluye get y schema checks; no lo sume a `get_coverage`. `feedback`, 389.7 µs, incluye novedad, decodificación de nuevas líneas, schema checks y decisión; no lo sume entero a sus etapas anidadas. Incluso eliminar toda la ruta pública medida de cobertura daría solo ~0.4% de aceleración en este perfil. Es un límite superior Amdahl para este run, no una predicción de API OTP nueva.

## 7. Mutación y corpus

`bench/engine_mutation_micro.escript` con input fijo de 51 bytes: una mutación aleatoria, mediana 1 µs (100 samples, resolución 1 µs); 1000 mutaciones, mediana 879 µs por batch (10 batches, 865–918), ~1.14 millones de mutaciones/s; 1000 visitas al plan staged dictionary, mediana 654 µs (10 batches, 398 candidatos por batch), **no** 1000 inputs mutados listos. Resultado raw: `docs/performance/engine-mutation-2026-10-04.term`. Es una estimación local, no comparación con implementación interna libFuzzer. La mutación aleatoria no es el límite principal al techo no-op actual. La etapa worker `mutation` en staged también mide `efz_mutation_plan:next/2` al perfilar.

`efz_corpus:select/0` corre en cada iteración aleatoria; `efz_worker:execute_allowed/4` calcula SHA256; `efz_worker:retain/3` decide retención. Sin novedad, feedback devuelve `equivalent_coverage` y no se escribe entrada nueva. `corpus_decision`, 86.1 µs/iteration en OTP, **incluye** descubrimientos ocasionales y escrituras, no es el precio puro sin novedad. Selección, hashing y retención necesitan un benchmark controlado con historial fijo para estimar E/S; estos datos no estiman fiablemente el máximo coste de escritura.

## 8. Coste worker/guardian y cuellos de botella

Las subetapas principales medidas sin solapamiento del no-op:

| Etapa | µs/iteration | Proporción | Candidato y riesgo | Límite si se elimina por completo |
|---|---:|---:|---|---:|
| Trace setup | 8924 | 56.4% | Investigar reutilización de sesión; riesgo alto para control de descendientes | 2.29× |
| Trace destroy | 3039 | 19.2% | Investigación conjunta con setup; riesgo alto de eventos antiguos | 1.24× |
| Comprobación compartida | 1736 | 11.0% | Medir componentes y buscar equivalente; riesgo alto de omitir contaminación | 1.12× |
| Espera de limpieza | 595 | 3.8% | Reducir solo con quiescencia demostrada; riesgo alto de escritor tardío | 1.04× |
| Executor outer/IPC | ~398 | ~2.5% | Medir aparte espera de resultado/`DOWN`; riesgo medio | ~1.03× |

Los límites se calculan con Amdahl por etapa y **no predicen** aceleraciones alcanzables. Setup+destroy suman ~11.96 ms (~75.6%); eliminar ambos sin coste sustituto daría límite teórico ~4.1× en este run. Quitarlos **sin sustituir sus garantías** es inaceptable. Primer paso práctico: investigación limitada de creación/reutilización de trace session demostrando la frontera; segundo: perfilar `shared_state/0`. Son investigaciones, no cambios listos.

El bitmap corto logró 24.43 exec/s; `target_us` fue 15.24 ms frente a 0.32 ms ETS y 0.093 ms OTP public. Los historiales difieren, así que no demuestra causalidad, pero la ruta hit a nivel fuente necesita perfil separado con inputs idénticos antes de la siguiente optimización bitmap. Esta etapa no cambió bitmap/ETS.

## 9. EFZ y erlang_fuzzer externo

| Propiedad | EFZ | `erlang_fuzzer` externo | Efecto/transferibilidad |
|---|---|---|---|
| Mutación | Erlang random/staged | libFuzzer | Historiales distintos; sustituirla puede cambiar la evolución del corpus |
| Ejecución | guardian/root por testcase | bucle en proceso | EFZ cuesta más, pero aísla el árbol BEAM |
| Modelo de procesos | worker persistente, guardian/coordinator/root nuevos | driver persistente | Adoptar raíz persistente cambia aislamiento crash/timeout |
| Cobertura | sondas EFZ o líneas OTP | características nativas | Semánticas distintas; recuentos no equivalentes |
| Corpus/feedback | novedad y retención EFZ | política libFuzzer | Comparaciones directas de aceptación inválidas |
| Limpieza | kill, DOWN, barreras, shared checks | reset/reutilización de proceso | EFZ paga quiescencia/diagnóstico; no eliminar sin contrato |
| IPC | varios mensajes y monitores | llamada directa | Diferencia esperada de coste |
| Persistencia | árbol nuevo | reutilización de target en proceso | Puede acelerar con otro modelo de seguridad |
| Crash/timeout | clasificación EFZ en árbol controlado | runtime libFuzzer/NIF | Garantías y fallos diferentes |

La diferencia 197× no puede atribuirse principalmente a un componente. Los 2–3 orígenes más aparentes: lifecycle guardian/trace por testcase, árbol controlado con IPC/cleanup y un modelo en proceso de mutación/feedback/corpus totalmente distinto. Las medidas confirman el primero como coste grande dentro de EFZ, pero **no miden** su proporción de la diferencia frente a `erlang_fuzzer` con historial idéntico.

## 10. Nota de diseño de ejecución persistente

El worker ya persiste; guardian/coordinator/root no. Una raíz persistente reduciría spawn/monitor y quizá trace setup, pero timeout/crash puede dejar descendientes anteriores, mensajes, escrituras nativas y estado compartido. Un pool seguro requiere capacidad por ejecución, compuerta de admisión, generación del contexto de cobertura, quiescencia probada, retirada de procesos contaminados, restart tras crash/timeout y pruebas deterministas de barreras. Su coste debe medirse. Es una investigación aparte, no parte del parche.

## 11. Decisión API OTP y siguientes pasos

`get_coverage` medido representa 0.081%, la ruta completa medida 0.398% e incluso feedback inclusivo entero 2.1% de la iteración. Por tanto, **optimizar la API OTP de cobertura no es actualmente la fuente principal de aceleración potencial de EFZ**. Conviene aplazar binary compacto y opaque check-and-advance. Siguiente paso: benchmark emparejado y repetible de trace-lifecycle en host controlado con barrido `+S`, seguido de prototipo limitado que reduzca setup/destroy sin perder seguridad. Segundo candidato: optimizar shared-state checks tras perfil separado. No se decide hacer `otp_native_public` predeterminado: líneas OTP no equivalen a sondas estructurales EFZ y los runs de 30 segundos no demuestran equivalencia de política/calidad. ETS sigue predeterminado.

## 12. Comprobaciones y límites

Pasaron `rebar3 compile`, 3 EUnit focused, CT (3), xref y Dialyzer. EUnit completo con 16 schedulers predeterminados: 257 PASS, 2 timeouts en tests staged existentes (`efz:await(10000/60000)`); con `ERL_FLAGS='+S 1:1'`: EUnit completo 259 PASS, módulo staged 8 PASS. Los timeouts están ligados a sus presupuestos de tiempo en host cargado; no se cambiaron esperas de test. Campañas no-op cortas con/sin perfil produjeron input IDs y motivos de retención idénticos en el test nuevo. `cleanup.term` de none/OTP muestra `efz_fuzzer`, `efz_corpus`, `efz_stats` como `undefined` tras parar; no se comprobaron fugas a largo plazo. `profile.term` limita 20k samples/etapa; tiempos con precisión de microsegundos incluyen perturbación del propio perfil; use `--profile` solo para diagnóstico. La comparación externa no controla inputs idénticos, invocación de objetivo ni política de seguridad.
