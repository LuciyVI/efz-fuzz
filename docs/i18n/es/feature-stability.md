# Estabilidad de características de cobertura

Esta es una guía breve. La [definición, configuración y estados completos](../../feature-stability.md) están en inglés.

Para una entrada auditada, EFZ usa los conjuntos completos de cada ejecución: `U = union(F₁…Fᵣ)`, `I = intersection(F₁…Fᵣ)` y `feature_stability = 100 × |I| / |U|`. Para la campaña suma `|I|` y `|U|` **por grupo de entrada** antes de dividir. Hacen falta al menos dos observaciones válidas y un `U` no vacío; en otro caso el porcentaje es nulo. Una traza vacía válida no equivale a una traza ausente.

En modo isolated, 20 observaciones suelen requerir 19 ejecuciones adicionales. Las llamadas diagnósticas no cuentan en primary exec/s ni cambian el RNG de mutación. El TUI muestra el porcentaje, estado, grupos auditados y antigüedad de la última medición. `100%` sólo describe las observaciones realizadas.
