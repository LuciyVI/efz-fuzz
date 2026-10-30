# Cobertura DWARF/nativa: punto de control de viabilidad

[English](../../dwarf-native-coverage.md) · [Русский](../ru/dwarf-native-coverage.md) · **Español** · [简体中文](../zh-CN/dwarf-native-coverage.md) · [Todos los idiomas](../README.md)

Estado: **backend directo DWARF no implementado** (2026-10-03). El backend seguro
de comparación `otp_native_public` solo usa API documentadas de OTP; consulte
[`dwarf-native-coverage-results.md`](dwarf-native-coverage-results.md).
ETS sigue siendo el predeterminado y bitmap es opcional. Este punto de control
se detiene antes de leer la memoria de la VM porque el entorno actual no ofrece
una forma demostrada de fijar el almacenamiento de cobertura asignado
dinámicamente mientras se copia. Los desplazamientos DWARF siguientes son
observaciones de un binario, no un lector de cobertura utilizable.

## Límite de integración de EFZ

`efz_config:valid_field/2` acepta `ets`, `ets_member`, `bitmap` y
`otp_native_public`. `efz_coverage` selecciona esos backends.
`efz_guardian:run/6` es propietario del contexto de cobertura de una iteración;
`efz_feedback` decide la novedad y la combinación global. El runner Cowboy
(`scripts/cowboy_long_bench.escript`) compila cuatro módulos Cowboy mediante
`efz_instrument:compile/2` para ETS/bitmap, que inserta sondas estructurales
EFZ. La ruta nativa pública utiliza `efz_cov_native_public:compile/2` con
`line_coverage` y selecciona el modo `line` antes de cargar esos módulos.
Representa líneas ejecutables, no cláusulas/resultados de EFZ, por lo que los
recuentos absolutos de cobertura no serían comparables.

## Runtime y disposición verificados

Runtime: OTP 27, ERTS 15.0, Linux x86-64. El ejecutable activo identificado
para esta investigación fue `beam.smp` de la instalación Erlang/OTP 27.0
(ERTS 15.0). Su SHA256 es
`dcc7fac32e6f401be539022fce3e15a3f92461600208a41f1e7bfe3ef9e5d98f`;
su build-id GNU ELF es `545a52682e29950d87511c488a8d0f31551f5ad2`.
El ELF contiene `.debug_info` y no se han eliminado sus símbolos.

La consulta de tipos DWARF de GDB (`gdb -q -batch -ex 'ptype /o BeamCodeHeader'
<beam.smp>`) informa un `BeamCodeHeader` de 144 bytes con estos campos:

| Campo | Desplazamiento en bytes | Tipo DWARF |
| --- | ---: | --- |
| `coverage_mode` | 80 | `Uint` |
| `coverage` | 88 | `void *` |
| `line_coverage_valid` | 96 | `byte *` |
| `loc_index_to_cover_id` | 104 | `Uint32 *` |
| `line_coverage_len` | 112 | `Uint` |

`Module` (`struct erl_module`) tiene `curr.code_hdr` en el desplazamiento 32 y
`old.code_hdr` en el 96 de este binario. Estos valores deben redescubrirse para
cada ejecutable exacto; nunca deben copiarse a la configuración de ejecución de
otra compilación. La fuente OTP 27.0 declara `coverage` como `void *`, por lo
que el tipo por sí solo no define la asignación, el tipo de elementos del array
ni su vida útil: [OTP 27.0 `beam_code.h`](https://github.com/erlang/otp/blob/OTP-27.0/erts/emulator/beam/beam_code.h).
La fuente de la tabla de módulos distingue explícitamente la búsqueda sin
bloqueos de la instancia activa de las instancias antigua/staging protegidas
por separado: [OTP 27.0 `module.c`](https://github.com/erlang/otp/blob/OTP-27.0/erts/emulator/beam/module.c).

`code:coverage_support/0` devuelve `true` aquí. Un módulo compilado con
`[binary, line_coverage, debug_info]`, cargado después de
`code:set_coverage_mode(line)`, produjo `[{3,false},{4,true}]` tras ejecutar una
rama mediante `code:get_coverage(line, Module)`; el
`code:reset_coverage(Module)` público lo restableció a dos entradas `false`.
Esto comprueba únicamente el comportamiento público de OTP. No se ha realizado
ni comparado ninguna lectura directa.

## Por qué está bloqueada la lectura directa

DWARF describe dónde está el **campo puntero** `coverage` en un
`BeamCodeHeader` ya localizado; no identifica la dirección de memoria del
encabezado de un módulo cargado ni mantiene vivo ese objeto. PIE/ASLR también
significa que las direcciones de símbolos ELF no son direcciones del proceso.
Leer `Module.curr.code_hdr` y después `coverage` sin seguir las reglas de ERTS
para índice de código/progreso de hilos puede competir con reload/purge y
acceder a memoria liberada. Comparar build-id y MD5 del módulo antes de leer
no elimina la carrera entre comprobación y uso.

Erlang puro expone la cobertura como términos Erlang mediante
`code:get_coverage/2`, no como un puntero fijado. Un puerto separado no puede
llamar a la búsqueda interna de módulos de la VM y carece de sincronización
con el cargador de código; en este host,
`/proc/sys/kernel/yama/ptrace_scope` vale `1`, por lo que un hijo tampoco puede
leer normalmente su BEAM padre mediante `/proc/<pid>/mem`. Un NIF dentro del
proceso podría, en principio, llamar a rutinas privadas de ERTS, pero un helper
correcto necesitaría las fuentes/cabeceras de compilación OTP coincidentes y
un contrato verificado de vida útil del índice de código activo. Esos
requisitos no están disponibles aquí. Adivinar desplazamientos y llamar a
símbolos privados no es un sustituto aceptable, ni siquiera para un benchmark.

Por tanto, `otp_native_direct` **no** se añade a `coverage_backend` ni al runner
Cowboy. No hay prueba de corrección de lectura directa, comprobación breve,
microbenchmark ni comando de 15 minutos. Las mediciones de la API pública se
registran por separado; no prueban que un helper DWARF mejore el rendimiento
total de fuzzing.

## Preparación mínima reproducible para continuar con seguridad

1. Obtenga la fuente completa de OTP **27.0 que coincida con esta compilación
   exacta de `beam.smp`** y su configuración. Conserve el SHA256/build-id del
   ejecutable en el artefacto de disposición; falle de forma segura si
   `/proc/<beam-pid>/exe` del proceso difiere.
2. Compile un helper mínimo, específico de la compilación y dentro del proceso,
   de **solo lectura**, con las definiciones reales de cobertura y cargador
   de ERTS. Debe adquirir la instancia activa del módulo bajo las reglas
   documentadas de progreso de hilos/índice de código de ERTS, validar modo,
   identidad del módulo y límites, copiar un búfer compacto acotado y liberar
   su fijación antes de retornar. Nunca conserve punteros ERTS entre llamadas.
   Si esto no puede establecerse a partir de las fuentes, use un pequeño
   parche de acceso en la compilación OTP desechable de investigación, en
   lugar de un NIF inseguro.
3. Descubra campos y tamaños del DWARF de ese ejecutable al arrancar. Exija el
   SHA256/build-id correspondiente y rechace DWARF ausente o diferencias.
   Deduzca el tipo real de elementos e indexación del array de cobertura de
   las fuentes coincidentes; el `void *` de DWARF no basta.
4. Prohíba/interrumpa reload o actualizaciones de código del objetivo durante
   una campaña. Demuestre que reset y lectura ocurren solo después de que los
   hijos escritores estén inactivos, incluidos tiempo límite y fallo de limpieza.
5. Primero compare instantáneas directas con `code:get_coverage(line, Module)`
   en un fixture pequeño `line_coverage`, con ramas, ejecución repetida,
   reset, reload y disposición no válida. Solo después integre el modo nativo
   en `efz_coverage`/`efz_guardian`, conservando la realimentación y política
   de corpus de EFZ.
6. Mantenga el modo público de OTP implementado como opción explícita. Mida
   cualquier helper directo posterior frente a él con el mismo esquema de
   líneas antes de ofrecer una ejecución manual de 900 segundos. Mantenga
   ETS como predeterminado e informe las líneas por separado de las sondas
   estructurales de EFZ.

Reproduzca el fixture de la API pública en un directorio desechable:

```sh
cat >/tmp/efz_dwarf_fixture.erl <<'EOF'
-module(efz_dwarf_fixture).
-export([run/1]).
run(0) -> zero;
run(N) when N > 0 -> X = N + 1, {positive, X}.
EOF
erl -noshell -eval '{ok,M,B}=compile:file("/tmp/efz_dwarf_fixture.erl",[binary,line_coverage,debug_info]), code:set_coverage_mode(line), {module,M}=code:load_binary(M,"/tmp/efz_dwarf_fixture.erl",B), io:format("before=~p~n",[code:get_coverage(line,M)]), efz_dwarf_fixture:run(1), io:format("after=~p~n",[code:get_coverage(line,M)]), ok=code:reset_coverage(M), io:format("reset=~p~n",[code:get_coverage(line,M)]), halt().'
```

El comando es una referencia pública de OTP, **no** un lector DWARF.
