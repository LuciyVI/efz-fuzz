# Validación del contrato P1 y traspaso

[English](../../../gleam-layer/p1-validation.md) · [Русский](../../ru/gleam-layer/p1-validation.md) · **Español** · [简体中文](../../zh-CN/gleam-layer/p1-validation.md) · [Todos los idiomas](../../README.md)

La aceptación P5 actual está en [p5-validation.md](p5-validation.md).
Las afirmaciones de traspaso y estado pendiente siguientes describen la
ejecución histórica de la fase.

Requisitos **2.0-native**, contrato **v1**, vector `{1,1,1,1,1,1}`.
Artefactos: `artifacts/gleam-layer/20261008-p1-contract/` (raíz del repositorio).
El contrato P1 y sus comprobaciones ejecutables están implementados y probados.
La revisión de coherencia siguiente es autorrevisión; **no** se ha realizado
revisión independiente. Esto no cierra el paquete completo de orquestación ni P5.

## Entradas y archivos cambiados

Se leyeron `efz_gleam_native_subagent_prompts/01_COMMON_CONTEXT.txt`, la
[baseline.md](baseline.md) P0 real, la instantánea original y fuentes/pruebas
actuales. HEAD sigue en `79d76221c6bc5df30b80e6b0de947f3860f4fa4b`.
Esta pasada registró el diff existente antes de cambiar; no sobrescribió
trabajo anterior. Los nueve archivos de prompts del usuario, su ZIP y
`AGENTS.md` conservan hashes.

P1 cambió:

- `docs/gleam-layer/architecture.md`: responsabilidades EFZ, extensiones
  reales, rutas de control/datos/fuera del bucle y límites de cobertura.
- `docs/gleam-layer/contracts.md`: representaciones versionadas, configuración,
  transiciones RNG explícitas, límites, errores, admisión/reinicio/poda.
- `docs/gleam-layer/p1-validation.md`, `agent-plan.md`, `decision-log.md`:
  evidencias, responsabilidades, decisiones y traspaso.
- `test/efz_gleam_contract_tests.erl`: fixtures adicionales de contrato ejecutable.
- `src/efz_gleam_adapter.erl`: errores de arranque acotados y útiles para
  opciones/modos/objetivos/límites incompatibles, preservando selección exitosa
  y desactivada.
- `gleam/efz_semantic/src/efz_qs_model.gleam`: comprobar capacidad antes de
  asignar prepend/append; salidas admitidas y semántica de rechazo intactas.
- `scripts/build_gleam.sh`: distribuir solo modelo invocable, quitar lanzador
  CLI generado no usado de metadatos runtime y archivar su BEAM previo fuera
  del ebin activo. No se añade stdlib.

Las responsabilidades/behaviours EFZ y vector de contrato no cambian. No se
introducen ABI C, NIF, registro de plugins, motor ni reescritura del objetivo.

## Comandos ejecutados y resultados

Todos los comandos se ejecutaron desde la raíz con `ERL_FLAGS='+S 2:2'`,
secuencialmente. `contract_test_modules` es el argumento de módulos EUnit
separados por comas:

```sh
contract_test_modules=efz_gleam_contract_tests,efz_gleam_layer_tests,efz_config_tests,efz_corpus_store_tests,efz_recipe_tests,efz_mutator_tests,efz_native_public_tests
```

| Comprobación / comando | Salida | Resultado | Artefacto en directorio de ejecución |
| --- | --- | --- | --- |
| `GLEAM_BIN=/no/compiler rebar3 eunit --module="$contract_test_modules"` | 0 | 34 pruebas superadas; integración opcional no seleccionada en compilación desactivada | `p1-off-eunit.log` / `.json` |
| `GLEAM_BIN=/tmp/efz-gleam-toolchain/gleam rebar3 as gleam eunit --module="$contract_test_modules"` | 0 | 51 superadas, BEAM Gleam real e integración EFZ nativa | `p1-on-eunit.log` / `.json` |
| `GLEAM_BIN=/tmp/efz-gleam-toolchain/gleam rebar3 as gleam compile` | 0 | Distribución runtime con Gleam 1.10.0 fijado | `p1-on-build.log` / `.json` |
| Mismo entorno, `rebar3 as gleam xref` | 0 | Sin referencias runtime no definidas | `p1-xref.log` / `.json` |
| `escript artifacts/gleam-layer/20261008-p1-contract/check_source_refs.escript "$PWD" "$PWD/_build/gleam"` | 0 | 26 referencias explícitas `file:function/arity` comprobadas contra formas abstractas compiladas | `source-references.log` / `.json` |
| `GLEAM_BIN=/no/compiler rebar3 eunit --module=efz_phase2_tests,efz_mutation_tests` | 0 | 42 pruebas antiguas de términos/executor y plan staged superadas | `legacy-compatibility.log` / `.json` |
| `git diff --check` | 0 | Sin errores de espacios en archivos seguidos | `diff-check.log` |

El primer xref del perfil Gleam terminó con **1**: el generado
`efz_semantic@@main:print_term/1` referenciaba el ausente
`gleam@string:inspect/1`. `xref.log` / `.json` conservan el fallo.
La distribución final excluye ese lanzador no usado y su declaración de módulo
.app; xref final pasa. Las ejecuciones EUnit intermedias (34/50) también están
registradas. Un comprobador de referencias rechazó inicialmente un documento
sin rutas explícitas (salida 127); se corrigió y la verificación final pasa.

Comandos/entorno/códigos exactos y hashes están en `gates.json` y JSON por
comprobación; no se guarda entorno completo ni secretos.
`preserved-inputs.json` verifica archivos del usuario intactos.
`acceptance-proofs-final/` copia artefactos reales de guía, reinicio, atribución
de cobertura y hallazgo artificial de las pruebas finales; sus rutas de origen
están en `acceptance-proofs-final.json`.

## Mapa de fixtures de aceptación

| Requisito | Fixture / evidencia ejecutada |
| --- | --- |
| ADT válido, leyes del códec, bytes arbitrarios | `efz_gleam_layer_tests:codec/0`: modelos canónicos vacíos/binarios/duplicados; comparación de vocabulario de bytes con Cowlib real fijado |
| Términos malformados, alineación, profundidad/bytes/elementos | `boundary_test/0`, `limits_and_failures/0`; `efz_gleam_contract_tests:malformed_model_and_limits_test/0`, `outcome_verdicts/0` |
| Paquete ausente, versiones, objetivo/modo/configuración | `invalid_capabilities_test/0`, `package_capabilities/0`; stub de versión expresamente como fixture de fallo de contrato |
| Mutación determinista, RNG desactivado/fracción cero, alternativa de bytes | `determinism/0`, `fallback_rng/0`; mismos candidatos y estado RNG explícito final |
| Runtime desactivado sin callbacks/estado | `off_preserves_configuration_test/0`, `runtime_off_callbacks/0`: traza real de llamadas de campaña; sin campos semánticos de estado/informe |
| Mismas unidades estructurales, hechos semánticos distintos | `coverage_attribution/0`, `guidance/0`: captura nativa real; entrada de trabajo solo semántica y selección ordinaria posterior como padre |
| Solo observación sin cambiar admisión | `observer_only/0`, comparado con entradas de trabajo runtime desactivado |
| Admisión fallida/reintento/característica repetida | `persistence_retry/0`: visto no cambia ante fallo de escritura; reintento correcto, duplicado conserva motivo de admisión |
| Retención/reinicio de representantes | `reduction/0`, `restart/0`: uniones estructural/semántica y bandera solo semántica sobreviven; reducción de solo lectura |
| Pass/Fail/Inconclusive, presupuesto cero | `limits_and_failures/0`, `outcome_verdicts/0`, `zero_budget_random_mode/0`; cero llamadas adicionales al objetivo |
| Hallazgos independientes de novedad, reproducción/minimización de propiedad | `finding_replay/0`: fixture artificial, tres fallos con una entrada de trabajo; reproducción de misma propiedad y eliminación acotada de bytes |
| Error de capa es diagnóstico, no alternativa | `fault_injection/0`: stub explícito; campaña se detiene antes de ejecutar objetivo de mutación |
| Esquemas distintos / artefactos antiguos | `semantic_schema_restore_test/0`, pruebas corpus v1/v2, receta v1/negativas/VM nueva y versión de propiedad distinta |
| Entradas como términos / planificación ordinaria existentes | Comprensiones de `efz_phase2_tests` incluyen listas/mapas/tuplas; `efz_mutation_tests` conserva operaciones ordinarias, equidad, límites y selección |
| Distribución sin CLI/stdlib opcionales | `runtime_shipment/0`: lista de módulos solo del modelo, sin iniciar aplicación opcional |

Mocks/stubs solo cierran contratos de errores. Las pruebas reales del modelo y
EFZ/cobertura nativa aportan evidencia de integración; ningún mock cuenta como
guía. El hallazgo artificial conocido es fixture de conexión/reproducción,
no detección independiente de defectos.

## Revisión de coherencia de fuentes

El responsable comprobó P0 y propietarios actuales frente a
[architecture.md](architecture.md): selección de padre precede a decode
estructurado; reintento ordinario conserva presupuesto/cursores; desactivado
no extrae RNG adicional; ejecución/captura precede callbacks puros; solo se
aceptan manifiestos cow_qs; guardian serializa intervalos; hallazgos preceden
fallo del observador; corpus confirma visto semántico tras insertar; reinicio
rechaza esquema distinto y calibra bytes; reducción no elimina silenciosamente
un representante. Se corrigieron asignación temprana, diagnósticos opacos y
lanzador no usado detectados y se repitieron las comprobaciones afectadas.

Limitaciones: autorrevisión, sin revisor independiente/subagentes; llamadas no
gestionadas en la misma VM siguen fuera del aislamiento. No se afirma oráculo
paralelo, diferido o interrumpible nativamente. Las series anteriores de
equivalencia/rendimiento desactivado no se reclasifican como mediciones finales
P5 tras estos cambios. El empaquetado limpio completo desactivado y serie
final de benchmark del mismo motor siguen como trabajo P5. El paquete completo
de prompts **no está terminado**.

## Traspaso y responsabilidades P2/P3/P4

El responsable posee arquitectura/contratos, compilación/configuración, bucle
y corpus compartidos; no hay workers escribiendo concurrentemente.
La delegación posterior debe asignar archivos explícitos y transmitir contexto
común, evidencia P0, contrato v1 y `gates.json`.

- **P2:** mantener Gleam 1.10.0 fijado y llamadas BEAM reales, validar términos
  externos, distribuir solo módulos runtime invocables y preservar compilación
  desactivada sin compilador. Fuente Erlang generada no es artefacto obligatorio.
  La distribución actual y comprobaciones de capacidades ausentes/incompatibles
  tienen evidencia real de pruebas.
- **P3:** mantener derivación de operaciones/transiciones RNG propiedad de EFZ
  y plan existente; aplicar límites antes de asignar campos/bytes/salida,
  preservar representación deliberadamente inválida y persistir bytes/receta
  v2 de solo datos. El contrato no autoriza planificador ni caché/política
  de pistas.
- **P4:** consumir características finitas solo mediante admisión serializada,
  mantener neutralidad de observación y comportamiento de reintento/reinicio,
  separar cobertura principal y contar/presupuestar ejecuciones añadidas.
  El soporte diferido necesita revisar capacidades; se rechaza en v1.

Son invariantes de traspaso, no afirmación de haber completado todos los
criterios posteriores ni revisión independiente de orquestación.
