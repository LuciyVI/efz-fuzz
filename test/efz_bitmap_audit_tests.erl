-module(efz_bitmap_audit_tests).
-include_lib("eunit/include/eunit.hrl").

%% Audit history: exact same events and outcomes for the reference and bitmap.
wide_differential_test_() -> {timeout, 120, fun wide_differential/0}.

invalid_identity_test() ->
    M=manifest(audit_invalid,3,2),
    %% Validation accepts impractically large capacity before allocation.
    ?assertEqual(ok,efz_coverage:check_capacity([M],1 bsl 60)),
    ?assertMatch({error,{invalid_manifests,_}},
        efz_coverage:prepare_schema([M#{probes=>[(hd(maps:get(probes,M)))#{probe_id=>-1}]}],64)),
    {ok,S}=efz_coverage:prepare_schema([M],64),
    try
        C=efz_coverage:open(bitmap,presence,S),ok=efz_coverage:attach(C),
        B=maps:get(build_id,M),
        lists:foreach(fun(Id)->
            ?assertError({efz_infrastructure,{unexpected_probe_or_build,_}},
                         efz_cov_rt:hit(Id))
        end,[{audit_invalid,B,-1},{audit_invalid,B,0},
             {audit_invalid,B,1 bsl 100},{audit_invalid,<<0:256>>,1}]),
        ?assertEqual({ok,[]},efz_coverage:snapshot(C)),
        ok=efz_cov:detach(),ok=efz_coverage:close(C)
    after efz_coverage:release_schema(S),drain() end.

%% Documents the limitation of clear_quiescent/1: Active=0 is not a join.
closed_clear_stale_cas_test() ->
    {ok,S}=efz_coverage:prepare_schema([manifest(audit_clear,4,2)],64),
    try
        C=efz_coverage:open(bitmap,presence,S),
        {bitmap,_,Words,_}=element(4,C),
        Old=atomics:get(Words,1),
        ok=efz_coverage:close(C),
        ok=efz_cov_bitmap:clear_quiescent(C),
        first=efz_cov_bitmap:cas_word(Words,1,2,Old),
        ?assertEqual(2,atomics:get(Words,1))
    after efz_coverage:release_schema(S) end.

sealed_reuse_and_retirement_test_() -> {timeout, 120, fun sealed_reuse_and_retirement/0}.
sealed_reuse_and_retirement() ->
    M=manifest(audit_reuse,11,128),
    {ok,S}=efz_coverage:prepare_schema([M],128),
    {ok,OtherS}=efz_coverage:prepare_schema([manifest(audit_reuse,13,128)],128),
    try
        [A,B|_]=efz_cov_manifest:identities(M),
        G=efz_coverage:new_global(S),
        Map=efz_coverage:allocate_execution(S),
        {efz_bitmap_map,_,Words,Active}=Map,
        BeforeMemory={atomics:info(Words),atomics:info(Active)},
        %% The same atomics are rearmed 10,000 times; A/B/A must never leak.
        lists:foreach(fun(I)->
            Id=case I rem 2 of 0->A;_->B end,
            C=efz_coverage:open(bitmap,presence,S,Map),
            ok=efz_coverage:attach(C),ok=efz_cov_rt:hit(Id),
            ok=efz_cov:detach(),
            Sealed=efz_coverage:seal(C),
            ?assertEqual({ok,1},efz_coverage:sealed_count(Sealed)),
            {ok,Bits}=efz_coverage:diagnostic_snapshot(Sealed),
            ?assertEqual({ok,[Id]},efz_coverage:decode_new(S,Bits)),
            ?assertEqual({ok,true},efz_coverage:has_new(G,Sealed))
        end,lists:seq(1,10000)),
        ?assertEqual(BeforeMemory,{atomics:info(Words),atomics:info(Active)}),
        Shared=efz_coverage:open(bitmap,presence,S,Map),Parent0=self(),
        Writers=[spawn_monitor(fun()->
            ok=efz_coverage:attach(Shared),Parent0!{shared_ready,self()},
            receive go -> ok=efz_cov_rt:hit(Id) end
        end)||Id<-[A,B]],
        [receive {shared_ready,P}->ok after 2000->error(shared_not_ready) end||{P,_}<-Writers],
        [P!go||{P,_}<-Writers],
        [receive {'DOWN',Ref,process,P,normal}->ok after 2000->error(shared_not_done) end
         ||{P,Ref}<-Writers],
        SharedSeal=efz_coverage:seal(Shared),
        ?assertEqual({ok,2},efz_coverage:sealed_count(SharedSeal)),
        ?assertEqual({error,incompatible_coverage_schema},
                     efz_coverage:has_new(efz_coverage:new_global(OtherS),SharedSeal)),
        %% An observation token is invalid after the next arm, even once
        %% that generation has also been sealed.
        C0=efz_coverage:open(bitmap,presence,S,Map),
        ?assertError({efz_infrastructure,bitmap_map_not_sealed},
                     efz_coverage:open(bitmap,presence,S,Map)),
        ok=efz_coverage:close(C0),
        C1=efz_coverage:open(bitmap,presence,S,Map),
        Seal1=efz_coverage:seal(C1),
        C2=efz_coverage:open(bitmap,presence,S,Map),
        ?assertEqual({error,unsealed_coverage},efz_coverage:has_new(G,Seal1)),
        ok=efz_coverage:close(C2),
        ?assertEqual({error,unsealed_coverage},efz_coverage:has_new(G,Seal1)),
        %% If cleanup is unconfirmed, the old allocation is retired. A
        %% deliberately stalled child can write only into its old map.
        Old=efz_coverage:open(bitmap,presence,S), Parent=self(),
        {Pid,Mon}=spawn_monitor(fun()->
            ok=efz_coverage:attach(Old), Parent!{writer_ready,self()},
            receive go -> ok=efz_cov_rt:hit(A) end
        end),
        receive {writer_ready,Pid}->ok after 2000->error(writer_not_ready) end,
        NewMap=efz_coverage:allocate_execution(S),
        New=efz_coverage:open(bitmap,presence,S,NewMap),
        ok=efz_coverage:attach(New),ok=efz_cov_rt:hit(B),ok=efz_cov:detach(),
        Pid!go,
        receive {'DOWN',Mon,process,Pid,normal}->ok after 2000->error(writer_not_done) end,
        ?assertEqual({ok,[B]},efz_coverage:snapshot(New)),
        ok=efz_coverage:close(New),ok=efz_coverage:close(Old)
    after efz_coverage:release_schema(S),efz_coverage:release_schema(OtherS),drain() end.

sealed_feedback_differential_test() ->
    M=manifest(audit_sealed,12,128),{ok,S}=efz_coverage:prepare_schema([M],128),
    try
        Builds=#{audit_sealed=>maps:get(build_id,M)},
        [A,B,C|_]=efz_cov_manifest:identities(M),
        Map=efz_coverage:allocate_execution(S),
        History=[{{ok,a},[A,B]},{{ok,b},[A,B]},{{crash,error,boom,[]},[C]},
                 {{timeout,10},[C]},{{ok,c},[C]},{{ok,d},[]},
                 {{ok,e},[A,B,C]}],
        lists:foldl(fun({Outcome,Ids},{Legacy,Bitmap})->
            Ctx=efz_coverage:open(bitmap,presence,S,Map),
            ok=efz_coverage:attach(Ctx),
            lists:foreach(fun efz_cov_rt:hit/1,Ids),ok=efz_cov:detach(),
            Sealed=efz_coverage:seal(Ctx),
            Result=#{builds=>Builds,outcome=>Outcome,coverage_status=>ok,coverage=>Ids},
            {ok,L1,DL}=efz_feedback:evaluate(Legacy,Result,mutation),
            {ok,B1,DB}=efz_feedback:evaluate(Bitmap,(maps:remove(coverage,Result))#{
                coverage_sealed=>Sealed},mutation),
            ?assertEqual(DL,DB),
            ?assertEqual(efz_coverage:global_snapshot(maps:get(global,L1)),
                         efz_coverage:global_snapshot(maps:get(global,B1))),
            {L1,B1}
        end,{efz_feedback:new(Builds),efz_feedback:new(Builds,presence,S)},History)
    after efz_coverage:release_schema(S),drain() end.

wide_differential() ->
    A=manifest(audit_a,1,65535), Z=manifest(audit_z,2,1),
    {ok,Schema}=efz_coverage:prepare_schema([A,Z],65536),
    try
        Build=maps:from_list([{maps:get(module,M),maps:get(build_id,M)}||M<-[A,Z]]),
        Id=fun(N)->{audit_a,maps:get(build_id,A),N} end,
        Other={audit_z,maps:get(build_id,Z),1},
        History=[{{ok,a},[Id(1),Id(2),Id(3),Id(3)]},
                 {{ok,b},[Id(1),Id(2)]},
                 {{ok,c},[Id(3),Id(4)]},
                 {{ok,d},[]},
                 {{ok,e},[Id(63),Id(64),Id(65)]},
                 {{ok,f},[Id(65535),Other]},
                 {{ok,g},[Id(65535)]},
                 {{crash,error,boom,[]},[Id(100)]},
                 {{timeout,10},[Id(101)]},
                 {{ok,h},[Id(100),Id(101)]}],
        {_,_}=lists:foldl(fun({Outcome,Events},{Legacy,Bitmap})->
            Observed=legacy_observation(Events),
            {BitmapObserved,Bits}=bitmap_observation(Schema,Events),
            ?assertEqual(Observed,BitmapObserved),
            Result=#{builds=>Build,coverage_status=>ok,outcome=>Outcome,coverage=>Observed},
            {ok,NextLegacy,LegacyDecision}=efz_feedback:evaluate(Legacy,Result,mutation),
            {ok,NextBitmap,BitmapDecision}=efz_feedback:evaluate(Bitmap,
                Result#{coverage_bits=>Bits},mutation),
            ?assertEqual(LegacyDecision,BitmapDecision),
            ?assertEqual(efz_coverage:global_snapshot(maps:get(global,NextLegacy)),
                         efz_coverage:global_snapshot(maps:get(global,NextBitmap))),
            {NextLegacy,NextBitmap}
        end,{efz_feedback:new(Build),efz_feedback:new(Build,presence,Schema)},History)
    after efz_coverage:release_schema(Schema),drain() end.

legacy_observation(Events) ->
    C=efz_coverage:open(ets,presence),ok=efz_coverage:attach(C),
    lists:foreach(fun efz_cov_rt:hit/1,Events),
    {ok,Observed}=efz_coverage:snapshot(C),
    ok=efz_cov:detach(),ok=efz_coverage:close(C),
    Observed.

bitmap_observation(Schema,Events) ->
    C=efz_coverage:open(bitmap,presence,Schema),ok=efz_coverage:attach(C),
    lists:foreach(fun efz_cov_rt:hit/1,Events),
    {ok,Observed}=efz_coverage:snapshot(C),
    {ok,Bits}=efz_coverage:snapshot_bits(C),
    ok=efz_cov:detach(),ok=efz_coverage:close(C),
    {Observed,Bits}.

manifest(Module,Byte,N) ->
    #{schema_version=>1,instrumentation_version=>1,metric=>clause_outcome_probe,
      module=>Module,build_id=>binary:copy(<<Byte>>,32),limitations=>[],
      probes=>[#{probe_id=>I,function=>run,arity=>1,kind=>function_clause,
                 structural_location=>[I],source_file=>"bitmap-audit",line=>I,column=>1}
               || I<-lists:seq(1,N)]}.

drain() -> receive {efz_cov_observed,_,_}->drain();{efz_cov_failure,_,_}->drain()
           after 0->ok end.
