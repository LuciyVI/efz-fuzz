-module(efz_external_target).
-export([run/1]).
run(<<"DIRTY">>)->persistent_term:put(efz_external_dirty,true),ok;
run(<<"WAIT">>)->receive never->ok end;
run(<<"BUSY">>)->busy();
run(Input)->efz_native_fixture:act(Input).
busy()->busy().
