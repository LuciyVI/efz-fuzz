-module(efz_plugin_other_observer_adapter).
-behaviour(efz_semantic_adapter).
-export([descriptor/0,prepare/3,observe/3,code_dependencies/1]).
descriptor() -> (efz_plugin_observer_adapter:descriptor())#{id=><<"fixture.observer_b">>}.
prepare(Target,Options,Limits) -> efz_plugin_observer_adapter:prepare(Target,Options,Limits).
observe(Raw,Outcome,Context) -> efz_plugin_observer_adapter:observe(Raw,Outcome,Context).
code_dependencies(_) -> #{semantic=>[efz_plugin_observer_adapter],target=>[]}.
