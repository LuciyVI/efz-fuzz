# Plugin del decodificador XML-RPC

[English](../../../../../examples/xmlrpc/README.md) · [Русский](../../../ru/examples/xmlrpc/README.md) · **Español** · [简体中文](../../../zh-CN/examples/xmlrpc/README.md) · [Todos los idiomas](../../../README.md)

El nuevo [conjunto de arneses de flujo de datos XML-RPC](../../xmlrpc-harness-suite.md) verifica llamadas, respuestas, fault, round trips de codificación/decodificación, dispatch local y rechazos previstos del codificador. Acepta bytes de carga útil y admite off, observation-only y guided; el ejemplo de XML crudo descrito a continuación conserva un formato de entrada separado.

El ejemplo usa [etnt/xmlrpc](https://github.com/etnt/xmlrpc) en el commit
`fb46463b2acadf164ec534d9e2033e194341c507`. Llama a
`xmlrpc_decode:payload(binary_to_list(Input))` una vez dentro de la ejecución
ordinaria de EFZ. No intervienen un servidor de red, un callback RPC, un
codificador ni una segunda ejecución del objetivo. El resultado `{error, Reason}`
del decodificador se convierte en `{rejected, Reason}`; los valores aceptados
siguen siendo términos XML-RPC reales de Erlang.

Prepare una dependencia aislada y los artefactos de cobertura exclusivos del
objetivo desde la raíz de EFZ:

```sh
git clone --no-checkout https://github.com/etnt/xmlrpc.git _build/xmlrpc-dependency
git -C _build/xmlrpc-dependency checkout --detach fb46463b2acadf164ec534d9e2033e194341c507
ERL_FLAGS='+S 2:2' rebar3 compile
ERL_FLAGS='+S 2:2' escript examples/xmlrpc/prepare.escript
GLEAM_BIN=/path/to/gleam-1.10.0 ERL_FLAGS='+S 2:2' rebar3 as gleam compile
```

La preparación rechaza otra revisión o fuentes del decodificador modificadas.
Los datos generados permanecen en `_build/xmlrpc-example/`: `dependency-ebin`,
`harness-ebin`, `instrumented`, `seeds` y `dependency-identity.term`. Añada los
directorios ebin de la dependencia y del harness a la ruta de código. Los módulos
seleccionados para instrumentación son `xmlrpc_decode` y `xmlrpc_util`; el modelo,
el adaptador y el harness quedan fuera de la cobertura del objetivo. Se requiere
`xmerl` de OTP. Aquí no se miden sus componentes internos;
`strict => false` conserva los valores predeterminados no literales de los
registros de `xmerl.hrl`, mientras se instrumenta el código ejecutable del decodificador.

```erlang
#{target => efz_xmlrpc_target,
  gleam_layer => #{adapter => efz_xmlrpc_adapter,
    adapter_options => #{string_bytes => 128,
                         methods => [<<"echo">>, <<"efz_missing_name">>]},
    structured_fraction => 10, feedback => guided, oracle => inline,
    oracle_budget => 64,
    limits => #{bytes => 4096, depth => 8, nodes => 128,
                collection => 16, operations => 1}}}.
```

La entrada canónica de EFZ sigue siendo XML en bytes sin procesar. El modelo Gleam
independiente admite `methodCall`, la declaración exacta opcional
`<?xml version="1.0"?>`, nombres de métodos/miembros no vacíos, `int`, `boolean`
(`0`/`1`), `string` explícitos y `array`/`struct` anidados. El texto es ASCII
imprimible (U+0020..U+007E), con las cinco entidades XML predefinidas. Bytes y puntos
de código coinciden solo en este dominio. Cadenas y nombres comparten el límite
`string_bytes`; los enteros son de 32 bits con signo. Los límites de colección
se aplican a los parámetros, arrays y miembros de estructuras; los nodos cuentan
la llamada, los valores y los miembros; el anidamiento de valores empieza en la profundidad uno.

El parser reconoce una gramática deliberadamente pequeña: no admite espacios
entre etiquetas, atributos, etiquetas autocerradas, entidades numéricas, DTD,
CDATA ni espacios de nombres. El objetivo puede aceptar estas entradas, pero el
modelo devuelve `skip` o el oráculo devuelve `inconclusive`; las mutaciones
ordinarias de bytes de EFZ siguen disponibles. Respuestas/faults, `i4`, doubles,
fechas, base64, nil, cadenas implícitas, texto UTF-8 no ASCII y propiedades del
codificador quedan fuera de la versión 1 del modelo. La generación y las mutaciones
admitidas producen entradas methodCall aceptadas. Los ID de operación son estables:
0 sustituir el primer escalar, 1 anteponer un escalar, 2 eliminar el primer
parámetro, 3 envolver los parámetros en un array, 4 sustituir los parámetros por
una estructura, 5 invertir los parámetros.

`xmlrpc_model_agreement`, versión 1, compara los valores esperados analizados de
forma independiente con el resultado primario proporcionado por el decodificador,
normalizando nombres que ya son átomos o charlists a binarios ASCII. Ni el modelo
ni el adaptador crean átomos a partir de la entrada. Las entradas no admitidas y
el rechazo esperado del objetivo no producen hallazgos de propiedades. Las llamadas
modeladas admitidas deben aceptarse con valores coincidentes. La observación usa
un vocabulario finito fijo para aceptación, tipos de valores, vaciedad,
profundidad e intervalos de tamaños de contenedores. Los nombres de métodos,
contenidos de cadenas y hashes del AST nunca se convierten en ID de características.

Con las rutas de dependencia/modelo disponibles, ejecute las pruebas de integración opcionales:

```sh
ERL_FLAGS='+S 2:2 -pa _build/xmlrpc-example/dependency-ebin -pa _build/xmlrpc-example/harness-ebin' \
  GLEAM_BIN=/path/to/gleam-1.10.0 rebar3 as gleam eunit --module=efz_xmlrpc_adapter_tests
```

Las pruebas indican explícitamente la ausencia de dependencias opcionales; la
compilación predeterminada ejecuta comprobaciones de descriptor/opciones sin
requerirlas. La reproducción sin procesar solo necesita los artefactos ordinarios
del harness/decodificador. La reproducción de propiedades requiere además el
plugin/modelo correspondiente y una configuración explícita de confianza; se
aplican las comprobaciones generales de identidad y predicado de EFZ sin cambios.

`escript examples/xmlrpc/benchmark_callbacks.escript` registra tres repeticiones
finitas de 10,000 llamadas por callback y por decodificador directo sin
instrumentar en `_build/xmlrpc-example/callback-measurements.term`, después de
100 llamadas de calentamiento. El informe fija la entrada anidada de 268 bytes,
los límites, hashes BEAM, opciones de compilación, OTP/ERTS y número de schedulers.
Estas mediciones excluyen el wrapper de ejecución de EFZ, el dispatcher, la
cobertura, el corpus y el bucle de campaña, y deben comunicarse por separado de
las mediciones de campañas completas. La observación y el oráculo consumen un
resultado ya obtenido y tienen cero ejecuciones medidas del objetivo.
