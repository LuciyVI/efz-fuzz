%% Bounded independent runtime finding store. Manifest publication precedes index;
%% an interrupted publication is an explicit error on reopen, never silently adopted.
-module(efz_runtime_store).
-export([new/0, save/5, load/1, portable/1, report/1]).
new()->#{loaded=>false,groups=>#{},metadata_bytes=>0,suppressed=>0,dropped=>0,occurrences=>0}.
report(S)->maps:without([loaded],S).
save(Dir,Input,Record,Policy,S0)->
    case efz_fs:directory(Dir) of
        ok->Lock=filename:join(Dir,".writer-lock"),
            case file:open(Lock,[write,binary,exclusive]) of
                {ok,F}->
                    Result=try save_locked(Dir,Input,Record,Policy,S0)
                        catch Class:Why->{error,{runtime_storage,Class,Why}} end,
                    Closed=file:close(F),Deleted=file:delete(Lock),
                    case {Result,Closed,Deleted} of
                        {{error,_},_,_}->Result;
                        {_,ok,ok}->Result;
                        _->{error,{runtime_store_lock_release,Closed,Deleted}} end;
                {error,Why}->{error,{runtime_store_locked_or_unavailable,Why}} end;
        Error->Error end.
save_locked(Dir,Input,Record,Policy,S0)->
    case restore(Dir,S0) of
        {error,_}=Error->Error;
        {ok,S}->case within(S,Policy) andalso map_size(maps:get(groups,S))=<maps:get(max_groups,Policy) andalso
            lists:all(fun(G)->length(maps:get(representatives,G))=<maps:get(max_representatives,Policy) end,maps:values(maps:get(groups,S))) of
            true->save_loaded(Dir,Input,Record,Policy,S);
            false->{error,runtime_store_policy_limit} end
    end.
save_loaded(Dir,B,R,P,S)->
    Category=maps:get(category,R),
    Id=crypto:hash(sha256,term_to_binary({1,Category,maps:get(scope,R),maps:get(harness,R),maps:get(target_builds,R)},[deterministic])),
    H=crypto:hash(sha256,B),Groups=maps:get(groups,S),
    G=maps:get(Id,Groups,#{category=>Category,occurrences=>0,representatives=>[]}),
    Reps=maps:get(representatives,G),
    Seen=lists:any(fun(#{input_hash:=X})->X=:=H end,Reps),
    Allowed=(maps:is_key(Id,Groups) orelse map_size(Groups)<maps:get(max_groups,P)) andalso length(Reps)<maps:get(max_representatives,P),
    Record=R#{schema_version=>1,input_hash=>H,signature_id=>Id},
    Size=erlang:external_size(Record),
    ManifestSize=erlang:external_size({efz_artifacts,1,[{"artifact.input",byte_size(B),H},
        {"artifact.term",Size,<<0:256>>}]}),
    MetadataSize=Size+ManifestSize,
    S1=S#{occurrences=>maps:get(occurrences,S)+1},
    G1=G#{occurrences=>maps:get(occurrences,G)+1},
    Counted=case maps:is_key(Id,Groups) of true->S1#{groups=>Groups#{Id=>G1}};false->S1 end,
    case {Seen,Allowed,Size=<maps:get(max_metadata_bytes,P)} of
        {true,_,_}->commit(Dir,S1#{groups=>Groups#{Id=>G1},suppressed=>maps:get(suppressed,S)+1},P);
        {false,true,true}->
            Name=binary_to_list(binary:encode_hex(Id,lowercase))++"-"++binary_to_list(binary:encode_hex(H,lowercase)),
            Rep=#{input_hash=>H,path=>filename:join(Dir,Name),metadata_bytes=>MetadataSize},
            Next=S1#{metadata_bytes=>maps:get(metadata_bytes,S)+MetadataSize,groups=>Groups#{Id=>G1#{representatives=>Reps++[Rep]}}},
            case within(Next,P) of
                false->drop(Dir,Counted,P);
                true->case efz_fs:atomic_group(Dir,Name,[{"artifact.input",B},{"artifact.term",term_to_binary(Record,[deterministic])}]) of
                    {ok,_}->commit(Dir,Next,P);
                    Error->Error
                end
            end;
        _->drop(Dir,Counted,P)
    end.
drop(Dir,S,P)->commit(Dir,S#{dropped=>maps:get(dropped,S)+1},P).
within(S,P)->IndexBytes=37+erlang:external_size(S),
    IndexBytes=<4194304 andalso maps:get(metadata_bytes,S)+IndexBytes=<maps:get(max_total_metadata_bytes,P).
commit(Dir,S,P)->case within(S,P) of
    false->{error,runtime_index_exceeds_metadata_limit};
    true->case efz_fs:atomic_file(filename:join(Dir,"index"),envelope(S)) of
        ok->{ok,S};Error->Error end end.
envelope(S)->B=term_to_binary(S,[deterministic]),<<"EFZO",1,(crypto:hash(sha256,B))/binary,B/binary>>.
restore(Dir,#{loaded:=true}=S)->
    case efz_fs:read_bounded(filename:join(Dir,"index"),4194304) of
        {ok,B}->case B=:=envelope(S) of true->{ok,S};false->{error,stale_runtime_store} end;
        Error->Error end;
restore(Dir,S)->
    case file:list_dir(Dir) of
        {error,enoent}->{ok,S#{loaded=>true}};
        {error,E}->{error,{runtime_store_directory,E}};
        {ok,[".writer-lock"]}->{ok,S#{loaded=>true}};
        {ok,Names}->case efz_fs:read_bounded(filename:join(Dir,"index"),4194304) of
            {ok,<<"EFZO",1,H:32/binary,B/binary>>}->
                try
                    true=crypto:hash(sha256,B)=:=H,<<131,116,_/binary>>=B,
                    I=binary_to_term(B,[safe]),true=is_map(I),
                    G=maps:get(groups,I),true=map_size(G)=<1024,
                    Reps=lists:append([maps:get(representatives,X)||X<-maps:values(G)]),
                    true=length(Reps)=<16384,
                    true=lists:sum([maps:get(metadata_bytes,R)||R<-Reps])=:=maps:get(metadata_bytes,I),
                    true=lists:all(fun(R)->N=maps:get(metadata_bytes,R),is_integer(N) andalso N>=0 andalso N=<4202496 end,Reps),
                    true=lists:all(fun(K)->N=maps:get(K,I),is_integer(N) andalso N>=0 end,[metadata_bytes,occurrences,dropped,suppressed]),
                    Expected=lists:sort([filename:basename(maps:get(path,R))||R<-Reps]),
                    true=lists:sort(Names--["index",".writer-lock"])=:=Expected,
                    %% Every committed artifact is checked; corrupt stores do not bypass quotas.
                    lists:foreach(fun(R)->ok=efz_fs:validate_group(filename:join(Dir,filename:basename(maps:get(path,R)))) end,Reps),
                    {ok,I#{loaded=>true}}
                catch _:_->{error,corrupt_or_interrupted_runtime_store} end;
            _->{error,corrupt_or_interrupted_runtime_store}
        end
    end.
load(Dir)->
    _=code:ensure_loaded(efz_recipe),_=code:ensure_loaded(efz_mutation),
    _=code:ensure_loaded(efz_mutation_plan),_=code:ensure_loaded(efz_runtime_config),
    case efz_fs:validate_group(Dir) of
        ok->case efz_fs:read_bounded(filename:join(Dir,"artifact.term"),4194304) of
            {ok,B}->try
                <<131,116,_/binary>>=B,R=binary_to_term(B,[safe]),
                #{schema_version:=1,input_hash:=H,policy:=P,category:=C,
                  coverage_mode:=Mode,scope:=Scope,origin:=Origin,harness:=Harness,target_builds:=Builds,
                  original_outcome:=_,evidence:=_,mutation:=_,timeout:=Timeout,signature_id:=Sig,max_input_bytes:=_}=R,
                true=map_size(R)=:=15,
                true=lists:member(Mode,[automatic,manual]),
                true=lists:member(Origin,[calibration,mutation,verification]),
                true=is_map(Harness) andalso is_list(Builds),
                true=is_integer(Timeout) andalso Timeout>=0,
                true=is_binary(Sig) andalso byte_size(Sig)=:=32,
                true=Scope=:=case C of vm_memory_growth_suspected->vm_global;_->target_owned end,
                true=lists:member(C,[vm_memory_growth_suspected,unstable_outcome,unstable_coverage,unstable_return,memory_pressure,
                    memory_growth_suspected,mailbox_pressure,ets_growth_suspected,descendant_activity,
                    child_abnormal_exit,timeout_busy,timeout_waiting,timeout_unknown]),
                {ok,PreparedPolicy}=efz_runtime_config:prepare(P),
                {ok,Input}=efz_input:read_file(filename:join(Dir,"artifact.input"),maps:get(max_input_bytes,R),runtime_replay),
                true=crypto:hash(sha256,Input)=:=H,{ok,R#{policy=>PreparedPolicy},Input}
            catch _:_->{error,invalid_runtime_finding} end;
            Error->Error end;
        Error->Error
    end.
%% All target atoms become UTF-8 data; PID/reference/function identities are not replay selectors.
portable(A) when is_atom(A)->atom_to_binary(A,utf8);
portable(M) when is_map(M)->maps:from_list([{portable(K),portable(V)}||{K,V}<-maps:to_list(M)]);
portable(T) when is_tuple(T)->list_to_tuple([portable(X)||X<-tuple_to_list(T)]);
portable([H|T])->[portable(H)|portable(T)];
portable([])->[];
portable(P) when is_pid(P);is_reference(P);is_port(P);is_function(P)-><<"runtime_identity">>;
portable(X)->X.
