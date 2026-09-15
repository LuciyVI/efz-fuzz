%% Ordinary artificial classifier; no EFZ API or coverage calls.
-module(efz_staged_parser).
-export([run/1]).
run(<<"TOKEN",_/binary>>) -> dictionary_token;
run(<<"BOOM!",_/binary>>) -> error(artificial_staged_exception);
run(<<128>>) -> signed_boundary;
run(<<1>>) -> arithmetic_one;
run(<<0>>) -> initial_zero;
run(<<>>) -> empty;
run(_) -> other.
