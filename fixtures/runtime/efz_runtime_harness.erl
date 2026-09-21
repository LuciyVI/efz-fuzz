-module(efz_runtime_harness).
-export([run/1]).
run(<<"empty">>)->ok;
run(B) when is_binary(B)->efz_runtime_sites:run(B).
