#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).
%% Finite component measurements, outside campaigns; no target execution.
main([Build,Out])->
    true=code:add_patha(filename:join([Build,"lib","efz","ebin"])),
    L={limits,4096,32,128,1},
    {ok,Large}=efz_gleam_adapter:generate(10,L),
    Rows=[sample(B,L)||B<-[<<"a=",255>>,Large]],
    ok=file:write_file(Out,json:encode(#{fixture_outcome_source=>model,
        target_executions=>0,diagnostic=>true,repetitions=>10000,samples=>Rows})),
    io:format("Feedback component samples written to ~s~n",[Out]);
main(_)->io:format("Usage: gleam_feedback_probe.escript BUILD OUTPUT.json~n"),halt(2).
sample(B,L)->
    {ok,{query,Fields,canonical}}=efz_gleam_adapter:decode(B,L),
    Outcome={ok,{accepted,[{K,V}||{field,K,V}<-Fields]}},
    {ok,Fs}=efz_gleam_adapter:observe(B,Outcome,L),
    {pass,query_model_agreement}=efz_gleam_adapter:oracle(B,Outcome,L),
    All=[{<<"cow_qs">>,1,I}||I<-lists:seq(0,11)],
    Entry=#{id=>1,metadata=>#{semantic=>efz_semantic:metadata(All)}},
    #{input_bytes=>byte_size(B),fields=>length(Fields),features=>[I||{_,_,I}<-Fs],
        observer_us=>measure(fun()->efz_gleam_adapter:observe(B,Outcome,L) end),
        oracle_us=>measure(fun()->efz_gleam_adapter:oracle(B,Outcome,L) end),
        exact_set_novelty_us=>measure(fun()->Fs--All end),
        representatives_12_us=>measure(fun()->efz_semantic:representatives([Entry]) end)}.
measure(F)->repeat(100,F),{Us,ok}=timer:tc(fun()->repeat(10000,F) end),Us/10000.
repeat(0,_)->ok;
repeat(N,F)->_=F(),repeat(N-1,F).
