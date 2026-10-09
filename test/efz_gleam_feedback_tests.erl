-module(efz_gleam_feedback_tests).
-include_lib("eunit/include/eunit.hrl").

metadata_boundaries_test()->
    ?assertError(invalid_semantic_metadata,efz_semantic:metadata(lists:duplicate(13,{<<"cow_qs">>,1,0}))),
    M=efz_semantic:metadata([{<<"cow_qs">>,1,0}]),
    ?assertError(invalid_semantic_metadata,efz_semantic:features(#{semantic=>M#{extra=>true}})),
    ?assertError(incompatible_semantic_schema,efz_semantic:features(#{semantic=>M#{feature_version=>2}})).
native_test_()->case code:which(efz_qs_model) of
    non_existing->[];
    _->{timeout,120,[fun same_coverage/0,fun deterministic_observation/0,fun concurrency/0,
        fun consistency/0,fun restart_prune/0,fun oracle_finding/0,fun oracle_budget/0,
        fun coverage_intervals/0,fun native_barriers/0,fun bounded_state/0]}
end.
limits()->{limits,4096,32,128,1}.
directory(Name)->Dir="_build/gleam-feedback-tests/"++Name++"-"++integer_to_list(erlang:system_time(microsecond)),
    ok=filelib:ensure_dir(Dir++"/placeholder"),Dir.
setup(Name)->
    catch efz:stop(),code:purge(cow_qs),code:delete(cow_qs),Dir=directory(Name),
    {ok,A}=efz_cov_native_public:compile("_build/default/lib/cowlib/src/cow_qs.erl",Dir++"/target",
        ["_build/default/lib/cowlib/include"]),{Dir,A}.
config(Dir,A,Feedback)->#{target=>efz_qs_target,seeds=>[<<"a=1">>],artifacts=>[A],
    coverage_backend=>otp_native_public,mutation_mode=>random,mutator=>efz_gleam_feedback_mutator,
    selection_seed=>{17,23,41},random_seed=>{17,23,41},max_iterations=>8,timeout=>1000,
    crash_dir=>Dir++"/crashes",gleam_layer=>#{structured_fraction=>0,feedback=>Feedback}}.
campaign(C)->try {ok,_}=efz:start(C),R=efz:await(30000),
    {R,efz_corpus:semantic_state(),efz_corpus:semantic_representatives()}
    after efz:stop() end.
proof(Dir,Value)->ok=file:write_file(Dir++"/proof.term",term_to_binary(Value)).

same_coverage()->
    {Dir,A}=setup("same-coverage"),Base=config(Dir,A,guided),B= <<"a=",255>>,
    {R1,_,_}=campaign(Base#{max_iterations=>0,gleam_layer=>false}),
    {R2,_,_}=campaign(Base#{max_iterations=>0,seeds=>[B],gleam_layer=>false}),
    ?assertEqual(maps:get(coverage,R1),maps:get(coverage,R2)),
    ?assertMatch([_|_],maps:get(coverage,R1)),
    {ok,F1}=efz_gleam_adapter:observe(<<"a=1">>,{ok,efz_qs_target:run(<<"a=1">>)},limits()),
    {ok,F2}=efz_gleam_adapter:observe(B,{ok,efz_qs_target:run(B)},limits()),?assertNotEqual(F1,F2),
    [begin {module,M}=code:ensure_loaded(M) end||M<-[efz_worker,efz_feedback,efz_gleam_adapter,efz_qs_model,efz_gleam_feedback_mutator]],
    Session=trace:session_create(p4_admission,self(),[]),
    try
        trace:function(Session,{efz_worker,execute_allowed,4},true,[local]),
        trace:function(Session,{efz_feedback,evaluate,3},true,[local]),
        trace:function(Session,{efz_qs_model,decode,2},true,[local]),
        trace:function(Session,{efz_qs_model,observe,4},true,[local]),
        trace:process(Session,all,true,[call]),
        {On,Seen,{ok,Reps}}=campaign(Base#{corpus_dir=>Dir++"/store"}),
        Ref=trace:delivered(Session,all),Events=events(Ref,[]),trace:process(Session,all,false,[call]),
        Parents=[maps:get(id,Parent)||{efz_worker,execute_allowed,[_,Parent,mutation,_]}<-Events],
        ?assert(lists:member(2,Parents)),
        Snapshots=[efz_coverage:native_decode(Schema,maps:get(coverage_native,Result))
            ||{efz_feedback,evaluate,[#{native_schema:=Schema},Result,_]}<-Events],
        Bits=[maps:get(coverage_native,Result)||{efz_feedback,evaluate,[_,Result,_]}<-Events],
        ?assertEqual(9,length(Snapshots)),?assert(lists:all(fun(S)->S=:=hd(Snapshots) end,Snapshots)),
        ?assertEqual(maps:get(coverage,R1),hd(Snapshots)),?assertMatch([_|_],hd(Snapshots)),
        ?assertEqual(1,length(lists:usort(Bits))),?assert(byte_size(hd(Bits))>0),
        ?assertEqual([], [F||{efz_qs_model,decode,_}=F<-Events]),
        ?assertEqual(9,length([F||{efz_qs_model,observe,_}=F<-Events])),
        [Initial,Semantic]=maps:get(corpus,On),?assertEqual(B,maps:get(input,Semantic)),
        SM=maps:get(metadata,Semantic),?assertEqual(new_semantic,maps:get(retention_reason,SM)),
        ?assertEqual([],maps:get(new_probes,SM)),
        ?assertEqual(F2,efz_semantic:features(SM)),
        ?assertEqual(lists:usort(F1++F2),Seen),?assertEqual(2,maps:get({<<"cow_qs">>,1,10},Reps)),
        ?assertEqual(1,maps:get(discoveries,maps:get(stats,On))),
        {Off,disabled,disabled}=campaign(Base#{gleam_layer=>false}),
        {Observation,disabled,disabled}=campaign(Base#{gleam_layer=>#{structured_fraction=>0,feedback=>observation_only}}),
        ?assertEqual([maps:get(input,Initial)],[maps:get(input,E)||E<-maps:get(corpus,Off)]),
        ?assertEqual([maps:get(input,Initial)],[maps:get(input,E)||E<-maps:get(corpus,Observation)]),
        ?assertEqual(maps:get(coverage,Off),maps:get(coverage,On)),
        ?assertEqual(maps:remove(started_at,maps:get(stats,Off)),
            maps:remove(started_at,maps:get(stats,Observation))),
        proof(Dir,#{inputs=>[<<"a=1">>,B],snapshots=>Snapshots,native_bits=>Bits,features=>[F1,F2],
            guided=>On,off=>Off,observation=>Observation,parent_ids=>Parents,
            seen=>Seen,representatives=>Reps,observation_decode_calls=>0})
    after trace:session_destroy(Session) end.
events(Ref,Acc)->receive
    {trace,_,call,{M,F,Args}}->events(Ref,[{M,F,Args}|Acc]);
    {trace_delivered,_,Ref}->lists:reverse(Acc)
    after 5000->error(trace_barrier_timeout) end.

deterministic_observation()->
    Actual={ok,efz_qs_target:run(<<"a=",255>>)},
    {ok,Expected}=efz_gleam_adapter:observe(<<"a=",255>>,Actual,limits()),
    lists:foreach(fun(_)->?assertEqual({ok,Expected},efz_gleam_adapter:observe(<<"a=",255>>,Actual,limits())),
        ?assertEqual({ok,[{<<"cow_qs">>,1,1}]},efz_gleam_adapter:observe(<<"a=%">>,{ok,rejected},limits())) end,lists:seq(1,10000)),
    ?assertEqual({skip,limit},efz_gleam_adapter:observe(<<0:32776>>,Actual,limits())),
    ?assertMatch({error,{semantic_layer_error,_,_}},efz_gleam_adapter:observe(<<>>, {ok,{accepted,[bad|improper]}},limits())),
    ?assertMatch({error,{semantic_layer_error,_,_}},efz_gleam_adapter:observe(<<>>, {ok,{accepted,lists:duplicate(101,{<<"a">>,<<>>})}},limits())),
    ?assertEqual({inconclusive,unsupported},efz_gleam_adapter:oracle(<<"a=%">>,{ok,rejected},limits())),
    ?assertEqual({inconclusive,target_timeout},efz_gleam_adapter:oracle(<<"a=1">>,{timeout,100},limits())),
    ?assertEqual({inconclusive,target_exception},efz_gleam_adapter:oracle(<<"a=1">>,{crash,error,any_reason,[]},limits())).

concurrency()->
    {ok,Pid}=efz_corpus:start_link([<<"a=1">>],{17,23,41},undefined,4096,#{feedback=>guided}),
    try
        Fs=[{<<"cow_qs">>,1,10}],M=#{parent=>1,phase=>mutation,new_probes=>[],retention_reason=>equivalent_coverage},
        Self=self(),Workers=[spawn_monitor(fun()->receive go->Self!{answer,efz_corpus:admit_semantic(B,M,Fs,false)} end end)
            ||B<-[<<"a=",255>>,<<"b=",255>>]],
        [W!go||{W,_}<-Workers],Answers=[receive {answer,Reply}->Reply after 3000->error(admission_timeout) end||_<-Workers],
        [receive {'DOWN',Mon,process,_,normal}->ok after 3000->error(caller_cleanup_timeout) end||{_,Mon}<-Workers],
        ?assertEqual(1,length([ok||{ok,_,_}<-Answers])),?assertEqual(1,length([ok||{rejected,_}<-Answers])),
        ?assertEqual(2,efz_corpus:size()),?assertEqual(Fs,efz_corpus:semantic_state()),
        ?assertMatch({ok,#{ {<<"cow_qs">>,1,10}:=2}},efz_corpus:semantic_representatives()),
        proof(directory("concurrency"),#{answers=>Answers,seen=>Fs,corpus=>efz_corpus:all()})
    after gen_server:stop(Pid) end.
consistency()->
    {Dir,A}=setup("consistency"),{ok,C}=efz_config:prepare((config(Dir,A,guided))#{max_iterations=>0}),
    Store=#{dir=>Dir++"/store",identity=>efz_corpus_store:identity(C)},
    {ok,Pid}=efz_corpus:start_link([<<"a=1">>],{1,2,3},Store,4096,#{feedback=>guided}),
    try
        Fs=[{<<"cow_qs">>,1,10}],M=#{parent=>1,phase=>mutation,new_probes=>[],retention_reason=>equivalent_coverage},
        Path=maps:get(dir,Store),ok=file:rename(Path,Path++"-preserved"),ok=file:write_file(Path,<<"blocked write">>),
        ?assertMatch({error,_},efz_corpus:admit_semantic(<<"a=",255>>,M,Fs,false)),
        ?assertEqual([],efz_corpus:semantic_state()),?assertEqual({ok,#{}},efz_corpus:semantic_representatives()),
        ok=file:delete(Path),ok=file:rename(Path++"-preserved",Path),
        ?assertMatch({ok,2,_},efz_corpus:admit_semantic(<<"a=",255>>,M,Fs,false)),
        lists:foreach(fun(_)->?assertMatch({existing,2,_},efz_corpus:admit_semantic(<<"a=",255>>,M,Fs,false)) end,lists:seq(1,1000)),
        ?assertEqual(Fs,efz_corpus:semantic_state()),
        {ok,Reps}=efz_corpus:semantic_representatives(),?assertEqual(1,map_size(Reps)),
        proof(Dir,#{write_failed_seen_unchanged=>true,retry_credited=>true,repeats=>1000,
            seen=>Fs,representatives=>Reps,seen_bytes=>erts_debug:flat_size(Fs)*erlang:system_info(wordsize)})
    after gen_server:stop(Pid) end.

restart_prune()->
    {Dir,A}=setup("restart-prune"),C=(config(Dir,A,guided))#{corpus_dir=>Dir++"/store"},
    {R,Seen,_}=campaign(C),
    {Restored,Seen,{ok,Reps}}=campaign(C#{seeds=>[],max_iterations=>0}),
    ?assertEqual(2,maps:get(calibrations,maps:get(stats,Restored))),
    ?assertEqual(0,maps:get(executions,maps:get(stats,Restored))),
    {Kept,Ps,Features}=efz_semantic:cover(maps:get(corpus,R)),?assertEqual(Seen,Features),
    ?assertEqual(2,length(Kept)),?assertEqual(Seen,lists:sort(maps:keys(Reps))),
    ?assert(lists:all(fun(E)->maps:get(id,E)=:=1 orelse maps:get(retention_reason,maps:get(metadata,E))=:=new_semantic end,Kept)),
    %% Copy the conservative subset to a new store; never delete source entries.
    New=Dir++"/reduced",ok=file:make_dir(New),
    [copy_entry(Dir++"/store",New,maps:get(input,E))||E<-Kept],
    {Reduced,Seen,_}=campaign(C#{corpus_dir=>New,seeds=>[],max_iterations=>0}),
    ?assertEqual(maps:get(coverage,R),maps:get(coverage,Reduced)),
    %% A manual deletion between campaigns has no persisted seen index: rebuild
    %% credits the remaining actual representatives, and the lost feature can recur.
    B= <<"a=",255>>,Removed=filename:join(New,hex(B)),ok=file:rename(Removed,Dir++"/removed-preserved"),
    {Manual,ManualSeen,_}=campaign(C#{corpus_dir=>New,seeds=>[],max_iterations=>0}),
    ?assertEqual(1,length(maps:get(corpus,Manual))),?assertNot(lists:member({<<"cow_qs">>,1,10},ManualSeen)),
    {Retry,Seen,_}=campaign(C#{corpus_dir=>New,seeds=>[],max_iterations=>8}),?assertEqual(2,length(maps:get(corpus,Retry))),
    %% Check a checksummed incompatible schema under the actual restore path.
    MetaPath=filename:join([New,hex(B),"metadata"]),{ok,Original}=file:read_file(MetaPath),
    <<"EFZC",1,N:32,_:32/binary,Payload:N/binary>>=Original,Record=binary_to_term(Payload,[safe]),
    Discovery=maps:get(discovery,Record),Semantic=maps:get(semantic,Discovery),
    Bad=Record#{discovery=>Discovery#{semantic=>Semantic#{feature_version=>2}}},P=term_to_binary(Bad),
    ok=file:write_file(MetaPath,<<"EFZC",1,(byte_size(P)):32,(crypto:hash(sha256,P))/binary,P/binary>>),
    try ?assertMatch({error,_},efz_config:prepare(C#{corpus_dir=>New,seeds=>[],max_iterations=>0}))
    after ok=file:write_file(MetaPath,Original) end,
    proof(Dir,#{report=>R,restored=>Restored,reduced=>Reduced,manual=>Manual,retry=>Retry,
        preserved_probes=>Ps,seen=>Seen,representatives=>Reps,schema_mismatch_rejected=>true}).
copy_entry(From,To,B)->Name=hex(B),Dest=filename:join(To,Name),ok=file:make_dir(Dest),
    [begin {ok,_}=file:copy(filename:join([From,Name,F]),filename:join(Dest,F)) end||F<-["input","metadata"]],ok.
hex(B)->binary_to_list(binary:encode_hex(crypto:hash(sha256,B),lowercase)).

oracle_finding()->
    {Dir,A}=setup("oracle-finding"),Input= <<"bug=11&x=2">>,
    C=(config(Dir,A,guided))#{target=>efz_qs_defect_target,seeds=>[Input],max_iterations=>2,
        gleam_layer=>#{structured_fraction=>0,feedback=>guided,oracle=>inline}},
    {R,_,_}=campaign(C),?assertEqual(3,maps:get(oracle_failures,maps:get(gleam_stats,R))),
    ?assertEqual(2,maps:get(executions,maps:get(stats,R))),
    ?assertEqual(0,maps:get(discoveries,maps:get(stats,R))),
    ?assertEqual(1,length(maps:get(corpus,R))),[Finding]=maps:get(crashes,R),Path=maps:get(path,Finding),
    ?assertEqual({ok,Input},file:read_file(Path++".input")),{ok,E}=efz_semantic_replay:load(Path++".semantic"),
    ?assertEqual({query_model_agreement,1},maps:get(property,E)),
    {ok,Replayed}=efz_semantic_replay:run(Input,efz_qs_defect_target,[A],E,
        #{timeout=>1000,coverage_backend=>otp_native_public,max_input_bytes=>4096}),
    ?assertEqual(reproduced,maps:get(status,Replayed)),?assertEqual(1,maps:get(target_executions,Replayed)),
    {ok,Min}=efz_semantic_replay:minimize(Input,efz_qs_defect_target,[A],E,
        #{timeout=>1000,coverage_backend=>otp_native_public,max_input_bytes=>4096},64),
    ?assertEqual(<<"bug=">>,maps:get(input,Min)),
    proof(Dir,#{fixture=>artificial,raw_input=>Input,report=>R,expectation=>E,replayed=>Replayed,minimized=>Min}).
oracle_budget()->
    {Dir,A}=setup("oracle-budget"),C=(config(Dir,A,guided))#{max_iterations=>6,
        gleam_layer=>#{structured_fraction=>0,feedback=>guided,oracle=>inline,oracle_budget=>2}},
    {R,_,_}=campaign(C),Cs=maps:get(gleam_stats,R),
    ?assertEqual(7,maps:get(observer_calls,Cs)),?assertEqual(2,maps:get(oracle_checks,Cs)),
    ?assertEqual(2,maps:get(oracle_passes,Cs)),?assertEqual(5,maps:get(oracle_skipped,Cs)),
    ?assertEqual(0,maps:get(oracle_extra_executions,R)),
    proof(Dir,#{report=>R,budget=>2,checked_without_structural_novelty=>true,skipped=>5}).
coverage_intervals()->
    {Dir,A}=setup("intervals"),C=config(Dir,A,guided),
    {Plain,_,_}=campaign(C#{max_iterations=>0,gleam_layer=>false}),
    {Checked,_,_}=campaign(C#{max_iterations=>0,gleam_layer=>#{structured_fraction=>0,feedback=>guided,oracle=>inline}}),
    ?assertEqual(maps:get(coverage,Plain),maps:get(coverage,Checked)),
    ?assertEqual(0,maps:get(oracle_extra_executions,Checked)),
    ?assert(lists:all(fun({M,_,_})->M=:=cow_qs end,maps:get(coverage,Checked))),
    %% A separate serialized replay interval exercises the actual runner; the
    %% production pure oracle does not perform this extra target execution.
    {ok,Prepared}=efz_config:prepare(C#{max_iterations=>0}),H=maps:get(harness,maps:get(execution_identities,Prepared)),
    Expected=(maps:with([beam_md5,attributes_sha256,build_id],H))#{module=>atom_to_binary(maps:get(module,H),utf8)},
    Builds=efz_recipe:build_ids(maps:from_list([{maps:get(module,M),maps:get(build_id,M)}||M<-maps:get(manifests,Prepared)])),
    O=#{timeout=>1000,coverage_backend=>otp_native_public,max_input_bytes=>4096,expected_harness=>Expected},
    {ok,Extra}=efz_recipe:execute(<<"a=%">>,efz_qs_target,[A],Builds,O),
    ?assertEqual({ok,rejected},maps:get(outcome,Extra)),
    {Next,_,_}=campaign(C#{max_iterations=>0,gleam_layer=>false}),
    ?assertEqual(maps:get(coverage,Plain),maps:get(coverage,Next)),
    proof(Dir,#{plain=>Plain,checked=>Checked,separate_replay=>Extra,next=>Next,
        production_extra_target_executions=>0,deferred_oracle_supported=>false}).

native_barriers()->
    {Dir,A}=setup("native-barriers"),{ok,Prepared}=efz_config:prepare(
        (config(Dir,A,guided))#{target=>efz_gleam_feedback_target,gleam_layer=>false,max_iterations=>0}),
    Ms=maps:get(manifests,Prepared),O=#{coverage=>automatic,coverage_backend=>otp_native_public,
        manifests=>Ms,coverage_schema=>efz_coverage:prepare_native(Ms),max_input_bytes=>4096},
    true=register(efz_gleam_feedback_observer,self()),
    try
        Plain=efz_executor:run(efz_gleam_feedback_target,<<"normal">>,1000,O),
        Late=efz_executor:run(efz_gleam_feedback_target,<<"late">>,1000,O),
        {Root,Child}=receive {late_ready,R,C}->{R,C} after 3000->error(no_late_child) end,
        ?assertEqual(maps:get(coverage,Plain),maps:get(coverage,Late)),
        ?assertNot(is_process_alive(Root)),?assertNot(is_process_alive(Child)),
        ?assertMatch(#{status:=confirmed,survivors:=[]},maps:get(cleanup,Late)),
        Before=code:get_coverage(line,cow_qs),
        receive late_executed->error(late_target_execution) after 220->ok end,
        ?assertEqual(Before,code:get_coverage(line,cow_qs)),
        Self=self(),Tag=make_ref(),{Caller,Mon}=spawn_monitor(fun()->
            Self!{Tag,efz_executor:run(efz_gleam_feedback_target,<<"hold">>,1000,O)} end),
        Held=receive {late_ready,R2,_}->R2 after 3000->error(no_held_target) end,
        Busy=efz_executor:run(efz_gleam_feedback_target,<<"normal">>,1000,O),
        ?assertEqual({infrastructure,runner_busy},maps:get(outcome,Busy)),
        Held!release,Done=receive {Tag,D}->D after 3000->error(no_held_result) end,
        receive {'DOWN',Mon,process,Caller,normal}->ok after 3000->error(caller_leak) end,
        ?assertEqual(maps:get(coverage,Plain),maps:get(coverage,Done)),
        Next=efz_executor:run(efz_gleam_feedback_target,<<"normal">>,1000,O),
        ?assertEqual(maps:get(coverage,Plain),maps:get(coverage,Next)),
        proof(Dir,#{plain=>Plain,late=>Late,unchanged_after_child_deadline=>Before,
            concurrent_attempt=>Busy,serialized_completion=>Done,next=>Next})
    after unregister(efz_gleam_feedback_observer) end.

bounded_state()->
    Outcomes=[{ok,{accepted,[]}}, {ok,{accepted,[{<<"a">>,<<>>}]}},
        {ok,{accepted,[{<<"a">>,<<255>>},{<<"b">>,<<"1">>}]}},
        {ok,{accepted,lists:duplicate(3,{<<"a">>,<<"1">>})}},
        {ok,rejected},{timeout,1000},{crash,error,fixture,[]}],
    Features=[begin {ok,Fs}=efz_gleam_adapter:observe(<<>>,O,limits()),Fs end||O<-Outcomes],
    All=lists:usort(lists:append(Features)),?assertEqual(12,length(All)),
    {ok,Pid}=efz_corpus:start_link([<<"seed">>],{1,2,3},undefined,4096,#{feedback=>guided}),
    try
        M=#{parent=>1,phase=>mutation,new_probes=>[],retention_reason=>equivalent_coverage},
        lists:foreach(fun(I)->Fs=lists:nth(1+(I rem length(Features)),Features),
            _=efz_corpus:admit_semantic(integer_to_binary(I),M,Fs,false) end,lists:seq(1,10000)),
        ?assertEqual(All,efz_corpus:semantic_state()),{ok,Reps}=efz_corpus:semantic_representatives(),
        ?assertEqual(12,map_size(Reps)),?assert(efz_corpus:size()=<8),
        ?assertMatch({error,invalid_semantic_admission},efz_corpus:admit_semantic(<<"bad">>,M,
            [{<<"cow_qs">>,1,12}],false)),
        Bytes=fun(T)->erts_debug:flat_size(T)*erlang:system_info(wordsize) end,
        proof(directory("bounded-state"),#{admission_attempts=>10000,target_executions=>0,
            fixture=>normalized_outcomes,seen=>All,representatives=>Reps,
            corpus_count=>efz_corpus:size(),seen_flat_bytes=>Bytes(All),representatives_flat_bytes=>Bytes(Reps),
            max_execution_features=>lists:max([length(Fs)||Fs<-Features]),
            per_execution_flat_bytes=>[Bytes(Fs)||Fs<-Features]})
    after gen_server:stop(Pid) end.
