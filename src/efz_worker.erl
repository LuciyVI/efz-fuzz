-module(efz_worker).
-behaviour(gen_server).
-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link(C) -> gen_server:start_link(?MODULE, C, []).
init(C) ->
    Builds = maps:from_list([{maps:get(module, M), maps:get(build_id, M)} || M <- maps:get(manifests, C)]),
    Schema = case maps:get(coverage_backend, C) of
        bitmap -> {ok, PreparedSchema} = efz_coverage:prepare_schema(
            maps:get(manifests, C), maps:get(coverage_bitmap_bits, C)), PreparedSchema;
        otp_native_public -> efz_coverage:prepare_native(maps:get(manifests,C));
        _ -> undefined
    end,
    C1 = case Schema of undefined -> C; _ -> C#{coverage_schema => Schema} end,
    ReuseMap = case Schema of
        undefined -> undefined;
        #{kind:=otp_native_line} -> undefined;
        _ -> efz_coverage:allocate_execution(Schema)
    end,
    Feedback = case Schema of
        undefined -> case maps:get(coverage_backend,C) of
            none -> efz_feedback:new(Builds,none);
            _ -> efz_feedback:new(Builds, maps:get(coverage_feedback, C))
        end;
        #{kind:=otp_native_line} -> efz_feedback:new(Builds,presence,Schema);
        _ -> efz_feedback:new(Builds, presence, Schema)
    end,
    ProfileFeedback=case maps:get(performance_profile,C) of
        true -> Feedback#{performance_profile=>true}; false -> Feedback
    end,
    case maps:find(random_seed, C) of {ok, Seed} -> _ = rand:seed(exsplus, Seed), ok; error -> ok end,
    ExecutorOptions = case maps:get(coverage_backend,C1) of
        otp_native_public -> reference;
        none -> reference;
        _ -> case maps:get(coverage_validation, C1) of
        per_execution -> reference;
        prepared ->
            {ok, Plan} = efz_cov_manifest:prepare(maps:get(coverage, C1), maps:get(manifests, C1)),
            (maps:with([runtime_oracles, coverage, coverage_backend, coverage_feedback,
                        performance_profile,
                        coverage_schema, max_input_bytes, execution_identities], C1))#{coverage_plan => Plan}
        end
    end,
    MutationState = case maps:get(mutation_mode,C) of
        random->undefined; staged->efz_mutation_plan:new(maps:get(mutation,C))
    end,
    ok=efz_external_worker:ready(),
    self() ! iterate,
    Replay=maps:get(benchmark_replay_inputs,C,undefined),
    {ok, C1#{pending_seeds => case Replay of undefined -> efz_corpus:all(); _ -> [] end,
            replay_remaining=>Replay,
            feedback => ProfileFeedback,
            bitmap_reuse_map=>ReuseMap,bitmap_map_arms=>0,
            verification_used=>0,runtime_store=>efz_runtime_store:new(),runtime_checks=>[],runtime_checks_dropped=>0,
            iteration => 0, decisions => [], crash_groups => #{}, crash_order => [],
            executor_options => ExecutorOptions,
            phase => case Replay of undefined -> calibration; _ -> replay end,
            mutation_state=>MutationState,
            mutation_trace=>[],trace_count=>0,coverage_seen=>efz_coverage:new_global(),coverage_empty=>0,coverage_broken=>0,coverage_unstarted=>0,
            profile=>#{},input_size_buckets=>#{},input_bytes_total=>0,input_count=>0,
            calibration_started_at => erlang:monotonic_time(microsecond)}}.

handle_info(iterate, #{phase:=replay,replay_remaining:=[Input|Rest],iteration:=N}=S) ->
    execute(Input,#{id=>1},mutation,begin_iteration(S#{replay_remaining=>Rest,
                                                       iteration=>N+1}));
handle_info(iterate, #{phase:=replay,replay_remaining:=[]}=S) -> finish(completed,S);
handle_info(iterate, #{pending_seeds := [E | Rest]} = S) ->
    execute(maps:get(input, E), E, calibration, begin_iteration(S#{pending_seeds => Rest}));
handle_info(iterate, #{pending_seeds := [], phase := calibration} = S) ->
    case diagnostic(S) of
        #{status:=no_probes_observed}=D ->
            logger:warning("EFZ automatic coverage: calibration emitted no probes; mutation will continue. ~tp",[D]);
        _ -> ok
    end,
    self() ! iterate,
    {noreply, S#{phase => mutation, mutation_started_at => erlang:monotonic_time(microsecond)}};
handle_info(iterate, #{iteration := N, max_iterations := N} = S) -> finish(completed, S);
handle_info(iterate, #{mutation_mode := staged} = S) -> staged_iteration(begin_iteration(S));
handle_info(iterate, #{mutator := Mu, iteration := N} = S) ->
    S0=begin_iteration(S),Profile=maps:get(performance_profile,S0),
    {E,SelectUs}=efz_perf_profile:measure(Profile,fun efz_corpus:select/0),
    S1=efz_perf_profile:add_state(S0,corpus_select,SelectUs),
    {Mutation,MutationUs}=efz_perf_profile:measure(Profile,fun() ->
        try {ok,Mu:mutate(maps:get(input, E), #{iteration => N + 1, max_input_bytes => maps:get(max_input_bytes,S)})}
         catch Class:Reason->{error,{mutator,Class,Reason}} end
        end),
    S2=efz_perf_profile:add_state(S1,mutation,MutationUs),
    case Mutation of
        {ok,Input} when is_binary(Input)->execute(Input, E, mutation, S2#{iteration => N + 1});
        Bad->infrastructure(Bad,S2)
    end;
handle_info(_, S) -> {noreply, S}.

staged_iteration(S=#{mutation_state:=Plan,iteration:=N}) ->
    Profile=maps:get(performance_profile,S),
    {Choice,MutationUs}=efz_perf_profile:measure(Profile,fun() ->
        try efz_mutation_plan:next(Plan,efz_corpus:mutation_entries())
        catch Class:Reason->{error,{mutation_engine,Class,Reason},Plan} end
    end),
    S0=efz_perf_profile:add_state(S,mutation,MutationUs),
    case Choice of
        {candidate,Input,P,Next}->
            Recipe=efz_recipe:make(P,Input,maps:get(mutation,S0),maps:get(builds,maps:get(feedback,S0))),
            S1=trace(Recipe,S0#{mutation_state=>Next,current_recipe=>Recipe,iteration=>N+1}),
            execute(Input,#{id=>maps:get(parent,P)},mutation,S1);
        {skip,_,Next}->self()!iterate,{noreply,S0#{mutation_state=>Next}};
        {done,idle_budget_exhausted,Next}->finish({mutation_stopped,idle_budget_exhausted},S0#{mutation_state=>Next});
        {done,Why,Next}->finish({mutation_exhausted,Why},S0#{mutation_state=>Next});
        {error,Why,Next}->infrastructure(Why,S0#{mutation_state=>Next})
    end.
infrastructure(Why,S)->notify_context(maps:get(failure_context,S,undefined),S),
    Primary=efz_stats:failure(Why),finish({infrastructure_failure,Primary},S).
trace(R,S=#{trace_count:=N,mutation:=C,mutation_trace:=Ts})->
    case N<maps:get(trace_limit,C) of true->S#{trace_count=>N+1,mutation_trace=>[R|Ts]};false->S end.

execute(Input, Parent, Phase, S) ->
    case efz_external_worker:quarantined(Input) of
        true->self()!iterate,{noreply,S};false->execute_allowed(Input,Parent,Phase,S)
    end.
execute_allowed(Input, Parent, Phase, S) ->
    Profile=maps:get(performance_profile,S),
    {Prepared,PrepUs}=efz_perf_profile:measure(Profile,fun() ->
    Context = #{input=>Input,input_hash=>crypto:hash(sha256,Input),parent=>maps:get(id,Parent),phase=>Phase},
    WithRecipe = case maps:find(current_recipe,S) of {ok,R}->Context#{recipe=>R};error->Context end,
    S1 = S#{failure_context=>WithRecipe},
    notify_context(WithRecipe,S1),
    {efz_input:check(Input,maps:get(max_input_bytes,S),Phase),S1}
    end),
    {Check,PreparedS}=Prepared,
    S2=efz_perf_profile:add_state(PreparedS,input_preparation,PrepUs),
    case Check of
        ok -> execute_checked(Input,Parent,Phase,S2);
        {error,Why} -> infrastructure(Why,S2)
    end.
executor_reference_options(S)->maps:with([runtime_oracles,coverage,coverage_backend,coverage_feedback,
    performance_profile,
    coverage_schema,max_input_bytes,execution_identities,manifests],S).
execute_checked(Input, Parent, Phase, S0 = #{target := M, timeout := T, feedback := F}) ->
    Options0 = case maps:get(executor_options, S0) of reference -> executor_reference_options(S0); Prepared -> Prepared end,
    Options=case maps:get(bitmap_reuse_map,S0) of
        undefined -> Options0;
        Map -> Options0#{coverage_reuse_map=>Map,
            coverage_compact=>not maps:get(enabled,maps:get(runtime_oracles,S0))}
    end,
    Profile=maps:get(performance_profile,S0),
    {Result,ExecutorUs}=efz_perf_profile:measure(Profile,fun() ->
        efz_executor:run(M, Input, T, Options#{execution_origin=>Phase,
            execution_recipe=>maps:get(current_recipe,S0,undefined)}) end),
    SExec=efz_perf_profile:add_state(S0,executor,ExecutorUs),
    SProfile=case maps:find(performance_profile,Result) of
        {ok,Times} when Profile ->
            WithTimes=maps:fold(fun(K,V,Acc)->
                efz_perf_profile:add_state(Acc,K,V) end,SExec,Times),
            efz_perf_profile:add_state(WithTimes,executor_outer_us,
                max(0,ExecutorUs-maps:get(guardian_total_us,Times,0)));
        _ -> SExec
    end,
    SInput=case Profile of
        true -> SProfile#{profile_input_bucket=>input_bucket(byte_size(Input)),
                          profile_input_bytes=>byte_size(Input),
                          profile_target_us=>maps:get(target_us,maps:get(performance_profile,Result,#{}),0)};
        false -> SProfile
    end,
    runtime_stats(Result),
    Arms=maps:get(bitmap_map_arms,SInput)+case maps:get(bitmap_map_armed,Result,false) of true->1;false->0 end,
    S = observed(Result,SInput#{bitmap_map_arms=>Arms,
        failure_context=>(maps:get(failure_context,S0))#{result=>public_result(Result)}}),
    notify_context(maps:get(failure_context,S),S),
    finish_iteration(execute_result(Input, Parent, Phase, Result, F, S)).
execute_result(Input, Parent, Phase, Result, F, S) ->
    efz_stats:inc(case Phase of calibration -> calibrations; mutation -> executions end),
    Profile=maps:get(performance_profile,S),
    {Evaluation,FeedbackUs}=efz_perf_profile:measure(Profile,
        fun()->efz_feedback:evaluate(F, Result, Phase) end),
    S1=efz_perf_profile:add_state(S,feedback,FeedbackUs),
    case Evaluation of
        {error, Why} ->
            infrastructure(Why,diagnostic_failure_context(Result,S1));
        {ok, F1, Decision} ->
            SFeedback=case {Profile,maps:get(outcome,Result),maps:find(profile_last,F1)} of
                {true,{ok,_},{ok,Times}} -> maps:fold(fun(K,V,Acc)->
                    efz_perf_profile:add_state(Acc,K,V) end,S1,Times);
                _ -> S1
            end,
            Meta = Decision#{parent => maps:get(id, Parent), execution_ref => maps:get(execution_ref, Result),
                             input_id => crypto:hash(sha256, Input), builds => maps:get(builds, Result),
                             phase => Phase, origin => Phase, outcome => maps:get(outcome, Result),
                             execution_identities=>maps:get(execution_identities,SFeedback),
                             coverage_observation=>maps:get(coverage_observation,Result,#{})},
            WithMutation=case {Phase,maps:find(current_recipe,SFeedback)} of
                {mutation,{ok,Recipe}}->Meta#{mutation=>Recipe};_->Meta
            end,
            semantic_result(Input,Result,WithMutation,F1,SFeedback,Profile)
    end.

semantic_result(Input,Result,Meta,F1,S,Profile) ->
    case semantic_callbacks(Input,Result,Meta,S) of
        {error,Why,SFailed}->infrastructure(Why,SFailed);
        {ok,WithSemantic,SFeedback}->
            {RetentionData,CorpusUs}=efz_perf_profile:measure(Profile,
                fun()->case maps:get(phase,SFeedback) of
                    replay -> {WithSemantic,0};
                    _ -> retain_layer(Input,WithSemantic,Profile,SFeedback)
                end end),
            {Retention,StoreUs}=RetentionData,
            S2=efz_perf_profile:add_state(
                efz_perf_profile:add_state(SFeedback,corpus_decision,CorpusUs),
                corpus_store,StoreUs),
            case Retention of
                {error, Why} ->
                    FailureState=diagnostic_failure_context(Result,S2),
                    infrastructure(Why,FailureState#{failure_context=>
                        (maps:get(failure_context,FailureState))#{metadata=>WithSemantic}});
                Meta1 -> accepted(Input, public_result(Result), Meta1, F1, S2)
            end
    end.

%% Off path creates no semantic state and performs no callback or random draw.
semantic_callbacks(_,_,Meta,#{gleam_layer:=false}=S)->{ok,Meta,S};
semantic_callbacks(Input,Result,Meta,S=#{gleam_layer:=P}) ->
    %% Persist real target failures first, independently of layer/admission.
    Public=public_result(Result),
    Counted=case maps:get(outcome,Public) of
        {ok,rejected}->layer_count(expected_rejections,S);
        {timeout,_}->layer_count(target_timeouts,S);
        {crash,_,_,_}->layer_count(target_exceptions,S);
        {exit,_}->layer_count(target_exceptions,S);
        _->S end,
    case record_failure(Input,Public,Meta,Counted) of
        {error,Why,S1}->{error,Why,S1};
        {ok,S1}->semantic_observe(Input,Public,Meta,S1#{target_failure_recorded=>true},P)
    end.
semantic_observe(Input,Result,Meta,S,P) ->
    {Observation,Cost}=timed(fun()->case maps:get(feedback,P) of
        disabled->{ok,[]};
        _->efz_gleam_adapter:observe(Input,maps:get(outcome,Result),efz_gleam_adapter:limits(P))
    end end),
    S0=case maps:get(feedback,P) of disabled->S;_->layer_count(observer_calls,layer_time(observer_us,Cost,S)) end,
    case Observation of
        {ok,Fs}->semantic_oracle(Input,Result,case maps:get(feedback,P) of
            disabled->Meta;_->Meta#{semantic=>efz_semantic:metadata(Fs)} end,S0,P);
        {skip,Why}->semantic_oracle(Input,Result,Meta#{semantic_observation=>{skipped,Why}},layer_count(observer_skipped,S0),P);
        {error,Why}->{error,{semantic_layer_error,Why},layer_count(layer_errors,S0)}
    end.
semantic_oracle(_,_,Meta,S,#{oracle:=disabled})->{ok,Meta,S};
semantic_oracle(Input,Result,Meta,S,P) ->
    Used=maps:get(oracle_used,S,0),
    case Used>=maps:get(oracle_budget,P) of
        true->{ok,Meta#{oracle=>{inconclusive,budget}},layer_count(oracle_skipped,S)};
        false ->
            {Check,Cost}=timed(fun()->efz_gleam_adapter:oracle(Input,maps:get(outcome,Result),efz_gleam_adapter:limits(P)) end),
            S0=layer_count(oracle_checks,layer_time(oracle_us,Cost,S#{oracle_used=>Used+1})),
            case Check of
                {error,Why}->{error,{semantic_layer_error,Why},layer_count(layer_errors,S0)};
                {fail,Property} ->
                    FindingMeta=Meta#{finding_kind=>oracle_failure,property=>{Property,1},
                        layer_versions=>efz_gleam_adapter:versions(),gleam_layer=>P,
                        target_original_outcome=>maps:get(outcome,Result)},
                    Finding=Result#{outcome=>{crash,oracle_failure,{Property,1},[]}},
                    case record_failure(Input,Finding,FindingMeta,S0) of
                        {ok,S1}->{ok,Meta#{oracle=>Check},layer_count(oracle_failures,S1)};
                        {error,Why,S1}->{error,Why,S1}
                    end;
                {pass,_}->{ok,Meta#{oracle=>Check},layer_count(oracle_passes,S0)};
                {inconclusive,_}->{ok,Meta#{oracle=>Check},layer_count(oracle_inconclusive,S0)}
            end
    end.
timed(F)->Start=erlang:monotonic_time(microsecond),R=F(),{R,erlang:monotonic_time(microsecond)-Start}.
layer_count(K,S)->Cs=maps:get(gleam_stats,S,#{}),S#{gleam_stats=>Cs#{K=>maps:get(K,Cs,0)+1}}.
layer_time(K,V,S)->Cs=maps:get(gleam_stats,S,#{}),S#{gleam_stats=>Cs#{K=>maps:get(K,Cs,0)+V}}.
retain_layer(Input,Meta,Profile,#{gleam_layer:=#{feedback:=guided}}) ->
    case {maps:get(outcome,Meta),maps:find(semantic,Meta)} of
        {{ok,_},{ok,_}} ->
            Keep=lists:member(maps:get(retention_reason,Meta),[new_coverage,new_probe,new_hit_count]),
            {Admission,StoreUs}=efz_perf_profile:measure(Profile,fun()->
                efz_corpus:admit_semantic(Input,Meta,efz_semantic:features(Meta),Keep) end),
            R=case Admission of
                {ok,Id,M}->efz_stats:inc(discoveries),M#{corpus_id=>Id};
                {existing,Id,M}->case maps:get(phase,Meta) of
                    calibration->M#{corpus_id=>Id};_->M#{corpus_id=>Id,retention_reason=>
                        case Keep of true->existing_input;false->equivalent_coverage end} end;
                {rejected,M}->M;
                {error,Why}->{error,Why}
            end,
            {R,StoreUs};
        _ -> retain(Input,Meta,Profile)
    end;
retain_layer(Input,Meta,Profile,_)->retain(Input,Meta,Profile).

begin_iteration(#{performance_profile:=true}=S) ->
    S#{profile_iteration_start=>erlang:monotonic_time(microsecond),
       profile_iteration_totals=>maps:map(fun(_,V)->maps:get(total_us,V) end,
                                          maps:get(profile,S))};
begin_iteration(S) -> S.
finish_iteration({noreply,#{performance_profile:=true,profile_iteration_start:=Start}=S}) ->
    Total=erlang:monotonic_time(microsecond)-Start,
    Profile=maps:get(profile,S),
    Before=maps:get(profile_iteration_totals,S),
    Accounted=lists:sum([maps:get(total_us,maps:get(K,Profile,#{total_us=>0}))-
                         maps:get(K,Before,0) ||
        K <- [corpus_select,mutation,input_preparation,executor,feedback,corpus_decision]]),
    S1=efz_perf_profile:add_state(S,iteration_total,Total),
    S2=efz_perf_profile:add_state(S1,worker_unaccounted,max(0,Total-Accounted)),
    Bucket=maps:get(profile_input_bucket,S2),
    Buckets=maps:get(input_size_buckets,S2),
    Old=maps:get(Bucket,Buckets,#{count=>0,total_iteration_us=>0,total_target_us=>0}),
    New=Old#{count=>maps:get(count,Old)+1,
             total_iteration_us=>maps:get(total_iteration_us,Old)+Total,
             total_target_us=>maps:get(total_target_us,Old)+maps:get(profile_target_us,S2)},
    {noreply,S2#{input_size_buckets=>Buckets#{Bucket=>New},
                 input_bytes_total=>maps:get(input_bytes_total,S2)+maps:get(profile_input_bytes,S2),
                 input_count=>maps:get(input_count,S2)+1}};
finish_iteration(Other) -> Other.

input_bucket(N) when N=<64 -> '0_64';
input_bucket(N) when N=<256 -> '65_256';
input_bucket(N) when N=<1024 -> '257_1024';
input_bucket(N) when N=<4096 -> '1025_4096';
input_bucket(_) -> 'over_4096'.
accepted(Input, Result, Meta1, F1, S) ->
    case maps:get(target_failure_recorded,S,false) of
        true->runtime_check(Input,Result,Meta1,S#{feedback=>F1});
        false->case record_failure(Input, Result, Meta1, S#{feedback => F1}) of
        {error,Why,S1} -> infrastructure(Why,S1);
        {ok,S1} -> runtime_check(Input,Result,Meta1,S1)
        end
    end.
runtime_check(Input,Result,Meta,S=#{runtime_oracles:=#{enabled:=true}=P}) ->
    St=maps:get(stability,P),Cats=efz_runtime:categories(Result),
    Reason=maps:get(retention_reason,Meta),
    Key=case maps:get(phase,Meta) of
        calibration->seed_runs;
        mutation->case Reason of
            target_failure->failure_runs;
            new_hit_count->interesting_runs;
            _->case Cats--[descendant_activity] of
                [_|_]->suspicious_runs;
                []->case maps:get(new_probes,Meta,[]) of []->none;_->interesting_runs end
            end
        end
    end,
    Requested=case maps:get(enabled,St) andalso Key=/=none of true->maps:get(Key,St);false->1 end,
    efz_stats:add(verification_requested,Requested-1),
    Left=max(0,maps:get(max_extra_executions,St)-maps:get(verification_used,S)),
    Begin=erlang:monotonic_time(microsecond),
    Rows=[efz_stability:snapshot(Result,P)],
    case verify(Input,Meta,min(Requested-1,Left),Rows,S) of
        {Status,All,S1}->
            Summary=efz_stability:summarize(All,Requested),
            efz_stats:add(verification_skipped,maps:get(skipped,Summary)),
            Admissible=[R||R<-All,maps:get(completed,R)],
            RuntimeCats=lists:usort(lists:append([maps:get(categories,maps:get(runtime,R),[])||R<-Admissible])),
            Categories=lists:usort(RuntimeCats++maps:get(categories,Summary)),
            Reproductions=maps:from_list([{C,length([ok||R<-Admissible,lists:member(C,maps:get(categories,maps:get(runtime,R),[]))])}||C<-RuntimeCats]),
            Check=Summary#{input_hash=>crypto:hash(sha256,Input),origin=>maps:get(phase,Meta),reproductions=>Reproductions,
                diagnostic_us=>erlang:monotonic_time(microsecond)-Begin},
            S2=remember_check(Check,S1),
            Stored=save_runtime(Categories,Input,Result,Meta,Check,S2),
            efz_stats:add(runtime_diagnostic_us,erlang:monotonic_time(microsecond)-Begin),
            case Stored of
                {ok,S3}->case Status of ok->accepted_success(Meta,S3);{error,Why}->infrastructure(Why,S3) end;
                {error,Why,S3}->case Status of
                    ok->infrastructure(Why,S3);
                    {error,Primary}->infrastructure(Primary,S3#{runtime_storage_error=>Why}) end
            end
    end;
runtime_check(_,_,Meta,S)->accepted_success(Meta,S).
verify(_,_,0,Rows,S)->{ok,lists:reverse(Rows),S};
verify(Input,Meta,N,Rows,S=#{runtime_oracles:=P,target:=M,timeout:=T})->
    O=case maps:get(executor_options,S) of reference->executor_reference_options(S);Prepared->Prepared end,
    VContext=(maps:get(failure_context,S))#{phase=>verification,origin=>verification},
    notify_context(maps:remove(result,VContext),S),
    R=public_result(efz_executor:run(M,Input,T,O#{execution_origin=>verification,
        execution_recipe=>maps:get(mutation,Meta,undefined)})),
    efz_stats:inc(verification_executions),
    efz_stats:add(verification_elapsed_us,maps:get(elapsed_us,R,0)),
    runtime_stats(R),
    S1=S#{verification_used=>maps:get(verification_used,S)+1,failure_context=>VContext#{result=>R}},
    notify_context(maps:get(failure_context,S1),S1),
    Next=[efz_stability:snapshot(R,P)|Rows],
    case efz_stability:failure(R) of
        {error,Why}->efz_stats:inc(verification_failed),{ {error,Why},lists:reverse(Next),
            S1#{failure_context=>(maps:get(failure_context,S1))#{origin=>verification,result=>R}}};
        ok->
            efz_stats:inc(verification_completed),
            case efz_stability:usable(R) of true->efz_stats:inc(verification_valid);false->ok end,
            VMeta=Meta#{origin=>verification,phase=>verification,outcome=>maps:get(outcome,R),
                execution_ref=>maps:get(execution_ref,R),new_probes=>[],retention_reason=>target_failure},
            SavedDecision=maps:get(crash_decision,S1,false),
            case record_failure(Input,R,VMeta,S1) of
                {ok,S2}->verify(Input,Meta,N-1,Next,S2#{crash_decision=>SavedDecision});
                {error,Why,S2}->{{error,Why},lists:reverse(Next),S2}
            end
    end.
runtime_stats(#{runtime_observations:=R})->
    case maps:get(sampling_status,R) of
        sampled->efz_stats:inc(runtime_sampled_executions);
        not_sampled->efz_stats:inc(runtime_missed_executions);
        disabled->ok end,
    efz_stats:add(runtime_sampling_us,maps:get(sampling_us,R)),
    efz_stats:add(runtime_max_buffer_bytes,maps:get(diagnostic_buffer_bytes,R));
runtime_stats(_)->ok.
remember_check(Check,S)->
    %% Summaries are bounded independently from disk. Probe arrays may be large;
    %% enforce byte quota before retaining them in the report.
    Limit=maps:get(max_total_metadata_bytes,maps:get(storage,maps:get(runtime_oracles,S))),
    Size=erlang:external_size(Check),Used=maps:get(runtime_report_bytes,S,0),
    case length(maps:get(runtime_checks,S))<128 andalso Used+Size=<Limit of
        true->S#{runtime_checks=>[Check|maps:get(runtime_checks,S)],runtime_report_bytes=>Used+Size};
        false->S#{runtime_checks_dropped=>maps:get(runtime_checks_dropped,S)+1}
    end.
save_runtime([],_,_,_,_,S)->{ok,S};
save_runtime([Cat|Rest],Input,Result,Meta,Check,S)->
    P=maps:get(runtime_oracles,S),
    #{harness:=HI}=maps:get(execution_identities,Result),
    Harness=(maps:with([beam_md5,attributes_sha256,build_id],HI))#{module=>atom_to_binary(maps:get(module,HI),utf8)},
    Origin=case lists:member(Cat,efz_runtime:categories(Result)) orelse
        lists:member(Cat,maps:get(categories,Check)) of true->maps:get(phase,Meta);false->verification end,
    Scope=case Cat of vm_memory_growth_suspected->vm_global;_->target_owned end,
    Record=#{coverage_mode=>maps:get(coverage,S),category=>Cat,scope=>Scope,origin=>Origin,harness=>Harness,
        target_builds=>efz_recipe:build_ids(maps:get(builds,Result)),policy=>P,
        max_input_bytes=>maps:get(max_input_bytes,S),timeout=>maps:get(timeout,S),
        original_outcome=>efz_runtime_store:portable(efz_stability:outcome(maps:get(outcome,Result))),
        evidence=>efz_runtime_store:portable(Check),mutation=>maps:get(mutation,Meta,undefined)},
    Dir=filename:join(filename:dirname(maps:get(crash_dir,S)),"runtime-findings"),
    case efz_runtime_store:save(Dir,Input,Record,maps:get(storage,P),maps:get(runtime_store,S)) of
        {ok,Store}->save_runtime(Rest,Input,Result,Meta,Check,S#{runtime_store=>Store});
        {error,Why}->{error,Why,S}
    end.
accepted_success(Meta1,S1) ->
    %% Bound report memory: retain decisions that explain calibration,
    %% retention/failure; equivalent repetitions counted in statistics.
    S2 = case maps:get(retention_reason, Meta1) of
        equivalent_coverage -> efz_stats:inc(rejections), S1;
        target_failure -> case maps:get(crash_decision,S1,false) of
            false->S1;
            Identity->S1#{decisions=>[maps:merge(decision_metadata(Meta1),Identity)|maps:get(decisions,S1)]}
        end;
        _ -> S1#{decisions => [decision_metadata(Meta1) | maps:get(decisions, S1)]}
    end,
    notify_context(undefined,S2),
    self() ! iterate,
    {noreply, maps:without([current_recipe,failure_context,crash_decision,target_failure_recorded],S2)}.
notify_context(Context,S)->maps:get(coordinator,S)!{execution_context,self(),Context},ok.
decision_metadata(#{mutation:=Recipe}=Meta)->
    Meta#{mutation=>maps:with([stage,primary_id,config_id,output_hash],Recipe)};
decision_metadata(Meta)->Meta.
retain(Input, #{retention_reason := Reason} = Meta,Profile)
  when Reason=:=new_coverage; Reason=:=new_probe; Reason=:=new_hit_count ->
    {Add,StoreUs}=efz_perf_profile:measure(Profile,fun()->efz_corpus:add(Input,Meta) end),
    Result=case Add of
        {ok, Id} -> efz_stats:inc(discoveries),
                    case Reason of new_hit_count->efz_stats:inc(count_only_discoveries);_->ok end,
                    Meta#{corpus_id => Id};
        {existing, _} -> Meta#{retention_reason => existing_input};
        {error, Why} -> {error, Why}
    end,
    {Result,StoreUs};
retain(_, Meta,_) -> {Meta,0}.

record_failure(Input, #{outcome := Outcome} = Result, Meta, S) ->
    case Outcome of
        {ok, _} -> {ok,S};
        _ ->
            efz_stats:inc(case Outcome of {timeout, _} -> timeouts; _ -> crashes end),
            efz_stats:inc(crash_occurrences),
            Identity=efz_crash:identify(Input,Result,maps:get(crash_policy,S)),
            case efz_crash:save(Input,Result,Meta,(maps:with([crash_dir,max_input_bytes,crash_policy],S))#{crash_identity=>Identity}) of
                {ok,Crash} -> {ok,remember_crash(Crash,S)};
                {error,Why} ->
                    Crash0 = Identity#{input=>Input,result=>Result,
                              metadata=>Meta,storage=>{error,Why}},
                    Crash=case maps:find(saved_artifact,Why) of
                        {ok,Path}->Crash0#{path=>Path};error->Crash0 end,
                    Context = (maps:get(failure_context,S))#{metadata=>Meta,storage_error=>Why},
                    {error,Why,remember_crash(Crash,S#{failure_context=>Context})}
            end
    end.
remember_crash(Crash,S) ->
    Limit=maps:get(max_representatives,maps:get(crash_policy,S)),
    {New,Representative,Groups}=efz_crash:remember(Crash,maps:get(crash_groups,S),Limit),
    Order=maps:get(crash_order,S),
    case New of true->efz_stats:inc(unique_crashes);false->ok end,
    S#{crash_groups=>Groups,crash_order=>case New of true->[maps:get(group_id,Crash)|Order];false->Order end,
        crash_decision=>case Representative of
            true->maps:with([occurrence_id,input_hash,signature_id,group_id],Crash);false->false end}.
observed(#{coverage_status:=ok,coverage_observation:=#{classification:=unstarted_coverage_observation}},S) ->
    efz_stats:inc(coverage_unstarted_executions),S#{coverage_unstarted=>maps:get(coverage_unstarted,S)+1};
observed(#{coverage_status:=ok,coverage_count:=Count,coverage_modules:=Modules},S) ->
    Seen=sets:union(maps:get(coverage_seen,S),sets:from_list(Modules)),
    Empty=case Count of 0->1;_->0 end,
    efz_stats:inc(case Count of 0->coverage_empty_executions;_->coverage_observed_executions end),
    S#{coverage_seen=>Seen,coverage_empty=>maps:get(coverage_empty,S)+Empty};
observed(#{coverage_status:=ok,coverage:=Hits},S) ->
    Seen=efz_coverage:modules_seen(maps:get(coverage_seen,S),Hits),
    Empty=case Hits of []->1;_->0 end,
    efz_stats:inc(case Hits of []->coverage_empty_executions;_->coverage_observed_executions end),
    S#{coverage_seen=>Seen,coverage_empty=>maps:get(coverage_empty,S)+Empty};
observed(_,S) ->
    efz_stats:inc(coverage_broken_observations),S#{coverage_broken=>maps:get(coverage_broken,S)+1}.
diagnostic(S) ->
    Ms=maps:get(manifests,S),Seen=maps:get(coverage_seen,S),
    #{policy=>maps:get(coverage_policy,S),
      status=>case {maps:get(coverage_backend,S),maps:get(coverage,S)} of
          {none,_}->disabled;
          {_,manual}->manual;
          {_,automatic}->case efz_coverage:observed_modules(Seen) of []->no_probes_observed;_->observed end
      end,
      unused_artifacts=>efz_coverage:missing_modules(Seen,Ms),
      observed_modules=>efz_coverage:observed_modules(Seen),
      empty_executions=>maps:get(coverage_empty,S),broken_observations=>maps:get(coverage_broken,S),
      unstarted_executions=>maps:get(coverage_unstarted,S)}.
diagnostic_status({infrastructure_failure,_}=Status,_) -> Status;
diagnostic_status(Status,#{policy:=strict,status:=no_probes_observed}=D) ->
    Why=#{kind=>coverage_not_observed,diagnostic=>D,stop_reason=>Status},
    {infrastructure_failure,efz_stats:failure(Why)};
diagnostic_status(Status,_) -> Status.
finish(Status0, S) ->
    Diagnostic=diagnostic(S),Status=diagnostic_status(Status0,Diagnostic),
    End = erlang:monotonic_time(microsecond),
    MutationStart = maps:get(mutation_started_at, S, End),
    CalibrationStart = maps:get(calibration_started_at, S),
    Timing = #{calibration_started_at => CalibrationStart,
               calibration_us => MutationStart - CalibrationStart,
               mutation_us => End - MutationStart},
    Base0 = #{max_input_bytes=>maps:get(max_input_bytes,S), status => Status, timing => Timing, stats => efz_stats:get(), corpus => efz_corpus:all(),
               execution_identities=>maps:get(execution_identities,S),coverage_diagnostics=>Diagnostic,
               decisions => lists:reverse(maps:get(decisions, S)),
               crash_policy=>maps:get(crash_policy,S),
               crashes => [maps:get(Id,maps:get(crash_groups,S))||Id<-lists:reverse(maps:get(crash_order,S))],
               coverage => efz_coverage:global_snapshot(maps:get(global, maps:get(feedback, S)))},
    ProfileReport=case maps:get(performance_profile,S) of
        true -> #{performance_profile=>efz_perf_profile:summary(maps:get(profile,S)),
                  input_size_buckets=>maps:get(input_size_buckets,S)};
        false -> #{}
    end,
    Feedback=maps:get(feedback,S),
    CoverageReport=case maps:get(coverage_feedback,S) of
        presence->#{coverage_feedback=>presence};
        hit_count->#{coverage_feedback=>hit_count,
            count_features=>efz_coverage:global_snapshot(maps:get(global_features,Feedback))}
    end,
    RuntimeReport=case maps:get(enabled,maps:get(runtime_oracles,S)) of
        false->#{};true->#{runtime_diagnostics=>#{policy=>maps:get(runtime_oracles,S),
            verification_executions=>maps:get(verification_used,S),checks=>lists:reverse(maps:get(runtime_checks,S)),
            checks_dropped=>maps:get(runtime_checks_dropped,S),findings=>efz_runtime_store:report(maps:get(runtime_store,S))}} end,
    BitmapReport=case maps:get(bitmap_reuse_map,S) of
        undefined -> #{};
        _ -> #{bitmap_storage=>#{execution_maps_allocated=>1,
                 execution_map_arms=>maps:get(bitmap_map_arms,S),
                 normal_reuses=>max(0,maps:get(bitmap_map_arms,S)-1)}}
    end,
    Base = maps:merge(maps:merge(maps:merge(maps:merge(maps:merge(Base0,CoverageReport),RuntimeReport),BitmapReport),ProfileReport),
                      maps:with([failure_context,runtime_storage_error],S)),
    WithCorpus=case maps:find(corpus_store,S) of
        error->Base;
        {ok,Store}->Base#{corpus_restore=>maps:with([dir,build_policy,restored_inputs,diagnostics],Store)}
    end,
    Report0=case maps:get(mutation_state,S) of
        undefined->WithCorpus;
        #{counts:=Counts}->WithCorpus#{mutation=>maps:get(mutation,S),mutation_stats=>Counts,
            mutation_initial_corpus=>[efz_mutation:hash(B)||B<-maps:get(seeds,S)],
            mutation_trace=>lists:reverse(maps:get(mutation_trace,S))}
    end,
    Report=case maps:get(gleam_layer,S) of
        false->Report0;
        P->Plan=maps:get(mutation_state,S),Report0#{gleam_layer=>P,
            gleam_stats=>maps:get(gleam_stats,S,#{}),
            structured_stats=>case Plan of undefined->#{};_->maps:get(structured_counts,Plan,#{}) end,
            semantic_features=>case maps:get(feedback,P) of guided->efz_corpus:semantic_state();_->[] end,
            oracle_extra_executions=>0}
    end,
    maps:get(coordinator, S) ! {campaign_done, self(), Report},
    {noreply, S}.
handle_call(benchmark_snapshot, _, S) ->
    Global = maps:get(global, maps:get(feedback, S)),
    {reply, #{stats => efz_stats:get(),
              coverage_count => length(efz_coverage:global_snapshot(Global)),
              corpus_size => efz_corpus:size(),
              execution_map_arms => maps:get(bitmap_map_arms, S),
              execution_maps_allocated => case maps:get(bitmap_reuse_map, S) of
                  undefined -> 0; _ -> 1 end,
              performance_profile => case maps:get(performance_profile,S) of
                  true -> efz_perf_profile:summary(maps:get(profile,S));
                  false -> disabled end,
              input_size_buckets=>maps:get(input_size_buckets,S),
              input_bytes_total=>maps:get(input_bytes_total,S),
              input_count=>maps:get(input_count,S),
              completed => false}, S};
handle_call(benchmark_coverage, _, S) ->
    Global = maps:get(global, maps:get(feedback, S)),
    {reply, efz_coverage:global_snapshot(Global), S};
handle_call(_, _, S) -> {reply, ok, S}.
handle_cast(_, S) -> {noreply, S}.
terminate(_, S) ->
    case maps:find(coverage_schema, S) of
        {ok, Schema} -> _ = catch efz_coverage:release_schema(Schema), ok;
        error -> ok
    end.
code_change(_, S, _) -> {ok, S}.

public_result(Result) -> maps:without([coverage_bits,coverage_sealed,bitmap_map_armed], Result).

%% Exact IDs are materialized only for exceptional failure evidence.
diagnostic_failure_context(#{coverage_sealed:=Sealed}=Result,S=#{coverage_schema:=Schema}) ->
    Public=public_result(Result),
    Evidence=case efz_coverage:diagnostic_snapshot(Sealed) of
        {ok,Bits} -> case efz_coverage:decode_new(Schema,Bits) of
            {ok,Ids} -> Public#{coverage=>Ids};
            _ -> Public
        end;
        _ -> Public
    end,
    S#{failure_context=>(maps:get(failure_context,S))#{result=>Evidence}};
diagnostic_failure_context(_,S) -> S.
