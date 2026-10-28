#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).

%% One fresh VM per measurement. This driver never substitutes for Erlamsa.
main([Engine, Mode, SeedText, SecondsText, Out, Root, ArtifactFile, Core, MaxRequestsText]) ->
    Seed = list_to_integer(SeedText), Seconds = list_to_integer(SecondsText),
    MaxRequests = list_to_integer(MaxRequestsText),
    true = Seed > 0 andalso Seconds >= 1 andalso Seconds =< 3600,
    true = MaxRequests >= 1 andalso MaxRequests =< 1000000,
    true = lists:member(Mode, ["baseline", "native", "erlamsa", "erlamsa_persistent",
        "hybrid", "hybrid_persistent", "semantic_persistent", "native_semantic"]),
    Paths = filelib:wildcard(filename:join([Engine, "lib", "*", "ebin"])),
    true = Paths =/= [], [true = code:add_patha(P) || P <- Paths],
    true = code:add_patha(filename:join([Root,"_build","default","lib","cowlib","ebin"])),
    {ok, efz_benchmark_erlamsa_target, Harness} = compile:file(
        filename:join([Root,"scripts","benchmark_erlamsa_target.erl"]), [binary,debug_info]),
    {module, efz_benchmark_erlamsa_target} = code:load_binary(
        efz_benchmark_erlamsa_target, "benchmark_erlamsa_target.erl", Harness),
    true = register(efz_erlamsa_benchmark_collector, self()),
    {ok, [Artifact]} = file:consult(ArtifactFile),
    Seeds = [<<>>, <<"a=">>, <<"a=%00%FF">>, <<"a=%20%26%3D%25&a=1">>,
             <<"plain=1">>, <<"a=1&x=%">>],
    C0 = #{target=>efz_benchmark_erlamsa_target, seeds=>Seeds,
        artifacts=>[Artifact], coverage_backend=>otp_native_public,
        max_input_bytes=>4096, mutation_mode=>staged, max_iterations=>infinity,
        mutation=>#{seed=>{Seed,Seed+1,Seed+2},stages=>[havoc],trace_limit=>0},
        selection_seed=>{Seed,Seed+1,Seed+2}, random_seed=>{Seed,Seed+1,Seed+2},
        performance_profile=>bench_profile(),timeout=>1000,crash_dir=>Out++"/crashes"},
    C = config(Mode, C0, Core, MaxRequests),
    %% A separate finite campaign warms code and executor without reusing corpus.
    {ok, _} = efz:start(C#{max_iterations=>10,crash_dir=>Out++"/warmup-crashes"}),
    Warm = efz:await(30000),
    completed = maps:get(status,Warm), ok = efz:stop(),
    _ = drain(#{accepted=>0,rejected=>0,input_bytes=>0,input_max=>0}),
    CampaignStarted = erlang:monotonic_time(microsecond),
    {ok, _} = efz:start(C#{corpus_dir=>Out++"/corpus"}),
    Worker = maps:get(worker, sys:get_state(whereis(efz_fuzzer))),
    Start = await_mutation(Worker),
    {Samples, Diag, StopAt} = sample(Start, Start+Seconds*1000000, [],
        #{accepted=>0,rejected=>0,input_bytes=>0,input_max=>0}),
    ok = efz:request_stop(), Report = efz:await(30000),
    End = erlang:monotonic_time(microsecond),
    FinalDiag = drain(Diag),
    RawProfile=maps:get(profile,sys:get_state(Worker),#{}),
    NativeTimes=case Mode of
        "native"->maps:get(samples,maps:get(mutation,RawProfile,#{samples=>[]}));
        "baseline"->maps:get(samples,maps:get(mutation,RawProfile,#{samples=>[]}));
        _->[]
    end,
    Stats = maps:get(stats,Report),
    Executions = maps:get(executions,Stats), Calibration = maps:get(calibrations,Stats),
    MutationUs = maps:get(mutation_us,maps:get(timing,Report)),
    Provider = maps:get(provider_stats,Report,#{}),
    Latencies = maps:get(latency_us,Provider,[]), CoreTimes=maps:get(core_us,Provider,[]),
    Phases = maps:get(phase_us,Provider,#{}),
    DirectCoreTimes = maps:get(direct_core_mutation_us,Phases,[]),
    IdentityTimes = maps:get(identity_check_us,Phases,[]),
    Session = maps:get(session,Provider,#{}),
    RequestSamples = maps:get(request_samples,Session,[]),
    StartupSamples = maps:get(startup_samples,Session,[]),
    RecycleStartupSamples = maps:get(recycle_startup_samples,Session,[]),
    RecycleCleanupSamples = maps:get(recycle_cleanup_samples,Session,[]),
    DecodeCalls = maps:get(accepted,FinalDiag)+maps:get(rejected,FinalDiag),
    true = DecodeCalls =:= Executions+Calibration,
    Summary = #{schema_version=>1, mode=>list_to_binary(Mode), seed=>Seed,
        requested_mutation_wall_seconds=>Seconds, mutation_us=>MutationUs,
        sample_window_us=>StopAt-Start, stop_latency_us=>End-StopAt,
        campaign_wall_us=>End-CampaignStarted,
        status=>maps:get(status,Report), mutation_executions=>Executions,
        calibration_executions=>Calibration, total_target_calls=>DecodeCalls,
        target_executions_per_second=>DecodeCalls*1000000/max(1,End-CampaignStarted),
        mutation_executions_per_second=>Executions*1000000/max(1,End-CampaignStarted),
        steady_state_target_executions_per_second=>DecodeCalls*1000000/max(1,StopAt-Start),
        target_coverage_count=>length(maps:get(coverage,Report)),
        target_coverage=>maps:get(coverage,Report), decode=>FinalDiag,
        accepted_fraction=>maps:get(accepted,FinalDiag)/max(1,DecodeCalls),
        mean_input_bytes=>maps:get(input_bytes,FinalDiag)/max(1,DecodeCalls),
        sampled_vm_memory_peak_bytes=>lists:max([maps:get(vm_memory_bytes,S)||S<-Samples]),
        sampled_worker_queue_peak=>lists:max([maps:get(worker_queue,S)||S<-Samples]),
        provider_stats=>maps:without([latency_us,core_us],Provider),
        provider_latency_p50_us=>quantile(Latencies,0.5),
        provider_latency_p95_us=>quantile(Latencies,0.95),
        provider_latency_samples=>length(Latencies),
        provider_core_p50_us=>quantile(CoreTimes,0.5),
        provider_core_p95_us=>quantile(CoreTimes,0.95),
        provider_core_samples=>length(CoreTimes),
        direct_core_mutation_p50_p95_us=>value_percentiles(DirectCoreTimes),
        identity_check_p50_p95_us=>value_percentiles(IdentityTimes),
        provider_phase_percentiles=>phase_percentiles(Phases),
        warm_request_p50_p95_us=>sample_percentiles(RequestSamples,request_total_us),
        worker_startup_p50_p95_us=>sample_percentiles(StartupSamples,worker_startup_us),
        recycle_startup_p50_p95_us=>sample_percentiles(RecycleStartupSamples,worker_startup_us),
        recycle_cleanup_p50_p95_us=>sample_percentiles(RecycleCleanupSamples,recycle_cleanup_us),
        vm_starts=>maps:get(vm_starts,Session,0),
        completed_requests_per_vm=>maps:get(completed_requests,Session,0),
        worker_restarts=>maps:get(restarts,Session,0),
        native_generation_p50_us=>quantile(NativeTimes,0.5),
        native_generation_p95_us=>quantile(NativeTimes,0.95),
        native_generation_samples=>length(NativeTimes),
        performance_profile=>maps:get(performance_profile,Report,#{}),
        input_size_buckets=>maps:get(input_size_buckets,Report,#{}),
        gleam_stats=>maps:get(gleam_stats,Report,#{}),
        structured_stats=>maps:get(structured_stats,Report,#{}),
        retained_inputs=>length(maps:get(corpus,Report)),
        semantic_only_retained=>length([E||E<-maps:get(corpus,Report),
            maps:get(retention_reason,maps:get(metadata,E),none)=:=new_semantic]),
        target_build_id=>maps:get(build_id,Artifact),
        harness_beam_sha256=>binary:encode_hex(crypto:hash(sha256,Harness),lowercase),
        initial_corpus_sha256=>binary:encode_hex(crypto:hash(sha256,term_to_binary(Seeds)),lowercase),
        selected_provider=>maps:get(provider,Report,#{mode=>native}),
        stats=>Stats, samples=>Samples, otp=>erlang:system_info(otp_release),
        erts=>erlang:system_info(version), schedulers=>erlang:system_info(schedulers_online)},
    ok = file:write_file(Out++"/report.term",term_to_binary(Report)),
    ok = file:write_file(Out++"/summary.json",json:encode(portable(Summary))),
    ok = efz:stop(),
    io:format("~s seed ~p: ~p executions ~.1f/s coverage ~p~n",[Mode,Seed,
        Executions,maps:get(target_executions_per_second,Summary),maps:get(target_coverage_count,Summary)]),
    case maps:get(status,Report) of
        stopped_by_user -> ok;
        Status -> io:format("campaign ended early: ~tp~n",[Status]), halt(3)
    end;
main(_) -> io:format("Usage: benchmark_erlamsa.escript ENGINE_BUILD MODE SEED SECONDS OUT SOURCE_ROOT SHARED_ARTIFACT CORE_ROOT MAX_REQUESTS~n"), halt(2).

config("native_semantic", C, _Core, _MaxRequests) -> C#{gleam_layer => semantic_layer()};

config(Mode,C,Core,MaxRequests) when Mode=:= "erlamsa";Mode=:= "hybrid";Mode=:= "semantic";
        Mode=:= "erlamsa_persistent";Mode=:= "hybrid_persistent";
        Mode=:= "semantic_persistent" ->
    ProviderMode = case Mode of "erlamsa"->erlamsa;"erlamsa_persistent"->erlamsa;_->hybrid end,
    Transport = case lists:suffix("_persistent",Mode) of true->persistent;false->disposable end,
    Base=C#{mutation_provider=>#{mode=>ProviderMode,core_path=>Core,timeout=>2000,
        transport=>Transport,max_requests=>MaxRequests,on_skip=>native,
        options=>#{profile=>bytes},weights=>[{native,70},{erlamsa,30}]}},
    case Mode of
        "semantic_persistent"->Base#{gleam_layer=>semantic_layer()};
        _->Base
    end;
config(_,C,_,_)->C.

semantic_layer()->#{adapter=>efz_qs_adapter,
    adapter_options=>#{fields=>32,component=>128},
    structured_fraction=>10,feedback=>guided,oracle=>disabled}.

bench_profile() -> os:getenv("EFZ_BENCH_PROFILE") =:= "1".

await_mutation(Worker) ->
    S=sys:get_state(Worker,10000),
    case maps:find(mutation_started_at,S) of
        {ok,T}->T;
        error->receive after 1->await_mutation(Worker) end
    end.

sample(Start,Deadline,Acc,Diag) ->
    Now=erlang:monotonic_time(microsecond),
    Snapshot=efz_fuzzer:benchmark_snapshot(),
    Complete=maps:get(completed,Snapshot,false),
    FuzzerState=sys:get_state(whereis(efz_fuzzer)),
    Worker=maps:get(worker,FuzzerState),
    Queue=case process_info(Worker,message_queue_len) of {message_queue_len,Q}->Q;_->0 end,
    Row=#{elapsed_us=>Now-Start,vm_memory_bytes=>erlang:memory(total),
        worker_queue=>Queue,target_coverage_count=>maps:get(coverage_count,Snapshot),
        mutation_executions=>maps:get(executions,maps:get(stats,Snapshot)),
        campaign_completed=>Complete,
        terminal_status=>maps:get(status,Snapshot,undefined)},
    Next=drain(Diag),
    case Complete orelse Now>=Deadline of
        true->{lists:reverse([Row|Acc]),Next,Now};
        false->receive after min(1000,max(1,(Deadline-Now) div 1000))->
            sample(Start,Deadline,[Row|Acc],Next) end
    end.

drain(D) -> receive
    {benchmark_decode,Kind,Bytes}->drain(D#{Kind=>maps:get(Kind,D)+1,
        input_bytes=>maps:get(input_bytes,D)+Bytes,input_max=>max(Bytes,maps:get(input_max,D))})
    after 0->D end.
quantile([],_) -> null;
quantile(L,P) -> Sorted=lists:sort(L),lists:nth(max(1,ceil(length(L)*P)),Sorted).
sample_percentiles(Samples,Key) ->
    Values=[V||Sample<-Samples,is_map(Sample),
        V<-[maps:get(Key,Sample,undefined)],is_integer(V),V>=0],
    #{samples=>length(Values),p50=>quantile(Values,0.5),p95=>quantile(Values,0.95),
      p99=>quantile(Values,0.99)}.
phase_percentiles(Phases) ->
    maps:from_list([{Key,value_percentiles(Values)}
        ||{Key,Values}<-maps:to_list(Phases),is_list(Values)]).
value_percentiles(Values) ->
    Valid=[V||V<-Values,is_integer(V),V>=0],
    #{samples=>length(Valid),p50=>quantile(Valid,0.5),p95=>quantile(Valid,0.95),
      p99=>quantile(Valid,0.99)}.
portable(B) when is_binary(B) ->
    case unicode:characters_to_binary(B,utf8,utf8) of
        B->B;
        _->#{hex=>binary:encode_hex(B,lowercase)}
    end;
portable(T) when is_tuple(T) -> [portable(X)||X<-tuple_to_list(T)];
portable(M) when is_map(M) -> maps:from_list([{key(K),portable(V)}||{K,V}<-maps:to_list(M)]);
portable(L) when is_list(L) -> [portable(X)||X<-L];
portable(A) when A=:=true;A=:=false;A=:=null -> A;
portable(A) when is_atom(A) -> atom_to_binary(A,utf8);
portable(N) -> N.
key(K) when is_atom(K) -> atom_to_binary(K,utf8);
key(K) when is_binary(K) -> K;
key(K) -> iolist_to_binary(io_lib:format("~tp",[K])).
