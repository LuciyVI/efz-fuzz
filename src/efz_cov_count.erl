%% Experimental, exact-identity hit features. Bucket labels are their inclusive
%% lower bounds: 1,2,4,8,16,32,64,128. These are not hashed bitmap positions.
-module(efz_cov_count).
-export([bucket/1, features/2, snapshot/1]).

bucket(N) when is_integer(N), N >= 128 -> 128;
bucket(N) when is_integer(N), N >= 64 -> 64;
bucket(N) when is_integer(N), N >= 32 -> 32;
bucket(N) when is_integer(N), N >= 16 -> 16;
bucket(N) when is_integer(N), N >= 8 -> 8;
bucket(N) when is_integer(N), N >= 4 -> 4;
bucket(N) when is_integer(N), N >= 2 -> 2;
bucket(1) -> 1.

%% Strict projection: losing counts must not silently turn into empty coverage.
features(Hits, Counts) when is_list(Hits), is_map(Counts) ->
    case lists:sort(maps:keys(Counts)) =:= lists:usort(Hits) andalso
         lists:all(fun(N)->is_integer(N) andalso N>0 end,maps:values(Counts)) of
        true -> {ok,lists:sort([{Id,bucket(N)} || {Id,N}<-maps:to_list(Counts)])};
        false -> {error,invalid_hit_counts}
    end;
features(_, _) -> {error,invalid_hit_counts}.

snapshot({efz_context,1,_,{ets_count,T},_}) ->
    try ets:tab2list(T) of
        Rows ->
            Counts=maps:from_list([{Id,N} || {{probe,Id},N}<-Rows]),
            case length(Rows)=:=map_size(Counts) andalso
                 lists:all(fun(N)->is_integer(N) andalso N>0 end,maps:values(Counts)) of
                true->{ok,Counts};
                false->{error,invalid_hit_counts}
            end
    catch error:badarg->{error,invalid_coverage_table} end.
