# Validación P0 — 2026-09-16

[English](../../runtime-diagnostics-validation.md) · [Русский](../ru/runtime-diagnostics-validation.md) · **Español** · [简体中文](../zh-CN/runtime-diagnostics-validation.md) · [Todos los idiomas](../README.md)

## Checkout y entorno

- Commit inicial: `205e18ba172d74bd6c652a68abfc73e02e4a1f86`.
- Ubuntu 24.04.4 LTS, x86_64, kernel `6.8.0-nyx+`.
- Erlang/OTP 27.0, ERTS 15.0, Rebar3 3.25.0.
- Rebar3/bench usó `ERL_FLAGS='+S 4:4'`; fixtures externas de lifecycle peligroso
  usaron `erl +S 2:2` bajo `timeout 10s`.
- No se encontró AGENTS.md aplicable en checkout ni padres.
- El checkout ya contenía cambios de coverage/hit-count, corpus, CLI y docs:
  [estado inicial completo](../../runtime-validation/preexisting-status.txt).
  El diff inicial está en `/tmp/efz-p0-baseline/preexisting.diff`.
  No hubo reset/clean, cambios de ramas ni commit/push.
- No se editaron archivos harness/target existentes. Los nuevos objetivos solo están en
  `fixtures/runtime/`. Los 11 archivos con cambios ajenos, no tocados por P0,
  coinciden byte a byte con el estado inicial guardado.
- [Archivos cambiados por esta tarea](../../runtime-validation/changed-files.txt).

La propiedad guardian, compuertas, monitores, barreras de traza, cobertura/integridad por ejecución,
retirada dirty-runner, grupos de crashes, raw/recipe replay y
calibración de una ejecución ya existían antes. La verificación repetida,
el sampler y runtime store/replay no. Se comprobó el feedback loop existente
contra el checkout real; las repeticiones nuevas no invocan
feedback/retención/planner.

## Comandos y resultados

Cada comando se ejecutó desde la raíz:

```sh
ERL_FLAGS='+S 4:4' rebar3 compile
ERL_FLAGS='+S 4:4' rebar3 eunit
ERL_FLAGS='+S 4:4' rebar3 ct
ERL_FLAGS='+S 4:4' rebar3 dialyzer
ERL_FLAGS='+S 4:4' rebar3 xref
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_runtime_tests
```

| Comprobación | Checkout inicial | Tras implementación |
|---|---:|---:|
| compile | PASS | PASS |
| EUnit | 199 aprobadas | 214 aprobadas |
| Common Test | 3 aprobadas | 3 aprobadas |
| Dialyzer | PASS, sin avisos | PASS, sin avisos |
| xref | PASS | PASS |
| Casos EUnit P0 nuevos | — | 15 aprobados, incluidos varios escenarios por caso |

Logs completos: [EUnit baseline](../../runtime-validation/baseline-eunit.log),
[EUnit final](../../runtime-validation/eunit.log), [CT](../../runtime-validation/ct.log),
[compile](../../runtime-validation/compile.log), [Dialyzer](../../runtime-validation/dialyzer.log),
[xref](../../runtime-validation/xref.log). También se guardan baseline compile/ct/dialyzer/xref
allí. La regresión inicial detectó un mensaje CLI cambiado,
“could not be loaded”; se corrigió y pasó la suite final.

Validado:

| Área | Comprobación real |
|---|---|
| Estabilidad | Frecuencias de outcome/cobertura normalizados, sondas estables/variables, vacío válido, exclusión de snapshot inválido, muestras insuficientes |
| Return | Referencias nuevas estables por defecto; comparador explícito devuelve not_comparable; rechazo acotado de términos grandes y scalar unstable_return |
| Executor | Target instrumentado real y API harness binaria intacta |
| Crash de verificación | Primer run correcto, segundo crash determinista; origin=verification, un crash occurrence; global coverage igual al original |
| Estado de mutación | Secuencia completa de bytes random y recetas/contadores staged igual en off/on |
| Recursos | Memoria temporal; 100 mensajes de buzón; 1000 filas ETS acotadas; pico sobrevive limpieza |
| Propiedad | 4 hijos controlados + raíz; cap 2 produce known=5, observed=2, partial=true; infraestructura excluida |
| Lifecycle hijo | Hijo anormal no cambia raíz correcta; limpieza normal no crea hallazgo anormal |
| Timeout | Targets reales busy/waiting; edad/evidencia; ring max_samples=2 conserva observaciones recientes |
| Datos ausentes | PID muerto, ETS desaparecido, samples ausentes, fallo sampler |
| Sampler bloqueado | Suspensión forzada en VM separada; timeout=150 ms, limpieza confirmada, duración total <1000 ms |
| Infraestructura | Dirty antes de verificar: 0 repeticiones; dirty en primera: siguiente omitida; fallo guardian conserva dirty-runner |
| Límites | Claves/tipos/rangos anidados inválidos; cap de slots; requested=16 con extra budget=1 produce completed=2, skipped=14 |
| Almacenamiento | Caps de representantes/grupos/payload, suppressed/dropped, índice obsoleto, corrupción, directorio interrumpido, fallo de ruta de escritura a archivo |
| Replay | Runtime round-trip, unstable de una ejecución inconcluso, harness/build mismatch, CLI VM nueva; legacy artifacts en suite anterior |
| Regresión | Todas las pruebas previas manual/automatic coverage, random/staged, recetas exactas, durable corpus, feedback y aislamiento |

Las respuestas alternas de la fixture `vary` proceden de un **proceso sincronizado
solo de prueba**, no de un scheduler aleatorio. No implica admitir
interacciones externas en harness de producción. Las fixtures dirty/guardian/stalled-sampler
se aíslan con watchdog de proceso SO; no hay atom bombs ni
asignación ilimitada de memoria/procesos. No se simulan pérdida real de energía
ni disco agotado; storage interrumpido/corrupto se comprobó creando
estado incompleto/dañado.

## Round-trip real de CLI

Prepare una fixture artificial acotada de timeout:

```sh
rebar3 compile
mkdir -p _build/runtime-demo-final/harness _build/runtime-demo-final/seeds
ERL_FLAGS='+S 4:4' erlc +debug_info -o _build/runtime-demo-final/harness \
  fixtures/runtime/efz_runtime_harness.erl
ERL_FLAGS='+S 4:4' erl -noshell -pa _build/default/lib/efz/ebin -eval '
  {ok,_}=efz_instrument:compile("fixtures/runtime/efz_runtime_sites.erl",
    #{modules=>[efz_runtime_sites],source_root=>".",outdir=>"_build/runtime-demo-final/targets"}),
  ok=file:write_file("_build/runtime-demo-final/seeds/waiting",<<"waiting">>),halt().'

ERL_FLAGS='+S 4:4' escript scripts/fuzz.escript \
  --target efz_runtime_harness --code-path _build/runtime-demo-final/harness \
  --artifacts _build/runtime-demo-final/targets --seeds _build/runtime-demo-final/seeds \
  --out _build/runtime-demo-final/out --max-iterations 0 --timeout 100 \
  --runtime-diagnostics --runtime-runs 3 --verification-budget 10 --sample-interval 5

EFZ_RUNTIME_FINDING=$(dirname "$(rg --files _build/runtime-demo-final/out/runtime-findings | rg '/artifact.input$' | head -n 1)")
ERL_FLAGS='+S 4:4' escript scripts/replay.escript \
  --runtime-finding "$EFZ_RUNTIME_FINDING" --target efz_runtime_harness \
  --code-path _build/runtime-demo-final/harness --artifacts _build/runtime-demo-final/targets --runs 3
```

Observado: campaña `completed`, 1 calibration + 2 verification executions,
3 timeout occurrences (tres fallos reales de ejecución), un crash group.
Runtime replay en otra VM: **observed timeout_waiting, 3/3**, compatibilidad
verificada. Logs: [campaña](../../runtime-validation/cli-fuzz.log),
[replay](../../runtime-validation/cli-replay.log). Use `--out` nuevo al cambiar
fixture/build local; no se migra el store anterior.

También se comprobó el **existente, sin cambios** `efz_example_target`:

```sh
mkdir -p _build/runtime-existing/seeds
ERL_FLAGS='+S 4:4' erl -noshell -pa _build/default/lib/efz/ebin -eval '
  {ok,_}=efz_instrument:compile("examples/simple_parser/efz_example_parser.erl",
    #{modules=>[efz_example_parser],source_root=>".",outdir=>"_build/runtime-existing/targets"}),
  ok=file:write_file("_build/runtime-existing/seeds/seed",<<0>>),halt().'
ERL_FLAGS='+S 4:4' escript scripts/fuzz.escript \
  --target efz_example_target --artifacts _build/runtime-existing/targets \
  --seeds _build/runtime-existing/seeds --out _build/runtime-existing/out \
  --mutation random --max-iterations 10 --timeout 100 \
  --runtime-diagnostics --runtime-runs 3 --verification-budget 20 --sample-interval 20
```

Observado: `completed`, 10 mutation executions, 6 verification executions,
0 infrastructure failures. Es una campaña smoke corta, no auditoría de fuzzing
larga; los descubrimientos/repeticiones pueden variar sin seed RNG
fijo en CLI. [Log real](../../runtime-validation/existing-harness.log).

## Benchmark — medidas reales

Driver: `bench/efz_runtime_bench.erl`, launcher `scripts/runtime_bench.escript`.
Un worker, automatic coverage preparada, presence feedback, fixture instrumentada
sin cambios y harness binario. Cada modo usa una VM con `+S 4:4`,
warmup de 100 mutaciones, cinco campañas de 1000 random mutations + 1 seed y seeds
fijos de mutación/selección. Stability/full realizan 4 ejecuciones extra cada uno
(seed y discovery); se midió, no se supuso. Tras las campañas rápidas,
`mailbox_ets` (~160 ms) se ejecuta aparte.

El baseline se compiló por separado en `/tmp/efz-p0-baseline/checkout` desde
`git archive HEAD`, el diff inicial guardado y el original untracked
`src/efz_cov_count.erl`. Incluye por tanto los cambios previos del usuario,
no solo HEAD limpio. Los modos principales se midieron secuencialmente, sin
suite/otro benchmark en paralelo. El host no era dedicado;
frecuencia/carga CPU no se fijaron.

```sh
# Each mode: warmup + five runs. The ordinary EFZ build must be ready.
ERL_FLAGS='+S 4:4' escript scripts/runtime_bench.escript baseline /tmp/efz-p0-bench/release/baseline /tmp/efz-p0-baseline/checkout/_build/default/lib/efz/ebin
ERL_FLAGS='+S 4:4' escript scripts/runtime_bench.escript off /tmp/efz-p0-bench/release/off
ERL_FLAGS='+S 4:4' escript scripts/runtime_bench.escript stability /tmp/efz-p0-bench/release/stability
ERL_FLAGS='+S 4:4' escript scripts/runtime_bench.escript resources /tmp/efz-p0-bench/release/resources
ERL_FLAGS='+S 4:4' escript scripts/runtime_bench.escript full /tmp/efz-p0-bench/release/full
ERL_FLAGS='+S 4:4' escript scripts/runtime_bench_report.escript /tmp/efz-p0-bench/release summary.csv
```

| Modo | Mediana mutation exec/s | Min–max | Mutaciones / verificación | Wall del run mediano, ms | Diagnóstico posterior, ms | Tiempo verificación, ms |
|---|---:|---:|---:|---:|---:|---:|
| baseline | 279.5 | 236.1–372.7 | 1000 / 0 | 3577.3 | 0.00 | 0.00 |
| off | 217.6 | 182.7–227.4 | 1000 / 0 | 4596.3 | 0.00 | 0.00 |
| stability | 219.6 | 212.1–224.0 | 1000 / 4 | 4553.4 | 52.37 | 4.35 |
| resources | 205.4 | 179.1–225.5 | 1000 / 0 | 4868.1 | 38.26 | 0.00 |
| full | 194.9 | 176.8–216.9 | 1000 / 4 | 5131.5 | 52.60 | 3.97 |

`runtime_diagnostic_us` es wall time del worker tras el executor inicial:
comparaciones, resumen/storage y verificación están **incluidos**.
No vuelva a sumarle `verification_elapsed_us`. El trabajo del sampler es
otra métrica en un proceso aparte. Estas filas corresponden al run con throughput
mediano, no a medianas independientes de cada contador.

Las campañas rápidas no produjeron muestras runtime: resources=0/1001 sampled/missed,
full=0/1005; stability desactiva sampler. Ceros en baseline/off significan
medición desactivada, no consumo ausente. Por tanto, la ralentización del bucle rápido
**no mide el coste de un hook de muestreo que realmente se ejecutó**.

| Modo con input largo | Wall, ms | Samples | Trabajo sampler, ms | Buffer ETS diagnóstico al terminar, bytes |
|---|---:|---:|---:|---:|
| baseline | 166.52 | 0 | 0.000 | 0 |
| off | 164.70 | 0 | 0.000 | 0 |
| stability | 166.50 | 0 | 0.000 | 2648 |
| resources | 167.44 | 7 | 1.004 | 7008 |
| full | 166.11 | 7 | 0.534 | 7008 |

El mayor buffer ETS completado en campañas rápidas fue 2648 bytes con P0 activo.
**No es toda la memoria de diagnóstico**: excluye heaps sampler/guardian y mapas
retenidos del informe. Slots residentes, hijos, bytes de informe y metadatos de disco tienen
caps separados. Targets arbitrarios con process_info/ETS caro requieren
perfil separado.

El [resumen CSV](../../runtime-validation/bench/summary.csv), raw `.term` y logs
para los cinco modos están en `docs/runtime-validation/bench/`. El mismo script
puede recalcular el resumen desde datos raw.

### Comprobación del resultado inesperado P0=off

El lote secuencial principal mostró off con **−22.2%** de throughput wall mediano.
No puede declararse ausencia de regresión. Se hizo un control
adicional en orden inverso (off primero, baseline después) con el mismo driver/fixture,
warmup y cinco campañas; `/usr/bin/time` midió además CPU de todo el proceso escript,
incluidos compilación/warmup/fixture larga; esos segundos CPU
**no son coste CPU de una mutación**:

```sh
/usr/bin/time -f 'wall_s=%e user_s=%U system_s=%S' \
  env ERL_FLAGS='+S 4:4' escript scripts/runtime_bench.escript off /tmp/efz-p0-bench/reverse/off
/usr/bin/time -f 'wall_s=%e user_s=%U system_s=%S' \
  env ERL_FLAGS='+S 4:4' escript scripts/runtime_bench.escript baseline /tmp/efz-p0-bench/reverse/baseline \
  /tmp/efz-p0-baseline/checkout/_build/default/lib/efz/ebin
```

| Control de orden inverso | Mediana mutation exec/s | Min–max | Wall proceso completo, s | CPU usuario, s | CPU sistema, s |
|---|---:|---:|---:|---:|---:|
| off | 253.0 | 248.0–258.6 | 20.78 | 57.28 | 4.30 |
| baseline | 251.6 | 223.5–259.1 | 21.59 | 59.80 | 4.66 |

Aquí off es **+0.54%** frente a baseline y no muestra aumento del tiempo CPU.
Más segundos CPU que wall es normal en una VM con varios hilos
scheduler. Se conservan ambos resultados opuestos: `bench/reverse/{off,baseline}/`
contiene raw `.term`, stdout y logs de tiempo. Muestra sensibilidad de la medida
a condiciones/orden, pero no establece una causa externa concreta.
No se demuestra ausencia estadísticamente significativa de regresión en
host dedicado.

## Resultado y límites pendientes

- **PASS funcional en este entorno:** ruta production executor/guardian,
  calibración repetida, recursos/hijos/timeouts, findings/report/replay
  independientes, límites y regresiones listadas; 214 EUnit + 3 CT,
  compile/Dialyzer/xref.
- **Aceptación de rendimiento PARTIAL:** se midieron los cinco modos;
  off no tiene degradación consistente en el control inverso, pero la variación
  impide PASS global por ausencia de regresión material.
  Hace falta control adicional en host dedicado estabilizado antes de afirmarlo.
- El muestreo no garantiza detectar picos rápidos. Enumerar ETS es parcial
  al alcanzar cap; la memoria no incluye todo off-heap.
  Heap sampler/report no se midió como pico separado: se informa
  buffer ETS real y limitaciones.
- El iniciador de una salida hija suele ser `unknown`: DOWN no prueba quién
  envió la señal. Cleanup registra su kill_requested; una carrera ambigua
  no se convierte en afirmación sobre causa exacta o fuga de procesos.
- El crecimiento de recursos dentro de un run es sospecha diagnóstica. No se demuestra
  ausencia de fugas arbitrarias, memory safety, corrección semántica, race/deadlock/livelock,
  fallos nativos ni efectos externos. Un reproducer stateful puede requerir
  historial de inputs/VM nueva. Esas extensiones no se implementan deliberadamente.
- La inyección completa de fallos power-loss/ENOSPC, otros OTP/SO y campañas
  largas de producción **NO SE EJECUTARON**. Ninguna comprobación final
  compile/test/benchmark listada tuvo comandos bloqueados por dependencias ausentes
  ni permisos.

El informe describe comprobaciones locales realmente ejecutadas; no declara
preparación productiva ni PASS completo global de todas las propiedades operativas.
