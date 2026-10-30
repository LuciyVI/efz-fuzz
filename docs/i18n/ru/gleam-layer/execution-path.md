# Фактическая карта исходников

[English](../../../gleam-layer/execution-path.md) · **Русский** · [Español](../../es/gleam-layer/execution-path.md) · [简体中文](../../zh-CN/gleam-layer/execution-path.md) · [Все языки](../../README.md)

- efz_config:prepare/1 проверяет конфигурацию, efz_cov_native_public:preflight/1
  или efz_instrument:preflight/1 проверяет выбранные артефакты цели.
- efz_fuzzer:init/1 запускает существующие корпус, статистику и worker supervisor.
- efz_worker:handle_info/2 калибрует seeds до мутаций; staged_iteration/1
  вызывает efz_mutation_plan:next/2 с efz_corpus:mutation_entries/0.
- efz_mutation_plan:visit/2 посещает родителей в порядке вставки и существующие lanes;
  attempts/6 диспетчеризует необязательную структурную ветвь до decode, иначе
  ordinary_attempts/6 сохраняет deterministic/havoc/splice операции.
- efz_worker:execute_checked/4 вызывает efz_executor:run/4. efz_guardian владеет timeout,
  управляемыми потомками, очисткой и завершением покрытия. Покрытие уже
  материализовано/зафиксировано до оценки новизны в execute_result/6.
- efz_worker:semantic_callbacks/4 находится после снимка цели. Чистый observer
  использует нормализованный результат; чистый oracle согласования с моделью имеет конечное число проверок
  и делает **ноль** вызовов цели. Нет очереди, worker или дополнительного интервала исполнения.
- efz_feedback:evaluate/3 остаётся владельцем решения о структурной новизне.
- efz_corpus:semantic_admission/6 расширяет retention для guided-режима, фиксируя
  постоянное хранение до обновления семантических признаков корпуса. efz_corpus:select/0
  и staged-план используют те же entries. Независимого семантического корпуса нет.
- efz_worker:record_failure/4 -> efz_crash:save/4 сохраняет исходные байты.
  Сбои цели предшествуют семантическим callbacks; нарушения oracle имеют отдельные
  отпечатки в том же хранилище находок, независимо от новизны.
- efz_recipe:regenerate/1 регенерирует версионированные structured_replace данные без
  Gleam; efz_replay и efz_recipe:execute/5 используют существующий executor с зафиксированными identities.
  efz_semantic_replay отдельно проверяет свойство и учитывает каждое исполнение
  минимизатора. efz_semantic:cover/1 консервативно сохраняет записанные признаки.
