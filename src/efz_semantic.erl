%% Versioned, exact finite namespace. No ETF/ETS state in the callback path.
-module(efz_semantic).
-export([valid/1, metadata/1, features/1, cover/1, representatives/1]).
valid(Fs) -> valid_features(Fs,64) andalso efz_qs_legacy:valid_features(Fs).
valid_features([],_) -> true;
valid_features([{Id,V,I}|Rest],N) when N>0,is_binary(Id),byte_size(Id)>0,byte_size(Id)=<64,
    is_integer(V),V>0,V=<65535,is_integer(I),I>=0,I=<255 -> valid_features(Rest,N-1);
valid_features(_,_) -> false.
metadata(Fs) ->
    case valid(Fs) of
        true->case efz_qs_legacy:metadata(Fs) of
            {ok,M}->M;not_legacy->#{schema_version=>2,features=>lists:usort(Fs)} end;
        false->error(invalid_semantic_metadata)
    end.
features(#{semantic:=#{schema_version:=1}=M}) -> efz_qs_legacy:features(M);
features(#{semantic:=#{schema_version:=2,features:=Fs}=M}) ->
    case map_size(M)=:=2 andalso valid(Fs) andalso Fs=:=lists:usort(Fs) of
        true->Fs;false->error(invalid_semantic_metadata) end;
features(#{semantic:=_}) -> error(incompatible_semantic_schema);
features(_) -> [].
%% Cold/read-only view: one actual entry ID per finite namespaced feature.
%% Historical seen remains corpus-owned. No refcount/index/cache is stored.
representatives(Entries)->lists:foldl(fun(E,Index)->
    Id=maps:get(id,E),true=is_integer(Id) andalso Id>0,
    lists:foldl(fun(F,Acc)->case maps:is_key(F,Acc) of
        true->Acc;false->Acc#{F=>Id} end end,Index,features(maps:get(metadata,E)))
end,#{},Entries).
%% Conservative corpus reduction: preserve every recorded structural and
%% semantic feature. Entries lacking calibrated evidence are never removed.
cover(Entries) -> lists:foldl(fun(E,{Kept,Ps,Fs})->
    M=maps:get(metadata,E),S=features(M),
    P=[{probe,X}||X<-maps:get(new_probes,M,[])]++[{count,X}||X<-maps:get(new_count_features,M,[])],
    Protected=not maps:is_key(semantic,M) orelse maps:get(phase,M,initial)=/=mutation,
    case Protected orelse (P--Ps)=/=[] orelse (S--Fs)=/=[] of
        true->{Kept++[E],lists:usort(P++Ps),lists:usort(S++Fs)};
        false->{Kept,Ps,Fs}
    end
end,{[],[],[]},Entries).
