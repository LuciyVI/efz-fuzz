#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).
%% One owned campaign. The viewer may exit; this process continues to completion.
main([ConfigPath,Out|Paths]) ->
    try
        Root=filename:dirname(filename:dirname(filename:absname(escript:script_name()))),
        [true=code:add_patha(P)||P<-[filename:join([Root,"_build","default","lib","efz","ebin"]),
            filename:join([Root,"_build","default","lib","cowlib","ebin"]),
            filename:join([Root,"_build","default","lib","cowboy","ebin"]),
            filename:join([Root,"_build","default","lib","ranch","ebin"])|Paths]],
        true=filelib:is_dir(Out),
        Config=configuration(ConfigPath,Root,Out),
        {ok,_}=efz:start(Config#{monitoring=>true,crash_dir=>filename:join(Out,"crashes")}),
        loop(Out)
    catch C:R -> io:format(standard_error,"TUI campaign: ~tp:~tp~n",[C,R]),halt(1)
    after efz:stop() end;
main(_) -> io:format(standard_error,"Usage: tui_bridge.escript CONFIG NEW_OUTPUT [CODE_PATH ...]~n",[]),halt(2).
loop(Out) ->
    S=efz_fuzzer:monitor_snapshot(),
    ok=efz_fs:atomic_file(filename:join(Out,"snapshot.json"),json:encode(portable(S))),
    case maps:get(status,S) of
        running -> receive after 500 -> loop(Out) end;
        _Status -> R=efz:await(15000),
            ok=efz_fs:atomic_file(filename:join(Out,"report.term"),term_to_binary(R)),
            case maps:get(infrastructure_failures,maps:get(stats,R),0) of 0->ok;_->halt(1) end
    end.
configuration("--demo",Root,Out)->
    Source=filename:join([Root,"examples","simple_parser","efz_example_parser.erl"]),
    {ok,A}=efz_instrument:compile(Source,#{modules=>[efz_example_parser],source_root=>Root,
        outdir=>filename:join(Out,"target")}),
    #{target=>efz_example_target,seeds=>[<<0>>,<<"BOOM!">>],artifacts=>[A],
      mutation_mode=>staged,max_iterations=>10000,timeout=>1000,
      mutation=>#{seed=>{17,23,41},stages=>[havoc]},selection_seed=>{17,23,41}};
configuration(Path,_,_)->
    {ok,[C]}=file:consult(Path),true=is_map(C),C.

portable(M) when is_map(M)->maps:from_list([{atom_to_binary(K,utf8),portable(V)}||{K,V}<-maps:to_list(M)]);
portable(L) when is_list(L)->[portable(X)||X<-L];
portable(A) when A=:=true;A=:=false;A=:=null->A;
portable(A) when is_atom(A)->atom_to_binary(A,utf8);
portable(T) when is_tuple(T)->unicode:characters_to_binary(io_lib:format("~0P",[T,5],[{chars_limit,1024}]));
portable(V)->V.
