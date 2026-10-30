#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).
%% Diagnostic microbenchmark only: temporary export_all never enters EFZ builds.
main([Out])->
    Root=filename:dirname(filename:dirname(filename:absname(escript:script_name()))),
    [begin
        Path=filename:join([Root,"src",atom_to_list(M)++".erl"]),
        {ok,M,B}=compile:noenv_file(Path,[binary,export_all,nowarn_export_all]),
        {module,M}=code:load_binary(M,"diagnostic_export_all",B)
    end||M<-[efz_mutation_plan,efz_worker]],
    Forms=[{attribute,1,module,efz_dispatch_control},
        {attribute,1,export,[{structured,3},{semantic_callbacks,4}]},
        {function,1,structured,3,[{clause,1,[v('A'),v('B'),v('S')],[],
            [{tuple,1,[{atom,1,ordinary},v('S')]}]}]},
        {function,1,semantic_callbacks,4,[{clause,1,[v('A'),v('B'),v('M'),v('S')],[],
            [{tuple,1,[{atom,1,ok},v('M'),v('S')]}]}]}],
    {ok,efz_dispatch_control,Control}=compile:forms(Forms,[binary,nowarn_unused_vars]),
    {module,efz_dispatch_control}=code:load_binary(efz_dispatch_control,"diagnostic_control",Control),
    C=#{max_input_bytes=>4096,stages=>[havoc]},S=#{rng=>unused},M=#{phase=>mutation},
    OffS=S#{gleam_layer=>false},N=1000000,
    Fs=[{plan,fun()->efz_mutation_plan:structured(<<"a=1">>,C,S) end,
             fun()->efz_dispatch_control:structured(<<"a=1">>,C,S) end,{ordinary,S}},
        {worker,fun()->efz_worker:semantic_callbacks(<<"a=1">>,unused,M,OffS) end,
             fun()->efz_dispatch_control:semantic_callbacks(<<"a=1">>,unused,M,OffS) end,{ok,M,OffS}}],
    Rows=[begin
        _=loop(10000,F),_=loop(10000,Base),
        {First,Second}=case I rem 2 of 0->{F,Base};_->{Base,F} end,
        {T1,Expected}=timer:tc(fun()->loop(N,First) end),
        {T2,Expected}=timer:tc(fun()->loop(N,Second) end),
        {ActualUs,ControlUs}=case I rem 2 of 0->{T1,T2};_->{T2,T1} end,
        #{dispatch=>Name,trial=>I,calls=>N,dispatch_ns=>ActualUs*1000/N,
          control_ns=>ControlUs*1000/N,delta_ns=>(ActualUs-ControlUs)*1000/N}
    end||{Name,F,Base,Expected}<-Fs,I<-lists:seq(1,5)],
    ok=file:write_file(Out,json:encode(Rows)),io:format("~p~n",[Rows]);
main(_)->halt(2).
v(Name)->{var,1,Name}.
loop(1,F)->F();
loop(N,F)->_=F(),loop(N-1,F).
