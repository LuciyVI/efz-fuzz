%% Ordinary target: only the compiler inserts coverage hooks.
-module(efz_lineage_parser).
-export([parse/1]).

parse(<<"A">>) -> path_a;
parse(<<"AB">>) -> path_ab;
parse(<<"ABC">>) -> path_abc;
parse(_) -> unknown.
