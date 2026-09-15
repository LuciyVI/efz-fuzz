-module(efz_durable_tests).
-include_lib("eunit/include/eunit.hrl").
-export([phase/2]).

durable_test_()->{"saved successful inputs become parents in a new VM",{timeout,30,fun durable/0}}.
durable()->
    Base=filename:absname("_build/durable-e2e-"++hex(crypto:strong_rand_bytes(8))),
    ok=filelib:ensure_dir(filename:join(Base,"plain/placeholder")),
    {ok,efz_durable_harness}=compile:noenv_file("fixtures/efz_durable_harness.erl",
        [debug_info,warnings_as_errors,{outdir,filename:join(Base,"plain")}]),
    {ok,A}=efz_instrument:compile("fixtures/efz_lineage_parser.erl",
        #{modules=>[efz_lineage_parser],source_root=>".",outdir=>filename:join(Base,"instrumented")}),
    NewSource=filename:join(Base,"v2/efz_lineage_parser.erl"),ok=filelib:ensure_dir(NewSource),
    {ok,Source}=file:read_file("fixtures/efz_lineage_parser.erl"),
    ok=file:write_file(NewSource,binary:replace(Source,<<"path_a;">>,<<"path_a_v2;">>)),
    {ok,A2}=efz_instrument:compile(NewSource,#{modules=>[efz_lineage_parser],
        source_root=>Base,outdir=>filename:join(Base,"instrumented-v2")}),
    {ok,Fault}=efz_instrument:compile("examples/staged/efz_staged_parser.erl",
        #{modules=>[efz_staged_parser],source_root=>".",outdir=>filename:join(Base,"fault-target")}),
    D=#{base=>Base,artifact=>A,new_artifact=>A2,fault_artifact=>Fault},
    Descriptor=filename:join(Base,"descriptor.term"),ok=file:write_file(Descriptor,term_to_binary(D)),
    %% Each phase is a fresh OS process/BEAM. Wait for VM exit before restoring.
    fresh(first,D,Descriptor),R1=report(first,D),
    [Empty,A1]=maps:get(corpus,R1),
    ?assertEqual([<<>>,<<"A">>],[maps:get(input,E)||E<-[Empty,A1]]),
    ?assertEqual(1,maps:get(discoveries,maps:get(stats,R1))),
    Saved=maps:get(persistence,maps:get(metadata,A1)),
    ?assertEqual(discovery,maps:get(origin,Saved)),
    ?assertEqual(2,maps:get(queue_id,Saved)),
    ?assertEqual(#{content_hash=>crypto:hash(sha256,<<>>),queue_id=>1},maps:get(parent,Saved)),
    ?assertEqual({ok,<<"A">>},file:read_file(filename:join([Base,"corpus",hex(crypto:hash(sha256,<<"A">>)),"input"]))),
    {ok,OldRecipe}=efz_recipe:decode(maps:get(recipe,Saved)),
    ?assertEqual({ok,<<"A">>},efz_recipe:regenerate(OldRecipe)),
    fresh(duplicate,D,Descriptor),Dup=report(duplicate,D),
    ?assertEqual(2,length(maps:get(corpus,Dup))),?assertEqual(2,maps:get(calibrations,maps:get(stats,Dup))),
    fresh(second,D,Descriptor),R2=report(second,D),
    [RestoredA]=[E||E<-maps:get(corpus,R2),maps:get(input,E)=:=<<"A">>],
    [AB]=[E||E<-maps:get(corpus,R2),maps:get(input,E)=:=<<"AB">>],
    ?assertEqual(1,maps:get(id,RestoredA)), % Old ID was 2: integer IDs were not resumed.
    ?assertEqual(true,maps:get(restored,maps:get(metadata,RestoredA))),
    ?assertEqual(Saved,maps:get(persistence,maps:get(metadata,RestoredA))),
    ?assertEqual(2,maps:get(calibrations,maps:get(stats,R2))),
    ?assertEqual(2,maps:get(restored_inputs,maps:get(corpus_restore,R2))),
    Meta=maps:get(metadata,AB),Recipe=maps:get(mutation,Meta),
    ?assertEqual(new_coverage,maps:get(retention_reason,Meta)),
    ?assertEqual(maps:get(id,RestoredA),maps:get(parent,Meta)),
    ?assertEqual(<<"A">>,maps:get(primary,Recipe)),
    ?assertEqual(crypto:hash(sha256,<<"A">>),maps:get(primary_id,Recipe)),
    ?assertEqual([{dictionary_insert,1,<<"B">>}],maps:get(operations,Recipe)),
    ?assertEqual({ok,<<"AB">>},efz_recipe:regenerate(Recipe)),
    ?assertEqual({ok,path_ab},maps:get(outcome,Meta)),
    ?assert(lists:any(fun(P)->maps:get(parent,P)=:=maps:get(id,RestoredA)
         andalso maps:get(primary,P)=:=<<"A">> end,maps:get(mutation_trace,R2))),
    fresh(reject_build,D,Descriptor),fresh(too_small,D,Descriptor),
    fresh(recalibrate,D,Descriptor),R3=report(recalibrate,D),
    ?assertEqual(3,maps:get(calibrations,maps:get(stats,R3))),
    ?assertEqual(3,length(maps:get(diagnostics,maps:get(corpus_restore,R3)))),
    ?assert(lists:all(fun({efz_lineage_parser,Build,_})->Build=:=maps:get(build_id,A2) end,maps:get(coverage,R3))),
    fresh(faults,D,Descriptor),RF=report(faults,D),
    ?assertEqual(1,maps:get(crashes,maps:get(stats,RF))),
    ?assertEqual([<<>>],[maps:get(input,E)||E<-maps:get(corpus,RF)]),
    {ok,Names}=file:list_dir(filename:join(Base,"fault-corpus")),?assertEqual(1,length(Names)),
    %% Keep reports/logs as acceptance evidence; only generated files under _build.
    ok=file:write_file("_build/durable-e2e-latest.txt",Base++"\n"),
    ok=file:write_file(filename:join(Base,"lineage.txt"),io_lib:format(
        "VM1 empty ID=~B -> A ID=~B; VM2 restored A ID=~B -> AB ID=~B~nparent=~tp primary=~tp primary_sha256=~s~n",
        [maps:get(id,Empty),maps:get(id,A1),maps:get(id,RestoredA),maps:get(id,AB),
         maps:get(parent,Recipe),maps:get(primary,Recipe),hex(maps:get(primary_id,Recipe))])).

fresh(Phase,#{base:=Base},Descriptor)->
    Eval=lists:flatten(io_lib:format("efz_durable_tests:phase(~p,~tp),halt(0).",[Phase,Descriptor])),
    P=open_port({spawn_executable,os:find_executable("erl")},[binary,exit_status,stderr_to_stdout,
        {cd,Base},{args,["+S","2:2","-noshell","-pa",filename:dirname(code:which(efz)),
             filename:dirname(code:which(?MODULE)),filename:join(Base,"plain"),"-eval",Eval]}]),
    {Status,Text}=output(P,<<>>),ok=file:write_file(filename:join(Base,atom_to_list(Phase)++".log"),Text),
    ?assertEqual({Phase,0,<<>>},{Phase,Status,case Status of 0-><<>>;_->Text end}).
output(P,Acc)->receive
    {P,{data,B}}->output(P,<<Acc/binary,B/binary>>);
    {P,{exit_status,N}}->{N,Acc}
after 8000->port_close(P),error({durable_vm_timeout,Acc}) end.
report(P,#{base:=Base})->{ok,B}=file:read_file(filename:join(Base,atom_to_list(P)++".term")),binary_to_term(B).
hex(B)->binary_to_list(binary:encode_hex(B,lowercase)).

phase(Phase,Descriptor)->
    ?assertEqual(undefined,whereis(efz_corpus)),
    {ok,Bytes}=file:read_file(Descriptor),D=binary_to_term(Bytes),Base=maps:get(base,D),
    Mutation=#{seed=>{17,23,41},stages=>[dictionary_insert],dictionary=>[<<"B">>],trace_limit=>20},
    C0=#{target=>efz_durable_harness,artifacts=>[maps:get(artifact,D)],seeds=>[],
         corpus_dir=>filename:join(Base,"corpus"),mutation_mode=>staged,mutation=>Mutation,
         max_iterations=>3,timeout=>1000,crash_dir=>filename:join(Base,"crashes")},
    C=case Phase of
        first->C0#{seeds=>[<<>>],max_iterations=>1,mutation=>Mutation#{dictionary=>[<<"A">>]}};
        second->C0;
        duplicate->C0#{seeds=>[<<"A">>,<<"A">>,<<>>,<<"A">>],max_iterations=>0};
        reject_build->C0#{artifacts=>[maps:get(new_artifact,D)]};
        recalibrate->C0#{artifacts=>[maps:get(new_artifact,D)],corpus_build_policy=>recalibrate,max_iterations=>0};
        too_small->C0#{max_input_bytes=>0};
        faults->C0#{target=>efz_staged_parser,artifacts=>[maps:get(fault_artifact,D)],seeds=>[<<>>],
            corpus_dir=>filename:join(Base,"fault-corpus"),max_iterations=>1,
            mutation=>Mutation#{dictionary=>[<<"BOOM!">>]}}
    end,
    try case Phase of
        P when P=:=reject_build;P=:=too_small->
            Error=efz:start(C),?assertMatch({error,_},Error),
            Text=iolist_to_binary(io_lib:format("~tp",[Error])),
            Expected=case P of reject_build-><<"corpus_build_mismatch">>;too_small-><<"input_too_large">> end,
            ?assertNotEqual(nomatch,binary:match(Text,Expected)),
            ?assertEqual(undefined,whereis(efz_corpus));
        _->
            {ok,_}=efz:start(C),R=efz:await(5000),?assertEqual(completed,maps:get(status,R)),
            ?assertEqual(maps:get(corpus,R),efz_corpus:all()),
            ok=file:write_file(filename:join(Base,atom_to_list(Phase)++".term"),term_to_binary(R))
    end after _=efz:stop() end.
