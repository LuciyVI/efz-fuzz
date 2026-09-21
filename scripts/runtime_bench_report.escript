#!/usr/bin/env escript
-mode(compile).
main([Base,Output])->
    Root=filename:dirname(filename:dirname(filename:absname(escript:script_name()))),
    true=code:add_patha(filename:join([Root,"_build","default","lib","efz","ebin"])),
    ok=application:load(efz),{ok,Modules}=application:get_key(efz,modules),
    [code:ensure_loaded(M)||M<-Modules],
    %% Intern fixture symbols from trusted local source, never from the data file.
    {ok,_,_}=compile:file(filename:join(Root,"fixtures/runtime/efz_runtime_sites.erl"),[binary]),
    {ok,_,_}=compile:file(filename:join(Root,"bench/efz_runtime_bench.erl"),[binary]),
    Modes=[baseline,off,stability,resources,full],
    Summaries=[summarize(Base,M)||M<-Modes],
    {ok,F}=file:open(Output,[write]),
    io:format(F,"mode,median_mutation_per_second,min_mutation_per_second,max_mutation_per_second,median_wall_us,mutations,calibrations,verification,verification_us,diagnostic_us,sampling_us,sampled,missed,buffer_bytes,long_wall_us,long_samples,long_sampling_us,long_buffer_bytes~n",[]),
    [io:format(F,"~s~n",[join([fmt(V)||V<-Row])])||Row<-Summaries],
    ok=file:close(F),io:format("~tp~n",[Summaries]);
main(_)->io:put_chars("Usage: runtime_bench_report.escript BASE OUTPUT.csv\n"),halt(2).
summarize(Base,Mode)->
    Path=filename:join([Base,atom_to_list(Mode),atom_to_list(Mode)++".term"]),
    {ok,B}=efz_fs:read_bounded(Path,4194304),R=binary_to_term(B,[safe]),Rows=maps:get(campaigns,R),
    Rates=[maps:get(mutation_per_second,X)||X<-Rows],
    Mid=hd([X||X<-Rows,maps:get(mutation_per_second,X)=:=median(Rates)]),
    Long=maps:get(long_input_runtime,R),
    [Mode,median(Rates),lists:min(Rates),lists:max(Rates),maps:get(wall_us,Mid),
     maps:get(mutation_executions,Mid),maps:get(calibration_executions,Mid),
     maps:get(verification_executions,Mid),maps:get(verification_elapsed_us,Mid),maps:get(diagnostic_us,Mid,0),
     maps:get(sampling_us,Mid),maps:get(sampled,Mid),maps:get(missed,Mid),maps:get(max_buffer_bytes,Mid),
     maps:get(long_input_wall_us,R),metric(sample_count,Long),metric(sampling_us,Long),metric(diagnostic_buffer_bytes,Long)].
metric(K,M) when is_map(M)->maps:get(K,M,0);
metric(_,_) -> 0.
median(L)->lists:nth(length(L) div 2+1,lists:sort(L)).
fmt(A) when is_atom(A)->atom_to_list(A);
fmt(N) when is_integer(N)->integer_to_list(N);
fmt(F)->float_to_list(F,[{decimals,3}]).
join(L)->lists:flatten(lists:join(",",L)).
