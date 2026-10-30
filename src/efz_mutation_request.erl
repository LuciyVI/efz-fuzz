%% Disposable mutation VM; the C launcher owns process-group kill and reaping.
-module(efz_mutation_request).
-export([availability/0, start/4, cancel/2, run/3, start_test/4]).
-define(MAX_FRAME, 1200000).
-define(CLEANUP_MS, 3000).

%% The disposable Linux VM is part of the enabled provider contract. Check
%% these prerequisites during configuration, before any target is executed.
availability() ->
    case os:type() of
        {unix, linux} ->
            case {os:find_executable("erl"), os:find_executable("python3")} of
                {false, _} -> unavailable(erl_missing);
                {_, false} -> unavailable(python3_missing);
                _ ->
                    case launcher_candidates() of
                        [] -> unavailable(launcher_missing);
                        [Launcher | _] ->
                            case filelib:is_regular(filename:join(filename:dirname(Launcher),
                                                                  "efz_mutation_launcher.py")) of
                                true -> ok;
                                false -> unavailable(bootstrap_missing)
                            end
                    end
            end;
        _ -> unavailable(linux_required)
    end.

unavailable(Reason) -> {error, {provider_unavailable, Reason}}.

start(Owner, Input, Request, P) -> start_request(Owner, Input, Request, P, default).

%% Trusted injection is an explicit function argument, never config/recipe data.
start_test(Owner, {Input, Request}, P, Launch) when is_function(Launch, 3) ->
    start_request(Owner, Input, Request, P, Launch);
start_test(_, _, _, _) -> {error, invalid_test_launcher}.

start_request(Owner, Input, Request, P, Launch)
  when is_pid(Owner), is_binary(Input), byte_size(Input) =< 1048576,
       is_map(Request), is_map(P) ->
    Timeout = maps:get(timeout, P, 1000),
    case is_integer(Timeout) andalso Timeout > 0 andalso Timeout =< 60000 of
        true ->
            Started = erlang:monotonic_time(microsecond),
            Deadline = erlang:monotonic_time(millisecond) + Timeout,
            Ref = make_ref(),
            Pid = spawn(fun() -> guardian(Owner, Ref, Input, Request, P,
                                         Launch, Started, Deadline) end),
            {ok, Pid, Ref};
        false -> {error, invalid_provider_timeout}
    end;
start_request(_, _, _, _, _) -> {error, invalid_provider_request}.

cancel(Pid, Ref) when is_pid(Pid), is_reference(Ref) ->
    Pid ! {efz_mutation_cancel, Ref}, ok;
cancel(_, _) -> ok.

run(Input, Request, P) ->
    case start(self(), Input, Request, P) of
        {ok, Pid, Ref} ->
            Monitor = erlang:monitor(process, Pid),
            await_run(Pid, Ref, Monitor);
        {error, _} = Error -> Error
    end.

%% The local controller owns the job process and sends only runtime reference
%% tokens. Cancelling still waits for the original correlated reply, which is
%% emitted after the disposable VM and launcher have been reaped.
await_run(Pid, Ref, Monitor) ->
    receive
        {efz_mutation_reply, Ref, Result, _Runtime} ->
            erlang:demonitor(Monitor, [flush]), Result;
        {'DOWN', Monitor, process, Pid, _} ->
            {error, {infrastructure, provider_guardian_down}};
        {efz_mutation_cancel_run, CancelToken} when is_reference(CancelToken) ->
            ok = cancel(Pid, Ref),
            await_run(Pid, Ref, Monitor)
    end.

guardian(Owner, Ref, Input, Request, P, Launch, Started, Deadline) ->
    process_flag(trap_exit, true),
    Monitor = erlang:monitor(process, Owner),
    Base = #{owner => Owner, owner_monitor => Monitor, ref => Ref,
             started => Started, deadline => Deadline, phase => setup,
             deliver => true, port => undefined, socket => undefined,
             listener => undefined, dir => undefined, port_exit => false,
             cleanup => undefined, result => undefined, core_us => 0,
             os_pid => undefined, launcher_pid => undefined},
    _ = store(Base),
    try
        {module, efz_provider_port} = code:ensure_loaded(efz_provider_port),
        {module, efz_provider_wire} = code:ensure_loaded(efz_provider_wire),
        loop(initialize(Base, Input, Request, P, Launch))
    catch _:_ ->
        loop(begin_cleanup({error, {infrastructure, provider_setup_failed}}, get({?MODULE, state})))
    after
        close_all(get({?MODULE, state})),
        erlang:demonitor(Monitor, [flush]),
        erase({?MODULE, state})
    end.

store(S) -> put({?MODULE, state}, S), S.

initialize(S0, Input, Request, P, Launch) ->
    CorePath = path(maps:get(core_path, P)),
    {ok, Payload} = efz_provider_wire:encode(#{input => Input, request => Request,
        context => maps:get(core_context, P), identity => maps:get(core_identity, P)}),
    Nonce = crypto:strong_rand_bytes(32),
    Guardian = self(), Token = make_ref(),
    spawn(fun() -> directory_owner(Guardian, Token) end),
    S1 = await_directory(Token, S0),
    case maps:get(phase, S1) of
        cleanup -> S1;
        setup ->
            SocketPath = filename:join(maps:get(dir, S1), "socket"),
            {ok, Listener} = gen_tcp:listen(0, [binary, {packet, 4},
                {packet_size, ?MAX_FRAME}, {active, false}, {backlog, 1},
                {ifaddr, {local, SocketPath}}]),
            S2 = store(S1#{listener => Listener}),
            Ebin = filename:dirname(code:which(?MODULE)),
            Default = ["+S", "1:1", "+A", "1", "-noshell", "-noinput",
                "-pa", Ebin, CorePath, "-s", "efz_provider_port", "main",
                "-extra", SocketPath, binary_to_list(binary:encode_hex(Nonce)), CorePath],
            Args = case Launch of default -> Default;
                _ -> Launch(SocketPath, binary_to_list(binary:encode_hex(Nonce)), Default) end,
            true = valid_args(Args),
            Erl = os:find_executable("erl"), true = is_list(Erl),
            Python = os:find_executable("python3"), true = is_list(Python),
            Port = open_port({spawn_executable, Python},
                [binary, exit_status, use_stdio, stderr_to_stdout, {line, 16384},
                 {env, [{"ERL_CRASH_DUMP", "/dev/null"}]},
                 {args, ["-u", bootstrap(), launcher(), Erl | Args]}]),
            store(S2#{port => Port, phase => accept, payload => Payload,
                      nonce => Nonce, context => maps:get(core_context, P)})
    end.

path(B) when is_binary(B) -> path(binary_to_list(B));
path(P) when is_list(P), P =/= [], length(P) =< 4096 ->
    true = lists:all(fun(C) -> is_integer(C) andalso C > 0 andalso C =< 255 end, P),
    true = filename:pathtype(P) =:= absolute, P.

valid_args(Args) when is_list(Args), length(Args) =< 64 ->
    lists:all(fun(A) -> is_list(A) andalso length(A) =< 4096 andalso
        lists:all(fun(C) -> is_integer(C) andalso C > 0 andalso C =< 255 end, A) end, Args);
valid_args(_) -> false.

launcher() ->
    [Found | _] = launcher_candidates(), Found.

launcher_candidates() ->
    Priv = case code:priv_dir(efz) of
        P when is_list(P) -> [filename:join(P, "efz_vm_launcher")]; _ -> [] end,
    Beam = filename:join([filename:dirname(code:which(?MODULE)), "..", "priv", "efz_vm_launcher"]),
    Fallback = case proplists:get_value(source, ?MODULE:module_info(compile)) of
        Source when is_list(Source) ->
            [filename:join([filename:dirname(filename:dirname(Source)), "priv", "efz_vm_launcher"])];
        _ -> []
    end,
    [F || F <- Priv ++ [Beam] ++ Fallback,
          filelib:is_regular(F), os:find_executable(F) =/= false].

%% OTP's erl_child_setup, rather than beam, is an open_port child's parent.
%% This fixed bootstrap makes the launcher's supplied parent its actual parent.
%% It proxies only the stop byte/EOF; C stdout goes directly to the port. Port
%% exit follows wait() of C, whose own confirmation follows VM/descendant reap.
bootstrap() -> filename:join(filename:dirname(launcher()), "efz_mutation_launcher.py").

%% Independent directory owner survives an untrappable guardian kill. Its
%% monitor exists before directory creation, so every exit path removes it.
directory_owner(Guardian, Token) ->
    Monitor = erlang:monitor(process, Guardian),
    try
        Dir = private_directory(4),
        Guardian ! {provider_directory, Token, Dir},
        receive {'DOWN', Monitor, process, Guardian, _} -> remove_directory(Dir) end
    catch _:_ -> Guardian ! {provider_directory_error, Token} end.

private_directory(0) -> error(directory_unavailable);
private_directory(Tries) ->
    Name = "/tmp/efz-provider-" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12))),
    case file:make_dir(Name) of
        ok -> case file:change_mode(Name, 8#700) of
            ok -> Name; _ -> _ = file:del_dir(Name), error(directory_permissions) end;
        {error, eexist} -> private_directory(Tries - 1);
        _ -> error(directory_unavailable)
    end.

await_directory(Token, S) ->
    Ref = maps:get(ref, S), Monitor = maps:get(owner_monitor, S),
    Wait = max(0, maps:get(deadline, S) - erlang:monotonic_time(millisecond)),
    receive
        {provider_directory, Token, Dir} -> store(S#{dir => Dir});
        {provider_directory_error, Token} -> error(directory_unavailable);
        {efz_mutation_cancel, Ref} -> begin_cleanup(cancelled, S);
        {'DOWN', Monitor, process, _, _} -> begin_cleanup(cancelled, S#{deliver => false})
    after Wait -> begin_cleanup({timeout, deadline}, S) end.

loop(S0) ->
    S = store(S0),
    case maps:get(phase, S) of
        cleanup -> cleanup_loop(S);
        accept -> accept_loop(S);
        _ -> active_loop(S)
    end.

accept_loop(S) ->
    case poll_control(S) of
        {changed, S1} -> loop(S1);
        none ->
            Remaining = maps:get(deadline, S) - erlang:monotonic_time(millisecond),
            case Remaining =< 0 of
                true -> loop(begin_cleanup({timeout, deadline}, S));
                false ->
                    case gen_tcp:accept(maps:get(listener, S), min(10, Remaining)) of
                        {ok, Socket} ->
                            gen_tcp:close(maps:get(listener, S)),
                            S1 = store(S#{socket => Socket, listener => undefined, phase => hello}),
                            ok = inet:setopts(Socket, [{active, once}, {send_timeout, 10},
                                                      {send_timeout_close, true}]),
                            loop(S1);
                        {error, timeout} -> loop(S);
                        {error, _} -> loop(begin_cleanup({error, provider_transport}, S))
                    end
            end
    end.

poll_control(S) ->
    Ref = maps:get(ref, S), Monitor = maps:get(owner_monitor, S), Port = maps:get(port, S),
    receive
        {efz_mutation_cancel, Ref} -> {changed, begin_cleanup(cancelled, S)};
        {'DOWN', Monitor, process, _, _} -> {changed, begin_cleanup(cancelled, S#{deliver => false})};
        {Port, {data, Data}} -> {changed, port_data(Data, S)};
        {Port, {exit_status, Status}} -> {changed, port_exit(Status, S)};
        {'EXIT', Port, _} -> {changed, S}
    after 0 -> none end.

active_loop(S) ->
    Remaining = maps:get(deadline, S) - erlang:monotonic_time(millisecond),
    case Remaining =< 0 of
        true -> loop(begin_cleanup({timeout, deadline}, S));
        false -> active_wait(S, Remaining)
    end.

active_wait(S, Remaining) ->
    Ref = maps:get(ref, S), Monitor = maps:get(owner_monitor, S),
    Port = maps:get(port, S), Socket = maps:get(socket, S),
    receive
        {efz_mutation_cancel, Ref} -> loop(begin_cleanup(cancelled, S));
        {'DOWN', Monitor, process, _, _} -> loop(begin_cleanup(cancelled, S#{deliver => false}));
        {Port, {data, Data}} -> loop(port_data(Data, S));
        {Port, {exit_status, Status}} -> loop(port_exit(Status, S));
        {'EXIT', Port, _} -> loop(S);
        {tcp, Socket, Bytes} -> loop(socket_frame(Bytes, S));
        {tcp_closed, Socket} -> loop(begin_cleanup({error, provider_closed}, S));
        {tcp_error, Socket, _} -> loop(begin_cleanup({error, provider_transport}, S))
    after Remaining -> loop(begin_cleanup({timeout, deadline}, S)) end.

socket_frame(Bytes, #{phase := hello} = S) ->
    case efz_provider_wire:decode(Bytes) of
        {ok, #{hello := Nonce} = Hello} when map_size(Hello) =:= 1 ->
            case Nonce =:= maps:get(nonce, S) of
                true -> case gen_tcp:send(maps:get(socket, S), maps:get(payload, S)) of
                    ok ->
                        ok = inet:setopts(maps:get(socket, S), [{active, once}]),
                        S#{phase => result};
                    _ -> begin_cleanup({error, provider_transport}, S)
                end;
                false -> begin_cleanup({error, provider_handshake}, S)
            end;
        _ -> begin_cleanup({error, provider_handshake}, S)
    end;
socket_frame(Bytes, #{phase := result} = S) ->
    case efz_provider_wire:decode(Bytes) of
        {ok, #{result := Result, core_us := CoreUs} = Reply}
          when map_size(Reply) =:= 2, is_integer(CoreUs), CoreUs >= 0, CoreUs < (1 bsl 63) ->
            case valid_result(Result, maps:get(context, S)) of
                true -> case erlang:monotonic_time(millisecond) < maps:get(deadline, S) of
                    true -> begin_cleanup(Result, S#{core_us => CoreUs});
                    false -> begin_cleanup({timeout, deadline}, S#{core_us => CoreUs})
                end;
                false -> begin_cleanup({error, invalid_provider_result}, S)
            end;
        _ -> begin_cleanup({error, invalid_provider_reply}, S)
    end.

valid_result({ok, Candidate, Meta}, #{limits := Limits}) ->
    is_binary(Candidate) andalso byte_size(Candidate) =< maps:get(output_bytes, Limits, 4096)
    andalso is_map(Meta) andalso efz_gleam_adapter:portable(Meta)
    andalso erlang:external_size(Meta) =< 4096;
valid_result({skip, Reason}, _) -> is_atom(Reason);
valid_result({error, Reason}, _) ->
    efz_gleam_adapter:portable(Reason) andalso erlang:external_size(Reason) =< 1024;
valid_result(_, _) -> false.

port_data({eol, Line}, S) ->
    case efz_control_json:decode(Line) of
        {ok, #{<<"pid">> := Pid, <<"launcher_pid">> := Launcher} = Ready}
          when map_size(Ready) =:= 2, is_integer(Pid), Pid > 0,
               is_integer(Launcher), Launcher > 0 -> S#{os_pid => Pid, launcher_pid => Launcher};
        {ok, #{<<"cleanup_confirmed">> := Confirmed, <<"exit_code">> := Exit,
               <<"signal">> := Signal}} when is_boolean(Confirmed), is_integer(Exit), is_integer(Signal) ->
            S#{cleanup => #{confirmed => Confirmed, exit_code => Exit, signal => Signal}};
        _ -> begin_cleanup({error, provider_launcher_protocol}, S)
    end;
port_data(_, S) -> begin_cleanup({error, provider_launcher_protocol}, S).

port_exit(Status, S) ->
    %% Socket frames and port exit evidence arrive on independent channels.
    %% Drain the ordered socket frames/close before classifying an early exit.
    S#{port_exit => true, port_status => Status}.

begin_cleanup(Result, #{phase := cleanup} = S) ->
    case Result of cancelled -> S#{result => cancelled}; _ -> S end;
begin_cleanup(Result, S) ->
    Port = maps:get(port, S),
    case is_port(Port) andalso not maps:get(port_exit, S) of
        true -> catch port_command(Port, <<0>>);
        false -> ok
    end,
    store(S#{phase => cleanup, result => Result,
             cleanup_deadline => erlang:monotonic_time(millisecond) + ?CLEANUP_MS}).

cleanup_loop(#{port := undefined} = S) -> finish(S, true);
cleanup_loop(#{port_exit := true, cleanup := #{confirmed := Confirmed}} = S) -> finish(S, Confirmed);
cleanup_loop(S) ->
    Remaining = maps:get(cleanup_deadline, S) - erlang:monotonic_time(millisecond),
    case Remaining =< 0 of
        true -> finish(S, false);
        false -> cleanup_wait(S, Remaining)
    end.

cleanup_wait(S, Remaining) ->
    Ref = maps:get(ref, S), Monitor = maps:get(owner_monitor, S),
    Port = maps:get(port, S), Socket = maps:get(socket, S),
    receive
        {efz_mutation_cancel, Ref} -> loop(S#{result => cancelled});
        {'DOWN', Monitor, process, _, _} -> loop(S#{deliver => false, result => cancelled});
        {Port, {data, Data}} -> loop(port_data(Data, S));
        {Port, {exit_status, Status}} -> loop(S#{port_exit => true, port_status => Status});
        {'EXIT', Port, _} -> loop(S);
        {tcp, Socket, _} -> loop(S);
        {tcp_closed, Socket} -> loop(S#{socket => undefined});
        {tcp_error, Socket, _} -> loop(S#{socket => undefined})
    after Remaining -> finish(S, false) end.

finish(S, Confirmed) ->
    close_all(S),
    Result = case Confirmed of
        true -> maps:get(result, S);
        false -> {error, {infrastructure, cleanup_unconfirmed}}
    end,
    Runtime0 = #{cleanup_confirmed => Confirmed,
        latency_us => max(0, erlang:monotonic_time(microsecond) - maps:get(started, S)),
        core_us => maps:get(core_us, S)},
    Runtime = maps:merge(Runtime0, maps:filter(fun(_, V) -> is_integer(V) end,
        maps:with([os_pid, launcher_pid], S))),
    _ = case maps:get(deliver, S) of
        true -> maps:get(owner, S) ! {efz_mutation_reply, maps:get(ref, S), Result, Runtime};
        false -> ok
    end,
    ok.

close_all(S) when is_map(S) ->
    lists:foreach(fun(K) -> case maps:get(K, S, undefined) of
        undefined -> ok; Socket -> catch gen_tcp:close(Socket) end end, [socket, listener]),
    case maps:get(port, S, undefined) of undefined -> ok; Port -> catch port_close(Port) end,
    case maps:get(dir, S, undefined) of undefined -> ok; Dir -> remove_directory(Dir) end;
close_all(_) -> ok.

remove_directory(Dir) ->
    _ = file:delete(filename:join(Dir, "socket")), _ = file:del_dir(Dir), ok.
