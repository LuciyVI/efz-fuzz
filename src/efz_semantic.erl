%% Versioned, exact finite namespace. No ETF/ETS state in the callback path.
-module(efz_semantic).
-export([valid/1, metadata/1, features/1, cover/1, representatives/1]).
valid(Fs) -> valid_features(Fs,12).
valid_features([],_) -> true;
valid_features([{<<"cow_qs">>,1,I}|Rest],N) when N>0,is_integer(I),I>=0,I<12 -> valid_features(Rest,N-1);
valid_features(_,_) -> false.
metadata(Fs) ->
    case valid(Fs) of
        true->#{schema_version=>1,namespace=><<"cow_qs">>,feature_version=>1,features=>lists:usort(Fs)};
        false->error(invalid_semantic_metadata)
    end.
features(#{semantic:=#{schema_version:=1,namespace:=<<"cow_qs">>,feature_version:=1,features:=Fs}=M}) ->
    case map_size(M)=:=4 andalso valid(Fs) andalso Fs=:=lists:usort(Fs) of
        true->Fs; false->error(invalid_semantic_metadata) end;
features(#{semantic:=_}) -> error(incompatible_semantic_schema);
features(_) -> [].
%% Cold/read-only view: one actual entry ID per feature, at most 12 keys.
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
