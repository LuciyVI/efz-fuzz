-module(efz_external_startup).
-on_load(init/0).
-export([run/1]).
init()->{module,efz_native_fixture}=code:ensure_loaded(efz_native_fixture),ok.
run(Input)->efz_native_fixture:act(Input).
