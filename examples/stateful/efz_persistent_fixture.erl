%% Local stateful fixture: the driver dictionary, ETS table, mailbox and a
%% linked OTP counter all persist until finish_session/1.
-module(efz_persistent_fixture).
-export([run/1,init_session/1,handle_input/2,step_barrier/1,finish_session/1,
         helper_probe/3]).

run(Input) ->
    State=init_session(#{}),
    try {Value,_}=handle_input(Input,State),Value
    after finish_session(State) end.

init_session(Config) ->
    case maps:get(native_nif_dir,Config,undefined) of
        undefined->ok;
        NifDir when is_list(NifDir)->true=code:add_patha(NifDir)
    end,
    put(efz_persistent_count,0),
    Table=ets:new(efz_persistent_fixture,[set,private]),
    {ok,Service}=efz_stateful_counter:start_link(),
    Variation=case maps:get(variation_file,Config,
                       maps:get(<<"variation_file">>,Config,undefined)) of
        undefined->0;
        File->
            {ok,Contents}=file:read_file(File),
            N=binary_to_integer(Contents),
            ok=file:write_file(File,integer_to_binary(N+1)),N
    end,
    Pause={maps:get(pause_after,Config,undefined),
           maps:get(pause_ready,Config,undefined),
           maps:get(pause_release,Config,undefined)},
    #{table=>Table,service=>Service,variation=>Variation,pause=>Pause}.

handle_input(Input,#{table:=Table,service:=Service,variation:=Variation,
                     pause:=Pause}=State) ->
    Count=get(efz_persistent_count)+1,
    put(efz_persistent_count,Count),
    ets:insert(Table,{last,Input}),
    ServiceCount=efz_stateful_counter:command(Service,add,1),
    PendingRef=case Input of <<"helper">>->make_ref();_->undefined end,
    Reply=case Input of
        <<"arm">> -> ets:insert(Table,{armed,true}),armed;
        <<"mail">> -> self()!persistent_marker,queued;
        <<"checkmail">> -> receive persistent_marker->mail_present
                             after 0->mail_absent end;
        <<"hang">> -> receive stop_hang->unexpected end;
        <<"native_hang">> ->
            %% Fixed test-only module name; the NIF is loaded only in the child VM.
            NativeModule=binary_to_atom(<<"efz_native_fixture">>,utf8),
            erlang:apply(NativeModule,act,[<<"HANG">>]);
        <<"detach">> ->
            Setsid=os:find_executable("setsid"),
            Sleep=os:find_executable("sleep"),
            Port=open_port({spawn_executable,Setsid},[exit_status,{args,["-w",Sleep,"30"]}]),
            {os_pid,DetachedPid}=erlang:port_info(Port,os_pid),
            {detached,DetachedPid};
        <<"boom">> -> erlang:error(synthetic_target_crash);
        <<"large">> -> binary:copy(<<"x">>,2048);
        <<"helper">> ->
            Context=get('$efz_execution_context'),
            Owner=self(),
            efz_target_vm:spawn_covered(Context,?MODULE,helper_probe,
                [Owner,PendingRef,Context]),helper_started;
        <<"variable">> ->
            maybe_pause(Variation,Pause),
            case Variation rem 3 of
                0->variable_odd;
                _->variable_even
        end;
        <<"fire">> -> case ets:lookup(Table,armed) of
            [{armed,true}]->armed_path;
            []->unarmed_path
        end;
        _ -> other
    end,
    Next=case Input of
        <<"helper">> -> State#{pending_helper=>PendingRef};
        _->State
    end,
    {#{reply=>Reply,count=>Count,service_count=>ServiceCount,
       ets_size=>ets:info(Table,size),driver=>pid_to_list(self())},Next}.

step_barrier(#{pending_helper:=Ref}=State) ->
    receive {helper_done,Ref}->{ok,maps:remove(pending_helper,State)}
    after 1000->error(helper_barrier_timeout) end;
step_barrier(State)->{ok,State}.

helper_probe(Owner,Ref,_Context)->
    Owner!{helper_done,Ref}.

finish_session(#{table:=Table,service:=Service}) ->
    ok=gen_server:stop(Service),ets:delete(Table),ok.

maybe_pause(N,{N,Ready,Release}) when Ready=/=undefined,Release=/=undefined ->
    ok=file:write_file(Ready,<<"ready">>),
    await_release(Release,250);
maybe_pause(N,{After,Ready,Release}) when is_list(After),
        Ready=/=undefined,Release=/=undefined ->
    case lists:member(N,After) of
        true ->
            Suffix="."++integer_to_list(N),
            ok=file:write_file(Ready++Suffix,<<"ready">>),
            await_release(Release++Suffix,250);
        false -> ok
    end;
maybe_pause(_,_) -> ok.
await_release(_,0)->erlang:error(pause_release_timeout);
await_release(Path,N)->
    case filelib:is_regular(Path) of
        true->ok;
        false->receive after 20->await_release(Path,N-1) end
    end.
