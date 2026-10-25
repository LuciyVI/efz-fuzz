# Mapa real de fuentes

[English](../../../gleam-layer/execution-path.md) · [Русский](../../ru/gleam-layer/execution-path.md) · **Español** · [简体中文](../../zh-CN/gleam-layer/execution-path.md) · [Todos los idiomas](../../README.md)

- efz_config:prepare/1 valida configuración; efz_cov_native_public:preflight/1
  o efz_instrument:preflight/1 verifican artefactos seleccionados.
- efz_fuzzer:init/1 inicia el corpus, estadísticas y supervisor del worker
  existentes.
- efz_worker:handle_info/2 calibra semillas antes de mutar; staged_iteration/1
  llama a efz_mutation_plan:next/2 con efz_corpus:mutation_entries/0.
- efz_mutation_plan:visit/2 visita padres por orden de inserción y las etapas
  existentes; attempts/6 elige una rama estructurada opcional antes de
  decodificar; de lo contrario ordinary_attempts/6 conserva operaciones
  deterministas/havoc/splice.
- efz_worker:execute_checked/4 llama a efz_executor:run/4. efz_guardian posee
  tiempo límite, descendientes gestionados, limpieza y finalización de
  cobertura. Esta ya está materializada/sellada antes de que execute_result/6
  evalúe novedad.
- efz_worker:semantic_callbacks/4 va después de capturar el objetivo. El
  observador puro usa el resultado normalizado; el oráculo puro de concordancia
  del modelo tiene recuento finito de comprobaciones y hace **cero** llamadas
  al objetivo. No hay cola, worker ni intervalo adicional de ejecución.
- efz_feedback:evaluate/3 sigue siendo la autoridad de novedad estructural.
- efz_corpus:semantic_admission/6 amplía retención para modo guiado, confirmando
  persistencia antes de actualizar las características propiedad del corpus.
  efz_corpus:select/0 y el plan staged usan esas mismas entradas. No hay corpus
  semántico independiente.
- efz_worker:record_failure/4 -> efz_crash:save/4 conserva bytes originales.
  Los fallos del objetivo preceden a callbacks semánticos; los del oráculo
  son huellas separadas en el mismo almacén, independientes de la novedad.
- efz_recipe:regenerate/1 regenera datos structured_replace versionados sin
  Gleam; efz_replay y efz_recipe:execute/5 usan el executor fijado existente.
  efz_semantic_replay comprueba la propiedad por separado y cuenta cada
  ejecución del minimizador. efz_semantic:cover/1 conserva prudentemente las
  características registradas.
