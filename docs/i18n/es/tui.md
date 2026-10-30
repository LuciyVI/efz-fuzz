# Panel de EFZ en terminal

[English](../../tui.md) · [Русский](../ru/tui.md) · **Español** · [简体中文](../zh-CN/tui.md) · [Todos los idiomas](../README.md)

El visor opcional en Python/curses combina una gráfica móvil de velocidad de
ejecución y cobertura con la última entrada completada en hexadecimal/ASCII y
los nombres de las funciones cubiertas. Requiere Python 3 con curses, una
terminal UTF-8 interactiva y las herramientas habituales de OTP/Rebar. No
necesita paquetes Python ni servidor web.

Desde la raíz del repositorio:

```sh
rebar3 compile
python3 scripts/tui.py --demo --out _build/tui-demo-1
```

La demostración instrumenta el parser incluido, ejecuta 10.000 mutaciones y
contiene deliberadamente excepciones artificiales del objetivo. No prueba un
servicio externo. Utilice un directorio de salida nuevo cada vez; nunca se
reemplazan resultados existentes.

Para su propio objetivo, proporcione el mismo mapa de campaña Erlang de
confianza que acepta `efz:start/1`, incluidas las semillas binarias sin procesar
y los mapas de artefactos preparados:

```sh
python3 scripts/tui.py --config campaign.term --out _build/tui-run-1 \
  --code-path harness-ebin
python3 scripts/tui.py --attach _build/tui-run-1
```

Repita `--code-path` para las dependencias o la compilación opcional de Gleam.
Las rutas relativas de la configuración de campaña se resuelven desde la raíz
del repositorio. El lanzador fija `monitoring` en true y `crash_dir` en
OUTPUT/crashes; los demás ajustes, incluidas la identidad y política del corpus
persistente, siguen bajo control del llamador. La configuración de campaña es
configuración ejecutable local de confianza, no un hallazgo. Este lanzador usa
actualmente el modo habitual de una sola VM, no el protocolo externo de la CLI
`--supervised`.

## Pantalla y controles

- Izquierda: velocidad móvil de ejecuciones principales (calibración + mutaciones),
  cobertura acumulada, presupuesto de mutaciones, número de calibraciones,
  corpus y estadísticas de hallazgos.
- Derecha: hexadecimal y ASCII de la última entrada completada, fase, padre,
  resultado y funciones del objetivo. Las vistas de entrada se limitan a
  512 bytes y se etiquetan cuando se truncan. Las listas de funciones se limitan
  a 64 entradas; el panel muestra tres.
- Espacio fija/libera la entrada y su resultado/funciones. Las gráficas siguen
  actualizándose.
- Arriba/abajo desplazan la vista de entrada en filas de 16 bytes.
- `q` o Ctrl-C cierran solo el visor. La campaña separada continúa; se imprimen
  su PID y ruta de salida. Vuelva a conectarse con `--attach OUTPUT`.
- Se admite redimensionar la terminal. Por debajo de 90×26, un aviso de tamaño
  sustituye a los paneles. Al terminar, el resultado final sigue visible hasta
  cerrar el visor.

El puente en segundo plano escribe snapshot.json atómicamente unas dos veces
por segundo, además de campaign.log y el report.term binario habitual al
finalizar. Si el puente falla, el visor que lo lanzó lo notifica; los detalles
están en campaign.log. Para detener explícitamente una campaña separada, envíe
SIGTERM al PID del puente impreso. Esto cancela el proceso y no garantiza un
informe completo; las entradas del corpus ya admitidas de forma persistente
siguen sujetas a las garantías habituales de EFZ. Esta primera versión del
panel no incluye controles interactivos de reproducción, minimización ni
anotación de hallazgos.

## Interpretación rigurosa de los datos

La entrada corresponde a la última ejecución **completada**, no se presenta
como un contador de programa en vivo. Para cobertura ETS instrumentada desde
fuente, las sondas exactas alcanzadas se asignan a funciones de los manifiestos
proporcionados. Si no hay funciones por ejecución, el panel no fijado etiqueta
explícitamente la alternativa como **cobertura acumulada**. La cobertura nativa
de líneas sin manifiestos de funciones y las configuraciones sin cobertura
muestran datos de funciones no disponibles, en lugar de inventar una pila de
llamadas. No está implementado el muestreo de pilas en vivo.

Los porcentajes se muestran únicamente cuando se conoce el denominador de
sondas del manifiesto. La cobertura nativa se etiqueta en líneas; la manual,
en unidades manuales. Un denominador cero/no disponible produce únicamente un
recuento absoluto. Las estadísticas son acumulativas, mientras que las gráficas
conservan como máximo 120 puntos muestreados. La velocidad se basa en diferencias
de ejecuciones a lo largo del tiempo de las instantáneas; no pretende ser una
distribución de latencia por objetivo.

Los contadores de resultados incluyen calibración y mutaciones principales,
pero excluyen las llamadas adicionales de verificación de ejecución.
`Returned value` no implica éxito semántico. Solo las convenciones explícitas
`{efz_term_input_rejected, Reason}`, `rejected` y `{rejected, Reason}` se
clasifican como rechazo del códec/objetivo. Otros errores devueltos siguen
siendo valores devueltos. Las excepciones no se clasifican automáticamente
como defectos reales: los throw esperados de un parser siguen requiriendo un
contrato adecuado del harness o revisión. El contador antiguo `rejections`
de EFZ incluye también ejecuciones con cobertura equivalente; aquí no se usa
como recuento de rechazos del parser.

## Integración y sobrecoste

El valor predeterminado es `monitoring => false`. Solo las campañas que lo
activan conservan la presentación acotada de entradas y los contadores de
resultados. No se añaden extracciones del RNG ni llamadas al objetivo.
`efz_fuzzer:monitor_snapshot/0` es una API de instantáneas de solo lectura,
versión 1: devuelve una muestra en caché y solicita una actualización asíncrona.
Como máximo hay una actualización pendiente, por lo que un objetivo lento no
bloquea al coordinador ni crea una cola ilimitada de consultas. La muestra
final se publica antes del informe de campaña. El formato opcional de vistas
previas, la asignación de funciones y la materialización muestreada de cobertura
tienen un coste; no se afirma que no exista sobrecoste.

## Validación

En OTP 27.3.4.1 / Rebar3 3.25.0:

- EUnit predeterminado: 311 pruebas superadas; EUnit completo con Gleam/XML-RPC:
  377 superadas.
- Common Test: 3 superadas; xref y Dialyzer superados.
- La integración del monitor verifica la equivalencia exacta de recetas de
  mutación y cobertura con monitorización desactivada/activada, vistas previas
  acotadas, totales finales coherentes y una API de instantáneas que responde
  cuando el objetivo está bloqueado deliberadamente.
- `python3 -m unittest discover -s test -p 'tui_test.py'`: 2 superadas; cubren el
  muestreo de velocidad y los límites del historial, la visualización de bytes
  y el saneamiento de controles de terminal.
- Una ejecución real en pseudoterminal verificó la representación de paneles,
  la fijación de entradas, la alternativa para terminal estrecha, la recuperación
  al redimensionar, la salida y la reconexión. Al lanzar la demostración y
  cerrar el visor, la campaña siguió ejecutándose; completó 10.000 mutaciones e
  informó de 7/9 sondas con `efz_example_parser:classify/1` visible.

Estas comprobaciones establecen el comportamiento admitido del panel con una
sola VM, no una monitorización sin impacto en el rendimiento ni compatibilidad
con todos los emuladores de terminal.

## Modo continuo

```sh
python3 scripts/tui.py --demo --continuous --out _build/tui-continuous-1
```

Esta demostración se ejecuta sin límite de mutaciones y admite entradas del
corpus de forma persistente en OUTPUT/corpus. El presupuesto se muestra como ∞.
Pulse `s` para dejar de planificar nuevas entradas, terminar la ejecución
acotada actual del objetivo y guardar report.term. La pantalla permanece
abierta con `stopped_by_user`; `q` sigue separando el visor sin detener la
campaña. Un monitor conectado también puede solicitar la parada. Las solicitudes
pendientes de parada/actualización se agrupan mientras el objetivo está ocupado.

Para una campaña personalizada, configure `max_iterations => infinity` en su
configuración de confianza. Configure `corpus_dir` si las entradas deben
sobrevivir a una terminación abrupta del proceso. El modo staged continuo
conserva su RNG, los cursores por contenido, el corpus de trabajo y la
configuración Gleam; añade una etapa havoc si no se seleccionó ninguna. Cuando
el planificador habitual agota un recorrido inactivo, una inserción o cambio de
bit garantizado y acotado por tamaño crea un candidato real y reproducible, en
lugar de un bucle de reintentos que solo consume CPU. Las campañas staged
continuas rechazan un límite de entrada cero: no existe una mutación legal
distinta de la única entrada vacía.

Siguen aplicándose los tiempos límite del objetivo por ejecución, los
presupuestos del oráculo y de verificación, los límites de entrada, los fallos
de infraestructura y las reglas existentes de cuarentena. Los informes
continuos conservan las últimas 1.024 decisiones explicativas con un contador
`decisions_dropped`; esto no elimina el corpus de trabajo ni los grupos de
hallazgos. Las trazas siguen acotadas. El crecimiento real del corpus y los
hallazgos distintos siguen consumiendo almacenamiento/memoria; ejecuciones
ilimitadas no significan recursos ilimitados.
