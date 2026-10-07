-module(efz_native_line_fixture).
-export([run/1]).
run(a) -> alpha;
run(b) ->
    Value = erlang:unique_integer([positive]),
    {beta, Value};
run(crash) -> error(expected_fixture_crash);
run(<<"a">>) -> run(a);
run(<<"crash">>) -> run(crash);
run(<<"timeout">>) -> receive after 1000 -> done end.
