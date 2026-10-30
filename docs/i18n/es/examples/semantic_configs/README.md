# Ejemplos de configuración de campañas

[English](../../../../../examples/semantic_configs/README.md) · [Русский](../../../ru/examples/semantic_configs/README.md) · **Español** · [简体中文](../../../zh-CN/examples/semantic_configs/README.md) · [Todos los idiomas](../../../README.md)

Cada archivo term contiene un mapa de campaña de confianza aceptado por efz:start/1 y
la opción --config de la CLI. Las semillas son binarios sin procesar, no rutas. Los paquetes
genéricos se codificaron con las especificaciones reales de los argumentos del harness.

| Archivo | Objetivo/API | Adaptador | Propiedad |
| --- | --- | --- | --- |
| lists_reverse.term | lists:reverse/1, argumento de lista | efz_term_api_adapter | Desactivada |
| maps_find.term | maps:find/2, átomo finito y mapa de valores de tupla | El mismo adaptador genérico | Desactivada |
| tuple_api.term | efz_term_tuple_library:combine/2, mapa y tupla | El mismo adaptador genérico | Desactivada |
| stateful.term | Escenario acotado de comandos de un gen_server nuevo | El mismo adaptador genérico | Callback explícito de traza independiente |
| xmlrpc.term | Entrada charlist de xmlrpc_decode:payload/1 fijado a una revisión | efz_xmlrpc_adapter | xmlrpc_model_agreement v1 |
| cow_qs.term | Entrada binaria de cow_qs:parse_qs/1 | efz_qs_adapter explícito | query_model_agreement v1 |
| cow_qs_legacy.term | Configuración QS histórica | Capa aislada de compatibilidad QS implícita | La misma propiedad QS |

Todos los ejemplos usan coverage_backend=none: ejecutan API reales y feedback
semántico sin afirmar que midan la cobertura estructural de la biblioteca. Prepare
por separado los artefactos exclusivos del objetivo y seleccione después el backend
y los artefactos correspondientes. No instrumente los adaptadores, modelos ni
auxiliares de propiedades como cobertura del objetivo.

Compile el perfil Gleam opcional y ejecute desde la raíz de EFZ:

    ERL_FLAGS='+S 2:2' escript scripts/fuzz.escript --config examples/semantic_configs/maps_find.term --code-path _build/gleam/lib/efz/ebin --out /tmp/maps-campaign

XML-RPC también requiere la dependencia fijada a una revisión preparada por
examples/xmlrpc/prepare.escript y las rutas de código
_build/xmlrpc-example/dependency-ebin y _build/xmlrpc-example/harness-ebin.
QS requiere _build/default/lib/cowlib/ebin. El llamante proporciona --out;
las opciones explícitas de la CLI permiten adaptar una configuración sin editarla.

Consulte [la guía de integración completa](../../gleam-layer/connecting-erlang-libraries.md)
para las restricciones de argumentos, el ciclo de vida, las plantillas de plugins,
las identidades y la reproducción.
