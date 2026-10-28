%% Local process control. The campaign and providers retain all execution policy.
-module(efz_control).
-export([main/0, report_summary/2]).
-define(MAX_FRAME,8388608).

-spec main() -> no_return().
main() ->
    process_flag(trap_exit,true),
    {ok,Output}=file:open("/dev/stdout",[write,raw,binary]),
    Log=spawn_link(fun log_loop/0),
    true=group_leader(Log,self()),
    ok=redirect_logger(),
    Owner=self(),
    Reader=spawn_link(fun()->reader(Owner) end),
    try loop(#{output=>Output,reader=>Reader,campaign=>undefined,jobs=>#{},closing=>false,
               provider_session=>undefined,provider_busy=>false})
    after _=file:close(Output) end,
    halt(0).

redirect_logger()->
    %% logger_std_h rejects changing an existing handler's output device.
    %% Recreate it before any target can emit a report onto protocol stdout.
    {ok,H}=logger:get_handler_config(default),
    Config=maps:get(config,H),
    ok=logger:remove_handler(default),
    logger:add_handler(default,maps:get(module,H),
        (maps:without([id,module],H))#{config=>Config#{type=>standard_error}}).

%% Ordinary target IO is redirected away from the reserved protocol descriptor.
log_loop() ->
    receive
        {io_request,From,ReplyAs,Request}->
            Reply=try io:request(standard_error,Request) catch _:_->{error,terminated} end,
            From!{io_reply,ReplyAs,Reply}, log_loop();
        _->log_loop()
    end.
reader(Owner) ->
    case file:open("/dev/stdin",[read,raw,binary]) of
        {ok,F}->try read_frames(F,Owner) after file:close(F) end;
        {error,R}->Owner!{wire_error,R}
    end.
read_frames(F,Owner) ->
    case exact(F,4,[]) of
        eof->Owner!wire_eof;
        {ok,<<N:32/unsigned-big>>} when N>0,N=< ?MAX_FRAME ->
            case exact(F,N,[]) of
                {ok,B}->case efz_control_json:decode(B) of
                    {ok,M}->Owner!{wire,M},
                        %% Bound queued requests even if a client floods stdin.
                        receive read_next->read_frames(F,Owner) end;
                    {error,R}->Owner!{wire_error,R}
                end;
                _->Owner!{wire_error,truncated_frame}
            end;
        _->Owner!{wire_error,frame_length}
    end.
exact(_,0,Acc)->{ok,iolist_to_binary(lists:reverse(Acc))};
exact(F,N,Acc)->case file:read(F,min(N,65536)) of
    {ok,B} when byte_size(B)>0->exact(F,N-byte_size(B),[B|Acc]);
    eof when Acc=:=[]->eof;
    _->{error,truncated_frame}
end.

loop(S) ->
    receive
        {wire,M}->
            S1=accept(M,S),
            maps:get(reader,S)!read_next,
            loop(S1);
        {job_done,Id,Result}->
            {Job,Jobs}=maps:take(Id,maps:get(jobs,S)),
            {_Pid,Ref,Op}=Job, demonitor(Ref,[flush]),
            send(S,Id,Result),
            case Op of
                close->ok;
                mutate->loop(S#{jobs=>Jobs,provider_busy=>false});
                mutate_batch->loop(S#{jobs=>Jobs,provider_busy=>false});
                _->loop(S#{jobs=>Jobs})
            end;
        {campaign_done,Result}->
            C=maps:get(campaign,S),loop(S#{campaign=>C#{result=>Result}});
        {'DOWN',Ref,process,_,Reason}->
            Matching=[{Id,Op}||{Id,{_,R,Op}}<-maps:to_list(maps:get(jobs,S)),R=:=Ref],
            S1=lists:foldl(fun({Id,Op},Acc)->
                send(Acc,Id,{error,internal_error,Reason}),
                case Op of close->self()!wire_eof;_->ok end,
                Acc#{jobs=>maps:remove(Id,maps:get(jobs,Acc))}
            end,S,Matching),loop(S1);
        wire_eof->_=cleanup(S,5000),ok;
        {wire_error,R}->send(S,null,{error,protocol_error,R}),_=cleanup(S,5000),ok;
        {'EXIT',P,R}->
            case P=:=maps:get(reader,S) andalso R=/=normal of
                true->_=cleanup(S,5000),ok;
                false->loop(S)
            end;
        _->loop(S)
    end.
accept(M,S) ->
    try
        {Id,Op,A}=efz_control_json:request(M),
        false=maps:is_key(Id,maps:get(jobs,S)),
        true=map_size(maps:get(jobs,S))<64,
        case maps:get(closing,S) of
            true->send(S,Id,{error,cancelled,session_closing}),S;
            false->dispatch(Id,Op,A,S)
        end
    catch
        throw:{control_error,Code,Why}->send(S,request_id(M),{error,Code,Why}),S;
        _:Why->send(S,request_id(M),{error,bad_config,Why}),S
    end.
request_id(#{<<"id">>:=Id}) when is_integer(Id),Id>=0,Id=<9007199254740991->Id;
request_id(_)->null.
dispatch(Id,start,A,#{campaign:=undefined}=S) ->
    no_replay(S),
    efz_control_json:keys(A,[<<"config">>]),
    C0=efz_control_json:campaign(maps:get(<<"config">>,A)),
    add_paths(maps:get(code_paths,C0,[])),
    Out=filename:absname(maps:get(out,C0)),
    ok=need(efz_fs:directory(Out),storage_error),
    Artifacts=need(efz_instrument:discover(maps:get(artifacts,C0)),bad_config),
    Target=need(efz_cli:local_target(maps:get(target,C0),Artifacts),bad_config),
    C=(maps:without([out,code_paths],C0))#{target=>Target,artifacts=>Artifacts,
        crash_dir=>filename:join(Out,"crashes"),monitoring=>maps:get(monitoring,C0,true)},
    _=need(efz:start(C),bad_config),
    Parent=self(),
    spawn_link(fun()->Result=safely(fun()->save_report(efz:await(infinity),Out) end),
        Parent!{campaign_done,Result} end),
    send(S,Id,{ok,#{status=><<"running">>,out=>str(Out)}}),
    S#{campaign=>#{out=>Out,result=>pending}};
dispatch(_,start,_,_)->fail(bad_config,one_campaign_per_session);
dispatch(Id,stats,A,S) ->
    efz_control_json:keys(A,[]),C=campaign(S),
    Reply=case maps:get(result,C) of
        pending->#{status=><<"running">>,stats=>stats(efz:stats()),
            snapshot=>snapshot(efz_fuzzer:monitor_snapshot())};
        {ok,R}->R;
        {error,Code,R}->fail(Code,R)
    end,
    send(S,Id,{ok,Reply}),S;
dispatch(Id,request_stop,A,S) ->
    efz_control_json:keys(A,[]),_=campaign(S),
    ok=efz:request_stop(),send(S,Id,{ok,#{status=><<"stop_requested">>}}),S;
dispatch(Id,await_result,A,S) ->
    efz_control_json:keys(A,[<<"timeout_ms">>]),C=campaign(S),
    Timeout=wait_timeout(A),Out=maps:get(out,C),
    job(Id,await_result,fun()->save_report(efz:await(Timeout),Out) end,S);
dispatch(Id,close,A,S) ->
    efz_control_json:keys(A,[<<"timeout_ms">>]),
    Timeout=efz_control_json:integer(maps:get(<<"timeout_ms">>,A,5000),0,30000),
    job(Id,close,fun()->cleanup(S,Timeout) end,S#{closing=>true});
dispatch(_Id,mutate,_A,#{provider_busy:=true})->fail(provider_busy,mutation_request_in_flight);
dispatch(Id,mutate,A,S) ->
    Parsed=prepare_mutation(A),
    {Prepared,Runtime,S0}=prepare_mutation_runtime(Parsed,S),
    job(Id,mutate,fun()->mutate_one(Prepared,Runtime) end,
        S0#{provider_busy=>true});
dispatch(_Id,mutate_batch,_A,#{provider_busy:=true})->fail(provider_busy,mutation_request_in_flight);
dispatch(Id,mutate_batch,A,S) ->
    efz_control_json:keys(A,[<<"items">>]),Items=maps:get(<<"items">>,A),
    true=is_list(Items) andalso length(Items)>0 andalso length(Items)=<64,
    Prepared=[prepare_mutation(I)||I<-Items],
    true=lists:sum([byte_size(B)||{B,_,_,_}<-Prepared])=<2097152,
    true=lists:sum([Max||{_,_,_,Max}<-Prepared])=<2097152,
    [{_,Provider,_,Max}|_]=Prepared,
    true=lists:all(fun({_,P,_,M})->P=:=Provider andalso M=:=Max end,Prepared),
    {First,Runtime,S0}=prepare_mutation_runtime(hd(Prepared),S),
    [First|Rest]=Prepared,
    job(Id,mutate_batch,fun()->#{items=>mutate_items([First|Rest],Runtime)} end,
        S0#{provider_busy=>true});
dispatch(Id,cancel,A,S) ->
    efz_control_json:keys(A,[<<"target_id">>]),
    Target=efz_control_json:integer(maps:get(<<"target_id">>,A),1,9007199254740991),
    Result=case maps:find(Target,maps:get(jobs,S)) of
        {ok,{Pid,_Monitor,Op}} when Op=:=mutate;Op=:=mutate_batch ->
            Pid!{efz_mutation_cancel_run,make_ref()},#{status=><<"cancelling">>};
        _->#{status=><<"not_running">>}
    end,
    send(S,Id,{ok,Result}),S;
dispatch(Id,results,A,S) ->
    Out=results_out(A,S),
    Offset=efz_control_json:integer(maps:get(<<"offset">>,A,0),0,10000000),
    Limit=efz_control_json:integer(maps:get(<<"limit">>,A,32),1,100),
    job(Id,results,fun()->saved_results(Out,Offset,Limit) end,S);
dispatch(Id,raw_replay,A,S) ->
    efz_control_json:keys(A,[<<"input">>,<<"expect">>,<<"target">>,<<"artifacts">>,
        <<"code_paths">>,<<"timeout">>,<<"max_input_bytes">>]),
    case maps:get(campaign,S) of undefined->ok;_->fail(bad_config,replay_requires_fresh_session) end,
    no_replay(S),
    Prepared=prepare_replay(A),
    job(Id,raw_replay,fun()->raw_replay(Prepared) end,S).

no_replay(S) ->
    case lists:any(fun({_,{_,_,Op}})->Op=:=raw_replay end,maps:to_list(maps:get(jobs,S))) of
        true->fail(bad_config,replay_already_running);
        false->ok
    end.

job(Id,Op,F,S) ->
    Parent=self(),
    {P,Ref}=spawn_monitor(fun()->Parent!{job_done,Id,safely(F)} end),
    S#{jobs=>(maps:get(jobs,S))#{Id=>{P,Ref,Op}}}.
safely(F) ->
    try {ok,F()}
    catch
        throw:{control_error,C,R}->{error,C,R};
        exit:{timeout,_}->{error,request_timeout,await_timeout};
        C:R->{error,internal_error,{C,R}}
    end.
send(S,Id,Result) ->
    Envelope=case Result of
        {ok,R}->#{version=>1,id=>Id,ok=>true,result=>R};
        {error,C,R}->#{version=>1,id=>Id,ok=>false,error=>#{code=>C,message=>efz_control_json:text(R)}}
    end,
    B=efz_control_json:encode(Envelope),
    case byte_size(B)=< ?MAX_FRAME of
        true->ok=file:write(maps:get(output,S),<<(byte_size(B)):32/unsigned-big,B/binary>>);
        false->send(S,Id,{error,protocol_error,response_size_limit})
    end.
campaign(#{campaign:=undefined})->fail(bad_config,no_campaign);
campaign(S)->maps:get(campaign,S).
wait_timeout(A)->case maps:get(<<"timeout_ms">>,A,30000) of
    <<"infinity">>->infinity;N->efz_control_json:integer(N,0,86400000) end.
add_paths(Paths) -> lists:foreach(fun(P)->case code:add_pathz(filename:absname(P)) of
    true->ok;E->fail(bad_config,{code_path,P,E}) end end,Paths).
need(ok,_)->ok;
need({ok,V},_)->V;
need({error,R},C)->fail(C,R).
-spec fail(atom(),term()) -> no_return().
fail(C,R)->throw({control_error,C,R}).
str(L)->unicode:characters_to_binary(L).
hex(B)->binary:encode_hex(B,lowercase).

prepare_mutation(A) ->
    efz_control_json:keys(A,[<<"input">>,<<"provider">>,<<"request">>,<<"max_input_bytes">>]),
    Max=efz_control_json:integer(maps:get(<<"max_input_bytes">>,A,4096),0,1048576),
    Input=efz_control_json:bytes(maps:get(<<"input">>,A),Max),
    Provider=efz_control_json:provider(maps:get(<<"provider">>,A,<<"native">>)),
    Request=efz_control_json:mutation_request(maps:get(<<"request">>,A,#{})),
    true=maps:is_key(seed,Request),{Input,Provider,Request,Max}.
prepare_mutation_runtime({_Input,Provider,_Request,Max}=Item,S) ->
    Identity=crypto:hash(sha256,term_to_binary({Provider,Max},[deterministic])),
    Transport=case Provider of native->disposable;_->maps:get(transport,Provider,disposable) end,
    case Transport of
        persistent -> case maps:get(provider_session,S,undefined) of
            #{identity:=Identity,prepared:=P,pid:=Pid,ref:=SessionRef} ->
                case reusable_control_session(Pid,SessionRef) of
                    true->{Item,#{prepared=>P,session=>#{pid=>Pid,ref=>SessionRef}},S};
                    false->open_control_provider_session(Item,Provider,Max,
                        close_control_provider_session(S))
                end;
            _ ->
                open_control_provider_session(Item,Provider,Max,
                    close_control_provider_session(S))
        end;
        _ ->
            S0=close_control_provider_session(S),
            {Item,undefined,S0}
    end.

reusable_control_session(Pid,Ref)->
    case catch efz_mutation_session:stats(Pid,Ref) of
        #{phase:=ready}->true;
        #{phase:=recycling}->true;
        _->false
    end.

open_control_provider_session({_,Provider,_,Max}=Item,Provider,Max,S0)->
    P=need(efz_mutation_provider:prepare(Provider,Max),bad_config),
    case efz_mutation_session:open(self(),P) of
        {ok,Pid,SessionRef,_Runtime}->
            Monitor=erlang:monitor(process,Pid),
            Session=#{identity=>crypto:hash(sha256,
                term_to_binary({Provider,Max},[deterministic])),prepared=>P,
                pid=>Pid,ref=>SessionRef,monitor=>Monitor},
            {Item,#{prepared=>P,session=>#{pid=>Pid,ref=>SessionRef}},
             S0#{provider_session=>Session}};
        {error,Reason}->
            io:format(standard_error,"EFZ persistent provider startup failed: ~0p~n",[Reason]),
            fail(bad_config,Reason)
    end.

close_control_provider_session(#{provider_session:=#{pid:=Pid,ref:=Ref,
        monitor:=Monitor}}=S) ->
    Session=maps:get(provider_session,S),
    Timeout=maps:get(cleanup_timeout,maps:get(prepared,Session),3000),
    Result=catch efz_mutation_session:close(Pid,Ref,Timeout),
    erlang:demonitor(Monitor,[flush]),
    case Result of
        {ok,#{last_cleanup_confirmed:=true}}->maps:remove(provider_session,S);
        {ok,#{state:=down}}->maps:remove(provider_session,S);
        {error,Reason}->fail(provider_failure,{provider_session_cleanup,Reason});
        Other->fail(provider_failure,{provider_session_cleanup,Other})
    end;
close_control_provider_session(S)->S.

mutate_one({Input,Provider,Request,Max},Runtime) ->
    P=case Runtime of
        #{prepared:=Prepared}->Prepared;
        _->need(efz_mutation_provider:prepare(Provider,Max),bad_config)
    end,
    Mutated=case maps:get(transport,P,disposable) of
        persistent ->
            #{session:=#{pid:=Pid,ref:=SessionRef}}=Runtime,
            efz_mutation_provider:mutate_session(Input,Request,P,Pid,SessionRef,
                maps:get(timeout,P,1000));
        _ -> efz_mutation_provider:mutate(Input,Request,P)
    end,
    case Mutated of
        {ok,B,Recipe} when is_binary(B),B=/=Input,byte_size(B)=<Max ->
            #{status=><<"changed">>,input=>#{base64=>base64:encode(B)},
                input_sha256=>hex(crypto:hash(sha256,Input)),output_sha256=>hex(crypto:hash(sha256,B)),
                recipe=>provenance(Recipe),runtime=>mutation_runtime(Provider,Runtime)};
        {ok,Input,_}->#{status=><<"skipped">>,reason=><<"unchanged">>,
            runtime=>mutation_runtime(Provider,Runtime)};
        {skip,R}->#{status=><<"skipped">>,reason=>efz_control_json:text(R),
            runtime=>mutation_runtime(Provider,Runtime)};
        {timeout,R}->fail(provider_timeout,R);
        cancelled->fail(cancelled,provider_cancelled);
        {error,R}->fail(provider_failure,R);
        Other->fail(provider_failure,{invalid_provider_result,Other})
    end.
mutation_runtime(native,_) -> #{transport=>none};
mutation_runtime(#{mode:=native},_) -> #{transport=>none};
mutation_runtime(Provider,#{session:=#{pid:=Pid,ref:=Ref}}) ->
    Stats=efz_mutation_session:stats(Pid,Ref),
    (maps:with([state,vm_starts,restarts,completed_requests,requests_this_vm],Stats))#{
        transport=>maps:get(transport,Provider,disposable)};
mutation_runtime(Provider,_) -> #{transport=>maps:get(transport,Provider,disposable)}.
provenance(R) ->
    P=efz_control_json:portable(R),
    case byte_size(efz_control_json:encode(P))=<65536 of
        true->P;false->#{available=>false,reason=><<"metadata_limit">>}
    end.
safely_item({_,Provider,_,_}=P,Runtime) -> case safely(fun()->mutate_one(P,Runtime) end) of
    {ok,R}->R;{error,C,R}->#{status=><<"error">>,
        error=>#{code=>C,message=>efz_control_json:text(R)},
        runtime=>mutation_runtime(Provider,Runtime)} end.

mutate_items([],_) -> [];
mutate_items([P|Rest],Runtime)->
    Item=safely_item(P,Runtime),
    case Item of
        #{error:=#{code:=cancelled}}->[Item|[cancelled_item()||_<-Rest]];
        _->[Item|mutate_items(Rest,Runtime)]
    end.
cancelled_item()->#{status=><<"error">>,error=>#{code=>cancelled,message=><<"Session closed">>}}.

cleanup(S,Timeout) ->
    Deadline=erlang:monotonic_time(millisecond)+Timeout,
    R=case maps:get(campaign,S) of
        undefined->null;
        C->case maps:get(result,C) of
            {ok,Final}->Final;
            {error,Code,Why}->fail(Code,Why);
            pending->ok=efz:request_stop(),
                save_report(efz:await(Timeout),maps:get(out,C))
        end
    end,
    %% Mutation replies follow OS cleanup; acknowledge close after their jobs.
    cancel_jobs(maps:values(maps:get(jobs,S)),Deadline),
    _=close_control_provider_session(S),
    ok=case whereis(efz_fuzzer) of undefined->ok;_->need(efz:stop(),internal_error) end,
    #{status=><<"closed">>,report=>R}.

cancel_jobs(Jobs,Deadline)->
    Monitors=[begin
        Ref=monitor(process,P),
        _ = case Op of
            mutate->P!{efz_mutation_cancel_run,make_ref()};
            mutate_batch->P!{efz_mutation_cancel_run,make_ref()};
            _->exit(P,shutdown)
        end,
        {P,Ref}
    end||{P,_,Op}<-Jobs,P=/=self()],
    await_jobs(Monitors,Deadline).
await_jobs([],_)->ok;
await_jobs([{P,Ref}|Rest],Deadline)->
    Remaining=max(0,Deadline-erlang:monotonic_time(millisecond)),
    receive {'DOWN',Ref,process,P,_}->await_jobs(Rest,Deadline)
    after Remaining->
        lists:foreach(fun({Pid,Mon})->exit(Pid,kill),demonitor(Mon,[flush]) end,[{P,Ref}|Rest]),
        fail(request_timeout,close_cleanup_timeout)
    end.
save_report(R,Out) ->
    ok=need(efz_fs:atomic_file(filename:join(Out,"report.term"),term_to_binary(R)),storage_error),
    Summary=report_summary(R,Out),
    ok=need(efz_fs:atomic_file(filename:join(Out,"report.json"),efz_control_json:encode(Summary)),storage_error),
    Summary.
report_summary(R,Out) ->
    Base=#{schema_version=>1,status=>status(maps:get(status,R)),
      stats=>stats(maps:get(stats,R,#{})),coverage_count=>length(maps:get(coverage,R,[])),
      corpus_size=>length(maps:get(corpus,R,[])),
      paths=>#{out=>str(Out),report=>str(filename:join(Out,"report.term")),
          summary=>str(filename:join(Out,"report.json")),crashes=>str(filename:join(Out,"crashes"))}},
    maps:merge(Base,snapshot(maps:with([provider,provider_stats],R))).
status(A) when is_atom(A)->atom_to_binary(A,utf8);
status({A,R}) when is_atom(A)->#{kind=>atom_to_binary(A,utf8),reason=>efz_control_json:text(R)};
status(T)->efz_control_json:text(T).
stats(M)->maps:from_list([{K,V}||{K,V}<-maps:to_list(M),is_atom(K),is_integer(V)]).
snapshot(M) ->
    %% Most snapshot binaries are text. Provider identities also contain hashes.
    maps:from_list([{snapshot_key(K),snapshot_value(V)}||{K,V}<-maps:to_list(M)]).
snapshot_key(K) when is_atom(K)->atom_to_binary(K,utf8);
snapshot_key(K) when is_binary(K)->case unicode:characters_to_binary(K) of
    K->K;_-><<"hex:",(binary:encode_hex(K,lowercase))/binary>> end;
snapshot_key(K)->efz_control_json:text(K).
snapshot_value(M) when is_map(M)->snapshot(M);
snapshot_value(L) when is_list(L)->[snapshot_value(V)||V<-L];
snapshot_value(A) when A=:=true;A=:=false;A=:=null->A;
snapshot_value(A) when is_atom(A)->atom_to_binary(A,utf8);
snapshot_value(B) when is_binary(B)->case unicode:characters_to_binary(B) of
    B->B;_->#{<<"base64">>=>base64:encode(B)} end;
snapshot_value(T) when is_tuple(T)->efz_control_json:text(T);
snapshot_value(V)->V.

results_out(A,S) ->
    efz_control_json:keys(A,[<<"out">>,<<"offset">>,<<"limit">>]),
    case maps:find(<<"out">>,A) of
        {ok,P}->filename:absname(efz_control_json:path(P));
        error->maps:get(out,campaign(S))
    end.
saved_results(Out,Offset,Limit) ->
    Summary=case efz_fs:read_bounded(filename:join(Out,"report.json"),65536) of
        {ok,B}->need(efz_control_json:decode(B),storage_error);
        {error,#{reason:=enoent}}->null;
        E->need(E,storage_error)
    end,
    Crashes=filename:join(Out,"crashes"),
    Names=case file:list_dir(Crashes) of {ok,Ns}->Ns;{error,enoent}->[];
        {error,DirectoryError}->fail(storage_error,DirectoryError) end,
    true=length(Names)=<10000,
    Groups=lists:sort([N||N<-Names,length(N)=:=64,lists:all(fun hexchar/1,N)]),
    Page=lists:sublist(lists:nthtail(min(Offset,length(Groups)),Groups),Limit),
    Findings=[finding(filename:join(Crashes,G))||G<-Page],
    Next=case Offset+length(Page)<length(Groups) of true->Offset+length(Page);false->null end,
    #{summary=>Summary,findings=>Findings,next_offset=>Next}.
hexchar(C)->(C>=$0 andalso C=<$9) orelse (C>=$a andalso C=<$f).
finding(Group) ->
    I=need(efz_crash_store:read(Group),storage_error),
    #{signature=>hex(maps:get(signature_id,I)),occurrences=>maps:get(occurrences,I),
      representatives=>[begin
          Prefix=filename:join([Group,binary_to_list(hex(Occ)),"artifact"]),
          #{input=>str(Prefix++".input"),expect=>str(Prefix++".replay"),
            input_sha256=>hex(Hash)}
      end||{Occ,Hash}<-maps:get(representatives,I)]}.
prepare_replay(A) ->
    Paths=maps:get(<<"code_paths">>,A,[]),true=is_list(Paths) andalso length(Paths)=<64,
    add_paths([efz_control_json:path(P)||P<-Paths]),
    Input=efz_control_json:path(maps:get(<<"input">>,A)),
    Expect=efz_control_json:path(maps:get(<<"expect">>,A,str(filename:rootname(Input)++".replay"))),
    Artifacts=need(efz_instrument:discover(efz_control_json:path(maps:get(<<"artifacts">>,A))),bad_config),
    Name=maps:get(<<"target">>,A),true=is_binary(Name),
    Target=need(efz_cli:local_target(binary_to_list(Name),Artifacts),bad_config),
    Options=maps:from_list([{K,efz_control_json:integer(V,0,Max)}||{K,Max}<-[{timeout,3600000},{max_input_bytes,1048576}],
        {ok,V}<-[maps:find(atom_to_binary(K,utf8),A)]]),
    {Input,Expect,Target,Artifacts,Options}.
raw_replay({Input,Expect,Target,Artifacts,Options}) ->
    E=need(efz_replay:load(Expect),bad_config),
    R=need(efz_replay:run(raw,Input,Target,Artifacts,E,Options),replay_failure),
    #{status=>status(maps:get(status,R)),input_sha256=>hex(maps:get(input_hash,R)),
      compatibility=><<"verified">>,target_executions=>1,
      outcome=>efz_control_json:text(maps:get(outcome,maps:get(result,R),unavailable))}.
