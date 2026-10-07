%% Repeated-byte token with a depth-gated semantic branch.
-module(efz_count_repeat).
-export([run/1]).
run(Input) -> scan(Input,0).
scan(<<$A,Rest/binary>>,N) -> scan(Rest,N+1);
scan(_,N) -> depth(N).
depth(N) when N>=16 -> deep;
depth(_) -> shallow.
