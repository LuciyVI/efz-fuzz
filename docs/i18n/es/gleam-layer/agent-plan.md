# Responsabilidades y orden de aceptación

[English](../../../gleam-layer/agent-plan.md) · [Русский](../../ru/gleam-layer/agent-plan.md) · **Español** · [简体中文](../../zh-CN/gleam-layer/agent-plan.md) · [Todos los idiomas](../../README.md)

Estado actual (13 de octubre de 2026): P5 PASS para el contrato admitido;
consulte [p5-validation.md](p5-validation.md). Las notas siguientes sobre
responsabilidad/no publicación registran ejecuciones históricas; las
actualizaciones posteriores de ramas fueron autorizadas por el usuario.

Contrato v1, requisitos 2.0-native (2026-10-07).
Un único responsable posee todos los cambios de esta sesión. No se lanzaron
subagentes: el usuario proporcionó COMMON_CONTEXT sin invocar explícitamente
el prompt de orquestación separado del paquete. No describa la implementación
como trabajo delegado o revisión independiente de subagentes. La referencia
se archivó antes de implementar.

P0 -> referencia y auditoría de fuentes de objetivo/cobertura.
P1 -> fijar contracts.md y mapa real de fuentes.
P2 -> paquete Gleam fijado sin dependencias, adaptador comprobado y compilación
opcional.
P3 -> semillas tipadas sin procesar, proveedor acotado en el plan staged
existente, esquema de receta 3 con operación v2; esquemas 1/2 antiguos siguen
admitidos.
P4 -> observador/oráculo puros acotados y admisión semántica serializada.
P5 -> reproducción de bytes/propiedades, minimizador finito, regresión,
A/B/B2 y series breves del mismo motor; la superioridad de rendimiento sigue
siendo una pregunta separada sin responder.

No se editan requisitos del usuario, corpus originales ni herramientas globales.
No se realizan commits, ramas, push, PR ni publicación.

## Auditoría de contrato P1 (2026-10-08)

El responsable posee `architecture.md`, `contracts.md`, `p1-validation.md`,
los compartidos `agent-plan.md`/`decision-log.md`, las correcciones puntuales
de capacidad del modelo/empaquetado/diagnóstico de arranque y
`efz_gleam_contract_tests.erl`. No hay workers activos ni se atribuye revisión
independiente. El contrato sigue en v1. Consulte p1-validation.md y la ejecución
separada de artefactos 20261008-p1-contract para comandos, salidas, ámbito de
revisión y traspaso. El prompt completo de orquestación y la aceptación final
P5 siguen pendientes.

## Auditoría de integración P2 (2026-10-08)

El responsable posee paquete/compilación/configuración, adaptador comprobado,
pruebas BEAM P2, driver de diagnóstico y documentación. No se usaron workers
concurrentes ni revisor independiente. La representación del paquete y contrato
v1 no cambian. Los cambios de producción validan todas las exportaciones del
núcleo al arrancar y acotan diagnósticos etiquetados de error de capa; los
archivos de política P3/P4 existentes no cambian. Los requisitos funcionales
P2 pasan; consulte p2-integration.md y 20261008-p2-native/gates.json.
La aceptación de fases P3/P4 y P5 final siguen como trabajo separado, no
finalización de todos los prompts del paquete.

## Responsabilidad del proveedor P3 (2026-10-08)

El responsable posee paquete/catálogo Gleam, extensiones de planificador y
recetas, drivers de semillas/sondas, pruebas específicas y documentación de
contrato/informe. No se atribuyen workers ni revisor independiente. No se
modifican compilación/configuración compartidas, harness del objetivo, corpus,
admisión, executor ni backends de cobertura. La aceptación P3 se sigue en
p3-provider.md y su ejecución de artefactos; la guía semántica P4 y P5 final
siguen como criterios separados.

## Responsabilidad del feedback P4 (2026-10-08)

El responsable posee el límite exacto de metadatos, consulta fuera del bucle
de representantes, fixtures/pruebas de feedback, sonda finita de feedback,
modos nuevos de benchmark y documentación. No se atribuyen subagentes ni
revisor independiente. Se auditaron y ejecutaron bucle, captura,
observador/oráculo, admisión/persistencia y hallazgos/reproducción existentes;
no se añaden cambios de planificador, worker, compilación/paquete/versión ni
objetivo. La aceptación y límites P4 constan en p4-feedback.md y
20261008-p4-feedback/gates.json. La regresión final P5, experimentos de
detección y conclusiones de rendimiento del mismo motor siguen abiertos.

## Aceptación final P5 (2026-10-13)

Se completaron CLI de reproducción, compatibilidad nativa antigua, regresión
completa, comparaciones aisladas con varias semillas, contabilidad real de
operaciones con estado y ensayos controlados de detección. Los hashes de
fuentes/evidencias y límites están en p5-validation.md. No se atribuyen revisor
separado ni subagente; no se afirma superioridad de rendimiento.
