%% The same target functions and initial corpus are used in every mode.
-module(efz_cowboy_suite).
-export([surfaces/0, target/1, modules/1, seeds/1, setup/1, teardown/1,
    counters/1, config/4]).

surfaces() -> [qs, headers, cookies, router, http1, http2, http3,
    websocket, multipart, hpack, qpack].
target(qs) -> efz_cowboy_qs_target;
target(headers) -> efz_cowboy_headers_target;
target(cookies) -> efz_cowboy_cookies_target;
target(router) -> efz_cowboy_router_target;
target(http1) -> efz_cowboy_http1_target;
target(http2) -> efz_cowboy_http2_target;
target(http3) -> efz_cowboy_http3_target;
target(websocket) -> efz_cowboy_websocket_target;
target(multipart) -> efz_cowboy_multipart_target;
target(hpack) -> efz_cowboy_hpack_target;
target(qpack) -> efz_cowboy_qpack_target.
modules(Surface) -> efz_cowboy_flow:modules(Surface).
seeds(Surface) -> efz_cowboy_flow:seeds(Surface).
setup(Surface) -> efz_cowboy_flow:setup(Surface).
teardown(Surface) -> efz_cowboy_flow:teardown(Surface).
counters(Surface) -> efz_cowboy_flow:counters(Surface).

config(Surface, Mode, Budget, Seed) when is_integer(Seed), Seed >= 0 ->
    true = lists:member(Surface, surfaces()),
    true = lists:member(Mode, [off, observation_only, guided]),
    true = Budget =:= infinity orelse (is_integer(Budget) andalso Budget > 0),
    Rng = {Seed + 1, Seed + 3, Seed + 7},
    Layer = case Mode of
        off -> false;
        _ -> #{adapter => efz_cowboy_flow_adapter,
            adapter_options => #{surface => Surface},
            %% Observation-only changes no mutation, RNG or admission rule.
            structured_fraction => case Mode of observation_only -> 0; guided -> 30 end,
            feedback => Mode, oracle => disabled,
            limits => #{bytes => 1024, nodes => 128, depth => 8,
                collection => 32, operations => 1}}
    end,
    #{target => target(Surface), artifacts => [], seeds => seeds(Surface),
      timeout => 500, max_iterations => Budget, max_input_bytes => 1024,
      coverage_backend => none, mutation_mode => staged,
      mutation => #{seed => Rng, stages => [bitflip, byteflip, havoc, splice]},
      random_seed => Rng, selection_seed => Rng, monitoring => true,
      runtime_oracles => #{enabled => false}, gleam_layer => Layer}.
