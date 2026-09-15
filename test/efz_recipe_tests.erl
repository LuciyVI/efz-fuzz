-module(efz_recipe_tests).
-include_lib("eunit/include/eunit.hrl").

config()->{ok,C}=efz_mutation_plan:prepare(#{seed=>{1,2,3},max_input_bytes=>64},[<<>>]),C.
recipe(B,Ops)->C=config(),{ok,Out}=efz_mutation:apply_operations(B,Ops,C),
    P=#{primary=>B,primary_id=>efz_mutation:hash(B),parent=>1,stage=>havoc,operations=>Ops,
        config_id=>maps:get(config_id,C),dictionary_id=>maps:get(dictionary_id,C)},
    {efz_recipe:make(P,Out,C,#{}),Out}.
all_operations_test()->
    Cases=[{<<0,0,0,0>>,[{flip_bits,7,4}]},{<<0,0,0,0>>,[{invert_bytes,0,4}]},
        {<<0,0,0,0>>,[{add,0,32,little,-1}]},{<<0,0>>,[{set_integer,0,16,big,32768}]},
        {<<1,2>>,[{overwrite,0,<<3>>}]},{<<>>,[{insert,0,<<3>>}]},
        {<<1>>,[{delete,0,1}]},{<<1,2>>,[{duplicate,0,2,2}]},
        {<<>>,[{dictionary_insert,0,<<"TOKEN">>}]},{<<0,0>>,[{dictionary_overwrite,0,<<"AB">>}]},
        {<<1,2>>,[{splice,1,1,<<8,9>>,efz_mutation:hash(<<8,9>>)}]},
        {<<>>,[{insert,0,<<1,2>>},{duplicate,0,2,1},{delete,0,1},{add,1,16,little,1},
               {dictionary_insert,3,<<"A">>},{splice,2,1,<<9,8,7>>,efz_mutation:hash(<<9,8,7>>)}]}],
    lists:foreach(fun({B,Ops})->{R,Expected}=recipe(B,Ops),{ok,Encoded}=efz_recipe:encode(R),
        {ok,Loaded}=efz_recipe:decode(Encoded),?assertEqual(R,Loaded),
        ?assertEqual({ok,Expected},efz_recipe:regenerate(Loaded)),
        ok=efz_recipe:save("_build/operation.recipe",R),?assertEqual({ok,R},efz_recipe:load("_build/operation.recipe"))
    end,Cases).
negative_test()->
    {R,_}=recipe(<<0>>,[{insert,1,<<1>>}]),
    lists:foreach(fun(K)->?assertEqual({error,incompatible_recipe},efz_recipe:regenerate(R#{K=>99})) end,
        [schema_version,engine_version,operation_version]),
    ?assertEqual({error,output_hash_mismatch},efz_recipe:regenerate(R#{output_hash=><<0:256>>})),
    ?assertEqual({error,output_size_mismatch},efz_recipe:regenerate(R#{output_size=>3})),
    lists:foreach(fun(Op)->?assertMatch({error,{recipe_operation,_}},efz_recipe:regenerate(R#{operations=>[Op]})) end,
        [{insert,100,<<1>>},{delete,-1,1},{unknown,0},
         {splice,0,0,<<3>>,<<0:256>>},{splice,0,0,missing_donor},
         {insert,0,binary:copy(<<0>>,129)}]),
    ?assertMatch({error,_},efz_recipe:regenerate(R#{primary=><<5>>})),
    ?assertMatch({error,_},efz_recipe:encode(R#{rng=>#{algorithm=>exsplus,seed=>{1,2,3},plan=>make_ref()}})),
    {ok,Encoded}=efz_recipe:encode(R),<<First,Rest/binary>>=Encoded,
    ?assertMatch({error,_},efz_recipe:decode(<<(First bxor 1),Rest/binary>>)),
    lists:foreach(fun(Payload)->?assertEqual({error,invalid_recipe_encoding},efz_recipe:decode(envelope(Payload))) end,
        [term_to_binary(R,[compressed]),term_to_binary(R#{primary=>self()}),
         term_to_binary(R#{primary=>fun()->ok end}),term_to_binary(R#{primary=>make_ref()}),
         <<131,108,16#ffffffff:32,106>>,<<131,70,0:64>>]),
    ?assertEqual({error,invalid_recipe_encoding},efz_recipe:decode(<<Encoded/binary,0>>)).
envelope(P)-><<"EFZR",1,(byte_size(P)):32,(efz_mutation:hash(P))/binary,P/binary>>.
fresh_vm_test()->
    {R,Expected}=recipe(<<0,1>>,[{dictionary_insert,1,<<"AB">>},{delete,0,1},
        {splice,2,1,<<3,4,5>>,efz_mutation:hash(<<3,4,5>>)}]),
    Path="_build/fresh-vm.recipe",Out="_build/fresh-vm.input",ok=efz_recipe:save(Path,R),
    Port=open_port({spawn_executable,os:find_executable("escript")},[binary,exit_status,stderr_to_stdout,
        {env,[{"ERL_FLAGS","+S 2:2"}]},{args,["scripts/replay.escript",Path,Out]}]),
    {Status,Text}=port_result(Port,<<>>),?assertEqual({0,false},{Status,binary:match(Text,<<"exception">>)=/=nomatch}),
    ?assertEqual({ok,Expected},file:read_file(Out)).
fresh_vm_limit_test()->
    B=binary:copy(<<0>>,4097),
    {ok,C}=efz_mutation_plan:prepare(#{seed=>{1,2,3},max_input_bytes=>8192,stages=>[bitflip]},[B]),
    {candidate,Out,P,_}=efz_mutation_plan:next(efz_mutation_plan:new(C),[#{id=>1,input=>B}]),
    R=efz_recipe:make(P,Out,C,#{}),
    Base="_build/replay-limit-"++binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8))),
    Recipe=Base++".recipe",Input=Base++".input",ok=efz_recipe:save(Recipe,R),
    try
        lists:foreach(fun({Args,ExpectedCode})->
            Port=open_port({spawn_executable,os:find_executable("escript")},[binary,exit_status,stderr_to_stdout,
                {env,[{"ERL_FLAGS","+S 2:2"}]},{args,["scripts/replay.escript",Recipe,Input|Args]}]),
            {Code,Text}=port_result(Port,<<>>),?assertEqual(ExpectedCode,Code),
            case Code of
                1 -> ?assertNot(filelib:is_regular(Input)),
                     ?assertNotEqual(nomatch,binary:match(Text,<<"input_too_large">>));
                0 -> ?assertEqual({ok,Out},file:read_file(Input))
            end
        end,[{[],1},{["--max-input-bytes","8192"],0}])
    after _=file:delete(Recipe),_=file:delete(Input) end.
port_result(Port,Acc)->receive
    {Port,{data,B}}->port_result(Port,<<Acc/binary,B/binary>>);
    {Port,{exit_status,N}}->{N,Acc}
    after 3000->port_close(Port),error(replay_vm_timeout)
    end.
