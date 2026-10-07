%% Storage experiment, deliberately separate from the production hook. All
%% dense accesses include an exact-identity ETS lookup; slots are never hashes.
-module(efz_hit_count_micro).
-export([run/1]).

run(Out) ->
    _ = application:ensure_all_started(crypto),
    Variants = [ets_set, ets_counter, dense_counters, dense_write_counters, dense_atomics],
    Rows = lists:append([matrix(N, Pattern, Variants) ||
        N <- [100,1000,10000,100000], Pattern <- [once, repeated]]),
    Concurrent = [concurrent(V) || V <- Variants],
    Result = #{environment => #{otp => erlang:system_info(otp_release),
        erts => erlang:system_info(version), schedulers => erlang:system_info(schedulers_online),
        architecture => erlang:system_info(system_architecture),
        word_bytes => erlang:system_info(wordsize), repeats => 5},
        rows => Rows, concurrent => Concurrent},
    ok = filelib:ensure_dir(filename:join(Out,"x")),
    ok = file:write_file(filename:join(Out,"micro.term"),term_to_binary(Result)),
    ok = file:write_file(filename:join(Out,"micro.txt"),io_lib:format("~tp.~n",[Result])),
    io:format("~s~n",[filename:join(Out,"micro.txt")]), Result.

matrix(N, Pattern, Variants) ->
    Build = crypto:hash(sha256, <<"benchmark-manifest">>),
    Ids = [{benchmark_target, Build, I} || I <- lists:seq(1,N)],
    {Used, Repeats} = case Pattern of once -> {Ids,1}; repeated -> {lists:sublist(Ids,10),1000} end,
    %% Warm all variants; alternate order between paired rounds.
    _ = [sample(V,Ids,Used,Repeats) || V <- Variants],
    Samples = lists:foldl(fun(Round, Acc) ->
        Order = case Round rem 2 of 0 -> lists:reverse(Variants); _ -> Variants end,
        lists:foldl(fun(V,A) -> A#{V=>[sample(V,Ids,Used,Repeats)|maps:get(V,A,[])]} end,Acc,Order)
    end, #{}, lists:seq(1,5)),
    [begin
        Ss=maps:get(V,Samples),
        Med=maps:from_list([{K,median([maps:get(K,S)||S<-Ss])} || K<-
            [hit_ns,snapshot_ns,reset_ns,setup_ns,close_ns,total_ns,storage_bytes,mapping_bytes]]),
        Row=Med#{variant=>V,probes=>N,pattern=>Pattern,hits=>length(Used)*Repeats,
                 ns_per_hit=>maps:get(hit_ns,Med)/(length(Used)*Repeats),samples=>Ss},
        io:format("~p ~p ~B: ~.1f ns/hit snapshot ~B us reset ~B us~n",
            [V,Pattern,N,maps:get(ns_per_hit,Row),maps:get(snapshot_ns,Med) div 1000,
             maps:get(reset_ns,Med) div 1000]), Row
    end || V<-Variants].

sample(V,Ids,Used,Repeats) ->
    erlang:garbage_collect(),
    {Setup,S}=timed(fun()->open(V,Ids) end),
    {Hit,ok}=timed(fun()->hits(Repeats,Used,S) end),
    {Snap,Rows}=timed(fun()->snapshot(S) end),
    Expected=case V of ets_set->1;_->Repeats end,
    true=Rows=:=lists:sort([{Id,Expected}||Id<-Used]),
    {Bytes,Mapping}=memory(S),
    {Reset,ok}=timed(fun()->reset(S) end),
    []=snapshot(S),
    {Close,ok}=timed(fun()->close(S) end),
    #{setup_ns=>Setup,hit_ns=>Hit,snapshot_ns=>Snap,reset_ns=>Reset,close_ns=>Close,
      total_ns=>Setup+Hit+Snap+Reset+Close,storage_bytes=>Bytes,mapping_bytes=>Mapping}.

open(V,_) when V=:=ets_set; V=:=ets_counter ->
    {V,ets:new(coverage_benchmark,[set,public])};
open(V,Ids) ->
    T=ets:new(prepared_slots,[set,public]),
    true=ets:insert(T,lists:zip(Ids,lists:seq(1,length(Ids)))),
    Ref=case V of
        dense_counters->counters:new(length(Ids),[atomics]);
        dense_write_counters->counters:new(length(Ids),[write_concurrency]);
        dense_atomics->atomics:new(length(Ids),[{signed,false}])
    end,
    {V,T,Ref,length(Ids)}.
hit(Id,{ets_set,T})->_=ets:insert_new(T,{{probe,Id}}),ok;
hit(Id,{ets_counter,T})->_=ets:update_counter(T,{probe,Id},{2,1},{{probe,Id},0}),ok;
hit(Id,{dense_atomics,T,R,_})->I=ets:lookup_element(T,Id,2),atomics:add(R,I,1);
hit(Id,{_,T,R,_})->I=ets:lookup_element(T,Id,2),counters:add(R,I,1).
hits(0,_,_)->ok;
hits(N,Ids,S)->lists:foreach(fun(Id)->hit(Id,S) end,Ids),hits(N-1,Ids,S).
snapshot({ets_set,T})->lists:sort([{Id,1}||{{probe,Id}}<-ets:tab2list(T)]);
snapshot({ets_counter,T})->lists:sort([{Id,C}||{{probe,Id},C}<-ets:tab2list(T)]);
snapshot({V,T,R,_})->lists:sort([{Id,C}||{Id,I}<-ets:tab2list(T),
    C<-[case V of dense_atomics->atomics:get(R,I);_->counters:get(R,I) end],C>0]).
reset({_,T})->ets:delete_all_objects(T),ok;
reset({V,_,R,N})->lists:foreach(fun(I)->case V of
    dense_atomics->atomics:put(R,I,0);_->counters:put(R,I,0) end end,lists:seq(1,N)),ok.
close({_,T})->ets:delete(T),ok;
close({_,T,_,_})->ets:delete(T),ok.
memory({_,T})->{ets:info(T,memory)*erlang:system_info(wordsize),0};
memory({V,T,R,_})->Info=case V of dense_atomics->atomics:info(R);_->counters:info(R) end,
    {maps:get(memory,Info),ets:info(T,memory)*erlang:system_info(wordsize)}.

concurrent(V)->
    Id={benchmark_target,crypto:hash(sha256,<<"concurrent">>),1},S=open(V,[Id]),
    {Ns,ok}=timed(fun()->
        Parent=self(), Ps=[spawn_monitor(fun()->receive go->hits(10000,[Id],S),Parent!{done,self()} end end)
            ||_<-lists:seq(1,4)],
        [P!go||{P,_}<-Ps],
        [receive {done,P}->ok end||{P,_}<-Ps],
        [receive {'DOWN',M,process,P,normal}->ok end||{P,M}<-Ps],ok
    end),
    Expected=case V of ets_set->1;_->40000 end,
    [{Id,Expected}]=snapshot(S),ok=close(S),
    #{variant=>V,writers=>4,hits=>40000,observed=>Expected,ns_per_hit=>Ns/40000}.
timed(F)->T=erlang:monotonic_time(nanosecond),R=F(),{erlang:monotonic_time(nanosecond)-T,R}.
median(Xs)->lists:nth(3,lists:sort(Xs)).
