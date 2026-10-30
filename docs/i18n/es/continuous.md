# Fuzzing continuo

[English](../../continuous.md) · [Русский](../ru/continuous.md) · **Español** · [简体中文](../zh-CN/continuous.md) · [Todos los idiomas](../README.md)

El bucle habitual de EFZ en una sola VM admite campañas aleatorias y
staged/Gleam sin límite mediante `max_iterations => infinity`. Las campañas
finitas mantienen sus valores predeterminados, límites de ejecuciones y
comportamiento de parada por agotamiento o inactividad.

```erlang
{ok, _} = efz:start(#{target => my_harness, seeds => [<<0>>],
    artifacts => Artifacts, mutation_mode => staged,
    max_iterations => infinity, corpus_dir => "out/corpus"}).
%% Después, desde la VM de control:
ok = efz:request_stop().
Report = efz:await(infinity).
stopped_by_user = maps:get(status, Report).
ok = efz:stop().
```

`request_stop/0` es asíncrono e idempotente. Detiene la planificación después de
la llamada/iteración actual del objetivo, respetando su tiempo límite y limpieza.
`await/1` devuelve el informe final; `stop/0` sigue siendo el cierre de la
aplicación y debe realizarse después de recuperar el informe. Una campaña que
ya terminó conserva su estado/informe original.

Para campañas desde la CLI:

```sh
escript scripts/fuzz.escript --config campaign.term --out out \
  --max-iterations infinity
# Desde otra terminal:
touch out/stop.request
```

La CLI guarda out/report.term y devuelve 0 ante una parada solicitada, salvo que
un fallo existente o una infracción de la política estricta de cobertura haga
fallar el informe. Elimine un stop.request antiguo antes de reutilizar un
directorio de salida. El modo finito de la CLI no cambia. Ctrl-C/SIGTERM termina
el proceso; no aplica este protocolo ordenado de guardado del informe. El lanzador
externo `--supervised` conserva sus propias políticas de ejecuciones finitas,
reinicios y plazos; este cambio no elimina esas protecciones.

La preparación del modo staged continuo añade havoc si no está entre las etapas
seleccionadas y calcula la identidad normal de configuración/receta a partir de
ese plan efectivo. Los cursores deterministas no se reinician. El agotamiento
por inactividad recurre a una mutación real de bytes con el mismo PRNG cuyo
estado se propaga, operaciones estándar de reproducción y un contador
`continuous_fallbacks`. Un bit cambia en una entrada no vacía; una entrada vacía
recibe un byte. El modo staged infinito requiere max_input_bytes > 0.

EFZ sigue siendo responsable de la admisión y persistencia del corpus, la
realimentación semántica, la ejecución principal del objetivo, la limpieza y la
reproducción. Las alternativas del proveedor Gleam y los presupuestos finitos
del oráculo no cambian. Nada reinicia ni recalibra toda la campaña cuando un
recorrido de mutaciones queda inactivo. Los fallos de infraestructura siguen
deteniéndola.

El modo continuo limita la lista explicativa de decisiones a 1.024 entradas y
cuenta las decisiones descartadas; las trazas acotadas de recetas y los informes
de comprobaciones de ejecución conservan sus límites. El corpus de trabajo y
los grupos de hallazgos realmente distintos no se podan automáticamente, por lo
que sigue siendo necesario planificar la capacidad de memoria y disco.

Consulte los [controles de la TUI](tui.md#modo-continuo) para la demostración
continua y la tecla `s` para detener y guardar.

## Validación

- EUnit predeterminado: 319 pruebas superadas; pruebas específicas del modo
  continuo con Gleam: 9 superadas.
- Common Test: 3 superadas; xref y Dialyzer superados; comprobaciones Python de
  la TUI: 2 superadas.
- Las pruebas específicas cubren la configuración infinita, la alternativa
  reproducible para padres vacíos y no vacíos, el agotamiento por inactividad
  sin reiniciar cursores, la continuidad del progreso, las solicitudes repetidas
  de parada y la ausencia de ejecuciones después del informe final.
- Un proveedor term/API real de Gleam se ejecuta de forma continua con
  realimentación guiada y presupuesto acotado del oráculo; una prueba de CLI
  solicita la parada mediante stop.request y verifica la salida 0 y el informe
  guardado.
- Una demostración en pseudoterminal superó 11.000 mutaciones (11.183 en la
  parada final); después, la tecla `s` guardó report.term y fijó el contador
  final. Otra ejecución de demostración persistente guardó registros input/metadata
  del corpus y se detuvo correctamente después de 761 mutaciones.

El funcionamiento continuo se establece eliminando el límite de ejecuciones y
comprobando los límites de progreso/parada; estas ejecuciones finitas de
aceptación no afirman haber probado una duración infinita ni almacenamiento
ilimitado.

## Ciclo de vida de clientes de larga duración

Las llamadas `efz:await/1` que agotan su tiempo de espera liberan sus entradas
pendientes en el coordinador. Los llamadores que mueren durante la espera
están monitorizados y también se eliminan; al finalizar correctamente, se
responde a los restantes y se liberan sus monitores.

Las solicitudes de parada siguen respondiendo mientras se ejecuta un objetivo
y las solicitudes repetidas encolan una única parada del worker. La parada
ordenada espera a que esa ejecución retorne o alcance el tiempo límite
configurado. Un fallo del worker durante una parada pendiente sigue siendo un
fallo de infraestructura en el informe final.

Una campaña continua detenida puede reiniciarse con el mismo `corpus_dir` y
`seeds => []`: las entradas guardadas se restauran y recalibran antes de
reanudar las mutaciones. Esto restaura el corpus, no la posición anterior del
generador aleatorio.
