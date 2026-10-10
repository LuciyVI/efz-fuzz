%% Cold context consistency fixture; this mutable source is deliberately test-only.
-module(efz_plugin_context_adapter).
-behaviour(efz_semantic_adapter).
-export([descriptor/0,prepare/3,observe/3]).
descriptor()->(efz_plugin_observer_adapter:descriptor())#{id=><<"fixture.context">>}.
prepare(_,_,_)->{ok,#{context_value=>case get({?MODULE,context}) of undefined->0;V->V end}}.
observe(_,_,#{context_value:=V})->{ok,[V]}.
