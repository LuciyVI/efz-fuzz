# VM persistente del objetivo

Esta es una guía breve. El [ciclo de vida, journal y replay completos](../../persistent-target.md) están en inglés.

`execution.mode = persistent_vm` y `state_policy = accumulate` se activan explícitamente. Durante una época persisten la VM, el PID del driver, el process dictionary, el mailbox y los recursos OTP/ETS del objetivo. Cada entrada abre una nueva ventana de cobertura, que no se calcula restando del union acumulado. Un crash, timeout o pérdida de integridad termina la época; reiniciar crea otra época.

El journal registra bytes exactos y su orden antes de enviarlos al objetivo. Sequence replay vuelve a ejecutar desde `init` por todo el prefix; raw replay de una sola entrada no recupera la historia. Las repeticiones independientes se ejecutan secuencialmente en épocas nuevas sin alterar la trayectoria primary. La actividad de fondo sin barrier no garantiza una ventana completa.
