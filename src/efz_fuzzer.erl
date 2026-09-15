-module(efz_fuzzer).
-behaviour(gen_server).
-export([start_link/1, stop/0, stats/0, await/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link(C0) ->
    case whereis(?MODULE) of
        undefined -> case efz_config:prepare(C0) of
            {ok, C} -> gen_server:start_link({local, ?MODULE}, ?MODULE, C, []);
            Error -> Error
        end;
        Pid -> {error, {already_started, Pid}}
    end.
stop() -> gen_server:stop(?MODULE).
stats() -> efz_stats:get().
await(Timeout) -> gen_server:call(?MODULE, await, Timeout).
init(C) ->
    process_flag(trap_exit, true),
    Store = maps:get(corpus_store, C, undefined),
    {ok, Corpus} = efz_corpus:start_link(maps:get(seeds, C), maps:get(selection_seed, C, undefined), Store, maps:get(max_input_bytes,C)),
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
    {ok, #{children => [Workers, Stats, Corpus], waiters => [], report => pending,
           worker => Worker, worker_monitor => WorkerRef,execution_context=>undefined,
           execution_identities=>maps:get(execution_identities,C),max_input_bytes=>maps:get(max_input_bytes,C)}}.
handle_call(await, From, #{report := pending, waiters := Ws} = S) ->
    {noreply, S#{waiters => [From | Ws]}};
handle_call(await, _, #{report := R} = S) -> {reply, R, S};
handle_call(_, _, S) -> {reply, ok, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info({execution_context,Worker,Context},#{worker:=Worker}=S)->
    {noreply,S#{execution_context=>Context}};
handle_info({campaign_done, Worker, Report}, #{worker := Worker, waiters := Ws} = S) ->
    lists:foreach(fun(W) -> gen_server:reply(W, Report) end, Ws),
    {noreply, S#{report => Report, waiters => []}};
handle_info({'DOWN', Ref, process, Worker, Reason},
            #{worker_monitor := Ref, worker := Worker, report := pending, waiters := Ws} = S) ->
    Why={worker_down,Reason},Primary=efz_stats:failure(Why),
    Base = #{status => {infrastructure_failure,Primary},worker_failure=>Why,
               stats => efz_stats:get(), corpus => efz_corpus:all(),
               execution_identities=>maps:get(execution_identities,S),max_input_bytes=>maps:get(max_input_bytes,S)},
    Report=case maps:get(execution_context,S) of undefined->Base;Ctx->Base#{failure_context=>Ctx} end,
    lists:foreach(fun(W) -> gen_server:reply(W, Report) end, Ws),
    {noreply, S#{report => Report, waiters => []}};
handle_info({'EXIT', Pid, Reason}, S) -> {stop, {campaign_child_exit, Pid, Reason}, S};
handle_info(_, S) -> {noreply, S}.
terminate(_, #{children := Children}) ->
    lists:foreach(fun(P) ->
        Ref = monitor(process, P), unlink(P), exit(P, shutdown),
        receive {'DOWN', Ref, process, P, _} -> ok end
    end, Children), ok.
code_change(_, S, _) -> {ok, S}.
