#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).
%% Evidence driver around the existing CLI, without enabling the layer.
main([Build,Seeds,Out,Root])->
    true=code:add_patha(filename:join([Build,"lib","efz","ebin"])),
    Lib=filename:join([Root,"_build","default","lib","cowlib"]),
    true=code:add_patha(filename:join(Lib,"ebin")),
    Src=filename:join(Lib,"src/cow_qs.erl"),
    {ok,_}=efz_instrument:compile(Src,#{modules=>[cow_qs],outdir=>Out++"/target",
        erl_opts=>[debug_info,warnings_as_errors,{i,filename:join(Lib,"include")}]}),
    false=code:is_loaded(efz_qs_model),
    0=efz_cli:main(["--target","efz_qs_target","--seeds",Seeds,"--artifacts",Out++"/target",
        "--out",Out++"/campaign","--mutation","staged","--max-iterations","0",
        "--corpus-dir",Out++"/corpus","--timeout","1000"]),
    false=code:is_loaded(efz_qs_model),
    {ok,ReportBin}=file:read_file(Out++"/campaign/report.term"),Report=binary_to_term(ReportBin,[safe]),
    {ok,Names}=file:list_dir(Seeds),
    {ok,ManifestBin}=file:read_file(Seeds++".manifest.term"),
    #{schema_version:=2,versions:={1,1,1,1,1,1},generator:=indices,
      generator_version:=2,indices:={0,11},target:=<<"cow_qs">>,gleam:="1.10.0",
      limits:={limits,4096,32,128,1},total_bytes:=Total,max_total_bytes:=65536,seeds:=Rows}=
        binary_to_term(ManifestBin,[safe]),
    12=length(Rows),true=Total=<65536,
    lists:foreach(fun({I,Hash,Size})->
        {ok,SeedBytes}=efz_input:read_file(filename:join(Seeds,integer_to_list(I)++".qs"),4096,seed_ingestion),
        Hash=crypto:hash(sha256,SeedBytes),Size=byte_size(SeedBytes)
    end,Rows),
    Raw=[begin {ok,B}=efz_input:read_file(filename:join(Seeds,Name),4096,seed_ingestion),B end||Name<-lists:sort(Names)],
    Corpus=[maps:get(input,E)||E<-maps:get(corpus,Report)],
    Total=lists:sum([byte_size(B)||B<-Raw]),
    true=lists:sort(Raw)=:=lists:sort(Corpus),
    Stats=maps:get(stats,Report),12=maps:get(calibrations,Stats),0=maps:get(executions,Stats),
    %% Independent actual parser result, outside mutation and campaign intervals.
    Outcomes=[case efz_qs_target:run(B) of {accepted,_}->accepted;rejected->rejected end||B<-Raw],
    11=length([ok||accepted<-Outcomes]),1=length([ok||rejected<-Outcomes]),
    completed=maps:get(status,Report),[]=maps:get(crashes,Report),
    false=maps:is_key(structured_stats,Report),false=maps:is_key(gleam_stats,Report),
    %% Both campaigns have stopped. Remove the old harness code version before
    %% the CLI's ordinary cold loading step; no execution interval is active.
    code:purge(efz_qs_target),
    0=efz_cli:main(["--target","efz_qs_target","--seeds",Seeds,"--artifacts",Out++"/target",
        "--out",Out++"/ordinary-loop","--mutation","staged","--max-iterations","50","--timeout","1000"]),
    false=code:is_loaded(efz_qs_model),
    {ok,OrdinaryBin}=file:read_file(Out++"/ordinary-loop/report.term"),
    Ordinary=binary_to_term(OrdinaryBin,[safe]),completed=maps:get(status,Ordinary),
    50=maps:get(executions,maps:get(stats,Ordinary)),
    false=maps:is_key(structured_stats,Ordinary),false=maps:is_key(gleam_stats,Ordinary),
    Result=#{schema_version=>1,cli_import=>true,raw_input_identity_preserved=>true,
        calibrations=>12,mutation_executions=>0,independent_parser_probes=>12,
        subsequent_ordinary_executions=>50,
        accepted=>11,expected_rejections=>1,gleam_loaded=>false,
        generator_version=>2,manifest_hashes_verified=>true,total_bytes=>Total,
        optional_application_loaded=>lists:keymember(efz_semantic,1,application:loaded_applications()),
        corpus_hashes=>[binary:encode_hex(crypto:hash(sha256,B),lowercase)||B<-Corpus]},
    ok=file:write_file(Out++"/proof.json",json:encode(Result));
main(_)->io:format("Usage: gleam_seed_import_check.escript OFF_BUILD SEEDS OUT ROOT\n"),halt(2).
