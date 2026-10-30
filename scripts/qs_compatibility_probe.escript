#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).
%% Deterministic QS compatibility observations, no campaign or defect fixture.
main([Engine,Root,Output]) ->
    true=code:add_patha(filename:join([Engine,"lib","efz","ebin"])),
    true=code:add_patha(filename:join([Root,"_build","default","lib","cowlib","ebin"])),
    {ok,efz_qs_target,B}=compile:file(filename:join([Root,"examples","query_string","efz_qs_target.erl"]),[binary,debug_info]),
    {module,efz_qs_target}=code:load_binary(efz_qs_target,"ordinary_qs_harness",B),
    Fixtures=[<<>>,<<"a=">>,<<"a=1&a=2">>,<<"a=%00%FF">>,
        <<"a=%20%26%3D%25&a=1">>,<<"a=%">>,<<"a=%GG">>,<<"a+b=c+d">>,
        <<"=unsupported">>,<<"flag">>,<<"utf=",16#c3,16#a9>>],
    L={limits,4096,32,128,1},
    Rows=[begin
        Outcome={ok,efz_qs_target:run(Raw)},
        #{input=>Raw,outcome=>Outcome,decode=>efz_gleam_adapter:decode(Raw,L),
          observation=>efz_gleam_adapter:observe(Raw,Outcome,L),
          oracle=>efz_gleam_adapter:oracle(Raw,Outcome,L),
          mutations=>[{Op,efz_gleam_adapter:mutate(Raw,Op,L)}||Op<-lists:seq(0,5)]}
    end||Raw<-Fixtures],
    Data=#{generation=>[efz_gleam_adapter:generate(I,L)||I<-lists:seq(0,23)],fixtures=>Rows},
    %% New explicit plugin must preserve operation bytes, local features and
    %% property decisions; the public namespace/property wrapper is versioned.
    case code:ensure_loaded(efz_qs_adapter) of
        {module,efz_qs_adapter}->
            {ok,Context}=efz_qs_adapter:prepare(efz_qs_target,#{},#{bytes=>4096}),
            lists:foreach(fun(I)->
                true=efz_qs_adapter:generate(I,Context)=:=efz_gleam_adapter:generate(I,L)
            end,lists:seq(0,23)),
            lists:foreach(fun(#{input:=Raw,outcome:=Outcome,mutations:=Mut,observation:=Obs,oracle:=Oracle})->
                lists:foreach(fun({Op,Expected})->Expected=efz_qs_adapter:mutate(Raw,Op,#{choice=>4321},Context) end,Mut),
                Local=case Obs of {ok,Fs}->{ok,[Id||{_,_,Id}<-Fs]};Other->Other end,
                Local=efz_qs_adapter:observe(Raw,Outcome,Context),
                Decision=case Oracle of {pass,Property}->{pass,{Property,1}};
                    {fail,Property}->{fail,{Property,1}};OtherDecision->OtherDecision end,
                Decision=efz_qs_adapter:oracle(Raw,Outcome,Context)
            end,Rows);
        {error,nofile}->ok
    end,
    {ok,F}=file:open(Output,[write,binary,exclusive]),
    ok=file:write(F,term_to_binary(Data,[deterministic])),ok=file:close(F),
    io:format("24 generations, 11 fixtures, 66 operations, observations/oracles saved~n");
main(_)->halt(2).
