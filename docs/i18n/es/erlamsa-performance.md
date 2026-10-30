# Worker externo persistente de Erlamsa

Esta es una guía breve. La [arquitectura y los límites completos](../../erlamsa-performance.md) están en inglés.

`transport = disposable` conserva el comportamiento anterior. `transport = persistent` inicia una VM Erlang externa para las solicitudes secuenciales de una campaña; cada solicitud usa un proceso nuevo y su propia seed. La identidad se comprueba al iniciar y el watchdog externo puede terminar la VM tras un timeout. `max_requests` permite reciclarla entre solicitudes. El reciclaje, PID y tiempos son evidencia de ejecución y no alteran el recipe.

Esta VM es independiente de la VM persistente opcional del objetivo. Las [mediciones](../../erlamsa-performance-validation.md) sólo corresponden a los builds y entradas registrados.
