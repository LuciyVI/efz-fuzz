-module(efz_finding_minimize_tests).
-include_lib("eunit/include/eunit.hrl").
-export([run/1]).
%% Artificial exception/timeout fixture. Arbitrary non-UTF8 bytes stay raw.
run(B)->
    _=cow_qs:parse_qs(<<"a=1">>),
    case B of
        <<255,_/binary>>->error(wanted_failure);
        <<"T",_/binary>>->timer:sleep(100);
        <<"U",_/binary>>->case ets:update_counter(efz_minimize_fixture,count,1) rem 2 of
            1->timer:sleep(100);0->error(other_failure) end;
        _->error(other_failure)
    end.
minimization_test_()->{timeout,30,[fun raw_crash/0,fun timeout_repeats/0]}.
prepare(B)->
    catch efz:stop(),code:purge(cow_qs),code:delete(cow_qs),
    D="_build/finding-minimize/"++integer_to_list(erlang:system_time(microsecond)),
    Lib=code:lib_dir(cowlib),{ok,A}=efz_cov_native_public:compile(filename:join(Lib,"src/cow_qs.erl"),D++"/target",[filename:join(Lib,"include")]),
    Builds=[{<<"cow_qs">>,maps:get(build_id,A)}],{ok,H}=efz_replay:harness_identity(?MODULE),
    O=#{timeout=>5,coverage_backend=>otp_native_public,max_input_bytes=>4096},
    {ok,R}=efz_recipe:execute(B,?MODULE,[A],Builds,O#{expected_harness=>H}),
    Policy=efz_crash:defaults(),{Sig,_}=efz_crash:signature(maps:get(outcome,R),Policy),
    E=efz_replay:expectation(R,Policy,crypto:hash(sha256,B),Sig,4096),{D,A,E,O}.
raw_crash()->
    B= <<255,0,255,1>>,{D,A,E,O}=prepare(B),
    {ok,M}=efz_finding_minimize:run(B,?MODULE,[A],E,O,#{}),
    ?assertEqual(<<255>>,maps:get(input,M)),?assertEqual(reproduced,maps:get(verification,M)),
    ?assertEqual(maps:get(signature_id,E),maps:get(fingerprint,M)),
    ?assertMatch({ok,#{status:=not_reproduced}},efz_replay:run_input(<<>>,?MODULE,[A],
        E#{input_hash=>crypto:hash(sha256,<<>>)},O)),
    ok=file:write_file(D++"/proof.term",term_to_binary(M)).
timeout_repeats()->
    {D,A,E,O}=prepare(<<"Txxx">>),
    {ok,M}=efz_finding_minimize:run(<<"Txxx">>,?MODULE,[A],E,O,#{executions=>64,repeat=>3}),
    ?assertEqual(<<"T">>,maps:get(input,M)),?assertEqual(3,maps:get(repeat_policy,M)),
    ?assertEqual(reproduced,maps:get(verification,M)),?assert(maps:get(target_executions,M)=<64),
    ets:new(efz_minimize_fixture,[named_table,public]),ets:insert(efz_minimize_fixture,{count,0}),
    try
        {_,A2,E2,O2}=prepare(<<"U">>),ets:insert(efz_minimize_fixture,{count,0}),
        {ok,Unstable}=efz_finding_minimize:run(<<"U">>,?MODULE,[A2],E2,O2,#{}),
        ?assertEqual(unstable,maps:get(status,Unstable)),?assertEqual(skipped,maps:get(verification,Unstable)),
        ok=file:write_file(D++"/timeout-proof.term",term_to_binary(#{stable=>M,unstable=>Unstable}))
    after ets:delete(efz_minimize_fixture) end.
