#!/usr/bin/env escript
-mode(compile).

%% Short component probe; target compilation is excluded from all timings.
main([Out]) ->
    true=code:add_patha("_build/default/lib/efz/ebin"),
    {ok,_}=application:ensure_all_started(crypto),
    Old=code:get_coverage_mode(),
    _=code:set_coverage_mode(line),
    Tmp=filename:join("/tmp","efz-native-components-"++integer_to_list(erlang:unique_integer([positive]))),
    ok=file:make_dir(Tmp),
    try
        Rows=[bench_lines(N,Tmp) || N<-[1,100,1000]],
        Result=#{environment=>#{otp=>erlang:system_info(otp_release),
            erts=>erlang:system_info(version),architecture=>erlang:system_info(system_architecture),
            schedulers=>erlang:system_info(schedulers_online),warmup_samples=>2,
            timed_samples=>10},rows=>Rows},
        ok=filelib:ensure_dir(Out),
        ok=file:write_file(Out,io_lib:format("~tp.~n",[Result])),
        io:format("~tp~n",[Result])
    after _=code:set_coverage_mode(Old) end;
main(_) -> erlang:error("usage: escript bench/otp_native_public_components.escript OUTPUT.term").

bench_lines(N,Tmp) ->
    M=efz_native_components_target,
    _=code:purge(M),_=code:delete(M),_=code:purge(M),
    Src=filename:join(Tmp,atom_to_list(M)++".erl"),
    Calls=["    erlang:unique_integer(),\n" || _<-lists:seq(1,N)],
    ok=file:write_file(Src,["-module(efz_native_components_target).\n-export([run/0]).\nrun() ->\n",Calls,"    ok.\n"]),
    {ok,Artifact}=efz_cov_native_public:compile(Src,Tmp),
    {ok,[Manifest]}=efz_cov_native_public:preflight([Artifact]),
    Schema=efz_cov_native_public:prepare([Manifest]),
    Empty=efz_cov_native_public:empty(Schema),
    M:run(),{ok,Known}=efz_cov_native_public:collect(Schema),
    true=efz_cov_native_public:count(Known)>=N,
    Iterations=case N of 1000->20;_->100 end,
    lists:foreach(fun(_)->sample(M,Schema,Empty,Known,Iterations) end,lists:seq(1,2)),
    Samples=[sample(M,Schema,Empty,Known,Iterations) || _<-lists:seq(1,10)],
    Keys=[reset,execute,get_coverage,conversion,novelty_true,novelty_false,merge,full_cycle],
    #{requested_lines=>N,covered_lines=>efz_cov_native_public:count(Known),
      iterations_per_sample=>Iterations,
      summary=>maps:from_list([{K,summarize([maps:get(K,S)/Iterations || S<-Samples])} || K<-Keys])}.

sample(M,Schema,Empty,Known,Iterations) ->
    lists:foldl(fun(_,Acc)->
        T0=erlang:monotonic_time(nanosecond),
        ok=code:reset_coverage(M),T1=erlang:monotonic_time(nanosecond),
        ok=M:run(),T2=erlang:monotonic_time(nanosecond),
        Raw=code:get_coverage(line,M),T3=erlang:monotonic_time(nanosecond),
        {ok,Bits}=efz_cov_native_public:convert_raw(Schema,[{M,Raw}]),
        T4=erlang:monotonic_time(nanosecond),
        true=efz_cov_native_public:has_new(Empty,Bits),
        T5=erlang:monotonic_time(nanosecond),
        false=efz_cov_native_public:has_new(Known,Bits),
        T6=erlang:monotonic_time(nanosecond),
        Known=efz_cov_native_public:merge(Empty,Bits),
        T7=erlang:monotonic_time(nanosecond),
        D=#{reset=>T1-T0,execute=>T2-T1,get_coverage=>T3-T2,
            conversion=>T4-T3,novelty_true=>T5-T4,novelty_false=>T6-T5,
            merge=>T7-T6,full_cycle=>T7-T0},
        maps:map(fun(K,V)->V+maps:get(K,D) end,Acc)
    end,maps:from_list([{K,0}||K<-[reset,execute,get_coverage,conversion,
                                   novelty_true,novelty_false,merge,full_cycle]]),
        lists:seq(1,Iterations)).

summarize(Vals) ->
    Sorted=lists:sort(Vals),
    #{median_ns=>lists:nth(5,Sorted),min_ns=>hd(Sorted),max_ns=>lists:last(Sorted)}.
