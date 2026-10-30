# Contrato de cobertura automática

[English](../../coverage.md) · [Русский](../ru/coverage.md) · **Español** · [简体中文](../zh-CN/coverage.md) · [Todos los idiomas](../README.md)

## Entorno y métrica admitidos

Probado realmente: OTP 27.0 / ERTS 15.0, `x86_64-pc-linux-gnu`, Rebar3 3.25.0.
El MD5 del módulo compilador forma parte de las identidades de compilación.
Otras versiones OTP y arquitecturas necesitan validación; la opción de OTP
mínimo por sí sola no constituye evidencia.

La métrica predeterminada ETS y la opcional bitmap es **cobertura de sondas de
cláusulas/resultados a nivel de fuente y con ámbito de ejecución**.
Cada observación es exactamente `{Module, BuildId, ProbeId}`.
`coverage_feedback => presence` predeterminado conserva semántica exacta de
conjuntos. El experimental `coverage_feedback => hit_count` añade contadores
por identidad exacta e intervalos de recuento; consulte
[su contrato y mediciones](hit-count-experiment.md). Ningún modo tiene bitmap
hash, aristas CFG inferidas ni estado de transiciones desde la sonda anterior.
El backend bitmap opcional almacena estas sondas estructurales exactas en
posiciones sin colisiones.

La [arquitectura de almacenamiento bitmap](coverage-bitmap-architecture.md)
conserva estas sondas e identidades exactas. En campañas automáticas de presencia,
fije `coverage_backend => bitmap` y opcionalmente `coverage_bitmap_bits => 65536`,
bits, no bytes. `ets` permanece predeterminado y como alternativa de retorno.
Bitmap con cobertura manual o hit-count se rechaza antes de la campaña.
Consulte [informe de implementación v1](coverage-bitmap-implementation-report.md)
y [mediciones v2](coverage-bitmap-v2-results.md) para pruebas y compromisos medidos.
El experimental `coverage_backend => otp_native_public` usa `line_coverage` de
OTP 27+ y API documentadas de reinicio/lectura. Su característica es una línea
ejecutable; su recuento e historia del corpus no equivalen a las sondas
estructurales EFZ. Necesita artefactos nativos compilados aparte y una VM dedicada
sin llamadores ajenos de esos módulos. Consulte
[implementación y resultados breves](otp-native-public-results.md).
La lectura directa DWARF sigue sin implementar.

## Sintaxis y semántica

| Construcción | Instrumentación |
|---|---|
| Cláusulas de función, incluidas guardas/patrones binarios | Entrada del cuerpo |
| `case`, `if` | Entrada del cuerpo de la cláusula elegida |
| `receive` | Entrada de cláusula elegida y del cuerpo `after` |
| `try` | Entrada al cuerpo, cláusulas `of` y catch elegidas, cuerpo `after` no vacío |
| `fun` anónimas/con nombre | Entrada de la cláusula fun elegida |
| Expresiones anidadas | Recorrer llamadas y expresiones de función llamada, tuplas, listas, claves/valores/actualizaciones de mapas, valores/actualizaciones/accesos de registros, valores/tamaños binarios, bloques, matches (RHS), operadores, antiguo `catch` |
| Patrones y guardas | Preservados estructuralmente; sin sondas |
| `andalso`, `orelse` | Conservar reglas del operador/evaluación; recorrer cuerpos anidados, sin sondas de resultado del operador |
| Referencias fun locales/remotas | Preservar referencias; recorrer componentes de expresión dinámica |
| Comprensiones de listas/binarios/mapas | Expresión completa preservada; diagnóstico y limitación en manifiesto; rechazo en modo estricto |
| `maybe`, incluido `else` | Expresión completa preservada; diagnóstico y limitación; rechazo en modo estricto |
| Valores predeterminados no literales de registros | Preservados sin sondas internas; diagnóstico y limitación; rechazo estricto |
| Formas ejecutables desconocidas | Preservar con diagnóstico/limitación visible o rechazar estrictamente |

`strict => true` es predeterminado. `strict => false` acepta explícitamente
instrumentación incompleta e imprime diagnósticos en stderr además de guardarlos
en el manifiesto. No se afirma cobertura interna en expresiones omitidas,
aunque contengan `case` o sintaxis fun admitida. La selección de funciones sigue
bajo el compilador y atributos `-feature` del fuente. Se comparan fixtures OTP 27
de comprensiones y `maybe` en compilaciones ordinarias e instrumentadas.

EPP procesa cabeceras/macros antes de transformar. Se conservan las fronteras
de archivos incluidos en las correspondencias del manifiesto. Las anotaciones
usan API `erl_anno` y conservan columnas cuando el compilador las proporciona.
Los ID de sonda distinguen cláusulas en una misma línea. La transformación genera
formas abstractas, nunca fuentes editados con expresiones regulares.

Las sondas se anteponen dentro de cuerpos originales sin variables nuevas,
envoltorios ni código posterior a llamadas de cola existentes.
No se reevalúan expresiones ni se mueven entre fronteras de excepciones.
Las expresiones de timeout de receive permanecen en su sitio; coincidencia
selectiva y orden de cláusulas no cambian. Las pruebas comparan buzones
controlados, efectos, retornos, clase/motivo de excepciones y marcos relevantes
del objetivo. Una prueba AST comprueba que la llamada recursiva de cola permanece
al final; una ejecución de 20,000 pasos también termina.

Es preservación funcional de construcciones probadas, no equivalencia de tiempo,
reducciones, memoria, planificación ni inspección de todas las claves del
diccionario. Los objetivos no deben alterar contexto ni filas ETS propiedad de
EFZ. ETS es público para que el proceso ejecutor inserte datos; no es una
frontera de seguridad dentro de la VM.

## API de compilación y selección

```erlang
{ok, Artifact} = efz_instrument:compile("src/my_parser.erl", #{
    modules => [my_parser],             % Explicit allowlist; never all dependencies
    source_root => ".",                % Common root of source and local headers
    outdir => "_build/efz-targets",      % Separate from the ordinary build
    erl_opts => [debug_info, warnings_as_errors,
                 {i, "include"}, {d, 'MY_FEATURE'}, {d, 'LIMIT', 256}],
    code_paths => ["_build/default/lib/my_dependency/ebin"],
    strict => true
}).
{ok, Manifests} = efz_instrument:preflight([Artifact]).
```

Compile EFZ primero, `rebar3 compile`, y ponga su ebin en el code path de la VM
compiladora. La fachada asegura que la transformación esté cargada.
Compilar no inicia EFZ ni campañas. Usa `compile:noenv_file/2` con las opciones
suministradas; se excluye deliberadamente `ERL_COMPILER_OPTIONS` ambiental.
Reproduzca explícitamente includes, macros, features y code paths de su proyecto.
Las rutas relativas parten del directorio de trabajo de la VM llamadora.
Se restaura cualquier cambio temporal de code path al regresar; las llamadas
a la fachada deben serializarse dentro de la VM. Compiladores concurrentes
necesitan directorios de salida distintos.

Se rechazan otras parse transforms, incluidos atributos fuente `-compile`,
opciones de modo de salida y directorios alternativos, en vez de ejecutar
silenciosamente otra transformación detrás del manifiesto. Se preservan los
demás atributos de registros/tipos/specs. El directorio de salida no puede ser
el de fuentes, uno activo del code path ni contener BEAM ordinarios.
La fachada escribe archivos tras compilar, no los trabajadores de transformación.
Es una ruta de compilación de fuentes, no instrumentador arbitrario de BEAM
precompilados ni plugin Rebar3.

Se rechazan módulos internos/runtime EFZ y los resueltos desde la instalación
OTP. Solo se instrumentan dependencias compiladas y seleccionadas explícitamente.
El ejemplo instrumenta exactamente `efz_example_parser`; su adaptador y todos
los módulos EFZ/OTP son ordinarios. Un perfil Rebar3 superior no se presupone
capaz de instrumentar proyectos dependientes.

Un descriptor contiene `module`, `beam`, `manifest`, `build_id` y `warnings` del
compilador. Preflight requiere BEAM y sidecar, valida esquema y sondas únicas,
decodifica con seguridad el sidecar, compara su término exacto con el manifiesto
integrado y comprueba atributo `efz_manifest` y checksum del código cargado.
Se rechaza un módulo ya cargado ordinario o de otra compilación. No hay purga
automática. Use una VM nueva o descarga controlada sin usuarios activos para
cambiar compilaciones. No se compila/carga/purga por iteración.
Las identidades del arnés y módulos seleccionados se fijan al preparar campaña
y las verifica el ejecutor. Sustitución en caliente durante un caso invalida
su observación incluso si vuelve la compilación original. Consulte
[el contrato de integridad](coverage-integrity.md).

## Esquema de manifiesto y reproducibilidad

El esquema 1, versión de instrumentación 1, integra este mapa como `-efz_manifest(...)`:

```erlang
#{schema_version => 1, instrumentation_version => 1,
  metric => clause_outcome_probe, module => my_parser, build_id => <<...>>,
  toolchain => #{otp => "27", compiler => <<...>>},
  probes => [#{probe_id => 1, function => parse, arity => 1,
               kind => function_clause,
               structural_location => [{function,parse,1},1],
               source_file => "src/my_parser.erl", line => 12, column => 1}],
  limitations => []}.
```

El sidecar `my_parser.efz-manifest` codifica ese mismo mapa como término externo
Erlang. `efz_cov_manifest:from_beam/1` extrae el mapa integrado autoritativo;
`identities/1` expande sus identidades. Resuelva `{M,B,Id}` por módulo,
compilación y `probe_id`, y lea la ubicación fuente y estructural.
Un manifiesto valida una entrada por ID y otra por ruta estructural.

Build ID es SHA-256 de versión de instrumentación, versión OTP, identidad del
módulo compilador, formas preprocesadas normalizadas y opciones relevantes.
Los ID son enteros deterministas asignados por recorrido AST local ordenado;
nunca se interpretan sin módulo y compilación. Las rutas estructurales distinguen
cuerpos anidados y cláusulas en la misma línea. Sin timestamps, ID aleatorios de
compilación, contadores globales de asignación ni espacios hash pequeños.

Contrato: fuente preprocesado, opciones relevantes y toolchain admitido idénticos
producen las mismas identidades de sondas. Directorio de salida, code paths,
rutas de búsqueda de includes por sí solas, debug-info y presentación de avisos
no cambian ID; el contenido expandido de cabeceras/macros sí.
Las rutas de atributos/anotaciones bajo `source_root` común explícito se
normalizan respecto a él. Se prueba reubicar esa raíz conservando estructura
relativa. Cabeceras externas con nombres absolutos y literales sensibles a rutas,
como expansiones absolutas `?FILE`, pueden cambiar ID; no se reescriben como
si los valores runtime fueran iguales. Cambiar líneas/columnas también puede
cambiar la compilación. Es estabilidad de identidad, no promesa de metadatos
BEAM idénticos byte a byte entre directorios.

La compilación integrada incluye cada sonda; se rechazan observaciones fuera de
manifiestos fijados y la retroalimentación comprueba independientemente el mapa
completo de compilaciones. Una compilación nueva exige campaña/calibración nueva.
Nunca se traslada silenciosamente cobertura guardada entre espacios incompatibles.
Se rechaza instrumentación doble.

## API de ejecución y propiedad

```erlang
Result = efz_executor:run(my_target_adapter, Input, 100, #{
    coverage => automatic, manifests => Manifests
}).
% #{execution_ref := Ref, outcome := Outcome, target_outcome := TargetOutcome,
%   elapsed_us := Us, coverage := ExactIdentities, coverage_status := ok,
%   builds := #{my_parser => BuildId}}
```

`Outcome` es `{ok, Value}`, `{crash, Class, Reason, Stack}`, `{exit, Reason}` o
`{timeout, Milliseconds}`. Errors y throws preservan clase/motivo/pila;
las excepciones exit conservan la tupla exit de Phase 1. Objetivos matados desde
fuera producen `{exit, killed}`. La cobertura se puede leer tras cualquiera.
`{infrastructure, Reason}` y `coverage_status => {error, Reason}` se distinguen
de bugs del objetivo; `target_outcome` conserva el resultado observado cuando
existe. `run/4` de bajo nivel espera manifiestos con preflight previo.
El inicio de campaña lo hace automáticamente y exige `artifacts`; no se permite
fallback vacío/manual en modo automático.

`efz_cov:open/0` crea `{efz_context,1,ExecutionRef,Table,Owner}` con un conjunto
ETS público sin nombre. `attach/1` lo instala explícitamente en el proceso que
ejecuta bajo `'$efz_execution_context'`. `snapshot/1` y `close/1` corresponden
al propietario; el guardian ejecutor los realiza tras confirmar terminación de
raíz y todos sus descendientes controlados. Los contextos tienen referencias
y tablas independientes. `efz_cov_rt:hit/1` consulta además un registro
independiente PID/contexto del guardian. Un contexto ausente en el diccionario
solo está inactivo fuera de participantes del ejecutor. Contextos perdidos/
malformados, tablas inválidas y excepciones capturadas del hook generan errores
persistentes de infraestructura. `coverage_observation` distingue
`valid_empty_coverage` de observación rota; `coverage_diagnostics` informa
artefactos sin usar. `coverage_policy => strict` opcional hace fallar una
campaña completada sin sondas.

El ámbito es **raíz más descendientes controlados de una ejecución**.
`efz_target:spawn/1` y `spawn_link/1` admiten hijos mediante un guardian
independiente antes de asociar contexto compartido y ejecutar código hijo.
El guardian toma la instantánea después de DOWN y barreras de entrega de traza.
Los spawns locales ordinarios se detectan pero rechazan como ejecuciones
contaminadas, sin fingir cobertura completa. Servicios OTP de fondo/remotos
quedan fuera. Consulte [ciclo de ejecución y política de VM contaminada](execution-isolation.md).

La compatibilidad manual es explícita: `coverage => manual`,
`efz_cov:hit(Id)` registra `{manual,Id}`. `efz_executor:run/3` usa ese modo y
devuelve la tupla antigua. No pueden mezclarse espacios manual/automático en
una campaña. Las facilidades antiguas `reset_local/0`/`snapshot/0` son locales
al proceso; llamadores ordinarios deben preferir
`open/attach/snapshot/close` explícitos y no reiniciar un contexto del ejecutor.

## Retroalimentación y artefactos

Solo un trabajador. Las semillas iniciales usan la misma ruta e inicializan el
conjunto global exitoso antes de mutar. `calibrations` se separa de las
`executions` y `discoveries` de mutación.

La novedad exitosa es `Observed - Global`. Se combinan observaciones exitosas
nuevas; binarios nuevos con novedad no vacía entran al corpus. Se rechazan
repeticiones sin descubrimientos falsos. Crashes/exits/timeouts se guardan
independientemente y **su cobertura no se combina con el conjunto global
exitoso**. Así una entrada posterior sin fallo puede conservar sondas antes
vistas solo en un fallo.

Cada retención tiene SHA-256 de entrada, identidad del corpus y padre, referencia
de ejecución, identidades nuevas, motivo, fase y mapa de compilación.
El informe final `efz:await/1` incluye decisiones, corpus, fallos, estadísticas
y cobertura exitosa. Ejecuciones rechazadas idénticas se resumen con contador.
Las ocurrencias de fallos son directorios atómicos en
`crash_dir/SIGNATURE/OCCURRENCE/artifact.input`, `.term`, `.replay` y `.recipe`
opcional, con manifiesto de grupo. `.term` original conserva metadatos del
resultado, incluida cobertura de fallo/timeout. Consulte
[crash/replay/report](replay.md). Son diagnósticos locales, no importación segura.

## Validación reproducible y costes adicionales

`rebar3 eunit --module=efz_phase2_tests` cubre comparaciones semánticas, todos
los tipos de sonda requeridos, diagnósticos de sintaxis no admitida, llamadas
entre módulos, contextos separados, repetibilidad por entrada, terminaciones,
timeouts, muerte del propietario, cancelación, fallo de backend, identidad/
reubicación, preflight y feedback. Las pruebas de terminación esperan un mensaje
enviado tras terminar el hook de entrada esperado; no deducen un hit de un sleep.
Las pruebas en la frontera del plazo aceptan los resultados documentados de
finalización o timeout y comprueban aislamiento posterior. Las comparaciones
ordinarias/instrumentadas descargan el mismo módulo solo tras terminar sus
procesos anteriores; no se renombran llamadas autocualificadas.

`rebar3 ct` tiene tres casos: campaña automática determinista, cobertura de fallo
artificial y de timeout sincronizado. El mutador de guion de cinco entradas
vive solo en `test/`; no es el mutador de producción ni demuestra éxito aleatorio.
`examples/automatic/run.escript` también ejecuta el mutador aleatorio original
de Phase 1 durante 500 iteraciones. Consulte
[validación registrada](phase2-validation.md).

Ejecute `escript scripts/coverage_bench.escript` tras `rebar3 compile`.
Carga el mismo fixture ordinario e instrumentado en secuencia controlada,
calienta cada ruta y mide siete muestras de 200,000 iteraciones de cola.
Las medidas activas reutilizan un contexto para exponer costes de sondas;
no son ejecuciones integrales de fuzzing por segundo. La salida incluye tiempos,
reducciones, instantáneas de memoria, tiempos de compilación, tamaño ETS exacto
y sondas observadas. No se impone umbral de rendimiento. Se miden hooks EFZ,
no OTP cover.
OTP 27 / ERTS 15.0; x86_64-pc-linux-gnu. Fixture `efz_bench_fixture`,
200000 iteraciones por muestra, 7 repeticiones, 30,000 iteraciones de calentamiento
por modo.

| Modo | Mediana us | Relativo | Muestras us | Reducciones, última muestra |
|---|---:|---:|---|---:|
| ordinary | 518 | 1.00x | [619,517,517,517,530,518,518] | 200013 |
| instrumented_inactive | 5315 | 10.26x | [5315,4438,4260,4203,5532,5467,5581] | 1000017 |
| instrumented_active | 67209 | 129.75x | [71060,66993,67233,67125,67095,67232,67209] | 1401177 |

Tabla activa: 419 palabras, 8 bytes/palabra, 6 sondas únicas observadas de
6 en el manifiesto. Eliminada tras medir. Compilación: ordinaria 3387 us;
instrumentada 62202 us, mediciones únicas con preparación en frío.
Sin umbral de corrección. Instantáneas en `_build/coverage-benchmark.term`.

Estas medidas son locales del 2026-09-08. El pequeño bucle ordinario está muy
optimizado y tarda menos de un milisegundo; no deben extrapolarse ratios a un
parser real. La recolección activa fue unas 12.6 veces el coste de la ruta
instrumentada inactiva en esta ejecución. Inserción/copia ETS tiene coste
medible; las reducciones subieron de 200,013 a 1,401,177. Memoria de proceso de
última muestra: 8,816 -> 8,816 bytes ordinaria; 13,704 -> 13,704 inactiva;
21,696 -> 55,176 activa. Son instantáneas, no estimaciones de pico.
La tabla mantuvo seis entradas pese a repeticiones y se eliminó al terminar.

Un candidato de optimización es una caché de sondas ya registradas local a la
ejecución que publique cada primer hit inmediatamente en ETS del propietario
antes de cachearlo. Podría reducir inserciones duplicadas conservando cobertura
ante terminación abrupta; requiere pruebas de ciclo de vida y fallos de backend
antes de adoptarse. La implementación actual mantiene cada hit síncrono con
el almacén externo.

Siguen los límites: un trabajador, una ejecución con descendientes controlados,
compilación fuente con toolchain probado, módulos explícitos y sintaxis omitida
anterior. No se implementan otras parse transforms, binarios solo precompilados,
atribución arbitraria a procesos de fondo, campañas OTP con estado, cobertura
CFG/ramas/estado completa ni aislamiento de todos los efectos VM/SO compartidos.

## Decisiones runtime e informes de Phase 2.1

El backend `ets` predeterminado usa ahora `ets:insert_new` y avisa al guardian
al insertar por primera vez, permitiendo detectar observaciones publicadas
perdidas de la tabla. `ets_member` opcional consulta `ets:member` primero e
inserta solo si falta. **No hay caché seen local al proceso**, ID compacto/hash,
muestreo ni publicación diferida. Cada hit sigue accediendo a la tabla externa;
eliminar un backend después del primer hit no permite falsos éxitos desde caché.
Las primeras observaciones cuestan consulta más inserción y pueden ser más
lentas. Ningún backend cambia instrumentación, manifiestos, build IDs ni
correspondencias fuente.

Las campañas preparan ahora una vez el conjunto exacto de sondas permitidas.
El trabajador posee una tabla ETS sin nombre **protegida** `efz_coverage_plan`,
con las mismas identidades que el validador reconstruía en cada iteración,
marcador de esquema/modo/compilaciones e identidades de módulos cargados.
El guardian valida marcador y toda identidad observada tras terminar raíz/
descendientes. Recibe solo opciones de ejecución e identificador del plan,
no estado completo del corpus/decisiones ni manifiestos fuente del trabajador.
Es una lista permitida compartida inmutable, no un búfer de cobertura reutilizado.
Las tablas de observación siguen siendo nuevas, públicas y propias de cada
ejecución. Los planes sobreviven entre ejecuciones y se eliminan con el trabajador;
no se reutilizan planes ni observaciones entre campañas. Planes inválidos/
eliminados producen fallos de infraestructura, incluso con instantánea vacía.

```erlang
% Default campaign settings in Phase 2.1:
#{coverage_backend => ets, coverage_validation => prepared}.
% Per-execution manifest validation, retained for comparison:
#{coverage_backend => ets, coverage_validation => per_execution}.
% Optional duplicate-write suppression (compatible with either validator):
#{coverage_backend => ets_member, coverage_validation => prepared}.
```

Para llamadas repetidas `run/4` de bajo nivel, prepare explícitamente tras preflight:

```erlang
{ok, Manifests} = efz_instrument:preflight(Artifacts),
{ok, Plan} = efz_cov_manifest:prepare(automatic, Manifests),
try
    efz_executor:run(Target, Input, Timeout,
        #{coverage => automatic, coverage_backend => ets, coverage_plan => Plan})
after
    efz_cov_manifest:release(Plan)
end.
```

`prepare/2` comprueba esquema/versión de instrumentación, unicidad de sondas,
selección automática no vacía y módulos duplicados. No carga ni inspecciona
artefactos: llame primero `preflight/1`. El plan es
`{efz_cov_plan,1,Table,BuildMap}`; su marcador liga modo y compilaciones.
Es independiente del backend: ambos hooks ETS publican identidades exactas
iguales. La configuración valida el backend antes de iniciar el trabajador.

El propietario debe mantener el plan vivo hasta completar sus ejecuciones.
En la API de bajo nivel es una capacidad de solo lectura compartible con otros
llamadores y reutilizable para la misma selección/compilaciones. Otros procesos
no pueden escribir su tabla protegida. No está ligado a una referencia de
ejecución; solo lo está el almacenamiento de observaciones. Libérelo desde el
propietario al terminar todos los usuarios; su terminación también lo elimina.
Tabla eliminada, mapa de compilación cambiado, modo incorrecto o descriptor
incompatible no validan una instantánea vacía. Versiones malformadas de
descriptor fallan como infraestructura, no bugs del objetivo. Se admite un plan
válido de otro propietario.

La finalización conserva trabajador y plan para el informe hasta `efz:stop/0`
o cerrar la aplicación. Otra campaña construye otro plan. No son caché de
recarga en caliente: el código seleccionado debe ser constante durante toda
su vida. Preflight rechaza código ordinario/otra compilación ya cargados;
la validación rechaza identidades fuera del conjunto fijado. Sustituir código
tras preflight por otro que no emita sondas no se detecta con validación de
conjuntos. Preparar una vez no garantiza corrección con carga arbitraria en caliente.

`run/4` solo con `manifests` conserva validación por ejecución por compatibilidad.
`efz_cov:open/0` conserva el backend de referencia; `open(ets_member)` elige el
alternativo. Los contextos existentes mantienen esquema 1; en el alternativo
la posición de almacenamiento contiene `{ets_member, Table}`.
El contenido del contexto sigue perteneciendo a EFZ.

Los informes distinguen cuatro conceptos sin alterar la política de combinación:

* `Result.coverage`: observaciones exactas de esa ejecución, incluidas las
  anteriores a excepciones, terminaciones externas y timeouts.
* `coverage` de campaña: unión de observaciones exitosas de calibración/ejecución.
* `result.coverage` del fallo guardado: observaciones del fallo; pueden incluir
  sondas ausentes de `coverage` de campaña.
* `new_probes` de decisión: novedad elegible para retención en corpus exitoso.
  Es intencionadamente `[]` para `retention_reason => target_failure`, aunque
  el fallo haya visto una sonda nueva. No se combinan observaciones exclusivas
  de fallos en el conjunto exitoso.

El mapa adicional `timing` del informe contiene `calibration_started_at`, en
microsegundos monotónicos, `calibration_us` y `mutation_us`. Este último excluye
calibración y construcción/impresión final, pero incluye selección, mutación,
ejecución, validación, feedback, estadísticas e I/O de artefactos de fallos.
No es solo tiempo del objetivo. Inicio y limpieza del benchmark se informan aparte.

`selection_seed` opcional inicializa el RNG de selección del proceso corpus.
`random_seed` existente sigue inicializando el RNG del mutador del trabajador.
Sin `selection_seed`, el comportamiento previo no cambia; fijar solo
`random_seed` no determina toda la campaña. Comparaciones reproducibles fijan
ambos o reproducen la secuencia guardada. El replay del benchmark vive en
`bench/`, no en el mutador de producción.

Consulte [perfilado, medidas, compromisos y reproducción Phase 2.1](phase2.1-performance.md).
La tabla Phase 2 anterior es histórica, no una constante de rendimiento.

## Repeticiones diagnósticas

Los [diagnósticos runtime](runtime-diagnostics.md) opcionales comparan conjuntos
exactos de sondas de ejecución, incluida identidad de compilación.
La cobertura de verificación nunca se combina con feedback global; no se
ocultan sondas variables. Observaciones inválidas/no iniciadas no son cobertura
vacía. Una serie vacía válida tiene repetibilidad y proporción de sondas estables
100%, con marca explícita.
