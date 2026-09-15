-module(efz_cov).
-export([open/0, open/1, attach/1, detach/0, snapshot/1, close/1,
         hit/1, reset_local/0, snapshot/0, merge/2, interesting/2]).

-type context() :: {efz_context, 1, reference(), ets:tid() | {ets_member, ets:tid()}, pid()}.
-spec open() -> context().
-spec attach(context()) -> ok.
-spec snapshot(context()) -> {ok, list()} | {error, invalid_coverage_table}.
-spec close(context()) -> ok.

open() ->
    %% Public permits target writes; target exit does not remove the owner-held table.
    {efz_context, 1, make_ref(), ets:new(efz_execution_coverage, [set, public]), self()}.

%% The reference path stays available and remains open/0's default.
open(ets) -> open();
open(ets_member) ->
    {efz_context, 1, Ref, Table, Owner} = open(),
    {efz_context, 1, Ref, {ets_member, Table}, Owner};
open(_) -> error({efz_infrastructure, unsupported_coverage_backend}).

table({ets_member, Table}) -> Table;
table(Table) -> Table.
attach({efz_context, 1, Ref, Table, Owner} = Context)
  when is_reference(Ref), is_pid(Owner) ->
    case ets:info(table(Table), owner) of
        Owner -> put('$efz_execution_context', Context), ok;
        _ -> error({efz_infrastructure, invalid_coverage_context})
    end.
detach() -> erase('$efz_execution_context'), ok.
snapshot({efz_context, 1, _, Table, _}) ->
    try ets:tab2list(table(Table)) of
        Rows -> {ok, lists:sort([Id || {{probe, Id}} <- Rows])}
    catch error:badarg -> {error, invalid_coverage_table} end.
close({efz_context, 1, _, Table, _}) ->
    case ets:info(table(Table)) of undefined -> ok; _ -> ets:delete(table(Table)), ok end.

%% Explicit legacy manual namespace. No global "current input" exists.
hit(Id) -> efz_cov_rt:hit({manual, Id}).
reset_local() ->
    case get('$efz_execution_context') of
        undefined -> attach(open());
        _ -> error({efz_infrastructure, context_already_attached})
    end.
snapshot() ->
    case get('$efz_execution_context') of
        undefined -> [];
        C -> {ok, Hits} = snapshot(C), Hits
    end.
merge(Global, Local) -> sets:union(Global, sets:from_list(Local)).
interesting(Global, Local) -> lists:any(fun(X) -> not sets:is_element(X, Global) end, Local).
