%% Same fixture and driver can run against the reconstructed pre-change checkout.
-module(efz_runtime_bench).
-export([run/3]).
run(Mode,Root,Out)->
    {ok,H,B}=compile:file(filename:join(Root,"fixtures/runtime/efz_runtime_harness.erl"),[binary,debug_info]),
    {module,H}=code:load_binary(H,"runtime-bench",B),
    {ok,A}=efz_instrument:compile(filename:join(Root,"fixtures/runtime/efz_runtime_sites.erl"),
        #{modules=>[efz_runtime_sites],source_root=>Root,outdir=>filename:join(Out,"targets")}),
    C0=#{target=>H,artifacts=>[A],seeds=>[<<"deterministic">>],timeout=>1000,
        max_iterations=>1000,random_seed=>{17,23,41},selection_seed=>{5,7,11},
        crash_dir=>filename:join(Out,"crashes")},
    P=case Mode of
        baseline->undefined;
        off->#{enabled=>false};
        stability->#{enabled=>true,resources=>#{enabled=>false},hangs=>#{enabled=>false}};
        resources->#{enabled=>true,stability=>#{enabled=>false},hangs=>#{enabled=>false}};
        full->#{enabled=>true}
    end,
    C=case P of undefined->C0;_->C0#{runtime_oracles=>P} end,
    %% Warm the same code/ETS/crypto paths; each measured campaign resets seeds.
    _=campaign(C#{max_iterations=>100}),
    Rows=[campaign(C)||_<-lists:seq(1,5)],
    %% Long-lived input samples memory independently from short-loop throughput.
    {ok,Ms}=efz_instrument:preflight([A]),
    O0=#{coverage=>automatic,manifests=>Ms},O=case P of undefined->O0;_->O0#{runtime_oracles=>P} end,
    {Micros,R}=timer:tc(fun()->efz_executor:run(H,<<"mailbox_ets">>,1000,O) end),
    Result=#{mode=>Mode,otp=>erlang:system_info(otp_release),schedulers=>erlang:system_info(schedulers_online),
        campaigns=>Rows,long_input_wall_us=>Micros,long_input_runtime=>maps:get(runtime_observations,R,disabled)},
    ok=efz_fs:atomic_file(filename:join(Out,atom_to_list(Mode)++".term"),term_to_binary(Result)),
    io:format("~p ~tp~n",[Mode,Rows]),Result.
campaign(C)->
    T=erlang:monotonic_time(microsecond),{ok,_}=efz:start(C),R=efz:await(60000),ok=efz:stop(),
    completed=maps:get(status,R),Wall=erlang:monotonic_time(microsecond)-T,S=maps:get(stats,R),
    #{wall_us=>Wall,mutation_executions=>maps:get(executions,S),
      calibration_executions=>maps:get(calibrations,S),verification_executions=>maps:get(verification_executions,S,0),
      verification_elapsed_us=>maps:get(verification_elapsed_us,S,0),
      diagnostic_us=>maps:get(runtime_diagnostic_us,S,0),sampling_us=>maps:get(runtime_sampling_us,S,0),sampled=>maps:get(runtime_sampled_executions,S,0),
      missed=>maps:get(runtime_missed_executions,S,0),max_buffer_bytes=>maps:get(runtime_max_buffer_bytes,S,0),
      mutation_per_second=>1000000*maps:get(executions,S)/Wall}.
