> Este documento describe la interfaz histórica de compatibilidad QS. La guía

[English](../../../gleam-layer/user-guide.md) · [Русский](../../ru/gleam-layer/user-guide.md) · **Español** · [简体中文](../../zh-CN/gleam-layer/user-guide.md) · [Todos los idiomas](../../README.md)
> actual de plugins públicos y API genérica es [Conectar bibliotecas Erlang](connecting-erlang-libraries.md).

# Capa Gleam nativa opcional

`rebar3 compile` predeterminado y todos los objetivos EFZ ordinarios no
requieren Gleam.

Compile con el compilador fijado (no instala nada):

```sh
GLEAM_BIN=/path/to/gleam-1.10.0 ERL_FLAGS='+S 2:2' rebar3 as gleam compile
escript scripts/gleam_seeds.escript /tmp/new-qs-seeds
```

Las [evidencias de integración P2](p2-integration.md) registran compilación limpia
desactivada sin compilador, activada reproducible, runtime desactivado, trazas
BEAM directas y pruebas de frontera. Para diagnóstico de componentes en otra VM:

```sh
escript scripts/gleam_beam_bench.escript "$PWD/_build/gleam" /tmp/gleam-beam-samples.json
escript scripts/gleam_dispatch_bench.escript /tmp/gleam-dispatch-samples.json
```

Estos drivers recogen contadores y tiempos finitos sin logging de producción
ni estado de telemetría. No los ejecute junto a benchmarks de campaña.

El manifiesto de semillas está fuera del directorio de bytes originales para
que EFZ no lo use accidentalmente como entrada. El modo solo semillas puede
ejecutarse después con la capa desactivada. La generación predeterminada
produce 12 semillas distintas: valores/consulta vacíos, nombres duplicados,
bytes arbitrarios, escape porcentual malformado, 31/32 campos, valores de
127/128 bytes y entrada de formato original de 4096 bytes. El comando rechaza
un directorio/manifiesto existente. El catálogo de índices es determinista;
el esquema 2 registra versión 2 del generador, versiones runtime, límites
y SHA-256 de cada entrada. Para artefactos ETS ordinarios preparados, importe
mediante la CLI existente:

```sh
escript scripts/fuzz.escript --target efz_qs_target --artifacts /tmp/qs-ets \
  --code-path _build/default/lib/efz/ebin --seeds /tmp/new-qs-seeds \
  --out /tmp/qs-seeds-only --max-iterations 100 --mutation staged
```

Este comando no tiene opción de capa en runtime. Evidencias independientes
de aceptación/importación del objetivo y resultados breves estructurados
están en [p3-provider.md](p3-provider.md).

Primer objetivo: `efz_qs_target:run/1`, wrapper de `cow_qs:parse_qs/1` fijado.
Modelo admitido: nombres binarios no vacíos, `=` explícito, valores binarios
ordenados, codificación porcentual/plus y separadores `&`. Bytes no admitidos
o malformados siguen la ruta ordinaria. El rechazo esperado del parser
devuelve `rejected`, sin hallazgo.

Prepare artefactos nativos solo del objetivo desde Erlang:

```erlang
{ok,A}=efz_cov_native_public:compile(
  "_build/default/lib/cowlib/src/cow_qs.erl", "/tmp/qs-native",
  ["_build/default/lib/cowlib/include"]).
{ok,_}=efz:start(#{target=>efz_qs_target, seeds=>[<<"a=1">>], artifacts=>[A],
  coverage_backend=>otp_native_public, mutation_mode=>staged,
  mutation=>#{seed=>{17,23,41},stages=>[havoc]},
  timeout=>1000, max_iterations=>1000, crash_dir=>"/tmp/qs-findings",
  gleam_layer=>#{structured_fraction=>10}}).
Report=efz:await(30000).
ok=efz:stop().
```

Use rutas de código `_build/gleam/lib/efz/ebin` y dependencias Cowlib. Fracción
0 no elige ni decodifica rama estructurada. `gleam_layer=>false` desactiva
todos los callbacks y estado semántico, también en la compilación activada.
Paquete ausente u objetivo/configuración no admitidos fallan claramente al
arrancar. Hay un adaptador admitido y no hay política de oráculo diferido.
El aislamiento predeterminado no cambia.

Para la CLI existente con artefactos ETS ordinarios, añada
`--code-path _build/gleam/lib/efz/ebin --gleam-layer --structured-fraction 10
--semantic-feedback guided --semantic-oracle inline --oracle-budget 64`.
La API anterior es el flujo de preparación nativa; el descubrimiento existente
de artefactos en CLI sigue correspondiendo a pares ETS instrumentados desde
fuente.

Comprobaciones: query_model_agreement v1 compara el modelo admitido con la
salida completada del parser principal. Entrada no admitida, presupuesto
agotado, tiempo límite o excepción dan Inconclusive con motivo. No hay
llamadas adicionales al objetivo. Las características del observador tienen
un espacio exacto de 12 IDs, independiente de cobertura estructural. Los
descubrimientos solo semánticos usan corpus/planificador ordinarios.

Las [evidencias P4](p4-feedback.md) registran capturas nativas iguales, selección
real de padres solo semánticos, reintento de escritura, conservación tras
reinicio/subconjunto y reproducción de hallazgos.
`efz_corpus:semantic_representatives/0` devuelve un índice característica→entrada
de trabajo, de solo lectura y fuera del bucle, en modo guiado; desactivado/
solo observación devuelve `disabled`. El reinicio recalibra las entradas
actuales antes de mutar. Oráculo diferido y eliminación de corpus en línea
no están admitidos.

Mida componentes de callbacks acotados por separado de las campañas:

```sh
escript scripts/gleam_feedback_probe.escript "$PWD/_build/gleam" /tmp/feedback-costs.json
```

Este diagnóstico finito usa resultados fixture derivados del modelo y no
ejecuta el objetivo. Mide coste del callback, no corrección del parser ni
rendimiento de campaña.

Un hallazgo del oráculo conserva `.input`, `.term`, `.replay`, `.recipe`
opcional y `.semantic` con checksum. Reproducir propiedades requiere Gleam
y objetivo/artefactos nativos explícitos sin cambios; regenerar recetas y
reproducir bytes ordinarios no los necesitan. Reproduzca/minimice el fixture
artificial usado en pruebas (no es un defecto real de Cowlib):

El comando siguiente de cinco argumentos posicionales es el helper QS
heredado. Los adaptadores nuevos usan la interfaz explícita `--config` de la
[guía de conexión](connecting-erlang-libraries.md#8-comprobar-persistencia-reproducción-y-minimización).

```sh
escript scripts/gleam_replay.escript ARTIFACT_PREFIX NATIVE_ARTIFACT_DIR \
  efz_qs_defect_target 64 /tmp/qs-minimized
```

Escribe fuera del grupo inmutable de hallazgos. El minimizador cuenta todas
las ejecuciones, conserva el mismo predicado, se detiene con presupuesto finito
e informa si eliminar bytes individuales alcanzó un punto fijo. No promete
mínimo global. Detenga campañas activas antes de reproducir propiedades.

`efz_semantic:cover/1` devuelve un subconjunto conservador de las uniones
registradas de sondas, recuentos y características semánticas; no elimina
archivos del corpus. Las entradas iniciales o sin calibrar siguen protegidas.
El reinicio reconstruye características mediante calibración normal de semillas,
contada por separado de las mutaciones.

No se afirma ventaja de rendimiento ni fracción óptima. La regresión final
P5 y aceptación de campañas finitas están en [p5-validation.md](p5-validation.md);
las muestras de componentes P2 solas no cierran ese criterio.
P3 informa intentos/éxitos, IDs de operación, alternativas por no
admitido/límite/sin cambios, errores de capa, bytes generados y microsegundos
agregados de callbacks. Para muestras finitas separadas por componente
(decodificación / mutación del núcleo / codificación / proveedor completo):

```sh
escript scripts/gleam_provider_probe.escript "$PWD/_build/gleam" \
  artifacts/gleam-layer/20261008-p3-provider/p2-model-original.beam /tmp/provider.json
```

El BEAM del modelo P2 es evidencia local, no una dependencia runtime distribuida.
Las recetas estructuradas usan ahora esquema 3 con procedencia RNG exacta;
los esquemas 1/2 antiguos siguen reproduciéndose sin Gleam. Ni recetas ni
metadatos cambian las entradas originales canónicas del corpus.
