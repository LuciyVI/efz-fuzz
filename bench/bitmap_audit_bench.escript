#!/usr/bin/env escript
-mode(compile).

%% Audit-only paired full cycles. One sample is one fresh execution and global.
main([Out]) ->
    true=code:add_patha("_build/default/lib/efz/ebin"),
    {ok,_}=application:ensure_all_started(crypto),
    {ok,S}=efz_coverage:prepare_schema([manifest(1024)],65536),
    Ids=efz_cov_manifest:identities(manifest(1024)),
    Cases=[{one_hit,lists:sublist(Ids,1)},
           {hundred_hits,lists:sublist(Ids,100)},
           {thousand_hits,lists:sublist(Ids,1000)},
           {ten_thousand_hits,[lists:nth((I rem 1024)+1,Ids)||I<-lists:seq(0,9999)]},
           {ten_thousand_repeated,lists:duplicate(10000,hd(Ids))}],
    try
        Rows=[pair(Name,Events,S)||{Name,Events}<-Cases],
        Result=#{environment=>#{otp=>erlang:system_info(otp_release),
            erts=>erlang:system_info(version),architecture=>erlang:system_info(system_architecture),
            schedulers=>erlang:system_info(schedulers_online),warmup_pairs=>2,sample_pairs=>10,
            capacity_bits=>65536,manifest_probes=>length(Ids)},rows=>Rows},
        ok=file:write_file(Out,io_lib:format("~tp.~n",[Result])),
        io:format("~tp~n",[Result])
    after efz_coverage:release_schema(S) end;
main(_) -> erlang:error("usage: escript bench/bitmap_audit_bench.escript OUTPUT_FILE").

manifest(N) ->
    #{schema_version=>1,instrumentation_version=>1,metric=>clause_outcome_probe,
      module=>bitmap_audit_bench,build_id=>binary:copy(<<43>>,32),limitations=>[],
      probes=>[#{probe_id=>I,function=>run,arity=>1,kind=>function_clause,
                 structural_location=>[I],source_file=>"bitmap-audit-bench",line=>I,column=>1}
               || I<-lists:seq(1,N)]}.

pair(Name,Events,S) ->
    lists:foreach(fun(_)->sample(ets,Events,S),sample(bitmap,Events,S) end,lists:seq(1,2)),
    Samples=lists:append([case I rem 2 of
        1->[sample(ets,Events,S),sample(bitmap,Events,S)];
        0->[sample(bitmap,Events,S),sample(ets,Events,S)]
    end||I<-lists:seq(1,10)]),
    #{name=>Name,event_count=>length(Events),samples=>Samples,
      summary=>maps:from_list([{B,summary([maps:get(us,X)||X<-Samples,maps:get(backend,X)=:=B])}
                              ||B<-[ets,bitmap]])}.

summary(Times0)->Times=lists:sort(Times0),
    #{median_us=>lists:nth(5,Times),min_us=>hd(Times),max_us=>lists:last(Times)}.

sample(B,Events,S)->
    erlang:garbage_collect(),
    {reductions,R0}=process_info(self(),reductions),
    {garbage_collection,G0}=process_info(self(),garbage_collection),
    {Us,_}=timer:tc(fun()->cycle(B,Events,S) end),
    {reductions,R1}=process_info(self(),reductions),
    {garbage_collection,G1}=process_info(self(),garbage_collection),
    #{backend=>B,us=>Us,reductions=>R1-R0,
      minor_gcs=>proplists:get_value(minor_gcs,G1,0)-proplists:get_value(minor_gcs,G0,0)}.

cycle(ets,Events,_S)->
    C=efz_coverage:open(ets,presence),ok=efz_coverage:attach(C),
    lists:foreach(fun efz_cov_rt:hit/1,Events),
    {ok,Observed}=efz_coverage:snapshot(C),
    ok=efz_cov:detach(),ok=efz_coverage:close(C),
    Global=efz_coverage:new_global(),
    _=efz_coverage:unseen(Global,Observed),
    _=efz_coverage:merge(Global,Observed),ok;
cycle(bitmap,Events,S)->
    C=efz_coverage:open(bitmap,presence,S),ok=efz_coverage:attach(C),
    lists:foreach(fun efz_cov_rt:hit/1,Events),
    {ok,_Observed}=efz_coverage:snapshot(C),
    {ok,Bits}=efz_coverage:snapshot_bits(C),
    ok=efz_cov:detach(),ok=efz_coverage:close(C),
    Global=efz_coverage:new_global(S),
    {ok,New}=efz_coverage:unseen_bits(Global,Bits),
    {ok,_}=efz_coverage:decode_new(S,New),
    {ok,_}=efz_coverage:merge_bits(Global,Bits),ok.
