# Documentación de EFZ

[English](../../README.md) · [Русский](../ru/index.md) · **Español** · [简体中文](../zh-CN/index.md) · [Todos los idiomas](../README.md)

El idioma canónico de la documentación es el inglés. El [índice de idiomas](../README.md) enlaza las ediciones completas en ruso, español y chino simplificado del README, las guías, las auditorías y los informes. El [README del proyecto](README.md) presenta las funciones.

## Empiece aquí

- [Preparar y ejecutar EFZ](quickstart.md)
- [Lanzador universal de fuzzing](cli.md)
- [Panel de EFZ en terminal](tui.md)
- [Fuzzing continuo](continuous.md)
- [Generar un conector a partir de una especificación Erlang](gleam-layer/connector-generation.md)
- [Conectar una biblioteca Erlang a Gleam Layer](gleam-layer/connecting-erlang-libraries.md)
- [Arquitectura de EFZ](architecture.md)
- [Mapa del repositorio EFZ: directorios y archivos](repository-map.md)

## Referencia completa

Los informes históricos conservan la fecha, el entorno verificado, el alcance y las limitaciones del trabajo original. Un resultado registrado describe aquella ejecución; no constituye una afirmación sobre cada revisión posterior. Los registros originales, los artefactos binarios y los identificadores del código se conservan como evidencia. Algunos informes enlazan directorios temporales o archivos de evidencia que no se incluyen en una copia nueva; sus rutas originales se conservan para mantener la procedencia.

### Guías del motor y de operación

- [Arquitectura de EFZ](architecture.md)
- [Auditoría de preparación de EFZ para calibración y feature_stability](calibration-readiness.md)
- [Lanzador universal de fuzzing](cli.md)
- [Fuzzing continuo](continuous.md)
- [Corpus persistente reutilizable](corpus.md)
- [Backend bitmap para la cobertura de EFZ](coverage-bitmap-architecture.md)
- [Auditoría técnica del backend de cobertura bitmap de EFZ](coverage-bitmap-audit.md)
- [Backend de cobertura bitmap: informe de implementación](coverage-bitmap-implementation-report.md)
- [Cobertura bitmap v2: implementación y resultado medido](coverage-bitmap-v2-results.md)
- [Integridad de la cobertura automática](coverage-integrity.md)
- [Seguimiento de cobertura EFZ: auditoría y comparación con AFL++](coverage-tracking-audit.md)
- [Contrato de cobertura automática](coverage.md)
- [Benchmark largo de Cowboy: ETS, bitmap-v2 y OTP-public](cowboy-long-benchmark.md)
- [Arneses de flujo de datos de Cowboy](cowboy-harness-suite.md)
- [Arneses de flujo de datos XML-RPC](xmlrpc-harness-suite.md)
- [Resultados de cobertura DWARF/nativa](dwarf-native-coverage-results.md)
- [Cobertura DWARF/nativa: punto de control de viabilidad](dwarf-native-coverage.md)
- [EFZ: perfil de rendimiento del motor v2 (2026-10-04)](engine-performance-profile-v2.md)
- [EFZ: perfil de coste de una iteración](engine-performance-profile.md)
- [Modelo de ejecución: harness binario síncrono con descendientes controlados](execution-isolation.md)
- [EFZ: feedback experimental de hit-count](hit-count-experiment.md)
- [Límites de entrada y fallos de almacenamiento](input-and-storage.md)
- [Mutación nativa por etapas (versión del motor 1)](mutations.md)
- [Cobertura experimental de líneas con API pública de OTP (2026-10-03)](otp-native-public-results.md)
- [P1-01 Supervisor externo](p1-01-external-supervisor.md)
- [Registro de validación de Phase 2](phase2-validation.md)
- [Registro de rendimiento y cierre de Phase 2.1](phase2.1-performance.md)
- [Validación Phase 3: mutación por etapas y replay exacto](phase3-validation.md)
- [Preparar y ejecutar EFZ](quickstart.md)
- [Ocurrencias de fallos, firmas y reproducción verificada](replay.md)
- [Mapa del repositorio EFZ: directorios y archivos](repository-map.md)
- [Correcciones de aceptación P0 — 2026-09-21](runtime-diagnostics-acceptance-fixes.md)
- [Validación P0 — 2026-09-16](runtime-diagnostics-validation.md)
- [Diagnóstico automático en ejecución (P0)](runtime-diagnostics.md)
- [Auditoría técnica de EFZ — 12 de septiembre de 2026](technical-audit-2026-09-12.md)
- [Panel de EFZ en terminal](tui.md)

### Capa semántica / Gleam

- [API 1 del adaptador semántico](gleam-layer/adapter-contract.md)
- [Responsabilidades y orden de aceptación](gleam-layer/agent-plan.md)
- [Arquitectura Gleam nativa: contrato v1](gleam-layer/architecture.md)
- [Referencia P0](gleam-layer/baseline.md)
- [Conectar una biblioteca Erlang a Gleam Layer](gleam-layer/connecting-erlang-libraries.md)
- [Generar un conector a partir de una especificación Erlang](gleam-layer/connector-generation.md)
- [Contrato Erlang/Gleam nativo v1](gleam-layer/contracts.md)
- [Decisiones](gleam-layer/decision-log.md)
- [Mapa real de fuentes](gleam-layer/execution-path.md)
- [Validación del contrato P1 y traspaso](gleam-layer/p1-validation.md)
- [P2: integración BEAM nativa opcional](gleam-layer/p2-integration.md)
- [P3: proveedor estructurado — PASS](gleam-layer/p3-provider.md)
- [P4: oráculo y realimentación del corpus — PASS](gleam-layer/p4-feedback.md)
- [P5: aceptación final de reproducción, regresión y mismo motor](gleam-layer/p5-validation.md)
- [Gleam Layer: implementación y resultados verificables](gleam-layer/universal-validation.md)
- [> Este documento describe la interfaz histórica de compatibilidad QS. La guía](gleam-layer/user-guide.md)

### Decisiones de arquitectura

- [ADR 0002: sondas de cláusulas/resultados en fuente con ETS por ejecución](adr/0002-automatic-coverage.md)

### Planes de implementación

- [Plan de implementación del backend de cobertura bitmap](plans/coverage-bitmap-implementation-plan.md)

Las [fuentes e imágenes de los diagramas UML](diagrams/README.md) se mantienen por separado.

## Integraciones y guías actuales

- [Erlamsa](erlamsa-integration.md)
- [Persistent worker](erlamsa-performance.md)
- [Feature stability](feature-stability.md)
- [Python SDK](packages/pyefz/README.md)

- [VM persistente del objetivo](persistent-target.md)
