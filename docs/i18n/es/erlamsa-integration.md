# Proveedor local Erlamsa

Esta es una guía breve. El [contrato completo y catálogo de operaciones](../../erlamsa-integration.md) está en inglés.

El proveedor se activa explícitamente con `mutation_provider.mode = erlamsa` o `hybrid`. El adaptador semántico se configura por separado; native sigue siendo el modo predeterminado. El gitlink `vendor/erlamsa` fija la versión del núcleo sin seguir automáticamente la rama del fork.

```sh
git submodule update --init --recursive
ERL_FLAGS='+S 2:2' rebar3 as erlamsa compile
```

Si falta el núcleo preparado, la configuración falla antes de ejecutar el objetivo. El replay de bytes guardados no necesita el núcleo; la regeneración exige la misma identidad de build y configuración. Los errores y tiempos de espera del proveedor no son fallos del objetivo. La [validación histórica](../../erlamsa-validation.md) corresponde a los SHA allí indicados.
