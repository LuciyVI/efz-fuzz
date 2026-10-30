# Modelo de ejecución: harness binario síncrono con descendientes controlados

[English](../../execution-isolation.md) · [Русский](../ru/execution-isolation.md) · **Español** · [简体中文](../zh-CN/execution-isolation.md) · [Todos los idiomas](../README.md)

El backend admitido funciona en una VM Erlang local con OTP 27 y una ejecución
concurrente. Contrato: **harness binario síncrono con ciclo de vida controlado de
descendientes**. La raíz implementa `Module:run(binary()) -> term()` y llama a
funciones instrumentadas normales. Los hijos usan la API de ciclo de vida:

```erlang
run(Input) ->
    Parent = self(),
    Child = efz_target:spawn(fun() ->
        Parent ! {parsed, self(), my_parser:parse(Input)}
    end),
    receive {parsed, Child, Value} -> Value end.
```

`efz_target:spawn_link/1` crea el mismo tipo de hijo propio con enlace al
proceso objetivo que lo llama. Ambas funciones aceptan `fun(() -> term())`, devuelven un PID
y solo están disponibles dentro de una ejecución. Los hijos anidados usan la misma API.
El guardian crea el proceso con una compuerta inicial cerrada, instala monitores
y trazas, registra la propiedad y devuelve el PID al padre. Solo
entonces el helper abre la compuerta. Se pasan al hijo el contexto de cobertura y la capacidad
de ciclo de vida; el resto del diccionario del proceso y su buzón son nuevos.

El retorno de la raíz determina el outcome del caso. Si importa el resultado o excepción de un
hijo sin enlace, el harness debe esperarlo y reflejarlo en su propio
resultado. EFZ no sustituye ese protocolo: los descendientes vivos se detienen forzosamente
cuando termina la raíz, y las sondas ya registradas se incluyen en la instantánea
de esa ejecución.

## Propietario independiente del ciclo de vida

```text
worker / llamante del executor
  └─ monitor ─ guardian (efz_guardian)
                  ├─ monitor del llamante
                  ├─ monitor ─ coordinator (resultado raíz + clasificación DOWN)
                  ├─ posee ─ ETS de observación y sesión trace
                  ├─ monitor ─ raíz con compuerta
                  └─ monitor ─ todos los descendientes controlados
```

El guardian no está enlazado con caller ni coordinator y usa un group leader `user`
estable. También es necesario para `application:stop(efz)`: el application
master puede terminar procesos de su grupo de E/S independientemente de los enlaces. En el
entorno admitido existe un proceso local `user`; stdout del objetivo pasa por él.

El coordinator informa `coordinator_ready` después de instalar el monitor de raíz.
La raíz no ejecuta código de usuario antes. El coordinator espera
`target_result` y `DOWN` de la raíz; el guardian controla el timeout independientemente.
La muerte del coordinator produce un outcome de infraestructura e inicia la misma limpieza.

El guardian pasa por estos estados:

```text
running
  ├─ raíz terminada/crash
  ├─ timeout
  ├─ caller DOWN (incluida cancelación de campaña)
  ├─ coordinator DOWN
  └─ spawn no admitido / límite de admisión superado
       ↓
cleaning: nuevas admisiones prohibidas
       ↓
kill raíz + descendientes + coordinator
       ↓
DOWN de cada proceso propio + barreras de entrega trace
       ↓
barrera global de loader + integridad fijada de código/contexto
       ↓
snapshot / validación / cerrar ETS / destruir sesión trace
       ↓
comprobar evidencia disponible de contaminación VM
       ↓
resultado final → caller espera también guardian DOWN
```

`kill` funciona independientemente de `trap_exit`. El plazo de limpieza es 1000 ms; se admiten como máximo
4096 procesos controlados por caso, incluida la raíz. Se comprueba el reloj
aunque el buzón no esté vacío, para que solicitudes continuas de spawn no
impidan el timeout. Son límites de ciclo de vida, no nueva configuración de mutaciones/campaña.

La sesión de trazas usa `procs` y `set_on_spawn`. Un `erlang:spawn` local normal
se detecta como **spawn no controlado**: no se inyecta contexto retrospectivamente,
y el caso se detiene como dirty runner. El guardian rastrea y mata
los descendientes locales que descubre, incluidos los anidados. Su `DOWN` puede
llegar antes de una traza spawn retrasada; se llama a `trace:delivered(Session,Pid)`
tras cada `DOWN`. Solo se permite retornar cuando se han vaciado los monitores vivos y las barreras
de entrega; un hijo descubierto tarde añade otro monitor/barrera.
Esto no depende de recorrer enlaces de forma simple ni de una única instantánea de PID.

Las semánticas de sesiones de trazas y barreras de entrega se verificaron con el
OTP 27.0 instalado, la [documentación oficial de trace](https://www.erlang.org/docs/27/apps/kernel/trace.html)
y la [documentación de trace_delivered](https://www.erlang.org/docs/27/apps/erts/erlang.html#trace_delivered/1).
Las rutas principales usan monitores reales y compuertas iniciales; las trazas añaden
comprobaciones de los límites del modelo.

## Resultado y prohibición de reutilización

Se añade lo siguiente a `outcome`, `coverage`, `coverage_status`
y `builds` existentes:

```erlang
#{execution_model => controlled_descendants,
  cleanup => #{status => confirmed,
               processes => [RootPid, ChildPid],
               survivors => [], violations => []},
  runner_reusable => true}.
```

`confirmed` confirma la terminación de procesos conocidos y el cierre de trazas, no la limpieza
completa de cualquier aplicación OTP. Si se detecta un cambio global, todos
los procesos pueden haber terminado y el runner seguir contaminado.

Si vence el plazo de limpieza o muere el propio guardian, el resultado es
`{infrastructure, #{kind => dirty_runner, ...}}`, `runner_reusable => false` y
`cleanup.status => unconfirmed`. El fallo del guardian no se declara ejecución limpia.
Los procesos que puedan sobrevivir a su pérdida requieren destruir la VM.
Si muere el caller, no recibe resultado, pero el guardian completa la limpieza
independientemente y marca la VM como dirty si corresponde.

La marca dirty se guarda en `persistent_term` bajo `{efz_guardian, dirty_runner}`.
`efz_executor:runner_status/0` devuelve `ready` o `{dirty, Reason}`. La marca
sobrevive a `efz:stop/0` y no tiene reset público: se necesita una VM nueva. Un posterior
`run/4` en una VM dirty devuelve infraestructura con
`cleanup.status => not_started` sin crear otro objetivo. Una segunda ejecución
concurrente se rechaza con `runner_busy`; no puede comprobarse el estado compartido de la VM
como aislado mientras se ejecutan casos en paralelo.

El worker detiene la campaña, incrementa `infrastructure_failures` y conserva
el input exacto, la receta y el resultado en `failure_context`. Estas
observaciones no pasan feedback correcto ni amplían la cobertura global
ni el corpus.

## Política de estado compartido

| Recurso | Política admitida | Comprobación / acción de EFZ |
|---|---|---|
| Diccionario del proceso, buzón | Solo el estado propio de raíz/hijo controlado | Se destruyen con los procesos; el siguiente caso recibe estado nuevo. |
| ETS de cobertura | Propiedad del guardian | Instantánea solo después de limpiar; tabla cerrada antes del resultado. |
| ETS propiedad del objetivo | Sin heir ni transferencia de propiedad fuera de la ejecución | Desaparece con su dueño; tablas nuevas supervivientes marcan el runner dirty. |
| ETS compartido existente | Se prohíben escrituras en este modelo | No se copian/revierten contenidos automáticamente. Para un efecto que se sabe que lo requiere, el harness llama a `efz_target:dirty(Reason)`; se necesita una VM desechable. |
| Nombres registrados | Solo para procesos propios | Se liberan tras `DOWN`. Registros nuevos/modificados que sobreviven marcan dirty; no se mata arbitrariamente un proceso externo. |
| `persistent_term` | El objetivo no debe cambiar valores globales de VM | Se comparan claves/valores antes/después; un cambio establece la marca dirty. Sin restauración automática. |
| Application env | El objetivo no debe cambiar env compartido | Se compara el env de aplicaciones cargadas; un cambio produce dirty. Una aplicación nueva sin env no se considera por sí sola una mutación del env. |
| Ports, remote spawn, timers/mensajes a procesos externos, servicios externos, archivos | Fuera del alcance compartido admitido | No se garantiza limpieza/rollback ni cancelación del trabajo remoto. Se necesita el siguiente backend. |

Las instantáneas diagnostican infracciones de un contrato cooperativo; **no son un
sandbox de seguridad**. No detectan todas las escrituras sobre ETS existente, cambios
transitorios restaurados, eliminación de registros ajenos,
mensajes a servicios externos ni falsificación deliberada de trazas/datos de protocolo.
[Integridad de cobertura](coverage-integrity.md) comprueba además daños al
contexto de cobertura EFZ y hot reload. Cambios concurrentes de código ajeno pueden
producir dirty de forma conservadora. Restaurar una instantánea de `persistent_term`/env
sobre cambios ajenos sería inseguro, por eso no se hace.

`A → dirty → A` se comprueba de dos formas. Para diccionario/buzón local,
ETS propio y registros, el tercer `A` realmente se ejecuta y devuelve el mismo
outcome y sondas. Para mutaciones globales, la segunda ejecución devuelve dirty y el
tercer `A` **no se ejecuta**. No se «reparan» deliberadamente los valores contaminados;
se retira la VM. Para aislar pruebas, estos casos corren en procesos de SO independientes.

## Siguiente backend para el alcance OTP asíncrono

Las aplicaciones OTP arbitrarias, servidores en segundo plano, NIF/ports, llamadas remotas y
servicios compartidos requieren una **VM Erlang desechable**, con dueño externo del
proceso de SO y confirmación de su terminación. Este backend todavía no está
implementado. Incluso un backend VM debe especificar por separado los efectos sobre archivos/red
y la limpieza remota. El guardian actual no sigue enlaces a otros
procesos ni presenta ese aislamiento como un problema ya resuelto.

## Evidencia de regresión

[efz_isolation_tests](../../../test/efz_isolation_tests.erl) compila un
[objetivo instrumentado](../../../fixtures/efz_isolation_target.erl) real. Comprueba normal,
crash, timeout, trap_exit, hijos enlazados/no enlazados/anidados, muerte de caller/coordinator,
spawns cerca del deadline, limpieza de registros/ETS y coincidencia del contexto de cobertura
hijo. Tras un caso admitido, todos los PID del informe de propiedad deben estar muertos,
incluidos procesos que murieron aún en la compuerta inicial.

VM nuevas independientes comprueban persistent_term/env/shared ETS, ETS/nombres escapados,
spawn no gestionado normal/anidado, pérdida del guardian y el informe dirty de campaña.
La prueba de fallo del guardian demuestra primero `unconfirmed` y la prohibición de reutilizar,
y después termina por sí misma los procesos de prueba restantes: esto no se presenta como
limpieza del executor. Los logs están en `_build/isolation-test/`.
Las regresiones generales de cobertura, crash/replay y `A → AB → ABC` siguen
verificando el pipeline existente.

Si un fallo primario de infraestructura (por ejemplo, `coordinator_down`) coincide
con limpieza dirty, `outcome` conserva la primera causa. `coverage_status`,
`cleanup` y `runner_reusable => false` registran que la VM no se puede reutilizar;
el siguiente input se rechaza como dirty runner. La regresión `coordinator_dirty`
comprueba esta combinación en una VM independiente.

La pérdida tardía del guardian después de una respuesta real se comprueba aparte en
`efz_crash_retention_tests`: una transformación AST exclusiva de prueba añade una compuerta
tras enviar el mensaje en una VM privada. Tras morir el coordinator, la respuesta
contiene el error original; el guardian termina anormalmente después. Informe/stats
conservan la causa original, `guardian_failure` describe la secundaria
y `execution_evidence` conserva la limpieza/cobertura originales. Se retira el runner
y no empieza el siguiente objetivo. Producción no tiene opción de inyección
de fallos.

## Observaciones runtime opcionales

P0 muestrea solo procesos admitidos por el guardian y sus propietarios ETS. Añade un
monitor/ciclo de vida acotado de sampler al guardian; propiedad, compuertas, barreras de traza
y reglas dirty-runner siguen siendo la autoridad. El fallo del sampler aporta evidencia diagnóstica
parcial; un fallo del guardian o del ciclo de vida no confirmado aún retira la VM. Las muertes de
limpieza no son fugas de procesos. Véase [diagnóstico runtime](runtime-diagnostics.md).

### VM externas independientes

La VM persistente del proveedor Erlamsa sólo genera mutaciones y no ejecuta el objetivo. Su ciclo de vida no cambia la ejecución aislada predeterminada del objetivo. Véase la [guía del worker](erlamsa-performance.md).
