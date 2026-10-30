%% Fresh-VM raw recipes and controlled OTP lifecycle; no vulnerability predicates.
-module(efz_semantic_portability_tests).
-include_lib("eunit/include/eunit.hrl").

directory(Name) ->
    D=filename:absname("_build/semantic-portability-tests/"++Name++"-"++
        integer_to_list(erlang:system_time(microsecond))),
    ok=filelib:ensure_dir(D++"/placeholder"),D.

fresh_vm_plugin_recipe_test_() -> {timeout,60,fun()->
    fresh_recipe(efz_plugin_length_target,efz_plugin_length_adapter,#{},<<4:16,"abcd">>,"plugin")
end}.
native_test_() -> case code:which(efz_term_model) of non_existing->[];
    _->{timeout,60,fun()->
        O=efz_term_reverse_target:options(),
        {ok,Seed}=efz_term_codec:encode([[1,2,3]],maps:get(arguments,O),#{}),
        fresh_recipe(efz_term_reverse_target,efz_term_api_adapter,O,Seed,"generic")
    end}
end.

fresh_vm_raw_execution_without_adapter_test_() -> {timeout,60,fun()->
    D=directory("raw-execution"),Core=filename:absname("_build/default/lib/efz/ebin"),
    Isolated=D++"/ebin",ok=filelib:ensure_dir(Isolated++"/placeholder"),
    %% Copy ordinary execution dependencies into an isolated code path while
    %% deliberately excluding every semantic adapter and optional model BEAM.
    lists:foreach(fun(Path)->
        Name=filename:basename(Path),
        case lists:suffix("_adapter.beam",Name) orelse lists:suffix("_model.beam",Name) of
            true->ok;
            false->{ok,_}=file:copy(Path,Isolated++"/"++Name),ok
        end
    end,filelib:wildcard(Core++"/*.beam")),
    ?assert(filelib:is_regular(Isolated++"/efz_term_codec.beam")),
    ?assert(filelib:is_regular(Isolated++"/efz_term_reverse_target.beam")),
    O=efz_term_reverse_target:options(),
    {ok,Raw}=efz_term_codec:encode([[1,2,3]],maps:get(arguments,O),#{}),
    InputPath=D++"/input.raw",ok=file:write_file(InputPath,Raw),
    Script="[InputPath]=init:get_plain_arguments(), "
        "non_existing=code:which(efz_term_api_adapter), "
        "non_existing=code:which(efz_gleam_adapter), "
        "non_existing=code:which(efz_qs_adapter), "
        "non_existing=code:which(efz_xmlrpc_adapter), "
        "non_existing=code:which(efz_term_model), "
        "{ok,Raw}=file:read_file(InputPath), "
        "{ok,Harness}=efz_replay:harness_identity(efz_term_reverse_target), "
        "{ok,Result}=efz_recipe:execute(Raw,efz_term_reverse_target,[],[], "
        "#{coverage_backend=>none,timeout=>1000,expected_harness=>Harness}), "
        "{ok,[3,2,1]}=maps:get(outcome,Result), "
        "#{status:=confirmed,survivors:=[],violations:=[]}=maps:get(cleanup,Result), "
        "false=code:is_loaded(efz_term_api_adapter), "
        "false=code:is_loaded(efz_gleam_adapter), "
        "false=code:is_loaded(efz_term_model), "
        "io:format(\"RAW_EXECUTION_OK~n\"),halt(0).",
    Exe=os:find_executable("erl"),?assert(is_list(Exe)),
    Port=open_port({spawn_executable,Exe},[binary,exit_status,use_stdio,stderr_to_stdout,
        {env,[{"ERL_FLAGS",false},{"ERL_LIBS",false}]},
        {args,["+S","2:2","-noshell","-pa",Isolated,"-eval",Script,"-extra",InputPath]}]),
    {Status,Output}=port_result(Port,<<>>),
    ok=file:write_file(D++"/fresh-vm-output.txt",Output),
    ?assertEqual({0,true},{Status,binary:match(Output,<<"RAW_EXECUTION_OK">>)=/=nomatch})
end}.

fresh_recipe(Target,Adapter,Options,Seed,Name) ->
    D=directory(Name),
    C=#{target=>Target,seeds=>[Seed],coverage_backend=>none,mutation_mode=>staged,
        mutation=>#{seed=>{17,23,41},stages=>[havoc]},max_iterations=>0,
        gleam_layer=>#{adapter=>Adapter,adapter_options=>Options,structured_fraction=>100}},
    {ok,P}=efz_config:prepare(C),MC=maps:get(mutation,P),
    {Raw,Provenance}=structured_candidate(efz_mutation_plan:new(MC),[#{id=>1,input=>Seed}],32),
    Recipe=efz_recipe:make(Provenance,Raw,MC,#{}),
    ?assertEqual(4,maps:get(schema_version,Recipe)),
    RecipePath=D++"/input.recipe",InputPath=D++"/input.raw",
    ok=efz_recipe:save(RecipePath,Recipe),ok=file:write_file(InputPath,Raw),
    %% The child has ordinary core BEAMs only. No test adapter code or optional
    %% model path is supplied, and no module is removed from the parent VM.
    Core=filename:absname("_build/default/lib/efz/ebin"),
    ?assert(filelib:is_regular(Core++"/efz_recipe.beam")),
    Script="[RecipePath,InputPath]=init:get_plain_arguments(), "
        "non_existing=code:which(efz_term_model), "
        "non_existing=code:which(efz_qs_model), "
        "non_existing=code:which(efz_plugin_length_adapter), "
        "{ok,Recipe}=efz_recipe:load(RecipePath), "
        "4=maps:get(schema_version,Recipe), "
        "{ok,Raw}=efz_recipe:regenerate(Recipe), "
        "{ok,Raw}=file:read_file(InputPath), "
        "false=code:is_loaded(efz_term_api_adapter), "
        "false=code:is_loaded(efz_term_model), "
        "false=code:is_loaded(efz_qs_model), "
        "io:format(\"RAW_RECIPE_OK~n\"),halt(0).",
    Exe=os:find_executable("erl"),?assert(is_list(Exe)),
    Port=open_port({spawn_executable,Exe},[binary,exit_status,use_stdio,stderr_to_stdout,
        {args,["+S","2:2","-noshell","-pa",Core,"-eval",Script,"-extra",RecipePath,InputPath]}]),
    {Status,Output}=port_result(Port,<<>>),
    ok=file:write_file(D++"/fresh-vm-output.txt",Output),
    ?assertEqual({0,true},{Status,binary:match(Output,<<"RAW_RECIPE_OK">>)=/=nomatch}).
structured_candidate(_,_,0) -> error(no_structured_candidate);
structured_candidate(State,Entries,Left) ->
    case efz_mutation_plan:next(State,Entries) of
        {candidate,Raw,Provenance,Next}->case maps:is_key(structured,Provenance) of
            true->{Raw,Provenance};false->structured_candidate(Next,Entries,Left-1) end;
        {skip,_,Next}->structured_candidate(Next,Entries,Left-1);
        Other->error({candidate_generation_failed,Other})
    end.
port_result(Port,Output) -> receive
    {Port,{data,Chunk}}->
        Joined= <<Output/binary,Chunk/binary>>,
        port_result(Port,binary:part(Joined,0,min(byte_size(Joined),8192)));
    {Port,{exit_status,Status}}->{Status,Output}
after 30000->port_close(Port),error(fresh_vm_recipe_timeout) end.

stateful_failure_cleanup_test_() -> {timeout,60,[
    fun()->stateful_failure_cleanup(exception) end,
    fun()->stateful_failure_cleanup(timeout) end]}.
stateful_failure_cleanup(Mode) ->
    D=directory("stateful-cleanup-"++atom_to_list(Mode)),
    {module,efz_stateful_counter}=code:ensure_loaded(efz_stateful_counter),
    {efz_stateful_counter,Original,OriginalFile}=code:get_object_code(efz_stateful_counter),
    Specs=maps:get(arguments,efz_stateful_target:options()),
    {ok,Raw}=efz_term_codec:encode([[{{'$efz_resource',counter},get,0}]],Specs,#{}),
    {ok,C}=efz_config:prepare(#{target=>efz_stateful_target,seeds=>[Raw],
        coverage_backend=>none,gleam_layer=>false,max_iterations=>0}),
    Execution=maps:with([coverage,coverage_backend,max_input_bytes,execution_identities,manifests],C),
    Before=counter_pids(),
    %% Warm the unchanged finite scenario and its controlled spawn before the
    %% 5-ms test. The execution deadline starts after guardian preparation.
    Warm=efz_executor:run(efz_stateful_target,Raw,1000,Execution),
    ?assertEqual({ok,#{trace=>[0],library_operations=>1,scenario_executions=>1}},maps:get(outcome,Warm)),
    assert_controlled_cleanup(Warm),
    try
        Binary=counter_replacement(Mode),
        _=code:purge(efz_stateful_counter),_=code:delete(efz_stateful_counter),
        {module,efz_stateful_counter}=code:load_binary(efz_stateful_counter,"cleanup-fixture",Binary),
        Timeout=case Mode of exception->1000;timeout->5 end,
        Failed=efz_executor:run(efz_stateful_target,Raw,Timeout,Execution),
        case Mode of
            exception->?assertMatch({crash,error,expected_stateful_fixture_exception,_},maps:get(outcome,Failed));
            timeout->?assertEqual({timeout,5},maps:get(outcome,Failed))
        end,
        assert_controlled_cleanup(Failed),
        ?assertEqual(Before,counter_pids()),
        ok=file:write_file(D++"/proof.term",term_to_binary(#{mode=>Mode,warm=>Warm,failure=>Failed}))
    after
        _=code:purge(efz_stateful_counter),_=code:delete(efz_stateful_counter),
        {module,efz_stateful_counter}=code:load_binary(efz_stateful_counter,OriginalFile,Original)
    end,
    Fresh=efz_executor:run(efz_stateful_target,Raw,1000,Execution),
    ?assertEqual({ok,#{trace=>[0],library_operations=>1,scenario_executions=>1}},maps:get(outcome,Fresh)),
    assert_controlled_cleanup(Fresh),?assertEqual(Before,counter_pids()).
assert_controlled_cleanup(Result) ->
    Cleanup=maps:get(cleanup,Result),
    ?assertMatch(#{status:=confirmed,survivors:=[],violations:=[]},Cleanup),
    Processes=maps:get(processes,Cleanup),
    %% The resource child was admitted, and both it and the scenario root died.
    ?assert(length(Processes)>=2),
    ?assert(lists:all(fun(Pid)->not is_process_alive(Pid) end,Processes)).
counter_replacement(Mode) ->
    {ok,Forms}=epp:parse_file("examples/stateful/efz_stateful_counter.erl",[],[]),
    Text=case Mode of
        exception->"command(_,_,_) -> erlang:error(expected_stateful_fixture_exception).";
        timeout->"command(Pid,Name,Value) -> timer:sleep(20), gen_server:call(Pid,{Name,Value},1000)."
    end,
    {ok,Tokens,_}=erl_scan:string(Text),{ok,Command}=erl_parse:parse_form(Tokens),
    Replacement=[case Form of {function,_,command,3,_}->Command;_->Form end||Form<-Forms],
    {ok,efz_stateful_counter,Binary,[]}=compile:forms(Replacement,[binary,return_errors,return_warnings]),
    Binary.

controlled_child_target_coverage_test_() ->
    {timeout,60,fun()->controlled_child_target_coverage(ets) end}.
controlled_child_native_coverage_test_() ->
    case code:coverage_support() of true->{timeout,60,
        fun()->controlled_child_target_coverage(otp_native_public) end};false->[] end.
controlled_child_target_coverage(Backend) ->
    D=directory("controlled-counter-"++atom_to_list(Backend)),
    {module,efz_stateful_counter}=code:ensure_loaded(efz_stateful_counter),
    {efz_stateful_counter,Original,OriginalFile}=code:get_object_code(efz_stateful_counter),
    Before=counter_pids(),
    try
        %% Coverage preflight must load its own prepared artifact. Leaving the
        %% ordinary target BEAM resident correctly fails identity validation.
        _=code:purge(efz_stateful_counter),_=code:delete(efz_stateful_counter),
        {ok,A}=case Backend of
            ets->efz_instrument:compile("examples/stateful/efz_stateful_counter.erl",
                #{modules=>[efz_stateful_counter],outdir=>D++"/counter"});
            otp_native_public->efz_cov_native_public:compile(
                "examples/stateful/efz_stateful_counter.erl",D++"/counter")
        end,
        Options=efz_stateful_target:options(),Specs=maps:get(arguments,Options),
        {ok,Raw}=efz_term_codec:encode([[{{'$efz_resource',counter},add,5},
            {{'$efz_resource',counter},get,0}]],Specs,#{}),
        {ok,C}=efz_config:prepare(#{target=>efz_stateful_target,seeds=>[Raw],
            coverage_backend=>Backend,artifacts=>[A],gleam_layer=>false,max_iterations=>0}),
        Execution0=maps:with([coverage,coverage_backend,coverage_feedback,max_input_bytes,
            execution_identities,manifests],C),
        Execution=case Backend of ets->Execution0;
            otp_native_public->Execution0#{coverage_schema=>efz_coverage:prepare_native(maps:get(manifests,C))} end,
        One=efz_executor:run(efz_stateful_target,Raw,1000,Execution),
        Two=efz_executor:run(efz_stateful_target,Raw,1000,Execution),
        ?assertEqual(maps:get(outcome,One),maps:get(outcome,Two)),
        ?assertEqual({ok,#{trace=>[5,5],library_operations=>2,scenario_executions=>1}},maps:get(outcome,One)),
        lists:foreach(fun(R)->
            ?assertEqual(ok,maps:get(coverage_status,R)),
            Coverage=case Backend of ets->maps:get(coverage,R);
                otp_native_public->efz_coverage:native_decode(maps:get(coverage_schema,Execution),
                    maps:get(coverage_native,R)) end,
            ?assertMatch([_|_],Coverage),
            ?assertEqual([efz_stateful_counter],lists:usort([M||{M,_,_}<-Coverage])),
            Cleanup=maps:get(cleanup,R),
            ?assertMatch(#{status:=confirmed,survivors:=[],violations:=[]},Cleanup),
            ?assert(lists:all(fun(Pid)->not is_process_alive(Pid) end,maps:get(processes,Cleanup)))
        end,[One,Two]),
        {ok,Read}=efz_term_codec:encode([[{{'$efz_resource',counter},get,0}]],Specs,#{}),
        Reset=efz_executor:run(efz_stateful_target,Read,1000,Execution),
        ?assertEqual({ok,#{trace=>[0],library_operations=>1,scenario_executions=>1}},maps:get(outcome,Reset)),
        ?assertEqual(Before,counter_pids()),
        ok=file:write_file(D++"/proof.term",term_to_binary(#{one=>One,two=>Two,fresh=>Reset}))
    after
        _=code:purge(efz_stateful_counter),_=code:delete(efz_stateful_counter),
        {module,efz_stateful_counter}=code:load_binary(efz_stateful_counter,OriginalFile,Original)
    end.
counter_pids() -> [P||P<-processes(),case process_info(P,dictionary) of
    {dictionary,Dict}->proplists:get_value('$initial_call',Dict)=:={efz_stateful_counter,init,1};
    _->false end].
