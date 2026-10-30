# Decisiones

[English](../../../gleam-layer/decision-log.md) · [Русский](../../ru/gleam-layer/decision-log.md) · **Español** · [简体中文](../../zh-CN/gleam-layer/decision-log.md) · [Todos los idiomas](../../README.md)

1. Usar Gleam 1.10.0 instalado en /tmp/efz-gleam-toolchain/gleam tras verificar
   compilación/BEAM reales; fijar versión exacta. Sin actualización automática
   a la última versión.
2. Usar el parser de cadenas de consulta Cowlib fijado, sin reescribirlo.
   El modelo contiene claves/valores binarios, duplicados ordenados y un
   escape malformado deliberado.
3. Mantener cobertura nativa y aislamiento guardian existentes. Los contadores
   públicos OTP son por módulo; el oráculo inline puro no añade llamadas.
4. El hook post_compile opcional usa ebin de la salida export erlang-shipment,
   nunca presupone .erl generado. No requiere stdlib ni runtime externo.
5. Las características finitas exactas del corpus se acreditan solo tras
   admisión persistente. Las anotaciones de semillas existentes se reconstruyen
   por calibración normal al reiniciar. Sin campaña, planificador, tabla ETS
   semántica, cola, caché ni worker ocultos.
6. Registrar structured_replace como operación v2 de solo datos. El esquema
   nuevo de receta estructurada 3 añade procedencia RNG validada; los esquemas
   1/2 antiguos siguen reproduciéndose con la capa desactivada.
7. Los fallos del oráculo usan grupos inmutables existentes, independientes
   de admisión del corpus. `.semantic` con checksum necesita manifiesto v2
   (máximo cinco archivos); hallazgos ordinarios conservan v1. Descubrimientos
   semánticos del corpus usan v3; registros v1/v2 se aceptan. Diferencia de
   esquema produce fallo.
8. Preservar últimos representantes semánticos en reducción conservadora.
   El corpus existente solo añade entradas; no se añade poda en línea.
9. Corregir el conflicto existente de directorios fuente de pruebas anidados
   moviendo cuatro harnesses sin cambios a examples y actualizando referencias.
   Conservar artefactos originales generados en _build/test-before-gleam-layout.
10. La regresión completa detectó una condición de presupuesto cero ausente en
    la función extraída de intentos ordinarios; restaurarla y repetir pruebas
    del planificador. Los directorios repetidos de fixtures ahora usan tiempos
    únicos para evitar colisiones de compilaciones antiguas.

Fuentes comprobadas: kernel code.erl de OTP 27 instalado y fuentes fijadas
cow_qs/cow_inline. Referencias primarias en línea:
https://gleam.run/documentation/externals/,
https://www.erlang.org/doc/apps/kernel/code.html,
https://gleam.run/news/gleam-doesnt-compile-to-erlang-source-anymore/.
La documentación/versiones actuales no definen artefactos del compilador
fijado; los generados de Gleam 1.10.0 y llamadas BEAM reales son la evidencia.

## Decisiones de auditoría P1 (2026-10-08)

- Fijar contrato real v1 como `{Contract,Model,Codec,Mutator,FeatureSchema,Property}`,
  todos en versión 1. Bastan behaviours existentes de mutador/objetivo y
  selección staged; no añadir registro de plugins, ABI C ni selección dinámica.
- Denominar la política del corpus historial de observados confirmados con
  éxito, no recuentos de referencias activos. Las entradas append-only
  conservan representantes. `cover/1` propone un subconjunto sin podar;
  la eliminación futura debe reconstruir índices coherentes atómicamente.
- El núcleo recibe ID de operación/índice de catálogo; EFZ deriva operaciones
  del estado exsplus explícito. Documentar con exactitud el estado siguiente
  en rutas ordinaria/éxito/alternativa/error.
- Rechazar oráculo diferido al arrancar. La propiedad inline admitida es pura
  y no reejecuta el objetivo; un oráculo costoso futuro necesita otro contrato
  de ejecución acotado.
- Comprobar capacidad de prepend/append antes de asignar, preservando salidas
  y veredictos de límite. Mantener vector de versión al no cambiar semántica.
- Gleam 1.10.0 genera un módulo CLI no usado que referencia inspección stdlib.
  Distribuir solo efz_qs_model y ajustar módulos de .app opcional; archivar
  BEAM CLI antiguo fuera de ebin. Conservar primer fallo xref y repetición
  final superada; no se introdujo paquete externo.
- La revisión es expresamente autorrevisión del autor. No se atribuyen
  revisor independiente/subagentes ni finalización de todos los prompts.

- Los errores de capacidad al arrancar ahora nombran explícitamente política
  de oráculo/objetivo no admitidos, requisito staged, opciones desconocidas,
  límites/fracción/presupuesto no válidos. Átomos acotados fijos sustituyen
  badmatch opacos; comportamiento de éxito/desactivado intacto.

## Decisiones de integración nativa P2 (2026-10-08)

- Mantener Gleam 1.10.0, OTP 27.0 y Rebar3 3.25.0 fijados y locks intactos.
  El perfil Rebar opcional existente consume solo BEAM compilado y .app.
  Dos compilaciones forzadas del paquete en el mismo entorno privado dan
  hashes idénticos.
- Validar ocho callbacks exportados del núcleo al arrancar activado, con
  motivo acotado de callback ausente. Sin búsqueda en ruta crítica, arranque
  de aplicación ni transporte.
- Demostrar callback real con fracción cero, feedback semántico desactivado
  y una comprobación pura inline. La traza ordena objetivo, captura nativa,
  adaptador, decode/check Gleam compilado; no se añade política estructurada/
  de guía en producción.
- Compilar desactivado desde fuentes sin directorio/ejecutable/artefactos
  Gleam. Copias privadas de dependencias ordinarias fijadas evitan depender
  de cachés BEAM o red; el override checkout de Rebar solo reescribe el lock
  privado y deja intacto el del repositorio.
- Mantener contadores/tiempos detallados muestreados en un driver finito de
  diagnóstico, separado de informes de producción y mediciones por lotes.
  No usa RNG. export_all temporal se restringe a la VM diagnóstica.
- La inyección de callback bloqueado usa worker monitorizado solo de prueba.
  La capa de producción mantiene llamadas directas acotadas; no se afirman
  cancelación nativa arbitraria ni protocolos de transporte de workers.
- Conservar logs fallidos iniciales: aviso de variable del stub; fuentes de
  fixtures temporales omitidas; aserción de traza del colector perfilado
  cuando la campaña usaba collect/1. Se corrigió cada uno y se repitió la
  comprobación afectada.
- Verificar raíces reales del runtime, además de versiones: el off inicial
  con PATH mínimo eligió OTP 27.3.4.13 del sistema. Conservarlo como evidencia
  extra de compatibilidad y repetir off limpio con asdf OTP 27.0 principal,
  aún sin artefactos Gleam/compilador. Registrar ruta absoluta de la fuente
  de cobertura P0 instalada.

- Acotar motivos etiquetados semantic_layer_error además de tuplas genéricas
  de excepción; solo clases error/exit/throw con motivos atómicos pasan.
  Un fallo etiquetado de 8192 bytes se reduce a invalid_boundary, preservando
  diagnósticos finitos.

## Decisiones del proveedor P3 (2026-10-08)

- Mantener selección EFZ de padre/etapa, presupuesto de mutación, corpus y
  ejecución del objetivo. Decodificar solo tras elegir la rama estructurada;
  la alternativa llama una vez directamente a ordinary_attempts con el estado
  RNG posterior a la selección. Los errores detienen con diagnóstico.
- Mantener semántica v1 de seis operaciones/modelo/códec/mutador. Sustituir
  la codificación descartada del mutador por comprobación previa de tamaño;
  comparar contra BEAM P2 archivado en VM diagnóstica separada. Sin caché,
  aprendizaje de pistas ni worker.
- Ampliar solo el catálogo fuera del bucle a versión 2 (paquete 1.1.0).
  Doce posiciones cubren límites de componente/campo/formato; preparación
  separada y todas las entradas llegan a CLI/corpus como bytes originales.
- El nuevo esquema estructurado 3 conserva palabras del estado exsplus en
  lista propia exacta, límites y fracción; recetas ordinarias mantienen
  esquema 1 y el estructurado 2 antiguo sigue legible. Operación v2 y
  envoltura EFZR v1 no cambian.
- Las muestras detalladas siguen en driver diagnóstico acotado; contadores
  de campaña añaden operaciones y bytes generados. Fracciones 1/5/10/20 son
  muestras exploratorias del mismo motor, no óptimo ni ventaja de rendimiento.

## Decisiones del feedback P4 (2026-10-08)

- Mantener query_model_agreement v1: comparar campos admitidos decodificados
  independientemente con resultado completado del parser Cowlib real.
  Es propiedad de resultado esperado, no comprobación diferencial ni ley de
  ida y vuelta de la capa. Sin reejecución ni oráculo costoso/diferido en línea.
- Mantener espacio exacto cow_qs/1 con 12 IDs y máximo cuatro por ejecución.
  Exigir metadatos persistidos canónicos de forma exacta. Una consulta del
  corpus de solo lectura y fuera del bucle deriva un representante por
  característica sin índice persistente.
- Confirmar bytes/metadatos nuevos antes del conjunto semántico visto,
  usando propietario serializado existente. Las características duplicadas
  concurrentes reciben un crédito; reintentar escritura fallida mantiene
  novedad. Las anotaciones de entradas existentes se reconstruyen al reiniciar.
- El corpus online append-only no necesita transacción de eliminación/
  referencias. Probar subconjunto conservador copiándolo a un almacén nuevo
  y recalibrar; preservar artefactos originales y rechazar diferencias de
  esquema. Quitar archivos manualmente entre campañas no puede dejar un
  índice visto global antiguo; editar disco online sigue sin admitirse.
- Verificar bits nativos sellados y unidades decodificadas no vacías.
  La primera aserción de traza comparó por error listas diagnósticas vacías;
  conservar pruebas anteriores y sustituir la evidencia de aceptación por
  la prueba nativa corregida.
- Mantener continuación normal de hallazgos y política de huellas/
  representantes. El defecto artificial no es un hallazgo real de Cowlib
  ni experimento de detección. Reproducción/minimización cuentan aparte;
  el oráculo de producción añade cero llamadas.
