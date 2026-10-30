%% Minimal observer-only plugin; absence of other callbacks is deliberate.
-module(efz_plugin_observer_adapter).
-behaviour(efz_semantic_adapter).
-export([descriptor/0,prepare/3,observe/3]).
descriptor() -> #{id=><<"fixture.observer_a">>,api_version=>1,model_version=>1,
    observer_version=>1,recipe_version=>1,operations_version=>1,
    capabilities=>[observation],operations=>[],model_modules=>[],properties=>[]}.
prepare(Target,Options,_Limits) ->
    Mode=maps:get(mode,Options,valid),
    case erlang:function_exported(Target,run,1) andalso maps:keys(Options)--[mode]=:=[]
        andalso lists:member(Mode,[valid,invalid,exception,large_error]) of
        true->{ok,#{mode=>Mode}};
        false->{error,invalid_observer_fixture_options}
    end.
observe(_,_,#{mode:=valid}) -> {ok,[1]};
observe(_,_,#{mode:=invalid}) -> {ok,[999]};
observe(_,_,#{mode:=exception}) -> error(fixture_callback_error);
observe(_,_,#{mode:=large_error}) -> {error,binary:copy(<<42>>,2048)}.
