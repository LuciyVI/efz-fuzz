%% Adapter for the existing ETS execution storage and exact Erlang sets.
-module(efz_cov_ets).
-export([open/2, attach/1, hit/2, snapshot/1, counts/1, count_features/2, close/1,
         new_global/0, unseen/2, merge/2, global_snapshot/1,
         modules_seen/2, missing_modules/2]).

open(ets, presence) -> new_context(ets);
open(ets_member, presence) -> new_context(ets_member);
open(Backend, hit_count) when Backend =:= ets; Backend =:= ets_member ->
    new_context(ets_count);
open(_, _) -> error({efz_infrastructure, unsupported_coverage_feedback}).

new_context(ets) ->
    {efz_context, 1, make_ref(), ets:new(efz_execution_coverage, [set, public]), self()};
new_context(Mode) ->
    {efz_context, 1, Ref, Table, Owner} = new_context(ets),
    {efz_context, 1, Ref, {Mode, Table}, Owner}.

table({ets_count, Table}) -> Table;
table({ets_member, Table}) -> Table;
table(Table) -> Table.

attach({efz_context, 1, Ref, Table, Owner} = Context)
  when is_reference(Ref), is_pid(Owner) ->
    case ets:info(table(Table), owner) of
        Owner -> put('$efz_execution_context', Context), ok;
        _ -> error({efz_infrastructure, invalid_coverage_context})
    end.

%% No per-hit list, map or set allocation. Retain the historical first-hit
%% notification and error protocol used by the guardian.
hit(_, undefined) -> ok;
hit(Id, {efz_context,1,Ref,{ets_count,Table},Owner}) ->
    try ets:update_counter(Table,{probe,Id},{2,1},{{probe,Id},0}) of
        1 -> Owner!{efz_cov_observed,Ref,Id},ok;
        N when N>1 -> ok;
        _ -> Owner!{efz_cov_failure,Ref,invalid_hit_counts},
             error({efz_infrastructure,invalid_hit_counts})
    catch error:badarg ->
        Owner!{efz_cov_failure,Ref,invalid_table},
        error({efz_infrastructure,invalid_coverage_table})
    end;
hit(Id, {efz_context,1,Ref,{ets_member,Table},Owner}) ->
    try case ets:member(Table,{probe,Id}) of
        true -> ok;
        false -> insert(Id,Ref,Table,Owner)
    end catch error:badarg ->
        Owner!{efz_cov_failure,Ref,invalid_table},
        error({efz_infrastructure,invalid_coverage_table})
    end;
hit(Id, {efz_context,1,Ref,Table,Owner}) ->
    try insert(Id,Ref,Table,Owner) of
        ok -> ok
    catch error:badarg ->
        Owner!{efz_cov_failure,Ref,invalid_table},
        error({efz_infrastructure,invalid_coverage_table})
    end;
hit(_, _) -> error({efz_infrastructure,invalid_coverage_context}).

insert(Id,Ref,Table,Owner) ->
    case ets:insert_new(Table,{{probe,Id}}) of
        true -> Owner!{efz_cov_observed,Ref,Id},ok;
        false -> ok
    end.

snapshot({efz_context,1,_,{ets_count,_},_}=Context) ->
    case counts(Context) of
        {ok,Counts} -> {ok,lists:sort(maps:keys(Counts))};
        Error -> Error
    end;
snapshot({efz_context,1,_,Table,_}) ->
    try ets:tab2list(table(Table)) of
        Rows -> {ok,lists:sort([Id || {{probe,Id}} <- Rows])}
    catch error:badarg -> {error,invalid_coverage_table} end.

counts(Context) -> efz_cov_count:snapshot(Context).
count_features(Hits, Counts) -> efz_cov_count:features(Hits, Counts).

close({efz_context,1,_,Table,_}) ->
    case ets:info(table(Table)) of
        undefined -> ok;
        _ -> ets:delete(table(Table)), ok
    end.

new_global() -> sets:new().
unseen(Global, Local) ->
    lists:sort(sets:to_list(sets:subtract(sets:from_list(Local),Global))).
merge(Global, Local) -> sets:union(Global,sets:from_list(Local)).
global_snapshot(Global) -> lists:sort(sets:to_list(Global)).

modules_seen(Seen, Hits) ->
    sets:union(Seen,sets:from_list([M || {M,_,_} <- Hits])).
missing_modules(Seen, Manifests) ->
    [#{module=>M,build_id=>B} || #{module:=M,build_id:=B} <- Manifests,
                                 not sets:is_element(M,Seen)].
