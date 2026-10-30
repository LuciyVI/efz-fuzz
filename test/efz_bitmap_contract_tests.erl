-module(efz_bitmap_contract_tests).
-include_lib("eunit/include/eunit.hrl").

mapping_and_capacity_test() ->
    A=manifest(bitmap_a,1,2),B=manifest(bitmap_b,2,2),
    {ok,S}=efz_coverage:prepare_schema([A,B],64),
    try
        C=efz_coverage:open(bitmap,presence,S),
        ok=efz_coverage:attach(C),
        [A1|_]=efz_cov_manifest:identities(A),
        [B1|_]=efz_cov_manifest:identities(B),
        ok=efz_cov_rt:hit(A1),ok=efz_cov_rt:hit(B1),
        ?assertEqual({ok,lists:sort([A1,B1])},efz_coverage:snapshot(C)),
        ?assertError({efz_infrastructure,{unexpected_probe_or_build,_}},
                     efz_cov_rt:hit({bitmap_a,<<3:256>>,1})),
        ok=efz_cov:detach(),ok=efz_coverage:close(C)
    after efz_coverage:release_schema(S),drain() end,
    ?assertMatch({error,{bitmap_capacity_exceeded,
                 #{required_bits:=65,configured_bits:=64}}},
                 efz_coverage:check_capacity([manifest(bitmap_a,1,65)],64)).

boundary_test() ->
    M=manifest(bitmap_boundary,4,128),
    {ok,S}=efz_coverage:prepare_schema([M],128),
    try
        C=efz_coverage:open(bitmap,presence,S),ok=efz_coverage:attach(C),
        Ids=efz_cov_manifest:identities(M),
        Selected=[lists:nth(I,Ids)||I<-[1,64,65,128]],
        lists:foreach(fun(Id)->ok=efz_cov_rt:hit(Id) end,Selected),
        {ok,{efz_bitmap_snapshot,1,_,Bits}}=efz_coverage:snapshot_bits(C),
        ?assertEqual(16,byte_size(Bits)),
        ?assertEqual({ok,Selected},efz_coverage:snapshot(C)),
        ?assertEqual(1,binary:at(Bits,0)),
        ?assertEqual(128,binary:at(Bits,7)),
        ?assertEqual(1,binary:at(Bits,8)),
        ?assertEqual(128,binary:at(Bits,15)),
        ok=efz_cov:detach(),ok=efz_coverage:close(C)
    after efz_coverage:release_schema(S),drain() end.

default_last_slot_test_() ->
    {timeout,60,fun()->
        M=manifest(bitmap_last,5,65536),
        {ok,S}=efz_coverage:prepare_schema([M],65536),
        try
            C=efz_coverage:open(bitmap,presence,S),ok=efz_coverage:attach(C),
            Last=lists:last(efz_cov_manifest:identities(M)),
            ok=efz_cov_rt:hit(Last),
            {ok,{efz_bitmap_snapshot,1,_,Bits}}=efz_coverage:snapshot_bits(C),
            ?assertEqual(8192,byte_size(Bits)),
            ?assertEqual(128,binary:at(Bits,8191)),
            ?assertEqual({ok,[Last]},efz_coverage:snapshot(C)),
            ok=efz_cov:detach(),ok=efz_coverage:close(C)
        after efz_coverage:release_schema(S),drain() end
    end}.

novelty_reset_and_schema_test() ->
    M=manifest(bitmap_history,6,3),
    {ok,S}=efz_coverage:prepare_schema([M],64),
    {ok,Other}=efz_coverage:prepare_schema([manifest(bitmap_history,7,3)],64),
    try
        [A,B,C]=efz_cov_manifest:identities(M),
        G0=efz_coverage:new_global(S),
        {efz_bitmap_snapshot,1,F,_}=G0,
        Invalid={efz_bitmap_snapshot,1,F,<<0:56,128>>},
        ?assertEqual({error,unexpected_bitmap_slot},efz_coverage:decode_new(S,Invalid)),
        {H1,G1}=iteration(S,[A],G0),
        ?assertEqual([A],H1),
        {H2,G2}=iteration(S,[A],G1),
        ?assertEqual([],H2),
        {H3,G3}=iteration(S,[B,C],G2),
        ?assertEqual([B,C],H3),
        {H4,_}=iteration(S,[A],G3),
        ?assertEqual([],H4),
        ?assertEqual({ok,[A,B,C]},efz_coverage:decode_new(S,G3)),
        ?assertEqual({error,incompatible_coverage_schema},
            efz_coverage:unseen_bits(G3,efz_coverage:new_global(Other))),
        Ctx=efz_coverage:open(bitmap,presence,S),
        ok=efz_coverage:close(Ctx),
        Fresh=efz_cov_bitmap:reset(Ctx),
        ?assertEqual({ok,[]},efz_coverage:snapshot(Fresh)),
        ?assertEqual({ok,[A,B,C]},efz_coverage:decode_new(S,G3)),
        ok=efz_coverage:close(Fresh)
    after efz_coverage:release_schema(S),efz_coverage:release_schema(Other),drain() end.

iteration(S,Hits,Global) ->
    C=efz_coverage:open(bitmap,presence,S),ok=efz_coverage:attach(C),
    lists:foreach(fun(Id)->ok=efz_cov_rt:hit(Id) end,Hits),
    {ok,Bits}=efz_coverage:snapshot_bits(C),
    {ok,NewBits}=efz_coverage:unseen_bits(Global,Bits),
    {ok,New}=efz_coverage:decode_new(S,NewBits),
    {ok,Merged}=efz_coverage:merge_bits(Global,Bits),
    ok=efz_cov:detach(),ok=efz_coverage:close(C),
    {New,Merged}.

cas_stale_read_test() ->
    R=atomics:new(1,[{signed,false}]), Parent=self(),
    Workers=[spawn_monitor(fun()->
        Old=atomics:get(R,1), Parent!{ready,self(),Old},
        receive go->Parent!{done,self(),efz_cov_bitmap:cas_word(R,1,Mask,Old)} end
    end)||Mask<-[1,2,1 bsl 63]],
    [receive {ready,Pid,0}->ok after 2000->error(no_ready) end||{Pid,_}<-Workers],
    [Pid!go||{Pid,_}<-Workers],
    [receive {done,Pid,first}->ok after 2000->error(no_cas) end||{Pid,_}<-Workers],
    ?assertEqual((1 bsl 63) bor 3,atomics:get(R,1)),
    [receive {'DOWN',Mon,process,Pid,normal}->ok after 2000->error(no_down) end||{Pid,Mon}<-Workers].

shared_writers_and_late_context_test() ->
    M=manifest(bitmap_writers,8,8),
    {ok,S}=efz_coverage:prepare_schema([M],64),
    try
        C=efz_coverage:open(bitmap,presence,S),Parent=self(),
        Ids=efz_cov_manifest:identities(M),
        Workers=[spawn_monitor(fun()->
            ok=efz_coverage:attach(C),Parent!{ready,self()},
            receive go->ok=efz_cov_rt:hit(Id),Parent!{done,self()} end
        end)||Id<-Ids],
        [receive {ready,Pid}->ok after 2000->error(no_ready) end||{Pid,_}<-Workers],
        [Pid!go||{Pid,_}<-Workers],
        [receive {done,Pid}->ok after 2000->error(no_hit) end||{Pid,_}<-Workers],
        [receive {'DOWN',Mon,process,Pid,normal}->ok after 2000->error(no_down) end||{Pid,Mon}<-Workers],
        ?assertEqual({ok,Ids},efz_coverage:snapshot(C)),
        Late=spawn_monitor(fun()->
            ok=efz_coverage:attach(C),Parent!{late_ready,self()},
            receive go->Parent!{late_result,self(),catch efz_cov_rt:hit(hd(Ids))} end
        end),
        {LatePid,LateMon}=Late,
        receive {late_ready,LatePid}->ok after 2000->error(no_late_ready) end,
        ok=efz_coverage:close(C),
        Fresh=efz_cov_bitmap:reset(C),
        LatePid!go,
        receive {late_result,LatePid,{'EXIT',{{efz_infrastructure,late_coverage_hit},_}}}->ok
        after 2000->error(no_late_failure) end,
        receive {'DOWN',LateMon,process,LatePid,normal}->ok after 2000->error(no_late_down) end,
        ?assertEqual({ok,[]},efz_coverage:snapshot(Fresh)),
        ok=efz_coverage:close(Fresh)
    after efz_coverage:release_schema(S),drain() end.

feedback_policy_test() ->
    M=manifest(bitmap_feedback,9,3),
    {ok,S}=efz_coverage:prepare_schema([M],64),
    try
        Builds=#{bitmap_feedback=>maps:get(build_id,M)},
        [A,B,C]=efz_cov_manifest:identities(M),
        Legacy=efz_feedback:new(Builds),Bitmap=efz_feedback:new(Builds,presence,S),
        History=[{calibration,{ok,seed},[A]},
                 {mutation,{ok,a},[A]},
                 {mutation,{crash,error,boom,[]},[B]},
                 {mutation,{timeout,10},[C]},
                 {mutation,{ok,b},[B,C]},
                 {mutation,{ok,a_again},[A]}],
        {FinalLegacy,FinalBitmap}=lists:foldl(fun({Phase,Outcome,Hits},{EL,EB})->
            Result=#{builds=>Builds,outcome=>Outcome,coverage_status=>ok,coverage=>Hits},
            {ok,Bits}=observation_bits(S,Hits),
            {ok,NL,DL}=efz_feedback:evaluate(EL,Result,Phase),
            {ok,NB,DB}=efz_feedback:evaluate(EB,Result#{coverage_bits=>Bits},Phase),
            ?assertEqual(DL,DB),
            ?assertEqual(efz_coverage:global_snapshot(maps:get(global,NL)),
                         efz_coverage:global_snapshot(maps:get(global,NB))),
            {NL,NB}
        end,{Legacy,Bitmap},History),
        ?assertEqual([A,B,C],efz_coverage:global_snapshot(maps:get(global,FinalLegacy))),
        ?assertEqual([A,B,C],efz_coverage:global_snapshot(maps:get(global,FinalBitmap)))
    after efz_coverage:release_schema(S),drain() end.

observation_bits(S,Hits) ->
    Context=efz_coverage:open(bitmap,presence,S),ok=efz_coverage:attach(Context),
    lists:foreach(fun(Id)->ok=efz_cov_rt:hit(Id) end,Hits),
    Bits=efz_coverage:snapshot_bits(Context),
    ok=efz_cov:detach(),ok=efz_coverage:close(Context),Bits.

integration_test_() ->
    {timeout,45,{setup,fun integration_setup/0,fun integration_cleanup/1,
        fun(S) -> [
            {"executor differential and failure evidence",fun()->executor_differential(S) end},
            {"timeout leaves only observed evidence",fun()->executor_timeout(S) end},
            {"campaign corpus decisions and backend rollback",fun()->campaign_differential(S) end},
            {"invalid modes reject before campaign",fun()->invalid_modes(S) end}
        ] end}}.

integration_setup() ->
    Specs=[{efz_fixture,"fixtures/efz_fixture.erl"},
           {efz_example_parser,"examples/simple_parser/efz_example_parser.erl"}],
    Artifacts=[begin
        _=code:purge(Module),_=code:delete(Module),_=code:purge(Module),
        {ok,A}=efz_instrument:compile(File,#{modules=>[Module],source_root=>".",
            outdir=>"_build/bitmap-integration-targets",
            erl_opts=>[debug_info,warnings_as_errors,{i,"fixtures/include"},{d,'MAGIC',42}]}),A
    end||{Module,File}<-Specs],
    {ok,Manifests}=efz_instrument:preflight(Artifacts),
    {ok,Plan}=efz_cov_manifest:prepare(automatic,Manifests),
    {ok,Schema}=efz_coverage:prepare_schema(Manifests,65536),
    #{artifacts=>Artifacts,manifests=>Manifests,plan=>Plan,schema=>Schema}.

integration_cleanup(S) ->
    efz:stop(),efz_cov_manifest:release(maps:get(plan,S)),
    efz_coverage:release_schema(maps:get(schema,S)),
    lists:foreach(fun(M)->code:purge(M),code:delete(M),code:purge(M) end,
        [efz_fixture,efz_example_parser]),drain().

executor_options(S,Backend) ->
    Base=#{coverage=>automatic,coverage_backend=>Backend,coverage_plan=>maps:get(plan,S)},
    case Backend of bitmap->Base#{coverage_schema=>maps:get(schema,S)};_->Base end.

executor_differential(S) ->
    Inputs=[{clauses,0},{clauses,2},{nested,1},{exception,error},receive_timeout,{tail,100}],
    E=[canonical_result(efz_executor:run(efz_fixture,I,1000,executor_options(S,ets)))||I<-Inputs],
    B=[canonical_result(efz_executor:run(efz_fixture,I,1000,executor_options(S,bitmap)))||I<-Inputs],
    ?assertEqual(E,B),
    ?assertEqual(true,lists:any(fun({Outcome,_,_})->element(1,Outcome)=:=crash end,B)).

canonical_result(R) ->
    Outcome=case maps:get(outcome,R) of
        {crash,Class,Reason,_}->{crash,Class,Reason};
        Other->Other
    end,
    {Outcome,maps:get(coverage_status,R),maps:get(coverage,R)}.

executor_timeout(S) ->
    Results=[begin
        Parent=self(),Ref=make_ref(),
        {Caller,Mon}=spawn_monitor(fun()->Parent!{Ref,efz_executor:run(efz_fixture,
            {wait,Parent},100,executor_options(S,Backend))} end),
        Target=receive {probe_recorded,P}->P after 2000->error(no_probe) end,
        Result=receive {Ref,R}->R after 3000->error(no_result) end,
        receive {'DOWN',Mon,process,Caller,normal}->ok after 1000->error(no_caller_down) end,
        ?assertNot(is_process_alive(Target)),
        ?assertEqual(false,maps:is_key(coverage_bits,Result)),
        canonical_result(Result)
    end||Backend<-[ets,bitmap]],
    ?assertEqual(hd(Results),lists:last(Results)),
    ?assertMatch({{timeout,100},ok,[_|_]},hd(Results)).

campaign_differential(S) ->
    [_,Parser]=maps:get(artifacts,S),
    Reports=[run_campaign(Parser,B)||B<-[ets,bitmap,ets]],
    [Reference|Others]=Reports,
    lists:foreach(fun(R)->?assertEqual(Reference,R) end,Others).

run_campaign(Parser,Backend) ->
    Config=#{target=>efz_example_target,artifacts=>[Parser],seeds=>[<<0>>],
             mutator=>efz_scripted_mutator,max_iterations=>5,
             coverage_backend=>Backend,random_seed=>{1,2,3},selection_seed=>{4,5,6},
             crash_dir=>filename:join("_build/bitmap-integration-crashes",atom_to_list(Backend))},
    {ok,_}=efz:start(Config),
    try
        Report=efz:await(10000),
        ?assertEqual(completed,maps:get(status,Report)),
        case Backend of
            bitmap ->
                #{execution_maps_allocated:=1,execution_map_arms:=Arms,
                  normal_reuses:=Reuses}=maps:get(bitmap_storage,Report),
                ?assert(Arms >= 6),?assertEqual(Arms-1,Reuses);
            _ -> ok
        end,
        #{coverage=>maps:get(coverage,Report),
          corpus=>[maps:get(input,E)||E<-maps:get(corpus,Report)],
          decisions=>[{maps:get(retention_reason,D),maps:get(new_probes,D,[])}||
                         D<-maps:get(decisions,Report)],
          crashes=>length(maps:get(crashes,Report)),
          stats=>maps:with([discoveries,crashes,timeouts,rejections],maps:get(stats,Report))}
    after efz:stop() end.

invalid_modes(S) ->
    [_,Parser]=maps:get(artifacts,S),
    Base=#{target=>efz_example_target,artifacts=>[Parser],seeds=>[<<0>>],
           coverage_backend=>bitmap},
    ?assertEqual({error,bitmap_requires_automatic_presence},
        efz_config:prepare(Base#{coverage_feedback=>hit_count})),
    ?assertEqual({error,bitmap_requires_automatic_presence},
        efz_config:prepare(Base#{coverage=>manual})),
    ?assertEqual({error,{invalid_campaign_option,coverage_bitmap_bits}},
        efz_config:prepare(Base#{coverage_bitmap_bits=>65})),
    ?assertEqual({error,{invalid_campaign_option,coverage_bitmap_bits}},
        efz_config:prepare(Base#{coverage_bitmap_bits=>1 bsl 60})).

manifest(Module,Byte,N) ->
    #{schema_version=>1,instrumentation_version=>1,metric=>clause_outcome_probe,
      module=>Module,build_id=>binary:copy(<<Byte>>,32),limitations=>[],
      probes=>[#{probe_id=>I,function=>run,arity=>1,kind=>function_clause,
                 structural_location=>[I],source_file=>"bitmap-test",line=>I,column=>1}
               || I<-lists:seq(1,N)]}.

drain() -> receive {efz_cov_observed,_,_}->drain();{efz_cov_failure,_,_}->drain()
           after 0->ok end.
