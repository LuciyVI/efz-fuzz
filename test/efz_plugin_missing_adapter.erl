%% Deliberately malformed fixture: advertises observation but omits observe/3.
-module(efz_plugin_missing_adapter).
-export([descriptor/0,prepare/3]).
descriptor() -> (efz_plugin_observer_adapter:descriptor())#{id=><<"fixture.missing_callback">>}.
prepare(_,_,_) -> {ok,#{}}.
