%% Local, single-flight target epoch in a separate OTP VM. The peer control
%% process owns and reaps the child. A failed step retires the entire epoch.
-module(efz_target_session).
-behaviour(gen_server).
-export([open/1, run/3, info/1, close/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

open(C) when is_map(C) -> gen_server:start(?MODULE,{C,self()},[]).
run(Pid,Input,Timeout) when is_pid(Pid),is_binary(Input),is_integer(Timeout),Timeout>0 ->
    try gen_server:call(Pid,{run,Input,Timeout},Timeout+3000)
    catch exit:_->{error,target_session_down} end.
info(Pid) -> gen_server:call(Pid,info,1000).
close(Pid) when is_pid(Pid) ->
    try gen_server:call(Pid,close,3000) catch exit:_ -> ok end;
close(_) -> ok.

init({C,Owner}) ->
    process_flag(trap_exit,true),
    Started=erlang:monotonic_time(microsecond),
    OwnerMon=erlang:monitor(process,Owner),
    Target=maps:get(target,C),Pins=maps:get(execution_identities,C),
    Ms=maps:get(manifests,C,[]),
    Artifacts=maps:get(artifacts,C,[]),
    Modules=lists:usort([Target|[maps:get(module,M)||M<-Ms]]),
    Paths=lists:usort([filename:dirname(code:which(M))||M<-Modules]++
        [filename:dirname(maps:get(beam,A))||A<-Artifacts]++
        [filename:dirname(code:which(?MODULE))]),
    Erl=os:find_executable("erl"),
    Setsid=os:find_executable("setsid"),
    Options=#{connection=>standard_io,exec=>{Setsid,[Erl]},
        args=>["+S","1:1","+A","1","-pa"|Paths],shutdown=>{halt,1000},
        peer_down=>continue,wait_boot=>5000},
    case peer:start_link(Options) of
      {ok,Peer,_} -> try
        lists:foreach(fun(A)->
            Module=maps:get(module,A),
            {module,Module}=peer:call(Peer,code,load_abs,
                [filename:rootname(maps:get(beam,A))],3000)
        end,Artifacts),
        lists:foreach(fun(M)->{module,M}=peer:call(Peer,code,ensure_loaded,[M],3000) end,Modules),
        Config=#{target_init=>maps:get(target_init,maps:get(execution,C,#{}),#{}),
            manifests=>Ms,coverage=>maps:get(coverage,C,automatic),
            coverage_feedback=>maps:get(coverage_feedback,C,presence),
            max_result_bytes=>maps:get(max_result_bytes,maps:get(execution,C),1048576),
            session_limits=>maps:with([max_epoch_ms,max_vm_memory_bytes,
                max_processes,max_ets_tables,max_ports,max_driver_mailbox],
                maps:get(execution,C))},
        {ok,_}=peer:call(Peer,efz_target_vm,start,[Target,Config,Pins],5000),
        Remote=peer:call(Peer,efz_target_vm,info,[],1000),
        {ok,#{peer=>Peer,os_pid=>maps:get(os_pid,Remote),driver=>maps:get(driver,Remote),
            pins=>Pins,owner=>Owner,owner_mon=>OwnerMon,
            step=>0,status=>ready,vm_starts=>1,
            startup_us=>erlang:monotonic_time(microsecond)-Started}}
      catch Class:Why -> _=catch peer:stop(Peer),
          {stop,{target_vm_start_failed,Class,Why}} end;
      {error,Why} -> {stop,{target_vm_start_failed,Why}}
    end.

handle_call(info,_,S) ->
    Metrics=case maps:get(status,S) of
        ready->try peer:call(maps:get(peer,S),efz_target_vm,info,[],1000)
            catch _:_ -> #{} end;
        _->#{} end,
    {reply,maps:merge(maps:with([os_pid,driver,step,status,vm_starts,startup_us],S),Metrics),S};
handle_call({run,Input,Timeout},_,S=#{peer:=Peer,status:=ready}) ->
    Started=erlang:monotonic_time(microsecond),
    try peer:call(Peer,efz_target_vm,step,[Input,Timeout],Timeout+500) of
        {ok,Remote} when is_map(Remote) ->
            Result=Remote#{execution_ref=>make_ref(),
                execution_identities=>maps:get(pins,S),
                target_vm_elapsed_us=>erlang:monotonic_time(microsecond)-Started},
            %% Keep a bounded identity snapshot of target-owned OS children.
            %% A child may leave the VM process group with setsid while still
            %% remaining a descendant in /proc.
            {TreeStatus,Tree}=owned_descendants(maps:get(os_pid,S)),
            Next=S#{step=>maps:get(step,S)+1,
                owned_os=>merge_owned(maps:get(owned_os,S,[]),Tree)},
            case TreeStatus of
                limit ->
                    {reply,{error,{infrastructure,target_os_descendant_limit}},
                        retire(Next,force)};
                complete ->
                    case maps:get(runner_reusable,Result,false) of
                        true->{reply,{ok,Result},Next};
                        false->{reply,{ok,Result},retire(Next,force)}
                    end
            end;
        Other -> {reply,{error,{target_vm_protocol,Other}},retire(S,force)}
    catch exit:{timeout,_} ->
        Result=failed_result({timeout,Timeout},S,Started),
        {reply,{ok,Result},retire(S#{step=>maps:get(step,S)+1},force)};
    Class:Why -> {reply,{error,{target_vm_failure,Class,Why}},retire(S,force)}
    end;
handle_call({run,_,_},_,S) -> {reply,{error,epoch_retired},S};
handle_call(close,_,S) -> {stop,normal,ok,retire(S)};
handle_call(_,_,S) -> {reply,{error,unsupported_request},S}.
handle_cast(_,S) -> {noreply,S}.
handle_info({'DOWN',Mon,process,Owner,_},S=#{owner_mon:=Mon,owner:=Owner}) ->
    {stop,owner_down,S};
handle_info({'EXIT',Peer,_},S=#{peer:=Peer}) ->
    kill_group(maps:get(os_pid,S)),
    kill_owned(maps:get(owned_os,S,[])),
    {noreply,S#{status=>down}};
handle_info(_,S) -> {noreply,S}.
terminate(Reason,S) ->
    _=retire(S,case Reason of normal->orderly;_->force end),ok.
code_change(_,S,_) -> {ok,S}.

retire(S)->retire(S,orderly).
retire(#{status:=down}=S,_) -> S;
retire(S=#{peer:=Peer},Policy) ->
    {_,Tree}=owned_descendants(maps:get(os_pid,S)),
    Owned=merge_owned(maps:get(owned_os,S,[]),Tree),
    case Policy of
        force->kill_group(maps:get(os_pid,S));
        orderly->_=try peer:call(Peer,efz_target_vm,stop,[],500) catch _:_ -> ok end
    end,
    _=try peer:stop(Peer) catch _:_ -> kill_os(maps:get(os_pid,S)) end,
    kill_owned(Owned),
    S#{status=>down}.

%% /proc task children includes children launched by any BEAM scheduler thread.
%% The recorded start-time prevents signalling a recycled PID. This cleanup is
%% bounded and does not claim to capture a child that double-forked and was
%% reparented before the snapshot.
owned_descendants(Root) -> owned_descendants([Root],#{Root=>true},[],1024).
owned_descendants([],_,Found,_) -> {complete,Found};
owned_descendants(_,_,Found,0) -> {limit,Found};
owned_descendants([Pid|Rest],Seen,Found,Left) ->
    Children=lists:usort(lists:flatmap(fun(Path)->
        case file:read_file(Path) of
            {ok,Bin}->[list_to_integer(Token)||Token<-string:tokens(binary_to_list(Bin)," \t\n"),
                Token=/=[],lists:all(fun(C)->C>=$0 andalso C=<$9 end,Token)];
            _->[]
        end
    end,filelib:wildcard("/proc/"++integer_to_list(Pid)++"/task/*/children"))),
    New=[C||C<-Children,not maps:is_key(C,Seen)],
    Allowed=lists:sublist(New,Left),
    Entries=[{C,Start}||C<-Allowed,(Start=proc_start(C))=/=undefined],
    MoreSeen=lists:foldl(fun(C,A)->A#{C=>true} end,Seen,Allowed),
    case length(New)>Left of
        true->{limit,Entries++Found};
        false->owned_descendants(Rest++Allowed,MoreSeen,
            Entries++Found,Left-length(Allowed))
    end.

merge_owned(A,B) -> maps:values(maps:from_list([{Pid,{Pid,Start}}||
    {Pid,Start}<-A++B,proc_start(Pid)=:=Start])).

kill_owned(Entries) ->
    lists:foreach(fun({Pid,Start})->
        case proc_start(Pid) of Start->kill_os(Pid);_->ok end
    end,Entries).

proc_start(Pid) ->
    case file:read_file("/proc/"++integer_to_list(Pid)++"/stat") of
        {ok,Bin}->
            case binary:matches(Bin,<<") ">>) of
                []->undefined;
                Matches->
                    {At,_}=lists:last(Matches),
                    Tail=binary:part(Bin,At+2,byte_size(Bin)-At-2),
                    Fields=string:tokens(binary_to_list(Tail)," \t\n"),
                    case length(Fields)>=20 of
                        true->lists:nth(20,Fields);
                        false->undefined
                    end
            end;
        _->undefined
    end.
kill_group(Pid) when is_integer(Pid),Pid>1 ->
    case os:find_executable("kill") of
        false->kill_os(Pid);
        Kill->Port=open_port({spawn_executable,Kill},[exit_status,
            {args,["-KILL","--","-"++integer_to_list(Pid)]}]),
            receive {Port,{exit_status,0}}->ok;
                    {Port,{exit_status,_}}->kill_os(Pid)
            after 1000->port_close(Port),kill_os(Pid) end
    end.
kill_os(Pid) when is_integer(Pid),Pid>0 ->
    case os:find_executable("kill") of
        false->ok;
        Kill->Port=open_port({spawn_executable,Kill},[exit_status,
            {args,["-KILL",integer_to_list(Pid)]}]),
            receive {Port,{exit_status,_}}->ok after 1000->port_close(Port) end
    end.
failed_result(Outcome,S,Started) ->
    #{execution_ref=>make_ref(),outcome=>Outcome,coverage=>[],
      coverage_status=>{error,coverage_window_incomplete},
      coverage_observation=>efz_cov_integrity:observation([], {error,coverage_window_incomplete},[]),
      builds=>#{},execution_identities=>maps:get(pins,S),
      elapsed_us=>erlang:monotonic_time(microsecond)-Started,
      runner_reusable=>false,execution_model=>persistent_target_driver,
      cleanup=>#{status=>epoch_retired,violations=>[]},
      step=>maps:get(step,S)+1,driver=>maps:get(driver,S),os_pid=>maps:get(os_pid,S)}.
