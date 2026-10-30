%% One independent lifecycle owner per local VM. No target code runs here.
%% The controlled tree is created here, not inferred from links. Tracing is
%% a guard against uncontrolled local spawn, not automatic context injection.
-module(efz_guardian).
-export([run/6, status/0, poison/1]).
-define(DIRTY, {?MODULE, dirty_runner}).
-define(CLEANUP_MS, 1000).

status() -> persistent_term:get(?DIRTY, ready).
poison(Why) -> persistent_term:put(?DIRTY, {dirty, Why}), ok.

run(Caller, Request, M, Input, Timeout, Options) ->
    %% Application master shutdown also kills unlinked processes in its IO
    %% group. Leave that group before creating any target lifecycle resources.
    true = group_leader(whereis(user), self()),
    case catch register(efz_execution_guardian, self()) of
        true ->
            case status() of
                ready ->
                    case efz_cov_integrity:validate(maps:get(execution_identities,Options)) of
                        ok -> start(Caller, Request, M, Input, Timeout, Options);
                        {error,Why} -> reply(Caller,Request,(rejected(Why))#{
                            builds=>efz_executor:builds(Options),runner_reusable=>true,
                            execution_identities=>maps:get(execution_identities,Options),
                            coverage_status=>{error,Why},
                            coverage_observation=>efz_cov_integrity:observation([],{error,Why},[])})
                    end;
                Dirty -> reply(Caller, Request, rejected(Dirty))
            end;
        _ -> reply(Caller, Request, rejected(runner_busy))
    end.

start(Caller, Request, M, Input, Timeout, Options) ->
    Profile=maps:get(performance_profile,Options,false),
    ProfileStart=profile_now(Profile),
    CallerMon = monitor(process, Caller),
    {Context,CoverageOpenUs} = case {Profile,maps:get(coverage_backend,Options,ets)} of
        {true,otp_native_public} ->
            efz_cov_native_public:open_profiled(maps:get(coverage_schema,Options));
        _ ->
            {Opened,OpenUs}=efz_perf_profile:measure(Profile,fun() ->
                case maps:find(coverage_reuse_map, Options) of
        {ok, Map} -> efz_coverage:open(maps:get(coverage_backend, Options, ets),
            maps:get(coverage_feedback,Options,presence),maps:get(coverage_schema,Options,undefined),Map);
        error -> efz_coverage:open(maps:get(coverage_backend, Options, ets),
            maps:get(coverage_feedback,Options,presence),maps:get(coverage_schema,Options,undefined))
                end end),
            {Opened,OpenUs}
    end,
    Session = trace:session_create(efz_lifecycle, self(), []),
    Pins=maps:get(execution_identities,Options),
    Context=efz_cov_integrity:open(Context,Pins),
    {Context,TraceSetupUs}=efz_perf_profile:measure(Profile,
        fun()->efz_cov_integrity:trace_setup(Session,Context,Pins) end),
    Capability = make_ref(), Guardian = self(),
    {Coordinator, CMon} = spawn_monitor(fun() -> efz_executor:coordinate(Guardian) end),
    {Baseline,BaselineUs}=efz_perf_profile:measure(Profile,fun shared_state/0),
    S0 = #{caller=>Caller,caller_mon=>CallerMon,request=>Request,context=>Context,
        session=>Session,capability=>Capability,coordinator=>Coordinator,coordinator_mon=>CMon,
        coordinator_alive=>true,alive=>#{},seen=>#{},barriers=>#{},code_drained=>false,phase=>running,
        violations=>[],attached=>#{},observed_probes=>sets:new(),coverage_failure=>ok,options=>Options,timeout=>Timeout,
        started=>erlang:monotonic_time(microsecond),baseline=>Baseline,
        profile_enabled=>Profile,profile_start=>ProfileStart,coverage_open_us=>CoverageOpenUs,
        trace_setup_us=>TraceSetupUs,shared_baseline_us=>BaselineUs,
        target_us=>0,cleanup_started_us=>0},
    Runtime=efz_runtime:start(Options),
    Guardian=self(),
    RunTarget=case Profile of
        true -> fun() ->
            Begin=erlang:monotonic_time(microsecond),
            try efz_executor:invoke(M,Input,Context,Coordinator)
            after Guardian!{efz_profile_target,
                erlang:monotonic_time(microsecond)-Begin} end
        end;
        false -> fun() -> efz_executor:invoke(M,Input,Context,Coordinator) end
    end,
    {{Root,S1},AdmitUs}=efz_perf_profile:measure(Profile,
        fun()->admit(RunTarget,S0#{runtime=>Runtime}) end),
    Coordinator ! {coordinate,Root,Context},
    PrepareUs=case Profile of true -> profile_now(true)-ProfileStart; false -> 0 end,
    loop(S1#{root=>Root,deadline=>now_ms()+Timeout,profile_prepare_us=>PrepareUs,
             admit_us=>AdmitUs}).

admit(Fun, S=#{context:=Context,capability:=Capability,session:=Session,alive:=Alive,seen:=Seen}) ->
    Guardian = self(),
    {Pid,Mon} = spawn_monitor(fun() ->
        GMon = monitor(process,Guardian),
        receive
            {start_owned,Capability} ->
                demonitor(GMon,[flush]),
                put('$efz_lifecycle',{Guardian,Capability}),
                ok=efz_coverage:attach(Context),
                try Fun() after _=catch efz_cov_integrity:check(Context) end;
            {'DOWN',GMon,process,Guardian,_} -> ok
        end
    end),
    %% The gate is closed while tracing and the ownership record are installed.
    ok=efz_cov_integrity:admit(Pid,Context),
    1 = trace:process(Session,Pid,true,[procs,set_on_spawn,call]),
    {Pid,S#{alive=>Alive#{Pid=>Mon},seen=>Seen#{Pid=>controlled},
        runtime=>efz_runtime:admit(Pid,maps:get(runtime,S))}}.

loop(S=#{phase:=cleaning,alive:=Alive,barriers:=Barriers,coordinator_alive:=false})
  when map_size(Alive)=:=0, map_size(Barriers)=:=0 ->
    %% Only after the last descendant and its spawn traces are drained can a
    %% global barrier cover all loader activity that overlapped target work.
    case maps:get(code_drained,S) of
        false -> Ref=trace:delivered(maps:get(session,S),all),
                 loop(S#{code_drained=>true,barriers=>#{Ref=>all}});
        true -> case maps:get(runtime,S) of
            #{alive:=true}->wait_event(S,maps:get(deadline,S));
            _->finish(S,confirmed) end
    end;
loop(S=#{deadline:=Deadline}) ->
    %% Check the clock even with a continuously nonempty mailbox. A spawn
    %% storm must not starve either the execution or cleanup deadline.
    case now_ms() >= Deadline of
        true -> expired(S);
        false -> wait_event(S,Deadline)
    end.
wait_event(S,Deadline) ->
    receive
        Message -> loop_event(Message,S)
    after max(0,Deadline-now_ms()) -> expired(S)
    end.
expired(S) ->
    case maps:get(phase,S) of
        running -> loop(cleanup({timeout,maps:get(timeout,S)},S));
        cleaning -> finish(violation(cleanup_deadline,S),unconfirmed)
    end.

loop_event({coordinator_ready,C},S=#{coordinator:=C,root:=Root,capability:=Cap,phase:=running}) ->
    Root!{start_owned,Cap},loop(S);
loop_event({spawn_owned,Cap,Parent,Req,Fun},S=#{capability:=Cap,phase:=running,alive:=Alive}) ->
    case maps:is_key(Parent,Alive) andalso map_size(maps:get(seen,S))<4096 of
        true -> {Pid,Next}=admit(Fun,S),Parent!{Req,{ok,Pid}},loop(Next);
        false -> Parent!{Req,{error,execution_not_admitted}},
                 loop(cleanup({infrastructure,execution_not_admitted},violation(descendant_limit,S)))
    end;
loop_event({spawn_owned,Cap,Parent,Req,_},S=#{capability:=Cap}) ->
    Parent!{Req,{error,execution_stopping}},loop(S);
loop_event({runner_dirty,Cap,Why},S=#{capability:=Cap}) -> loop(violation({declared,Why},S));
loop_event({coordinator_done,C,Outcome},S=#{coordinator:=C,phase:=running}) ->
    loop(cleanup(Outcome,S));
loop_event({'DOWN',Mon,process,_,_},S=#{caller_mon:=Mon,phase:=running}) ->
    loop(cleanup({infrastructure,caller_down},S));
loop_event({'DOWN',Mon,process,_,Why},S=#{coordinator_mon:=Mon}) ->
    Next=S#{coordinator_alive=>false},
    case maps:get(phase,S) of
        running -> loop(cleanup({infrastructure,{coordinator_down,Why}},Next));
        cleaning -> loop(Next)
    end;
loop_event({'DOWN',Mon,process,_,Why},S=#{runtime:=#{mon:=Mon}=R}) ->
    loop(S#{runtime=>efz_runtime:sampler_down(Why,R)});
loop_event({'DOWN',Mon,process,Pid,Why},S=#{alive:=Alive,barriers:=Barriers,session:=Session}) ->
    case maps:find(Pid,Alive) of
        {ok,Mon} ->
            %% DOWN alone does not drain dislocated spawn traces. Each dead
            %% process gets its own barrier, including children found late.
            Ref=trace:delivered(Session,Pid),
            loop(S#{alive=>maps:remove(Pid,Alive),barriers=>Barriers#{Ref=>Pid},
                runtime=>efz_runtime:down(Pid,Why,maps:get(phase,S),maps:get(runtime,S))});
        _ -> loop(S)
    end;
loop_event({trace_delivered,Pid,Ref},S=#{barriers:=Bs}) ->
    case maps:find(Ref,Bs) of {ok,Pid}->loop(S#{barriers=>maps:remove(Ref,Bs)});_->loop(S) end;
loop_event({trace,_,spawn,Child,_},S) -> discovered(Child,S);
loop_event({trace,Child,spawned,_,_},S) -> discovered(Child,S);
loop_event({efz_cov_failure,Ref,Why},S=#{context:={efz_context,1,Ref,_,_}}) ->
    loop(coverage_failed(Why,S));
loop_event({efz_profile_target,Us},S=#{profile_enabled:=true}) ->
    loop(S#{target_us=>Us});
loop_event({efz_cov_observed,Ref,Id},S=#{context:={efz_context,1,Ref,_,_},observed_probes:=Observed}) ->
    loop(S#{observed_probes=>sets:add_element(Id,Observed)});
loop_event(Event,S=#{context:=Context,seen:=Seen,attached:=Attached}) ->
    case efz_cov_integrity:trace_event(Event,Context,Seen) of
        {attached,Pid} -> loop(S#{attached=>Attached#{Pid=>true}});
        {failed,Why} -> loop(coverage_failed(Why,S));
        ignore -> loop(S)
    end.
coverage_failed(Why,S=#{coverage_failure:=ok}) -> S#{coverage_failure=>{error,Why}};
coverage_failed(_,S) -> S.

discovered(Pid,S=#{seen:=Seen,alive:=Alive}) when is_pid(Pid),node(Pid)=:=node() ->
    case maps:is_key(Pid,Seen) of
        true -> loop(S);
        false ->
            Mon=monitor(process,Pid),
            Next=violation(uncontrolled_spawn,S#{seen=>Seen#{Pid=>uncontrolled},alive=>Alive#{Pid=>Mon}}),
            exit(Pid,kill),
            loop(cleanup({infrastructure,uncontrolled_spawn},Next))
    end;
discovered(_,S) -> loop(cleanup({infrastructure,remote_spawn},violation(remote_spawn,S))).

cleanup(_,S=#{phase:=cleaning}) -> S;
cleanup(Outcome,S=#{alive:=Alive,coordinator:=C}) ->
    %% kill ignores trap_exit. All creation is serialized through this owner;
    %% subsequent admission requests are refused, including nested requests.
    maps:foreach(fun(P,_)->exit(P,kill) end,Alive),
    exit(C,kill),
    S#{phase=>cleaning,outcome=>Outcome,deadline=>now_ms()+?CLEANUP_MS,
       cleanup_started_us=>profile_now(maps:get(profile_enabled,S)),
       runtime=>efz_runtime:stop(maps:get(runtime,S))}.
violation(Why,S=#{violations:=Vs}) -> S#{violations=>lists:usort([Why|Vs])}.

finish(S,ProcessStatus) ->
    Profile=maps:get(profile_enabled,S),
    FinishStart=profile_now(Profile),
    #{context:=Context,options:=Options,session:=Session,baseline:=Before}=S,
    {PinStatus,IntegrityUs}=efz_perf_profile:measure(Profile,
        fun()->efz_cov_integrity:validate(maps:get(execution_identities,Options)) end),
    Failure=case maps:get(coverage_failure,S) of ok->PinStatus;Error->Error end,
    Native=maps:get(coverage_backend,Options,ets)=:=otp_native_public,
    NoCoverage=maps:get(coverage_backend,Options,ets)=:=none,
    Compact=maps:get(coverage_compact,Options,false) andalso
        maps:get(coverage_backend,Options,ets)=:=bitmap andalso
        maps:is_key(coverage_reuse_map,Options) andalso ProcessStatus=:=confirmed
        andalso Failure=:=ok andalso element(1,maps:get(outcome,S))=:=ok,
    {Hits,SnapshotStatus}=case Compact of
        true -> {[],compact_plan_status(Options)};
        false -> case Native of
            true -> {[],Failure};
            false -> case NoCoverage of
                true -> {[],Failure};
                false -> efz_executor:coverage(Context,Options,Failure)
            end
        end
    end,
    {CountEvidence,CovStatus0}=count_evidence(Context,Options,Hits,SnapshotStatus),
    CovStatus1=case Compact of
        true -> CovStatus0;
        false -> case {CovStatus0,sets:is_subset(maps:get(observed_probes,S),sets:from_list(Hits))} of
            {ok,false} -> {error,coverage_observations_lost};
            _ -> CovStatus0
        end
    end,
    Attached=lists:sort(maps:keys(maps:get(attached,S))),
    CovStatus2=case {CovStatus1,maps:get(outcome,S),lists:member(maps:get(root,S),Attached)} of
        {ok,{ok,_},false} -> {error,missing_coverage_attachment};
        _ -> CovStatus1
    end,
    {BitsEvidence,CovStatus}=case {Compact,Native,ProcessStatus,CovStatus2,maps:get(outcome,S)} of
        {false,true,confirmed,ok,{ok,_}} ->
            NativeCollect=case Profile of
                true -> efz_cov_native_public:collect_profiled(maps:get(coverage_schema,Options));
                false -> efz_coverage:native_collect(maps:get(coverage_schema,Options))
            end,
            case NativeCollect of
                {ok,NativeBits,Times} ->
                    put('$efz_native_profile',Times),
                    {{efz_native_observation,NativeBits},ok};
                {ok,NativeBits} -> {{efz_native_observation,NativeBits},ok};
                {error,NativeWhy} -> {none,{error,NativeWhy}}
            end;
        {true,false,confirmed,ok,{ok,_}} ->
            Sealed0=efz_coverage:seal(Context),
            case {efz_coverage:sealed_count(Sealed0),sets:size(maps:get(observed_probes,S))} of
                {{ok,N},N} -> {Sealed0,ok};
                {{ok,_},_} -> {none,{error,coverage_observations_lost}};
                {{error,CountWhy},_} -> {none,{error,CountWhy}}
            end;
        {false,false,confirmed,ok,{ok,_}} -> case efz_coverage:snapshot_bits(Context) of
            {ok,SnapshotBits} -> {SnapshotBits,ok};
            {error,SnapshotWhy} -> {none,{error,SnapshotWhy}};
            none -> {none,ok}
        end;
        _ -> {none,CovStatus2}
    end,
    Observation=case {Compact,BitsEvidence} of
        {true,_} -> efz_cov_integrity:observation_count(sets:size(maps:get(observed_probes,S)),CovStatus,Attached);
        {false,{efz_native_observation,NativeBits0}} ->
            efz_cov_integrity:observation_count(efz_coverage:native_count(NativeBits0),CovStatus,Attached);
        _ -> efz_cov_integrity:observation(Hits,CovStatus,Attached)
    end,
    case BitsEvidence of
        {efz_bitmap_sealed,_,_,_,_,_,_} -> ok;
        _ -> ok=efz_coverage:close(Context)
    end,
    ok=efz_cov_integrity:close(),
    {_,TraceDestroyUs}=efz_perf_profile:measure(Profile,
        fun()->trace:session_destroy(Session) end),
    Runtime=efz_runtime:finish(maps:get(runtime,S),maps:get(outcome,S),
        #{status=>ProcessStatus,survivors=>maps:keys(maps:get(alive,S))}),
    {Changes,SharedCheckUs}=efz_perf_profile:measure(Profile,
        fun()->shared_changes(Before,shared_state()) end),
    Violations=lists:usort(maps:get(violations,S)++Changes),
    Reusable=ProcessStatus=:=confirmed andalso Violations=:=[],
    Cleanup=#{status=>ProcessStatus,processes=>lists:sort(maps:keys(maps:get(seen,S))),
        survivors=>lists:sort(maps:keys(maps:get(alive,S))),violations=>Violations},
    Outcome=maps:get(outcome,S),
    {Final,Status}=case Reusable of
        false -> Why=#{kind=>dirty_runner,cleanup=>Cleanup},ok=poison(Why),
                 Primary=case Outcome of {infrastructure,_}->Outcome;_->{infrastructure,Why} end,
                 {Primary,{error,dirty_runner}};
        true -> case {Outcome,CovStatus} of
            {{infrastructure,_},_}->{Outcome,CovStatus};
            {_,ok}->{Outcome,ok};
            {_,{error,Why}}->{{infrastructure,Why},CovStatus}
        end
    end,
    {efz_context,1,Ref,_,_}=Context,
    Result0=#{execution_ref=>Ref,outcome=>Final,target_outcome=>Outcome,
        coverage=>Hits,coverage_status=>Status,coverage_observation=>Observation,
        execution_identities=>maps:get(execution_identities,Options),builds=>efz_executor:builds(Options),
        elapsed_us=>erlang:monotonic_time(microsecond)-maps:get(started,S),
        execution_model=>controlled_descendants,cleanup=>Cleanup,runner_reusable=>Reusable},
    ResultBase=case maps:is_key(coverage_reuse_map,Options) of
        true -> Result0#{bitmap_map_armed=>true};
        false -> Result0
    end,
    Result=case {Final,Status,Reusable,BitsEvidence} of
        {{ok,_},ok,true,{efz_native_observation,ResultNativeBits}} ->
            NativeSchema=maps:get(coverage_schema,Options),
            DiagnosticHits=case maps:get(enabled,maps:get(runtime_oracles,Options,#{enabled=>false}),false) of
                true -> efz_coverage:native_decode(NativeSchema,ResultNativeBits);
                false -> []
            end,
            ResultBase#{coverage_native=>ResultNativeBits,
                coverage=>DiagnosticHits,
                coverage_count=>efz_coverage:native_count(ResultNativeBits),
                coverage_modules=>efz_coverage:native_modules(NativeSchema,ResultNativeBits)};
        {{ok,_},ok,true,{efz_bitmap_sealed,_,_,_,_,_,_}=Sealed} ->
            Modules=sets:fold(fun({M,_,_},Acc)->sets:add_element(M,Acc) end,
                              sets:new(),maps:get(observed_probes,S)),
            (maps:remove(coverage,ResultBase))#{coverage_count=>sets:size(maps:get(observed_probes,S)),
                coverage_modules=>sets:to_list(Modules),coverage_sealed=>Sealed};
        {{ok,_},ok,true,none}->ResultBase;
        {{ok,_},ok,true,Bits}->ResultBase#{coverage_bits=>Bits};
        _->ResultBase
    end,
    demonitor(maps:get(caller_mon,S),[flush]),
    Profiled=case Profile of
        true ->
            End=profile_now(true),
            Prepare=maps:get(profile_prepare_us,S,0),
            Target=maps:get(target_us,S),
            CleanupWaitUs=case maps:get(cleanup_started_us,S) of
                0 -> 0; BeginCleanup -> max(0,FinishStart-BeginCleanup)
            end,
            Processing=End-FinishStart,
            Total=End-maps:get(profile_start,S),
            GuardianTimes=#{guardian_total_us=>Total,guardian_prepare_us=>Prepare,
                target_us=>Target,cleanup_wait_us=>CleanupWaitUs,
                guardian_finish_us=>Processing,
                guardian_unaccounted_us=>max(0,Total-Prepare-Target-CleanupWaitUs-Processing),
                coverage_open_us=>maps:get(coverage_open_us,S),
                trace_setup_us=>maps:get(trace_setup_us,S),
                shared_baseline_us=>maps:get(shared_baseline_us,S),
                admit_us=>maps:get(admit_us,S),
                integrity_validate_us=>IntegrityUs,
                trace_destroy_us=>TraceDestroyUs,
                shared_check_us=>SharedCheckUs},
            Result#{performance_profile=>maps:merge(GuardianTimes,
                case get('$efz_native_profile') of
                    undefined -> #{}; NativeTimes -> NativeTimes
                end)};
        false -> Result
    end,
    reply(maps:get(caller,S),maps:get(request,S),maps:merge(maps:merge(Profiled,CountEvidence),Runtime)).

profile_now(true) -> erlang:monotonic_time(microsecond);
profile_now(false) -> 0.

%% All admitted writers have terminated before either snapshot. Presence keeps
%% its original result shape; hit counts are supplemental, never probe IDs.
count_evidence(_,#{coverage_feedback:=hit_count},_,{error,_}=Error) -> {#{},Error};
count_evidence(Context,#{coverage_feedback:=hit_count},Hits,ok) ->
    case efz_coverage:counts(Context) of
        {ok,Counts} -> case efz_coverage:count_features(Hits,Counts) of
            {ok,Features}->{#{coverage_feedback=>hit_count,hit_counts=>Counts,count_features=>Features},ok};
            Error->{#{},Error}
        end;
        Error->{#{},Error}
    end;
count_evidence(_,_,_,Status) -> {#{},Status}.

%% Slot admission validates each hit against the exact schema. Still validate
%% that the prepared plan itself remains live, as the list-based path did.
compact_plan_status(#{coverage_plan:=Plan}) ->
    efz_cov_manifest:validate_prepared(automatic,[],Plan);
compact_plan_status(_) -> ok.

%% This detects persistent_term/env changes and new escaped ETS tables. It is
%% NOT a transaction or a sandbox: arbitrary existing shared ETS writes, ports,
%% remote work, external services and changing tracing remain out of contract.
shared_state() ->
    #{persistent=>maps:remove(?DIRTY,maps:from_list(persistent_term:get())),
      env=>maps:from_list([{A,lists:sort(application:get_all_env(A))} ||
          {A,_,_}<-application:loaded_applications()]),ets=>ets:all(),
      names=>maps:from_list([{N,whereis(N)} || N<-registered()])}.
shared_changes(A,B) ->
    Ps=changed_keys(maps:get(persistent,A),maps:get(persistent,B)),
    %% Loading an application with no environment is not itself contamination.
    EnvA=maps:filter(fun(_,V)->V=/=[] end,maps:get(env,A)),
    EnvB=maps:filter(fun(_,V)->V=/=[] end,maps:get(env,B)),
    Es=changed_keys(EnvA,EnvB),Ts=maps:get(ets,B)--maps:get(ets,A),
    Ns=[N || {N,P}<-maps:to_list(maps:get(names,B)),maps:find(N,maps:get(names,A))=/={ok,P}],
    [{persistent_term_changed,Ps} || Ps=/=[]] ++
    [{application_env_changed,Es} || Es=/=[]] ++ [{escaped_ets,Ts} || Ts=/=[]] ++
    [{escaped_registered_names,Ns} || Ns=/=[]].
changed_keys(A,B) -> [K || K<-lists:usort(maps:keys(A)++maps:keys(B)),maps:find(K,A)=/=maps:find(K,B)].
now_ms() -> erlang:monotonic_time(millisecond).
reply(Caller,Request,Result) -> Caller!{Request,self(),Result},ok.
rejected({dirty,Why}) -> rejected(Why);
rejected(Why) -> #{execution_ref=>make_ref(),outcome=>{infrastructure,Why},coverage=>[],
    coverage_status=>{error,runner_unavailable},builds=>#{},elapsed_us=>0,
    cleanup=>#{status=>not_started},runner_reusable=>false}.
