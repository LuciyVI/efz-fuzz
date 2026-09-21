-module(efz_native_fixture).
-on_load(load/0).
-export([act/1]).
load()->erlang:load_nif(filename:join(filename:dirname(code:which(?MODULE)),"efz_native_fixture"),0).
act(_)->erlang:nif_error(not_loaded).
