-module(efz_coverage_idle_mutator).
-behaviour(efz_mutator).
-export([mutate/2]).

mutate(_,#{iteration:=5}) -> <<1>>;
mutate(_,_) -> <<0>>.
