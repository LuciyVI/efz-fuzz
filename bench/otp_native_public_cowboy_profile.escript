#!/usr/bin/env escript
-mode(compile).
-define(MODULES,[cowboy_http,cowboy_req,cowboy_router,cowboy_stream]).
main([Out]) ->
    lists:foreach(fun(P)->true=code:add_patha(filename:absname(P)) end,
                  ["_build/default/lib/efz/ebin"|filelib:wildcard("_build/default/lib/*/ebin")]),
    {ok,_}=application:ensure_all_started(crypto),
    Old=code:get_coverage_mode(),
    Tmp=filename:join("/tmp","efz-native-cowboy-profile-"++integer_to_list(erlang:unique_integer([positive]))),
    ok=file:make_dir(Tmp),
    try
        Artifacts=[begin Src=filename:join(["_build/default/lib/cowboy/src",atom_to_list(M)++".erl"]),
                         {ok,A}=efz_cov_native_public:compile(Src,Tmp),A end || M<-?MODULES],
        {ok,Manifests}=efz_cov_native_public:preflight(Artifacts),
        Schema=efz_cov_native_public:prepare(Manifests),
        lists:foreach(fun(M)->
            Src=filename:join("test/targets/cowboy",atom_to_list(M)++".erl"),
            {ok,M,Beam}=compile:noenv_file(Src,[binary,debug_info]),
            {module,M}=code:load_binary(M,Src,Beam)
        end,[efz_cowboy_transport,efz_cowboy_stream,efz_cowboy_long_target]),
        ok=efz_cowboy_long_target:setup(),
        {ok,Input}=file:read_file("test/targets/cowboy/seeds/01-get-root.http"),
        Empty=efz_cov_native_public:empty(Schema),
        _=efz_cowboy_long_target:run(Input),
        {ok,_}=efz_cov_native_public:collect(Schema),
        lists:foreach(fun(_)->sample(Input,Schema,Empty,100) end,lists:seq(1,2)),
        Samples=[sample(Input,Schema,Empty,100)||_<-lists:seq(1,10)],
        Keys=[reset,execute,get_coverage,conversion,novelty_true,novelty_false,merge,full_cycle],
        Result=#{environment=>#{otp=>erlang:system_info(otp_release),
            erts=>erlang:system_info(version),architecture=>erlang:system_info(system_architecture),
            schedulers=>erlang:system_info(schedulers_online),cowboy_modules=>?MODULES,
            schema=>maps:get(fingerprint,Schema),total_lines=>maps:get(bits,Schema),
            input=>"01-get-root.http",warmup_samples=>2,timed_samples=>10,
            iterations_per_sample=>100},
            summary=>maps:from_list([{K,summarize([maps:get(K,S)/100||S<-Samples])}||K<-Keys])},
        ok=filelib:ensure_dir(Out),
        ok=file:write_file(Out,io_lib:format("~tp.~n",[Result])),
        io:format("~tp~n",[Result]),
        ok=efz_cowboy_long_target:teardown()
    after _=code:set_coverage_mode(Old) end;
main(_) -> erlang:error("usage: escript bench/otp_native_public_cowboy_profile.escript OUTPUT.term").

sample(Input,Schema,Empty,Iterations) ->
    Entries=maps:get(entries,Schema),
    lists:foldl(fun(_,Acc)->
        T0=erlang:monotonic_time(nanosecond),
        lists:foreach(fun({M,_,_,_})->ok=code:reset_coverage(M) end,Entries),
        T1=erlang:monotonic_time(nanosecond),
        {ok,{accepted,_}}=efz_cowboy_long_target:run(Input),
        T2=erlang:monotonic_time(nanosecond),
        Raw=[{M,code:get_coverage(line,M)}||{M,_,_,_}<-Entries],
        T3=erlang:monotonic_time(nanosecond),
        {ok,Bits}=efz_cov_native_public:convert_raw(Schema,Raw),
        T4=erlang:monotonic_time(nanosecond),
        true=efz_cov_native_public:has_new(Empty,Bits),
        T5=erlang:monotonic_time(nanosecond),
        false=efz_cov_native_public:has_new(Bits,Bits),
        T6=erlang:monotonic_time(nanosecond),
        _Merged=efz_cov_native_public:merge(Empty,Bits),
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
