-module(efz_cov).
-export([open/0, open/1, open/2, attach/1, detach/0, snapshot/1, close/1,
         hit/1, reset_local/0, snapshot/0, merge/2, interesting/2]).

-type context() :: {efz_context, 1, reference(), ets:tid() | {ets_member | ets_count, ets:tid()}, pid()}.
-spec open() -> context().
-spec attach(context()) -> ok.
-spec snapshot(context()) -> {ok, list()} | {error, invalid_coverage_table | invalid_hit_counts}.
-spec close(context()) -> ok.

open() ->
    efz_coverage:open(ets, presence).

%% The reference path stays available and remains open/0's default.
open(ets) -> open();
open(ets_member) -> efz_coverage:open(ets_member, presence);
open(_) -> error({efz_infrastructure, unsupported_coverage_backend}).

open(Backend,presence) -> efz_coverage:open(Backend,presence);
open(Backend,hit_count) when Backend=:=ets; Backend=:=ets_member ->
    efz_coverage:open(Backend,hit_count);
open(_,_) -> error({efz_infrastructure,unsupported_coverage_feedback}).
attach(Context) -> efz_coverage:attach(Context).
detach() -> erase('$efz_execution_context'), ok.
snapshot(Context) -> efz_coverage:snapshot(Context).
close(Context) -> efz_coverage:close(Context).

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
merge(Global, Local) -> efz_coverage:merge(Global, Local).
interesting(Global, Local) -> efz_coverage:unseen(Global, Local) =/= [].
