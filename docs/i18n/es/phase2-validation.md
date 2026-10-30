# Registro de validación de Phase 2

[English](../../phase2-validation.md) · [Русский](../ru/phase2-validation.md) · **Español** · [简体中文](../zh-CN/phase2-validation.md) · [Todos los idiomas](../README.md)

Fecha: 2026-09-08. Todos los objetivos y corpus son fixtures artificiales locales.
Entorno: OTP 27.0, ERTS 15.0, x86_64-pc-linux-gnu; Rebar3 3.25.0.

## Línea base y alcance

El repositorio es el subdirectorio `efz/` del espacio de trabajo suministrado.
Al comenzar, README y los metadatos de la aplicación estaban modificados, y la
mayoría del código, ejemplos, pruebas y documentación de Phase 1 no estaban
seguidos por Git. No se encontraron AGENTS.md ni instrucciones adicionales del
repositorio. Se comparó el trabajo con una copia de ese estado inicial;
se preservaron los fuentes ajenos del corpus, mutador, behaviour, callback de
aplicación y supervisor raíz. No se cambiaron identidad Git, remotos, commits,
preparación de cambios ni envíos.

Antes de editar código: `rebar3 compile` pasó; `rebar3 eunit` pasó las 7 pruebas;
`rebar3 ct` pasó sin casos; `rebar3 dialyzer` pasó. No había un plugin configurado
de formato/lint. Las comprobaciones xref existentes se ejercitan en la
validación final.

El ejecutor inicial podía devolver un resultado antes de confirmar la
terminación por tiempo de espera, y la cobertura era un conjunto gen_server
compartido. Faltaban calibración inicial, almacenamiento de fallos y cierre
fiable de campañas. Estas bases se repararon en la ruta existente de ejecución/
trabajador/fuzzer; se conservaron el mutador aleatorio original y la
implementación del corpus en memoria.

## Comandos y resultados finales

| Comando | Resultado |
|---|---|
| `rebar3 compile` | Pasa; los avisos se tratan como errores |
| `rebar3 eunit` | Pasan 24 pruebas, incluidos 17 casos agrupados de Phase 2 |
| `rebar3 eunit --module=efz_phase2_tests` | Pasa; los 17 casos específicos de Phase 2 |
| `rebar3 ct` | Pasan 3 casos de integración |
| `rebar3 dialyzer` | Pasa; compiler añadido a las aplicaciones extra del PLT para las API de compilación |
| `rebar3 xref` | Pasa las comprobaciones configuradas de indefinidos/obsoletos |
| `REBAR_BASE_DIR="$EFZ_CLEAN_BUILD" rebar3 compile` con un directorio `mktemp` nuevo | Pasa; el BEAM ordinario del parser no tiene manifiesto EFZ |
| `escript examples/automatic/run.escript` | Completadas la compilación instrumentada y 500 iteraciones con el mutador real |
| `escript scripts/coverage_bench.escript` | Siete muestras medidas por modo calentado; sin umbral |
| `git diff --check` | Pasa |

Ninguna dependencia bloqueó los comandos. Los diagnósticos negativos esperados
incluyen rechazo estricto de comprensiones, `maybe` y valores predeterminados no
literales de registros, artefactos ausentes/cambiados y módulos no seleccionados.
Durante el desarrollo, la prueba de reubicación detectó la normalización de la
raíz de fuentes `.` y se corrigió. Se corrigió un fixture inválido de valor
predeterminado de registro después de que el compilador rechazara una variable
ligada en una declaración de registro. Fueron fallos de desarrollo, no de la
línea base; los resultados finales de las pruebas figuran arriba.

La compilación limpia se creó en `/tmp/efz-clean.cl22wE` sin limpiar ni restablecer
el árbol/directorio de compilación existentes. Se comprobó su parser ordinario
con `efz_cov_manifest:from_beam/1`, que devolvió
`{error,missing_instrumentation}` como se esperaba. Los resultados generados
siguen ignorados bajo `_build` o en el directorio temporal explícito de compilación.

## Evidencia concreta de retención y continuación

El mutador determinista de prueba, únicamente `test/efz_scripted_mutator.erl`, emite:

```erlang
[<<>>, <<>>, <<255>>, <<1,7>>, <<1,7>>]
```

Tras calibrar la única semilla `<<0>>`, se conserva `<<>>` como entrada 2 del corpus,
con padre 1 y `retention_reason => new_coverage`. Devuelve `{ok,empty}` y descubre
la cláusula de entrada vacía de `classify/1` en
`examples/simple_parser/efz_example_parser.erl:7:1`. En esta compilación registrada,
su identidad lógica tiene ID de sonda 2 y SHA-256 de compilación:

```text
5f11a3a9df248ba517a1ae78cfad9462d6c6453bc0565bfe27089fa4a8239b6a
```

Este ID se leyó del manifiesto/decisión generado; no se codificó como constante
en el núcleo ni en la prueba de aceptación. Los metadatos también incluyen una
referencia de ejecución y el SHA-256 de la entrada. Se rechaza la siguiente
mutación idéntica. `<<255>>` lanza la excepción artificial etiquetada y se guarda
como fallo con cobertura no vacía. La campaña continúa y conserva `<<1,7>>`,
luego rechaza su repetición.

Recuentos deterministas finales: 1 calibración, 5 ejecuciones de mutación,
2 descubrimientos, 2 rechazos equivalentes, 1 fallo y 3 entradas en el corpus.
La cobertura exclusiva de fallos no se combina; una aserción separada demuestra
que aún puede ser nueva para un resultado exitoso posterior.
`_build/phase2-acceptance.term` almacena el informe completo.

La ejecución con el mutador de producción usa `random_seed => {17,23,41}`,
semilla `<<0>>` y 500 iteraciones. Resultado medido: 5 descubrimientos,
2 fallos artificiales (1 único), 493 rechazos equivalentes, 0 tiempos de espera,
0 fallos de infraestructura y 6 entradas en el corpus. Se completa después de
ambos fallos. `_build/example-report.term` y `_build/example-report.txt`
contienen el informe; los archivos de entrada y metadatos están en
`_build/example-crashes`. Las observaciones del mutador aleatorio se distinguen
de la demostración de aceptación mediante un guion determinista.

## Cobertura tras la terminación y aislamiento

El fixture de ciclo de vida envía `{probe_recorded, self()}` solo después de que
regrese la sonda automática de entrada. Las pruebas esperan ese mensaje antes
de solicitar una terminación externa o de esperar el tiempo de espera de una
ejecución bloqueada deliberadamente. Los resultados finales comprueban cobertura
no vacía asociada a esa entrada de función, `coverage_status
=> ok` y, respectivamente, `{exit,killed}` o `{timeout,1000}`. El proceso ya está
muerto cuando se devuelve la cobertura final de timeout. Los resultados de
error, throw y exit también conservan su cobertura anterior a la terminación.
Las instantáneas inspeccionadas contienen dos sondas para cada error/throw/exit
y una para cada terminación externa/timeout, todas con `coverage_status => ok`.

EUnit escribe instantáneas inspeccionables en `_build/phase2-kill.term`,
`_build/phase2-timeout.term`, `_build/phase2-error.term`,
`_build/phase2-throw.term` y `_build/phase2-exit.term`.

Otras comprobaciones cubren contextos vacíos nuevos, conjuntos iguales de sondas
con referencias distintas para la misma entrada, sondas de entrada disjuntas
para entradas diferentes, dos contextos asociados simultáneamente, llamadas
entre módulos seleccionados, ejecuciones repetidas en el límite del plazo y
recuentos de tablas ETS sin cambios. La muerte del llamador, cancelación pública
de campaña y cierre de la aplicación durante un objetivo activo sincronizado
terminan el objetivo y el propietario del contexto. Una excepción capturada del
hook por tabla inválida sigue produciendo un resultado de infraestructura,
no un fallo del objetivo ni retroalimentación vacía exitosa.

## Observaciones del benchmark

Consulte [las muestras medidas completas](coverage.md#validación-reproducible-y-costes-adicionales).
El mismo fixture ordinario/instrumentado ejecutó 200,000 iteraciones de un bucle
recursivo de cola por muestra tras 30,000 iteraciones de calentamiento,
siete repeticiones por modo:

| Modo | Mediana | Respecto al ordinario |
|---|---:|---:|
| Ordinary | 518 us | 1.00x |
| Instrumented, no context | 5,315 us | 10.26x |
| Instrumented, active context | 67,209 us | 129.75x |

El conjunto activo contenía seis sondas en 419 palabras ETS (3,352 bytes a
8 bytes/palabra), y después se eliminó. Este bucle sintético expone el coste de
hooks/ETS; no afirma nada sobre el rendimiento integral de un parser.
No se midió OTP cover. No hay umbrales de corrección específicos de una máquina.

## Archivos cambiados respecto al árbol suministrado de Phase 1

* Adiciones de compilación/runtime: `src/efz_instrument.erl`,
  `src/efz_instrument_pt.erl`, `src/efz_cov_rt.erl`,
  `src/efz_cov_manifest.erl`, `src/efz_feedback.erl`.
* Cambios de integración existente: `src/efz.erl`, `src/efz_config.erl`,
  `src/efz_cov.erl`, `src/efz_executor.erl`, `src/efz_worker.erl`,
  `src/efz_fuzzer.erl`, `src/efz_worker_sup.erl`, `src/efz_stats.erl`,
  `src/efz_crash.erl`, `src/efz.app.src`, `rebar.config`.
* Ejemplo: cambiado `examples/simple_parser/efz_example_parser.erl`; añadidos
  `examples/simple_parser/efz_example_target.erl` y `examples/automatic/run.escript`.
* Pruebas: cambiado `test/efz_smoke_tests.erl`; añadidos `test/efz_phase2_tests.erl`,
  `test/efz_scripted_mutator.erl` y `test/efz_coverage_SUITE.erl`.
* Fixtures/benchmark: `fixtures/efz_fixture.erl`,
  `fixtures/efz_fixture_helper.erl`, `fixtures/include/efz_fixture.hrl`,
  `fixtures/efz_skipped.erl`, `fixtures/efz_record_default.erl`,
  `fixtures/efz_bench_fixture.erl`, `scripts/coverage_bench.escript`.
* Documentación: `README.md`, `docs/architecture.md`, `docs/coverage.md`,
  `docs/adr/0002-automatic-coverage.md` y este registro de validación.

Los límites restantes son explícitos: solo OTP 27.0 probado; un trabajador y un
proceso de ejecución; sin limpieza/atribución de hijos arbitrarios; la sintaxis
omitida exige modo permisivo; sin reescritura arbitraria de BEAM ni otras parse
transforms; coste considerable medido de hooks; sin cobertura completa de
ramas/CFG/estado ni sandbox de VM/SO.
