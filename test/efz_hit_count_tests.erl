-module(efz_hit_count_tests).
-include_lib("eunit/include/eunit.hrl").

bucket_test() ->
    Ns=[1,2,3,4,7,8,15,16,31,32,63,64,127,128,1000],
    ?assertEqual([1,2,2,4,4,8,8,16,16,32,32,64,64,128,128],[efz_cov_count:bucket(N)||N<-Ns]),
    ?assertError(function_clause,efz_cov_count:bucket(0)).
exact_features_test() ->
    A={m,<<1:256>>,1}, B={m,<<1:256>>,2}, OtherBuild={m,<<2:256>>,1},
    F=efz_feedback:new(#{m=><<1:256>>},hit_count),
    {ok,F1,D1}=efz_feedback:evaluate(F,result(#{A=>1,B=>1}),mutation),
    ?assertEqual([A,B],maps:get(new_probes,D1)),?assertEqual(new_probe,maps:get(retention_reason,D1)),
    {ok,F2,D2}=efz_feedback:evaluate(F1,result(#{A=>2,B=>1}),mutation),
    ?assertEqual([],maps:get(new_probes,D2)),?assertEqual([{A,2}],maps:get(new_count_features,D2)),
    ?assertEqual(new_hit_count,maps:get(retention_reason,D2)),
    {ok,_,D3}=efz_feedback:evaluate(F2,result(#{A=>2,B=>4}),mutation),
    ?assertEqual([{B,4}],maps:get(new_count_features,D3)),
    ?assertEqual({ok,[{A,1},{OtherBuild,1}]},efz_cov_count:features([A,OtherBuild],#{A=>1,OtherBuild=>1})),
    ?assertEqual({error,instrumentation_build_mismatch},efz_feedback:evaluate(F2,(result(#{OtherBuild=>1}))#{builds=>#{m=><<2:256>>}},mutation)),
    ?assertEqual({error,{coverage_failure,invalid_hit_counts}},efz_feedback:evaluate(F2,maps:remove(hit_counts,result(#{A=>1})),mutation)),
    ?assertEqual({error,invalid_hit_counts},efz_cov_count:features([A],#{B=>1})).
result(Counts) -> #{builds=>#{m=><<1:256>>},coverage_status=>ok,outcome=>{ok,ok},
    coverage=>lists:sort(maps:keys(Counts)),coverage_feedback=>hit_count,hit_counts=>Counts}.

counter_namespace_test() ->
    A={m,<<1:256>>,1},B={m,<<2:256>>,1},
    C=efz_cov:open(ets,hit_count),ok=efz_cov:attach(C),
    try
        ok=efz_cov_rt:hit(A),ok=efz_cov_rt:hit(B),ok=efz_cov_rt:hit(B),
        ?assertEqual({ok,#{A=>1,B=>2}},efz_cov_count:snapshot(C)),
        %% ETS counters retain Erlang integers instead of wrapping at 64 bits.
        {efz_context,1,_,{ets_count,T},_}=C,
        true=ets:insert(T,{{probe,A},(1 bsl 63)-1}),ok=efz_cov_rt:hit(A),
        ?assertEqual({ok,#{A=>(1 bsl 63),B=>2}},efz_cov_count:snapshot(C))
    after efz_cov:detach(),efz_cov:close(C),flush_observed() end.
flush_observed() -> receive {efz_cov_observed,_,_}->flush_observed() after 0->ok end.

integration_test_() -> {setup,fun setup/0,fun cleanup/1,fun(A)->[
    {"presence remains the default; schema rejects invalid mode",fun()->configuration(A) end},
    {"real instrumented multiplicity, both storage selectors",fun()->multiplicity(A) end},
    {"real multi-probe count delta and valid empty observation",fun()->multi_probe(A) end},
    {"coverage mode does not change mutation operators or recipe",fun()->mutation_independence(A) end},
    {"count snapshot and integrity on child/crash/timeout",fun()->lifecycle(A) end},
    {"worker retains bucket discoveries and scheduler reuses exact parents",{timeout,30,fun()->campaign(A) end}},
    {"count-only corpus persistence and fresh-VM regeneration/restore",{timeout,30,fun()->durable(A) end}},
    {"crash from count mode replays raw bytes and recipe in a fresh VM",{timeout,10,fun()->crash_replay(A) end}}
] end}.
setup() ->
    _=application:ensure_all_started(crypto),
    {ok,H,B}=compile:file("fixtures/hit_count/efz_count_harness.erl",[binary,debug_info,warnings_as_errors]),
    {module,H}=code:load_binary(H,"fixtures/hit_count/efz_count_harness.erl",B),
    {ok,A}=efz_instrument:compile("fixtures/hit_count/efz_count_sites.erl",
        #{modules=>[efz_count_sites],source_root=>".",outdir=>"_build/hit-count-tests/targets"}),A.
cleanup(_) -> efz:stop(),ok.
configuration(A) ->
    C=#{target=>efz_count_harness,seeds=>[<<>>],artifacts=>[A]},
    {ok,Prepared}=efz_config:prepare(C),?assertEqual(presence,maps:get(coverage_feedback,Prepared)),
    ?assertEqual({error,{invalid_campaign_option,coverage_feedback}},efz_config:prepare(C#{coverage_feedback=>bitmap})).
options(A,Mode) -> {ok,Ms}=efz_instrument:preflight([A]),#{coverage=>automatic,manifests=>Ms,coverage_feedback=>Mode}.
execute(A,Mode,Input) -> efz_executor:run(efz_count_harness,Input,1000,options(A,Mode)).
multi_probe(A) ->
    R1=execute(A,hit_count,<<"PAIR",1:16,1:16>>),
    [PA,PB]=maps:get(coverage,R1),
    {ok,F1,_}=efz_feedback:evaluate(efz_feedback:new(maps:get(builds,R1),hit_count),R1,mutation),
    {ok,F2,D2}=efz_feedback:evaluate(F1,execute(A,hit_count,<<"PAIR",2:16,1:16>>),mutation),
    ?assertEqual([{PA,2}],maps:get(new_count_features,D2)),
    {ok,_,D3}=efz_feedback:evaluate(F2,execute(A,hit_count,<<"PAIR",2:16,4:16>>),mutation),
    ?assertEqual([{PB,4}],maps:get(new_count_features,D3)),
    Zero=execute(A,hit_count,<<>>),?assertEqual(#{},maps:get(hit_counts,Zero)),
    ?assertMatch(#{classification:=valid_empty_coverage},maps:get(coverage_observation,Zero)),
    {ok,F2,D0}=efz_feedback:evaluate(F2,Zero,mutation),
    ?assertEqual(equivalent_coverage,maps:get(retention_reason,D0)).
mutation_independence(A) ->
    {ok,P}=efz_config:prepare(config(A,presence)),{ok,H}=efz_config:prepare(config(A,hit_count)),
    ?assertEqual(maps:get(mutation,P),maps:get(mutation,H)),
    Entries=[#{id=>1,input=><<>>}],
    ?assertEqual(efz_mutation_plan:next(efz_mutation_plan:new(maps:get(mutation,P)),Entries),
                 efz_mutation_plan:next(efz_mutation_plan:new(maps:get(mutation,H)),Entries)),
    ?assertEqual(efz_mutator_random:mutate(<<"A">>,P#{seed=>{17,23,41}}),
                 efz_mutator_random:mutate(<<"A">>,H#{seed=>{17,23,41}})).
multiplicity(A) ->
    P1=execute(A,presence,<<"L1">>),P1000=execute(A,presence,<<"L1000">>),
    ?assertEqual(maps:get(coverage,P1),maps:get(coverage,P1000)),
    ?assertNot(maps:is_key(hit_counts,P1)),
    {ok,PF,_}=efz_feedback:evaluate(efz_feedback:new(maps:get(builds,P1)),P1,mutation),
    {ok,_,PD}=efz_feedback:evaluate(PF,P1000,mutation),
    ?assertEqual(equivalent_coverage,maps:get(retention_reason,PD)),
    lists:foreach(fun(Backend)->
        F0=efz_feedback:new(maps:get(builds,P1),hit_count),
        lists:foldl(fun(N,{F,Seen})->
            Input=iolist_to_binary(["L",integer_to_list(N)]),
            R=efz_executor:run(efz_count_harness,Input,1000,(options(A,hit_count))#{coverage_backend=>Backend}),
            ?assertEqual({ok,{Input,N}},maps:get(outcome,R)),
            [X]=maps:get(coverage,R),?assertEqual(#{X=>N},maps:get(hit_counts,R)),
            {ok,F1,D}=efz_feedback:evaluate(F,R,mutation),Bucket=efz_cov_count:bucket(N),
            Expected=case {Seen,lists:member(Bucket,Seen)} of {[],_}->new_probe;{_,true}->equivalent_coverage;_->new_hit_count end,
            ?assertEqual(Expected,maps:get(retention_reason,D)),
            {F1,lists:usort([Bucket|Seen])}
        end,{F0,[]},[1,2,3,4,7,8,15,16,31,32,63,64,127,128,1000])
    end,[ets,ets_member]).
lifecycle(A) ->
    Child=execute(A,hit_count,<<"CHILD">>),?assertEqual([1000],maps:values(maps:get(hit_counts,Child))),
    lists:foreach(fun(Input)->
        R=efz_executor:run(efz_count_harness,Input,50,options(A,hit_count)),
        ?assertEqual(ok,maps:get(coverage_status,R)),?assertEqual([1],maps:values(maps:get(hit_counts,R))),
        ?assert(lists:all(fun(P)->not is_process_alive(P) end,maps:get(processes,maps:get(cleanup,R)))),
        F=efz_feedback:new(maps:get(builds,R),hit_count),
        {ok,F,D}=efz_feedback:evaluate(F,R,mutation),?assertEqual(target_failure,maps:get(retention_reason,D))
    end,[<<"CRASH">>,<<"TIMEOUT">>]),
    Bad=execute(A,hit_count,<<"CORRUPT">>),
    ?assertMatch({infrastructure,invalid_hit_counts},maps:get(outcome,Bad)),
    Good=execute(A,hit_count,<<"L1">>),?assertEqual([1],maps:values(maps:get(hit_counts,Good))).
config(A,Mode) -> #{target=>efz_count_harness,artifacts=>[A],seeds=>[<<>>],
    coverage_feedback=>Mode,mutation_mode=>staged,max_input_bytes=>4,max_iterations=>500,
    timeout=>1000,mutation=>#{seed=>{17,23,41},stages=>[dictionary_insert],trace_limit=>1000,
        dictionary=>[<<"L1">>,<<"L2">>,<<"L3">>,<<"L4">>,<<"L8">>,<<"L16">>,<<"L100">>]}}.
run_campaign(C) -> {ok,_}=efz:start(C),try efz:await(25000) after efz:stop() end.
campaign(A) ->
    P=run_campaign(config(A,presence)),H=run_campaign(config(A,hit_count)),
    ?assertEqual([<<>>,<<"L1">>],[maps:get(input,E)||E<-maps:get(corpus,P)]),
    Es=maps:get(corpus,H),
    lists:foreach(fun(B)->?assert(lists:any(fun(E)->maps:get(input,E)=:=B end,Es)) end,
        [<<"L1">>,<<"L2">>,<<"L4">>,<<"L8">>,<<"L16">>,<<"L100">>]),
    ?assertNot(lists:any(fun(E)->maps:get(input,E)=:=<<"L3">> end,Es)),
    [L2]=[E||E<-Es,maps:get(input,E)=:=<<"L2">>],Id=maps:get(id,L2),
    ?assertEqual(new_hit_count,maps:get(retention_reason,maps:get(metadata,L2))),
    Descendants=[R||R<-maps:get(mutation_trace,H),maps:get(parent,R)=:=Id],
    ?assert(Descendants=/=[]),
    lists:foreach(fun(R)->?assertEqual(<<"L2">>,maps:get(primary,R)),
        ?assertEqual(crypto:hash(sha256,<<"L2">>),maps:get(primary_id,R)),
        ?assertMatch({ok,_},efz_recipe:regenerate(R)) end,Descendants),
    ?assertEqual(maps:get(coverage,P),maps:get(coverage,H)),
    ?assertEqual(0,maps:get(infrastructure_failures,maps:get(stats,H))),
    ok=file:write_file("_build/hit-count-tests/campaign.term",term_to_binary(H)).
durable(A) ->
    Dir="_build/hit-count-tests/corpus-"++binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8))),
    H=run_campaign((config(A,hit_count))#{corpus_dir=>Dir}),
    [E]=[X||X<-maps:get(corpus,H),maps:get(input,X)=:=<<"L2">>],
    Meta=maps:get(metadata,E),Record=maps:get(persistence,Meta),
    ?assertMatch(#{schema_version:=2,discovery:=#{retention_reason:=new_hit_count,new_probes:=[]}},Record),
    R=maps:get(mutation,Meta),{ok,Encoded}=efz_recipe:encode(R),
    Job="_build/hit-count-tests/fresh.term",
    ok=file:write_file(Job,term_to_binary({config(A,hit_count),Dir,Encoded})),
    Eval="{ok,B}=file:read_file(\""++Job++"\"),{C,D,R}=binary_to_term(B),"
        "{ok,M,H}=compile:file(\"fixtures/hit_count/efz_count_harness.erl\",[binary,debug_info]),"
        "{module,M}=code:load_binary(M,\"fixtures/hit_count/efz_count_harness.erl\",H),"
        "{ok,Recipe}=efz_recipe:decode(R),{ok,<<\"L2\">>}=efz_recipe:regenerate(Recipe),"
        "{ok,_}=efz:start(C#{seeds=>[<<>>],corpus_dir=>D}),Report=efz:await(25000),"
        "Es=maps:get(corpus,Report),[E]=[X||X<-Es,maps:get(input,X)=:=<<\"L2\">>],"
        "true=maps:get(restored,maps:get(metadata,E)),Id=maps:get(id,E),"
        "true=lists:any(fun(T)->maps:get(parent,T)=:=Id andalso maps:get(primary,T)=:=<<\"L2\">> end,maps:get(mutation_trace,Report)),"
        "N=maps:get(restored_inputs,maps:get(corpus_restore,Report)),N=maps:get(calibrations,maps:get(stats,Report)),"
        "ok=efz:stop(),halt(0).",
    Port=open_port({spawn_executable,os:find_executable("erl")},[binary,exit_status,stderr_to_stdout,
        {args,["+S","2:2","-noshell","-pa",filename:dirname(code:which(efz)),"-eval",Eval]}]),
    {Status,Output}=port_result(Port,<<>>),?assertEqual({0,Output},{Status,Output}),
    %% Reusable bytes may also be recalibrated under presence with the same builds.
    P=run_campaign((config(A,presence))#{seeds=>[],corpus_dir=>Dir,max_iterations=>0}),
    ?assertEqual(length(maps:get(corpus,H)),maps:get(calibrations,maps:get(stats,P))).
crash_replay(A) ->
    C=(config(A,hit_count))#{max_iterations=>1,max_input_bytes=>8,
        crash_dir=>"_build/hit-count-tests/crashes-"++binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8))),
        mutation=>#{seed=>{17,23,41},stages=>[dictionary_insert],dictionary=>[<<"CRASH">>]}},
    H=run_campaign(C),[Crash]=maps:get(crashes,H),
    ?assertEqual(<<"CRASH">>,maps:get(input,Crash)),
    ?assertEqual([1],maps:values(maps:get(hit_counts,maps:get(result,Crash)))),
    Job="_build/hit-count-tests/crash-job.term",
    ok=file:write_file(Job,term_to_binary({A,maps:get(path,Crash)})),
    Eval="{ok,B}=file:read_file(\""++Job++"\"),{A,P}=binary_to_term(B),"
        "{ok,M,H}=compile:file(\"fixtures/hit_count/efz_count_harness.erl\",[binary,debug_info]),"
        "{module,M}=code:load_binary(M,\"fixtures/hit_count/efz_count_harness.erl\",H),"
        "{ok,E}=efz_replay:load(P++\".replay\"),"
        "{ok,#{status:=reproduced}}=efz_replay:run(raw,P++\".input\",M,[A],E,#{}),"
        "{ok,#{status:=reproduced}}=efz_replay:run(recipe,P++\".recipe\",M,[A],E,#{}),"
        "[{Name,_}]=maps:get(target_builds,E),"
        "{error,replay_build_mismatch}=efz_replay:run(raw,P++\".input\",M,[A],E#{target_builds=>[{Name,<<0:256>>}]},#{}),"
        "Wrong=(maps:get(harness,E))#{beam_md5=><<0:128>>},"
        "{error,replay_harness_mismatch}=efz_replay:run(raw,P++\".input\",M,[A],E#{harness=>Wrong},#{}),halt(0).",
    Port=open_port({spawn_executable,os:find_executable("erl")},[binary,exit_status,stderr_to_stdout,
        {args,["+S","2:2","-noshell","-pa",filename:dirname(code:which(efz)),"-eval",Eval]}]),
    {Status,Output}=port_result(Port,<<>>),?assertEqual({0,Output},{Status,Output}).
port_result(P,Acc) -> receive
    {P,{data,B}}->port_result(P,<<Acc/binary,B/binary>>);
    {P,{exit_status,N}}->{N,Acc}
    after 26000->port_close(P),error(fresh_vm_timeout) end.
