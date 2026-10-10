#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).

%% Callback microbenchmark, intentionally separate from EFZ campaign throughput.
main([]) ->
    Root = filename:dirname(filename:dirname(filename:dirname(filename:absname(escript:script_name())))),
    lists:foreach(fun(Path) -> true = code:add_patha(filename:join(Root, Path)) end,
        ["_build/gleam/lib/efz/ebin", "_build/xmlrpc-example/dependency-ebin",
         "_build/xmlrpc-example/harness-ebin"]),
    Limits = #{bytes => 4096, depth => 8, nodes => 128, collection => 16, operations => 1},
    {ok, C} = efz_xmlrpc_adapter:prepare(efz_xmlrpc_target, #{}, Limits),
    {ok, B} = efz_xmlrpc_adapter:generate(8, C),
    O = {ok, efz_xmlrpc_target:run(B)},
    {pass, {xmlrpc_model_agreement, 1}} = efz_xmlrpc_adapter:oracle(B, O, C),
    Functions = [
        {direct_primary, fun() -> {accepted, _} = efz_xmlrpc_target:run(B) end, 1},
        {generation, fun() -> {ok, _} = efz_xmlrpc_adapter:generate(8, C) end, 0},
        {mutation, fun() -> {ok, _, _} = efz_xmlrpc_adapter:mutate(B, 0, #{choice => 1}, C) end, 0},
        {observation, fun() -> {ok, _} = efz_xmlrpc_adapter:observe(B, O, C) end, 0},
        {oracle, fun() -> {pass, _} = efz_xmlrpc_adapter:oracle(B, O, C) end, 0}],
    Count = 10000,
    Measurements = [begin
        loop(100, F),
        Rows = [begin
            {Micros, ok} = timer:tc(fun() -> loop(Count, F) end),
            #{repeat => Repeat, calls => Count, elapsed_us => Micros,
              us_per_call => Micros / Count, target_executions => Count * TargetExecutions}
        end || Repeat <- lists:seq(1, 3)],
        {Name, Rows}
    end || {Name, F, TargetExecutions} <- Functions],
    Report = #{kind => xmlrpc_callback_microbenchmark, repetitions => 3,
        warmup_calls_per_callback => 100, setup_primary_executions => 1,
        otp_release => erlang:system_info(otp_release),
        erts_version => erlang:system_info(version),
        system_architecture => erlang:system_info(system_architecture),
        schedulers => erlang:system_info(schedulers_online),
        input_sha256 => crypto:hash(sha256, B), input_bytes => byte_size(B),
        dependency_commit => <<"fb46463b2acadf164ec534d9e2033e194341c507">>,
        limits => Limits, adapter_descriptor => efz_xmlrpc_adapter:descriptor(),
        code_identities => [beam_identity(M) || M <-
            [efz_xmlrpc_adapter, efz_xmlrpc_model, efz_xmlrpc_target, xmlrpc_decode, xmlrpc_util]],
        coverage => disabled,
        measurement_scope => direct_uninstrumented_calls_without_efz_execution_wrapper,
        measurements => Measurements},
    Destination = filename:join([Root, "_build", "xmlrpc-example", "callback-measurements.term"]),
    ok = file:write_file(Destination, io_lib:format("~tp.~n", [Report])),
    io:format("~tp~nSaved ~ts~n", [Report, Destination]);
main(_) -> io:format(standard_error, "Usage: examples/xmlrpc/benchmark_callbacks.escript~n", []), halt(2).
loop(0, _) -> ok;
loop(N, F) -> _ = F(), loop(N - 1, F).
beam_identity(M) ->
    {M, Beam, _} = code:get_object_code(M),
    #{module => M, sha256 => crypto:hash(sha256, Beam),
      compile_options => proplists:get_value(options, M:module_info(compile), [])}.
