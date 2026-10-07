#!/usr/bin/env escript
%% Paired, bounded bitmap/ETS measurements. Raw samples are retained as terms.
-mode(compile).

main([Out]) ->
    true=code:add_patha("_build/default/lib/efz/ebin"),
    {ok,_}=application:ensure_all_started(crypto),
    ok=filelib:ensure_dir(filename:join(Out,"x")),
    M=manifest(1024),{ok,S}=efz_coverage:prepare_schema([M],65536),
    Ids=efz_cov_manifest:identities(M),
    try
        Cases=[{"hit_repeated_5000",fun(B)->prepare_hit(B,S,[hd(Ids)],5000) end},
               {"hit_sparse_64",fun(B)->prepare_hit(B,S,lists:sublist(Ids,64),1) end},
               {"hit_dense_1024",fun(B)->prepare_hit(B,S,Ids,1) end},
               {"reset_fresh",fun(B)->prepare_reset(B,S) end},
               {"snapshot_64",fun(B)->prepare_snapshot(B,S,lists:sublist(Ids,64)) end},
               {"snapshot_1024",fun(B)->prepare_snapshot(B,S,Ids) end},
               {"decode_1024",fun(B)->prepare_decode(B,S,Ids) end},
               {"full_clear",fun(B)->prepare_clear(B,S) end},
               {"compare_256",fun(B)->prepare_compare(B,S,Ids) end},
               {"merge_256",fun(B)->prepare_merge(B,S,Ids) end},
               {"full_cycle_sparse",fun(B)->{fun()->cycle_case(B,S,lists:sublist(Ids,8),10) end,fun()->ok end} end},
               {"full_cycle_dense",fun(B)->{fun()->cycle_case(B,S,Ids,5) end,fun()->ok end} end},
               {"one_writer",fun(B)->{fun()->writers_case(B,S,lists:sublist(Ids,1)) end,fun()->ok end} end},
               {"two_writers_same_word",fun(B)->{fun()->writers_case(B,S,lists:sublist(Ids,2)) end,fun()->ok end} end},
               {"four_writers_same_word",fun(B)->{fun()->writers_case(B,S,lists:sublist(Ids,4)) end,fun()->ok end} end},
               {"eight_writers_same_word",fun(B)->{fun()->writers_case(B,S,lists:sublist(Ids,8)) end,fun()->ok end} end}],
        Rows=[paired(Name,F,10)||{Name,F}<-Cases],
        Campaign=campaign_pairs(Out,10),
        Environment=#{otp=>erlang:system_info(otp_release),
                      erts=>erlang:system_info(version),
                      architecture=>erlang:system_info(system_architecture),
                      word_bytes=>erlang:system_info(wordsize),
                      schedulers=>erlang:system_info(schedulers_online),
                      schedulers_total=>erlang:system_info(schedulers),
                      beam_memory=>erlang:memory(),
                      sample_pairs=>10,warmup_pairs=>2,
                      bitmap_bits=>65536,manifest_probes=>length(Ids)},
        Result=#{environment=>Environment,rows=>Rows,campaign=>Campaign,
                 storage_memory=>storage_memory(S,Ids)},
        ok=file:write_file(filename:join(Out,"bitmap-benchmark.term"),term_to_binary(Result)),
        io:format("~tp~n",[Result])
    after efz_coverage:release_schema(S) end;
main(_) -> erlang:error("usage: escript bench/bitmap_bench.escript OUTPUT_DIR").

manifest(N) ->
    #{schema_version=>1,instrumentation_version=>1,metric=>clause_outcome_probe,
      module=>bitmap_bench,build_id=>binary:copy(<<42>>,32),limitations=>[],
      probes=>[#{probe_id=>I,function=>run,arity=>1,kind=>function_clause,
                 structural_location=>[I],source_file=>"bitmap-bench",line=>I,column=>1}
               || I<-lists:seq(1,N)]}.

open(ets,_)->efz_coverage:open(ets,presence);
open(bitmap,S)->efz_coverage:open(bitmap,presence,S).
hits(Ids,Count)->lists:foreach(fun(_)->lists:foreach(fun efz_cov_rt:hit/1,Ids) end,
    lists:seq(1,Count)).
with_context(B,S,F)->
    C=open(B,S),ok=efz_coverage:attach(C),
    try F(C) after ok=efz_cov:detach(),ok=efz_coverage:close(C) end.
prepare_hit(B,S,Ids,Count)->
    C=open(B,S),ok=efz_coverage:attach(C),
    {fun()->hits(Ids,Count) end,
     fun()->ok=efz_cov:detach(),ok=efz_coverage:close(C) end}.
prepare_reset(B,S)->
    C=open(B,S),ok=efz_coverage:close(C),
    {fun()->Next=case B of ets->open(ets,S);bitmap->efz_cov_bitmap:reset(C) end,
            ok=efz_coverage:close(Next) end,fun()->ok end}.
prepare_snapshot(B,S,Ids)->
    C=open(B,S),ok=efz_coverage:attach(C),hits(Ids,1),ok=efz_cov:detach(),
    {fun()->case B of
        ets->{ok,_}=efz_coverage:snapshot(C);
        bitmap->{ok,_}=efz_coverage:snapshot_bits(C)
    end end,fun()->ok=efz_coverage:close(C) end}.

prepare_decode(ets,S,Ids)->
    C=open(ets,S),ok=efz_coverage:attach(C),hits(Ids,1),ok=efz_cov:detach(),
    {fun()->{ok,_}=efz_coverage:snapshot(C) end,fun()->ok=efz_coverage:close(C) end};
prepare_decode(bitmap,S,Ids)->
    Bits=prepared(bitmap,S,Ids),
    {fun()->{ok,_}=efz_coverage:decode_new(S,Bits) end,fun()->ok end}.
prepare_clear(ets,S)->prepare_reset(ets,S);
prepare_clear(bitmap,S)->
    C=open(bitmap,S),ok=efz_coverage:close(C),
    {fun()->ok=efz_cov_bitmap:clear_quiescent(C) end,fun()->ok end}.

storage_memory(S,Ids)->
    C=open(bitmap,S),
    Bitmap=efz_cov_bitmap:memory(C),
    ok=efz_coverage:close(C),
    E=open(ets,S),
    ok=efz_coverage:attach(E),hits(Ids,1),ok=efz_cov:detach(),
    EtsWords=ets:info(element(4,E),memory),
    ok=efz_coverage:close(E),
    #{bitmap=>Bitmap,ets_1024_hit_table_words=>EtsWords,
      ets_word_bytes=>erlang:system_info(wordsize)}.

prepared(B,S,Ids)->with_context(B,S,fun(C)->
    hits(Ids,1),case B of
        ets->{ok,H}=efz_coverage:snapshot(C),H;
        bitmap->{ok,Bits}=efz_coverage:snapshot_bits(C),Bits
    end end).
prepare_compare(ets,_S,Ids)->
    Global=sets:from_list(lists:sublist(Ids,128)),
    Local=lists:sublist(Ids,256),
    {fun()->[_|_]=efz_coverage:unseen(Global,Local),ok end,fun()->ok end};
prepare_compare(bitmap,S,Ids)->
    Global0=efz_coverage:new_global(S),
    Prior=prepared(bitmap,S,lists:sublist(Ids,128)),
    {ok,Global}=efz_coverage:merge_bits(Global0,Prior),
    Local=prepared(bitmap,S,lists:sublist(Ids,256)),
    {fun()->{ok,_}=efz_coverage:unseen_bits(Global,Local),ok end,fun()->ok end}.
prepare_merge(ets,_S,Ids)->
    Global=sets:from_list(lists:sublist(Ids,128)),
    Local=lists:sublist(Ids,256),
    {fun()->_=efz_coverage:merge(Global,Local),ok end,fun()->ok end};
prepare_merge(bitmap,S,Ids)->
    Global0=efz_coverage:new_global(S),
    Prior=prepared(bitmap,S,lists:sublist(Ids,128)),
    {ok,Global}=efz_coverage:merge_bits(Global0,Prior),
    Local=prepared(bitmap,S,lists:sublist(Ids,256)),
    {fun()->{ok,_}=efz_coverage:merge_bits(Global,Local),ok end,fun()->ok end}.
cycle_case(ets,S,Ids,N)->cycle_ets(S,Ids,N,efz_coverage:new_global());
cycle_case(bitmap,S,Ids,N)->cycle_bitmap(S,Ids,N,efz_coverage:new_global(S)).
cycle_ets(_,_,0,_)->ok;
cycle_ets(S,Ids,N,Global)->
    Local=prepared(ets,S,Ids),
    _New=efz_coverage:unseen(Global,Local),
    cycle_ets(S,Ids,N-1,efz_coverage:merge(Global,Local)).
cycle_bitmap(_,_,0,_)->ok;
cycle_bitmap(S,Ids,N,Global)->
    Local=prepared(bitmap,S,Ids),
    {ok,_New}=efz_coverage:unseen_bits(Global,Local),
    {ok,Merged}=efz_coverage:merge_bits(Global,Local),
    cycle_bitmap(S,Ids,N-1,Merged).
writers_case(B,S,Ids)->
    C=open(B,S),Parent=self(),
    Workers=[spawn_monitor(fun()->ok=efz_coverage:attach(C),Parent!{ready,self()},
        receive go->hits([Id],100),Parent!{done,self()} end end)||Id<-Ids],
    [receive {ready,P}->ok after 2000->error(no_ready) end||{P,_}<-Workers],
    [P!go||{P,_}<-Workers],
    [receive {done,P}->ok after 2000->error(no_done) end||{P,_}<-Workers],
    [receive {'DOWN',Ref,process,P,normal}->ok after 2000->error(no_down) end||{P,Ref}<-Workers],
    {ok,Ids}=efz_coverage:snapshot(C),ok=efz_coverage:close(C).

paired(Name,Fun,Count)->
    lists:foreach(fun(_)->sample(ets,Fun),sample(bitmap,Fun) end,lists:seq(1,2)),
    Samples=lists:append([case I rem 2 of
        1 -> [sample(ets,Fun),sample(bitmap,Fun)];
        0 -> [sample(bitmap,Fun),sample(ets,Fun)]
    end||I<-lists:seq(1,Count)]),
    #{name=>Name,samples=>Samples,summary=>summary(Samples)}.
sample(B,Fun)->
    erlang:garbage_collect(),
    {Timed,Cleanup}=Fun(B),
    {reductions,R0}=process_info(self(),reductions),
    {garbage_collection,G0}=process_info(self(),garbage_collection),
    {Us,_}=timer:tc(Timed),
    {reductions,R1}=process_info(self(),reductions),
    {garbage_collection,G1}=process_info(self(),garbage_collection),
    ok=Cleanup(),
    #{backend=>B,us=>Us,reductions=>R1-R0,
      minor_gcs=>proplists:get_value(minor_gcs,G1,0)-proplists:get_value(minor_gcs,G0,0)}.
summary(Samples)->maps:from_list([{B,begin
    Times=lists:sort([maps:get(us,R)||R<-Samples,maps:get(backend,R)=:=B]),
    #{median_us=>lists:nth((length(Times)+1) div 2,Times),
      p95_us=>lists:nth((95*length(Times)+99) div 100,Times),
      min_us=>hd(Times),max_us=>lists:last(Times)}
end}||B<-[ets,bitmap]]).

campaign_pairs(Out,Count)->
    _=code:purge(efz_example_parser),_=code:delete(efz_example_parser),
    {ok,Artifact}=efz_instrument:compile("examples/simple_parser/efz_example_parser.erl",
        #{modules=>[efz_example_parser],source_root=>".",
          outdir=>filename:join(Out,"targets")}),
    {ok,_}=efz_instrument:preflight([Artifact]),
    Run=fun(B)->campaign(Out,Artifact,B) end,
    lists:foreach(fun(_)->Run(ets),Run(bitmap) end,lists:seq(1,2)),
    Samples=lists:append([case I rem 2 of
        1->[Run(ets),Run(bitmap)];0->[Run(bitmap),Run(ets)] end
        ||I<-lists:seq(1,Count)]),
    #{workload=>example_parser_random_50,samples=>Samples,
      summary=>summary(Samples)}.
campaign(Out,Artifact,Backend)->
    C=#{target=>efz_example_target,artifacts=>[Artifact],seeds=>[<<0>>],
        mutator=>efz_mutator_random,max_iterations=>50,coverage_backend=>Backend,
        random_seed=>{17,23,41},selection_seed=>{101,109,113},timeout=>100,
        crash_dir=>filename:join([Out,"crashes",atom_to_list(Backend)])},
    Started=erlang:monotonic_time(microsecond),
    {ok,_}=efz:start(C),
    try
        Report=efz:await(30000),
        WallUs=erlang:monotonic_time(microsecond)-Started,
        #{status:=completed,timing:=Timing,stats:=Stats}=Report,
        0=maps:get(infrastructure_failures,Stats),
        #{backend=>Backend,us=>WallUs,mutation_us=>maps:get(mutation_us,Timing),
          executions=>maps:get(executions,Stats),
          exec_per_s=>1000000*maps:get(executions,Stats)/max(1,WallUs),
          corpus_size=>length(maps:get(corpus,Report)),
          coverage_size=>length(maps:get(coverage,Report))}
    after efz:stop() end.
