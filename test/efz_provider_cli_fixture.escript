#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).
%% Test setup calls the real provider and stores only bounded portable recipes.
main([Dir,Core])->
    Root=filename:dirname(filename:dirname(filename:absname(escript:script_name()))),
    true=code:add_patha(filename:join([Root,"_build","default","lib","efz","ebin"])),
    O=#{mode=>erlamsa,core_path=>Core,on_skip=>skip,limits=>#{operations=>1},
        options=>#{profile=>bytes,operators=>[{byte_flip,1}],patterns=>[{once,1}]}},
    {ok,P}=efz_mutation_provider:prepare(O,4096),
    Input=list_to_binary(lists:seq(0,255)),
    Request=#{seed=>{17,23,41},operator=>byte_flip,pattern=>once,budget=>1},
    {ok,Candidate,Meta}=efz_mutation_provider:mutate(Input,Request,P),
    {ok,C}=efz_mutation_plan:prepare(#{seed=>{17,23,41},stages=>[havoc]},[Input]),
    Data=#{schema_version=>1,wrapper_version=>1,source=>erlamsa,mode=>erlamsa,
        identity=>maps:get(core_identity,P),config_identity=>maps:get(config_identity,P),
        request=>Request,request_number=>1,recipe=>term_to_binary(Meta,[deterministic]),
        limits=>maps:get(limits,P),fallback=>none},
    Plan=#{primary=>Input,primary_id=>crypto:hash(sha256,Input),parent=>1,stage=>havoc,
        config_id=>maps:get(config_id,C),dictionary_id=>maps:get(dictionary_id,C),
        source_kind=>provider,provider=>Data,
        operations=>[{provider_replace,1,crypto:hash(sha256,Candidate),Candidate}]},
    Recipe=efz_recipe:make(Plan,Candidate,C,#{}),
    ok=efz_recipe:save(filename:join(Dir,"artifact.recipe"),Recipe),
    ok=file:write_file(filename:join(Dir,"expected.input"),Candidate),
    ok=file:write_file(filename:join(Dir,"provider.term"),io_lib:format("~tp.~n",[O])),
    ok=file:write_file(filename:join(Dir,"mismatch.term"),io_lib:format("~tp.~n",[O#{timeout=>2000}])),
    ok.
