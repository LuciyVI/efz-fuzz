#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).
main([Engine,ModeText,SeedText,CountText,TraceText,Out,SourceRoot]) ->
    main([Engine,ModeText,SeedText,CountText,TraceText,Out,SourceRoot,"legacy"]);
main([Engine,ModeText,SeedText,CountText,TraceText,Out,SourceRoot,SeedDirectory]) ->
    Mode=list_to_existing_atom(ModeText),Seed=list_to_integer(SeedText),N=list_to_integer(CountText),
    Trace=list_to_integer(TraceText),true=N>=1 andalso N=<100000,true=Trace>=0 andalso Trace=<10000,
    true=code:add_patha(filename:join([Engine,"lib","efz","ebin"])),
    true=code:add_patha(filename:join([SourceRoot,"_build","default","lib","cowlib","ebin"])),
    %% This unchanged ordinary harness is common to all revisions, including A.
    {ok,efz_qs_target,B}=compile:file(filename:join([SourceRoot,"examples","query_string","efz_qs_target.erl"]),[binary,debug_info]),
    {module,efz_qs_target}=code:load_binary(efz_qs_target,"qs_harness",B),
    Target=case Mode of discovery->
        {ok,efz_qs_defect_target,Defect}=compile:file(filename:join([SourceRoot,"test","efz_qs_defect_target.erl"]),[binary,debug_info]),
        {module,efz_qs_defect_target}=code:load_binary(efz_qs_defect_target,"explicit_artificial_fixture",Defect),
        efz_qs_defect_target;_->efz_qs_target end,
    SrcDir=filename:join(Out,"source"),ok=filelib:ensure_dir(SrcDir++"/cow_qs.erl"),
    {ok,_}=file:copy(filename:join([SourceRoot,"_build","default","lib","cowlib","src","cow_qs.erl"]),SrcDir++"/cow_qs.erl"),
    {ok,_}=file:copy(filename:join([SourceRoot,"_build","default","lib","cowlib","include","cow_inline.hrl"]),SrcDir++"/cow_inline.hrl"),
    {ok,A}=efz_cov_native_public:compile(SrcDir++"/cow_qs.erl",Out++"/target"),
    C0=#{target=>Target,seeds=>[<<"a=1">>],artifacts=>[A],coverage_backend=>otp_native_public,
        mutation_mode=>staged,max_iterations=>N,timeout=>1000,crash_dir=>Out++"/crashes",
        selection_seed=>{Seed,Seed+1,Seed+2},
        mutation=>#{seed=>{Seed,Seed+1,Seed+2},stages=>[havoc],trace_limit=>Trace}},
    C1=mode(Mode,C0),
    PreparedModes=[seeds,structured,observation,guided,oracle,fraction1,fraction5,fraction10,fraction20],
    C=case SeedDirectory=/="legacy" andalso lists:member(Mode,PreparedModes) of
        true->{ok,Names}=file:list_dir(SeedDirectory),
            true=length(Names)=<64,
            Seeds=[begin {ok,Raw}=efz_input:read_file(filename:join(SeedDirectory,Name),4096,benchmark_seed),Raw end
                ||Name<-lists:sort(Names),filename:extension(Name)=:=".qs"],
            true=length(Seeds)>=1 andalso length(Seeds)=<64,C1#{seeds=>Seeds};
        false->C1 end,
    %% Warm the existing executor in a separate campaign; never inherit corpus.
    WarmN=case Mode of discovery->0;_->20 end,
    {ok,_}=efz:start(C#{max_iterations=>WarmN,crash_dir=>Out++"/warmup-crashes"}),
    Warm=efz:await(30000),ok=efz:stop(),
    case Mode of discovery->0=maps:get(oracle_failures,maps:get(gleam_stats,Warm),0),
        1=maps:get(oracle_passes,maps:get(gleam_stats,Warm));_->ok end,
    {Red0,_}=erlang:statistics(reductions),{GC0,_,_}=erlang:statistics(garbage_collection),
    Start=erlang:monotonic_time(microsecond),
    {ok,_}=efz:start(C),
    Worker=maps:get(worker,sys:get_state(whereis(efz_fuzzer))),
    Samples=sample(Start,Worker,0,[]),R=efz:await(120000),
    ObservedWall=erlang:monotonic_time(microsecond)-Start,
    Timing=maps:get(timing,R),
    Wall=maps:get(calibration_started_at,Timing)+maps:get(calibration_us,Timing)+maps:get(mutation_us,Timing)-Start,
    CorpusState=sys:get_state(whereis(efz_corpus)),
    SemanticState=maps:is_key(semantic_seen,CorpusState),
    ok=efz:stop(),{Red1,_}=erlang:statistics(reductions),{GC1,_,_}=erlang:statistics(garbage_collection),
    Stats=maps:get(stats,R),Exec=maps:get(executions,Stats),Cal=maps:get(calibrations,Stats),
    Rows=[{efz_mutation:hash(Bin),maps:get(stage,Q),maps:get(parent,Q)}||Q<-maps:get(mutation_trace,R),
        {ok,Bin}<-[efz_recipe:regenerate(Q)]],
    Kept=maps:get(corpus,R),
    RawDir=Out++"/corpus",ok=filelib:ensure_dir(RawDir++"/entry"),
    CorpusRows=[begin Input=maps:get(input,E),Hash=binary:encode_hex(crypto:hash(sha256,Input),lowercase),
        ok=file:write_file(filename:join(RawDir,binary_to_list(Hash)++".input"),Input),
        #{hash=>Hash,size=>byte_size(Input),id=>maps:get(id,E),features=>portable(efz_semantic_features(E))}
    end||E<-Kept],
    ok=file:write_file(Out++"/corpus.json",json:encode(CorpusRows)),
    CalUs=maps:get(calibration_us,maps:get(timing,R)),MutUs=maps:get(mutation_us,maps:get(timing,R)),
    Summary=#{otp=>erlang:system_info(otp_release),erts=>erlang:system_info(version),
        schedulers_online=>erlang:system_info(schedulers_online),emu_flavor=>erlang:system_info(emu_flavor),mode=>Mode,seed=>Seed,requested_executions=>N,main_executions=>Exec+Cal,mutation_executions=>Exec,
        wall_us=>Wall,poll_completion_wall_us=>ObservedWall,mutation_us=>MutUs,calibration_us=>CalUs,
        setup_including_calibration_us=>max(0,Wall-MutUs),online_exec_per_second=>Exec*1000000/max(1,MutUs),
        samples=>Samples,sample_period_ms=>100,sample_limit=>512,
        memory_sampled_peak=>lists:max([maps:get(memory,X)||X<-Samples]),
        queue_sampled_peak=>lists:max([maps:get(queue,X)||X<-Samples]),
        exec_per_second=>(Exec+Cal)*1000000/Wall,status=>maps:get(status,R),
        memory_end=>erlang:memory(total),reductions=>Red1-Red0,gc_count=>GC1-GC0,
        corpus_count=>length(Kept),corpus_bytes=>lists:sum([byte_size(maps:get(input,E))||E<-Kept]),
        semantic_only=>length([E||E<-Kept,maps:get(retention_reason,maps:get(metadata,E),none)=:=new_semantic]),
        coverage_count=>length(maps:get(coverage,R)),trace=>Rows,
        trace_sha256=>crypto:hash(sha256,term_to_binary(Rows)),
        gleam_stats=>maps:get(gleam_stats,R,#{}),structured_stats=>maps:get(structured_stats,R,#{}),
        semantic_features=>maps:get(semantic_features,R,[]),semantic_state_created=>SemanticState,
        active_represented_features=>length(lists:usort(lists:append([efz_semantic_features(E)||E<-Kept]))),
        gleam_loaded=>code:is_loaded(efz_qs_model)=/=false,
        optional_application_loaded=>lists:keymember(efz_semantic,1,application:loaded_applications()),
        oracle_extra_executions=>maps:get(oracle_extra_executions,R,0),
        errors=>maps:get(infrastructure_failures,Stats),crashes=>maps:get(crashes,Stats),
        findings=>[#{path=>maps:get(path,F),input_hash=>maps:get(input_hash,F)}||F<-maps:get(crashes,R)],
        discovery_status=>case maps:get(crashes,Stats) of 0->censored;_->found end,
        first_finding_sample_upper_us=>case [maps:get(elapsed_us,X)||X<-Samples,maps:get(findings,X)>0] of
            []->unavailable;[FirstTime|_]->FirstTime end,
        unavailable=>[campaign_latency_percentiles,component_decode_mutate_encode_split,oracle_deferred],
        start_corpus_sha256=>crypto:hash(sha256,term_to_binary(maps:get(seeds,C)))},
    ok=file:write_file(Out++"/report.term",term_to_binary(R)),
    ok=file:write_file(Out++"/summary.term",term_to_binary(Summary)),
    ok=file:write_file(Out++"/summary.json",json:encode(portable(Summary))),
    io:format("~p seed ~p: ~p executions, ~.1f/s, status ~p~n",[Mode,Seed,Exec+Cal,maps:get(exec_per_second,Summary),maps:get(status,R)]),
    completed=maps:get(status,R);
main(_)->io:format("Usage: gleam_bench.escript ENGINE_BUILD MODE SEED EXECUTIONS TRACE_LIMIT OUT SOURCE_ROOT\n"),halt(2).

mode(discovery,C)->C#{seeds=>[<<"abc=1">>],
    mutation=>(maps:get(mutation,C))#{stages=>[havoc],dictionary=>[<<"bug">>]},
    gleam_layer=>#{structured_fraction=>10,feedback=>guided,oracle=>inline,oracle_budget=>10000}};
mode(baseline,C)->C;
mode(off,C)->C#{gleam_layer=>false};
mode(seeds,C)->C#{seeds=>typed_seeds()};
mode(structured,C)->C#{seeds=>typed_seeds(),gleam_layer=>#{structured_fraction=>10}};
mode(observation,C)->C#{seeds=>typed_seeds(),gleam_layer=>#{structured_fraction=>10,feedback=>observation_only}};
mode(guided,C)->C#{seeds=>typed_seeds(),gleam_layer=>#{structured_fraction=>10,feedback=>guided}};
mode(oracle,C)->C#{seeds=>typed_seeds(),gleam_layer=>#{structured_fraction=>10,feedback=>guided,oracle=>inline,oracle_budget=>64}};
mode(fraction0,C)->C#{gleam_layer=>#{structured_fraction=>0}};
mode(fraction1,C)->C#{seeds=>typed_seeds(),gleam_layer=>#{structured_fraction=>1}};
mode(fraction5,C)->C#{seeds=>typed_seeds(),gleam_layer=>#{structured_fraction=>5}};
mode(fraction10,C)->C#{seeds=>typed_seeds(),gleam_layer=>#{structured_fraction=>10}};
mode(fraction20,C)->C#{seeds=>typed_seeds(),gleam_layer=>#{structured_fraction=>20}};
mode(feedback_disabled,C)->C#{seeds=>typed_seeds(),gleam_layer=>#{structured_fraction=>0,feedback=>disabled}};
mode(feedback_observation,C)->C#{seeds=>typed_seeds(),gleam_layer=>#{structured_fraction=>0,feedback=>observation_only}}.
typed_seeds()->[<<>>,<<"a=">>,<<"a=%00%FF">>,<<"a=%20%26%3D%25&a=1">>,<<"bug=1">>,<<"a=1&x=%">>].
portable(B) when is_binary(B)->binary:encode_hex(B,lowercase);
portable(T) when is_tuple(T)->[portable(X)||X<-tuple_to_list(T)];
portable(M) when is_map(M)->maps:map(fun(_,V)->portable(V) end,M);
portable(L) when is_list(L)->[portable(X)||X<-L];
portable(A) when A=:=true;A=:=false;A=:=null->A;
portable(A) when is_atom(A)->atom_to_binary(A,utf8);
portable(N)->N.

%% Same existing snapshot API and 100ms sampling overhead in every revision.
sample(Start,Worker,N,Acc)->
    Snapshot=efz_fuzzer:benchmark_snapshot(),
    Queue=case process_info(Worker,message_queue_len) of undefined->0;{message_queue_len,Q}->Q end,
    Row=#{elapsed_us=>erlang:monotonic_time(microsecond)-Start,memory=>erlang:memory(total),
        queue=>Queue,coverage_count=>maps:get(coverage_count,Snapshot),
        main_executions=>maps:get(executions,maps:get(stats,Snapshot))+maps:get(calibrations,maps:get(stats,Snapshot)),
        findings=>maps:get(crashes,maps:get(stats,Snapshot))},
    Next=case N<512 of true->[Row|Acc];false->Acc end,
    case maps:get(completed,Snapshot) of
        true->lists:reverse(Next);
        false->true=erlang:monotonic_time(microsecond)-Start<120000000,
            receive after 100->sample(Start,Worker,N+1,Next) end
    end.
efz_semantic_features(#{metadata:=M})->case maps:find(semantic,M) of
    {ok,#{features:=Fs}}->Fs;error->[] end.
