-module(efz_smoke_tests).
-include_lib("eunit/include/eunit.hrl").
smoke_test() ->
    %% Explicit compatibility mode; Phase 2 automatic acceptance is separate.
    {ok, _} = efz:start(#{target => efz_example_target, seeds => [<<0>>],
                         coverage => manual, max_iterations => 10, timeout => 20}),
    try
        Report = efz:await(5000),
        ?assertEqual(10, maps:get(executions, maps:get(stats, Report)))
    after efz:stop() end.
