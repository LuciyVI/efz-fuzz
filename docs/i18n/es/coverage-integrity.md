# Integridad de la cobertura automática

[English](../../coverage-integrity.md) · [Русский](../ru/coverage-integrity.md) · **Español** · [简体中文](../zh-CN/coverage-integrity.md) · [Todos los idiomas](../README.md)

El contrato se aplica al ejecutor con [ciclo de vida controlado de descendientes](execution-isolation.md).
Una lista vacía de sondas no demuestra por sí sola que la observación funcione. EFZ comprueba
el código cargado, el contexto de conexión, los errores del hook y la conservación de las sondas
ya publicadas, independientemente del valor devuelto con éxito por el harness.

## Identidades fijadas

`efz_config:prepare/1` construye `execution_identities`:

```erlang
#{harness => #{module => my_harness, beam_md5 => <<...>>,
               build_id => undefined, attributes_sha256 => <<...>>,
               compile => [...]},
  modules => #{my_parser => #{module => my_parser, beam_md5 => <<...>>,
                             build_id => <<...>>, attributes_sha256 => <<...>>,
                             compile => [...]}}}.
```

El harness se fija por separado, aunque no esté instrumentado ni incluido en
`artifacts`. `build_id => undefined` es lo esperado para un harness normal.
La identidad procede del **código cargado** mediante
`erlang:get_module_info/1`, no de un archivo encontrado en la ruta de código. `beam_md5` es
la suma de comprobación OTP del código ejecutable, no el SHA-256 del BEAM completo;
los atributos y metadatos de compilación se comprueban por separado.
[OTP explica la diferencia entre la suma del código y los atributos de compilación](https://www.erlang.org/doc/apps/stdlib/beam_lib#md5/1).

La comprobación previa compara el manifiesto sidecar con el integrado y después
compara la suma del código BEAM del artefacto y su manifiesto con el módulo cargado. Copiar
un manifiesto antiguo en otra implementación ya no permite superar la validación.
`efz_cov_manifest:prepare/2` guarda las identidades cargadas de los módulos seleccionados en
un plan de validación protegido.

El worker pasa las identidades fijadas de la campaña a ambos modos: `prepared` y
`per_execution`. Se incluyen en los resultados, los metadatos retenidos y
el informe final. `builds` representa las **compilaciones seleccionadas esperadas**;
si una comprobación de identidad falla, no puede interpretarse como confirmación de que se
haya ejecutado el código anterior.

Un `efz_executor:run/4` independiente sin `execution_identities` fija el harness
para una llamada; el plan conserva las identidades de los módulos entre llamadas.
Las campañas usan las identidades creadas por `efz_config:prepare/1`. Replay compara los
objetivos/artefactos proporcionados explícitamente con los build IDs y la identidad del harness guardados en
`artifact.replay`, y después crea identidades de ejecución. El nivel inferior
`efz_recipe:execute/5` requiere `expected_harness`; una receta de mutación por sí sola no
demuestra la versión anterior del harness. El hash de atributos usa ETF determinista
para coincidir entre VM. Detalles: [replay](replay.md).

## Comprobaciones de sustitución

El guardian compara las identidades antes de iniciar el objetivo y después de su terminación.
Durante la ejecución, una sesión de trazas OTP independiente observa solicitudes de carga/borrado de
módulos seleccionados a través de `code_server`, incluidas cargas por lotes `code:finish_loading/1`
con código preparado antes de ejecutar. Un intento de cargar un módulo seleccionado hace
que el resultado deje de ser fiable, aunque después se restaure el BEAM original.
Es una regla conservadora: también se rechazan la recarga de bytes idénticos o un intento fallido
de sustituir un módulo seleccionado. Se permite cargar dependencias nuevas normales
mediante el servidor de código si no forman parte de las identidades fijadas.

También se rastrean ERTS `delete_module/1` y `finish_after_on_load/2` para módulos seleccionados,
y `finish_loading/1` fuera del servidor de código. Un commit directo de ERTS
produce conservadoramente `unsupported_direct_code_loading`: los handles opacos del código preparado
no permiten filtrar de forma fiable los módulos seleccionados. Esto cubre
la sustitución mediante ERTS seguida de restauración de la compilación original.

Antes del resultado final, el guardian espera DOWN y las barreras de traza de todos
los procesos propios; después, una barrera global de entrega de trazas del cargador, comprueba
la instantánea e identidades y elimina los recursos de ejecución. Un plan preparado
inválido o destruido también genera un fallo de infraestructura, incluso si la
instantánea está vacía.

## Estados del contexto y de observación

`efz_coverage_observers` es una tabla **ETS protegida** con nombre, propiedad del guardian.
Antes de abrir la compuerta inicial se registra `PID → expected context`; también se guardan
allí las identidades fijadas. La tabla no contiene cobertura global ni es un
«input actual» global: cada hook consulta solo el registro de su propio PID. El
ciclo de vida del guardian ya limita la VM a una ejecución local.

El hook compara el diccionario del proceso con ese registro. Por tanto, `erase()`
o un valor malformado no convierte un hook activo en inactivo. El error se envía
al guardian antes de la excepción; el objetivo no puede ocultarlo con su propio
`catch`. Trazar `put/erase` conserva pruebas de cambios del contexto aunque el
objetivo restaure la clave o muera antes de comprobar la salida. Los errores son persistentes:
un hit válido posterior no los borra. Los descendientes controlados se comprueban
igual que la raíz.

Cada sonda nueva se inserta primero síncronamente en ETS de observación y después
se comunica al guardian. Al terminar, cada mensaje debe corresponder a una fila ETS
conservada. Borrar observaciones publicadas sin reescribirlas produce
`coverage_observations_lost`. Los duplicados no crean una secuencia de mensajes idénticos.

| `coverage_observation.classification` | `state` | Significado |
|---|---|---|
| `observed_coverage` | `observed` | Observación intacta con sondas |
| `valid_empty_coverage` | `attached` | Conexión de la raíz confirmada, sin errores ni sondas |
| `broken_coverage_observation` | `failed`, `detached` o `invalid` | Error de hook, contexto, identidad o validación, u observaciones perdidas |
| `unstarted_coverage_observation` | `unattached` | El objetivo no se conectó a tiempo, por ejemplo por timeout antes de abrir la compuerta; no es una ejecución vacía correcta |

El mapa contiene `attached_processes`, `probe_count` y `reason` si ocurre un
error. Se prohíbe un outcome correcto sin conexión confirmada de la raíz.
Una infracción produce `outcome = {infrastructure, Reason}` y
`coverage_status = {error, Reason}`; `target_outcome` conserva el
resultado independiente del objetivo si se obtuvo. El worker incrementa
`infrastructure_failures`, guarda el input/resultado exacto en `failure_context`
y detiene la campaña. Las sondas parciales sirven de diagnóstico, pero no
participan en feedback correcto.

## Campañas reales sin hits y desconectadas

Llamar a una función instrumentada puede terminar en `function_clause` antes de entrar
en cualquier cuerpo de cláusula. Un harness normal puede capturar la excepción y devolver `zero`.
Esto es `valid_empty_coverage` real. Un harness que omite el objetivo para cierto
input también puede producir un resultado vacío válido. Una sola ejecución así
no demuestra una conexión incorrecta del harness.

La campaña cuenta módulos observados **en todas las observaciones intactas de ejecución**,
incluidos crashes del objetivo, por separado de la cobertura global correcta. El informe
contiene:

```erlang
#{coverage_diagnostics => #{policy => diagnostic,
    status => no_probes_observed, % or observed / manual
    observed_modules => [],
    unused_artifacts => [#{module => my_parser, build_id => <<...>>}],
    empty_executions => 1, unstarted_executions => 0, broken_observations => 0}}.
```

- `coverage_policy => diagnostic` es el valor predeterminado: la ausencia de sondas queda
  explícita en el informe y la CLI imprime un diagnóstico. La campaña puede
  terminar con estado normal.
- `coverage_policy => strict`: si la campaña termina sin ninguna sonda instrumentada
  fiable, devuelve `{infrastructure_failure, #{kind =>
  coverage_not_observed, ...}}`, incrementa el contador de fallos de infraestructura
  y la CLI devuelve **1**. No se reemplaza un error primario de infraestructura
  existente.
- Se enumera cada artefacto no utilizado aunque otros hayan emitido sondas.
  Strict requiere al menos una sonda total, no hits de todos los artefactos
  seleccionados.
- Una calibración sin hits genera una advertencia, pero no detiene las mutaciones: el primer
  input útil puede aparecer después. Esto también proporciona diagnóstico temprano para una
  campaña infinita. Los contadores `coverage_*_executions` y
  `coverage_broken_observations` están disponibles mediante `efz:stats/0`
  mientras la campaña se ejecuta.

```sh
escript scripts/fuzz.escript --target my_harness --code-path ./ebin \
  --seeds ./corpus --out ./findings --artifacts ./instrumented \
  --coverage-policy strict --max-iterations 1000
```

La política de campaña es independiente de `strict` en el parse transform, que comprueba
la compatibilidad sintáctica de Erlang durante la instrumentación. Ninguna cambia la novedad:

```text
New = Current - Global
ejecución válida correcta: Global := Global union Current
observación rota: error, sin merge ni retención
```

## Límites y validación

Esta es una comprobación de corrección en una VM compartida de confianza, no protección frente a
código Erlang hostil arbitrario. Sustituir el propio EFZ, desactivar trazas, falsificar
mensajes de protocolo/filas ETS y la ejecución remota quedan fuera del modelo admitido.
El alcance OTP asíncrono completo requiere un backend independiente de VM desechable.
El adaptador de trazas del servidor de código se verificó en OTP 27.0; sus regresiones
son obligatorias al admitir otras versiones OTP. Las comprobaciones de identidad/trazas añaden
coste; los benchmarks antiguos no caracterizan este backend tras
reforzar las comprobaciones de integridad.

[efz_integrity_tests](../../../test/efz_integrity_tests.erl) cubre normal/sin hits,
artefactos desconectados/no utilizados, política strict, novedad intacta, dictionary
erase/malformed/restore, excepciones capturadas de hooks, filas ETS perdidas, contexto de hijos,
kill, recarga previa/durante/transitoria, identidad independiente del harness,
planes preparados, manifiestos copiados, cargas atómicas públicas y commits directos ERTS.
[efz_cli_tests](../../../test/efz_cli_tests.erl) comprueba diagnostic/strict/política inválida
en VM Erlang nuevas independientes.
