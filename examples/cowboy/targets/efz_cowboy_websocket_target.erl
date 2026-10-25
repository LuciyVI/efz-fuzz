%% Payload-to-public-API data flow. See docs/cowboy-harness-suite.md.
-module(efz_cowboy_websocket_target).
-export([run/1, seeds/0, sample/1, modules/0, surface/0]).
run(Input) -> efz_cowboy_flow:run(websocket, Input).
seeds() -> efz_cowboy_flow:seeds(websocket).
sample(Index) -> efz_cowboy_flow:sample(websocket, Index).
modules() -> efz_cowboy_flow:modules(websocket).
surface() -> websocket.
