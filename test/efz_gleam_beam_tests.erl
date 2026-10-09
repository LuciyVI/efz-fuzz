%% P2 real BEAM reachability; fault stubs are explicitly contract-only fixtures.
-module(efz_gleam_beam_tests).
-include_lib("eunit/include/eunit.hrl").

unavailable_off_test() ->
    Before = code:is_loaded(efz_qs_model),
    ?assertEqual({ok, #{}}, efz_gleam_adapter:prepare(false, #{})),
    ?assertEqual(Before, code:is_loaded(efz_qs_model)),
    case code:which(efz_qs_model) of
        non_existing -> ?assertMatch({error,{gleam_configuration,{gleam_package_unavailable,_}}},
            efz_gleam_adapter:prepare(#{structured_fraction=>0}, base()));
        _ -> ok
    end.

native_test_() ->
    case code:which(efz_qs_model) of
        non_existing -> [];
        _ -> {timeout,60,[fun exports_and_ffi/0,fun hook_trace/0,fun repeated_calls/0,
                         fun missing_callback/0,fun invalid_results/0,fun controlled_hang/0]}
    end.

base() -> #{target=>efz_qs_target,mutation_mode=>random,max_input_bytes=>4096,manifests=>[]}.
limits() -> {limits,4096,32,128,1}.
directory(Name) ->
    Dir = "_build/gleam-beam-tests/" ++ Name ++ "-" ++ integer_to_list(erlang:system_time(microsecond)),
    ok = filelib:ensure_dir(filename:join(Dir,"proof.term")), Dir.
proof(Dir,Term) -> file:write_file(filename:join(Dir,"proof.term"),term_to_binary(Term)).

exports_and_ffi() ->
    {module,efz_qs_model}=code:ensure_loaded(efz_qs_model),
    Api=[{versions,0},{decode,2},{encode,2},{normalize,1},{generate,2},{mutate,3},{observe,4},{check,2}],
    ?assertEqual([],Api--efz_qs_model:module_info(exports)),
    %% This exercises the real sole external erlang:bit_size/1 in Gleam.
    ?assertEqual({error,limit},efz_qs_model:decode(<<1:1>>,limits())),
    ?assertEqual({error,boundary},efz_gleam_adapter:decode(<<1:1>>,limits())),
    Max=max_input(), ?assertEqual(4096,byte_size(Max)),
    lists:foreach(fun(B) ->
        {ok,M}=efz_gleam_adapter:decode(B,limits()),
        {ok,Encoded}=efz_gleam_adapter:encode(M,limits()),
        ?assertEqual({ok,M},efz_gleam_adapter:decode(Encoded,limits())),
        ?assertEqual({ok,M},efz_gleam_adapter:normalize(M,limits()))
    end,[<<>>,<<"a=%00%FF">>,Max]),
    ?assertEqual({skip,limit},efz_gleam_adapter:decode(<<Max/binary,0>>,limits())),
    Dir=directory("exports"),
    ok=proof(Dir,#{schema_version=>1,exports=>Api,versions=>efz_qs_model:versions(),
        loaded_path=>code:which(efz_qs_model),max_input_bytes=>byte_size(Max),ffi=>{erlang,bit_size,1}}).
max_input() ->
    First= <<(binary:copy(<<"a">>,127))/binary,"=",(binary:copy(<<"v">>,128))/binary>>,
    Rest= <<(binary:copy(<<"a">>,126))/binary,"=",(binary:copy(<<"v">>,128))/binary>>,
    iolist_to_binary(lists:join(<<"&">>,[First|lists:duplicate(15,Rest)])).

config(Dir,Layer) -> #{target=>efz_qs_target,seeds=>[<<"a=1">>],coverage_backend=>none,
    max_iterations=>0,timeout=>1000,crash_dir=>filename:join(Dir,"crashes"),gleam_layer=>Layer}.
run(C) ->
    catch efz:stop(),
    try
        {ok,_}=efz:start(C), Controller=whereis(efz_fuzzer),
        Worker=maps:get(worker,sys:get_state(Controller)),
        R=efz:await(10000),
        ?assert(is_process_alive(Controller)),
        {R,Worker,efz_corpus:semantic_state()}
    after efz:stop() end.

hook_trace() ->
    Dir=directory("hook"), Lib=code:lib_dir(cowlib),
    code:purge(cow_qs),code:delete(cow_qs),
    {ok,A}=efz_cov_native_public:compile(filename:join([Lib,"src","cow_qs.erl"]),
        filename:join(Dir,"target"),[filename:join(Lib,"include")]),
    {module,efz_qs_model}=code:ensure_loaded(efz_qs_model),
    {module,efz_gleam_adapter}=code:ensure_loaded(efz_gleam_adapter),
    {module,efz_qs_target}=code:ensure_loaded(efz_qs_target),
    Session=trace:session_create(efz_p2_hook,self(),[]),
    try
        [trace:function(Session,MFA,true,[local]) || MFA <-
            [{efz_qs_target,run,1},{efz_cov_native_public,collect,1},
             {efz_gleam_adapter,oracle,3},
             {efz_qs_model,versions,0},{efz_qs_model,decode,2},{efz_qs_model,check,2}]],
        1=trace:function(Session,{code,ensure_loaded,1},[{[efz_qs_model],[],[]}],[local]),
        _=trace:process(Session,all,true,[call,arity]),
        C=(config(Dir,#{structured_fraction=>0,feedback=>disabled,oracle=>inline,oracle_budget=>1}))#{
            coverage_backend=>otp_native_public,artifacts=>[A]},
        {R,Worker,State}=run(C), Ref=trace:delivered(Session,all), Events=events(Ref,[]),
        Mfas=[M || {_,M}<-Events],
        ?assertEqual(1,length([M || M={efz_qs_model,decode,2}<-Mfas])),
        ?assertEqual(1,length([M || M={efz_qs_model,check,2}<-Mfas])),
        ?assertEqual(1,length([M || M={code,ensure_loaded,1}<-Mfas])),
        ?assert(lists:all(fun({Pid,{efz_qs_model,F,_}}) when F=/=versions->Pid=:=Worker;
                            (_)->true end,Events)),
        ?assert(position({efz_qs_target,run,1},Mfas)<position({efz_qs_model,decode,2},Mfas)),
        ?assert(position({efz_qs_target,run,1},Mfas)<position({efz_cov_native_public,collect,1},Mfas)),
        ?assert(position({efz_cov_native_public,collect,1},Mfas)<position({efz_gleam_adapter,oracle,3},Mfas)),
        ?assertEqual(completed,maps:get(status,R)),
        ?assertEqual(1,maps:get(oracle_passes,maps:get(gleam_stats,R))),
        ?assertEqual(disabled,State),?assertEqual(0,maps:get(oracle_extra_executions,R)),
        ?assertEqual(#{},maps:get(structured_stats,R)),
        ?assertNot(lists:keymember(efz_semantic,1,application:loaded_applications())),
        ok=file:write_file(filename:join(Dir,"trace.json"),json:encode(#{schema_version=>1,
            call_mfas=>[list_to_binary(atom_to_list(M)++":"++atom_to_list(F)++"/"++integer_to_list(Arity))
                        ||{M,F,Arity}<-Mfas],
            all_data_calls_on_existing_worker=>true,snapshot_before_callback=>true,
            model_lookup_count=>1,semantic_state_created=>false,structured_calls=>0,
            oracle_passes=>1,oracle_extra_executions=>0})),
        ok=proof(Dir,#{schema_version=>1,call_mfas=>Mfas,all_data_calls_on_efz_worker=>true,
            startup_model_lookup_count=>1,report=>R,semantic_state=>State,
            loaded_path=>code:which(efz_qs_model)})
    after trace:session_destroy(Session) end.
position(M,L) -> length(lists:takewhile(fun(X)->X=/=M end,L)).
events(Ref,Acc) -> receive
    {trace,Pid,call,MFA}->events(Ref,[{Pid,MFA}|Acc]);
    {trace_delivered,_,Ref}->lists:reverse(Acc)
after 5000->error(trace_barrier_timeout) end.

repeated_calls() ->
    _=efz_gleam_adapter:decode(<<"a=%00%FF">>,limits()), Before=lists:sort(get()),
    repeat(1000), ?assertEqual(Before,lists:sort(get())),
    Dir=directory("reuse"), C=config(Dir,#{structured_fraction=>0,feedback=>disabled,oracle=>inline,oracle_budget=>1}),
    {R1,_,disabled}=run(C), ?assertEqual(undefined,whereis(efz_corpus)),
    {R2,_,disabled}=run(C),
    ?assertEqual(maps:remove(oracle_us,maps:get(gleam_stats,R1)),
                 maps:remove(oracle_us,maps:get(gleam_stats,R2))),
    ?assertEqual(undefined,whereis(efz_execution_guardian)),
    ?assertEqual(undefined,whereis(efz_fuzzer)),
    ok=proof(Dir,#{schema_version=>1,repeated_direct_calls=>1000,process_dictionary_unchanged=>true,
        per_campaign_oracle_checks=>[maps:get(oracle_checks,maps:get(gleam_stats,R))||R<-[R1,R2]],
        semantic_states=>[disabled,disabled],registered_owners_cleaned=>true}).
repeat(0)->ok;
repeat(N)->{ok,M}=efz_gleam_adapter:decode(<<"a=%00%FF">>,limits()),
    {ok,_}=efz_gleam_adapter:encode(M,limits()),repeat(N-1).

missing_callback() ->
    with_stub([{versions,0}],erl_parse:abstract({error,unsupported}),fun() ->
        ?assertEqual({error,{gleam_configuration,{gleam_callback_unavailable,decode,2}}},
            efz_gleam_adapter:prepare(#{structured_fraction=>0},base()))
    end).

invalid_results() ->
    Api=api(), Dir=directory("failures"),
    lists:foreach(fun(Value) -> with_stub(Api,erl_parse:abstract(Value),fun() ->
        ?assertMatch({error,{semantic_layer_error,_,_}},efz_gleam_adapter:decode(<<"a=1">>,limits())),
        {R,_,disabled}=run(config(Dir,#{structured_fraction=>0,feedback=>disabled,oracle=>inline})),
        ?assertMatch({infrastructure_failure,_},maps:get(status,R)),
        ?assertEqual(1,maps:get(layer_errors,maps:get(gleam_stats,R))),
        ?assertEqual([],maps:get(crashes,R))
    end) end,[{ok,{query,[{field,"text",<<>>}],canonical}},{ok,<<0:32776>>},{error,unknown_rejection}]),
    Error={call,1,{remote,1,{atom,1,erlang},{atom,1,error}},[
        erl_parse:abstract({unbounded_diagnostic,binary:copy(<<42>>,8192)})]},
    with_stub(Api,Error,fun() ->
        ?assertEqual({error,{semantic_layer_error,error,invalid_boundary}},
            efz_gleam_adapter:decode(<<"a=1">>,limits()))
    end),
    %% A callback cannot bypass the diagnostic bound by using the layer's tag.
    TaggedError={call,1,{remote,1,{atom,1,erlang},{atom,1,error}},[
        erl_parse:abstract({semantic_layer_error,error,binary:copy(<<42>>,8192)})]},
    with_stub(Api,TaggedError,fun() ->
        ?assertEqual({error,{semantic_layer_error,error,invalid_boundary}},
            efz_gleam_adapter:decode(<<"a=1">>,limits()))
    end),
    %% A real target exception stays a finding even when the later layer fails.
    {efz_qs_target,Original,File}=code:get_object_code(efz_qs_target),
    Forms=[{attribute,1,module,efz_qs_target},{attribute,1,export,[{run,1}]},
        {function,1,run,1,[{clause,1,[{var,1,'_'}],[],[
            {call,1,{remote,1,{atom,1,erlang},{atom,1,error}},[{atom,1,p2_target_fixture_failure}]}]}]}],
    {ok,efz_qs_target,B}=compile:forms(Forms,[binary]),
    code:purge(efz_qs_target),code:delete(efz_qs_target),
    {module,efz_qs_target}=code:load_binary(efz_qs_target,"p2_target_fault_fixture",B),
    try with_stub(Api,Error,fun() ->
        {R,_,disabled}=run(config(Dir,#{structured_fraction=>0,feedback=>disabled,oracle=>inline})),
        ?assertMatch({infrastructure_failure,_},maps:get(status,R)),
        [Finding]=maps:get(crashes,R),?assert(filelib:is_file(maps:get(path,Finding)++".input")),
        ?assertEqual(1,maps:get(layer_errors,maps:get(gleam_stats,R))),
        ok=proof(Dir,#{schema_version=>1,target_finding_preserved=>true,report=>R})
    end) after
        code:purge(efz_qs_target),code:delete(efz_qs_target),
        {module,efz_qs_target}=code:load_binary(efz_qs_target,File,Original)
    end,
    {Healthy,_,disabled}=run(config(Dir,#{structured_fraction=>0,feedback=>disabled,oracle=>inline})),
    ?assertEqual(completed,maps:get(status,Healthy)).

controlled_hang() ->
    Dir=directory("hang"),
    Hang={'receive',1,[],{atom,1,infinity},[{atom,1,unreachable}]},
    with_stub(api(),Hang,fun() ->
        {Pid,Monitor}=spawn_monitor(fun()->efz_gleam_adapter:decode(<<"a=1">>,limits()) end),
        receive {'DOWN',Monitor,process,Pid,_}->error(unexpected_early_return)
        after 30 -> exit(Pid,kill) end,
        receive {'DOWN',Monitor,process,Pid,killed}->ok
        after 1000 -> error(test_worker_cleanup_timeout) end,
        ?assertNot(is_process_alive(Pid)),
        ok=proof(Dir,#{schema_version=>1,test_only_worker=>true,deadline_ms=>30,
            down=>killed,cleanup_confirmed=>true,production_worker_added=>false})
    end).
api()->[{versions,0},{decode,2},{encode,2},{normalize,1},{generate,2},{mutate,3},{observe,4},{check,2}].
with_stub(Api,Decode,Fun) ->
    {efz_qs_model,Original,File}=code:get_object_code(efz_qs_model),
    Forms=[{attribute,1,module,efz_qs_model},{attribute,1,export,Api}]++
        [{function,1,F,A,[{clause,1,lists:duplicate(A,{var,1,'_'}),[],[
            case F of versions->erl_parse:abstract({1,1,1,1,1,1});decode->Decode;
                _->{call,1,{remote,1,{atom,1,erlang},{atom,1,error}},[{atom,1,unused_p2_fault_callback}]} end]}]}
         ||{F,A}<-Api],
    {ok,efz_qs_model,B}=compile:forms(Forms,[binary]),
    code:purge(efz_qs_model),code:delete(efz_qs_model),
    {module,efz_qs_model}=code:load_binary(efz_qs_model,"p2_contract_fault_stub",B),
    try Fun() after
        code:purge(efz_qs_model),code:delete(efz_qs_model),
        {module,efz_qs_model}=code:load_binary(efz_qs_model,File,Original)
    end.
