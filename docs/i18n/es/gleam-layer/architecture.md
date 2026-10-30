# Arquitectura Gleam nativa: contrato v1

[English](../../../gleam-layer/architecture.md) · [Русский](../../ru/gleam-layer/architecture.md) · **Español** · [简体中文](../../zh-CN/gleam-layer/architecture.md) · [Todos los idiomas](../../README.md)

Requisitos: **2.0-native**. Contrato: **1**. Revisión base:
`79d76221c6bc5df30b80e6b0de947f3860f4fa4b`. Describe el checkout actual,
incluido el código de integración presente antes de la auditoría P1.
Consulte [baseline.md](baseline.md) para los resultados P0 reales y su solución
a la disposición de directorios fuente.

## Responsabilidades de EFZ y puntos de extensión

Las rutas son relativas al repositorio; las aridades forman parte del mapa de
fuentes.

| Responsabilidad | Propietario real en EFZ |
| --- | --- |
| Ciclo de vida/informe de campaña | `src/efz_fuzzer.erl:init/1`, `handle_info/2`, `terminate/2` |
| Calibración/bucle principal | `src/efz_worker.erl:handle_info/2`, `staged_iteration/1` |
| Padre/planificador | `src/efz_corpus.erl:select/0`, `mutation_entries/0`; `src/efz_mutation_plan.erl:next/2`, `visit/2` |
| Selección/operaciones de mutación | `src/efz_mutation_plan.erl:attempts/6`, `structured/3`, `ordinary_attempts/6`; `src/efz_mutation.erl:apply_operation/3` |
| PRNG | Staged `src/efz_mutation_plan.erl:new/1`, `uniform/2`; aleatorio heredado `src/efz_worker.erl:init/1`, `src/efz_mutator_random.erl:mutate/2`; selección `src/efz_corpus.erl:init/1`, `handle_call/3` |
| Objetivo/tiempo límite/reset/limpieza | `src/efz_executor.erl:run/4`, `invoke/4`; `src/efz_guardian.erl:run/6`, `start/6`, `cleanup/2`, `finish/2` |
| Captura de cobertura | `src/efz_guardian.erl:finish/2`; existentes `src/efz_cov_native_public.erl:collect/1`, `collect_profiled/1` y backends de `src/efz_coverage.erl` |
| Novedad estructural | `src/efz_feedback.erl:evaluate/3` |
| Corpus/admisión/persistencia | `src/efz_worker.erl:retain_layer/4`; `src/efz_corpus.erl:admit_semantic/4`, `semantic_admission/6`, `add_checked/3`; `src/efz_corpus_store.erl:save/4` |
| Hallazgos/huella | `src/efz_worker.erl:record_failure/4`; `src/efz_crash.erl:signature/2`, `save/4`; `src/efz_crash_store.erl` |
| Recetas/reproducción original/de propiedades | `src/efz_recipe.erl:make/4`, `regenerate/1`, `execute/5`; `src/efz_replay.erl:run/6`; `src/efz_semantic_replay.erl:run/5`, `minimize/6` |
| Reducción conservadora del corpus | `src/efz_semantic.erl:cover/1`, subconjunto propuesto de solo lectura; sin eliminación en línea |

Los behaviours existentes son `src/efz_mutator.erl:mutate/2` y
`src/efz_target.erl:run/1`. El behaviour mutador sirve para mutación aleatoria
ordinaria; no transporta el estado RNG del plan staged ni veredictos semánticos.
La capa extiende la selección del plan con un `efz_gleam_adapter` fijo y
comprobado. No hace falta una segunda plataforma de behaviours ni registro de
plugins. El prefijo `efz_` sigue los nombres existentes. Gleam devuelve datos;
EFZ conserva todas las decisiones de planificación.

## Rutas de control, datos y operaciones fuera del bucle

**Control:** `efz_config:prepare/1` valida capacidades existentes de cobertura/
objetivo; `efz_gleam_adapter:prepare/2` comprueba opciones, paquete, límites y
versiones. También valida una vez todas las exportaciones necesarias del
núcleo. [p2-integration.md](p2-integration.md) registra artefactos reales del
compilador, compilaciones limpias y trazas de llegada a callbacks.
`efz_fuzzer:init/1` inicia los propietarios existentes.
`scripts/gleam_seeds.escript` prepara archivos de semillas por separado antes
del bucle; la activación en ejecución es independiente.

**Datos:** EFZ selecciona padre y etapa, elige la familia estructurada opcional
y decodifica/muta/codifica solo esa rama. Las mutaciones ordinarias permanecen
en el mismo plan. Se ejecuta el mismo punto de entrada bajo el executor EFZ.
Su captura completada precede a observador/oráculo y admisión serializada.
El modo desactivado/fracción cero no añade extracciones RNG; las entradas
malformadas/no admitidas conservan la ruta ordinaria.

**Fuera del bucle:** EFZ guarda recetas declarativas acotadas y archivos
auxiliares inmutables de hallazgos. Reproducción/minimización usan explícitamente
su executor. El oráculo inline actual es puro, con presupuesto y cero llamadas
adicionales al objetivo. Oráculos en línea diferidos/costosos no se admiten en
v1 y fallan al arrancar. El soporte futuro debe usar los límites de supervisión/
ejecución existentes y presupuestos finitos.

## Aislamiento de cobertura y compatibilidad

P0 confirmó cobertura pública nativa de líneas en OTP 27.0. Los contadores
son por módulo, no por proceso. `efz_guardian:run/6` registra
`efz_execution_guardian`; otra ejecución EFZ recibe `runner_busy`. `loop/1`
espera descendientes y barreras de traza antes de que `finish/2` capture;
`efz_executor:run_pinned/4` también espera el fin del guardian. El intervalo es:

`reset/open → objetivo → barrera de finalización/limpieza → captura → callbacks → admisión`.

Los manifiestos del adaptador activado pueden seleccionar solo `cow_qs`,
excluyendo EFZ, Gleam, harness/adaptador y oráculo. Las llamadas no gestionadas
a módulos seleccionados en la misma VM quedan fuera del contrato. No hay
observador semántico asíncrono ni cola de respuestas tardías. Cualquier oráculo
futuro que repita el objetivo requiere un intervalo EFZ serializado separado
tras la captura principal, IDs de ejecución/campaña y contadores propios.

Se conservan los demás backends existentes; una selección explícita nunca
recurre silenciosamente a otro. El executor de bajo nivel conserva entradas
como términos. Las campañas ya requerían binarios en P0; el primer adaptador
no impone una restricción nueva a otras API. No se añaden ABI C, NIF, puerto,
VM adicional, motor externo ni parche OTP.

## Responsabilidad y revisión

El responsable principal posee esta pasada P1 de documentación/pruebas y la
configuración, bucle y corpus compartidos. No hay workers activos; no se
atribuye revisión delegada o independiente. [p1-validation.md](p1-validation.md)
registra comprobaciones de fuente, pruebas, limitaciones y traspaso a P2/P3/P4.
Los requisitos originales del usuario y `AGENTS.md` permanecen intactos.
