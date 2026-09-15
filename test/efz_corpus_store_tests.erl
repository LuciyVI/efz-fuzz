-module(efz_corpus_store_tests).
-include_lib("eunit/include/eunit.hrl").

with_store(F) ->
    Dir = filename:absname("_build/store-test-" ++ hex(crypto:strong_rand_bytes(8))),
    I = #{target=><<"durable_fixture">>,callback=>{<<"run">>,1},target_md5=><<0:128>>,
          coverage=>automatic,builds=>[{<<"durable_fixture">>,<<1:256>>}]},
    S = #{dir=>Dir,identity=>I,build_policy=>reject},
    try F(S) after _=file:del_dir_r(Dir) end.
hex(B)->binary_to_list(binary:encode_hex(B,lowercase)).
entry(S,B)->filename:join(maps:get(dir,S),hex(crypto:hash(sha256,B))).
restore(S)->efz_corpus_store:restore(maps:get(dir,S),maps:get(identity,S),maps:get(build_policy,S)).
initial(S,B)->{ok,R}=efz_corpus_store:save(S,B,1,#{}),R.
alter_metadata(S,B,F)->
    P=filename:join(entry(S,B),"metadata"),{ok,Encoded}=file:read_file(P),
    <<"EFZC",1,_:32,_:32/binary,Payload/binary>>=Encoded,
    New=term_to_binary(F(binary_to_term(Payload))),
    ok=file:write_file(P,<<"EFZC",1,(byte_size(New)):32,(crypto:hash(sha256,New))/binary,New/binary>>).

roundtrip_test()->with_store(fun(S)->
    Empty=initial(S,<<>>),
    {ok,C}=efz_mutation_plan:prepare(#{seed=>{1,2,3},stages=>[dictionary_insert],dictionary=>[<<"A">>]},[<<>>]),
    {candidate,<<"A">>,P,_}=efz_mutation_plan:next(efz_mutation_plan:new(C),[#{id=>1,input=><<>>}]),
    Recipe=efz_recipe:make(P,<<"A">>,C,#{durable_fixture=><<1:256>>}),
    Meta=#{parent=>1,parent_content=>crypto:hash(sha256,<<>>),retention_reason=>new_coverage,
           new_probes=>[{durable_fixture,<<1:256>>,2}],mutation=>Recipe},
    {ok,R}=efz_corpus_store:save(S,<<"A">>,2,Meta),
    {ok,Rows,[]}=restore(S),
    ?assertEqual([<<"A">>,<<>>],[maps:get(input,E)||E<-Rows]),
    ?assertEqual([R,Empty],[maps:get(record,E)||E<-Rows]),
    ?assertEqual({ok,<<"A">>},file:read_file(filename:join(entry(S,<<"A">>),"input"))),
    ?assertEqual(#{content_hash=>crypto:hash(sha256,<<>>),queue_id=>1},maps:get(parent,R)),
    {ok,Decoded}=efz_recipe:decode(maps:get(recipe,R)),?assertEqual(Recipe,Decoded)
end).
duplicate_test()->with_store(fun(S)->
    R=initial(S,<<0,255,10>>),
    ?assertEqual({ok,R},efz_corpus_store:save(S,<<0,255,10>>,99,#{})),
    {ok,[_],[]}=restore(S),{ok,Names}=file:list_dir(maps:get(dir,S)),?assertEqual(1,length(Names))
end).
corrupt_metadata_test()->with_store(fun(S)->
    _=initial(S,<<1>>),P=filename:join(entry(S,<<1>>),"metadata"),
    {ok,B}=file:read_file(P),N=byte_size(B)-1,<<Head:N/binary,Last>>=B,
    ok=file:write_file(P,<<Head/binary,(Last bxor 1)>>),
    ?assertMatch({error,{corpus_metadata_checksum,_}},restore(S)),
    %% Saving a duplicate must not overwrite evidence of a corrupt entry.
    ?assertMatch({error,{corpus_metadata_checksum,_}},efz_corpus_store:save(S,<<1>>,2,#{}))
end).
metadata_shape_test()->with_store(fun(S)->
    _=initial(S,<<1>>),alter_metadata(S,<<1>>,fun(R)->maps:remove(content_hash,R) end),
    ?assertMatch({error,{invalid_corpus_metadata,_,invalid_metadata_shape}},restore(S))
end).
missing_input_test()->with_store(fun(S)->
    _=initial(S,<<1>>),ok=file:delete(filename:join(entry(S,<<1>>),"input")),
    ?assertMatch({error,{{corpus_file,_},enoent}},restore(S))
end).
missing_metadata_test()->with_store(fun(S)->
    _=initial(S,<<1>>),ok=file:delete(filename:join(entry(S,<<1>>),"metadata")),
    ?assertMatch({error,{{corpus_file,_},enoent}},restore(S))
end).
input_hash_test()->with_store(fun(S)->
    _=initial(S,<<1>>),ok=file:write_file(filename:join(entry(S,<<1>>),"input"),<<2>>),
    ?assertMatch({error,{invalid_corpus_metadata,_,corpus_input_hash_mismatch}},restore(S))
end).
content_name_test()->with_store(fun(S)->
    _=initial(S,<<1>>),ok=file:rename(entry(S,<<1>>),entry(S,<<2>>)),
    ?assertMatch({error,{corpus_content_name_mismatch,_}},restore(S))
end).
truncated_input_test()->with_store(fun(S)->
    _=initial(S,<<1,2>>),ok=file:write_file(filename:join(entry(S,<<1,2>>),"input"),<<1>>),
    ?assertMatch({error,{invalid_corpus_metadata,_,corpus_input_size_mismatch}},restore(S))
end).
truncated_metadata_test()->with_store(fun(S)->
    _=initial(S,<<1>>),P=filename:join(entry(S,<<1>>),"metadata"),
    {ok,B}=file:read_file(P),ok=file:write_file(P,binary:part(B,0,byte_size(B)-1)),
    ?assertMatch({error,{truncated_or_invalid_corpus_metadata,_}},restore(S))
end).
schema_test()->with_store(fun(S)->
    _=initial(S,<<1>>),alter_metadata(S,<<1>>,fun(R)->R#{schema_version=>2} end),
    ?assertMatch({error,{invalid_corpus_metadata,_,{incompatible_corpus_schema,2}}},restore(S)),
    P=filename:join(entry(S,<<1>>),"metadata"),ok=file:write_file(P,<<"EFZC",2>>),
    ?assertMatch({error,{incompatible_corpus_schema,_,2}},restore(S))
end).
build_policy_test()->with_store(fun(S)->
    _=initial(S,<<1>>),I=(maps:get(identity,S))#{builds=>[{<<"durable_fixture">>,<<2:256>>}]},
    ?assertMatch({error,{corpus_build_mismatch,_,_,_}},restore(S#{identity=>I})),
    {ok,[Row],[{corpus_build_mismatch,_,_,I}]}=restore(S#{identity=>I,build_policy=>recalibrate}),
    ?assertEqual(maps:get(identity,S),maps:get(identity,maps:get(record,Row))),
    J=I#{target=><<"another_harness">>},
    ?assertMatch({error,{corpus_build_mismatch,_,_,_}},restore(S#{identity=>J}))
end).
interrupted_write_test()->with_store(fun(S)->
    _=initial(S,<<"published">>),Dir=maps:get(dir,S),Owner=self(),
    Temp=filename:join(Dir,".tmp-interrupted-test"),
    %% Kill a real process at the durable transaction's pre-publication prefix:
    %% its raw input is fsynced, but it has not published metadata/the directory.
    {Pid,Ref}=spawn_monitor(fun()->
        ok=file:make_dir(Temp),{ok,F}=file:open(filename:join(Temp,"input"),[write,raw,binary]),
        ok=file:write(F,<<"uncommitted">>),ok=file:sync(F),ok=file:close(F),
        Owner!{staged,self()},receive continue->ok end
    end),
    receive {staged,Pid}->ok after 1000->error(no_staging_writer) end,
    exit(Pid,kill),receive {'DOWN',Ref,process,Pid,killed}->ok after 1000->error(writer_not_dead) end,
    {ok,[#{input:=<<"published">>}],[{interrupted_corpus_write,Temp}]}=restore(S),
    _=initial(S,<<"later">>),
    {ok,Rows,[_]}=restore(S),?assertEqual([<<"later">>,<<"published">>],lists:sort([maps:get(input,R)||R<-Rows]))
end).
failed_write_preserves_queue_test()->with_store(fun(S)->
    {ok,Pid}=efz_corpus:start_link([<<>>],undefined,S),
    try
        %% The already-persisted seed is intact at Backup. The configured path
        %% becomes a file, so the real store cannot publish the next discovery.
        Dir=maps:get(dir,S),Backup=Dir++"-backup",ok=file:rename(Dir,Backup),
        try
            ok=file:write_file(Dir,<<"unavailable">>),
            Meta=#{parent=>1,retention_reason=>new_coverage,new_probes=>[{durable_fixture,<<1:256>>,2}]},
            ?assertMatch({error,{corpus_persistence,_}},efz_corpus:add(<<"A">>,Meta)),
            ?assertEqual([<<>>],[maps:get(input,E)||E<-efz_corpus:all()])
        after ok=file:delete(Dir),ok=file:rename(Backup,Dir) end
    after gen_server:stop(Pid) end
end).
