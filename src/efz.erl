-module(efz).
-export([start/1, stop/0, stats/0, await/1]).
start(C) ->
    {ok, _} = application:ensure_all_started(efz),
    supervisor:start_child(efz_sup, #{id => efz_fuzzer,
        start => {efz_fuzzer, start_link, [C]}, restart => temporary,
        shutdown => infinity, type => worker}).
stop() ->
    case whereis(efz_fuzzer) of undefined -> ok; _ -> efz_fuzzer:stop() end,
    application:stop(efz).
stats() -> efz_fuzzer:stats().
await(Timeout) -> efz_fuzzer:await(Timeout).
