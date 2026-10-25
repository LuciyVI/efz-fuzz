# Resultados de cobertura DWARF/nativa

[English](../../dwarf-native-coverage-results.md) · [Русский](../ru/dwarf-native-coverage-results.md) · **Español** · [简体中文](../zh-CN/dwarf-native-coverage-results.md) · [Todos los idiomas](../README.md)

Estado al 2026-10-03: **helper de lectura directa aplazado**. Consulte
[`dwarf-native-coverage.md`](dwarf-native-coverage.md) para conocer la disposición
observada en OTP, el problema de vida útil de los punteros y la preparación
reproducible para continuar.

| Comprobación | Resultado |
| --- | --- |
| API pública de cobertura nativa de OTP | PASS en un fixture pequeño de cobertura de líneas y el backend experimental `otp_native_public` |
| Descubrimiento de tipos/campos DWARF | PASS para el binario OTP 27.0 investigado |
| Lectura directa segura de cobertura | NO EJECUTADA: sin contrato/helper demostrado de vida útil del cargador de código |
| Lectura directa frente a `code:get_coverage/2` | NO EJECUTADA |
| Comprobación breve de Cowboy con API pública de OTP (30 s) | PASS tras corregir el formato de metadatos del corpus: 5889 ejecuciones, 196.26 exec/s, 0 errores de infraestructura con el código final; una sola ejecución del código final |
| Comprobación breve de Cowboy con DWARF nativo (30 s) | NO EJECUTADA: backend no implementado |
| Microbenchmark nativo de reset/lectura/novedad/merge | PASS; consulte `docs/performance/otp-native-public-2026-10-03.term` y `otp-native-public-cowboy-2026-10-03.term` |
| Ejecuciones de Cowboy de 15 minutos | NO EJECUTADAS; reservadas para ejecución manual tras las comprobaciones breves |

En la ruta fija GET de Cowboy, las medianas por componente fueron: reset
0.50 µs, `code:get_coverage` 5.63 µs, conversión compacta 30.77 µs, búsqueda sin
novedad 3.37 µs, merge 4.97 µs, ciclo completo con objetivo directo 68.68 µs
(10 muestras de 100 iteraciones después de dos calentamientos). La ejecución
completa de EFZ de 30 segundos promedia unos 5.1 ms por ejecución, por lo que
actualmente no se ha demostrado que `get_coverage` ni la conversión dominen el
tiempo total de EFZ. Estas mediciones por sí solas no justifican un helper
directo. **No hay** cifras de rendimiento DWARF nativo.
