-module(efz_mutation_request_tests).
-include_lib("eunit/include/eunit.hrl").
-include_lib("kernel/include/file.hrl").

enabled_runtime_prerequisites_test() ->
    ?assertEqual(ok, efz_mutation_request:availability()).

success_only_after_reap_test() ->
    Before = directories(), Ports = lists:sort(erlang:ports()),
    {ok, Guardian, Ref} = fixture(self(), "success", 2000),
    {Result, Runtime} = reply(Ref),
    ?assertMatch({ok,<<1,2,0>>,#{operation:=fixture}}, Result),
    assert_reaped(Runtime),
    ?assert(maps:get(latency_us,Runtime) > maps:get(core_us,Runtime)),
    ?assert(maps:get(worker_startup_us,Runtime) > 0),
    ?assert(maps:get(request_total_us,Runtime) >= maps:get(worker_startup_us,Runtime)),
    ?assert(maps:get(parent_encode_us,Runtime) > 0),
    ?assert(maps:get(response_frame_bytes,Runtime) > 0),
    await_dead(Guardian,1000),
    await(fun() -> directories() =:= Before end,1000),
    ?assertEqual(Ports,lists:sort(erlang:ports())).

bounded_faults_test() ->
    lists:foreach(fun({Mode,Expected}) ->
        {ok,G,Ref} = fixture(self(),Mode,2000),
        {Result,Runtime} = reply(Ref),
        ?assertMatch(Expected,Result), assert_reaped(Runtime), await_dead(G,1000)
    end,[{"skip",{skip,fixture_skip}},{"error",{error,fixture_error}},
         {"crash",{error,provider_closed}},{"malformed_type",{error,invalid_provider_result}},
         {"malformed_frame",{error,invalid_provider_reply}}]).

deadline_includes_startup_test() ->
    Started = erlang:monotonic_time(millisecond),
    {ok,G,Ref} = fixture(self(),"hang",50),
    {Result,Runtime} = reply(Ref),
    ?assertEqual({timeout,deadline},Result), assert_reaped(Runtime),
    ?assert(erlang:monotonic_time(millisecond)-Started < 1000),
    await_dead(G,1000).

cancel_repeat_and_no_late_reply_test() ->
    {ok,G,Ref} = fixture(self(),"late",2000),
    _ = guardian_pids(G),
    ok = efz_mutation_request:cancel(G,Ref),
    ok = efz_mutation_request:cancel(G,Ref),
    {Result,Runtime} = reply(Ref),
    ?assertEqual(cancelled,Result), assert_reaped(Runtime),
    await_dead(G,1000),
    ok = efz_mutation_request:cancel(G,Ref),
    receive {efz_mutation_reply,Ref,_,_} -> error(late_reply) after 300 -> ok end.

owner_death_reaps_test() ->
    Before = directories(), Owner = spawn(fun() -> receive finish -> ok end end),
    {ok,G,Ref} = fixture(Owner,"hang",3000),
    Pids = guardian_pids(G), exit(Owner,kill), await_dead(G,3500),
    lists:foreach(fun assert_os_dead/1,Pids),
    await(fun() -> directories() =:= Before end,1000),
    receive {efz_mutation_reply,Ref,_,_} -> error(owner_reply) after 0 -> ok end.

guardian_kill_closes_stdin_and_reaps_test() ->
    Before = directories(),
    {ok,G,_} = fixture(self(),"hang",3000),
    Pids = guardian_pids(G), exit(G,kill), await_dead(G,1000),
    lists:foreach(fun(P) -> await(fun() -> not os_alive(P) end,3500) end,Pids),
    await(fun() -> directories() =:= Before end,1000).

unrelated_cancel_is_ignored_test() ->
    {ok,G,Ref} = fixture(self(),"success",2000),
    ok = efz_mutation_request:cancel(G,make_ref()),
    {Result,Runtime} = reply(Ref),
    ?assertMatch({ok,_,_},Result), assert_reaped(Runtime), await_dead(G,1000).

wire_rejects_before_native_decode_test() ->
    ?assertEqual({error,wire_compressed},efz_provider_wire:decode(<<131,80,0:32>>)),
    ?assertEqual({error,wire_container},efz_provider_wire:decode(<<131,116,16#ffffffff:32>>)),
    ?assertEqual({error,wire_runtime_object},efz_provider_wire:decode(term_to_binary(self()))),
    ?assertEqual({error,wire_runtime_object},efz_provider_wire:decode(term_to_binary(fun() -> ok end))),
    ?assertMatch({error,_},efz_provider_wire:decode(<<131,109,16#ffffffff:32>>)),
    ?assertMatch({error,_},efz_provider_wire:decode(<<131,97,0,0>>)),
    {ok,Bin} = efz_provider_wire:encode(#{seed=>16#ffffffffffffffff,input=><<1,2>>}),
    ?assertEqual({ok,#{seed=>16#ffffffffffffffff,input=><<1,2>>}},efz_provider_wire:decode(Bin)).

wire_preserves_bytes_without_interning_atoms_test() ->
    Input = binary:copy(list_to_binary(lists:seq(0,255)),4096),
    {ok,Frame} = efz_provider_wire:encode(#{input=>Input}),
    ?assertEqual({ok,#{input=>Input}},efz_provider_wire:decode(Frame)),
    ?assertEqual({error,wire_nonportable},
                 efz_provider_wire:encode(#{input=><<Input/binary,0>>})),
    Name = <<"efz_never_intern_",(binary:encode_hex(crypto:strong_rand_bytes(16)))/binary>>,
    ?assertException(error,badarg,binary_to_existing_atom(Name,utf8)),
    ?assertEqual({error,wire_format},
                 efz_provider_wire:decode(<<131,119,(byte_size(Name)),Name/binary>>)),
    ?assertException(error,badarg,binary_to_existing_atom(Name,utf8)).

invalid_request_does_not_launch_test() ->
    P = provider(1000),
    ?assertEqual({error,invalid_provider_timeout},efz_mutation_request:start(self(),<<>> ,#{},P#{timeout=>0})),
    ?assertEqual(ok,efz_mutation_request:cancel(self(),not_a_ref)),
    {ok,G,Ref} = efz_mutation_request:start(self(),<<>>,#{bad=>self()},P),
    {Result,Runtime} = reply(Ref),
    ?assertMatch({error,{infrastructure,provider_setup_failed}},Result),
    ?assertEqual(true,maps:get(cleanup_confirmed,Runtime)), await_dead(G,1000).

native_hang_is_killed_test_() ->
    {timeout,15,fun() ->
        Dir = native_fixture(),
        try
            {ok,G,Ref} = fixture(self(),"native_hang",1000,[Dir]),
            {Result,Runtime} = reply(Ref),
            ?assertEqual({timeout,deadline},Result), assert_reaped(Runtime), await_dead(G,1000)
        after file:del_dir_r(Dir) end
    end}.

fixture(Owner,Mode,Timeout) -> fixture(Owner,Mode,Timeout,[]).
fixture(Owner,Mode,Timeout,Paths) ->
    {module,efz_provider_fault_fixture} = code:ensure_loaded(efz_provider_fault_fixture),
    FixtureEbin = filename:dirname(code:which(efz_provider_fault_fixture)),
    Launch = fun(_Socket,_Nonce,Args) ->
        Prefix = lists:append([["-pa",P] || P <- [FixtureEbin|Paths]]),
        Prefix ++ [case A of "efz_provider_port" -> "efz_provider_fault_fixture";
                            _ -> A end || A <- Args] ++ [Mode]
    end,
    efz_mutation_request:start_test(Owner,{<<1,2>>,#{}},provider(Timeout),Launch).

provider(Timeout) -> #{timeout=>Timeout,core_context=>#{limits=>#{output_bytes=>4096}},
                      core_identity=>#{},core_path=>"/tmp"}.

reply(Ref) ->
    receive {efz_mutation_reply,Ref,Result,Runtime} -> {Result,Runtime}
    after 6000 -> error(missing_provider_reply) end.

assert_reaped(Runtime) ->
    ?assertEqual(true,maps:get(cleanup_confirmed,Runtime)),
    lists:foreach(fun assert_os_dead/1,[maps:get(os_pid,Runtime),maps:get(launcher_pid,Runtime)]).
assert_os_dead(Pid) -> ?assertNot(os_alive(Pid)).
os_alive(Pid) -> filelib:is_dir("/proc/"++integer_to_list(Pid)).

guardian_pids(G) ->
    Deadline = erlang:monotonic_time(millisecond)+1500,
    guardian_pids(G,Deadline).
guardian_pids(G,Deadline) ->
    case process_info(G,dictionary) of
        {dictionary,D} ->
            S = proplists:get_value({efz_mutation_request,state},D,#{}),
            case maps:with([os_pid,launcher_pid],S) of
                #{os_pid:=Pid,launcher_pid:=Launcher} when is_integer(Pid),is_integer(Launcher) ->
                    {os_pid,Bootstrap} = erlang:port_info(maps:get(port,S),os_pid),
                    [Pid,Launcher,Bootstrap];
                _ -> wait_pids(G,Deadline)
            end;
        _ -> error(guardian_exited_early)
    end.
wait_pids(G,Deadline) ->
    case erlang:monotonic_time(millisecond) < Deadline of
        true -> receive after 5 -> guardian_pids(G,Deadline) end;
        false -> error(no_worker_pid)
    end.

await_dead(Pid,Timeout) -> await(fun() -> not is_process_alive(Pid) end,Timeout).
await(Predicate,Timeout) -> await_until(Predicate,erlang:monotonic_time(millisecond)+Timeout).
await_until(Predicate,Deadline) ->
    case Predicate() of
        true -> ok;
        false ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> receive after 5 -> await_until(Predicate,Deadline) end;
                false -> error(cleanup_timeout)
            end
    end.
directories() -> lists:sort(filelib:wildcard("/tmp/efz-provider-????????????????????????")).

native_fixture() ->
    Root = filename:dirname(filename:dirname(proplists:get_value(source,?MODULE:module_info(compile)))),
    Dir = "/tmp/efz-provider-native-"++integer_to_list(erlang:unique_integer([positive])),
    ok = file:make_dir(Dir),
    Source = filename:join([Root,"fixtures","external","efz_native_fixture.erl"]),
    {ok,efz_native_fixture} = compile:file(Source,[{outdir,Dir},report_errors,report_warnings]),
    CC = os:find_executable("cc"), true = is_list(CC),
    Include = filename:join([code:root_dir(),"usr","include"]),
    C = filename:join([Root,"fixtures","external","efz_native_fixture.c"]),
    Port = open_port({spawn_executable,CC},[binary,exit_status,use_stdio,stderr_to_stdout,
        {args,["-O2","-fPIC","-shared","-I",Include,"-o",filename:join(Dir,"efz_native_fixture.so"),C]}]),
    compile_wait(Port), Dir.
compile_wait(Port) ->
    receive
        {Port,{data,_}} -> compile_wait(Port);
        {Port,{exit_status,0}} -> ok;
        {Port,{exit_status,_}} -> error(native_fixture_compile_failed)
    after 5000 -> catch port_close(Port),error(native_fixture_compile_timeout) end.
