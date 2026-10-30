#!/usr/bin/env escript
-mode(compile).

main([Out]) ->
    true=code:add_patha("_build/default/lib/efz/ebin"),
    {ok,_}=application:ensure_all_started(crypto),
    Input = <<"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n">>,
    Seeds=[<<Input/binary,(integer_to_binary(I))/binary>> || I<-lists:seq(1,12)],
    {ok,Pid}=efz_corpus:start_link(Seeds,{1,2,3}),
    unlink(Pid),
    try
        Select=measure(10000,fun()->efz_corpus:select() end),
        Hash=measure(100000,fun()->crypto:hash(sha256,Input) end),
        Meta=measure(100000,fun()->term_to_binary(#{parent=>1,input_id=>crypto:hash(sha256,Input)}) end),
        Duplicate=measure(1000,fun()->efz_corpus:add(hd(Seeds),#{}) end),
        InMemory=measure(100,fun(I)->
            efz_corpus:add(<<Input/binary,"-",(integer_to_binary(I))/binary>>,#{}) end),
        {ok,C}=efz_config:prepare(#{target=>efz_noop_target,seeds=>[Input],coverage_backend=>none}),
        Identity=efz_corpus_store:identity(C),
        Dir=filename:join("/tmp","efz-corpus-v2-"++integer_to_list(erlang:unique_integer([positive]))),
        Store=#{dir=>Dir,identity=>Identity,max_input_bytes=>4096},
        try
            Disk=measure(30,fun(I)->
                efz_corpus_store:save(Store,<<Input/binary,"-",(integer_to_binary(I))/binary>>,I,#{}) end),
            DiskDuplicate=measure(30,fun()->efz_corpus_store:save(Store,<<Input/binary,"-1">>,1,#{}) end),
            Report=#{otp=>erlang:system_info(otp_release),
                     schedulers=>erlang:system_info(schedulers_online),
                     corpus_select=>Select,sha256=>Hash,metadata_encode=>Meta,
                     in_memory_duplicate=>Duplicate,in_memory_insert=>InMemory,
                     fsync_publish=>Disk,disk_duplicate=>DiskDuplicate},
            ok=filelib:ensure_dir(Out),
            ok=file:write_file(Out,io_lib:format("~tp.~n",[Report])),
            io:format("~tp~n",[Report])
        after file:del_dir_r(Dir) end
    after exit(Pid,shutdown) end;
main(_) -> error("usage: escript bench/engine_corpus_micro.escript OUTPUT.term").

measure(N,Fun) when is_function(Fun,0) -> measure(N,fun(_)->Fun() end);
measure(N,Fun) when is_function(Fun,1) ->
    {reductions,R0}=process_info(self(),reductions),
    {GC0,_,_}=erlang:statistics(garbage_collection),
    T0=erlang:monotonic_time(microsecond),
    lists:foreach(fun(I)->_ = Fun(I) end,lists:seq(1,N)),
    Us=erlang:monotonic_time(microsecond)-T0,
    {reductions,R1}=process_info(self(),reductions),
    {GC1,_,_}=erlang:statistics(garbage_collection),
    #{calls=>N,total_us=>Us,us_per_call=>Us/N,
      caller_reductions_per_call=>(R1-R0)/N,vm_gc_delta=>GC1-GC0}.
