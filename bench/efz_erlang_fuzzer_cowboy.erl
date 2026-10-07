-module(efz_erlang_fuzzer_cowboy).
-export([test_one_input/1]).
-on_load(init/0).

%% The upstream fuzzer registers counters for modules loaded when this module
%% is loaded. Keep the same Cowboy allowlist as cowboy_long_bench.escript.
init() ->
    Paths = string:split(os:getenv("EFZ_COWBOY_BENCH_PATHS"), "\n", all),
    lists:foreach(fun(P) -> true = code:add_patha(P) end,
                  lists:reverse([P || P <- Paths, P =/= ""])),
    Cowboy = [cowboy_http, cowboy_req, cowboy_router, cowboy_stream],
    lists:foreach(fun(M) -> {module, M} = code:ensure_loaded(M) end,
                  Cowboy ++ [efz_cowboy_transport, efz_cowboy_stream,
                             efz_cowboy_long_target]),
    lists:foreach(fun(M) -> line_counters = code:get_coverage_mode(M) end,
                  Cowboy),
    efz_cowboy_long_target:setup().

test_one_input(Data) when is_binary(Data) ->
    {ok, _} = efz_cowboy_long_target:run(Data),
    ok.
