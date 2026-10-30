-module(efz_gleam_endtoend_tests).
-include_lib("eunit/include/eunit.hrl").

reduction_limits_test()->
    ?assertMatch({error,_},efz_semantic_corpus:reduce(#{seeds=>[<<0:32776>>]},
        "/nonexistent/efz-invalid-reduction",#{})).
native_test_()->case code:which(efz_qs_model) of
    non_existing->[];
    _->{timeout,90,[fun raw_minimization/0,fun cold_reduction/0,fun capability_before_target/0]}
end.
setup(Name)->
    catch efz:stop(),code:purge(cow_qs),code:delete(cow_qs),
    Dir="_build/gleam-endtoend/"++Name++"-"++integer_to_list(erlang:system_time(microsecond)),
    {ok,A}=efz_cov_native_public:compile("_build/default/lib/cowlib/src/cow_qs.erl",Dir++"/target",
        ["_build/default/lib/cowlib/include"]),{Dir,A}.
config(D,A)->#{target=>efz_qs_target,seeds=>[<<"a=1">>],artifacts=>[A],
    coverage_backend=>otp_native_public,max_iterations=>0,timeout=>1000,
    crash_dir=>D++"/crashes",gleam_layer=>#{structured_fraction=>0,feedback=>guided}}.
finding()->
    {D,A}=setup("finding"),B= <<"bug=11&x=2">>,
    C=(config(D,A))#{target=>efz_qs_defect_target,seeds=>[B],
        gleam_layer=>#{structured_fraction=>0,feedback=>guided,oracle=>inline}},
    {ok,_}=efz:start(C),R=efz:await(30000),ok=efz:stop(),
    [F]=maps:get(crashes,R),P=maps:get(path,F),{ok,E}=efz_semantic_replay:load(P++".semantic"),
    {D,A,B,P,E}.
raw_minimization()->
    {D,A,B,P,E}=finding(),O=#{timeout=>1000,coverage_backend=>otp_native_public,max_input_bytes=>4096},
    {ok,M}=efz_semantic_replay:minimize(B,efz_qs_defect_target,[A],E,O,64),
    ?assertEqual(<<"bug=">>,maps:get(input,M)),
    ?assertMatch({ok,#{status:=reproduced}},maps:get(verification,M)),
    ?assertEqual(crypto:hash(sha256,B),maps:get(original_hash,M)),
    ?assert(maps:get(target_executions,M)=<64),?assert(length(maps:get(trace,M))=<128),
    ?assertEqual({ok,B},file:read_file(P++".input")),
    ?assertMatch({ok,#{status:=not_reproduced}},efz_semantic_replay:run(B,efz_qs_target,[A],
        E#{harness=>harness(efz_qs_target)},O)),
    {ok,Small}=efz_semantic_replay:minimize(B,efz_qs_defect_target,[A],E,O,1),
    ?assertEqual(1,maps:get(target_executions,Small)),?assertEqual({skipped,budget},maps:get(verification,Small)),
    ?assertMatch({error,invalid_minimization_deadline},efz_semantic_replay:minimize(B,
        efz_qs_defect_target,[A],E,O#{minimization_timeout_ms=>0},64)),
    ok=file:write_file(D++"/proof.term",term_to_binary(#{minimized=>M,budget_one=>Small,original=>P})).
harness(T)->{ok,H}=efz_replay:harness_identity(T),H.
cold_reduction()->
    {D,A}=setup("corpus"),Seeds=[<<"a=1">>,<<"a=2">>,<<"a=",255>>],
    C=(config(D,A))#{seeds=>Seeds,gleam_layer=>false},
    {ok,Prepared}=efz_config:prepare(C),Identity=efz_corpus_store:identity(Prepared),
    Store=#{dir=>D++"/original",identity=>Identity},
    [begin {ok,_}=efz_corpus_store:save(Store,B,I,#{}) end||{B,I}<-lists:zip(Seeds,[1,2,3])],
    {ok,Rows,[]}=efz_corpus_store:restore(D++"/original",Identity,reject,4096),
    ?assert(lists:all(fun(#{record:=Rec})->maps:get(schema_version,Rec)=:=1 end,Rows)),
    {ok,Result}=efz_semantic_corpus:reduce(C#{seeds=>[maps:get(input,X)||X<-Rows]},D++"/reduced",#{}),
    ?assertEqual(3,maps:get(before_entries,Result)),?assertEqual(2,maps:get(after_entries,Result)),
    ?assertEqual(5,maps:get(target_executions,Result)),?assertEqual(0,maps:get(online_executions,Result)),
    ?assertEqual({ok,Rows,[]},efz_corpus_store:restore(D++"/original",Identity,reject,4096)),
    ?assert(lists:member({<<"cow_qs">>,1,10},maps:get(features,Result))),
    ok=file:write_file(D++"/proof.term",term_to_binary(Result)).
capability_before_target()->
    {_,A,B,_,E}=finding(),{efz_qs_model,Beam,Path}=code:get_object_code(efz_qs_model),
    {ok,efz_qs_model,Bad}=compile:forms([{attribute,1,module,efz_qs_model},
        {attribute,1,export,[{versions,0}]},{function,1,versions,0,[{clause,1,[],[],[{atom,1,bad}]}]}],[binary]),
    try
        code:purge(efz_qs_model),code:delete(efz_qs_model),
        {module,efz_qs_model}=code:load_binary(efz_qs_model,"explicit_capability_fixture",Bad),
        ?assertEqual({error,{semantic_replay_capability,incompatible_gleam_versions}},
            efz_semantic_replay:run(B,unavailable_target,[A],E,#{}))
    after code:purge(efz_qs_model),code:delete(efz_qs_model),
        {module,efz_qs_model}=code:load_binary(efz_qs_model,Path,Beam) end.
