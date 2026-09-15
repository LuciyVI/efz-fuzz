%% Binary adapter for the unchanged, ordinary repeated-loop fixture.
-module(efz_perf_loop_target).
-export([run/1]).
run(Bin) ->
    N = case Bin of <<X, _/binary>> -> 128 + X; <<>> -> 128 end,
    Value = efz_bench_fixture:run(N),
    %% Validate the closed-form checksum without rerunning the target.
    Remainder = case N rem 4 of 0 -> 0; 1 -> 2; 2 -> 5; 3 -> 8 end,
    Expected = (N div 4) * 9 + Remainder,
    Expected = Value,
    Value.
