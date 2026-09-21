-module(efz_worker).
-behaviour(gen_server).
-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link(C) -> gen_server:start_link(?MODULE, C, []).
init(C) ->
    Builds = maps:from_list([{maps:get(module, M), maps:get(build_id, M)} || M <- maps:get(manifests, C)]),
    case maps:find(random_seed, C) of {ok, Seed} -> _ = rand:seed(exsplus, Seed), ok; error -> ok end,
    ExecutorOptions = case maps:get(coverage_validation, C) of
        per_execution -> reference;
        prepared ->
            {ok, Plan} = efz_cov_manifest:prepare(maps:get(coverage, C), maps:get(manifests, C)),
            (maps:with([runtime_oracles, coverage, coverage_backend, max_input_bytes, execution_identities], C))#{coverage_plan => Plan}
    end,
    MutationState = case maps:get(mutation_mode,C) of
        random->undefined; staged->efz_mutation_plan:new(maps:get(mutation,C))
    end,
    self() ! iterate,
    {ok, C#{pending_seeds => efz_corpus:all(), feedback => efz_feedback:new(Builds),
            verification_used=>0,runtime_store=>efz_runtime_store:new(),runtime_checks=>[],runtime_checks_dropped=>0,
            iteration => 0, decisions => [], crash_groups => #{}, crash_order => [],
            executor_options => ExecutorOptions, phase => calibration, mutation_state=>MutationState,
            mutation_trace=>[],trace_count=>0,coverage_seen=>sets:new(),coverage_empty=>0,coverage_broken=>0,coverage_unstarted=>0,
            calibration_started_at => erlang:monotonic_time(microsecond)}}.

handle_info(iterate, #{pending_seeds := [E | Rest]} = S) ->
    execute(maps:get(input, E), E, calibration, S#{pending_seeds => Rest});
handle_info(iterate, #{pending_seeds := [], phase := calibration} = S) ->
    case diagnostic(S) of
        #{status:=no_probes_observed}=D ->
            logger:warning("EFZ automatic coverage: calibration emitted no probes; mutation will continue. ~tp",[D]);
        _ -> ok
    end,
    self() ! iterate,
    {noreply, S#{phase => mutation, mutation_started_at => erlang:monotonic_time(microsecond)}};
handle_info(iterate, #{iteration := N, max_iterations := N} = S) -> finish(completed, S);
handle_info(iterate, #{mutation_mode := staged} = S) -> staged_iteration(S);
handle_info(iterate, #{mutator := Mu, iteration := N} = S) ->
    E = efz_corpus:select(),
    case try {ok,Mu:mutate(maps:get(input, E), #{iteration => N + 1, max_input_bytes => maps:get(max_input_bytes,S)})}
         catch Class:Reason->{error,{mutator,Class,Reason}} end of
        {ok,Input} when is_binary(Input)->execute(Input, E, mutation, S#{iteration => N + 1});
        Bad->infrastructure(Bad,S)
    end;
handle_info(_, S) -> {noreply, S}.

staged_iteration(S=#{mutation_state:=Plan,iteration:=N}) ->
    Choice=try efz_mutation_plan:next(Plan,efz_corpus:mutation_entries())
        catch Class:Reason->{error,{mutation_engine,Class,Reason},Plan} end,
    case Choice of
        {candidate,Input,P,Next}->
            Recipe=efz_recipe:make(P,Input,maps:get(mutation,S),maps:get(builds,maps:get(feedback,S))),
            S1=trace(Recipe,S#{mutation_state=>Next,current_recipe=>Recipe,iteration=>N+1}),
            execute(Input,#{id=>maps:get(parent,P)},mutation,S1);
        {skip,_,Next}->self()!iterate,{noreply,S#{mutation_state=>Next}};
        {done,idle_budget_exhausted,Next}->finish({mutation_stopped,idle_budget_exhausted},S#{mutation_state=>Next});
        {done,Why,Next}->finish({mutation_exhausted,Why},S#{mutation_state=>Next});
        {error,Why,Next}->infrastructure(Why,S#{mutation_state=>Next})
    end.
infrastructure(Why,S)->notify_context(maps:get(failure_context,S,undefined),S),
    Primary=efz_stats:failure(Why),finish({infrastructure_failure,Primary},S).
trace(R,S=#{trace_count:=N,mutation:=C,mutation_trace:=Ts})->
    case N<maps:get(trace_limit,C) of true->S#{trace_count=>N+1,mutation_trace=>[R|Ts]};false->S end.

execute(Input, Parent, Phase, S) ->
    Context = #{input=>Input,input_hash=>crypto:hash(sha256,Input),parent=>maps:get(id,Parent),phase=>Phase},
    WithRecipe = case maps:find(current_recipe,S) of {ok,R}->Context#{recipe=>R};error->Context end,
    S1 = S#{failure_context=>WithRecipe},
    notify_context(WithRecipe,S1),
    case efz_input:check(Input,maps:get(max_input_bytes,S),Phase) of
        ok -> execute_checked(Input,Parent,Phase,S1);
        {error,Why} -> infrastructure(Why,S1)
    end.
executor_reference_options(S)->maps:with([runtime_oracles,coverage,coverage_backend,
    max_input_bytes,execution_identities,manifests],S).
execute_checked(Input, Parent, Phase, S0 = #{target := M, timeout := T, feedback := F}) ->
    Options = case maps:get(executor_options, S0) of reference -> executor_reference_options(S0); Prepared -> Prepared end,
    Result = efz_executor:run(M, Input, T, Options#{execution_origin=>Phase}),
    runtime_stats(Result),
    S = observed(Result,S0#{failure_context=>(maps:get(failure_context,S0))#{result=>Result}}),
    notify_context(maps:get(failure_context,S),S),
    execute_result(Input, Parent, Phase, Result, F, S).
execute_result(Input, Parent, Phase, Result, F, S) ->
    efz_stats:inc(case Phase of calibration -> calibrations; mutation -> executions end),
    case efz_feedback:evaluate(F, Result, Phase) of
        {error, Why} ->
            infrastructure(Why,S);
        {ok, F1, Decision} ->
            Meta = Decision#{parent => maps:get(id, Parent), execution_ref => maps:get(execution_ref, Result),
                             input_id => crypto:hash(sha256, Input), builds => maps:get(builds, Result),
                             phase => Phase, origin => Phase, outcome => maps:get(outcome, Result),
                             execution_identities=>maps:get(execution_identities,S),
                             coverage_observation=>maps:get(coverage_observation,Result,#{})},
            WithMutation=case {Phase,maps:find(current_recipe,S)} of
                {mutation,{ok,Recipe}}->Meta#{mutation=>Recipe};_->Meta
            end,
            case retain(Input, WithMutation) of
                {error, Why} -> infrastructure(Why, S#{failure_context=>(maps:get(failure_context,S))#{metadata=>WithMutation}});
                Meta1 -> accepted(Input, Result, Meta1, F1, S)
            end
    end.
accepted(Input, Result, Meta1, F1, S) ->
    case record_failure(Input, Result, Meta1, S#{feedback => F1}) of
        {error,Why,S1} -> infrastructure(Why,S1);
        {ok,S1} -> runtime_check(Input,Result,Meta1,S1)
    end.
runtime_check(Input,Result,Meta,S=#{runtime_oracles:=#{enabled:=true}=P}) ->
    St=maps:get(stability,P),Cats=efz_runtime:categories(Result),
    Reason=maps:get(retention_reason,Meta),
    Key=case maps:get(phase,Meta) of
        calibration->seed_runs;
        mutation->case Reason of
            target_failure->failure_runs;
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
    R=efz_executor:run(M,Input,T,O#{execution_origin=>verification}),
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
    {noreply, maps:without([current_recipe,failure_context,crash_decision],S2)}.
notify_context(Context,S)->maps:get(coordinator,S)!{execution_context,self(),Context},ok.
decision_metadata(#{mutation:=Recipe}=Meta)->
    Meta#{mutation=>maps:with([stage,primary_id,config_id,output_hash],Recipe)};
decision_metadata(Meta)->Meta.
retain(Input, #{retention_reason := new_coverage} = Meta) ->
    case efz_corpus:add(Input, Meta) of
        {ok, Id} -> efz_stats:inc(discoveries), Meta#{corpus_id => Id};
        {existing, _} -> Meta#{retention_reason => existing_input};
        {error, Why} -> {error, Why}
    end;
retain(_, Meta) -> Meta.

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
observed(#{coverage_status:=ok,coverage:=Hits},S) ->
    Seen=sets:union(maps:get(coverage_seen,S),sets:from_list([M || {M,_,_}<-Hits])),
    Empty=case Hits of []->1;_->0 end,
    efz_stats:inc(case Hits of []->coverage_empty_executions;_->coverage_observed_executions end),
    S#{coverage_seen=>Seen,coverage_empty=>maps:get(coverage_empty,S)+Empty};
observed(_,S) ->
    efz_stats:inc(coverage_broken_observations),S#{coverage_broken=>maps:get(coverage_broken,S)+1}.
diagnostic(S) ->
    Ms=maps:get(manifests,S),Seen=maps:get(coverage_seen,S),
    #{policy=>maps:get(coverage_policy,S),
      status=>case maps:get(coverage,S) of
          manual->manual;automatic->case sets:size(Seen) of 0->no_probes_observed;_->observed end
      end,
      unused_artifacts=>[#{module=>M,build_id=>B} || #{module:=M,build_id:=B}<-Ms,not sets:is_element(M,Seen)],
      observed_modules=>lists:sort(sets:to_list(Seen)),
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
               coverage => lists:sort(sets:to_list(maps:get(global, maps:get(feedback, S))))},
    RuntimeReport=case maps:get(enabled,maps:get(runtime_oracles,S)) of
        false->#{};true->#{runtime_diagnostics=>#{policy=>maps:get(runtime_oracles,S),
            verification_executions=>maps:get(verification_used,S),checks=>lists:reverse(maps:get(runtime_checks,S)),
            checks_dropped=>maps:get(runtime_checks_dropped,S),findings=>efz_runtime_store:report(maps:get(runtime_store,S))}} end,
    Base = maps:merge(maps:merge(Base0,RuntimeReport),maps:with([failure_context,runtime_storage_error],S)),
    WithCorpus=case maps:find(corpus_store,S) of
        error->Base;
        {ok,Store}->Base#{corpus_restore=>maps:with([dir,build_policy,restored_inputs,diagnostics],Store)}
    end,
    Report=case maps:get(mutation_state,S) of
        undefined->WithCorpus;
        #{counts:=Counts}->WithCorpus#{mutation=>maps:get(mutation,S),mutation_stats=>Counts,
            mutation_initial_corpus=>[efz_mutation:hash(B)||B<-maps:get(seeds,S)],
            mutation_trace=>lists:reverse(maps:get(mutation_trace,S))}
    end,
    maps:get(coordinator, S) ! {campaign_done, self(), Report},
    {noreply, S}.
handle_call(_, _, S) -> {reply, ok, S}.
handle_cast(_, S) -> {noreply, S}.
terminate(_, _) -> ok.
code_change(_, S, _) -> {ok, S}.
