-module(efz_bench_fixture).
-export([run/1]).
run(N) -> loop(N, 0).
loop(0, Acc) -> Acc;
loop(N, Acc) ->
    Next = case N band 3 of 0 -> Acc + 1; 1 -> Acc + 2; _ -> Acc + 3 end,
    loop(N - 1, Next).
