-module(efz_runtime_memory_fixture).
-export([run/1]).
%% A retained return is a supported residual VM allocation, not a target leak.
%% No shared state, external processes or ownership escape are required.
run(<<"residual">>)->
    B=binary:copy(<<42>>,16*1024*1024),
    receive after 40->ok end,B;
run(<<"temporary">>)->
    B=binary:copy(<<42>>,16*1024*1024),
    receive after 40->ok end,
    byte_size(B);
run(<<"waiting">>)->receive never->ok end;
run(<<"reference">>)->make_ref();
run(_)->ok.
