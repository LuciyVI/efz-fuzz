# Generar un conector a partir de una especificación Erlang

[English](../../../gleam-layer/connector-generation.md) · [Русский](../../ru/gleam-layer/connector-generation.md) · **Español** · [简体中文](../../zh-CN/gleam-layer/connector-generation.md) · [Todos los idiomas](../../README.md)

El adaptador genérico existente permite conectar una API sin un modelo Gleam
nuevo ni un adaptador específico de la biblioteca. El generador ahora lee las
declaraciones `-spec` y `-type` locales de un BEAM local de confianza para
crear el esquema de sus argumentos:

```sh
ERL_FLAGS='+S 2:2' rebar3 compile
mkdir -p _build/my_library
ERL_FLAGS='+S 2:2' erlc +debug_info -o _build/my_library path/to/my_library.erl
ERL_FLAGS='+S 2:2' escript scripts/semantic_scaffold.escript from-beam \
  _build/my_connector efz_my_target \
  _build/my_library/my_library.beam function_name 2
```

`from-beam OUTDIR HARNESS_MODULE BEAM FUNCTION ARITY` requiere una única
especificación de función sin restricciones y una exportación coincidente.
Lee los metadatos sin cargar la biblioteca ni ejecutar su callback `on_load`.
Utilice únicamente BEAM de confianza: es una herramienta de desarrollo local,
no un servicio de carga de artefactos no fiables.

La salida contiene un pequeño harness `run/1`, `campaign.term`, una semilla
codificada, instrucciones de compilación/ejecución e `inference.term`. Las
evidencias registran el SHA-256 del BEAM de entrada, el punto de entrada, el
esquema inferido, los límites comunes y las limitaciones. Nunca se reemplazan
archivos de salida existentes. Añada el directorio ebin de la biblioteca con
`--code-path` al ejecutar la campaña generada, además del directorio del harness.
El adaptador genérico requiere la compilación opcional de Gleam para los
callbacks semánticos; el harness de bytes generado solo usa el códec sin modelo.

Los tipos de argumentos admitidos son enteros acotados y rangos de enteros,
flotantes finitos, booleanos, binarios, cadenas, listas propias tipadas, tuplas
fijas, átomos individuales, uniones finitas de átomos y alias de tipos locales
no recursivos, incluidos parámetros de tipo. La longitud de los contenedores
se limita por defecto a 32; los enteros/flotantes usan el rango acotado del
códec, ±1.000.000. Los rangos explícitos de enteros conservan sus límites dentro
del intervalo de 64 bits con signo del códec. Todo el árbol de argumentos debe
respetar también los límites de profundidad, nodos y bytes. Por ello, las
especificaciones válidas grandes o muy anidadas pueden rechazarse, en lugar de
relajar sus restricciones silenciosamente.

Una especificación de tipos **no** identifica el formato de un binario, las
relaciones entre argumentos, las transiciones de estado válidas ni el significado
del valor devuelto. Revise el esquema generado antes de considerar que las
entradas cumplen el contrato de la biblioteca. En particular, el dominio acotado
generado solo define el ámbito de prueba; no enumera por completo el tipo ni
establece precondiciones semánticas. Un `binary()` puede ser JSON, UTF-8, un
resumen criptográfico o bytes arbitrarios.

Las especificaciones sobrecargadas o restringidas, tipos recursivos,
remotos/opacos, uniones heterogéneas, `term()`/`any()` generales, átomos sin
acotar, mapas, recursos y expresiones no admitidas detienen la generación con
un error explícito. Utilice un archivo de opciones explícitas en vez de suponer:

```sh
ERL_FLAGS='+S 2:2' escript scripts/semantic_scaffold.escript generic \
  _build/my_connector efz_my_target reviewed-options.term
```

No se infieren un oráculo de corrección ni una lista de excepciones permitidas.
La campaña generada mantiene el oráculo desactivado. Añada un predicado de
comportamiento revisado y documente los rechazos esperados antes de clasificar
fallos de la biblioteca. Las API con estado siguen necesitando contratos
explícitos de preparación/reinicio/limpieza y de comandos.

El mismo harness generado funciona con `gleam_layer => false`,
`feedback => observation_only` o `feedback => guided`; el modo se configura en
la campaña. Así no hacen falta implementaciones distintas del harness para los
tres modos. Esto no elimina el coste de ejecución de los callbacks, que debe
medirse.

## Ejemplo con la dependencia Cowlib incluida

Después de `rebar3 compile`, este comando genera un conector funcional sin
editar el esquema ni el harness; utilice un directorio de salida nuevo:

```sh
escript scripts/semantic_scaffold.escript from-beam \
  _build/auto-cow-qs efz_auto_cow_qs \
  _build/default/lib/cowlib/ebin/cow_qs.beam urlencode 1
```

Siga el README generado para compilar el harness y la capa Gleam opcional.
Añada `--code-path _build/default/lib/cowlib/ebin` al comando de campaña.
El argumento `binary()` de la API se convierte en un esquema binario limitado
a 32 bytes. Para cambiar de modo, modifique únicamente
`gleam_layer`/`feedback` en `campaign.term`, no el código generado. El nombre
del módulo harness debe ser distinto del nombre del módulo de la biblioteca.

Validación en OTP 27.3.4.1: el harness de Cowlib generado, sin cambios, completó
100 ejecuciones de mutación en cada modo: desactivado, solo observación y guiado,
sin caídas del objetivo ni fallos de infraestructura. Es una comprobación de
integración del conector, no una prueba de un defecto real ni una comparación
de rendimiento o capacidad de detección. Las pruebas de regresión también
compilan y ejecutan el código generado, comprueban la decodificación de semillas,
los alias locales y la procedencia, y verifican el rechazo de tipos no admitidos,
información de depuración ausente, salidas existentes y nombres de módulos
conflictivos. La extracción se prueba con un fixture `on_load` para garantizar
que no se carga el módulo de la API.
