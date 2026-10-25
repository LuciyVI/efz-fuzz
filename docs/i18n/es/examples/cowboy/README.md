# Cowboy: un objetivo pequeño para EFZ

[English](../../../../../examples/cowboy/README.md) · [Русский](../../../ru/examples/cowboy/README.md) · **Español** · [简体中文](../../../zh-CN/examples/cowboy/README.md) · [Todos los idiomas](../../../README.md)

`efz_cowboy_target:run/1` acepta **los bytes de la query string sin el `?` inicial**,
por ejemplo `<<"q=hello+world&edit">>`, y llama a `cowboy_req:parse_qs/1`.
El resultado es `{ok, Pairs}` o `{invalid, qs | limit_reached}` ante un rechazo
esperado de Cowboy. El wrapper no captura excepciones inesperadas. Cowboy
convierte sus propias excepciones del parser en `request_error`, por lo que
este harness comprueba la API pública y su semántica de errores, sin conservar
necesariamente cada causa interna.

La ejecución es síncrona en el proceso objetivo. Se usa un Req mínimo con el
campo `qs`; no se inicia un listener, una conexión ni la aplicación Cowboy.
El alcance es la decodificación de query strings en Cowboy/Cowlib. El framing
HTTP, las cabeceras, sockets, enrutamiento, handlers y procesos hijos quedan fuera.

## Ejecución

Desde la raíz **efz/**, con una copia de Cowboy compilada en un directorio hermano:

```sh
rebar3 compile
make -C ../cowboy
escript examples/cowboy/run.escript ../cowboy check
escript examples/cowboy/run.escript ../cowboy 500
```

La ruta del espacio de trabajo actual contiene `:`. El `erlang.mk` de Cowboy no
puede compilar en esa ruta (`target pattern contains no '%'`). La alternativa
verificada es una copia separada en `/tmp`; se conserva la copia original:

```sh
COWBOY_BUILD=$(mktemp -d /tmp/efz-cowboy.XXXXXX)
cp -a ../cowboy "$COWBOY_BUILD/cowboy"
make -C "$COWBOY_BUILD/cowboy"
rebar3 compile
escript examples/cowboy/run.escript "$COWBOY_BUILD/cowboy" check
escript examples/cowboy/run.escript "$COWBOY_BUILD/cowboy" 500
```

`make` descarga las dependencias fijadas en el Makefile de Cowboy. Cuando el proxy
no estaba disponible en este entorno, se verificó la compilación mediante acceso directo:

```sh
env -u HTTPS_PROXY -u HTTP_PROXY -u ALL_PROXY \
    -u https_proxy -u http_proxy -u all_proxy make -C "$COWBOY_BUILD/cowboy"
```

Para el benchmark HTTP/1 de larga duración, separado de este ejemplo, Cowboy
2.19.0 está fijado en `rebar.config` y `rebar.lock`; su ejecutor se describe en
[`docs/cowboy-long-benchmark.md`](../../cowboy-long-benchmark.md).
Este ejemplo anterior de query strings sigue usando una copia hermana de Cowboy
y se ejecuta en una VM nueva.

El ejecutor instrumenta automáticamente la lista permitida `[cowboy_req, cow_qs]`
en `_build/cowboy-targets`, verifica el BEAM/manifiesto y usa el executor estándar.
Se conservan los artefactos ordinarios de Cowboy. Se pasa el directorio include
de Cowlib para `cow_qs`. Para `cowboy_req` se usa explícitamente `strict => false`:
en la versión verificada, dos comprensiones de listas (`filter_cookies/2`,
`kvlist_to_map/2`) se conservan sin probes internos. No pertenecen a la ruta
`parse_qs/1`; las limitaciones se imprimen al compilar y se registran en el
manifiesto. No se afirma medir la cobertura completa de todo Cowboy.

El ejemplo usa el modo staged, la semilla `{17,23,41}`, el corpus inicial `[<<>>]`,
las etapas `dictionary_insert`, `bitflip`, `havoc` y un límite de entrada de
1024 bytes. El argumento de número de ejecuciones acepta 1–100000, con 500 por
omisión. Se conservan los valores predeterminados de cobertura de EFZ: validación
prepared + ETS. Los rechazos de parsing esperados cuentan como finalización
normal del objetivo, de modo que sus nuevos probes pueden ampliar el corpus.
Informe: `_build/cowboy-report.term`; fallos inesperados: `_build/cowboy-crashes/`.

## Validación local

Verificado con OTP 27.0, Rebar3 3.25.0, Cowboy 2.19.0
(`79e3fb02b31d47af6e69e8f3ba18fba291a3072a`), Cowlib 2.20.0
(`c768a804565ff5b8178ed968a5921e469d6bd7b2`). `check` ejecuta 14 comprobaciones EUnit:
entrada vacía, claves repetidas, decodificación porcentual, bytes cero/no UTF-8,
escapes mal formados, el límite de 99/100/101 claves, coincidencia exacta de los
snapshots ETS/ets_member, nuevas referencias de ejecución y retención de `a=1`
tras una mutación real de diccionario con cobertura automática. Estas comprobaciones
adicionales se ejecutan mediante `check`, por separado de `rebar3 eunit` normal,
y requieren Cowboy real.

Una ejecución local de 500 mutaciones terminó con: 1 ejecución de semilla,
20 descubrimientos, 480 rechazos, 0 fallos/timeouts/fallos de infraestructura.
Es una observación de la compilación indicada, no una constante esperada para
otras versiones. Las comprobaciones de referencia `rebar3 compile` y
`rebar3 eunit` pasaron: 62 pruebas de EFZ.
