-module(efz_fuzzer).
-behaviour(gen_server).
-export([start_link/1, stop/0, request_stop/0, status/0, stats/0, await/1,
         monitor_snapshot/0, benchmark_snapshot/0, benchmark_coverage/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link(C0) ->
    case whereis(?MODULE) of
        undefined -> case efz_config:prepare(C0) of
            {ok, C} -> gen_server:start_link({local, ?MODULE}, ?MODULE, C, []);
            Error -> Error
        end;
        Pid -> {error, {already_started, Pid}}
    end.
request_stop()->gen_server:call(?MODULE,request_stop).
status()->gen_server:call(?MODULE,status).
stop() -> gen_server:stop(?MODULE).
stats() -> efz_stats:get().
%% A continuous campaign may outlive polling clients and their call timeouts.
%% Cancel timed-out calls explicitly; monitors clean up callers killed in await.
await(Timeout) ->
    Token = make_ref(),
    try gen_server:call(?MODULE, {await, Token}, Timeout)
    catch exit:Reason ->
        gen_server:cast(?MODULE, {cancel_await, Token}),
        exit(Reason)
    end.
%% Sampled by external benchmarks; never called from the execution hot path.
monitor_snapshot() -> gen_server:call(?MODULE,monitor_snapshot,15000).
benchmark_snapshot() -> gen_server:call(?MODULE, benchmark_snapshot, 15000).
benchmark_coverage() -> gen_server:call(?MODULE, benchmark_coverage, 15000).
init(C) ->
    process_flag(trap_exit, true),
    Store = maps:get(corpus_store, C, undefined),
    {ok, Corpus} = efz_corpus:start_link(maps:get(seeds, C), maps:get(selection_seed, C, undefined), Store, maps:get(max_input_bytes,C),maps:get(gleam_layer,C,false)),
    {ok, Stats} = efz_stats:start_link(),
    WorkerC = case Store of
        undefined -> C;
        _ ->
            lists:foreach(fun(D) -> logger:warning("EFZ corpus restore: ~tp", [D]) end, maps:get(diagnostics,Store)),
            C#{corpus_store=>maps:remove(restored,Store)}
    end,
    {ok, Workers} = efz_worker_sup:start_link(WorkerC#{coordinator => self()}),
    [{efz_worker, Worker, worker, _}] = supervisor:which_children(Workers),
    WorkerRef = monitor(process, Worker),
    {ok, #{children => [Workers, Stats, Corpus], waiters => #{}, report => pending,
           worker => Worker, worker_monitor => WorkerRef,execution_context=>undefined,
           stop_requested=>false,monitor_pending=>false,monitor_snapshot=>#{schema_version=>1,target=>maps:get(target,C),
             status=>running,max_iterations=>maps:get(max_iterations,C),elapsed_ms=>0,stats=>#{},last=>null,
             coverage_idle=>efz_coverage_idle:public(
                 efz_coverage_idle:new(maps:get(stop_after_no_new_coverage_seconds,C)),0),
             feature_stability=>efz_stability:public(efz_stability:new(
                 maps:get(runtime_oracles,C),{maps:get(coverage,C),maps:get(coverage_backend,C)}))},
           execution_identities=>maps:get(execution_identities,C),max_input_bytes=>maps:get(max_input_bytes,C)}}.
handle_call(request_stop,_,#{stop_requested:=true}=S)->{reply,ok,S};
handle_call(request_stop,_,#{report:=pending,worker:=W}=S)->
    gen_server:cast(W,request_stop),{reply,ok,S#{stop_requested=>true}};
handle_call(request_stop,_,S)->{reply,ok,S};
handle_call(status,_,#{report:=R}=S)->
    {reply,case R of pending->running;_->finished end,S};
handle_call({await, Token}, From = {Caller, _}, #{report := pending, waiters := Ws} = S) ->
    Ref = monitor(process, Caller),
    {noreply, S#{waiters => Ws#{Token => {From, Ref}}}};
handle_call({await, _}, _, #{report := R} = S) -> {reply, R, S};
handle_call(monitor_snapshot, _, #{worker:=Worker,report:=Report}=S) ->
    %% Never wait for a worker currently executing a slow target. Coalesce polls.
    Pending=maps:get(monitor_pending,S),
    Request=Report=:=pending andalso not Pending,
    case Request of true->gen_server:cast(Worker,monitor_sample);false->ok end,
    Cached=maps:get(monitor_snapshot,S),
    Reply=case Report of pending->Cached;_->Cached#{status=>maps:get(status,Report),
        stats=>maps:remove(primary_infrastructure_failure,maps:get(stats,Report)),
        feature_stability=>maps:get(feature_stability,Report,maps:get(feature_stability,Cached)),
        coverage_idle=>maps:get(coverage_idle,Report,maps:get(coverage_idle,Cached))} end,
    {reply,Reply,S#{monitor_pending=>Pending orelse Request}};
handle_call(benchmark_snapshot, _, #{worker := Worker, report := Report} = S) ->
    Reply = case Report of
        pending -> gen_server:call(Worker, benchmark_snapshot, 10000);
        _ -> #{stats => maps:get(stats, Report),
               coverage_count => length(maps:get(coverage, Report, [])),
               corpus_size => length(maps:get(corpus, Report, [])),
               status => maps:get(status,Report),
               failure_context => maps:get(failure_context,Report,undefined),
               completed => true}
    end,
    {reply, Reply, S};
handle_call(benchmark_coverage, _, #{worker := Worker, report := Report} = S) ->
    Reply = case Report of
        pending -> gen_server:call(Worker, benchmark_coverage, 10000);
        _ -> maps:get(coverage, Report, [])
    end,
    {reply, Reply, S};
handle_call(_, _, S) -> {reply, ok, S}.
handle_cast({cancel_await, Token}, #{waiters := Ws} = S) ->
    case maps:take(Token, Ws) of
        {{_, Ref}, Rest} -> demonitor(Ref, [flush]), {noreply, S#{waiters => Rest}};
        error -> {noreply, S}
    end;
handle_cast(_, S) -> {noreply, S}.
handle_info({monitor_sample,Worker,Snapshot},#{worker:=Worker}=S)->
    Old=maps:get(monitor_snapshot,S),
    {noreply,S#{monitor_snapshot=>newest_stability(Old,Snapshot),monitor_pending=>false}};
handle_info({feature_stability_progress,Worker,FS},#{worker:=Worker,report:=pending}=S)->
    Old=maps:get(monitor_snapshot,S),
    Fresh=newest_stability(Old,Old#{feature_stability=>FS}),
    {noreply,S#{monitor_snapshot=>Fresh}};
handle_info({execution_context,Worker,Context},#{worker:=Worker}=S)->
    {noreply,S#{execution_context=>Context}};
handle_info({campaign_done, Worker, Report}, #{worker := Worker, waiters := Ws} = S) ->
    reply_waiters(Ws, Report),
    {noreply, S#{report => Report, waiters => #{}}};
handle_info({'DOWN', Ref, process, Worker, Reason},
            #{worker_monitor := Ref, worker := Worker, report := pending, waiters := Ws} = S) ->
    Why={worker_down,Reason},Primary=efz_stats:failure(Why),
    Base = #{status => {infrastructure_failure,Primary},worker_failure=>Why,
               stats => efz_stats:get(), corpus => efz_corpus:all(),
               execution_identities=>maps:get(execution_identities,S),max_input_bytes=>maps:get(max_input_bytes,S)},
    Report=case maps:get(execution_context,S) of undefined->Base;Ctx->Base#{failure_context=>Ctx} end,
    reply_waiters(Ws, Report),
    {noreply, S#{report => Report, waiters => #{}}};
handle_info({'DOWN', Ref, process, _, _}, #{waiters := Ws} = S) ->
    {noreply, S#{waiters => maps:filter(fun(_, {_, R}) -> R =/= Ref end, Ws)}};
handle_info({'EXIT', Pid, Reason}, S) -> {stop, {campaign_child_exit, Pid, Reason}, S};
handle_info(_, S) -> {noreply, S}.
newest_stability(Old,New) ->
    A=maps:get(feature_stability,Old,#{}),B=maps:get(feature_stability,New,#{}),
    case maps:get(revision,A,0)>maps:get(revision,B,0) of
        true->New#{feature_stability=>A};false->New end.
terminate(_, #{children := Children}) ->
    lists:foreach(fun(P) ->
        Ref = monitor(process, P), unlink(P), exit(P, shutdown),
        receive {'DOWN', Ref, process, P, _} -> ok end
    end, Children), ok.
code_change(_, S, _) -> {ok, S}.

reply_waiters(Ws, Report) ->
    maps:foreach(fun(_, {From, Ref}) ->
        demonitor(Ref, [flush]), gen_server:reply(From, Report)
    end, Ws).
