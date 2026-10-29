%% Runs in a dedicated peer VM. Only the fixed controller accepts peer RPCs;
%% target callbacks execute in one long-lived driver process.
-module(efz_target_vm).
-behaviour(gen_server).
-export([start/3, step/2, stop/0, info/0, spawn_covered/4]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start(Target, InitConfig, Pins) when is_atom(Target), is_map(InitConfig), is_map(Pins) ->
    case whereis(?MODULE) of
        undefined -> gen_server:start({local,?MODULE},?MODULE,{Target,InitConfig,Pins},[]);
        _ -> {error,already_started}
    end.
step(Input, Timeout) when is_binary(Input), is_integer(Timeout), Timeout>0 ->
    gen_server:call(?MODULE,{step,Input,Timeout},Timeout+1000).
stop() -> gen_server:call(?MODULE,stop,1000).
info() -> gen_server:call(?MODULE,info,1000).

%% The wrapper runs outside instrumented target code, so the helper attaches
%% its current step context before its first instrumented function entry.
spawn_covered(Context,Module,Function,Args) when is_atom(Module),is_atom(Function),
        is_list(Args) ->
    spawn_link(fun()->
        ok=efz_coverage:attach(Context),
        apply(Module,Function,Args)
    end).

init({Target,InitConfig,Pins}) ->
    process_flag(trap_exit,true),
    persistent_term:put({?MODULE,window},inactive),
    case efz_cov_integrity:validate(Pins) of
        ok ->
            Parent=self(),Ref=make_ref(),
            {Driver,Mon}=spawn_monitor(fun()->driver_init(Parent,Ref,Target,InitConfig) end),
            receive
                {driver_ready,Ref,Driver,Mode} ->
                    {ok,#{target=>Target,pins=>Pins,init_config=>InitConfig,
                        driver=>Driver,monitor=>Mon,mode=>Mode,step=>0,
                        started_ms=>erlang:monotonic_time(millisecond),
                        os_pid=>list_to_integer(os:getpid())}};
                {driver_failed,Ref,Why} -> {stop,{target_init_failed,Why}};
                {'DOWN',Mon,process,Driver,Why} -> {stop,{target_init_down,Why}}
            after 5000 -> exit(Driver,kill),{stop,target_init_timeout} end;
        {error,Why} -> {stop,{identity_mismatch,Why}}
    end.

handle_call(info,_,S) ->
    Driver=maps:get(driver,S),
    {reply,#{os_pid=>maps:get(os_pid,S),driver=>list_to_binary(pid_to_list(maps:get(driver,S))),
        step=>maps:get(step,S),mode=>maps:get(mode,S),
        processes=>length(processes()),ets_tables=>length(ets:all()),
        ports=>length(erlang:ports()),memory_bytes=>erlang:memory(total),
        driver_mailbox=>case process_info(Driver,message_queue_len) of
            {message_queue_len,N}->N;_->0 end},S};
handle_call({step,Input,Timeout},_,S=#{driver:=Driver,monitor:=Mon,step:=Index}) ->
    case efz_cov_integrity:validate(maps:get(pins,S)) of
        ok -> do_step(Input,Timeout,Index+1,Driver,Mon,S);
        {error,Why} -> {reply,{error,{identity_mismatch,Why}},S}
    end;
handle_call(stop,_,S) -> {stop,normal,ok,S};
handle_call(_,_,S) -> {reply,{error,unsupported_request},S}.
handle_cast(_,S) -> {noreply,S}.
handle_info({'DOWN',Mon,process,Driver,Why},S=#{monitor:=Mon,driver:=Driver}) ->
    {stop,{driver_down,Why},S};
handle_info(_,S) -> {noreply,S}.
terminate(_,S) ->
    persistent_term:erase({?MODULE,window}),
    Driver=maps:get(driver,S,undefined),
    case is_pid(Driver) of
        true ->
            Ref=make_ref(),Driver!{finish,self(),Ref},
            receive {driver_finished,Ref}->ok after 500->exit(Driver,kill) end;
        false -> ok
    end.
code_change(_,S,_) -> {ok,S}.

do_step(Input,Timeout,Index,Driver,Mon,S) ->
    Started=erlang:monotonic_time(microsecond),Ref=make_ref(),
    Feedback=maps:get(coverage_feedback,maps:get(init_config,S,#{}),presence),
    %% A fresh observation table is independent of the persistent driver.
    Context=efz_coverage:open(ets,Feedback),
    persistent_term:put({?MODULE,window},{self(),Ref,Context}),
    Driver!{step,self(),Ref,Input,Context},
    Deadline=erlang:monotonic_time(millisecond)+Timeout,
    Outcome=wait_step(Ref,Driver,Mon,Deadline),
    WindowFailure=drain_window_failures(Ref,false),
    persistent_term:put({?MODULE,window},inactive),
    Integrity=efz_cov_integrity:validate(maps:get(pins,S)),
    {Hits,Status}=case efz_coverage:snapshot(Context) of
        {ok,Points}->
            Valid=efz_cov_manifest:validate_observed(
                maps:get(coverage,maps:get(init_config,S)),Points,
                maps:get(manifests,maps:get(init_config,S))),
            case {WindowFailure,Integrity,Valid} of
                {false,ok,ok}->{Points,ok};
                {true,_,_}->{Points,{error,persistent_window_unattached}};
                {_,{error,Why},_}->{Points,{error,{identity_mismatch,Why}}};
                {_,_,Failure}->{Points,Failure}
            end;
        {error,Why}->{[],{error,Why}}
    end,
    Counts=case Feedback of
        hit_count->efz_coverage:counts(Context);
        _->none
    end,
    ok=efz_coverage:close(Context),
    {ResourceStatus,Resources}=resource_status(S,Driver),
    Reusable=Status=:=ok andalso ResourceStatus=:=none andalso case Outcome of
        {timeout,_}->false;{exit,_}->false;
        {crash,_,_,_}->false;{infrastructure,_}->false;_->true end,
    Observation=efz_cov_integrity:observation(Hits,Status,[driver]),
    Base=#{outcome=>Outcome,coverage=>Hits,coverage_status=>Status,
        coverage_observation=>Observation,builds=>efz_executor:builds(#{
            manifests=>maps:get(manifests,maps:get(init_config,S,#{}),[])}),
        elapsed_us=>erlang:monotonic_time(microsecond)-Started,
        runner_reusable=>Reusable,execution_model=>persistent_target_driver,
        cleanup=>#{status=>case Reusable of true->session_retained;false->epoch_retired end,
                   violations=>[]},step=>Index,driver=>list_to_binary(pid_to_list(Driver)),
        os_pid=>maps:get(os_pid,S),epoch_limit_reason=>ResourceStatus,
        session_resources=>Resources},
    Result=case Counts of
        {ok,C}->Base#{coverage_feedback=>hit_count,hit_counts=>C};
        none->Base;
        {error,CountWhy}->Base#{coverage_status=>{error,CountWhy}}
    end,
    case Reusable of
        true -> {reply,{ok,Result},S#{step=>Index}};
        false -> {stop,epoch_retired,{ok,Result},S#{step=>Index}}
    end.

resource_status(S,Driver) ->
    Limits=maps:get(session_limits,maps:get(init_config,S,#{}),#{}),
    Age=erlang:monotonic_time(millisecond)-maps:get(started_ms,S),
    case maps:get(max_epoch_ms,Limits,infinity) of
        Max when is_integer(Max),Age>=Max->{max_epoch_ms,#{epoch_ms=>Age}};
        _->resource_counts(Limits,Driver,Age)
    end.

resource_counts(Limits,Driver,Age) ->
    Keys=[max_vm_memory_bytes,max_processes,max_ets_tables,max_ports,max_driver_mailbox],
    case lists:any(fun(K)->maps:get(K,Limits,infinity)=/=infinity end,Keys) of
        false->{none,#{epoch_ms=>Age}};
        true->
            Mailbox=case process_info(Driver,message_queue_len) of
                {message_queue_len,N}->N;_->0 end,
            Counts=#{max_vm_memory_bytes=>erlang:memory(total),
                max_processes=>length(processes()),max_ets_tables=>length(ets:all()),
                max_ports=>length(erlang:ports()),max_driver_mailbox=>Mailbox},
            Exceeded=[K||K<-Keys,is_integer(maps:get(K,Limits,infinity)),
                maps:get(K,Counts)>maps:get(K,Limits)],
            Reason=case Exceeded of [First|_]->First;[]->none end,
            {Reason,Counts#{epoch_ms=>Age}}
    end.

wait_step(Ref,Driver,Mon,Deadline) ->
    Remaining=max(0,Deadline-erlang:monotonic_time(millisecond)),
    receive
        {driver_result,Ref,Driver,Outcome} -> Outcome;
        {'DOWN',Mon,process,Driver,Why} -> {exit,Why}
    after Remaining -> exit(Driver,kill),{timeout,Remaining} end.

drain_window_failures(Ref,Found) ->
    receive {efz_target_window_failure,Ref,_}->drain_window_failures(Ref,true)
    after 0->Found end.

driver_init(Parent,Ref,Target,InitConfig) ->
    Mode=case {erlang:function_exported(Target,init_session,1),
               erlang:function_exported(Target,handle_input,2),
               erlang:function_exported(Target,finish_session,1)} of
        {true,true,true}->session;
        {false,false,false}->run;
        _->invalid
    end,
    case Mode of
        invalid -> Parent!{driver_failed,Ref,invalid_target_callbacks};
        _ ->
            try
                State=case Mode of
                    session->Target:init_session(maps:get(target_init,InitConfig,#{}));
                    run->undefined
                end,
                Parent!{driver_ready,Ref,self(),Mode},
                driver_loop(Target,Mode,State,maps:get(max_result_bytes,InitConfig,1048576))
            catch Class:Why -> Parent!{driver_failed,Ref,{Class,Why}} end
    end.
driver_loop(Target,Mode,State,MaxResult) ->
    receive
        {step,Controller,Ref,Input,Context} ->
            ok=efz_coverage:attach(Context),
            try
                {Value,Next}=case Mode of
                    session -> Target:handle_input(Input,State);
                    run -> {Target:run(Input),State}
                end,
                Ready=case Mode=:=session andalso
                           erlang:function_exported(Target,step_barrier,1) of
                    true -> case Target:step_barrier(Next) of
                        {ok,Updated}->Updated;
                        ok->Next;
                        Other->error({invalid_step_barrier,Other})
                    end;
                    false->Next
                end,
                true=get('$efz_execution_context')=:=Context,
                case erlang:external_size(Value)=<MaxResult of
                    true ->
                        Controller!{driver_result,Ref,self(),{ok,Value}},
                        erase('$efz_execution_context'),
                        driver_loop(Target,Mode,Ready,MaxResult);
                    false ->
                        Controller!{driver_result,Ref,self(),
                            {infrastructure,target_result_limit}},
                        exit(self(),kill)
                end
            catch Class:Why:Stack ->
                Controller!{driver_result,Ref,self(),{crash,Class,Why,
                    lists:sublist(Stack,16)}},
                exit(target_crash)
            end;
        {finish,Controller,Ref} ->
            case Mode of session->catch Target:finish_session(State);run->ok end,
            Controller!{driver_finished,Ref},
            ok
    end.
