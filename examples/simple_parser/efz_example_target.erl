-module(efz_example_target).
-behaviour(efz_target).
-export([run/1]).
run(Input) -> efz_example_parser:classify(Input).
