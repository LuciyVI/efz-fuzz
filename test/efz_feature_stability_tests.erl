-module(efz_feature_stability_tests).
-include_lib("eunit/include/eunit.hrl").

state() ->
    {ok,P}=efz_runtime_config:prepare(#{enabled=>true,
        resources=>#{enabled=>false},hangs=>#{enabled=>false},
        stability=>#{seed_runs=>20,max_groups=>2,max_features_per_group=>2000}}),
    efz_stability:new(P,ets).
add(S,G,F) -> efz_stability:observe(S,G,G,make_ref(),20,{ok,F},10).

exact_formula_test() ->
    A=add(add(state(),a,[a,b]),a,[a,b]),
    ?assertMatch(#{percent:=100.0,stable_feature_pairs:=2,observed_feature_pairs:=2,
                   variable_feature_pairs:=0},efz_stability:public(A)),
    B=add(add(state(),b,[a,b]),b,[a,c]),
    ?assertEqual(100.0/3,maps:get(percent,efz_stability:public(B))),
    ?assertMatch(#{stable_feature_pairs:=1,observed_feature_pairs:=3,
                   variable_feature_pairs:=2},efz_stability:public(B)),
    C=add(add(state(),c,[a]),c,[b]),
    ?assertEqual(0.0,maps:get(percent,efz_stability:public(C))),
    D=add(add(state(),d,[]),d,[a]),
    ?assertEqual(0.0,maps:get(percent,efz_stability:public(D))),
    E=add(add(state(),e,[]),e,[]),
    ?assertMatch(#{status:=no_observed_features,percent:=null},efz_stability:public(E)),
    ?assertMatch(#{status:=insufficient_samples,percent:=null},efz_stability:public(add(state(),f,[a]))),
    ?assertEqual(100.0,maps:get(percent,efz_stability:public(add(add(state(),g,[a,a,b]),g,[a,b,b])))).

weighted_groups_and_revisions_test() ->
    Nine=lists:seq(1,9),
    S1=add(add(state(),a,lists:seq(1,10)),a,Nine),
    S2=add(add(S1,b,[same]),b,[different]),
    P=efz_stability:public(S2),
    ?assertMatch(#{stable_feature_pairs:=9,observed_feature_pairs:=12,
        variable_feature_pairs:=3,groups_measured:=2,groups_unstable:=2,percent:=75.0},P),
    ?assertEqual(4,maps:get(revision,P)),
    Ref=make_ref(),
    S3=efz_stability:observe(S2,a,a,Ref,20,{ok,Nine},11),
    S4=efz_stability:observe(S3,a,a,Ref,20,{ok,[]},12),
    ?assertEqual(5,maps:get(revision,efz_stability:public(S4))),
    ?assertEqual(75.0,maps:get(percent,efz_stability:public(S4))),
    ?assertEqual(20,maps:get(requested_runs,maps:get(current,efz_stability:public(S4)))).

twenty_repeats_and_complementary_groups_test() ->
    Base=lists:seq(1,950),
    First=add(state(),twenty,lists:seq(1,1000)),
    Twenty=lists:foldl(fun(_,Acc)->add(Acc,twenty,Base) end,First,lists:seq(1,19)),
    ?assertMatch(#{percent:=95.0,stable_feature_pairs:=950,
        observed_feature_pairs:=1000,current:=#{valid_runs:=20}},efz_stability:public(Twenty)),
    A=add(add(state(),a,[a]),a,[b]),
    B=add(add(A,b,[b]),b,[a]),
    ?assertMatch(#{stable_feature_pairs:=0,observed_feature_pairs:=4,
        variable_feature_pairs:=4},efz_stability:public(B)),
    ?assertEqual(0.0,maps:get(percent,efz_stability:public(B))),
    Shared=add(add(add(add(state(),a,[x]),a,[x]),b,[x]),b,[x]),
    ?assertMatch(#{stable_feature_pairs:=2,observed_feature_pairs:=2},
        efz_stability:public(Shared)).

invalid_limit_and_large_fraction_test() ->
    S0=state(),
    S1=add(S0,a,[a]),
    S2=efz_stability:observe(S1,a,a,make_ref(),20,{invalid,missing_trace},11),
    ?assertMatch(#{invalid_attempts:=1,invalid_reasons:=#{invalid_coverage_window:=1},
        percent:=null,
        current:=#{attempted_runs:=2,valid_runs:=1}},efz_stability:public(S2)),
    S3=add(S2,a,[a]),
    ?assertEqual(100.0,maps:get(percent,efz_stability:public(S3))),
    {ok,P}=efz_runtime_config:prepare(#{enabled=>true,
        stability=>#{max_features_per_group=>2}}),
    Large=efz_stability:new(P,ets),
    Capped=add(Large,large,[a,b,c]),
    ?assertMatch(#{percent:=null,groups_skipped:=1,collection_status:=capped},
        efz_stability:public(Capped)),
    ?assertMatch(#{collection_status:=capped},
        efz_stability:public(efz_stability:complete(Capped,20,partial))),
    ?assertMatch({error,invalid_runtime_oracles},efz_runtime_config:prepare(
        #{stability=>#{seed_runs=>257}})),
    ?assertMatch({ok,_},efz_runtime_config:prepare(#{stability=>#{seed_runs=>20}})),
    ?assertMatch(#{status:=insufficient_samples},efz_stability:public(Large)).

group_cap_and_empty_legacy_test() ->
    S=add(add(state(),a,[a]),a,[a]),
    S1=add(add(S,b,[b]),b,[b]),
    S2=add(S1,c,[c]),
    ?assertMatch(#{groups_measured:=2,groups_skipped:=1,
        stable_feature_pairs:=2,observed_feature_pairs:=2},efz_stability:public(S2)),
    Legacy=efz_stability:summarize([#{valid=>true,completed=>true,coverage=>[],
        outcome=>ok,builds=>#{}},#{valid=>true,completed=>true,coverage=>[],
        outcome=>ok,builds=>#{}}],2),
    ?assertEqual(100.0,maps:get(stable_probe_ratio,Legacy)).

control_configuration_test() ->
    R=#{<<"enabled">>=>true,
        <<"resources">>=>#{<<"enabled">>=>false},
        <<"hangs">>=>#{<<"enabled">>=>false},
        <<"stability">>=>#{<<"enabled">>=>true,<<"seed_runs">>=>20,
            <<"max_groups">>=>32,<<"max_features_per_group">>=>8192}},
    C=efz_control_json:campaign(#{<<"runtime_oracles">>=>R}),
    ?assertMatch({ok,#{stability:=#{seed_runs:=20},resources:=#{enabled:=false},
        hangs:=#{enabled:=false}}},
        efz_runtime_config:prepare(maps:get(runtime_oracles,C))).

schema_identity_separates_groups_test() ->
    S0=state(),
    S1=add(S0,{input,build_one,schema_one},[same]),
    S2=add(S1,{input,build_two,schema_two},[same]),
    ?assertMatch(#{status:=insufficient_samples,percent:=null,
        groups_incomplete:=2,groups_measured:=0},efz_stability:public(S2)).

recalibration_requested_total_test() ->
    S0=state(),
    S1=efz_stability:observe(S0,a,a,make_ref(),3,{ok,[a]},1),
    S2=efz_stability:observe(S1,a,a,make_ref(),3,{ok,[a]},2),
    S3=efz_stability:complete(S2,3,partial),
    S4=efz_stability:observe(S3,a,a,make_ref(),3,{ok,[a]},3),
    ?assertMatch(#{groups_measured:=1,current:=#{valid_runs:=3,
        requested_runs:=6,provisional:=true}},efz_stability:public(S4)),
    S5=efz_stability:observe(S4,a,a,make_ref(),3,{ok,[a]},4),
    ?assertMatch(#{groups_measured:=1,stable_feature_pairs:=1,
        observed_feature_pairs:=1,current:=#{valid_runs:=4,requested_runs:=6}},
        efz_stability:public(S5)),
    ?assertMatch(#{collection_status:=partial},
        efz_stability:public(efz_stability:complete(S5,3,complete))).
