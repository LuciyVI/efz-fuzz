-module(efz_crash).
-export([defaults/0, prepare/1, signature/2, fingerprint/3, identify/3, save/4, remember/3]).

defaults() -> #{reason=>category,max_frames=>5,max_representatives=>3}.
prepare(P) when is_map(P) ->
    C=maps:merge(defaults(),P),
    case maps:keys(P)--maps:keys(defaults()) of
        [] -> case C of
            #{reason:=R,max_frames:=F,max_representatives:=N}
              when (R=:=category orelse R=:=exact orelse R=:=ignore),
                   is_integer(F),F>=1,F=<32,is_integer(N),N>=1,N=<32 -> {ok,C};
            _ -> {error,invalid_crash_policy}
        end;
        _ -> {error,unknown_crash_policy_keys}
    end;
prepare(_) -> {error,invalid_crash_policy}.

%% Signature is a versioned classification; diagnostics retain the raw term.
fingerprint(C,R,Stack) -> element(1,signature({crash,C,R,Stack},defaults())).
signature(Outcome,Policy) ->
    {Class,Reason,Stack}=case Outcome of
        {crash,C,R,St}->{C,R,St};
        {exit,R}->{exit,R,[]};
        {timeout,_}->{timeout,deadline,[]}
    end,
    Mode=maps:get(reason,Policy),
    NormalReason=reason(Reason,Mode),Frames=frames(Stack,maps:get(max_frames,Policy)),
    Normal=#{schema_version=>2,class=>Class,reason_policy=>Mode,
        reason=>NormalReason,frames=>Frames},
    %% Map ETF order may depend on the VM atom table. Hash an explicit wire
    %% order; stable/1 also encodes Reason maps as sorted lists of pairs.
    Wire={efz_crash_signature,2,Class,Mode,NormalReason,Frames},
    {crypto:hash(sha256,term_to_binary(Wire)),Normal}.
frames(Stack,N) -> lists:sublist(lists:filtermap(fun
    ({M,F,A,_}) when is_atom(M),is_atom(F) -> frame(M,F,A);
    ({M,F,A}) when is_atom(M),is_atom(F) -> frame(M,F,A);
    (_) -> false
end,Stack),N).
frame(M,F,A) ->
    case lists:member(M,[efz_executor,efz_guardian,efz_cov,efz_cov_rt,efz_cov_integrity]) of
        true -> false;
        false when is_integer(A),A>=0 -> {true,{M,F,A}};
        false when is_list(A) -> {true,{M,F,length(A)}};
        false -> false
    end.
reason(_,ignore) -> ignored;
reason(R,category) when is_atom(R) -> {tag,R};
reason(R,category) when is_tuple(R),tuple_size(R)>0,is_atom(element(1,R)) -> {tag,element(1,R)};
reason(R,category) -> type(R);
reason(R,exact) -> stable(R).
type(R) when is_integer(R)->integer;
type(R) when is_float(R)->float;
type(R) when is_bitstring(R)->bitstring;
type(R) when is_tuple(R)->tuple;
type(R) when is_map(R)->map;
type(R) when is_pid(R)->pid;
type(R) when is_port(R)->port;
type(R) when is_reference(R)->reference;
type(R) when is_function(R)->function;
type(_)->list.
%% Runtime identities never enter a signature, even in value-sensitive mode.
%% Typed encodings keep a pid distinct from the user atom 'pid'. Paths inside
%% an exact Reason remain data by explicit policy; stack paths are always absent.
stable(R) when is_pid(R);is_port(R);is_reference(R);is_function(R) -> {runtime,type(R)};
stable(R) when is_tuple(R) -> {tuple,[stable(X)||X<-tuple_to_list(R)]};
stable(R) when is_map(R) -> {map,lists:sort([{stable(K),stable(V)}||{K,V}<-maps:to_list(R)])};
stable([H|T]) -> {cons,stable(H),stable(T)};
stable([]) -> nil;
stable(R) -> {value,R}.

identify(Input,Result,Policy) ->
    {Sig,Normal}=signature(maps:get(outcome,Result),Policy),
    #{id=>Sig,group_id=>Sig,signature_id=>Sig,crash_signature=>Normal,
      occurrence_id=>crypto:strong_rand_bytes(16),input_hash=>crypto:hash(sha256,Input)}.

%% Full artifacts are immutable representatives. Every successful save counts
%% the occurrence durably, including duplicates and inputs beyond the disk cap.
save(Input,Result,Metadata,Dir) when not is_map(Dir) ->
    save(Input,Result,Metadata,#{crash_dir=>Dir});
save(Input,Result,Metadata,#{crash_dir:=Dir}=Options) ->
    {ok,Policy}=prepare(maps:get(crash_policy,Options,#{})),
    Identity=case maps:find(crash_identity,Options) of {ok,I}->I;error->identify(Input,Result,Policy) end,
    Hash=maps:get(input_hash,Identity),Key=maps:get(signature_id,Identity),
    Max=maps:get(max_input_bytes,Options,efz_input:default_limit()),
    Context=Identity#{crash_fingerprint=>Key},
    case efz_input:check(Input,Max,crash_input) of
        {error,E} -> {error,maps:merge(E,Context)};
        ok ->
            {RecipeFiles,RecipeError}=case recipe_file(Metadata,Input,Max) of
                {ok,Fs}->{Fs,none};
                {error,Why}->{[],#{kind=>artifact,operation=>encode_recipe,path=>Dir,reason=>Why}}
            end,
            Write=fun(GroupDir,Name)->
                Expected=efz_replay:expectation(Result,Policy,Hash,Key,Max),
                Payload=Identity#{format=>efz_crash,schema_version=>2,result=>Result,
                    metadata=>Metadata,max_input_bytes=>Max,crash_policy=>Policy,recipe_error=>RecipeError},
                Files=[{"artifact.input",Input},{"artifact.term",term_to_binary(Payload)},
                       {"artifact.replay",efz_replay:encode(Expected)}|RecipeFiles],
                case efz_fs:atomic_group(GroupDir,Name,Files) of
                    {ok,Location}->{ok,filename:join(Location,"artifact")};Error->Error end
            end,
            case efz_crash_store:save(Dir,Identity,maps:get(max_representatives,Policy),Write) of
                {ok,Stored}->
                    case RecipeError of
                        none->{ok,maps:merge(Identity#{input=>Input,result=>Result,metadata=>Metadata},Stored)};
                        E->Extra=case maps:find(path,Stored) of {ok,P}->#{saved_artifact=>P};error->#{} end,
                            {error,maps:merge(maps:merge(E,Context),Extra#{retention=>Stored})}
                    end;
                {error,E}->Failure=case RecipeError of none->E;R->R#{storage_error=>E} end,
                    {error,maps:merge(Failure,Context)}
            end
    end.

%% Both report and disk keep bounded representatives. Report counts describe
%% this campaign; durable_occurrences counts committed events across campaigns.
remember(Crash,Groups,Limit) ->
    Id=maps:get(group_id,Crash),Occ=maps:get(occurrence_id,Crash),
    case maps:find(Id,Groups) of
        error -> G=Crash#{occurrences=>1,representatives=>[Crash],first_occurrence_id=>Occ,last_occurrence_id=>Occ},
                 {true,true,Groups#{Id=>G}};
        {ok,G} ->
            Reps=maps:get(representatives,G),
            Add=length(Reps)<Limit andalso not lists:any(fun(R)->maps:get(input_hash,R)=:=maps:get(input_hash,Crash) end,Reps),
            Next=(maps:merge(G,maps:with([durable_occurrences,disk_representatives,group_path],Crash)))#{
                occurrences=>maps:get(occurrences,G)+1,last_occurrence_id=>Occ,
                representatives=>case Add of true->Reps++[Crash];false->Reps end},
            {false,Add,Groups#{Id=>Next}}
    end.
recipe_file(Metadata,Input,Max) ->
    case maps:find(mutation,Metadata) of
        error -> {ok,[]};
        {ok,R} -> case efz_recipe:regenerate(R,#{max_input_bytes=>Max}) of
            {ok,Input} -> case efz_recipe:encode(R) of
                {ok,B} -> {ok,[{"artifact.recipe",B}]}; Error -> Error
            end;
            {ok,_} -> {error,crash_recipe_input_mismatch};
            Error -> Error
        end
    end.
