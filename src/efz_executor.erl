-module(efz_executor).
-export([run/3, run/4, runner_status/0]).
%% Internal protocol entry points; targets use efz_target, never these.
-export([coordinate/1, invoke/4, coverage/3, builds/1]).

runner_status() -> efz_guardian:status().

%% Compatibility wrapper; there is only one execution pipeline.
run(M, Input, Timeout) -> maps:get(outcome, run(M, Input, Timeout, #{coverage => manual})).

run(M, Input, Timeout, Options) when is_integer(Timeout), Timeout >= 0 ->
    %% The low-level instrumentation API historically accepts terms. Campaigns
    %% and replay always supply max_input_bytes and require binary inputs.
    Check = case is_binary(Input) orelse maps:is_key(max_input_bytes,Options) of
        true -> efz_input:check(Input,maps:get(max_input_bytes,Options,efz_input:default_limit()),execution);
        false -> ok
    end,
    case Check of
        ok -> run_checked(M,Input,Timeout,Options);
        {error,Why} -> #{execution_ref=>make_ref(),outcome=>{infrastructure,Why},
            coverage_status=>ok,coverage=>[],elapsed_us=>0,builds=>builds(Options),
            coverage_observation=>efz_cov_integrity:observation([],ok,[])}
    end.
run_checked(M, Input, Timeout, Options) ->
    _=code:ensure_loaded(M),
    case efz_cov_integrity:options(M,Options) of
        {ok,Pinned} -> run_pinned(M,Input,Timeout,Pinned);
        {error,Why} -> #{execution_ref=>make_ref(),outcome=>{infrastructure,Why},
            coverage_status=>{error,Why},coverage=>[],elapsed_us=>0,builds=>builds(Options),
            coverage_observation=>efz_cov_integrity:observation([],{error,Why},[]),
            cleanup=>#{status=>not_started},runner_reusable=>true}
    end.
run_pinned(M, Input, Timeout, Options) ->
    Caller=self(), Request=make_ref(),
    {Guardian,Monitor}=spawn_monitor(fun()->
        efz_guardian:run(Caller,Request,M,Input,Timeout,Options)
    end),
    receive
        {Request,Guardian,Result} ->
            receive
                {'DOWN',Monitor,process,Guardian,normal} -> Result;
                {'DOWN',Monitor,process,Guardian,Why} -> guardian_failed(Why,Result)
            end;
        {'DOWN',Monitor,process,Guardian,Why} ->
            guardian_failed(Why,#{execution_ref=>Request,coverage=>[],builds=>builds(Options),elapsed_us=>0,
                execution_identities=>maps:get(execution_identities,Options)})
    end.
guardian_failed(Why,Result) ->
    Failure=#{kind=>dirty_runner,reason=>{guardian_down,Why}},
    ok=efz_guardian:poison(Failure),
    Primary=case maps:get(outcome,Result,undefined) of
        {infrastructure,_}=Original->Original;
        _->{infrastructure,Failure}
    end,
    %% A reply can precede an abnormal guardian DOWN. Retire the runner, but
    %% keep that reply's primary failure and evidence instead of masking them.
    Result#{outcome=>Primary,guardian_failure=>Failure,
        execution_evidence=>maps:with([outcome,coverage_status,coverage_observation,cleanup],Result),
        coverage_status=>{error,dirty_runner},
        coverage_observation=>efz_cov_integrity:observation(maps:get(coverage,Result),{error,Failure},[]),
        cleanup=>#{status=>unconfirmed},runner_reusable=>false}.

%% This process classifies only the root. The guardian owns deadlines,
%% descendants, context lifetime and final result publication independently.
coordinate(Guardian) ->
    GMon=monitor(process,Guardian),
    receive
        {coordinate,Root,{efz_context,1,Ref,_,_}} ->
            Mon=monitor(process,Root),
            Guardian!{coordinator_ready,self()},
            Outcome=receive
                {target_result,Ref,Root,Value} ->
                    receive {'DOWN',Mon,process,Root,_}->Value;
                        {'DOWN',GMon,process,Guardian,_}->exit(normal) end;
                {'DOWN',Mon,process,Root,Why} -> {exit,Why};
                {'DOWN',GMon,process,Guardian,_} -> exit(normal)
            end,
            Guardian!{coordinator_done,self(),Outcome},ok;
        {'DOWN',GMon,process,Guardian,_} -> ok
    end.
invoke(M,Input,{efz_context,1,Ref,_,_},Coordinator) ->
    Outcome=try {ok,M:run(Input)}
    catch
        error:{efz_infrastructure,Why} -> {infrastructure,Why};
        exit:Reason -> {exit,Reason};
        Class:Reason:Stack -> {crash,Class,Reason,Stack}
    end,
    Coordinator!{target_result,Ref,self(),Outcome},ok.

coverage(Context, Options, Failure) ->
    case efz_cov:snapshot(Context) of
        {ok, Hits} ->
            Status = case Failure of
                ok -> validate(Hits, Options);
                _ -> Failure
            end,
            {Hits, Status};
        {error, Why} -> {[], {error, Why}}
    end.

validate(Hits, #{coverage_plan := Plan} = Options) ->
    efz_cov_manifest:validate_prepared(maps:get(coverage, Options, automatic), Hits, Plan);
validate(Hits, Options) ->
    efz_cov_manifest:validate_observed(maps:get(coverage, Options, automatic),
                                     Hits, maps:get(manifests, Options, [])).
builds(#{coverage_plan := {efz_cov_plan,1,_,_}=Plan}) -> efz_cov_manifest:builds(Plan);
builds(#{coverage_plan := _}) -> #{};
builds(Options) -> maps:from_list([{maps:get(module, M), maps:get(build_id, M)} ||
                                  M <- maps:get(manifests, Options, [])]).
