-module(efz_persistent_target_tests).
-include_lib("eunit/include/eunit.hrl").

state_and_window_test_() -> {timeout,30,fun state_and_window/0}.
sequence_audit_test_() -> {timeout,60,fun sequence_audit/0}.
history_vs_stability_test_() -> {timeout,60,fun history_vs_stability/0}.
journal_identity_test_() -> {timeout,30,fun journal_identity/0}.
journal_cap_test_() -> {timeout,30,fun journal_cap/0}.
timeout_retires_epoch_test_() -> {timeout,30,fun timeout_retires_epoch/0}.
controlled_variation_test_() -> {timeout,60,fun controlled_variation/0}.
audit_live_progress_test_() -> {timeout,60,fun audit_live_progress/0}.
primary_stop_test_() -> {timeout,30,fun primary_stop/0}.
thousand_steps_one_vm_test_() -> {timeout,60,fun thousand_steps_one_vm/0}.
owner_death_cleanup_test_() -> {timeout,30,fun owner_death_cleanup/0}.
unexpected_vm_exit_test_() -> {timeout,30,fun unexpected_vm_exit/0}.
preflight_sequential_test_() -> {timeout,60,fun preflight_sequential/0}.
result_bound_test_() -> {timeout,30,fun result_bound/0}.
session_budget_test_() -> {timeout,30,fun session_budget/0}.
crash_ends_epoch_test_() -> {timeout,60,fun crash_ends_epoch/0}.
native_nif_timeout_reaps_test_() -> {timeout,30,fun native_nif_timeout_reaps/0}.
detached_os_child_reaps_test_() -> {timeout,30,fun detached_os_child_reaps/0}.
detached_child_after_native_timeout_test_() ->
    {timeout,30,fun detached_child_after_native_timeout/0}.
json_configuration_test() ->
    C=efz_control_json:campaign(#{<<"target">>=><<"efz_persistent_fixture">>,
        <<"execution">>=>#{<<"mode">>=><<"persistent_vm">>,
            <<"state_policy">>=><<"accumulate">>,
            <<"durability">>=><<"fsynced">>},
        <<"runtime_oracles">>=>#{<<"enabled">>=>true,
            <<"stability">>=>#{<<"sequence">>=>#{
                <<"policy">>=><<"deferred">>,<<"repeats">>=>20,
                <<"max_calls">>=>100}}}}),
    ?assertMatch(#{execution:=#{mode:=persistent_vm,durability:=fsynced}},C),
    ?assertMatch({ok,#{stability:=#{sequence:=#{repeats:=20}}}},
        efz_runtime_config:prepare(maps:get(runtime_oracles,C))),
    ?assertMatch({ok,_},
        efz_runtime_config:prepare(#{stability=>#{sequence=>
            #{policy=>preflight_and_deferred}}})),
    ?assertMatch({error,invalid_runtime_oracles},
        efz_runtime_config:prepare(#{stability=>#{sequence=>
            #{policy=>unknown}}})).

preflight_sequential() ->
    {_Dir,_C,C0}=prepared(),
    Runtime=#{enabled=>true,resources=>#{enabled=>false},
        hangs=>#{enabled=>false},stability=>#{sequence=>#{policy=>preflight_and_deferred,
            repeats=>2,max_calls=>4,max_elapsed_ms=>30000}}},
    try
        {ok,_}=efz:start(C0#{runtime_oracles=>Runtime,monitoring=>true}),
        Report=efz:await(30000),
        ?assertEqual(completed,maps:get(status,Report)),
        ?assertEqual(2,maps:get(vm_starts,maps:get(preflight_audit,Report))),
        ?assertEqual(2,maps:get(vm_starts,maps:get(target_audit,Report))),
        ?assertEqual(1,maps:get(vm_starts,maps:get(target_session,Report))),
        ?assertEqual(2,maps:get(step,maps:get(sequence_journal,Report))),
        ?assertEqual(8,maps:get(verification_executions,maps:get(stats,Report))),
        ?assertEqual(100.0,maps:get(percent,maps:get(feature_stability,Report)))
    after efz:stop(),unload() end.

group_context_test() ->
    {_Dir,C,_}=prepared(),
    H=efz_sequence_journal:initial_hash(),
    A=efz_sequence_audit:group_id(C,H,1,<<"x">>),
    ?assertEqual(A,efz_sequence_audit:group_id(C,H,1,<<"x">>)),
    ?assertNotEqual(A,efz_sequence_audit:group_id(C,H,2,<<"x">>)),
    ?assertNotEqual(A,efz_sequence_audit:group_id(C,
        efz_sequence_journal:next_hash(H,<<"prefix">>),1,<<"x">>)),
    ?assertNotEqual(A,efz_sequence_audit:group_id(C,H,1,<<"y">>)),
    unload().

invalid_context_test() ->
    {_Dir,_C,Base}=prepared(),
    E=maps:get(execution,Base),
    ?assertMatch({error,invalid_persistent_execution},
        efz_config:prepare(Base#{execution=>E#{target_init=>#{handle=>self()}}})),
    ?assertMatch({error,unsupported_persistent_execution_context},
        efz_config:prepare(Base#{coverage_backend=>bitmap})),
    unload().

prepared() ->
    Dir="_build/persistent-target-test-"++
        integer_to_list(erlang:unique_integer([positive])),
    unload(),
    {ok,A}=efz_instrument:compile("examples/stateful/efz_persistent_fixture.erl",
        #{modules=>[efz_persistent_fixture],source_root=>".",outdir=>Dir}),
    C0=#{target=>efz_persistent_fixture,artifacts=>[A],
        seeds=>[<<"arm">>,<<"fire">>],max_iterations=>0,
        crash_dir=>Dir++"/crashes",timeout=>3000,
        execution=>#{mode=>persistent_vm,state_policy=>accumulate}},
    {ok,C}=efz_config:prepare(C0),
    {Dir,C,C0}.

state_and_window() ->
    {_Dir,C,_}=prepared(),
    {ok,Session}=efz_target_session:open(C),
    try
        Initial=efz_target_session:info(Session),
        {ok,A}=efz_target_session:run(Session,<<"arm">>,3000),
        {ok,B}=efz_target_session:run(Session,<<"fire">>,3000),
        {ok,M}=efz_target_session:run(Session,<<"mail">>,3000),
        {ok,Q}=efz_target_session:run(Session,<<"checkmail">>,3000),
        ?assertEqual(1,maps:get(vm_starts,Initial)),
        ?assertEqual(maps:get(driver,A),maps:get(driver,Q)),
        ?assertEqual(maps:get(os_pid,A),maps:get(os_pid,Q)),
        ?assertEqual(armed_path,reply(B)),
        ?assertEqual(mail_present,reply(Q)),
        ?assertEqual([1,2,3,4],
            [maps:get(count,value(R))||R<-[A,B,M,Q]]),
        ?assertEqual([1,2,3,4],
            [maps:get(service_count,value(R))||R<-[A,B,M,Q]]),
        ?assertEqual([ok,ok,ok,ok],
            [maps:get(coverage_status,R)||R<-[A,B,M,Q]]),
        {ok,Again}=efz_target_session:run(Session,<<"fire">>,3000),
        ?assertEqual(maps:get(coverage,B),maps:get(coverage,Again)),
        ?assert(maps:get(coverage,B)=/= []),
        {ok,Helper1}=efz_target_session:run(Session,<<"helper">>,3000),
        {ok,Helper2}=efz_target_session:run(Session,<<"helper">>,3000),
        ?assertEqual(ok,maps:get(coverage_status,Helper1)),
        ?assertEqual(maps:get(coverage,Helper1),maps:get(coverage,Helper2)),
        ?assert(maps:get(coverage,Helper1)=/= []),
        ?assertEqual(7,maps:get(step,efz_target_session:info(Session)))
    after efz_target_session:close(Session),unload() end.

timeout_retires_epoch() ->
    {_Dir,C,_}=prepared(),
    {ok,Session}=efz_target_session:open(C),
    try
        {ok,_}=efz_target_session:run(Session,<<"arm">>,3000),
        {ok,R}=efz_target_session:run(Session,<<"hang">>,50),
        ?assertMatch({timeout,_},maps:get(outcome,R)),
        ?assertEqual(false,maps:get(runner_reusable,R)),
        ?assertEqual({error,epoch_retired},efz_target_session:run(Session,<<"fire">>,100))
    after efz_target_session:close(Session),unload() end.

native_nif_timeout_reaps() ->
    {_Base,C0,_}=prepared(),
    Dir=compile_native_fixture(),
    Exec=(maps:get(execution,C0))#{target_init=>#{native_nif_dir=>Dir}},
    C=C0#{execution=>Exec},
    try
        {ok,Session}=efz_target_session:open(C),
        Pid=maps:get(os_pid,efz_target_session:info(Session)),
        try
            {ok,R}=efz_target_session:run(Session,<<"native_hang">>,100),
            ?assertMatch({timeout,_},maps:get(outcome,R)),
            ?assertEqual(false,maps:get(runner_reusable,R)),
            ?assertEqual({error,epoch_retired},
                efz_target_session:run(Session,<<"fire">>,100))
        after efz_target_session:close(Session) end,
        wait_process_dead(Pid,2000)
    after file:del_dir_r(Dir),unload() end.

detached_os_child_reaps() ->
    {_Base,C,_}=prepared(),
    {ok,Session}=efz_target_session:open(C),
    Root=maps:get(os_pid,efz_target_session:info(Session)),
    try
        {ok,R}=efz_target_session:run(Session,<<"detach">>,3000),
        {detached,Child}=reply(R),
        ?assert(filelib:is_dir("/proc/"++integer_to_list(Child))),
        ?assertNotEqual(Root,Child),
        ?assertEqual(Child,process_group(Child)),
        ok=efz_target_session:close(Session),
        wait_process_dead(Root,2000),
        wait_process_dead(Child,2000)
    after efz_target_session:close(Session),unload() end.

detached_child_after_native_timeout() ->
    {_Base,C0,_}=prepared(),
    Dir=compile_native_fixture(),
    Exec=(maps:get(execution,C0))#{target_init=>#{native_nif_dir=>Dir}},
    C=C0#{execution=>Exec},
    try
        {ok,Session}=efz_target_session:open(C),
        Root=maps:get(os_pid,efz_target_session:info(Session)),
        try
            {ok,A}=efz_target_session:run(Session,<<"detach">>,3000),
            {detached,Child}=reply(A),
            ?assertEqual(Child,process_group(Child)),
            {ok,B}=efz_target_session:run(Session,<<"native_hang">>,100),
            ?assertMatch({timeout,_},maps:get(outcome,B)),
            wait_process_dead(Root,2000),
            wait_process_dead(Child,2000)
        after efz_target_session:close(Session) end
    after file:del_dir_r(Dir),unload() end.

process_group(Pid) ->
    {ok,Bin}=file:read_file("/proc/"++integer_to_list(Pid)++"/stat"),
    {At,_}=lists:last(binary:matches(Bin,<<") ">>)),
    Fields=string:tokens(binary_to_list(binary:part(Bin,At+2,
        byte_size(Bin)-At-2))," \t\n"),
    list_to_integer(lists:nth(3,Fields)).

compile_native_fixture() ->
    Dir="_build/persistent-native-"++integer_to_list(erlang:unique_integer([positive])),
    ok=file:make_dir(Dir),
    {ok,efz_native_fixture}=compile:file("fixtures/external/efz_native_fixture.erl",
        [{outdir,Dir},report_errors,report_warnings]),
    CC=os:find_executable("cc"),
    Include=filename:join([code:root_dir(),"usr","include"]),
    Port=open_port({spawn_executable,CC},[exit_status,{args,["-O2","-fPIC",
        "-shared","-I",Include,"-o",filename:join(Dir,"efz_native_fixture.so"),
        "fixtures/external/efz_native_fixture.c"]}]),
    receive {Port,{exit_status,0}}->Dir;
        {Port,{exit_status,_}}->error(native_fixture_compile_failed)
    after 5000->error(native_fixture_compile_timeout) end.

thousand_steps_one_vm() ->
    {_Dir,C,_}=prepared(),
    {ok,Session}=efz_target_session:open(C),
    Initial=efz_target_session:info(Session),
    try
        Last=lists:foldl(fun(_,_) ->
            {ok,R}=efz_target_session:run(Session,<<"noop">>,3000),R
        end,undefined,lists:seq(1,1000)),
        End=efz_target_session:info(Session),
        ?assertEqual(1,maps:get(vm_starts,End)),
        ?assertEqual(maps:get(os_pid,Initial),maps:get(os_pid,End)),
        ?assertEqual(maps:get(driver,Initial),maps:get(driver,End)),
        ?assertEqual(1000,maps:get(step,End)),
        ?assertEqual(1000,maps:get(count,value(Last))),
        ?assertEqual(0,maps:get(driver_mailbox,End)),
        ?assert(maps:get(ets_tables,End)=<maps:get(ets_tables,Initial)+1),
        ?assert(maps:get(processes,End)=<maps:get(processes,Initial)+2)
    after efz_target_session:close(Session),unload() end,
    Pid=maps:get(os_pid,Initial),
    wait_process_dead(Pid,2000).

wait_process_dead(_,Remaining) when Remaining=<0->error(target_vm_not_reaped);
wait_process_dead(Pid,Remaining)->
    case filelib:is_dir("/proc/"++integer_to_list(Pid)) of
        false->ok;
        true->receive after 20->wait_process_dead(Pid,Remaining-20) end
    end.

owner_death_cleanup() ->
    {_Dir,C,_}=prepared(),
    Parent=self(),
    Owner=spawn(fun()->
        {ok,Session}=efz_target_session:open(C),
        Info=efz_target_session:info(Session),
        Parent!{owned_session,Session,maps:get(os_pid,Info)},
        receive after infinity->ok end
    end),
    {Session,Pid}=receive {owned_session,S,P}->{S,P}
        after 5000->error(session_not_started) end,
    Monitor=erlang:monitor(process,Session),
    exit(Owner,kill),
    receive {'DOWN',Monitor,process,Session,_}->ok
        after 5000->error(session_owner_cleanup_timeout) end,
    wait_process_dead(Pid,2000),
    unload().

unexpected_vm_exit() ->
    {_Dir,C,_}=prepared(),
    {ok,Session}=efz_target_session:open(C),
    try
        Pid=maps:get(os_pid,efz_target_session:info(Session)),
        Kill=os:find_executable("kill"),
        Port=open_port({spawn_executable,Kill},[exit_status,
            {args,["-KILL",integer_to_list(Pid)]}]),
        receive {Port,{exit_status,0}}->ok
        after 2000->error(kill_command_timeout) end,
        wait_process_dead(Pid,2000),
        Result=efz_target_session:run(Session,<<"fire">>,100),
        ?assertMatch({error,_},Result),
        ?assertEqual(down,maps:get(status,efz_target_session:info(Session)))
    after efz_target_session:close(Session),unload() end.

result_bound() ->
    {_Dir,C0,_}=prepared(),
    C=C0#{execution=>(maps:get(execution,C0))#{max_result_bytes=>1024}},
    {ok,Session}=efz_target_session:open(C),
    try
        {ok,R}=efz_target_session:run(Session,<<"large">>,3000),
        ?assertEqual({infrastructure,target_result_limit},maps:get(outcome,R)),
        ?assertEqual(false,maps:get(runner_reusable,R)),
        ?assertEqual({error,epoch_retired},
            efz_target_session:run(Session,<<"fire">>,100))
    after efz_target_session:close(Session),unload() end.

session_budget() ->
    {_Dir,C0,Raw}=prepared(),
    E=(maps:get(execution,C0))#{max_processes=>1},
    C=C0#{execution=>E},
    {ok,Session}=efz_target_session:open(C),
    try
        {ok,R}=efz_target_session:run(Session,<<"arm">>,3000),
        ?assertEqual({ok,armed},case maps:get(outcome,R) of
            {ok,V}->{ok,maps:get(reply,V)};Other->Other end),
        ?assertEqual(max_processes,maps:get(epoch_limit_reason,R)),
        ?assertEqual(false,maps:get(runner_reusable,R)),
        ?assertEqual({error,epoch_retired},
            efz_target_session:run(Session,<<"fire">>,100))
    after efz_target_session:close(Session),unload() end,
    ?assertMatch({error,invalid_persistent_execution},
        efz_config:prepare(Raw#{execution=>E#{max_epoch_ms=>0}})).

crash_ends_epoch() ->
    {_Dir,_C,C0}=prepared(),
    Runtime=#{enabled=>false},
    Config=C0#{seeds=>[<<"arm">>,<<"boom">>,<<"fire">>],
        runtime_oracles=>Runtime},
    try
        {ok,_}=efz:start(Config),Report=efz:await(15000),
        ?assertEqual(target_epoch_terminated,maps:get(status,Report)),
        ?assertMatch({crash,error,synthetic_target_crash,_},
            maps:get(epoch_end_outcome,Report)),
        Journal=maps:get(sequence_journal,Report),
        ?assertEqual(true,maps:get(complete,Journal)),
        ?assertEqual(2,maps:get(step,Journal)),
        {ok,[<<"arm">>,<<"boom">>]}=efz_sequence_journal:steps(
            maps:get(path,Journal),prepared_config(Config))
    after efz:stop(),unload() end.

sequence_audit() ->
    {_Dir,_C,C0}=prepared(),
    Runtime=#{enabled=>true,resources=>#{enabled=>false},
        hangs=>#{enabled=>false},stability=>#{sequence=>#{policy=>deferred,
            repeats=>3,max_calls=>6,max_elapsed_ms=>30000}}},
    try
        {ok,_}=efz:start(C0#{runtime_oracles=>Runtime,monitoring=>true}),
        R=efz:await(30000),
        ?assertEqual(completed,maps:get(status,R)),
        J=maps:get(sequence_journal,R),
        ?assertEqual(true,maps:get(complete,J)),
        ?assertEqual(2,maps:get(step,J)),
        F=maps:get(feature_stability,R),
        ?assertEqual(audited_sequence_steps,maps:get(scope,F)),
        ?assertEqual(100.0,maps:get(percent,F)),
        ?assertEqual(2,maps:get(groups_measured,F)),
        Audit=maps:get(target_audit,R),
        ?assertEqual(3,maps:get(vm_starts,Audit)),
        ?assertEqual(6,maps:get(calls,Audit)),
        ?assertEqual(6,maps:get(verification_executions,maps:get(stats,R))),
        {ok,[First,Second]}=efz_sequence_journal:steps(maps:get(path,J),
            prepared_config(C0#{runtime_oracles=>Runtime})),
        ?assertEqual([<<"arm">>,<<"fire">>],[First,Second]),
        {ok,[Step1,Step2]}=efz_sequence_audit:replay(maps:get(path,J),
            prepared_config(C0#{runtime_oracles=>Runtime}),2),
        ?assertEqual(armed_path,reply(Step2)),
        ?assertEqual(maps:get(os_pid,Step1),maps:get(os_pid,Step2)),
        Summary=efz_control:report_summary(R,"_build/persistent-target-summary"),
        ?assertEqual(100.0,maps:get(<<"percent">>,
            maps:get(<<"feature_stability">>,Summary)))
    after efz:stop(),unload() end.

history_vs_stability() ->
    {_Dir,_C,C0}=prepared(),
    Runtime=#{enabled=>true,resources=>#{enabled=>false},
        hangs=>#{enabled=>false},stability=>#{sequence=>#{policy=>deferred,
            repeats=>2,max_calls=>6,max_elapsed_ms=>30000}}},
    Inputs=[<<"fire">>,<<"arm">>,<<"fire">>],
    try
        {ok,_}=efz:start(C0#{benchmark_replay_inputs=>Inputs,
            runtime_oracles=>Runtime}),
        R=efz:await(30000),
        ?assertEqual(completed,maps:get(status,R)),
        ?assertEqual(Inputs,begin
            {ok,B}=efz_sequence_journal:steps(
                maps:get(path,maps:get(sequence_journal,R)),prepared_config(
                    C0#{benchmark_replay_inputs=>Inputs,runtime_oracles=>Runtime})),B
        end),
        ?assertEqual(1,maps:get(changed,maps:get(history_sensitivity,R))),
        F=maps:get(feature_stability,R),
        ?assertEqual(3,maps:get(groups_measured,F)),
        ?assertEqual(100.0,maps:get(percent,F))
    after efz:stop(),unload() end.

controlled_variation() ->
    {Dir,_C,C0}=prepared(),
    Variation=filename:join(Dir,"variation-counter"),
    ok=file:write_file(Variation,<<"0">>),
    Exec=(maps:get(execution,C0))#{target_init=>#{variation_file=>Variation}},
    Runtime=#{enabled=>true,resources=>#{enabled=>false},
        hangs=>#{enabled=>false},stability=>#{sequence=>#{policy=>deferred,
            repeats=>3,max_calls=>6,max_elapsed_ms=>30000}}},
    try
        {ok,_}=efz:start(C0#{seeds=>[<<"arm">>,<<"variable">>],
            execution=>Exec,runtime_oracles=>Runtime}),
        R=efz:await(30000),F=maps:get(feature_stability,R),
        ?assertEqual(measured,maps:get(status,F)),
        ?assert(maps:get(percent,F)<100.0),
        ?assert(maps:get(variable_feature_pairs,F)>0),
        ?assert(maps:get(variable_examples,F)=/=[]),
        ?assert(lists:all(fun(#{observed_runs:=Seen,valid_runs:=Valid})->
            Seen>0 andalso Seen<Valid end,maps:get(variable_examples,F))),
        ?assertEqual(2,maps:get(groups_measured,F)),
        ?assertEqual(3,maps:get(completed_repetitions,maps:get(target_audit,R)))
    after efz:stop(),unload() end.

audit_live_progress() ->
    {Dir,_C,C0}=prepared(),
    Variation=filename:join(Dir,"live-counter"),
    Ready=filename:join(Dir,"pause-ready"),
    Release=filename:join(Dir,"pause-release"),
    ok=file:write_file(Variation,<<"0">>),
    Exec=(maps:get(execution,C0))#{target_init=>#{variation_file=>Variation,
        pause_after=>[3,4],pause_ready=>Ready,pause_release=>Release}},
    Runtime=#{enabled=>true,resources=>#{enabled=>false},
        hangs=>#{enabled=>false},stability=>#{sequence=>#{policy=>deferred,
            repeats=>20,max_calls=>20,max_elapsed_ms=>30000}}},
    try
        {ok,_}=efz:start(C0#{seeds=>[<<"variable">>],execution=>Exec,
            runtime_oracles=>Runtime,monitoring=>true,timeout=>7000}),
        wait_file(Ready++".3",10000),
        Before=await_valid(2,3000),
        ?assertEqual(100.0,maps:get(percent,Before)),
        ?assertEqual(audit,maps:get(target_phase,efz_fuzzer:monitor_snapshot())),
        ok=file:write_file(Release++".3",<<>>),
        wait_file(Ready++".4",10000),
        After=await_valid(3,3000),
        ?assert(maps:get(percent,After)<100.0),
        ?assertEqual(running,efz_fuzzer:status()),
        ok=efz:request_stop(),
        ok=file:write_file(Release++".4",<<>>),
        Report=efz:await(15000),
        ?assertEqual(stopped_by_user,maps:get(status,Report)),
        Final=maps:get(feature_stability,Report),
        ?assertEqual(stopped,maps:get(collection_status,Final)),
        ?assert(maps:get(percent,Final)<100.0),
        ?assertEqual(stopped,maps:get(status,maps:get(target_audit,Report)))
    after
        _=file:write_file(Release++".3",<<>>),
        _=file:write_file(Release++".4",<<>>),
        efz:stop(),unload()
    end.

primary_stop() ->
    {Dir,_C,C0}=prepared(),
    Variation=filename:join(Dir,"primary-stop-counter"),
    Ready=filename:join(Dir,"primary-stop-ready"),
    Release=filename:join(Dir,"primary-stop-release"),
    ok=file:write_file(Variation,<<"0">>),
    Exec=(maps:get(execution,C0))#{target_init=>#{variation_file=>Variation,
        pause_after=>0,pause_ready=>Ready,pause_release=>Release}},
    Runtime=#{enabled=>true,resources=>#{enabled=>false},hangs=>#{enabled=>false},
        stability=>#{sequence=>#{policy=>deferred,repeats=>2,max_calls=>8}}},
    try
        {ok,_}=efz:start(C0#{seeds=>[<<"variable">>,<<"fire">>],
            max_iterations=>infinity,execution=>Exec,runtime_oracles=>Runtime,
            timeout=>7000,monitoring=>true}),
        wait_file(Ready,10000),
        ok=efz:request_stop(),
        ok=file:write_file(Release,<<>>),
        Report=efz:await(15000),
        ?assertEqual(stopped_by_user,maps:get(status,Report)),
        ?assertEqual(1,maps:get(step,maps:get(sequence_journal,Report))),
        ?assertEqual(true,maps:get(complete,maps:get(sequence_journal,Report))),
        ?assertEqual(not_measured,maps:get(status,maps:get(target_audit,Report))),
        ?assertEqual(down,maps:get(status,maps:get(target_session,Report)))
    after _=file:write_file(Release,<<>>),efz:stop(),unload() end.

wait_file(_,Remaining) when Remaining=<0 -> error(pause_not_reached);
wait_file(Path,Remaining) ->
    case filelib:is_regular(Path) of
        true->ok;
        false->receive after 20->wait_file(Path,Remaining-20) end
    end.
await_valid(_,Remaining) when Remaining=<0 -> error(audit_progress_missing);
await_valid(N,Remaining) ->
    F=maps:get(feature_stability,efz_fuzzer:monitor_snapshot()),
    Current=maps:get(current,F,null),
    case Current of
        #{valid_runs:=Count} when Count>=N->F;
        _->receive after 20->await_valid(N,Remaining-20) end
    end.

journal_identity() ->
    {_Dir,C,_}=prepared(),
    {ok,J0}=efz_sequence_journal:open(C),
    {ok,J1}=efz_sequence_journal:dispatch(J0,<<"ab">>,#{phase=>calibration}),
    {ok,J2}=efz_sequence_journal:dispatch(J1,<<"c">>,#{phase=>calibration}),
    J=efz_sequence_journal:close(J2,completed),
    ?assertMatch({ok,[<<"ab">>,<<"c">>]},
        efz_sequence_journal:steps(maps:get(path,J),C)),
    ?assertNotEqual(efz_sequence_journal:next_hash(
        efz_sequence_journal:next_hash(efz_sequence_journal:initial_hash(),<<"ab">>),<<"c">>)
        ,efz_sequence_journal:next_hash(
        efz_sequence_journal:next_hash(efz_sequence_journal:initial_hash(),<<"a">>),<<"bc">>)),
    Other=C#{execution=>(maps:get(execution,C))#{target_init=>#{different=>true}}},
    ?assertMatch({error,sequence_identity_mismatch},
        efz_sequence_journal:steps(maps:get(path,J),Other)),
    unload().

journal_cap() ->
    {_Dir,C,_}=prepared(),
    Limited=C#{execution=>(maps:get(execution,C))#{max_journal_bytes=>4096}},
    {ok,J0}=efz_sequence_journal:open(Limited),
    Input=binary:copy(<<"j">>,384),
    {J1,N}=fill_journal(J0,Input,0),
    ?assert(N>0),
    Done=efz_sequence_journal:close(J1,journal_limit),
    ?assertEqual(true,maps:get(complete,Done)),
    {ok,Steps}=efz_sequence_journal:steps(maps:get(path,Done),Limited),
    ?assertEqual(N,length(Steps)),
    unload().

fill_journal(J,Input,N) ->
    case efz_sequence_journal:dispatch(J,Input,#{phase=>mutation}) of
        {ok,Next}->fill_journal(Next,Input,N+1);
        {error,journal_limit}->{J,N}
    end.

prepared_config(C) -> {ok,Ready}=efz_config:prepare(C),Ready.
value(R) -> {ok,V}=maps:get(outcome,R),V.
reply(R) -> maps:get(reply,value(R)).
unload() -> code:purge(efz_persistent_fixture),code:delete(efz_persistent_fixture).
