%% Model-free oracle fixture for semantic boundary regressions.
-module(efz_plugin_oracle_adapter).
-behaviour(efz_semantic_adapter).
-export([descriptor/0,prepare/3,oracle/3]).
descriptor() -> #{id=><<"fixture.oracle">>,api_version=>1,model_version=>1,
    observer_version=>1,recipe_version=>1,operations_version=>1,
    capabilities=>[oracle],operations=>[],model_modules=>[],
    properties=>[{fixture_property,1}]}.
prepare(_,Options,_) -> {ok,Options}.
oracle(_,_,#{skip:=true}) -> {skip,unsupported};
oracle(_,_,_) -> {pass,{fixture_property,1}}.
