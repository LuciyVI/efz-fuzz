%% Minimal generator-only plugin: no parser, mutation, observation or oracle.
-module(efz_plugin_generator_adapter).
-behaviour(efz_semantic_adapter).
-export([descriptor/0,prepare/3,generate/2]).
descriptor() -> #{id=><<"fixture.generator">>,api_version=>1,model_version=>1,
    observer_version=>1,recipe_version=>1,operations_version=>1,
    capabilities=>[generation],operations=>[],model_modules=>[],properties=>[]}.
prepare(_Target,#{},Limits) -> {ok,#{bytes=>maps:get(bytes,Limits)}}.
generate(_Index,#{bytes:=Max}) when Max>=2 -> {ok,<<0:16>>};
generate(_,_) -> {skip,limit}.
