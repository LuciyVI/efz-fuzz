# Cobertura bitmap v2: implementación y resultado medido

[English](../../coverage-bitmap-v2-results.md) · [Русский](../ru/coverage-bitmap-v2-results.md) · **Español** · [简体中文](../zh-CN/coverage-bitmap-v2-results.md) · [Todos los idiomas](../README.md)

Fecha: 2026-10-02. Es una continuación de la [auditoría v1](coverage-bitmap-audit.md),
no sustituye su referencia. Bitmap sigue siendo una opción explícita; `ets`
continúa como predeterminado.

## Cambios y límites

* [`efz_worker:init/1`, `execute_checked/4`](../../../src/efz_worker.erl) asignan un
  mapa de ejecución por campaña bitmap y lo pasan a cada guardian. El informe
  final incluye `bitmap_storage`: un mapa asignado, recuento de activaciones y
  reutilizaciones normales. El worker ejecuta iteraciones síncronamente y no
  activa el mapa hasta que `efz_executor:run/4` recibe el `DOWN` final del guardian.
* [`efz_guardian:finish/2`](../../../src/efz_guardian.erl) sella una observación bitmap
  exitosa compacta solo cuando la limpieza de descendientes controlados existente
  alcanza `confirmed`: admisión detenida, todos los descendientes conocidos y
  coordinador terminados, barreras de traza de proceso y globales entregadas,
  sampler de runtime detenido. Una limpieza fallida o no confirmada marca el
  runner contaminado. La muerte del guardian también se convierte en runner
  contaminado por [`efz_executor:guardian_failed/2`](../../../src/efz_executor.erl).
  Ningún mapa de esa ejecución se reactiva; la campaña se detiene. Un escritor
  tardío puede seguir mutando su asignación **retirada** tras la muerte del
  guardian, pero no puede escribir en el siguiente mapa. Este contrato cubre
  descendientes locales admitidos, no procesos remotos arbitrarios o no controlados.
* [`efz_cov_bitmap:allocate/1`, `open/2`, `seal/1`](../../../src/efz_cov_bitmap.erl)
  usan un array reutilizable de palabras `atomics` sin signo, estado activo y
  número de generación. `open/2` borra completamente 1.024 palabras para el
  mapa predeterminado de 65.536 bits y avanza la generación. Un token sellado
  de una generación anterior se rechaza incluso después de sellar una ejecución
  posterior. `Active=0` por sí solo **no** prueba que los escritores estén en
  reposo; el ciclo de vida del guardian aporta esa evidencia. Los anteriores
  `open/1`, `snapshot_bits/1`, `reset/1` y la ruta de instantáneas inmutables
  permanecen para pruebas diferenciales de bajo nivel y alternativa.
* [`efz_cov_bitmap:has_new/2`](../../../src/efz_cov_bitmap.erl) recorre palabras con
  `Current AND NOT Global` y termina al encontrar la primera nueva.
  [`efz_feedback:bitmap_sealed_success/5`](../../../src/efz_feedback.erl) deja el
  global intacto si no hay bits nuevos; si hay novedad, decodifica solo los
  bits **nuevos** para la decisión exacta `new_probes` existente y después
  combina por palabras con el global en otra operación. Caídas, exits,
  tiempos límite y fallos de infraestructura siguen sin combinar. Feedback
  accede a las operaciones bitmap mediante [`efz_coverage`](../../../src/efz_coverage.erl).
* La ruta normal de éxito de campaña ya no materializa una instantánea bitmap
  completa ni todos los IDs observados. Los mensajes de primer acierto siguen
  en la contabilidad de integridad del guardian; un recuento por palabras
  confirma que su número coincide con el mapa sellado.
  [`efz_cov_integrity:observation_count/3`](../../../src/efz_cov_integrity.erl)
  conserva clasificación/recuento de observación. La lista exacta antigua
  sigue produciéndose para fallos, llamadas de bajo nivel del executor y
  campañas con oráculos de runtime activados. El informe global final sigue
  decodificando IDs exactos. Instrumentación, API del harness, motor de
  mutación, clasificación de caídas y admisión del corpus no cambiaron.
* [`efz_config:valid_field/2`](../../../src/efz_config.erl) rechaza capacidades
  superiores a 2^26 bits (8 MiB de datos) antes del arranque; la capacidad
  debe ser positiva y divisible por 64. La predeterminada es 65.536 **bits**
  (8 KiB de datos). Una asignación v2 predeterminada usa unos 8.232 bytes para
  palabras más 56 bytes para atomics de activo/generación, además de esquema,
  IDs inversos, binarios, términos Erlang y sobrecoste del asignador.

## Máquina de estados de aislamiento y reutilización

`mapa del worker (inactivo) → activación/borrado completo por guardian → escritores controlados → limpieza confirmada por guardian → sellado → comparación del worker → confirmación opcional → decisión de corpus → siguiente activación`.

El mapa sellado no cambia mientras feedback lo lee porque el worker no inicia
otra ejecución hasta terminar ese paso de feedback/corpus. Si la limpieza no
se confirma o muere el guardian, el runner queda contaminado y el mapa antiguo
se retira con el worker/VM; se rechaza una ejecución posterior en él. Un
runner/campaña nuevos asignan otro mapa. La generación evita lecturas
accidentales mediante tokens sellados obsoletos. Una sola comprobación de
activo no elimina la carrera entre comprobación y CAS ni se usa como prueba
de liberación segura. El fin de escritores controlados y vaciado de trazas
siguen siendo el límite real de sellado.

## Verificación

Referencia antes de cambios: 241 EUnit PASS. Tras v2: 243 EUnit PASS,
3 CT PASS, xref PASS, Dialyzer PASS. Comandos:

```sh
ERL_FLAGS='+S 4:4' rebar3 eunit
ERL_FLAGS='+S 4:4' rebar3 ct
ERL_FLAGS='+S 4:4' rebar3 xref
ERL_FLAGS='+S 4:4' rebar3 dialyzer
```

[`efz_bitmap_audit_tests`](../../../test/efz_bitmap_audit_tests.erl) añade
10.000 reactivaciones A/B en un mapa, tamaño estable de asignación atomics,
rechazo de generación antigua, escritor tardío de mapa retirado controlado
por barreras y comparación de feedback ETS/v2 entre éxito, cobertura repetida,
caída y tiempo límite. [`efz_isolation_tests`](../../../test/efz_isolation_tests.erl)
añade un caso bitmap de muerte del guardian en VM nueva: limpieza no confirmada,
runner contaminado y rechazo de la siguiente ejecución.
[`efz_bitmap_contract_tests`](../../../test/efz_bitmap_contract_tests.erl) comprueba
recuentos de asignación/reutilización y rechazo de capacidad no válida.
Las pruebas diferenciales completas existentes siguen comparando IDs
observados, novedad, cobertura global y decisiones de corpus. Estas pruebas
no fuerzan una superación real del plazo de limpieza en una VM viva; la muerte
del guardian prueba de forma determinista la ruta de no confirmación/retirada.

## Protocolo de benchmark y resultados

Comandos (los archivos originales se conservan junto a este informe):

```sh
ERL_FLAGS='+S 4:4' escript bench/bitmap_bench.escript _build/bitmap-v2-benchmark-final-code
ERL_FLAGS='+S 4:4' escript bench/bitmap_audit_bench.escript _build/bitmap-v2-baseline-full-cycle.term
ERL_FLAGS='+S 4:4' escript bench/bitmap_v2_cycle_bench.escript docs/performance/bitmap-v2-cycle-2026-10-02.term
ERL_FLAGS='+S 4:4' escript bench/bitmap_v2_components.escript docs/performance/bitmap-v2-components-2026-10-02.term
```

Entorno: OTP 27.0, ERTS 15.0, Linux x86_64, Intel Core i7-1260P, `+S 4:4`.
Los drivers emparejados de campaña y ciclo completo usan dos pares de
calentamiento y 10 pares alternos. El driver de componentes usa dos
calentamientos y diez muestras de 100, 1.000 o 10.000 llamadas. La campaña de
parser ejecuta 50 mutaciones aleatorias con semilla contra
`efz_example_target`/`efz_example_parser`; corpus 4 y cobertura final 5
coincidieron en todas las muestras. Son mediciones locales breves; frecuencia
CPU, ruido del scheduler y un único harness limitan la generalización.
Las medidas v1 se tomaron antes de cambiar código en el mismo checkout y se
conservaron como [datos originales de campaña/micro v1](../../performance/bitmap-v2-v1-baseline-2026-10-02.term)
y [ciclos completos v1](../../performance/bitmap-v2-v1-full-cycle-2026-10-02.term).
Campaña/micro v2 [ejecución 1](../../performance/bitmap-v2-2026-10-02-samples.term),
[ejecución 2](../../performance/bitmap-v2-2026-10-02-final-samples.term) y
[ejecución 3 de código final](../../performance/bitmap-v2-2026-10-02-final-code-samples.term),
[ciclos completos de tres variantes](../../performance/bitmap-v2-cycle-2026-10-02.term)
y [datos de componentes](../../performance/bitmap-v2-components-2026-10-02.term)
son independientes.

Medianas en microsegundos, salvo indicación exec/s:

| Carga | ETS | bitmap-v1 | bitmap-v2 |
|---|---:|---:|---:|
| Campaña de parser, exec/s | 362 / 264 | 325 | 255 |
| Ciclo completo, 1 acierto | 4 | 411 | 195 |
| Ciclo completo, 100 aciertos | 106 | 432 | 250 |
| Ciclo completo, 1.000 aciertos | 2,832 | 985 | 773 |
| Ciclo completo, 10.000 aciertos | 9,685 | 7,143 | 6,939 |
| Ciclo completo, 10.000 aciertos repetidos | 5,805 | 10,479 | 8,731 |
| Etapa de acierto repetido, 5.000 aciertos | 927 / 1,887 | 1,546 | 2,928 |
| Borrado completo / activación | <1 (tabla ETS nueva) | 21 (benchmark solo de borrado) | 15.01 (borrado y activación, 100 llamadas/muestra) |
| Novedad, 256 locales/128 globales | 82 (IDs nuevos exactos) | 27 (bitmap nuevo) | 0.197 (salida temprana booleana) |
| Combinación, 256 locales/128 globales | 57 | 28 | 43.72 |

Para parser y aciertos repetidos, los valores ETS separados por barra son la
referencia v1 y la ejecución v2 emparejada de código final; **no** son
denominadores intercambiables. El tiempo mediano v1 fue 153,702 µs bitmap frente
a 138,236 µs ETS; v2 final fue 195,798 frente a 189,237 µs. Las medianas de
razones emparejadas exec/s bitmap/ETS fueron **0.881** v1 y **0.974** v2 final
(10 pares cada una). Las otras dos razones v2 fueron **0.938** y **0.984**;
la auditoría original informó 0.893 en su ejecución independiente anterior.
Las ejecuciones v2 muestran variación temporal importante y ninguna ventaja
fiable para el parser. Las filas de ciclo completo de tres variantes proceden
de una ejecución emparejada y son comparables como algoritmos, pero esta usa
el pequeño cambio de aciertos repetidos de la fuente v2 para ambas rutas
bitmap; las medianas históricas v1 intactas son 419, 431, 1,852, 8,844 y
8,517 µs respectivamente. La fila de novedad muestra deliberadamente contratos
de retorno distintos: ETS devuelve IDs exactos, v1 materializa otro bitmap,
v2 devuelve solo un booleano; v2 decodifica IDs nuevos exactos solo después
de `true`. Las filas reset contienen operaciones distintas y medidas ETS
submicrosegundo; use mediciones por componente del coste de reset, no una
razón de aceleración.

Medianas v2 por componente (µs/llamada, mínimos–máximos en datos originales):
borrado/activación completos **15.01**, recuento sellado disperso **25.83**,
recuento sellado denso **53.39**, sin novedad disperso **24.00**, sin novedad
denso **23.47**, novedad en primera palabra **0.084**, novedad en última
palabra del mapa **23.27** y combinación de 256 ranuras **43.72**. La etapa de
5.000 aciertos repetidos sigue siendo más lenta que ETS en todas las v2:
1,486 frente a 998 µs, 1,361 frente a 890 µs y 2,928 frente a 1,887 µs.

En muestras aisladas por componente de 10.000 llamadas, la búsqueda en
diccionario de proceso tardó **0.007 µs/llamada**, registro de integridad
**0.210**, búsqueda ETS de ranura exacta **0.100**, lectura atómica **0.021**
y `efz_cov_rt:hit/1` repetido completo **0.431**; estos costes medidos por
separado no son estrictamente aditivos. Esta configuración carece de registro
del guardian, por lo que la medida de integridad ejercita la rama de registro
ausente, no un escritor registrado de producción. La ruta repetida sigue
pagando ambas búsquedas ETS y guards aunque su bit ya esté fijado. Esas
búsquedas y recorridos completos de recuento/sin novedad son los cuellos de
botella medidos restantes de ejecuciones dispersas. El borrado completo por
defecto es más sencillo y barato que el coste combinado de recuento/comprobación
dispersa; no se añadieron palabras modificadas porque cargarían cada acierto
y necesitan un diseño separado de contabilidad concurrente y una mejora total.

## Decisión y trabajo pendiente

Corrección y compatibilidad de feedback: **PASS** para el contrato de procesos
controlados probado. Concurrencia/aislamiento: **PASS** para descendientes
locales admitidos, limpieza confirmada y retirada de runners contaminados;
los procesos remotos no controlados siguen fuera del contrato existente.
Memoria: **PARCIAL**: una campaña normal asigna un mapa y 10.000 reutilizaciones
mantienen sus tamaños atomics, pero no se hizo un estudio RSS prolongado.
Rendimiento: **FAIL** para cambiar el predeterminado: v2 mejora la razón
emparejada del parser, pero su mediana sigue por debajo de 1 en las tres
ejecuciones, con gran variación, y los aciertos repetidos son más lentos.
Mantenibilidad: **PARCIAL**: las rutas v1 y compacta coexisten deliberadamente
para comparación diferencial; la compacta está acoplada al ciclo de vida como
se documentó arriba.

Mantenga `coverage_backend => ets` como predeterminado. Bitmap-v2 solo está
disponible mediante selección explícita de `coverage_backend => bitmap` para
presencia automática. Revierta quitando la opción o estableciendo
`coverage_backend => ets`. Antes de reconsiderar el predeterminado, repita
campañas emparejadas del parser y otros harnesses representativos, ejecute una
prueba larga de RSS/recursos y perfile si dominan las búsquedas de acierto o
los recorridos completos dispersos. No adopte seguimiento de palabras
modificadas ni cobertura nativa OTP sin su propio caso medido de
corrección/rendimiento.
