-module(efz_native_public_tests).
-include_lib("eunit/include/eunit.hrl").

native_public_test_() ->
    {setup,fun setup/0,fun teardown/1,fun exercise/1}.

setup() ->
    Old=code:get_coverage_mode(),
    _=code:purge(efz_native_line_fixture),
    _=code:delete(efz_native_line_fixture),
    _=code:purge(efz_native_line_fixture),
    Out=filename:join("/tmp","efz-native-public-"++integer_to_list(erlang:unique_integer([positive]))),
    ok=file:make_dir(Out),
    Src="test/efz_native_line_fixture.erl",
    {ok,Artifact}=efz_cov_native_public:compile(Src,Out),
    {ok,[Manifest]}=efz_cov_native_public:preflight([Artifact]),
    Schema=efz_cov_native_public:prepare([Manifest]),
    {Old,Out,Manifest,Schema}.
teardown({Old,Out,_,_}) ->
    code:purge(efz_native_line_fixture),
    code:delete(efz_native_line_fixture),
    code:purge(efz_native_line_fixture),
    code:set_coverage_mode(Old),
    _=file:delete(filename:join(Out,"efz_native_line_fixture.beam")),
    _=file:del_dir(Out),ok.

exercise({_,Out,Manifest,Schema}) ->
    [?_test(begin
        Build=maps:get(build_id,Manifest),
        Builds=#{efz_native_line_fixture=>Build},
        ?assert(efz_cov_native_public:valid(Schema,Builds)),
        ?assertNot(efz_cov_native_public:valid(Schema#{slots=>[]},Builds)),
        ?assertNot(efz_cov_native_public:valid(Schema#{fingerprint=><<0>>},Builds)),
        Ctx=efz_cov_native_public:open(Schema),
        ?assertMatch({efz_context,1,_,_,_},Ctx),
        {ok,Empty}=efz_cov_native_public:collect(Schema),
        ?assertEqual([],efz_cov_native_public:decode(Schema,Empty)),
        ?assertEqual(efz_cov_native_public:empty(Schema),Empty),
        alpha=efz_native_line_fixture:run(a),
        {ok,A}=efz_cov_native_public:collect(Schema),
        ?assertEqual(raw_reached(Build),efz_cov_native_public:decode(Schema,A)),
        ?assertEqual([efz_native_line_fixture],efz_cov_native_public:modules(Schema,A)),
        ?assertEqual({error,{native_line_layout_changed,efz_native_line_fixture}},
                     efz_cov_native_public:convert_raw(Schema,[{efz_native_line_fixture,[{999,true}]}])),
        ?assert(efz_cov_native_public:has_new(Empty,A)),
        ?assertEqual(A,efz_cov_native_public:unseen(Empty,A)),
        GlobalA=efz_cov_native_public:merge(Empty,A),
        ?assertNot(efz_cov_native_public:has_new(GlobalA,A)),
        alpha=efz_native_line_fixture:run(a),
        {ok,Repeated}=efz_cov_native_public:collect(Schema),
        ?assertEqual(A,Repeated),
        {beta,_}=efz_native_line_fixture:run(b),
        {ok,B}=efz_cov_native_public:collect(Schema),
        ?assertEqual(raw_reached(Build),efz_cov_native_public:decode(Schema,B)),
        ?assert(efz_cov_native_public:has_new(GlobalA,B)),
        GlobalB=efz_cov_native_public:merge(GlobalA,B),
        ?assertEqual(B,GlobalB),
        _=efz_cov_native_public:open(Schema),
        {ok,Reset}=efz_cov_native_public:collect(Schema),
        ?assertEqual(Empty,Reset),
        %% Feedback may merge only a successful result; failures keep global.
        F0=efz_feedback:new(Builds,presence,Schema),
        Base=#{builds=>Builds,coverage_status=>ok,coverage=>[],coverage_native=>B},
        {ok,F1,_}=efz_feedback:evaluate(F0,Base#{outcome=>{ok,accepted}},mutation),
        ?assertEqual(B,element(3,maps:get(global,F1))),
        {ok,F2,_}=efz_feedback:evaluate(F0,Base#{outcome=>{timeout,10}},mutation),
        ?assertEqual(maps:get(global,F0),maps:get(global,F2)),
        {ok,F3,_}=efz_feedback:evaluate(F0,Base#{outcome=>{crash,error,expected,[]}},mutation),
        ?assertEqual(maps:get(global,F0),maps:get(global,F3)),
        %% The real guardian/executor path must preserve outcome classification
        %% and leave failed observations out of feedback's global state.
        Config=#{target=>efz_native_line_fixture,seeds=>[<<"a">>],
                 artifacts=>[Manifest],coverage_backend=>otp_native_public,
                 timeout=>10,runtime_oracles=>#{enabled=>false}},
        {ok,Prepared}=efz_config:prepare(Config),
        Options=(maps:with([coverage,coverage_backend,coverage_feedback,
                            manifests,execution_identities,max_input_bytes,
                            runtime_oracles],Prepared))#{coverage_schema=>Schema},
        Good=efz_executor:run(efz_native_line_fixture,<<"a">>,100,Options),
        ?assertMatch({ok,alpha},maps:get(outcome,Good)),
        Bad=efz_executor:run(efz_native_line_fixture,<<"crash">>,100,Options),
        ?assertMatch({crash,error,expected_fixture_crash,_},maps:get(outcome,Bad)),
        Slow=efz_executor:run(efz_native_line_fixture,<<"timeout">>,10,Options),
        ?assertMatch({timeout,_},maps:get(outcome,Slow)),
        Fresh=efz_feedback:new(Builds,presence,Schema),
        {ok,AfterGood,_}=efz_feedback:evaluate(Fresh,Good,mutation),
        {ok,AfterCrash,_}=efz_feedback:evaluate(AfterGood,Bad,mutation),
        {ok,AfterTimeout,_}=efz_feedback:evaluate(AfterCrash,Slow,mutation),
        ?assertEqual(maps:get(global,AfterGood),maps:get(global,AfterTimeout)),
        %% Reload with altered code must invalidate the old campaign schema.
        Variant=filename:join(Out,"variant.erl"),
        ok=file:write_file(Variant, <<"-module(efz_native_line_fixture).\n-export([run/1]).\nrun(a) -> changed;\nrun(b) -> different.\n">>),
        {ok,efz_native_line_fixture,Beam}=compile:noenv_file(Variant,[binary,line_coverage,debug_info]),
        {module,efz_native_line_fixture}=code:load_binary(efz_native_line_fixture,Variant,Beam),
        ?assertNot(efz_cov_native_public:valid(Schema,Builds)),
        ?assertEqual({error,invalid_native_schema},efz_cov_native_public:collect(Schema)),
        _=file:delete(Variant)
    end)].

raw_reached(Build) ->
    [{efz_native_line_fixture,Build,L} || {L,true} <-
        code:get_coverage(line,efz_native_line_fixture)].
