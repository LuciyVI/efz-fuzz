#!/usr/bin/env escript
-mode(compile).

%% Bounded component timings; preparation is outside the timed region.
main([Out]) ->
    true=code:add_patha("_build/default/lib/efz/ebin"),
    {ok,_}=application:ensure_all_started(crypto),
    M=manifest(1024),Big=manifest(65536),
    {ok,S}=efz_coverage:prepare_schema([M],65536),
    {ok,LastSchema}=efz_coverage:prepare_schema([Big],65536),
    Ids=efz_cov_manifest:identities(M),
    try
        First=sealed(S,[hd(Ids)]),
        Last=sealed(LastSchema,[lists:last(efz_cov_manifest:identities(Big))]),
        Sparse=sealed(S,lists:sublist(Ids,8)),Dense=sealed(S,Ids),
        Local256=sealed(S,lists:sublist(Ids,256)),
        Empty=efz_coverage:new_global(S),LastEmpty=efz_coverage:new_global(LastSchema),
        {ok,Known}=efz_coverage:commit_sealed(Empty,Dense),
        {ok,Prior128}=efz_coverage:commit_sealed(Empty,
                         sealed(S,lists:sublist(Ids,128))),
        Map=efz_coverage:allocate_execution(S),
        HitContext=efz_coverage:open(bitmap,presence,S,efz_coverage:allocate_execution(S)),
        ok=efz_coverage:attach(HitContext),
        HitId=hd(Ids),ok=efz_cov_rt:hit(HitId),
        {bitmap,_,HitWords,_}=element(4,HitContext),
        SlotTable=maps:get(table,S),
        Cases=[{reset_full_clear,100,fun()->C=efz_coverage:open(bitmap,presence,S,Map),
                                        _=efz_coverage:seal(C),ok end},
               {hit_context_lookup,10000,fun()->_ = get('$efz_execution_context'),ok end},
               {hit_integrity_lookup,10000,fun()->_ = efz_cov_integrity:expected(),ok end},
               {hit_slot_lookup,10000,fun()->_ = ets:lookup(SlotTable,HitId),ok end},
               {hit_atomic_read,10000,fun()->_ = atomics:get(HitWords,1),ok end},
               {hit_repeated_10000,10000,fun()->ok=efz_cov_rt:hit(HitId) end},
               {count_sparse,1000,fun()->{ok,_}=efz_coverage:sealed_count(Sparse),ok end},
               {count_dense,1000,fun()->{ok,_}=efz_coverage:sealed_count(Dense),ok end},
               {novelty_false_sparse,1000,fun()->{ok,false}=efz_coverage:has_new(Known,Sparse),ok end},
               {novelty_false_dense,1000,fun()->{ok,false}=efz_coverage:has_new(Known,Dense),ok end},
               {novelty_first_word,1000,fun()->{ok,true}=efz_coverage:has_new(Empty,First),ok end},
               {novelty_256_after_128,1000,fun()->{ok,true}=efz_coverage:has_new(Prior128,Local256),ok end},
               {novelty_last_word,1000,fun()->{ok,true}=efz_coverage:has_new(LastEmpty,Last),ok end},
               {commit_256,100,fun()->{ok,_}=efz_coverage:commit_sealed(Prior128,Local256),ok end},
               {commit_sparse,100,fun()->{ok,_}=efz_coverage:commit_sealed(Empty,Sparse),ok end},
               {commit_dense,100,fun()->{ok,_}=efz_coverage:commit_sealed(Empty,Dense),ok end}],
        Rows=[measure(Name,Count,Fun)||{Name,Count,Fun}<-Cases],
        ok=efz_cov:detach(),ok=efz_coverage:close(HitContext),
        Result=#{environment=>#{otp=>erlang:system_info(otp_release),
            erts=>erlang:system_info(version),architecture=>erlang:system_info(system_architecture),
            schedulers=>erlang:system_info(schedulers_online),warmup=>2,samples=>10,
            bitmap_bits=>65536,manifest_probes=>1024},rows=>Rows},
        ok=file:write_file(Out,io_lib:format("~tp.~n",[Result])),
        io:format("~tp~n",[Result])
    after efz_coverage:release_schema(S),efz_coverage:release_schema(LastSchema) end;
main(_) -> erlang:error("usage: escript bench/bitmap_v2_components.escript OUTPUT_FILE").

sealed(S,Ids) ->
    C=efz_coverage:open(bitmap,presence,S,efz_coverage:allocate_execution(S)),
    ok=efz_coverage:attach(C),
    lists:foreach(fun efz_cov_rt:hit/1,Ids),ok=efz_cov:detach(),
    efz_coverage:seal(C).

measure(Name,Count,Fun) ->
    lists:foreach(fun(_)->repeat(Count,Fun) end,lists:seq(1,2)),
    Samples=[begin erlang:garbage_collect(),
                   {Us,_}=timer:tc(fun()->repeat(Count,Fun) end),Us/Count end
             || _<-lists:seq(1,10)],
    Sorted=lists:sort(Samples),
    #{name=>Name,iterations_per_sample=>Count,us_per_call=>Samples,
      median_us=>lists:nth(5,Sorted),min_us=>hd(Sorted),max_us=>lists:last(Sorted)}.

repeat(0,_) -> ok;
repeat(N,Fun) -> ok=Fun(),repeat(N-1,Fun).

manifest(N) ->
    #{schema_version=>1,instrumentation_version=>1,metric=>clause_outcome_probe,
      module=>bitmap_v2_components,build_id=>binary:copy(<<45>>,32),limitations=>[],
      probes=>[#{probe_id=>I,function=>run,arity=>1,kind=>function_clause,
                 structural_location=>[I],source_file=>"bitmap-v2-bench",line=>I,column=>1}
               || I<-lists:seq(1,N)]}.
