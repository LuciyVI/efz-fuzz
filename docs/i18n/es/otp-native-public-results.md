# Cobertura experimental de líneas con API pública de OTP (2026-10-03)

[English](../../otp-native-public-results.md) · [Русский](../ru/otp-native-public-results.md) · **Español** · [简体中文](../zh-CN/otp-native-public-results.md) · [Todos los idiomas](../README.md)

## Implementado

La opción coverage_backend => otp_native_public usa la cobertura nativa de
líneas documentada de OTP 27. efz_cov_native_public:compile/2 compila los
módulos objetivo con line_coverage. preflight/1 selecciona
code:set_coverage_mode(line) antes de cargar y registra el SHA256, MD5 del BEAM
y lista ordenada de líneas ejecutables de cada módulo. prepare/1 fija
{Module, BuildId, Line} a una ranura por línea y calcula la huella del esquema.
La identidad entera de línea encaja en el formato existente de metadatos del
corpus.

Antes de admitir el objetivo, efz_guardian:start/6 llama a efz_coverage:open/3,
que reinicia la cobertura nativa. Tras confirmar la limpieza,
efz_guardian:finish/2 lee mediante code:get_coverage(line, Module) y empaqueta
inmediatamente las listas de términos en un conjunto de bits usando el orden
de líneas preparado. efz_feedback:native_success/5 comprueba la novedad y
combina solo resultados exitosos. Las caídas, tiempos límite y fallos de
infraestructura no actualizan cobertura global. La aceptación del corpus
continúa por efz_worker:retain/2. El harness y código de mutación no contienen
llamadas de cobertura nativa.

La cobertura de líneas no es cobertura de puntos estructurales EFZ. No se
importa cobertura persistida entre backends o compilaciones distintas. El
backend experimental requiere una VM dedicada sin llamadas ajenas a los
módulos objetivo seleccionados: el almacenamiento de cobertura OTP pertenece
a cada módulo cargado, no a una ejecución EFZ. El guardian confirma que sus
descendientes controlados terminaron antes de leer, pero no puede aislar
llamadores arbitrarios ajenos en la misma VM. Un MD5 de módulo o lista de
líneas incompatible produce un fallo explícito de cobertura. ETS es el
predeterminado.

## Corrección

El fixture EUnit específico se superó. Comprueba estado vacío/reset, línea A,
A repetida, línea B nueva, coincidencia exacta entre líneas alcanzadas según
code:get_coverage/2 y el conjunto compacto de bits, novedad y combinación,
política de no confirmar ante caídas/tiempos límite y rechazo de esquema tras
recargar un módulo cambiado. También ejecuta la ruta real guardian/executor
con entradas exitosas, con caída y con tiempo límite, y comprueba que solo el
resultado exitoso cambia el estado global de realimentación.
Validación completa del código final: rebar3 compile PASS; rebar3 eunit
256 PASS; rebar3 ct 3 PASS; rebar3 xref PASS; rebar3 dialyzer PASS.
La PLT de Dialyzer incluye Cowboy, y el transporte determinista en memoria
tiene una anotación precisa porque el tipo de socket de Cowboy no describe
su token de referencia. El tipo de modo de code.erl de OTP 27.0 se llama
line_coverage, mientras que la documentación y runtime usan line; el arranque
llama al modo documentado mediante apply/3 para evitar un falso aviso de
contrato. Ninguna lectura usa una API no documentada.

Una comprobación breve inicial de Cowboy detectó corpus_persistence
invalid_probe: la identidad nativa usaba {line,N} como tercer miembro.
El formato existente del corpus requiere un entero positivo. Ahora es
{Module,BuildId,Line}; la ejecución corregida de 4 segundos completó
707 ejecuciones sin errores de infraestructura. No se cambió ninguna
expectativa de prueba para ocultar el fallo.

## Ejecuciones breves completas con Cowboy

Cada modo se ejecutó una vez en una VM nueva durante 30 segundos, con
Cowboy 2.19.0, los mismos cuatro módulos, 12 semillas y semilla aleatoria
424242. Son ejecuciones exploratorias únicas, no un criterio de aceptación
de rendimiento.

| Backend | Ejecuciones | Media exec/s | Mediana de ventanas exec/s | Descubrimientos | Corpus final | Errores |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| ETS | 3911 | 130.33 | 131.49 | 45 | 57 | 0 |
| bitmap-v2 | 1997 | 66.53 | 65.99 | 37 | 49 | 0 |
| OTP-public | 5889 | 196.26 | 196.58 | 35 | 47 | 0 |

Todos los modos informaron cero caídas y tiempos límite. ETS/bitmap usan
887 sondas estructurales EFZ; el nativo usa 1089 ranuras de líneas ejecutables.
Por tanto, los recuentos finales de cobertura tienen unidades distintas.
Las historias de corpus y mutación divergen porque se completan distintos
números de iteraciones. Directorios originales:
 /tmp/efz-ets-smoke-30-compare
 /tmp/efz-bitmap-smoke-30-compare
 /tmp/efz-native-public-final2-smoke-30

## Mediciones de componentes

El fixture sintético generó 1, 100 y 1000 llamadas ejecutadas en líneas fuente
separadas. Dos muestras de calentamiento precedieron a diez medidas;
100 iteraciones/muestra para 1 y 100 líneas, 20 para 1000. Los valores son
medianas de microsegundos por iteración, OTP 27.0 / ERTS 15.0, x86-64,
16 schedulers. Datos originales:
docs/performance/otp-native-public-2026-10-03.term.

| Líneas solicitadas | Reset | get_coverage | Conversión | Sin novedad | Combinación | Ciclo completo de objetivo directo |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 0.046 | 0.050 | 0.147 | 0.047 | 0.104 | 0.476 |
| 100 | 0.034 | 0.167 | 1.271 | 0.166 | 0.232 | 2.363 |
| 1000 | 0.060 | 2.670 | 13.535 | 1.291 | 1.795 | 24.637 |

El compilador emite una línea ejecutable adicional para run/0, por lo que se
alcanzaron 2, 101 y 1001 líneas. Este benchmark de componentes excluye guardian,
comprobaciones del esquema, mutación y E/S del corpus. Se repitió el benchmark
de ciclos emparejados ETS/bitmap-v2 con datos originales en
docs/performance/bitmap-v2-cycle-2026-10-03.term. Su carga e instrumentación
difieren, por lo que sus valores en microsegundos no son una comparación
nativa equivalente.

Una ruta GET real fija de Cowboy usó dos muestras de calentamiento y diez
muestras de 100 iteraciones. Mediana de reset 0.50 us, lectura pública
5.63 us, conversión 30.77 us, búsqueda sin novedad 3.37 us, combinación
4.97 us, ejecución directa del objetivo 15.08 us, ciclo local completo
68.68 us. Datos originales:
docs/performance/otp-native-public-cowboy-2026-10-03.term. La conversión
representa una parte importante de este ciclo local; get_coverage por sí
solo no. La ejecución completa EFZ promedió unos 5.1 ms por ejecución.
Estos resultados no muestran que la materialización pública sea el cuello
de botella dominante de toda la campaña. Las medidas no aíslan todos los
costes de guardian, mutación o corpus. Un lector directo seguro sigue siendo
un estudio separado con requisitos de aceptación. No se implementaron lecturas
de punteros, NIF ni backend directo DWARF.

## Reproducción

Ejecute desde efz/:

    rebar3 compile
    rebar3 eunit --module=efz_native_public_tests
    escript bench/otp_native_public_components.escript docs/performance/otp-native-public-repeat.term
    escript bench/otp_native_public_cowboy_profile.escript docs/performance/otp-native-public-cowboy-repeat.term
    ./scripts/run_cowboy_long_bench.sh --backend otp_native_public --duration 30 --seed 424242

La ejecución de 900 segundos se reserva para ejecución manual después de
superar los controles de corrección.
