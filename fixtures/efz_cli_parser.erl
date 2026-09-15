%% Ordinary source: only the selected parser is instrumented by the test build.
-module(efz_cli_parser).
-export([parse/1]).
parse(<<128, Rest/binary>>) -> {high, Rest};
parse(B) -> {low, B}.
