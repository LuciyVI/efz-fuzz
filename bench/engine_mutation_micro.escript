#!/usr/bin/env escript
-mode(compile).

main([Out]) ->
    true=code:add_patha("_build/default/lib/efz/ebin"),
    {ok,_}=application:ensure_all_started(crypto),
    B = <<"GET /api/items?id=123 HTTP/1.1\r\nHost: localhost\r\n\r\n">>,
    Opts=#{iteration=>1,max_input_bytes=>4096},
    _=rand:seed(exsplus,{1,2,3}),
    _=efz_mutator_random:mutate(B,Opts),
    Single=measure(100,fun()->efz_mutator_random:mutate(B,Opts) end),
    Batch=measure(10,fun()->random_batch(1000,B,Opts,0) end),
    Batch10k=measure(5,fun()->random_batch(10000,B,Opts,0) end),
    Batch100k=measure(3,fun()->random_batch(100000,B,Opts,0) end),
    {ok,C}=efz_mutation_plan:prepare(#{seed=>{1,2,3},max_input_bytes=>4096,
        stages=>[dictionary_insert,dictionary_overwrite],
        dictionary=>[<<"GET">>,<<"Host">>,<<"/api">>,<<"POST">>]},[B]),
    Entries=[#{id=>1,input=>B}],
    Dictionary=measure(10,fun()->staged_batch(1000,efz_mutation_plan:new(C),Entries,0) end),
    Report=#{otp=>erlang:system_info(otp_release),
        architecture=>erlang:system_info(system_architecture),
        schedulers=>erlang:system_info(schedulers_online),
        input_bytes=>byte_size(B),single_random_us=>Single,
        random_1000_us=>Batch,random_10000_us=>Batch10k,
        random_100000_us=>Batch100k,dictionary_1000_visits_us=>Dictionary},
    ok=filelib:ensure_dir(Out),
    ok=file:write_file(Out,io_lib:format("~tp.~n",[Report])),
    io:format("~tp~n",[Report]);
main(_) -> error("usage: escript bench/engine_mutation_micro.escript OUTPUT.term").

measure(N,Fun) ->
    Samples=[begin
        {reductions,R0}=process_info(self(),reductions),
        {memory,M0}=process_info(self(),memory),
        {Us,Value}=timer:tc(Fun),
        {reductions,R1}=process_info(self(),reductions),
        {memory,M1}=process_info(self(),memory),
        Digest=case Value of V when is_binary(V) -> {binary_crc32,erlang:crc32(V)};
            _ -> Value end,
        #{us=>Us,reductions=>R1-R0,memory_delta=>M1-M0,result=>Digest}
    end || _ <- lists:seq(1,N)],
    Times=lists:sort([maps:get(us,S) || S<-Samples]),
    #{calls=>N,median_us=>lists:nth(max(1,ceil(N/2)),Times),
      min_us=>hd(Times),max_us=>lists:last(Times),samples=>Samples}.

random_batch(0,_,_,Bytes) -> #{output_bytes_total=>Bytes};
random_batch(N,B,Opts,Bytes) ->
    Output=efz_mutator_random:mutate(B,Opts),
    random_batch(N-1,B,Opts,Bytes+byte_size(Output)).

staged_batch(0,_,_,Count) -> Count;
staged_batch(N,S,Entries,Count) ->
    case efz_mutation_plan:next(S,Entries) of
        {candidate,_,_,Next} -> staged_batch(N-1,Next,Entries,Count+1);
        {skip,_,Next} -> staged_batch(N-1,Next,Entries,Count);
        {done,_,_} -> Count;
        {error,Why,_} -> error(Why)
    end.
