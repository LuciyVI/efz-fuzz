-module(efz_durable_harness).
-export([run/1]).
run(B) when is_binary(B) -> efz_lineage_parser:parse(B).
