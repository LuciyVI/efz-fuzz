# Mutación nativa por etapas (versión del motor 1)

[English](../../mutations.md) · [Русский](../ru/mutations.md) · **Español** · [简体中文](../zh-CN/mutations.md) · [Todos los idiomas](../README.md)

La mutación por etapas es opcional. Las campañas existentes siguen usando
`efz_mutator_random` y su behaviour `mutate/2`. La cobertura predeterminada sigue
siendo validación preparada y el hook ETS original;
`coverage_backend => ets_member` permanece disponible. Ningún modo de mutación
cambia identidades de sondas, gestión de excepciones, calibración de semillas
ni la política de combinar solamente cobertura exitosa.

```erlang
{ok, Artifact} = efz_instrument:compile("examples/staged/efz_staged_parser.erl",
    #{modules => [efz_staged_parser], source_root => ".",
      outdir => "_build/my-staged-target"}),
{ok, _} = efz:start(#{target => efz_staged_parser, artifacts => [Artifact],
    seeds => [<<0>>], mutation_mode => staged, max_iterations => 200,
    max_input_bytes => 64,
    mutation => #{seed => {17,23,41},
        dictionary => [<<"TOKEN">>, <<"BOOM!">>],
        stages => [dictionary_insert,boundary,arithmetic,havoc,splice],
        max_block_bytes => 16, max_token_bytes => 16,
        attempts_per_visit => 8, havoc_depth => 4, random_retries => 4,
        max_idle_visits => 256, trace_limit => 0}}),
Report = efz:await(30000),
ok = efz:stop().
```

Ejecute `escript examples/staged/run.escript` después de `rebar3 compile` para
compilación completa, campaña, receta guardada de fallo y reproducción ejecutada.
Su diccionario viene de `examples/staged/tokens.hex`, no de la opción inline anterior.

## Responsabilidades y estado

* `efz_mutation:apply_operation/3` aplica una operación concreta sin decisiones
  aleatorias, lecturas del corpus, relojes, cobertura ni estado de procesos.
  `apply_operations/3` aplica una secuencia realizada ordenada a binarios intermedios.
* `efz_dictionary` analiza/normaliza tokens una vez al validar la configuración.
* `efz_mutation_plan` posee estado RNG explícito, cursores deterministas perezosos
  y planificación. Su `prepare/2` acepta opciones de mutación y binarios iniciales;
  `new/1` recibe la configuración normalizada. Trate el estado devuelto como opaco.
* `efz_corpus:mutation_entries/0` proporciona ID y bytes por orden de inserción.
  `efz_worker` pide un candidato al planificador e invoca el ejecutor y bucle
  de retroalimentación **existentes**. El modo aleatorio anterior conserva su selector.
* `efz_recipe` empaqueta operaciones y bytes concretos para regeneración
  independiente y crea contextos nuevos validados para replay. Consulte [replay.md](replay.md).

La interfaz de bajo nivel es `next(State, Entries)`, con `id` e `input` en cada
entrada. Devuelve `{candidate, Binary, Provenance, NextState}`,
`{skip, Reason, NextState}`, `{done, Reason, NextState}` o
`{error, Reason, NextState}`. Entradas/configuración deben proceder de validación;
no existe un setter admitido para alterar la configuración de un estado activo.
Los errores de planificación/aplicación son fallos de infraestructura, no del objetivo.

Configuración y diccionario permanecen congelados en el trabajador durante la
campaña. Cada cursor se identifica por `{SHA256(SeedBytes), ConfigurationId}`.
Entradas iniciales de igual contenido comparten trabajo determinista aunque
sus ID numéricos difieran. Contenido nuevo recibe cursores nuevos. No hay formato
de checkpoint para la campaña completa.

## Valores predeterminados y límites

`mutation_mode => random` es el valor público predeterminado. El modo por etapas
usa el mapa nuevo `mutation` y requiere el `mutator` predeterminado; rechaza un
callback antiguo personalizado en vez de ignorarlo. Suministrar opciones
`mutation` en modo aleatorio es un error. En modo por etapas, omitir
`max_iterations` lo fija a 1,000; un `infinity` explícito se rechaza.
El modo aleatorio mantiene la semántica anterior de presupuesto y no adquiere
implícitamente los límites del modo por etapas.

| Opción del planificador, dentro de `mutation` salvo `max_input_bytes` de campaña | Predeterminado | Límite admitido |
|---|---:|---:|
| `max_input_bytes`, derivado de campaña; API directa del planificador también lo acepta | 4,096 | 0–1,048,576 |
| `max_block_bytes` | 128 | 1–65,536 |
| `max_token_bytes` | 128 | 1–65,536; tokens reales también cumplen límite de bloque |
| `max_tokens` | 256 | 0–4,096 |
| `max_dictionary_bytes` | 16,384 | 0–1,048,576 |
| `max_delta` | 8 | 1–128 |
| `attempts_per_visit` | 8 | 1–1,024 |
| `havoc_depth` | 8 | 1–32 |
| `random_retries` | 4 | 1–128 |
| `max_idle_visits` | 256 | 1–100,000 |
| `trace_limit` | 0 | 0–10,000 recetas generadas |
| `prng` | `exsplus` | Solo `exsplus` en motor v1 |
| `seed` | Generada una vez | Tupla de tres enteros, cada uno 0–2^64−1 |
| `dictionary` | `[]` | Lista de tokens binarios no vacíos |

El `max_iterations` superior del modo por etapas permite 0–1,000,000 ejecuciones
del objetivo con mutaciones. Se aceptan hasta 4,096 semillas iniciales, cada una
dentro del límite de entrada. Las semillas excesivas fallan validación; no se
truncan. Las calibraciones se cuentan aparte, por lo que el límite total de
ejecuciones es cantidad de semillas más `max_iterations`. Límites inválidos,
nombres de etapas, etapas duplicadas, opciones desconocidas o algoritmos no
admitidos fallan antes de ejecutar el objetivo.

Un intento havoc puede aplicar hasta `havoc_depth` operaciones integrantes.
El límite de intentos acota intentos de candidatos/pilas, no cada operación de
pila; por tanto, el trabajo por visita sigue explícitamente acotado por el
producto. Los planificadores comprueban tamaños disponibles antes de construir
bloques literales. Las primitivas comprueban tamaños finales de concatenación
antes de asignar binarios candidatos. Análisis del diccionario y configuración
ocurren antes del bucle de mutación.

## Diccionarios hexadecimales EFZ

Los tokens inline son literales binarios, por ejemplo
`dictionary => [<<"TOKEN">>, <<0,255>>]`. Alternativamente, establezca
`dictionary_file => "examples/staged/tokens.hex"` dentro de `mutation`.
Pueden usarse ambas opciones: se combinan sus tokens normalizados.
La ruta se lee una vez al configurar; se sustituye por los bytes normalizados
y su identidad en el informe, sin efecto de ediciones posteriores del archivo.

El **formato de diccionario hexadecimal EFZ** contiene un token hexadecimal
de longitud par por línea:

```text
# TOKEN and the artificial crash token
544f4b454e
424f4f4d21

00ff
```

Se acepta hexadecimal en mayúsculas/minúsculas. Se recortan espacios externos
y CRLF; se ignoran líneas vacías y líneas recortadas que comiencen por `#`.
Comentarios inline, longitud impar o bytes no hexadecimales se rechazan con
número de línea. No es sintaxis de diccionarios AFL ni evalúa fuentes ni crea átomos.

Los tokens vacíos inline se rechazan; las líneas vacías se ignoran.
Se eliminan duplicados y ordenan los tokens por orden de términos binarios.
La normalización comprueba cantidad de tokens y bytes totales antes de deduplicar
cada origen; las listas combinadas se comprueban otra vez antes de deduplicar
finalmente. Los bytes de tokens deben cumplir los límites de token y bloque.
SHA-256 de la codificación normalizada de la lista da la identidad del diccionario,
independiente de orden/ruta originales. El lector impone además una cota física
`2*max_dictionary_bytes + 128*max_tokens + 4096`, incluidos comentarios/espacios.
No se trunca ningún token silenciosamente. Un diccionario normalizado vacío es
válido; sus etapas terminan o informan `dictionary_unavailable` en havoc.

## Planificación y enumeración perezosa

Las etapas ordenadas predeterminadas son:

```erlang
[bitflip,byteflip,arithmetic,boundary,
 dictionary_insert,dictionary_overwrite,havoc,splice]
```

Se permite cualquier subconjunto no vacío y sin duplicados en orden explícito.
No hay power schedule automático ni aprendizaje. El planificador toma los ID
del corpus al empezar cada ronda y los visita por inserción. Las entradas
nuevas se incorporan en la ronda siguiente, evitando que el crecimiento continuo
prive a las antiguas de ejecución. Para cada identidad de contenido, su carril
de etapa avanza circularmente, con **como máximo un candidato ejecutado por visita**.
Un barrido determinista largo no bloquea otras entradas ni etapas aleatorias activas.

En una visita determinista, skip/no-change avanza el cursor y reintenta hasta
`attempts_per_visit`; producir un candidato termina la visita. Las etapas
terminadas siguen terminadas. Solo se almacena un cursor entero por etapa;
el espacio de candidatos nunca se materializa como lista. Las tablas de anchos,
campos y valores son listas pequeñas acotadas.

El orden estable de enumeración es:

| Etapa | Orden |
|---|---|
| `bitflip` | Ancho de 1, 2, 4 bits; después cada offset de bit que encaje, ascendente |
| `byteflip` | Ancho de 1, 2, 4 bytes; después cada offset de byte que encaje, ascendente |
| `arithmetic` | Campos `(8,big)`, `(16,little)`, `(16,big)`, `(32,little)`, `(32,big)`; offset de byte válido; deltas `+1,-1,+2,-2,...,+max_delta,-max_delta` |
| `boundary` | Mismos campos y offsets; nueve patrones de frontera siguientes |
| `dictionary_insert` | Frontera de inserción ascendente, luego orden de tokens normalizados |
| `dictionary_overwrite` | Orden de tokens normalizados, luego cada offset válido ascendente |

Progreso significa producir un candidato o avanzar un cursor determinista,
incluida una operación sin efecto o limitada por tamaño. Ambos reinician el
contador de inactividad y registro de carriles visitados sin progreso.
Visitar un carril no disponible/terminado o agotar reintentos aleatorios aumenta
inactividad. Esa visita devuelve `skip`; el trabajador planifica otra visita
sin consumir presupuesto de ejecuciones del objetivo.

Mientras quede alguna operación determinista en el corpus actual, la protección
de inactividad no puede parar el planificador. Agotado todo trabajo finito,
hay dos condiciones de parada distintas:

| Condición | Motivo `done` del planificador | `status` de campaña |
|---|---|---|
| Todos los cursores deterministas agotados, sin etapas aleatorias activas | `mutation_exhausted` | `{mutation_exhausted, mutation_exhausted}` |
| Etapas aleatorias activas; presupuesto inactivo alcanzado **y** cada contenido visitó cada carril activo desde el último progreso | `idle_budget_exhausted` | `{mutation_stopped, idle_budget_exhausted}` |
| Sin entradas de corpus, API de bajo nivel | `empty_corpus` | `{mutation_exhausted, empty_corpus}` |

La segunda condición protege el progreso; no demuestra que no exista candidato
aleatorio teórico. `max_idle_visits` es el mínimo de visitas consecutivas sin
progreso antes de poder parar; no es un máximo duro de visitas que avancen
cursores finitos o completen un barrido. Incluso un presupuesto de uno deja
actuar a un carril productivo posterior. Por ejemplo, con 256 semillas de un
byte, `[dictionary_overwrite,bitflip]` y token `<<"AB">>`, las 256 visitas de
sobrescritura no disponible van seguidas de candidatos bitflip, no de agotamiento
prematuro.

Con corpus fijo, los cursores finitos terminan tras un número finito de visitas
acotadas; un espacio determinista de cero elementos termina inmediatamente.
Si quedan etapas aleatorias sin progreso, el umbral inactivo y un barrido completo
acotan las visitas restantes. El registro almacena un contador por identidad
contenido/configuración usando el orden circular existente; nunca enumera
mutaciones. Añadir entradas reinicia inactividad/barridos porque entradas
principales o donantes nuevas cambian el espacio de búsqueda. Se conservan
cursores, estado RNG y ronda pendiente; reanudar con el mismo corpus conserva
también la contabilidad de inactividad. El planificador espera las entradas de
solo adición de `efz_corpus`.

El trabajador sigue terminando con `completed` al alcanzar `max_iterations`
ejecuciones del objetivo. Los candidatos binarios vacíos son candidatos normales,
no centinelas de agotamiento.

## Semántica exacta de operaciones (versión 1)

Todos los offsets de bytes parten de cero. Para una entrada de tamaño `N`, las
fronteras de inserción son `0..N`; un rango válido cumple `0 <= Offset`,
`Length >= 0`, `Offset + Length <= N`. El offset `N` añade al final;
eliminar `[0,N)` produce `<<>>`. Las primitivas reciben límites normalizados y
solo devuelven `{ok, Candidate}` si cambian bytes; de lo contrario,
`{skip, Reason}` o `{error, Reason}`.

| Operación concreta | Significado y restricciones |
|---|---|
| `{flip_bits, Offset, Width}` | El bit 0 es el más significativo del byte 0. XOR de exactamente 1, 2 o 4 bits consecutivos; el rango debe caber en `8*N`. Se admiten cambios entre bytes. |
| `{invert_bytes, Offset, Length}` | XOR de cada byte con 255; longitud exactamente 1, 2 o 4 y rango válido. |
| `{add, Offset, Width, Endian, Delta}` | Leer un campo completo sin signo de 8/16/32 bits, `little` o `big`; escribir `(Old + Delta) band ((1 bsl Width)-1)`. `abs(Delta) <= max_delta`. Delta cero no tiene efecto. |
| `{set_integer, Offset, Width, Endian, Value}` | Escribir un patrón exacto sin signo `0..2^Width-1` en un campo válido de 8/16/32 bits. El planificador usa la tabla versionada de fronteras; la primitiva acepta cualquier patrón que encaje. |
| `{overwrite, Offset, Bytes}` | Reemplazar exactamente `byte_size(Bytes)` bytes válidos sin redimensionar. La longitud literal respeta el límite de bloque. |
| `{insert, Offset, Bytes}` | Insertar todos los bytes literales en una frontera válida. Sin truncar. Se admite origen vacío. |
| `{delete, Offset, Length}` | Eliminar un rango no vacío válido. El planificador elige hasta el límite de bloque; la primitiva permite cualquier eliminación no vacía válida. |
| `{duplicate, Offset, Length, At}` | Copiar un rango de origen válido no vacío e insertarlo en una frontera de la entrada **original**. Se permite solapamiento; longitud limitada por bloque. |
| `{dictionary_insert, Offset, Token}` | Insertar el token completo no vacío respetando límites de token/bloque/tamaño resultante. |
| `{dictionary_overwrite, Offset, Token}` | Reemplazar un rango válido del tamaño del token sin redimensionar; mismos límites. |
| `{splice, CutA, CutB, DonorBytes, DonorSHA256}` | `Primary[0:CutA] ++ Donor[CutB:DonorSize]`. Ambos cortes son fronteras. Verificar hash y tamaño del donante antes de concatenar; cumplir tamaño final. |

Para ancho `W`, sean `H = 2^(W-1)` y `U = 2^W-1`. El orden de versión 1 es
`[0,1,2,H-2,H-1,H,H+1,U-1,U]`. Para ocho bits es
`[0,1,2,126,127,128,129,254,255]`. Son patrones de bits, incluidos valores cerca
de fronteras de interpretación con signo; no se usa desbordamiento accidental
con signo.

Campos/rangos que no encajen se omiten con `insufficient_length`; no se lee un
campo parcial. Entradas/literales resultantes excesivos se omiten con `size_limit`.
Salida idéntica o literal ordinario vacío se omiten con `no_change`; tokens de
diccionario vacíos no están disponibles en la primitiva y son inválidos al
configurar. Operaciones malformadas, hashes de donante inválidos, entradas origen
excesivas o deltas fuera del límite son errores. Algunos offsets inválidos dan
skip en vez de error de estructura; regenerar una receta rechaza **ambos**.
Todos los operadores que necesitan bytes se omiten en entradas vacías;
inserciones literales/de diccionario y empalmes adecuados pueden producir
candidatos desde vacío.

Los donantes vienen de la instantánea existente del corpus, excluyendo contenido
igual a la semilla principal. Sus contenidos distintos se deduplican y ordenan
por término binario antes de una elección uniforme. Duplicados de cola no sesgan
la elección. Un corpus de un contenido informa `donor_unavailable`.
La operación lleva bytes/hash del donante y la procedencia contiene bytes/hash
principales e ID del corpus; replay nunca consulta un índice de donante en cola.
Un donante igual al binario intermedio actual también se omite; cortes con salida
sin cambios se omiten. No se modifica ninguna entrada del corpus.

## Havoc y reproducibilidad

Havoc elige uniformemente una profundidad en `1..havoc_depth` y después una de
11 familias: cambio de bits, inversión de bytes, aritmética, frontera entera,
sobrescritura, inserción, eliminación, duplicación, inserción de diccionario,
sobrescritura de diccionario, empalme. No se afirma que este peso fijo sencillo
sea óptimo. Los parámetros se eligen contra el resultado intermedio anterior.
La falta de diccionario o donante y otras elecciones inaplicables consumen una
posición de pila, en vez de reintentar un operador sin límite.

Cada intento de pila consume una elección de profundidad; splice independiente
tiene profundidad fija 1. Havoc consume una elección de familia por posición.
Las elecciones de parámetros se consumen en orden de código; fallos de
prerrequisitos regresan inmediatamente sin elegir parámetros no disponibles.
Se conserva todo estado RNG consumido al omitir. Hay como máximo
`min(attempts_per_visit, random_retries)` intentos aleatorios de candidatos por
visita. Un binario final igual al principal no tiene efecto aunque las operaciones
intermedias cambiaran bytes. Puede reintentarse dentro del mismo límite.
Solo operaciones integrantes con cambios exitosos aparecen en una receta
realizada; las omitidas no necesitan reproducirse porque no alteraron bytes
intermedios.

Todas las decisiones nuevas usan `rand:seed_s(exsplus, Seed)` y
`rand:uniform_s/2`; no se usa `rand:uniform()` implícito en el motor por etapas.
El estado privado pertenece al planificador del trabajador. Aleatoriedad del
objetivo, selección antigua del corpus, registros y estadísticas no lo consumen.
Sin `mutation.seed`, 24 bytes aleatorios generan los tres enteros de semilla
**una vez** al inicializar; semilla real y algoritmo se informan en
`Report.mutation` y las recetas.

En el entorno probado OTP 27.0, reproducir decisiones requiere versión del motor,
configuración normalizada, algoritmo/semilla, bytes/orden iniciales del corpus
y diccionario, y resultados/retención deterministas.
`Report.mutation_initial_corpus` registra hashes ordenados; el informe conserva
bytes iniciales. La identidad de configuración es SHA-256 de pares ordenados
normalizados, incluida versión del motor, semilla e identidad del diccionario.
Se excluye `trace_limit` por ser observacional. Cambiar configuración/diccionario
requiere otra campaña. El estado rand interno con manejadores no se escribe en
recetas. No se promete compatibilidad PRNG entre versiones OTP.

Reproducir decisiones, regenerar un binario concreto y reproducir un resultado
del objetivo son afirmaciones distintas. Las recetas reconstruyen bytes sin
RNG ni corpus; objetivos sensibles al tiempo pueden comportarse distinto al
reproducir la ejecución.

## Procedencia y contabilidad

Las entradas retenidas exponen recetas completas en `Entry.metadata.mutation`;
los registros únicos de fallos usan `Crash.metadata.mutation`, y el almacén
escribe `.recipe` junto a `.input` y el resultado `.term` existente.
Las decisiones conservan un resumen corto de mutación, etapa y hashes
principal/configuración/candidato, evitando recetas completas para cada decisión
fallida. Los candidatos rechazados equivalentes no se retienen.
`trace_limit` opcional conserva solo las primeras recetas generadas hasta su
límite, incluidas las rechazadas después, sin consumir RNG.

`Report.stats` existente conserva contadores de calibración, mutaciones,
descubrimientos, rechazos, fallos/timeouts, huellas únicas e infraestructura.
`Report.mutation_stats` añade:

* `visits`: visitas de planificación, incluidos carriles terminados/inaplicables.
* `mutation_attempts`: intentos de operación determinista o de pila aleatoria.
* `operation_attempts`: intentos integrantes, incluidas opciones no disponibles.
* `skipped_operations` y `skip_reasons`: operaciones omitidas; los motivos también
  cuentan pilas finales sin efecto, por lo que los totales no tienen que coincidir.
* `skipped_candidates`: visitas terminadas sin candidato.
* `generated_candidates`: candidatos realmente entregados a ejecución en runs normales.

La API en vivo `efz:stats/0` conserva los contadores existentes del objetivo/
campaña; contadores detallados y traza acotada están en el informe final.
Una pila es una decisión de candidato/retención, no prueba de que cada operación
causó un descubrimiento independientemente. Los grupos de huellas no cuentan
bugs independientes demostrados. Fallos/timeouts conservan observaciones de
ejecución pero nunca combinan cobertura exclusiva de fallos en la novedad del
corpus exitoso. Siguen aplicándose las restricciones de un trabajador, un proceso
objetivo y compilaciones fijas de cobertura/aislamiento de [coverage.md](coverage.md).
