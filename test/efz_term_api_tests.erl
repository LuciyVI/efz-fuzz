-module(efz_term_api_tests).
-include_lib("eunit/include/eunit.hrl").

portable_nested_terms_test() ->
    S=[#{kind=>tuple,items=>[
        #{kind=>integer},#{kind=>float},#{kind=>boolean},#{kind=>binary},
        #{kind=>charlist},#{kind=>atom,values=>[known]},
        #{kind=>map,key=>#{kind=>integer},value=>#{kind=>list,item=>#{kind=>integer}}}]}],
    Args=[{42,1.25,true,<<0,255>>,[65,16#20ac],known,#{2=>[1,2],1=>[]}}],
    {ok,Raw}=efz_term_codec:encode(Args,S,#{}),
    ?assertEqual({ok,Args},efz_term_codec:decode(Raw,S,#{})),
    ?assertEqual({ok,Raw},efz_term_codec:encode(Args,S,#{})),
    ?assertMatch({skip,_},efz_term_codec:decode(<<Raw/binary,0>>,S,#{})),
    ?assertMatch({skip,_},efz_term_codec:decode(Raw,S,#{depth=>2})),
    ?assertMatch({skip,_},efz_term_codec:decode(Raw,S,#{nodes=>3})),
    ?assertMatch({skip,_},efz_term_codec:decode(Raw,S,#{bytes=>8})).

portable_boundary_test() ->
    S=[#{kind=>term,atoms=>[existing]}],
    ?assertMatch({skip,_},efz_term_codec:encode([other],S,#{})),
    ?assertMatch({skip,_},efz_term_codec:encode([self()],S,#{})),
    ?assertMatch({skip,_},efz_term_codec:encode([make_ref()],S,#{})),
    ?assertMatch({skip,_},efz_term_codec:encode([fun()->ok end],S,#{})),
    ?assertMatch({skip,_},efz_term_codec:decode(<<"EFZT",1,1:16,8,65535:16>>,S,#{})),
    ?assertMatch({skip,_},efz_term_codec:decode(<<"EFZT",1,1:16,5,65535:16>>,S,#{})),
    ?assertMatch({error,_},efz_term_codec:validate_specs([#{kind=>atom,values=>[]}],#{})),
    ?assertMatch({error,_},efz_term_codec:validate_specs([#{kind=>integer,min=>4,max=>1}],#{})),
    ?assertMatch({error,_},efz_term_codec:validate_specs([#{kind=>pid}],#{})).

portable_standalone_bounds_test() ->
    %% A public codec caller cannot override packet bounds with invalid specs,
    %% even when it did not run campaign cold validation first.
    TooMany=lists:duplicate(33,1),Specs=lists:duplicate(33,#{kind=>integer}),
    ?assertMatch({skip,_},efz_term_codec:encode(TooMany,Specs,#{})),
    Wide=#{kind=>integer,min=>-(1 bsl 64),max=>(1 bsl 64)},
    ?assertMatch({skip,_},efz_term_codec:encode([1 bsl 63],[Wide],#{})),
    ?assertMatch({skip,_},efz_term_codec:encode([-(1 bsl 63)-1],[Wide],#{})),
    Boundary=[-(1 bsl 63),(1 bsl 63)-1],
    Signed=#{kind=>integer,min=>-(1 bsl 63),max=>(1 bsl 63)-1},
    {ok,Raw}=efz_term_codec:encode(Boundary,[Signed,Signed],#{}),
    ?assertEqual({ok,Boundary},efz_term_codec:decode(Raw,[Signed,Signed],#{})),
    ?assertMatch({skip,_},efz_term_codec:encode([<<"abc">>],
        [#{kind=>binary,max_length=>64}],#{collection=>2})),
    ?assertMatch({skip,_},efz_term_codec:encode([[1,2,3]],
        [#{kind=>list,max_length=>64,item=>#{kind=>integer}}],#{collection=>2})).

bounded_dynamic_tree_test() ->
    S=[#{kind=>term,atoms=>[allowed]}],
    Args=[#{allowed=>{[true,1,2.0,<<"bytes">>],#{3=>[]}}}],
    {ok,Raw}=efz_term_codec:encode(Args,S,#{}),
    ?assertEqual({ok,Args},efz_term_codec:decode(Raw,S,#{})),
    ?assertMatch({skip,_},efz_term_codec:encode([{{{{{{{{{1}}}}}}}}}],S,#{})),
    Char=[#{kind=>charlist}],
    ?assertMatch({skip,_},efz_term_codec:encode([[1]],Char,#{depth=>1})),
    ?assertEqual({ok,[]},efz_term_codec:decode(<<"EFZT",1,0:16>>,[],#{})),
    %% An adversarial configured minimum cannot allocate past the node budget.
    Huge=[#{kind=>list,min_length=>32,item=>#{kind=>list,min_length=>32,item=>#{kind=>integer}}}],
    ?assertEqual({skip,limit},efz_term_api_adapter:seed(0,#{arguments=>Huge},#{nodes=>8})).

dynamic_tuple_collection_boundary_test() ->
    Specs=[#{kind=>term}],Limits=#{collection=>3},
    AtBoundary=[{1,2,3}],
    {ok,Raw}=efz_term_codec:encode(AtBoundary,Specs,Limits),
    ?assertEqual({ok,AtBoundary},efz_term_codec:decode(Raw,Specs,Limits)),
    ?assertMatch({skip,_},efz_term_codec:encode([{1,2,3,4}],Specs,Limits)),
    %% A packet permitted by a wider collection limit cannot bypass a smaller
    %% limit when decoding, including nested dynamic tuples.
    {ok,Wider}=efz_term_codec:encode([{1,2,3,4}],Specs,#{collection=>4}),
    ?assertMatch({skip,_},efz_term_codec:decode(Wider,Specs,Limits)),
    ?assertMatch({skip,_},efz_term_codec:encode([#{1=>{1,2,3,4}}],Specs,Limits)),
    Maximum=#{collection=>256,nodes=>512},
    Largest=[list_to_tuple(lists:seq(1,256))],
    {ok,MaxRaw}=efz_term_codec:encode(Largest,Specs,Maximum),
    ?assertEqual({ok,Largest},efz_term_codec:decode(MaxRaw,Specs,Maximum)),
    ?assertMatch({skip,_},efz_term_codec:encode([list_to_tuple(lists:seq(1,257))],Specs,Maximum)).

generic_real_api_test() ->
    Rev=efz_term_reverse_target:options(),
    {ok,R}=efz_term_codec:encode([[1,2,3]],maps:get(arguments,Rev),#{}),
    ?assertEqual([3,2,1],efz_term_reverse_target:run(R)),
    ?assertEqual([3,2,1],efz_term_api_adapter:execute(R,Rev)),
    Maps=efz_term_maps_target:options(),
    {ok,M}=efz_term_codec:encode([present,#{present=>{7,<<"v">>}}],maps:get(arguments,Maps),#{}),
    ?assertEqual({ok,{7,<<"v">>}},efz_term_maps_target:run(M)),
    Tuple=efz_term_tuple_target:options(),
    {ok,T}=efz_term_codec:encode([#{a=>9},{a,4}],maps:get(arguments,Tuple),#{}),
    ?assertEqual({9,1,{a,4}},efz_term_tuple_target:run(T)),
    ?assertMatch({efz_term_input_rejected,_},efz_term_reverse_target:run(<<"not a term packet">>)),
    case code:which(efz_term_model) of
        non_existing->?assertMatch({error,{term_api_model_unavailable,_}},
            efz_term_api_adapter:prepare(efz_term_reverse_target,Rev,#{}));
        _->?assertMatch({ok,_},efz_term_api_adapter:prepare(efz_term_reverse_target,Rev,#{}))
    end,
    ?assertMatch({error,_},efz_term_api_adapter:prepare(efz_term_reverse_target,Maps,#{})).

harness_input_limits_preflight_test() ->
    Custom=efz_term_custom_limits_target:options(),
    Limits=efz_term_custom_limits_target:input_limits(),
    ?assertEqual({error,term_api_input_limits_mismatch},
        efz_term_api_adapter:prepare(efz_term_reverse_target,
            efz_term_reverse_target:options(),#{collection=>64})),
    ?assertEqual({error,invalid_term_api_input_limits},
        efz_term_api_adapter:prepare(efz_term_invalid_limits_target,
            efz_term_invalid_limits_target:options(),#{})),
    case code:which(efz_term_model) of
        non_existing->?assertMatch({error,{term_api_model_unavailable,_}},
            efz_term_api_adapter:prepare(efz_term_custom_limits_target,Custom,Limits));
        _->
            {ok,C}=efz_term_api_adapter:prepare(efz_term_custom_limits_target,Custom,Limits),
            {ok,Raw}=efz_term_api_adapter:generate(0,C),
            {ok,[Args]}=efz_term_codec:decode(Raw,maps:get(arguments,Custom),Limits),
            ?assert(length(Args)>32),
            ?assertEqual(lists:reverse(Args),efz_term_custom_limits_target:run(Raw)),
            ?assertMatch({skip,_},efz_term_codec:decode(Raw,maps:get(arguments,Custom),#{})),
            ?assertMatch({ok,_},efz_term_api_adapter:prepare(efz_term_reverse_target,
                efz_term_reverse_target:options(),#{collection=>16,nodes=>64})),
            ?assertMatch({ok,_},efz_term_api_adapter:prepare(efz_term_custom_limits_target,
                Custom,Limits#{bytes=>2048,nodes=>128})),
            Dependencies=efz_term_api_adapter:code_dependencies(C),
            ?assert(lists:member(efz_term_codec,maps:get(semantic,Dependencies)))
    end.

resource_reconstruction_state_reset_test() ->
    O=efz_stateful_target:options(),S=maps:get(arguments,O),
    Cs=[{{'$efz_resource',counter},add,5},{{'$efz_resource',counter},get,0},
        {{'$efz_resource',counter},reset,0},{{'$efz_resource',counter},get,0}],
    {ok,Raw}=efz_term_codec:encode([Cs],S,#{}),
    Before=counter_pids(),
    One=efz_stateful_target:run(Raw),Two=efz_stateful_target:run(Raw),
    ?assertEqual(One,Two),
    ?assertEqual(#{scenario_executions=>1,library_operations=>4,trace=>[5,5,0,0]},One),
    ?assertEqual(Before,counter_pids()),
    ?assertEqual(true,efz_stateful_target:property([Cs],{ok,One})),
    {ok,Read}=efz_term_codec:encode([[{{'$efz_resource',counter},get,0}]],S,#{}),
    ?assertEqual([0],maps:get(trace,efz_stateful_target:run(Read))),
    ?assertMatch({skip,_},efz_term_codec:encode([[{{'$efz_resource',other},get,0}]],S,#{})).
counter_pids() -> [P||P<-processes(),case process_info(P,dictionary) of
    {dictionary,D}->proplists:get_value('$initial_call',D)=:={efz_stateful_counter,init,1};
    _->false end].

bounded_summary_test() ->
    S=efz_term_codec:summary({self(),make_ref(),fun()->ok end,[1,2,3]},#{nodes=>3}),
    ?assertEqual(3,maps:get(nodes,S)),?assertEqual(true,maps:get(truncated,S)),
    ?assert(lists:all(fun(C)->C>=0 andalso C=<12 end,maps:get(classes,S))).

optional_model_test_() -> case code:which(efz_term_model) of non_existing->[];
    _->[fun structural_mutations/0,fun nested_api_mutations/0,
        fun result_observation/0,fun custom_state_property/0,fun wrong_model_abi/0] end.
wrong_model_abi() ->
    {module,efz_term_model}=code:ensure_loaded(efz_term_model),
    {efz_term_model,Original,OriginalFile}=code:get_object_code(efz_term_model),
    try
        lists:foreach(fun({Present,Arity,Missing,MissingArity})->
            Forms=[{attribute,1,module,efz_term_model},
                {attribute,2,export,[{Present,Arity}]},
                {function,3,Present,Arity,[{clause,3,
                    lists:duplicate(Arity,{var,3,'_'}),[],[{integer,3,0}]}]}],
            {ok,efz_term_model,Binary,[]}=compile:forms(Forms,[binary,return_errors,return_warnings]),
            _=code:purge(efz_term_model),_=code:delete(efz_term_model),
            {module,efz_term_model}=code:load_binary(efz_term_model,"wrong-model-abi",Binary),
            ?assertEqual({error,{term_api_model_callback_unavailable,Missing,MissingArity}},
                efz_term_api_adapter:prepare(efz_term_reverse_target,
                    efz_term_reverse_target:options(),#{}))
        end,[{scalar,4,observe,6},{observe,6,scalar,4}])
    after
        _=code:purge(efz_term_model),_=code:delete(efz_term_model),
        {module,efz_term_model}=code:load_binary(efz_term_model,OriginalFile,Original)
    end.
structural_mutations() ->
    O=efz_term_reverse_target:options(),
    {ok,C}=efz_term_api_adapter:prepare(efz_term_reverse_target,O,#{}),
    {ok,Raw}=efz_term_codec:encode([[1,2,3]],maps:get(arguments,O),#{}),
    lists:foreach(fun({Op,Choice})->
        First=efz_term_api_adapter:mutate(Raw,Op,#{choice=>Choice},C),
        ?assertEqual(First,efz_term_api_adapter:mutate(Raw,Op,#{choice=>Choice},C)),
        case First of {ok,B,_}->?assertMatch({ok,_},efz_term_codec:decode(B,maps:get(arguments,O),#{}));
            {skip,_}->ok end
    end,[{Op,Choice}||Op<-lists:seq(0,4),Choice<-lists:seq(0,20)]),
    ?assertMatch({skip,_},efz_term_api_adapter:mutate(<<"malformed">>,0,#{choice=>0},C)),
    {ok,Smaller}=efz_term_api_adapter:shrink(Raw,C),
    ?assert(lists:any(fun(B)->byte_size(B)<byte_size(Raw) end,Smaller)),
    lists:foreach(fun(I)->First=efz_term_api_adapter:generate(I,C),
        ?assertEqual(First,efz_term_api_adapter:generate(I,C)) end,lists:seq(0,31)).
nested_api_mutations() ->
    lists:foreach(fun({Target,Args})->
        O=Target:options(),Specs=maps:get(arguments,O),
        {ok,C}=efz_term_api_adapter:prepare(Target,O,#{}),
        {ok,Raw}=efz_term_codec:encode(Args,Specs,#{}),
        lists:foreach(fun({Op,Choice})->case efz_term_api_adapter:mutate(Raw,Op,#{choice=>Choice},C) of
            {ok,Bin,_}->?assertMatch({ok,_},efz_term_codec:decode(Bin,Specs,#{}));
            {skip,_}->ok
        end end,[{Op,Choice}||Op<-lists:seq(0,4),Choice<-lists:seq(0,40)])
    end,[{efz_term_maps_target,[present,#{present=>{1,<<"abc">>}}]},
        {efz_term_tuple_target,[#{a=>1,b=>2},{a,3}]},
        {efz_stateful_target,[[{{'$efz_resource',counter},put,7},
            {{'$efz_resource',counter},add,2}]]}]).
result_observation() ->
    O=efz_term_maps_target:options(),{ok,C}=efz_term_api_adapter:prepare(efz_term_maps_target,O,#{}),
    {ok,F}=efz_term_api_adapter:observe(<<>>,{ok,{ok,{1,<<"x">>}}},C),
    ?assert(length(F)=<64),?assert(lists:all(fun(I)->I>=0 andalso I=<255 end,F)),
    ?assertEqual({ok,F},efz_term_api_adapter:observe(<<>>,{ok,{ok,{999,<<"different">>}}},C)),
    {ok,Timed}=efz_term_api_adapter:observe(<<>>,{timeout,1000},C),
    ?assert(lists:member(2,Timed)),
    ?assertEqual({inconclusive,no_property},efz_term_api_adapter:oracle(<<>>,{ok,ok},C)).
custom_state_property() ->
    O=(efz_stateful_target:options())#{property=>#{callback=>{efz_stateful_target,property}}},
    {ok,C}=efz_term_api_adapter:prepare(efz_stateful_target,O,#{}),
    Cs=[{{'$efz_resource',counter},add,1}],
    {ok,Raw}=efz_term_codec:encode([Cs],maps:get(arguments,O),#{}),
    ?assertEqual({pass,{generic_custom_property,1}},efz_term_api_adapter:oracle(Raw,{ok,efz_stateful_target:run(Raw)},C)),
    ?assertEqual({fail,{generic_custom_property,1}},efz_term_api_adapter:oracle(Raw,{ok,#{trace=>[5],library_operations=>1}},C)).
