%% Bounded representatives and a durable occurrence counter, not a checkpoint.
%% A directory lock excludes independent VMs as well as local writers. An
%% interrupted writer leaves explicit evidence; never guess that its lock is stale.
-module(efz_crash_store).
-export([save/4, read/1]).
-define(MAX_INDEX,16384).

save(Dir,Identity,Limit,Write) ->
    Group=filename:absname(filename:join(Dir,hex(maps:get(signature_id,Identity)))),
    case efz_fs:directory(Group) of
        ok->locked(Group,fun()->save_locked(Group,Identity,Limit,Write) end);
        Error->Error
    end.
locked(Group,Fun) ->
    Lock=filename:join(Group,".lock"),
    case file:make_dir(Lock) of
        ok->
            Result=protect(Fun),
            Release=case file:del_dir(Lock) of
                ok->efz_fs:sync_directory(Group);
                {error,Why}->{error,io_error(unlock,Lock,Why)}
            end,
            case {Result,Release} of
                {{error,E},{error,R}}->{error,E#{lock_release_error=>R}};
                {_,ok}->Result;
                {{ok,Info},{error,E}}->{error,E#{committed=>Info}}
            end;
        {error,eexist}->{error,#{kind=>crash_storage,operation=>lock,path=>Lock,
            reason=>writer_active_or_interrupted}};
        {error,Why}->{error,io_error(lock,Lock,Why)}
    end.
save_locked(Group,I,Limit,Write) ->
    Sig=maps:get(signature_id,I),Occ=maps:get(occurrence_id,I),Hash=maps:get(input_hash,I),
    Index=load(Group,Sig),Reps=maps:get(representatives,Index),
    check(length(Reps)=<Limit,Group,{representative_limit_below_existing,length(Reps),Limit}),
    validate_files(Group,Reps),
    %% A caller retry with the same last occurrence is idempotent. Normal saves
    %% allocate a fresh occurrence ID even when input bytes are identical.
    Retry=maps:get(last_occurrence_id,Index)=:=Occ,
    case Retry of true->check(maps:get(last_input_hash,Index)=:=Hash,Group,occurrence_identity_mismatch);false->ok end,
    {NextReps,Info}=case lists:keyfind(Hash,2,Reps) of
        {Rep,Hash}->{Reps,#{storage=>duplicate,path=>prefix(Group,Rep),representative_occurrence_id=>Rep}};
        false when length(Reps)<Limit,not Retry ->
            Path=need(Write(Group,hex(Occ))),
            {Reps++[{Occ,Hash}],#{storage=>saved,path=>Path,representative_occurrence_id=>Occ}};
        false->{Reps,#{storage=>limit_reached}}
    end,
    Count=maps:get(occurrences,Index),
    Next=case Retry of
        true->Index;
        false->check(Count<16#ffffffffffffffff,Group,occurrence_counter_exhausted),
            Index#{occurrences=>Count+1,last_occurrence_id=>Occ,last_input_hash=>Hash,
                first_occurrence_id=>case Count of 0->Occ;_->maps:get(first_occurrence_id,Index) end,
                representatives=>NextReps}
    end,
    case efz_fs:atomic_file(filename:join(Group,"summary"),encode(Next)) of
        ok->{ok,Info#{durable_occurrences=>maps:get(occurrences,Next),
            disk_representatives=>length(NextReps),group_path=>Group}};
        {error,E}->
            Extra=case Info of #{storage:=saved,path:=P}->#{saved_artifact=>P};_->#{} end,
            {error,maps:merge(E,Extra)}
    end.

%% The reader does not import raw .term diagnostics. Its bounded schema only
%% contains counts, binary identities and selected representative IDs/hashes.
read(Group) -> protect(fun()->
    Index=read_index(filename:join(Group,"summary")),
    validate_files(Group,maps:get(representatives,Index)),{ok,Index}
end).
load(Group,Sig) ->
    Path=filename:join(Group,"summary"),
    case efz_fs:read_bounded(Path,?MAX_INDEX) of
        {ok,B}->I=decode(B,Path),check(maps:get(signature_id,I)=:=Sig,Path,signature_mismatch),I;
        {error,#{reason:=enoent}}->
            %% Legacy archives remain replayable and are never silently deleted
            %% or treated as a fresh empty store (which would bypass the cap).
            Names=need_fs(file:list_dir(Group),list_directory,Group)--[".lock"],
            check(Names=:=[],Group,{unindexed_crash_group,Names}),
            #{schema_version=>1,signature_id=>Sig,occurrences=>0,first_occurrence_id=>none,
              last_occurrence_id=>none,last_input_hash=>none,representatives=>[]};
        {error,E}->throw({store,E})
    end.
read_index(Path)->decode(need(efz_fs:read_bounded(Path,?MAX_INDEX)),Path).
encode(I)->B=term_to_binary(I),<<"EFZG",1,(byte_size(B)):32,(crypto:hash(sha256,B))/binary,B/binary>>.
decode(B,Path)->
    try
        <<"EFZG",1,N:32,H:32/binary,P:N/binary>>=B,
        true=crypto:hash(sha256,P)=:=H,<<131,116,_/binary>>=P,
        I=binary_to_term(P,[safe]),true=valid(I),I
    catch error:_->fail(Path,invalid_crash_summary) end.
valid(#{schema_version:=1,signature_id:=S,occurrences:=N,first_occurrence_id:=F,
        last_occurrence_id:=L,last_input_hash:=H,representatives:=Rs}=I) ->
    map_size(I)=:=7 andalso hash(S,32) andalso is_integer(N) andalso N>0 andalso N=<16#ffffffffffffffff andalso
    hash(F,16) andalso hash(L,16) andalso hash(H,32) andalso is_list(Rs) andalso
    length(Rs)>0 andalso length(Rs)=<32 andalso length(Rs)=<N andalso
    lists:all(fun({O,B})->hash(O,16) andalso hash(B,32);(_)->false end,Rs) andalso
    length(Rs)=:=length(lists:usort([O||{O,_}<-Rs])) andalso
    length(Rs)=:=length(lists:usort([B||{_,B}<-Rs]));
valid(_)->false.
validate_files(Group,Reps)->
    Names=need_fs(file:list_dir(Group),list_directory,Group),
    Expected=["summary",".lock"]++[hex(O)||{O,_}<-Reps],
    check(Names--Expected=:=[],Group,{unindexed_or_interrupted_write,Names--Expected}),
    lists:foreach(fun({Occ,Hash})->
        P=prefix(Group,Occ),
        need(efz_fs:validate_group(filename:dirname(P))),
        B=need(efz_input:read_file(P++".input",efz_input:hard_limit(),crash_representative)),
        check(crypto:hash(sha256,B)=:=Hash,P,representative_hash_mismatch)
    end,Reps).
prefix(Group,Occ)->filename:join([Group,hex(Occ),"artifact"]).
hash(B,N)->is_binary(B) andalso byte_size(B)=:=N.
hex(B)->binary_to_list(binary:encode_hex(B,lowercase)).
need(ok)->ok;
need({ok,V})->V;
need({error,E})->throw({store,E}).
need_fs({ok,V},_,_)->V;
need_fs({error,Why},Op,Path)->throw({store,io_error(Op,Path,Why)}).
io_error(Op,Path,Why)->#{kind=>filesystem,operation=>Op,path=>Path,reason=>Why}.
check(true,_,_)->ok;
check(false,Path,Why)->fail(Path,Why).
-spec fail(term(),term())->no_return().
fail(Path,Why)->throw({store,#{kind=>crash_storage,operation=>validate,path=>Path,reason=>Why}}).
protect(F)->try F() catch throw:{store,E}->{error,E} end.
