%% A handshake requires repeated tick/ack transitions before accepting commit.
-module(efz_count_machine).
-export([run/1]).
run(Input) -> ready(Input,0).
ready(<<$T,Rest/binary>>,N) -> waiting(Rest,N);
ready(<<$C>>,N) when N>=8 -> deep;
ready(_,_) -> shallow.
waiting(<<$A,Rest/binary>>,N) -> ready(Rest,N+1);
waiting(_,_) -> shallow.
