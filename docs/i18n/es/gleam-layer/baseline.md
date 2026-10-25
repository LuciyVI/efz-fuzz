# Referencia P0

[English](../../../gleam-layer/baseline.md) · [Русский](../../ru/gleam-layer/baseline.md) · **Español** · [简体中文](../../zh-CN/gleam-layer/baseline.md) · [Todos los idiomas](../../README.md)

HEAD 79d76221c6bc5df30b80e6b0de947f3860f4fa4b; diferencias iniciales de archivos
seguidos/índice vacías. El directorio de requisitos y el zip del usuario se
conservaron (hashes en los artefactos de ejecución). Runtime: OTP 27.0,
ERTS 15.0, Rebar3, +S 2:2, JIT x86_64 Linux. Los commits fijados de
Cowboy/Cowlib/Ranch no cambian en rebar.lock.

`rebar3 compile` original: salida 1 (proxy configurado inaccesible).
Obtención acotada de dependencias por HTTPS directo + compilación: salida 0.
No se cambió configuración global. La disposición EUnit/CT original fallaba
antes de las pruebas: los directorios fuente anidados de objetivos de prueba
se convertían en enlaces simbólicos que chocaban con la copia de test/ de
Rebar. Reproducido en un /tmp/efz-native-baseline-20261007 nuevo. Al copiar allí
fuentes de harness idénticas a un directorio fuente sin solapamiento:
EUnit salida 0, **260 superadas**; CT salida 0, **3 superadas**. El checkout
principal aplica esta corrección moviendo los cuatro módulos harness sin
cambios a examples/cowboy/targets y examples/engine. El _build/test original
se conserva como _build/test-before-gleam-layout. No se eliminó ningún corpus.

Antes de implementar, 200 ejecuciones staged reales de efz_example_target con
semilla de mutación {17,23,41} terminaron mediante EFZ. baseline.term y
p0-trace.log registran candidatos, hallazgos y resultados exactos. Instantánea
de fuentes y runner de referencia: /tmp/efz-native-baseline-20261007
(git archive del HEAD original; solo difiere la disposición de directorios
fuente de compilación). La compilación ordinaria no requiere Gleam.

`efz_cov_native_public:preflight/1` verifica la capacidad y el modo de cobertura
pública de OTP sin recurrir silenciosamente a otro backend. El almacenamiento
nativo de OTP 27 es por módulo (kernel-10.0/src/code.erl instalado,
líneas 270-296 y 2309-2312). Las pruebas EUnit existentes cubren backends ETS,
ETS-member, bitmap y nativo. El modo nativo de líneas es compatible con esta
VM; no puede combinarse con hit_count ni manual. Una sola campaña/worker,
junto con la barrera de limpieza del guardian, serializa los intervalos en
línea. Las llamadas concurrentes no gestionadas al objetivo en esta VM quedan
fuera del contrato. Gleam no introduce un backend, oráculo paralelo ni
observador asíncrono.

Aclaración de herramientas P2 (2026-10-08): el `erl` principal se resuelve
mediante asdf a `/home/fbogoslavskii/.asdf/installs/erlang/27.0`, ERTS 15.0.
La fuente verificada es `lib/kernel-10.0/src/code.erl` bajo esa raíz.
`/usr/bin/erl` selecciona independientemente el OTP del sistema 27.3.4.13 /
ERTS 15.2.7.9. P2 registra ambos y repite compilación/pruebas limpias del modo
desactivado en el mismo OTP 27.0 principal usado para el modo activado
(`toolchain-paths.json` en la ejecución P2).
