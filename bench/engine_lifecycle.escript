#!/usr/bin/env escript
-mode(compile).

%% Synthetic layers only. The executor and campaign rows use real EFZ code.
main([Out]) ->
    true=code:add_patha("_build/default/lib/efz/ebin"),
    {ok,_}=application:ensure_all_started(crypto),
    Input = <<"A">>,
    Base=#{target=>efz_noop_target,seeds=>[Input],coverage_backend=>none,
        runtime_oracles=>#{enabled=>false},timeout=>1000,
        random_seed=>{1,2,3},selection_seed=>{1,2,3}},
    {ok,Options}=efz_config:prepare(Base),
    Actor=spawn(fun actor_loop/0),
    Results=[run(direct_100000,100000,fun()->efz_noop_target:run(Input) end),
        run(persistent_actor_10000,10000,fun()->
            Ref=make_ref(),Actor!{self(),Ref},
            receive {Ref,ok}->ok end end),
        run(spawn_monitor_1000,1000,fun()->spawn_call(Input) end),
        run(real_executor_300,300,fun()->
            #{outcome:={ok,ok}}=efz_executor:run(efz_noop_target,Input,1000,Options),ok end),
        run(full_campaign_300,300,fun()->
            Config=Base#{benchmark_replay_inputs=>lists:duplicate(300,Input)},
            {ok,_}=efz:start(Config),
            try #{status:=completed}=efz:await(60000) after efz:stop() end
        end,1)],
    Actor!stop,
    Report=#{otp=>erlang:system_info(otp_release),
        schedulers=>erlang:system_info(schedulers_online),rows=>Results},
    ok=filelib:ensure_dir(Out),
    ok=file:write_file(Out,io_lib:format("~tp.~n",[Report])),
    io:format("~tp~n",[Report]);
main(_) -> error("usage: escript bench/engine_lifecycle.escript OUTPUT.term").

run(Name,N,Fun) -> run(Name,N,Fun,N).
run(Name,Iterations,Fun,Calls) ->
    {reductions,R0}=process_info(self(),reductions),
    {GC0,_,_}=erlang:statistics(garbage_collection),
    T0=erlang:monotonic_time(microsecond),
    repeat(Calls,Fun),
    Us=erlang:monotonic_time(microsecond)-T0,
    {reductions,R1}=process_info(self(),reductions),
    {GC1,_,_}=erlang:statistics(garbage_collection),
    #{stage=>Name,iterations=>Iterations,total_us=>Us,
      us_per_iteration=>Us/Iterations,exec_per_sec=>1000000*Iterations/max(1,Us),
      caller_reductions_per_iteration=>(R1-R0)/Iterations,
      vm_gc_delta=>GC1-GC0}.
repeat(0,_) -> ok;
repeat(N,Fun) -> _=Fun(),repeat(N-1,Fun).

actor_loop() ->
    receive
        {Caller,Ref}->ok=efz_noop_target:run(<<"A">>),Caller!{Ref,ok},actor_loop();
        stop->ok
    end.
spawn_call(Input) ->
    {P,Mon}=spawn_monitor(fun()->ok=efz_noop_target:run(Input) end),
    receive {'DOWN',Mon,process,P,normal}->ok end.
