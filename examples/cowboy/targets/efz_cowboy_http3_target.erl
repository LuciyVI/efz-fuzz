%% Payload-to-public-API data flow. See docs/cowboy-harness-suite.md.
-module(efz_cowboy_http3_target).
-export([run/1, seeds/0, sample/1, modules/0, surface/0]).
run(Input) -> efz_cowboy_flow:run(http3, Input).
seeds() -> efz_cowboy_flow:seeds(http3).
sample(Index) -> efz_cowboy_flow:sample(http3, Index).
modules() -> efz_cowboy_flow:modules(http3).
surface() -> http3.
