#!/usr/bin/env escript
-mode(compile).
main([Dir]) ->
    true = code:add_patha("_build/default/lib/efz/ebin"),
    File = filename:join(Dir,"audit_faults.erl"),
    {ok,audit_faults,Beam} = compile:noenv_file(File,[binary,debug_info]),
    {module,audit_faults} = code:load_binary(audit_faults,File,Beam),
    %% Valid initial corpus and default idle threshold: no-op lane stops before bitflip.
    Seeds = [<<I>> || I <- lists:seq(0,255)],
    {ok,C} = efz_mutation_plan:prepare(#{seed=>{1,2,3},
        stages=>[dictionary_overwrite,bitflip],dictionary=>[<<"AB">>]},Seeds),
    Es = [#{id=>I+1,input=><<I>>} || I <- lists:seq(0,255)],
    {done,mutation_exhausted,End} = skips(efz_mutation_plan:new(C),Es),
    #{generated_candidates:=0,visits:=256} = maps:get(counts,End),
    {operation,_} = efz_mutation_plan:deterministic(bitflip,<<0>>,0,C),
    io:format("EARLY_EXHAUSTION valid_corpus=256 candidates=0 visits=256 available_bitflip=true~n"),
    HarnessFile = filename:join(Dir,"audit_harness.erl"),
    {ok,audit_harness,HarnessBeam} = compile:noenv_file(HarnessFile,[binary,debug_info]),
    {module,audit_harness} = code:load_binary(audit_harness,HarnessFile,HarnessBeam),
    {ok,AB} = file:read_file(filename:join(Dir,"artifact.term")),
    {ok,_} = efz:start(#{target=>audit_harness,artifacts=>[binary_to_term(AB)],seeds=>Seeds,
        mutation_mode=>staged,max_iterations=>100,
        mutation=>#{seed=>{1,2,3},stages=>[dictionary_overwrite,bitflip],dictionary=>[<<"AB">>]}}),
    Early = efz:await(5000), ok = efz:stop(),
    #{calibrations:=256,executions:=0,infrastructure_failures:=0} = maps:get(stats,Early),
    {mutation_exhausted,mutation_exhausted} = maps:get(status,Early),
    io:format("EARLY_EXHAUSTION_CAMPAIGN ~tp~n",[maps:with([status,stats,mutation_stats],Early)]),
    %% Root-level options are retained but not interpreted as limits.
    {ok,Ignored} = efz_config:prepare(#{target=>audit_faults,coverage=>manual,seeds=>[<<"noop">>],
        max_input_bytes=>0, function=>absent, arity=>99, corpus_dir=>"unused"}),
    io:format("IGNORED_CONFIG ~tp~n",[maps:with([max_input_bytes,function,arity,corpus_dir],Ignored)]),
    {ok,_} = efz:start(#{target=>audit_faults,coverage=>manual,seeds=>[<<"crash">>],
        max_iterations=>0,crash_dir=>"/dev/null/efz-audit"}),
    Report = efz:await(5000), ok = efz:stop(),
    {infrastructure_failure,{worker_down,_}} = maps:get(status,Report),
    io:format("STORAGE_FAILURE ~tp~n",[maps:with([status,stats],Report)]),
    ok = file:write_file(filename:join(Dir,"storage-failure.term"),term_to_binary(Report)).
skips(S,Es) -> case efz_mutation_plan:next(S,Es) of {skip,_,Next}->skips(Next,Es);Other->Other end.
