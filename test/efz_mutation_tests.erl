-module(efz_mutation_tests).
-include_lib("eunit/include/eunit.hrl").

config()->config(#{}).
config(Extra)->{ok,C}=efz_mutation_plan:prepare(maps:merge(#{seed=>{17,23,41},max_input_bytes=>64,
    max_block_bytes=>16,max_token_bytes=>16},Extra),[<<>>]),C.
op(B,Op)->efz_mutation:apply_operation(B,Op,config()).

vectors()->[
    {<<0,0>>,{flip_bits,7,2},<<1,128>>},
    {<<0,0>>,{flip_bits,6,4},<<3,192>>},
    {<<255>>,{flip_bits,0,1},<<127>>},
    {<<0,127,255,64>>,{invert_bytes,0,4},<<255,128,0,191>>},
    {<<0,127,255>>,{invert_bytes,1,2},<<0,128,0>>},
    {<<0>>,{invert_bytes,0,1},<<255>>},
    {<<255>>,{add,0,8,big,1},<<0>>},
    {<<0>>,{add,0,8,little,-1},<<255>>},
    {<<255,0>>,{add,0,16,little,1},<<0,1>>},
    {<<0,255>>,{add,0,16,big,1},<<1,0>>},
    {<<0,0>>,{add,0,16,big,-1},<<255,255>>},
    {<<255,255,255,255>>,{add,0,32,little,1},<<0,0,0,0>>},
    {<<0,0,0,0>>,{add,0,32,big,-1},<<255,255,255,255>>},
    {<<0,0>>,{set_integer,0,16,little,32768},<<0,128>>},
    {<<0,0,0,0>>,{set_integer,0,32,big,16#80000000},<<128,0,0,0>>},
    {<<1,2,3>>,{overwrite,1,<<9,8>>},<<1,9,8>>},
    {<<1,2>>,{insert,2,<<9>>},<<1,2,9>>},
    {<<>>,{insert,0,<<9>>},<<9>>},
    {<<1>>,{delete,0,1},<<>>},
    {<<1,2,3>>,{duplicate,0,2,1},<<1,1,2,2,3>>},
    {<<>>,{dictionary_insert,0,<<"AB">>},<<"AB">>},
    {<<1,2,3>>,{dictionary_overwrite,1,<<"AB">>},<<1,"AB">>},
    {<<1,2,3>>,{splice,1,1,<<8,9>>,efz_mutation:hash(<<8,9>>)},<<1,9>>},
    {<<1>>,{splice,0,0,<<>>,efz_mutation:hash(<<>>)},<<>>}].
operators_test()->lists:foreach(fun({B,Op,Expected})->?assertEqual({ok,Expected},op(B,Op)) end,vectors()).
limits_test()->
    C=config(#{max_input_bytes=>4,max_block_bytes=>2,max_token_bytes=>2}),
    ?assertEqual({ok,<<1,2,3,4>>},efz_mutation:apply_operation(<<1,2>>,{insert,2,<<3,4>>},C)),
    lists:foreach(fun(Op)->?assertEqual({skip,size_limit},efz_mutation:apply_operation(<<1,2,3>>,Op,C)) end,
        [{insert,0,<<3,4>>},{duplicate,0,2,3},{dictionary_insert,0,<<3,4>>}]),
    ?assertEqual({skip,size_limit},efz_mutation:apply_operation(<<>>,{insert,0,<<1,2,3>>},C)),
    ?assertEqual({error,oversized_input},efz_mutation:apply_operation(<<0,0,0,0,0>>,{delete,0,1},C)),
    lists:foreach(fun(Op)->?assertEqual({skip,insufficient_length},op(<<>>,Op)) end,
        [{flip_bits,0,1},{invert_bytes,0,1},{add,0,16,little,1},{delete,0,1},{duplicate,0,1,0},{overwrite,0,<<1>>}]),
    ?assertEqual({skip,insufficient_length},op(<<1,2>>,{insert,3,<<3>>})),
    ?assertEqual({skip,insufficient_length},op(<<1>>,{add,0,16,big,1})),
    ?assertEqual({skip,no_change},op(<<1>>,{overwrite,0,<<1>>})),
    ?assertEqual({error,invalid_operation},op(<<1>>,{delete,0,0})),
    ?assertEqual({error,delta_limit},op(<<1>>,{add,0,8,big,129})),
    ?assertEqual({skip,donor_unavailable},op(<<1>>,{splice,0,0,<<1>>,efz_mutation:hash(<<1>>)})),
    ?assertEqual({error,invalid_donor},op(<<1>>,{splice,0,0,<<2>>,<<0:256>>})).
bit_model_test()->
    %% Independent list-of-bits model, including every crossing position.
    lists:foreach(fun(N)->B=list_to_binary(lists:seq(0,N-1)),Bits=[X||<<X:1>><=B],
        lists:foreach(fun(W)->lists:foreach(fun(Off)->
            Expected=[case I>=Off andalso I<Off+W of true->X bxor 1;false->X end||{I,X}<-lists:zip(lists:seq(0,8*N-1),Bits)],
            Out = << <<X:1>> || X<-Expected >>,
            ?assertEqual({ok,Out},op(B,{flip_bits,Off,W}))
        end,lists:seq(0,8*N-W)) end,[1,2,4])
    end,lists:seq(1,12)).
block_model_test()->
    lists:foreach(fun(N)->Xs=lists:seq(1,N),B=list_to_binary(Xs),
        lists:foreach(fun(At)->Expected=list_to_binary(lists:sublist(Xs,At)++[99,100]++lists:nthtail(At,Xs)),
            ?assertEqual({ok,Expected},op(B,{insert,At,<<99,100>>})) end,lists:seq(0,N)),
        lists:foreach(fun(At)->lists:foreach(fun(Len)->Expected=list_to_binary(lists:sublist(Xs,At)++lists:nthtail(At+Len,Xs)),
            ?assertEqual({ok,Expected},op(B,{delete,At,Len})) end,lists:seq(1,N-At)) end,lists:seq(0,N-1))
    end,lists:seq(0,12)).
boundaries_test()->
    ?assertEqual([0,1,2,126,127,128,129,254,255],efz_mutation:boundaries(8)),
    lists:foreach(fun(W)->Vs=efz_mutation:boundaries(W),
        ?assert(lists:member((1 bsl (W-1)),Vs)),?assertEqual((1 bsl W)-1,lists:last(Vs)),
        lists:foreach(fun(V)->lists:foreach(fun(E)->
            B=binary:copy(<<42>>,W div 8),{ok,Out}=op(B,{set_integer,0,W,E,V}),
            ?assertEqual(V,binary:decode_unsigned(Out,E)) end,[little,big]) end,Vs)
    end,[8,16,32]).

dictionary_test()->
    C=config(),{ok,Ts,Id}=efz_dictionary:normalize([<<"B">>,<<"A">>,<<"B">>],C),
    ?assertEqual([<<"A">>,<<"B">>],Ts),
    ?assertEqual({ok,Ts,Id},efz_dictionary:normalize(lists:reverse(Ts),C)),
    Path="_build/phase3-dictionary.hex",ok=file:write_file(Path,<<"# comment\n\n42\n 41\r\n42\n">>),
    ?assertEqual({ok,Ts,Id},efz_dictionary:load(Path,C)),
    lists:foreach(fun(Text)->ok=file:write_file(Path,Text),?assertMatch({error,_},efz_dictionary:load(Path,C)) end,
        [<<"a\n">>,<<"zz\n">>,<<"41 # comment\n">>,<<255,0>>,binary:copy(<<"aa">>,17)]),
    lists:foreach(fun(Tokens)->?assertMatch({error,_},efz_dictionary:normalize(Tokens,C)) end,
        [[<<>>],[not_binary],[binary:copy(<<0>>,17)]]),
    ?assertMatch({error,_},efz_dictionary:normalize([<<"A">>,<<"B">>],C#{max_tokens=>1})),
    ?assertMatch({error,_},efz_dictionary:normalize([<<"AB">>],C#{max_dictionary_bytes=>1})),
    ?assertEqual({ok,<<"A">>},op(<<>>,{dictionary_insert,0,<<"A">>})),
    ?assertEqual({skip,insufficient_length},op(<<>>,{dictionary_overwrite,0,<<"A">>})).
configuration_test()->
    lists:foreach(fun(O)->?assertMatch({error,_},efz_mutation_plan:prepare(O,[<<0>>])) end,
        [#{max_input_bytes=>0},#{max_delta=>0},#{max_block_bytes=>0},#{max_token_bytes=>-1},
         #{max_tokens=>-1},#{max_dictionary_bytes=>-1},#{attempts_per_visit=>0},#{havoc_depth=>33},
         #{random_retries=>0},#{max_idle_visits=>0},#{trace_limit=>10001},#{stages=>[]},
         #{stages=>[havoc,havoc]},#{stages=>[unknown]},#{unknown=>1},#{seed=>bad},#{prng=>default}]),
    {ok,Generated}=efz_mutation_plan:prepare(#{},[<<>>]),?assertMatch({_,_,_},maps:get(seed,Generated)),
    ?assertNotEqual(maps:get(config_id,config()),maps:get(config_id,config(#{max_delta=>1}))),
    ?assertEqual(maps:get(config_id,config()),maps:get(config_id,config(#{trace_limit=>10}))),
    ?assertMatch({error,_},efz_config:prepare(#{target=>efz_example_target,seeds=>[<<0>>],
        coverage=>manual,mutation_mode=>staged,max_iterations=>infinity})).

sequence(C,B,N)->collect(efz_mutation_plan:new(C),[#{id=>1,input=>B}],N,[]).
collect(S,_,0,Acc)->{lists:reverse(Acc),S};
collect(S,Es,N,Acc)->case efz_mutation_plan:next(S,Es) of
    {candidate,B,P,Next}->collect(Next,Es,N-1,[{B,P}|Acc]);
    {skip,_,Next}->collect(Next,Es,N,Acc);
    {done,_,Next}->{lists:reverse(Acc),Next}
end.
enumeration_test()->
    C=config(#{stages=>[bitflip],attempts_per_visit=>1}),
    {Rows,_}=sequence(C,<<0>>,100),
    Expected=[128,64,32,16,8,4,2,1,192,96,48,24,12,6,3,240,120,60,30,15],
    ?assertEqual([<<X>>||X<-Expected],[B||{B,_}<-Rows]),
    Es=[#{id=>1,input=><<0>>}],{First,S1}=collect(efz_mutation_plan:new(C),Es,7,[]),
    {Rest,_}=collect(S1,Es,100,[]),?assertEqual(Rows,First++Rest),
    BC=config(#{stages=>[boundary],attempts_per_visit=>1}),
    {Bs,_}=sequence(BC,<<0>>,100),?assertEqual([<<X>>||X<-[1,2,126,127,128,129,254,255]],[B||{B,_}<-Bs]),
    AC=config(#{stages=>[arithmetic],max_delta=>2}),
    {As,_}=sequence(AC,<<0>>,10),?assertEqual([<<1>>,<<255>>,<<2>>,<<254>>],[B||{B,_}<-As]),
    DC=config(#{stages=>[dictionary_insert],dictionary=>[<<"B">>,<<"A">>]}),
    {Ds,_}=sequence(DC,<<0>>,10),?assertEqual([<<"A",0>>,<<"B",0>>,<<0,"A">>,<<0,"B">>],[B||{B,_}<-Ds]).
fairness_test()->
    C=config(#{stages=>[bitflip,boundary],attempts_per_visit=>1}),
    {Rows,_}=collect(efz_mutation_plan:new(C),[#{id=>1,input=><<0>>},#{id=>2,input=><<1>>}],6,[]),
    Ps=[{maps:get(parent,P),maps:get(stage,P)}||{_,P}<-Rows],
    ?assertEqual([{1,bitflip},{2,bitflip},{2,boundary},{1,bitflip},{2,bitflip},{1,boundary}],Ps),
    %% An unfinished bit sweep cannot prevent random stages taking a visit.
    HC=config(#{stages=>[bitflip,havoc]}),{Mixed,_}=sequence(HC,binary:copy(<<0>>,32),20),
    ?assert(lists:member(havoc,[maps:get(stage,P)||{_,P}<-Mixed])).
finite_test()->
    C=config(#{stages=>[splice],max_idle_visits=>3}),
    {[],S}=sequence(C,<<>>,20),
    ?assertEqual(3,maps:get(visits,maps:get(counts,S))),
    ?assert(maps:get(donor_unavailable,maps:get(skip_reasons,maps:get(counts,S)))>0),
    {[],_}=sequence(config(#{stages=>[bitflip,dictionary_insert]}),<<>>,10),
    Z=config(#{stages=>[havoc],max_input_bytes=>0,max_idle_visits=>4}),
    {[],End}=sequence(Z,<<>>,20),?assertEqual(4,maps:get(visits,maps:get(counts,End))).

idle_256_seeds_test()->
    C=config(#{stages=>[dictionary_overwrite,bitflip],dictionary=>[<<"AB">>]}),
    Es=[#{id=>I+1,input=><<I>>}||I<-lists:seq(0,255)],
    ?assertEqual(256,maps:get(max_idle_visits,C)),
    Paused=skip_visits(efz_mutation_plan:new(C),Es,256),
    ?assertEqual(0,maps:get(generated_candidates,maps:get(counts,Paused))),
    {candidate,<<128>>,P,Next}=efz_mutation_plan:next(Paused,Es),
    ?assertEqual(bitflip,maps:get(stage,P)),?assertEqual(1,maps:get(parent,P)),
    ?assertEqual(1,maps:get(generated_candidates,maps:get(counts,Next))).

unproductive_lane_test()->
    Cases=[{<<0>>,[dictionary_insert,bitflip],[],<<128>>},
           {<<0>>,[dictionary_overwrite,bitflip],[<<"AB">>],<<128>>},
           {<<0>>,[splice,bitflip],[],<<128>>},
           {<<>>,[bitflip,dictionary_insert],[<<"A">>],<<"A">>}],
    lists:foreach(fun({B,Stages,Tokens,Expected})->
        C=config(#{stages=>Stages,dictionary=>Tokens,max_idle_visits=>1}),
        Es=[#{id=>1,input=>B}],
        {skip,_,Paused}=efz_mutation_plan:next(efz_mutation_plan:new(C),Es),
        {candidate,Actual,_,_}=efz_mutation_plan:next(Paused,Es),
        ?assertEqual(Expected,Actual)
    end,Cases).

deterministic_progress_test()->
    C=config(#{stages=>[dictionary_overwrite],dictionary=>[<<"A">>,<<"B">>],
        attempts_per_visit=>1,max_idle_visits=>1}),
    Es=[#{id=>1,input=><<"AA">>}],
    %% Two overwrites are no-ops, but advancing their cursors is real progress.
    Paused=skip_visits(efz_mutation_plan:new(C),Es,2),
    ?assertEqual(0,maps:get(idle,Paused)),
    {Rows,End}=collect(Paused,Es,10,[]),
    ?assertEqual([<<"BA">>,<<"AB">>],[B||{B,_}<-Rows]),
    ?assertEqual({done,mutation_exhausted,End},efz_mutation_plan:next(End,Es)).

empty_deterministic_space_test()->
    lists:foreach(fun({B,Stages,Tokens})->
        C=config(#{stages=>Stages,dictionary=>Tokens,max_idle_visits=>1}),
        S=efz_mutation_plan:new(C),
        {done,mutation_exhausted,End}=efz_mutation_plan:next(S,[#{id=>1,input=>B}]),
        ?assertEqual(0,maps:get(visits,maps:get(counts,End)))
    end,[{<<>>,[bitflip,byteflip,arithmetic,boundary],[]},
         {<<0>>,[dictionary_insert,dictionary_overwrite],[]},
         {<<0>>,[dictionary_overwrite],[<<"AB">>]}]),
    %% Size-limited operations still terminate lazily after cursor exhaustion.
    C=config(#{stages=>[dictionary_insert],dictionary=>[<<"A">>],
        max_input_bytes=>1,attempts_per_visit=>1,max_idle_visits=>1}),
    {[],End}=sequence(C,<<0>>,10),
    ?assertEqual(2,maps:get(operation_attempts,maps:get(counts,End))),
    ?assertMatch({done,mutation_exhausted,_},
        efz_mutation_plan:next(End,[#{id=>1,input=><<0>>}])),
    ?assertMatch({done,empty_corpus,_},efz_mutation_plan:next(efz_mutation_plan:new(C),[])).

idle_guard_test()->
    C=config(#{stages=>[splice],max_idle_visits=>3}),
    Es=[#{id=>1,input=><<>>}],Start=efz_mutation_plan:new(C),
    One=skip_visits(Start,Es,1),End=skip_visits(One,Es,2),
    ?assertEqual(skip_visits(Start,Es,3),End), % Resume does not reset the guard.
    ?assertEqual(3,maps:get(visits,maps:get(counts,End))),
    ?assertEqual({done,idle_budget_exhausted,End},efz_mutation_plan:next(End,Es)),
    %% Even a budget of one cannot prevent the next random lane being visited.
    Z=config(#{stages=>[splice,havoc],max_input_bytes=>0,max_idle_visits=>1}),
    Both=skip_visits(efz_mutation_plan:new(Z),Es,2),
    ?assertEqual({done,idle_budget_exhausted,Both},efz_mutation_plan:next(Both,Es)),
    ?assertEqual(2,maps:get(visits,maps:get(counts,Both))).

productive_random_lane_test()->
    C=config(#{stages=>[splice,havoc],max_input_bytes=>1,max_idle_visits=>1,
        havoc_depth=>1,random_retries=>128,attempts_per_visit=>128}),
    Es=[#{id=>1,input=><<>>}],
    Paused=skip_visits(efz_mutation_plan:new(C),Es,1),
    {candidate,B,P,End}=efz_mutation_plan:next(Paused,Es),
    ?assertEqual(1,byte_size(B)),?assertEqual(havoc,maps:get(stage,P)),
    ?assertEqual(0,maps:get(idle,End)).

idle_growth_test()->
    C=config(#{stages=>[splice],max_idle_visits=>1}),
    Es=[#{id=>1,input=><<>>}],
    Paused=skip_visits(efz_mutation_plan:new(C),Es,1),
    ?assertMatch({done,idle_budget_exhausted,_},efz_mutation_plan:next(Paused,Es)),
    %% A new donor changes the search space even with no deterministic stages.
    {candidate,B,_,Next}=efz_mutation_plan:next(Paused,Es++[#{id=>2,input=><<"ABC">>}]),
    ?assertNotEqual(<<>>,B),?assertEqual(0,maps:get(idle,Next)).

mixed_exhaustion_test()->
    C=config(#{stages=>[bitflip,splice],max_idle_visits=>1}),
    Es=[#{id=>1,input=><<0>>}],
    {Rows,End}=collect(efz_mutation_plan:new(C),Es,100,[]),
    %% Missing donors between finite visits cannot cut the bit sweep short.
    ?assertEqual(20,length(Rows)),
    ?assertEqual([bitflip],lists:usort([maps:get(stage,P)||{_,P}<-Rows])),
    ?assertEqual({done,idle_budget_exhausted,End},efz_mutation_plan:next(End,Es)).

exhausted_growth_test()->
    C=config(#{stages=>[bitflip],max_idle_visits=>1}),Es=[#{id=>1,input=><<0>>}],
    {Rows,End}=collect(efz_mutation_plan:new(C),Es,100,[]),
    ?assertEqual(20,length(Rows)),
    ?assertEqual({done,mutation_exhausted,End},efz_mutation_plan:next(End,Es)),
    Grown=Es++[#{id=>2,input=><<1>>}],
    %% Growth adds work without replaying the old content's exhausted cursor.
    {skip,stage_done,Next}=efz_mutation_plan:next(End,Grown),
    {candidate,<<129>>,P,_}=efz_mutation_plan:next(Next,Grown),
    ?assertEqual(2,maps:get(parent,P)).

skip_visits(S,_,0)->S;
skip_visits(S,Es,N)->
    {skip,_,Next}=efz_mutation_plan:next(S,Es),
    skip_visits(Next,Es,N-1).
random_state_test()->
    C=config(#{stages=>[havoc,splice],dictionary=>[<<"X">>]}),Es=[#{id=>1,input=><<0,1>>},#{id=>2,input=><<8,9>>}],
    {A,_}=with_log_level(warning,fun()->collect(efz_mutation_plan:new(C),Es,100,[]) end),
    _=rand:seed(exsplus,{999,888,777}),lists:foreach(fun(_)->rand:uniform() end,lists:seq(1,100)),
    {B,_}=with_log_level(debug,fun()->collect(efz_mutation_plan:new(C#{trace_limit=>10}),Es,100,[]) end),?assertEqual(A,B),
    ?assert(lists:any(fun({_,P})->length(maps:get(operations,P))>1 end,A)),
    lists:foreach(fun({Out,P})->
        R=efz_recipe:make(P,Out,C,#{}),?assertEqual({ok,Out},efz_recipe:regenerate(R)),
        ?assert(byte_size(Out)=<64),?assertNotEqual(maps:get(primary,P),Out)
    end,A).
with_log_level(Level,F)->
    #{level:=Old}=logger:get_primary_config(),ok=logger:set_primary_config(level,Level),
    try F() after ok=logger:set_primary_config(level,Old) end.

noop_stack_test()->
    %% This fixed exsplus seed realizes two changed operations that cancel.
    C=config(#{seed=>{556,2,3},stages=>[havoc],max_input_bytes=>1,havoc_depth=>2,
        random_retries=>1,attempts_per_visit=>1}),
    {skip,random_retry_budget,S}=efz_mutation_plan:next(efz_mutation_plan:new(C),[#{id=>1,input=><<0>>}]),
    ?assertMatch(#{operation_attempts:=2,skipped_operations:=0,generated_candidates:=0,
        skipped_candidates:=1,skip_reasons:=#{no_change:=1}},maps:get(counts,S)),
    ?assertEqual({ok,<<0>>},efz_mutation:apply_operations(<<0>>,[{flip_bits,0,1},{flip_bits,0,1}],C)).
growing_corpus_test()->
    C=config(#{stages=>[bitflip],attempts_per_visit=>1}),
    {Parents,_}=lists:mapfoldl(fun(N,{S,Es})->
        {candidate,_,P,Next}=efz_mutation_plan:next(S,Es),
        {maps:get(parent,P),{Next,Es++[#{id=>N+2,input=><<N,0>>}]}}
    end,{efz_mutation_plan:new(C),[#{id=>1,input=><<0,0>>},#{id=>2,input=><<1,0>>}]},lists:seq(1,10)),
    ?assertEqual([1,2,1,2,3,4,1,2,3,4],Parents).
duplicate_donors_test()->
    C=config(#{stages=>[splice]}),S=efz_mutation_plan:new(C),
    Es=[#{id=>1,input=><<1>>},#{id=>2,input=><<2>>}],
    {candidate,B,P,_}=efz_mutation_plan:next(S,Es),
    {candidate,B,P,_}=efz_mutation_plan:next(S,Es++[#{id=>3,input=><<2>>}]),
    [{splice,_,_,Donor,Id}]=maps:get(operations,P),?assertEqual(<<2>>,Donor),?assertEqual(efz_mutation:hash(Donor),Id),
    ?assertEqual([#{id=>1,input=><<1>>},#{id=>2,input=><<2>>}],Es).
internal_selection_test()->
    {ok,Forms}=epp:parse_file("src/efz_mutation.erl",[],[]),
    ?assertError({efz_internal_module,efz_mutation},efz_instrument_pt:parse_transform(Forms,
        [{efz_modules,[efz_mutation]},{efz_source_root,"."}])).
