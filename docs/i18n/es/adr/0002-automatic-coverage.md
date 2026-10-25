# ADR 0002: sondas de cláusulas/resultados en fuente con ETS por ejecución

[English](../../../adr/0002-automatic-coverage.md) · [Русский](../../ru/adr/0002-automatic-coverage.md) · **Español** · [简体中文](../../zh-CN/adr/0002-automatic-coverage.md) · [Todos los idiomas](../../README.md)

Estado: aceptado antes de implementar la transformación, 2026-09-08.

Referencia: OTP 27.0 / ERTS 15.0, x86_64-pc-linux-gnu; Rebar3 3.25.0.
Las siete pruebas EUnit existentes, compilación y Dialyzer se superan.
Common Test no tiene suites (cero pruebas). No existen formateador/linter del
repositorio ni AGENTS.md. La fase 1 está en gran parte sin commit; conserve y
adapte esa implementación.

## Alternativas

* Transformación de formas abstractas: el compilador instalado expone los
  cuerpos de cláusulas y formas case/if/receive/try/fun anidadas antes de
  reducirlas. Anteponer llamadas dentro de los cuerpos conserva guards,
  patrones, orden de evaluación y posición de cola. El recorrido explícito
  de expresiones y los diagnósticos limitan el riesgo de sintaxis. Un hook
  puede usar el contexto del proceso ejecutor y un propietario ETS externo.
* OTP cover y cobertura nativa: OTP 27 tiene API de cobertura nativa
  (verificadas en el módulo code instalado); cover usa soporte nativo cuando
  está disponible. Ofrecen cobertura de líneas/funciones y análisis cover,
  pero su API de recopilación/reset orientada a módulos no proporciona
  referencias de ejecución EFZ ni aísla procesos ajenos. Un adaptador
  necesitaría diseño adicional de aislamiento y atribución. No hemos medido
  cover y no afirmamos ventajas de velocidad.
* Reescritura de Core Erlang o BEAM: la reducción oculta algunos resultados
  del código fuente e introduce acoplamiento a la versión del compilador y
  trabajo de mapeo. Editar opcodes no documentados añade riesgo de validación
  sin resolver la atribución a ejecuciones.

Elija un backend de formas abstractas. Compile solo módulos fuente permitidos,
independientemente de una aplicación o campaña. Incruste un atributo de
manifiesto en el BEAM y escriba un archivo auxiliar desde la fachada explícita
de compilación. Use espacios de nombres de compilación SHA-256 y rutas de
sondas estructurales deterministas. No edite el texto fuente.

Runtime: un conjunto ETS público y sin nombre por ejecución, propiedad del
coordinador de monitorización del executor y externo al objetivo. El
coordinador también monitoriza al llamador y mata/espera al objetivo en una
cancelación. Solo después del DOWN del objetivo puede capturar/eliminar el
almacenamiento. Los hooks usan un contexto de diccionario de proceso con
espacio de nombres; el diccionario no almacena la cobertura. Los errores de
backend son fallos persistentes de infraestructura, incluso cuando los
manejadores de excepciones del objetivo los capturan.

Campaña: un worker; calibrar semillas, combinar solo cobertura de ejecuciones
exitosas, conservar la novedad de conjuntos exactos y guardar las caídas del
objetivo por separado. Fijar IDs de compilación en la validación previa y
rechazar observaciones incompatibles. Mantener la API manual hit en un espacio
de identidades separado solo para el modo explícito de compatibilidad.

Mida rutas ordinaria, instrumentada inactiva e instrumentada activa con un
benchmark repetido tras calentamiento. ETS añade trabajo por acierto; priorice
la corrección del ciclo de vida antes de optimizar. Registre las mediciones
reales en docs/coverage.md.

Referencias: [OTP 27 cover](https://www.erlang.org/docs/27/apps/tools/cover.html)
y [OTP 27 code](https://www.erlang.org/docs/27/apps/kernel/code.html).
La documentación en línea de OTP 27 describe un parche posterior de 27.x;
también se inspeccionaron exportaciones y fuentes instaladas. El soporte nativo
se añadió en OTP 27.
