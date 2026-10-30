-module(efz_coverage_layer_tests).
-include_lib("eunit/include/eunit.hrl").

%% Contract from the pre-layer ETS path: exact identities, first-hit messages,
%% sorted snapshots and novelty remain identical for both storage selectors.
legacy_presence_contract_test() ->
    A={site,<<1:256>>,1}, B={site,<<1:256>>,2},
    lists:foreach(fun(Backend) ->
        C=efz_coverage:open(Backend,presence),
        {efz_context,1,Ref,Storage,Owner}=C,
        ok=efz_coverage:attach(C),
        try
            ok=efz_cov_rt:hit(B),ok=efz_cov_rt:hit(A),ok=efz_cov_rt:hit(A),
            ?assertEqual({ok,[A,B]},efz_coverage:snapshot(C)),
            ?assertEqual([{efz_cov_observed,Ref,B},{efz_cov_observed,Ref,A}],observations()),
            G0=efz_coverage:new_global(),
            ?assertEqual([A,B],efz_coverage:unseen(G0,[A,B])),
            G1=efz_coverage:merge(G0,[A,B]),
            ?assertEqual([],efz_coverage:unseen(G1,[B,A,A])),
            ?assertEqual([A,B],efz_coverage:global_snapshot(G1))
        after
            ok=efz_cov:detach(),ok=efz_coverage:close(C)
        end,
        ?assertEqual(undefined,ets:info(table(Storage))),
        ?assertEqual(self(),Owner)
    end,[ets,ets_member]).

legacy_count_contract_test() ->
    A={site,<<1:256>>,1},
    lists:foreach(fun(Backend) ->
        C=efz_coverage:open(Backend,hit_count),
        ok=efz_coverage:attach(C),
        try
            ok=efz_cov_rt:hit(A),ok=efz_cov_rt:hit(A),
            ?assertEqual({ok,[A]},efz_coverage:snapshot(C)),
            ?assertEqual({ok,#{A=>2}},efz_coverage:counts(C)),
            ?assertEqual([{efz_cov_observed,element(3,C),A}],observations())
        after ok=efz_cov:detach(),ok=efz_coverage:close(C) end
    end,[ets,ets_member]).

observations() -> observations([]).
observations(Acc) ->
    receive {efz_cov_observed,_,_}=Event -> observations([Event|Acc])
    after 0 -> lists:reverse(Acc) end.

table({ets_count,T}) -> T;
table({ets_member,T}) -> T;
table(T) -> T.
