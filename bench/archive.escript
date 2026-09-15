#!/usr/bin/env escript
%% Audit complete local artifacts and retain compact, consultable evidence.
-mode(compile).
main([Final, Destination]) ->
    true=code:add_patha("_build/default/lib/efz/ebin"),
    Env=read(Final,"environment"),
    Hooks=rows(Final,"hooks",36),Executors=rows(Final,"executor",12),Campaigns=rows(Final,"campaign",24),
    Checks=[begin
        Rs=[R||R=#{fixture:=F1,mode:=M1}<-Campaigns,F1=:=F,M1=:=Mode],
        4=length(Rs),
        [Check]=lists:usort([maps:get(check,S)||R<-Rs,S<-maps:get(samples,R)]),
        #{fixture=>F,mode=>Mode,check_sha256=>hash(term_to_binary(Check)),
          successful_probes=>length(maps:get(coverage,Check)),
          corpus_entries=>length(maps:get(corpus,Check)),stats=>maps:get(stats,Check)}
    end||F<-[loop,parser,sparse],Mode<-[replay,real]],
    %% Rebuild identities, never execute another throughput measurement.
    lists:foreach(fun verify_fixture/1,maps:get(fixtures,Env)),
    Memory=[memory_group("_build/performance-memory-",V,Env)||V<-variants()],
    MemoryAfter=[memory_group("_build/phase21-closeout-memory-",V,Env)||V<-variants()],
    Core=[verify_beam(P)||P<-filelib:wildcard("_build/default/lib/efz/ebin/*.beam")],
    Files=lists:usort(lists:append([filelib:wildcard(P)||P<-["src/*.erl","src/*.src","test/*.erl",
        "bench/*","fixtures/*.erl","fixtures/include/*","fixtures/performance/*.erl",
        "examples/automatic/*","examples/simple_parser/*.erl","rebar.config","scripts/*"]])),
    Sources=[{P,file_hash(P)}||P<-Files,filelib:is_regular(P)],
    Report=read(Final,"automatic-example"),completed=maps:get(status,Report),
    0=maps:get(infrastructure_failures,maps:get(stats,Report)),
    true=maps:get(discoveries,maps:get(stats,Report))>0,true=maps:get(crashes,maps:get(stats,Report))>0,
    Profiles=[{P,begin {ok,B}=file:read_file(P),true=binary:match(B,<<"Total:">>)=/=nomatch,B end}
        ||P<-filelib:wildcard("_build/phase21-baseline/profile-*.txt")++[filename:join(Final,"profile-sparse-prepared.txt")]],
    Paths=lists:append([filelib:wildcard(P)||P<-[Final++"/*.term",Final++"/*.txt",
        "_build/performance-memory-*/*.term","_build/performance-memory-*/*.txt","_build/phase21-closeout-memory-*/*.term",
        "_build/phase21-baseline/*","_build/phase21-closeout-fixed/*.txt","_build/phase21-closeout-startup/*.term"]]),
    Evidence=#{startup_after_preflight_fix=>#{environment=>compact_env(read("_build/phase21-closeout-startup","environment")),
        rows=>compact_rows(rows("_build/phase21-closeout-startup","startup",12))},schema=>1,provenance=>retrospective_source_and_beam_audit,
        note=><<"Source/BEAM hashes captured at closeout, not at original measurement time. Original completion is also supported by session exit records. Profiling is separate from throughput. Full raw terms were decoded; canonical campaign checks compared before compacting.">>,
        environment=>compact_env(Env),current_sources_sha256=>Sources,current_beams=>Core,
        raw_artifacts_sha256=>[{P,file_hash(P)}||P<-Paths,filelib:is_regular(P),filename:basename(P)=/="artifact-audit.txt"],
        candidates=>[{F,read(Final,atom_to_list(F)++"-candidates")}||F<-[loop,parser,sparse]],
        hooks=>compact_rows(Hooks),executor=>compact_rows(Executors),campaign=>compact_rows(Campaigns),
        campaign_exact_comparisons=>Checks,memory=>Memory,memory_after_preflight_fix=>MemoryAfter,profiles=>Profiles,
        previous_loop_benchmark=>read("_build/phase21-baseline","coverage-benchmark"),
        example_before_preflight_fix=>Report,example=>read("_build/phase21-closeout-fixed","automatic-example"),
        termination_results=>[{K,read("_build","phase2-"++K)}||K<-["error","throw","exit","kill","timeout"]],
        regression_logs=>[{P,begin {ok,B}=file:read_file(P),B end}||P<-filelib:wildcard("_build/phase21-closeout-fixed/*.txt"),not lists:member(filename:basename(P),["automatic-example.txt","artifact-audit.txt"])],
        deterministic_acceptance=>read("_build","phase2-acceptance")},
    ok=filelib:ensure_dir(Destination),
    ok=file:write_file(Destination,unicode:characters_to_binary(io_lib:format("~tp.~n",[archive_term(Evidence)]))),
    io:format("Audited 36 hook, 12 executor, 24 campaign rows, 5 samples each; all six exact campaign comparisons agree.~n"),
    io:format("Verified 8 memory groups, fixture source/build identities, ~B current BEAMs, completed example and 4 complete profiles.~n",[length(Core)]),
    lists:foreach(fun(R)->show(R) end,Executors++Campaigns),
    io:format("Environment: ~tp~nCampaign checks: ~tp~n",[compact_env(Env),Checks]),
    lists:foreach(fun(#{variant:=V,measurement:=M})->
        Compact=maps:map(fun(_,X) when is_map(X)->maps:remove(proc_status,X);(_,X)->X end,M),
        io:format("Memory ~p: ~tp~n",[V,Compact]) end,Memory);
main(_)->error("usage: escript bench/archive.escript FINAL_DIR EVIDENCE.term").
read(D,N)->{ok,B}=file:read_file(filename:join(D,N++".term")),binary_to_term(B).
rows(D,N,Count)->
    Rs=read(D,N),Count=length(Rs),
    lists:foreach(fun(#{samples:=Ss,raw_us:=Raw,median_us:=Median,min_us:=Min,max_us:=Max})->
        5=length(Ss),Raw=[maps:get(us,S)||S<-Ss],Sorted=lists:sort(Raw),
        Median=lists:nth(3,Sorted),Min=hd(Sorted),Max=lists:last(Sorted)
    end,Rs),Rs.
compact_rows(Rs)->[R#{samples=>[compact_sample(S)||S<-maps:get(samples,R)]}||R<-Rs].
compact_sample(#{check:=C}=S)->(maps:remove(check,S))#{check_sha256=>hash(term_to_binary(C))};
compact_sample(S)->S.
compact_env(E)->
    Cpu=maps:get(cpuinfo,E),
    [Model|_]=[L||L<-binary:split(Cpu,<<"\n">>,[global]),binary:match(L,<<"model name">>)=:={0,10}],
    (maps:remove(cpuinfo,E))#{cpu_model=>Model,cpuinfo_sha256=>hash(Cpu)}.
fixture_ids(E)->[{maps:get(name,F),maps:get(build_id,maps:get(artifact,F))}||F<-maps:get(fixtures,E)].
verify_saved_fixture(F)->
    SourceHash=maps:get(source_sha256,F),SourceHash=file_hash(maps:get(source,F)),
    A=maps:get(artifact,F),Build=maps:get(build_id,A),
    {ok,#{build_id:=Build}=Manifest}=efz_cov_manifest:from_beam(maps:get(beam,A)),
    {ok,Sidecar}=file:read_file(maps:get(manifest,A)),Manifest=binary_to_term(Sidecar),ok.
verify_fixture(F)->
    verify_saved_fixture(F),M=maps:get(module,F),
    {ok,A}=efz_instrument:compile(maps:get(source,F),#{modules=>[M],source_root=>".",
        outdir=>"_build/phase21-closeout/identity-audit"}),
    Build=maps:get(build_id,maps:get(artifact,F)),Build=maps:get(build_id,A),ok.
verify_beam(Path)->
    {ok,{M,[{compile_info,Info},{abstract_code,Abstract}]}}=beam_lib:chunks(Path,[compile_info,abstract_code]),
    Source=proplists:get_value(source,Info),Opts=proplists:get_value(options,Info),
    {ok,M,Beam}=compile:noenv_file(Source,[binary|Opts]),
    {ok,{M,[{abstract_code,Abstract}]}}=beam_lib:chunks(Beam,[abstract_code]),
    {ok,{M,CodeMd5}}=beam_lib:md5(Path),{ok,{M,CodeMd5}}=beam_lib:md5(Beam),
    #{beam=>Path,sha256=>file_hash(Path),code_md5=>binary:encode_hex(CodeMd5,lowercase),
      source=>Source,source_sha256=>file_hash(Source),compiler=>Info}.
file_hash(P)->{ok,B}=file:read_file(P),hash(B).
hash(B)->binary:encode_hex(crypto:hash(sha256,B),lowercase).
show(R)->
    N=maps:get(executions,R),Ss=maps:get(samples,R),
    Extra=[{K,[maps:get(K,S)||S<-Ss]}||K<-[startup_us,calibration_us,api_start_us,cleanup_us],maps:is_key(K,hd(Ss))],
    io:format("~p ~p ~p N=~B median=~.4f range=~.4f..~.4f us/op; startup ~w~n",
        [maps:get(fixture,R),maps:get(mode,R,executor),maps:get(variant,R),N,
         maps:get(median_us,R)/N,maps:get(min_us,R)/N,maps:get(max_us,R)/N,Extra]).

archive_term(T) when is_reference(T)->runtime_reference_omitted;
archive_term(T) when is_pid(T)->runtime_pid_omitted;
archive_term(T) when is_map(T)->maps:from_list([{archive_term(K),archive_term(V)}||{K,V}<-maps:to_list(T)]);
archive_term(T) when is_tuple(T)->list_to_tuple([archive_term(V)||V<-tuple_to_list(T)]);
archive_term(T) when is_list(T)->[archive_term(V)||V<-T];
archive_term(T)->T.

variants()->[reference,member,prepared,prepared_member].
memory_group(Prefix,V,Env)->
    D=Prefix++atom_to_list(V),E=read(D,"environment"),
    lists:foreach(fun verify_saved_fixture/1,maps:get(fixtures,E)),
    true=fixture_ids(E)=:=fixture_ids(Env),
    [#{variant:=V}=M]=read(D,"memory"),
    Base=maps:with([coverage_tables,plan_tables,process_count],maps:get(before,M)),
    lists:foreach(fun(K)->Base=maps:with([coverage_tables,plan_tables,process_count],maps:get(K,M)) end,
        [after_cleanup,after_campaign_cleanup]),
    #{variant=>V,environment=>compact_env(E),measurement=>M,raw_sha256=>file_hash(filename:join(D,"memory.term"))}.
