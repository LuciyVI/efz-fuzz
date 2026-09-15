-module(efz_limits_tests).
-include_lib("eunit/include/eunit.hrl").
-export([mutate/2]).

%% Deliberately violates the public random mutator callback. This checks the
%% worker boundary independently of the built-in mutator's own size handling.
mutate(B,_) -> <<B/binary,0>>.

limits_test_() -> {setup,fun setup/0,fun cleanup/1,fun(S)->[
    {"campaign schema and seed boundaries",fun()->seeds(S) end},
    {"explicit campaign limit above default reaches every boundary",fun()->above_default(S) end},
    {"real random mutator honors zero and full inputs",fun()->random(S) end},
    {"staged limit and recipe are derived from campaign",fun()->staged(S) end},
    {"oversized random callback cannot reach target",fun()->oversized_random(S) end},
    {"restored inputs and active corpus obey campaign limit",fun()->restore(S) end},
    {"raw replay and recipe boundaries",fun()->replay(S) end},
    {"executor refuses oversized campaign inputs",fun()->executor(S) end},
    {"crash persistence boundaries",fun()->crash_boundaries(S) end},
    {"storage failure preserves exact input and primary reason",fun()->storage_failure(S) end},
    {"permission denied is a structured infrastructure result",fun()->permission_denied(S) end},
    {"missing parent is created and artifact group is immutable",fun()->missing_parent(S) end},
    {"failure after first file rolls back unpublished group",fun()->partial_write(S) end},
    {"partial committed group is rejected without overwriting",fun()->corrupt_group(S) end},
    {"interrupted staging never becomes a committed crash",fun()->interrupted(S) end}
] end}.
setup() ->
    Base=filename:absname("_build/limits-test-"++hex(crypto:strong_rand_bytes(8))),
    {ok,A}=efz_instrument:compile("fixtures/efz_limits_target.erl",
        #{modules=>[efz_limits_target],source_root=>".",outdir=>filename:join(Base,"instrumented")}),
    #{base=>Base,artifact=>A}.
cleanup(S)->efz:stop(),_=code:purge(efz_limits_target),_=code:delete(efz_limits_target),
    ok=file:del_dir_r(maps:get(base,S)).
path(S,N)->filename:join(maps:get(base,S),N).
hex(B)->binary_to_list(binary:encode_hex(B,lowercase)).
base(S)->#{target=>efz_limits_target,artifacts=>[maps:get(artifact,S)],seeds=>[<<>>],
    timeout=>1000,max_iterations=>0,crash_dir=>path(S,"crashes")}.
campaign(C)->{ok,_}=efz:start(C),try R=efz:await(10000), ?assert(is_process_alive(whereis(efz_fuzzer))), R after efz:stop() end.
observe(F)->true=register(efz_limits_observer,self()),
    try R=F(),{R,delivered([])} after unregister(efz_limits_observer) end.
delivered(Acc)->receive {delivered_input,B}->delivered([B|Acc]) after 0->lists:reverse(Acc) end.
seeds(S)->
    lists:foreach(fun(Mode)->
        C=(base(S))#{mutation_mode=>Mode,max_input_bytes=>3},
        {ok,Prepared}=efz_config:prepare(C#{seeds=>[<<>>,<<"ABC">>]}),
        ?assertEqual(3,maps:get(max_input_bytes,Prepared)),
        ?assertMatch({error,#{kind:=input_limit,operation:=initial_seed,input_bytes:=4,max_input_bytes:=3}},
            efz_config:prepare(C#{seeds=>[<<"ABCD">>]})),
        ?assertMatch({ok,_},efz_config:prepare(C#{seeds=>[<<>>],max_input_bytes=>0})),
        ?assertMatch({error,#{reason:=input_too_large}},efz_config:prepare(C#{seeds=>[<<0>>],max_input_bytes=>0}))
    end,[staged,random]),
    lists:foreach(fun(N)->?assertEqual({error,{invalid_campaign_option,max_input_bytes}},
        efz_config:prepare((base(S))#{max_input_bytes=>N})) end,[-1,1048577,1.0]),
    ?assertEqual({error,{campaign_level_option,max_input_bytes}},
        efz_config:prepare((base(S))#{mutation_mode=>staged,mutation=>#{max_input_bytes=>3}})).
above_default(S)->
    Input=binary:copy(<<42>>,4097), Max=4098, Dir=path(S,"large-corpus"),
    C=(base(S))#{seeds=>[Input],max_input_bytes=>Max,max_iterations=>1,corpus_dir=>Dir},
    {R,[Input,Mutated]}=observe(fun()->campaign(C) end),
    ?assertEqual(completed,maps:get(status,R)),?assert(byte_size(Mutated)=<Max),
    Restored=campaign(C#{seeds=>[],max_iterations=>0}),
    ?assert(lists:any(fun(#{input:=B})->B=:=Input end,maps:get(corpus,Restored))),
    A=maps:get(artifact,S),Bs=[{<<"efz_limits_target">>,maps:get(build_id,A)}],
    ?assertEqual({error,#{kind=>input_limit,operation=>replay,reason=>input_too_large,
        input_bytes=>4097,max_input_bytes=>4096,input_hash=>crypto:hash(sha256,Input)}},
        efz_recipe:execute(Input,efz_limits_target,[A],Bs,#{})),
    ?assertMatch({ok,#{outcome:={ok,Input}}},
        efz_recipe:execute(Input,efz_limits_target,[A],Bs,replay_options(Max))),
    {ok,Crash}=efz_crash:save(Input,crash_result(),#{},#{crash_dir=>path(S,"large-crash"),max_input_bytes=>Max}),
    ?assertEqual({ok,Input},file:read_file(maps:get(path,Crash)++".input")),
    ?assertMatch({ok,#{outcome:={ok,Input}}},efz_recipe:execute_file(maps:get(path,Crash)++".input",
        efz_limits_target,[A],Bs,replay_options(Max))),
    ?assertEqual(ok,efz_input:check(binary:copy(<<0>>,1048576),1048576,boundary)),
    ?assertMatch({error,#{reason:=input_too_large}},efz_input:check(binary:copy(<<0>>,1048577),1048576,boundary)).
replay_options(Max)->
    {ok,H}=efz_replay:harness_identity(efz_limits_target),
    #{max_input_bytes=>Max,expected_harness=>H}.

random(S)->
    lists:foreach(fun({Max,Seeds})->
        {R,Bs}=observe(fun()->campaign((base(S))#{seeds=>Seeds,max_input_bytes=>Max,
            max_iterations=>300,random_seed=>{17,23,41}}) end),
        ?assertEqual(completed,maps:get(status,R)),
        ?assertEqual(300,maps:get(executions,maps:get(stats,R))),
        ?assertEqual(300+length(Seeds),length(Bs)),
        ?assert(lists:all(fun(B)->is_binary(B) andalso byte_size(B)=<Max end,Bs)),
        ?assertEqual(Seeds,lists:sublist(Bs,length(Seeds)))
    end,[{0,[<<>>]},{3,[<<>>,<<"ABC">>]}]).
staged(S)->
    lists:foreach(fun(Max)->
        {R,Bs}=observe(fun()->campaign((base(S))#{mutation_mode=>staged,max_input_bytes=>Max,
            max_iterations=>10,mutation=>#{seed=>{1,2,3},stages=>[dictionary_insert],
            dictionary=>[<<"ABC">>,<<"ABCD">>],trace_limit=>20}}) end),
        ?assert(lists:all(fun(B)->byte_size(B)=<Max end,Bs)),
        ?assertEqual(Max,maps:get(max_input_bytes,maps:get(mutation,R))),
        lists:foreach(fun(Recipe)->
            ?assertEqual(Max,maps:get(max_input_bytes,maps:get(limits,Recipe))),
            {ok,B}=efz_recipe:regenerate(Recipe,#{max_input_bytes=>Max}),
            ?assert(lists:member(B,Bs))
        end,maps:get(mutation_trace,R)),
        case Max of 0->?assertEqual([<<>>],Bs);3->?assert(lists:member(<<"ABC">>,Bs)) end
    end,[0,3]).
oversized_random(S)->
    {R,Bs}=observe(fun()->campaign((base(S))#{seeds=>[<<"ABC">>],max_input_bytes=>3,
        max_iterations=>1,mutator=>?MODULE}) end),
    ?assertEqual([<<"ABC">>],Bs),
    ?assertMatch({infrastructure_failure,#{kind:=input_limit,input_bytes:=4}},maps:get(status,R)),
    ?assertEqual(0,maps:get(executions,maps:get(stats,R))),
    ?assertEqual(1,maps:get(infrastructure_failures,maps:get(stats,R))),
    ?assertEqual(<<"ABC",0>>,maps:get(input,maps:get(failure_context,R))).
restore(S)->
    C=(base(S))#{seeds=>[<<>>,<<"ABC">>],max_input_bytes=>3,corpus_dir=>path(S,"corpus")},
    _=campaign(C),
    lists:foreach(fun(Mode)->
        R=campaign(C#{seeds=>[],mutation_mode=>Mode}),
        ?assertEqual(2,maps:get(calibrations,maps:get(stats,R))),
        ?assertEqual([<<>>,<<"ABC">>],lists:sort([maps:get(input,E)||E<-maps:get(corpus,R)])),
        ?assertMatch({error,{corpus_restore,#{reason:=input_too_large,max_input_bytes:=2}}},
            efz_config:prepare(C#{seeds=>[],mutation_mode=>Mode,max_input_bytes=>2}))
    end,[random,staged]),
    {ok,P}=efz_corpus:start_link([<<>>],undefined,undefined,3),
    try
        ?assertMatch({ok,2},efz_corpus:add(<<"ABC">>,#{})),
        ?assertMatch({error,#{reason:=input_too_large}},efz_corpus:add(<<"ABCD">>,#{})),
        ?assertEqual(2,efz_corpus:size())
    after gen_server:stop(P) end.
replay(S)->
    A=maps:get(artifact,S),Bs=[{<<"efz_limits_target">>,maps:get(build_id,A)}],
    lists:foreach(fun({Max,B})->
        {ok,#{outcome:={ok,B}}}=efz_recipe:execute(B,efz_limits_target,[A],Bs,replay_options(Max)),
        P=path(S,"replay.input"),ok=file:write_file(P,B),
        ?assertMatch({ok,#{outcome:={ok,B}}},efz_recipe:execute_file(P,efz_limits_target,[A],Bs,replay_options(Max))),
        TooBig = <<B/binary,0>>,
        ?assertMatch({error,#{reason:=input_too_large}},efz_recipe:execute(TooBig,efz_limits_target,[A],Bs,replay_options(Max))),
        ok=file:write_file(P,TooBig),
        ?assertMatch({error,#{reason:=input_too_large}},efz_recipe:execute_file(P,efz_limits_target,[A],Bs,replay_options(Max)))
    end,[{0,<<>>},{3,<<"ABC">>}]),
    {ok,C}=efz_mutation_plan:prepare(#{seed=>{1,2,3},max_input_bytes=>4,stages=>[dictionary_insert],dictionary=>[<<"ABCD">>]},[<<>>]),
    {candidate,Out,P,_}=efz_mutation_plan:next(efz_mutation_plan:new(C),[#{id=>1,input=><<>>}]),
    Recipe=efz_recipe:make(P,Out,C,#{}),
    ?assertEqual({ok,<<"ABCD">>},efz_recipe:regenerate(Recipe,#{max_input_bytes=>4})),
    ?assertMatch({error,#{reason:=input_too_large}},efz_recipe:regenerate(Recipe,#{max_input_bytes=>3})),
    CrashDir=path(S,"invalid-recipe-crash"),
    ?assertMatch({error,#{reason:=#{kind:=input_limit},input_hash:=_,crash_fingerprint:=_}},
        efz_crash:save(<<>>,crash_result(),#{mutation=>Recipe},#{crash_dir=>CrashDir,max_input_bytes=>3})),
    ?assertMatch({error,#{reason:=crash_recipe_input_mismatch}},
        efz_crash:save(<<>>,crash_result(),#{mutation=>Recipe},#{crash_dir=>CrashDir,max_input_bytes=>4})),
    ?assert(filelib:is_dir(CrashDir)),
    RawFiles=filelib:wildcard(CrashDir++"/*/*/artifact.input"),
    ?assertEqual(1,length(RawFiles)),
    lists:foreach(fun(RawPath)->?assertEqual({ok,<<>>},file:read_file(RawPath)) end,RawFiles).
executor(_S)->
    {R,Bs}=observe(fun()->efz_executor:run(efz_limits_target,<<0>>,1000,#{coverage=>manual,max_input_bytes=>0}) end),
    ?assertEqual([],Bs),?assertMatch({infrastructure,#{reason:=input_too_large}},maps:get(outcome,R)).
crash_result()->#{outcome=>{crash,error,test_crash,[]}}.
crash_boundaries(S)->
    lists:foreach(fun({Max,B})->
        Opts=#{crash_dir=>path(S,"boundary-crashes"),max_input_bytes=>Max},
        {ok,C}=efz_crash:save(B,crash_result(),#{},Opts),
        ?assertEqual({ok,B},file:read_file(maps:get(path,C)++".input")),
        ?assertMatch({error,#{kind:=input_limit,crash_fingerprint:=_,input_hash:=_}},
            efz_crash:save(<<B/binary,0>>,crash_result(),#{},Opts))
    end,[{0,<<>>},{3,<<"ABC">>}]).
failed_campaign(S,Dir,Errno)->
    {R,Inputs}=observe(fun()->campaign((base(S))#{mutation_mode=>staged,max_iterations=>1,
        max_input_bytes=>5,crash_dir=>Dir,mutation=>#{stages=>[dictionary_insert],dictionary=>[<<"CRASH">>]}}) end),
    ?assertEqual([<<>>,<<"CRASH">>],Inputs),
    {infrastructure_failure,E}=maps:get(status,R),
    ?assertMatch(#{kind:=filesystem,operation:=_,path:=_,reason:=Errno,crash_fingerprint:=_,input_hash:=_},E),
    ?assertEqual(crypto:hash(sha256,<<"CRASH">>),maps:get(input_hash,E)),
    St=maps:get(stats,R),?assertEqual(1,maps:get(infrastructure_failures,St)),
    ?assertEqual(1,maps:get(crashes,St)),?assertEqual(1,maps:get(unique_crashes,St)),
    ?assertEqual(1,maps:get(executions,St)),
    Ctx=maps:get(failure_context,R),?assertEqual(<<"CRASH">>,maps:get(input,Ctx)),
    ?assertEqual(E,maps:get(storage_error,Ctx)),
    ?assertEqual({ok,<<"CRASH">>},efz_recipe:regenerate(maps:get(recipe,Ctx))),
    [Crash]=maps:get(crashes,R),?assertEqual({error,E},maps:get(storage,Crash)),
    ?assertMatch({crash,error,{limits_test_crash,<<"CRASH">>},[_|_]},maps:get(outcome,maps:get(result,Crash))),
    R.
storage_failure(S)->
    %% A regular-file ancestor is the portable equivalent of /dev/null/invalid-dir.
    Block=path(S,"not-a-directory"),ok=file:write_file(Block,<<"preserve">>),
    R=failed_campaign(S,filename:join(Block,"invalid-dir"),enotdir),
    ?assertEqual({ok,<<"preserve">>},file:read_file(Block)),
    ok=file:write_file("_build/limits-storage-failure.term",term_to_binary(R)).
permission_denied(S)->
    Dir=path(S,"denied"),ok=file:make_dir(Dir),ok=file:change_mode(Dir,8#500),
    try _=failed_campaign(S,Dir,eacces) after ok=file:change_mode(Dir,8#700) end.
missing_parent(S)->
    Dir=path(S,"new/parents/crashes"),
    {ok,C}=efz_crash:save(<<0>>,crash_result(),#{},Dir),
    {ok,Before}=file:read_file(maps:get(path,C)++".term"),
    {ok,C2}=efz_crash:save(<<0>>,crash_result(),#{second=>true},Dir),
    ?assertEqual(maps:get(path,C),maps:get(path,C2)),
    ?assertNotEqual(maps:get(occurrence_id,C),maps:get(occurrence_id,C2)),
    ?assertEqual(duplicate,maps:get(storage,C2)),
    ?assertEqual(2,maps:get(durable_occurrences,C2)),
    ?assertEqual(maps:get(group_id,C),maps:get(group_id,C2)),
    ?assertEqual({ok,Before},file:read_file(maps:get(path,C)++".term")),
    {ok,Names}=file:list_dir(Dir),?assertEqual(1,length(Names)).
partial_write(S)->
    Dir=path(S,"partial"),
    %% Real IO fails on the second file, after input has been written/fsynced.
    {error,E}=efz_fs:atomic_group(Dir,"group",[{"artifact.input",<<0>>},{"missing-parent/artifact.term",<<1>>}]),
    ?assertMatch(#{operation:=open,reason:=enoent,staging_path:=_},E),
    ?assertEqual({ok,[]},file:list_dir(Dir)),
    ?assertNot(filelib:is_dir(filename:join(Dir,"group"))).
corrupt_group(S)->
    Dir=path(S,"corrupt"),{ok,C}=efz_crash:save(<<0>>,crash_result(),#{},Dir),
    Path=maps:get(path,C)++".term",ok=file:write_file(Path,<<"truncated">>),
    {error,E}=efz_fs:validate_group(filename:dirname(maps:get(path,C))),
    ?assertMatch(#{operation:=validate_group,reason:=artifact_checksum_mismatch},E),
    ?assertEqual({ok,<<"truncated">>},file:read_file(Path)),
    ?assertEqual([],filelib:wildcard(filename:join(Dir,".tmp-*"))).
interrupted(S)->
    Dir=path(S,"interrupted"),Temp=filename:join(Dir,".tmp-killed-writer"),
    Parent=self(),{Pid,Ref}=spawn_monitor(fun()->
        ok=filelib:ensure_dir(filename:join(Temp,"artifact.input")),
        {ok,F}=file:open(filename:join(Temp,"artifact.input"),[write,raw,binary]),
        ok=file:write(F,<<"partial">>),ok=file:sync(F),ok=file:close(F),
        Parent!{staged,self()},receive continue->ok end
    end),
    receive {staged,Pid}->ok after 1000->error(writer_timeout) end,
    exit(Pid,kill),receive {'DOWN',Ref,process,Pid,killed}->ok end,
    ?assertEqual([],filelib:wildcard(filename:join(Dir,"*/manifest"))),
    {ok,C}=efz_crash:save(<<0>>,crash_result(),#{},Dir),
    ?assertEqual({ok,<<0>>},file:read_file(maps:get(path,C)++".input")),
    ?assertEqual({ok,<<"partial">>},file:read_file(filename:join(Temp,"artifact.input"))).
