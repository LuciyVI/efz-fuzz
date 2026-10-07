%% Tiny length-prefixed record parser: only complete records advance depth.
-module(efz_count_records).
-export([run/1]).
run(Input) -> records(Input,0).
records(<<1,1,Payload,Rest/binary>>,N) when Payload=<127 -> records(Rest,N+1);
records(_,N) -> finish(N).
finish(N) when N>=8 -> deep;
finish(_) -> shallow.
