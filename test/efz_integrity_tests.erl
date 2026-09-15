-module(efz_integrity_tests).
-include_lib("eunit/include/eunit.hrl").

integrity_test_() -> {setup,fun setup/0,fun cleanup/1,fun(S)->[
    {"normal automatic probes and pinned harness/build identities",fun()->normal(S) end},
    {"valid zero hits from a real unmatched instrumented clause",fun()->zero(S) end},
    {"disconnected harness is diagnostic, strict campaign fails closed",fun()->disconnected(S) end},
    {"unused selected artifact is reported separately",fun()->unused(S) end},
    {"crashing execution with probes is not a disconnected campaign",fun()->crash_observed(S) end},
    {"strict mode waits through zero-hit calibration for real staged discovery",fun()->strict_discovery(S) end},
    {"erased, malformed, detached and restored dictionaries cannot hide",fun()->contexts(S) end},
    {"caught hook exceptions remain infrastructure failures",fun()->caught(S) end},
    {"lost ETS observations are independent of attached context",fun()->lost(S) end},
    {"controlled child context failure invalidates the execution",fun()->child(S) end},
    {"erase followed by kill still fails integrity",fun()->killed(S) end},
    {"plain hot reload before execution is rejected",fun()->before_reload(S,plain) end},
    {"different instrumented build before execution is rejected",fun()->before_reload(S,alternate) end},
    {"harness identity is independently pinned",fun()->harness_reload(S) end},
    {"prepared plan keeps the original loaded BEAM identity",fun()->prepared_reload(S) end},
    {"preflight rejects changed code even with a copied original manifest",fun()->copied_manifest(S) end},
    {"plain hot reload during execution is detected",fun()->during_reload(S,plain) end},
    {"different build during execution is detected",fun()->during_reload(S,alternate) end},
    {"harness hot reload during execution is detected",fun()->during_harness_reload(S) end},
    {"transient plain replacement followed by original build is detected",fun()->transient(S) end},
    {"atomic load prepared before execution is detected",fun()->atomic_reload(S) end},
    {"transient direct ERTS commit cannot evade the code-server guard",fun()->direct_reload(S) end}
] end}.

setup() ->
    Dir="_build/integrity-test",ok=filelib:ensure_dir(Dir++"/placeholder"),
    lists:foreach(fun unload/1,[efz_integrity_target,efz_integrity_harness,efz_fixture_helper]),
    {ok,A}=efz_instrument:compile("fixtures/efz_integrity_target.erl",
        #{modules=>[efz_integrity_target],source_root=>".",outdir=>Dir++"/original"}),
    {ok,B}=efz_instrument:compile("fixtures/efz_integrity_target.erl",
        #{modules=>[efz_integrity_target],source_root=>".",outdir=>Dir++"/alternate",erl_opts=>[{d,'ALTERNATE'}]}),
    {ok,U}=efz_instrument:compile("fixtures/efz_fixture_helper.erl",
        #{modules=>[efz_fixture_helper],source_root=>".",outdir=>Dir++"/unused"}),
    Plain=plain(efz_integrity_target,[]),Harness=plain(efz_integrity_harness,[]),
    Harness2=plain(efz_integrity_harness,[{d,'ALTERNATE'}]),
    load(efz_integrity_harness,Harness),{ok,Ms}=efz_instrument:preflight([A]),
    {ok,AB}=file:read_file(maps:get(beam,A)),{ok,BB}=file:read_file(maps:get(beam,B)),
    #{artifact=>A,unused=>U,manifests=>Ms,original=>AB,alternate=>BB,plain=>Plain,
      harness=>Harness,harness2=>Harness2}.
plain(M,Options) ->
    {ok,M,B}=compile:noenv_file("fixtures/"++atom_to_list(M)++".erl",[binary,debug_info|Options]),B.
load(M,B)->{module,M}=code:load_binary(M,"integrity-fixture",B),ok.
unload(M)->_=code:purge(M),_=code:delete(M),_=code:purge(M),ok.
restore(S)->unload(efz_integrity_target),load(efz_integrity_target,maps:get(original,S)).
cleanup(_)->efz:stop(),lists:foreach(fun unload/1,[efz_integrity_target,efz_integrity_harness,efz_fixture_helper]).
config(S,Extra)->maps:merge(#{target=>efz_integrity_harness,seeds=>[<<"A">>],
    artifacts=>[maps:get(artifact,S)],timeout=>1000,max_iterations=>0},Extra).
pinned(S,Extra)->{ok,C}=efz_config:prepare(config(S,Extra)),C.
execute(B,C)->efz_executor:run(efz_integrity_harness,B,1000,C).
campaign(S,Extra)->
    {ok,_}=efz:start(config(S,Extra)),
    try efz:await(5000) after efz:stop() end.
clean(R)->
    ?assertEqual(confirmed,maps:get(status,maps:get(cleanup,R))),
    [?assertNot(is_process_alive(P)) || P<-maps:get(processes,maps:get(cleanup,R))],
    ?assertEqual(undefined,ets:whereis(efz_coverage_observers)),
    ?assertEqual(ready,efz_executor:runner_status()).
observation(R)->maps:get(coverage_observation,R).
broken(R)->
    ?assertMatch({infrastructure,_},maps:get(outcome,R)),
    ?assertMatch({error,_},maps:get(coverage_status,R)),
    ?assertEqual(broken_coverage_observation,maps:get(classification,observation(R))),
    %% Failed observations cannot change global novelty, even if target caught
    %% the exception and returned a successful term.
    F=efz_feedback:new(maps:get(builds,R)),
    ?assertMatch({error,_},efz_feedback:evaluate(F,R,mutation)).
normal(S)->
    C=pinned(S,#{}),Pins=maps:get(execution_identities,C),
    #{harness:=H,modules:=#{efz_integrity_target:=Target}}=Pins,
    ?assertEqual(efz_integrity_harness,maps:get(module,H)),
    ?assertEqual(erlang:get_module_info(efz_integrity_harness,md5),maps:get(beam_md5,H)),
    ?assertEqual(undefined,maps:get(build_id,H)),?assert(is_list(maps:get(compile,H))),
    ?assertEqual(maps:get(build_id,maps:get(artifact,S)),maps:get(build_id,Target)),
    R=execute(<<"A">>,C),?assertEqual({ok,a},maps:get(outcome,R)),
    ?assertMatch(#{classification:=observed_coverage,state:=observed,attached_processes:=[_]},observation(R)),
    ?assertEqual(Pins,maps:get(execution_identities,R)),clean(R),
    F=efz_feedback:new(maps:get(builds,R)),
    {ok,F1,D}=efz_feedback:evaluate(F,R,mutation),
    ?assertEqual(maps:get(coverage,R),maps:get(new_probes,D)),
    {ok,_,D1}=efz_feedback:evaluate(F1,R,mutation),?assertEqual([],maps:get(new_probes,D1)).
zero(S)->
    R=execute(<<"zero">>,pinned(S,#{})),
    ?assertEqual({ok,zero},maps:get(outcome,R)),?assertEqual([],maps:get(coverage,R)),
    ?assertMatch(#{classification:=valid_empty_coverage,state:=attached,attached_processes:=[_]},observation(R)),
    ?assertEqual(ok,maps:get(coverage_status,R)),clean(R).
disconnected(S)->
    R=campaign(S,#{seeds=>[<<"skip">>]}),
    ?assertEqual(completed,maps:get(status,R)),
    ?assertMatch(#{status:=no_probes_observed,empty_executions:=1,broken_observations:=0},maps:get(coverage_diagnostics,R)),
    Strict=campaign(S,#{seeds=>[<<"skip">>],coverage_policy=>strict}),
    ?assertMatch({infrastructure_failure,#{kind:=coverage_not_observed}},maps:get(status,Strict)),
    ?assertEqual(1,maps:get(infrastructure_failures,maps:get(stats,Strict))),
    ?assertMatch({error,{invalid_campaign_option,coverage_policy}},efz_config:prepare(config(S,#{coverage_policy=>unknown}))).
unused(S)->
    R=campaign(S,#{artifacts=>[maps:get(artifact,S),maps:get(unused,S)],coverage_policy=>strict}),
    ?assertEqual(completed,maps:get(status,R)),
    ?assertMatch(#{status:=observed,observed_modules:=[efz_integrity_target],
        unused_artifacts:=[#{module:=efz_fixture_helper}]},maps:get(coverage_diagnostics,R)),
    unload(efz_fixture_helper).
strict_discovery(S)->
    R2=campaign(S,#{seeds=>[<<>>],coverage_policy=>strict,mutation_mode=>staged,
        max_iterations=>1,mutation=>#{stages=>[dictionary_insert],dictionary=>[<<"A">>],trace_limit=>1}}),
    ?assertEqual(completed,maps:get(status,R2)),
    ?assertEqual(1,maps:get(discoveries,maps:get(stats,R2))),
    ?assert(lists:any(fun(#{input:=B})->B=:=<<"A">> end,maps:get(corpus,R2))).
crash_observed(S)->
    R=campaign(S,#{seeds=>[<<"probe_crash">>],coverage_policy=>strict,
        crash_dir=>"_build/integrity-test/crashes-"++binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(6),lowercase))}),
    ?assertEqual(completed,maps:get(status,R)),?assertEqual([],maps:get(coverage,R)),
    ?assertEqual(observed,maps:get(status,maps:get(coverage_diagnostics,R))).
contexts(S)->
    lists:foreach(fun(Backend)->
        C=pinned(S,#{coverage_backend=>Backend}),
        lists:foreach(fun(B)->R=execute(B,C),broken(R),clean(R) end,
            [<<"erase_all">>,<<"erase_key">>,<<"detach">>,<<"malformed">>,<<"erase_restore">>])
    end,[ets,ets_member]).
caught(S)->
    lists:foreach(fun(B)->R=execute(B,pinned(S,#{})),
        ?assertEqual({ok,caught},maps:get(target_outcome,R)),broken(R),clean(R)
    end,[<<"caught_hook">>,<<"erased_hook">>]),
    R=campaign(S,#{seeds=>[<<"caught_hook">>]}),
    ?assertMatch({infrastructure_failure,{coverage_failure,_}},maps:get(status,R)),
    ?assertEqual(1,maps:get(infrastructure_failures,maps:get(stats,R))),
    ?assertMatch(#{input:=<<"caught_hook">>},maps:get(failure_context,R)).
lost(S)->R=execute(<<"lose_hits">>,pinned(S,#{})),broken(R),
    ?assertEqual({error,coverage_observations_lost},maps:get(coverage_status,R)),clean(R).
child(S)->R=execute(<<"child_context">>,pinned(S,#{})),broken(R),clean(R).
async(B,C,Fun)->
    true=register(efz_integrity_observer,self()),Parent=self(),
    {Caller,Mon}=spawn_monitor(fun()->Parent!{result,execute(B,C)} end),
    try
        Root=receive {ready,P}->P after 2000->error(no_ready) end,
        Fun(Root),
        R=receive {result,Result}->Result after 3000->error(no_result) end,
        receive {'DOWN',Mon,process,Caller,normal}->ok end,R
    after unregister(efz_integrity_observer) end.
killed(S)->
    R=async(<<"erase_wait">>,pinned(S,#{}),fun(P)->exit(P,kill) end),broken(R),clean(R).
before_reload(S,Kind)->
    C=pinned(S,#{}),
    try load(efz_integrity_target,maps:get(Kind,S)),R=execute(<<"A">>,C),broken(R),
        ?assertMatch({infrastructure,#{kind:=module_identity_changed,module:=efz_integrity_target}},maps:get(outcome,R)),
        ?assertEqual(not_started,maps:get(status,maps:get(cleanup,R)))
    after restore(S) end.
harness_reload(S)->
    C=pinned(S,#{}),
    try load(efz_integrity_harness,maps:get(harness2,S)),R=execute(<<"skip">>,C),broken(R),
        ?assertMatch({infrastructure,#{kind:=module_identity_changed,module:=efz_integrity_harness}},maps:get(outcome,R))
    after unload(efz_integrity_harness),load(efz_integrity_harness,maps:get(harness,S)) end.
prepared_reload(S)->
    {ok,P}=efz_cov_manifest:prepare(automatic,maps:get(manifests,S)),
    try load(efz_integrity_target,maps:get(plain,S)),
        R=execute(<<"A">>,#{coverage=>automatic,coverage_plan=>P}),broken(R),
        ?assertMatch({infrastructure,#{kind:=module_identity_changed}},maps:get(outcome,R))
    after efz_cov_manifest:release(P),restore(S) end.
copied_manifest(S)->
    [Manifest]=maps:get(manifests,S),
    Forms=[{attribute,1,module,efz_integrity_target},{attribute,2,export,[{parse,1}]},
        {attribute,3,efz_manifest,Manifest},
        {function,4,parse,1,[{clause,4,[{var,4,'_'}],[],[{atom,4,plain}]}]}],
    {ok,efz_integrity_target,Beam}=compile:forms(Forms,[binary]),
    try load(efz_integrity_target,Beam),
        ?assertEqual({error,{loaded_module_identity_mismatch,efz_integrity_target}},
            efz_instrument:preflight([maps:get(artifact,S)]))
    after restore(S) end.
during_harness_reload(S)->
    try R=async(<<"wait">>,pinned(S,#{}),fun(P)->load(efz_integrity_harness,maps:get(harness2,S)),P!finish end),
        broken(R),clean(R)
    after unload(efz_integrity_harness),load(efz_integrity_harness,maps:get(harness,S)) end.
during_reload(S,Kind)->
    try R=async(<<"wait">>,pinned(S,#{}),fun(P)->load(efz_integrity_target,maps:get(Kind,S)),P!finish end),
        broken(R),clean(R)
    after restore(S) end.
transient(S)->
    try R=async(<<"wait_zero">>,pinned(S,#{}),fun(P)->
        load(efz_integrity_target,maps:get(plain,S)),_=code:purge(efz_integrity_target),
        load(efz_integrity_target,maps:get(original,S)),P!finish end),
        ?assertEqual({ok,zero},maps:get(target_outcome,R)),?assertEqual([],maps:get(coverage,R)),
        ?assertMatch({error,{module_load_during_execution,_}},maps:get(coverage_status,R)),broken(R),clean(R)
    after restore(S) end.
atomic_reload(S)->
    {ok,Prepared}=code:prepare_loading([{efz_integrity_target,"prepared",maps:get(plain,S)}]),
    try R=async(<<"wait">>,pinned(S,#{}),fun(P)->ok=code:finish_loading(Prepared),P!finish end),
        ?assertMatch({error,{module_load_during_execution,_}},maps:get(coverage_status,R)),broken(R),clean(R)
    after restore(S) end.
direct_reload(S)->
    Plain=erlang:prepare_loading(efz_integrity_target,maps:get(plain,S)),
    Original=erlang:prepare_loading(efz_integrity_target,maps:get(original,S)),
    try R=async(<<"wait_zero">>,pinned(S,#{}),fun(P)->
        ok=erlang:finish_loading([Plain]),_=code:purge(efz_integrity_target),
        ok=erlang:finish_loading([Original]),P!finish end),
        ?assertEqual({ok,zero},maps:get(target_outcome,R)),
        ?assertMatch({error,{unsupported_direct_code_loading,_}},maps:get(coverage_status,R)),broken(R),clean(R)
    after restore(S) end.
