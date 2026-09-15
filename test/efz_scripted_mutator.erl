%% Deterministic feedback acceptance fixture, never a production mutator.
-module(efz_scripted_mutator).
-behaviour(efz_mutator).
-export([mutate/2]).
mutate(_, #{iteration := N}) -> lists:nth(N, [<<>>, <<>>, <<255>>, <<1, 7>>, <<1, 7>>]).
