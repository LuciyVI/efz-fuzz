-module(efz_cowboy_long_target).
-export([setup/0, teardown/0, run/1]).
%% Cowboy's socket contract cannot describe this deterministic in-memory
%% transport. The runtime path is exercised by the Cowboy harness tests.
-dialyzer({nowarn_function, run/1}).

setup() ->
    Dispatch = cowboy_router:compile([{'_', [
        {"/", ?MODULE, #{}}, {"/api/:id", ?MODULE, #{}},
        {"/items/[...]", ?MODULE, #{}}, {'_', ?MODULE, #{}}
    ]}]),
    persistent_term:put({?MODULE, dispatch}, Dispatch),
    ok.

teardown() ->
    persistent_term:erase({?MODULE, dispatch}), ok.

run(Input) when is_binary(Input) ->
    Socket = make_ref(),
    self() ! {cowboy_bench_data, Socket, Input},
    %% Incomplete requests terminate immediately instead of waiting for an
    %% HTTP timeout. The close belongs to this one invocation only.
    self() ! {cowboy_bench_closed, Socket},
    Opts = #{stream_handlers => [efz_cowboy_stream], max_keepalive => 1,
             request_timeout => 1000, inactivity_timeout => 1000,
             linger_timeout => 0, protocols => [http],
             env => #{dispatch => persistent_term:get({?MODULE, dispatch})}},
    try
        cowboy_http:init(self(), cowboy_bench, Socket,
                         efz_cowboy_transport, undefined, Opts)
    catch
        exit:{shutdown, Reason} -> result(Reason)
    after
        erase(efz_cowboy_bench_result),
        receive {cowboy_bench_data, Socket, _} -> ok after 0 -> ok end,
        receive {cowboy_bench_closed, Socket} -> ok after 0 -> ok end
    end.

result(Reason) ->
    case get(efz_cowboy_bench_result) of
        {accepted, Bytes} when Reason =:= normal -> {ok, {accepted, Bytes}};
        {accepted, _} -> error({unexpected_cowboy_termination, Reason});
        rejected -> {ok, rejected};
        {unexpected, Class, Why, Stack} -> erlang:raise(Class, Why, Stack);
        undefined ->
            case Reason of
                {connection_error, _, _} -> {ok, rejected};
                {stream_error, _, _} -> {ok, rejected};
                {socket_error, closed, _} -> {ok, rejected};
                skip_body_unknown_length -> {ok, rejected};
                skip_body_too_large -> {ok, rejected};
                _ -> error({unexpected_cowboy_termination, Reason})
            end
    end.
