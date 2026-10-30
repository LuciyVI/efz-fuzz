%% Payload-to-public-API data flow. See docs/cowboy-harness-suite.md.
-module(efz_cowboy_headers_target).
-export([run/1, seeds/0, sample/1, modules/0, surface/0]).
run(Input) -> efz_cowboy_flow:run(headers, Input).
seeds() -> efz_cowboy_flow:seeds(headers).
sample(Index) -> efz_cowboy_flow:sample(headers, Index).
modules() -> efz_cowboy_flow:modules(headers).
surface() -> headers.
