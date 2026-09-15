-module(efz_cli_harness).
-export([run/1]).
run(B) when is_binary(B) -> efz_cli_parser:parse(B).
