%% Payload-to-public-API data flow. See docs/cowboy-harness-suite.md.
-module(efz_cowboy_multipart_target).
-export([run/1, seeds/0, sample/1, modules/0, surface/0]).
run(Input) -> efz_cowboy_flow:run(multipart, Input).
seeds() -> efz_cowboy_flow:seeds(multipart).
sample(Index) -> efz_cowboy_flow:sample(multipart, Index).
modules() -> efz_cowboy_flow:modules(multipart).
surface() -> multipart.
