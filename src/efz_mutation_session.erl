%% One persistent, externally supervised Erlang VM per campaign or local SDK
%% mutation session. The OS launcher remains the process-group watchdog.
-module(efz_mutation_session).
-behaviour(gen_server).
-export([open/2, open_test/3, submit/6, cancel/3, close/3, stats/2, run/5]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(MAX_FRAME, 1200000).
-define(MAX_INPUT, 1048576).
-define(MAX_REQUEST, 65536).

open(Owner, Provider) -> open_session(Owner, Provider, default).
open_test(Owner, Provider, Launch) when is_function(Launch, 3) ->
    open_session(Owner, Provider, Launch);
open_test(_, _, _) -> {error, invalid_test_launcher}.

open_session(Owner, Provider, Launch) when is_pid(Owner), is_map(Provider) ->
    case {efz_mutation_request:availability(), valid_provider(Provider)} of
        {ok, true} ->
            OpenRef = make_ref(), Caller = self(),
            case gen_server:start(?MODULE, {Owner, Provider, Launch, Caller, OpenRef}, []) of
                {ok, Pid} ->
                    Monitor = erlang:monitor(process, Pid),
                    Startup = maps:get(startup_timeout, Provider, 10000),
                    Cleanup = maps:get(cleanup_timeout, Provider, 3000),
                    Result = receive
                        {efz_mutation_session_open, OpenRef, Pid,
                         {ok, SessionRef, Runtime}} -> {ok, Pid, SessionRef, Runtime};
                        {efz_mutation_session_open, OpenRef, Pid, {error, Reason}} ->
                            {error, Reason};
                        {'DOWN', Monitor, process, Pid, _} ->
                            {error, {infrastructure, provider_startup_failed}}
                    after Startup + Cleanup + 3000 ->
                        gen_server:cast(Pid, {abort_open, OpenRef}),
                        {error, {infrastructure, provider_startup_timeout}}
                    end,
                    erlang:demonitor(Monitor, [flush]),
                    Result;
                {error, Reason} -> {error, {infrastructure, {provider_start, Reason}}}
            end;
        {{error, Reason}, _} -> {error, Reason};
        {_, false} -> {error, invalid_persistent_provider}
    end;
open_session(_, _, _) -> {error, invalid_persistent_provider}.

valid_provider(#{core_path := Path, core_identity := Identity, core_context := Context,
                 config_identity := ConfigId} = Provider) ->
    lists:member(maps:get(transport, Provider, disposable), [persistent, disposable]) andalso
    (is_list(Path) orelse is_binary(Path)) andalso
    efz_erlamsa:identity_valid(Identity) andalso is_map(Context) andalso
    is_binary(ConfigId) andalso byte_size(ConfigId) =:= 32 andalso
    integer(maps:get(timeout, Provider, 1000), 1, 60000) andalso
    integer(maps:get(startup_timeout, Provider, 10000), 1, 60000) andalso
    integer(maps:get(cleanup_timeout, Provider, 3000), 1, 30000) andalso
    integer(maps:get(max_requests, Provider, 10000), 1, 1000000);
valid_provider(_) -> false.

submit(Pid, SessionRef, ReplyTo, Input, Request, Timeout)
  when is_pid(Pid), is_reference(SessionRef), is_pid(ReplyTo), is_binary(Input),
       is_map(Request), is_integer(Timeout), Timeout > 0, Timeout =< 60000 ->
    gen_server:call(Pid, {submit, SessionRef, ReplyTo, Input, Request, Timeout}, 2000);
submit(_, _, _, _, _, _) -> {error, invalid_provider_request}.

cancel(Pid, SessionRef, RequestRef)
  when is_pid(Pid), is_reference(SessionRef), is_reference(RequestRef) ->
    gen_server:cast(Pid, {cancel, SessionRef, RequestRef}), ok;
cancel(_, _, _) -> ok.

close(Pid, SessionRef, Timeout)
  when is_pid(Pid), is_reference(SessionRef), is_integer(Timeout),
       Timeout >= 0, Timeout =< 30000 ->
    try gen_server:call(Pid, {close, SessionRef}, Timeout + 1500)
    catch exit:{timeout, _} -> {error, {infrastructure, provider_cleanup_timeout}};
          exit:_ -> {ok, #{state => down}}
    end;
close(_, _, _) -> {error, invalid_provider_session}.

stats(Pid, SessionRef) when is_pid(Pid), is_reference(SessionRef) ->
    try gen_server:call(Pid, {stats, SessionRef}, 1000)
    catch exit:_ -> #{state => down}
    end;
stats(_, _) -> #{state => down}.

run(Pid, SessionRef, Input, Request, Timeout) ->
    case submit(Pid, SessionRef, self(), Input, Request, Timeout) of
        {ok, Ref} -> await(Pid, SessionRef, Ref);
        {error, _} = Error -> Error
    end.

await(Pid, SessionRef, Ref) ->
    Monitor = erlang:monitor(process, Pid),
    receive
        {efz_mutation_reply, Ref, Result, Runtime} ->
            erlang:demonitor(Monitor, [flush]), {ok, Result, Runtime};
        {'DOWN', Monitor, process, Pid, _} ->
            {error, {infrastructure, provider_session_down}};
        {efz_mutation_cancel_run, Token} when is_reference(Token) ->
            _ = cancel(Pid, SessionRef, Ref), await_reply(Pid, Monitor, Ref)
    end.

await_reply(Pid, Monitor, Ref) ->
    receive
        {efz_mutation_reply, Ref, Result, Runtime} ->
            erlang:demonitor(Monitor, [flush]), {ok, Result, Runtime};
        {'DOWN', Monitor, process, Pid, _} ->
            {error, {infrastructure, provider_session_down}}
    end.

init({Owner, Provider, Launch, Caller, OpenRef}) ->
    process_flag(trap_exit, true),
    OwnerMonitor = erlang:monitor(process, Owner),
    State = #{owner => Owner, owner_monitor => OwnerMonitor, provider => Provider,
        launch => Launch, open_caller => Caller, open_ref => OpenRef,
        session_ref => make_ref(), phase => starting, started_us => now_us(),
        epoch => crypto:strong_rand_bytes(16), request_number => 1,
        vm_starts => 0, restarts => 0, completed_requests => 0,
        request_samples => [], startup_samples => [], recycle_samples => [],
        requests_this_vm => 0, recycle_pending => false, active => undefined,
        pending_request => undefined, close_from => undefined,
        timeout_count => 0, cancellation_count => 0, error_count => 0,
        socket => undefined, listener => undefined, port => undefined,
        dir => undefined, dir_owner => undefined, dir_token => undefined,
        os_pid => undefined, launcher_pid => undefined, cleanup => undefined,
        port_exit => false, cleanup_timer => undefined, startup_timer => undefined,
        startup_started_us => now_us(), initial_open => true, close_requested => false,
        open_notified => false,
        instance_cleanup_us => 0, last_cleanup_confirmed => false},
    self() ! start_vm,
    {ok, State};
init(_) -> {stop, invalid_provider_session}.

handle_call({submit, SessionRef, ReplyTo, Input, Request, Timeout}, _From, S)
  when SessionRef =:= map_get(session_ref, S) ->
    case validate_submission(ReplyTo, Input, Request, Timeout, S) of
        true -> accept_submission(ReplyTo, Input, Request, Timeout, S);
        {error, Reason} -> {reply, {error, Reason}, S}
    end;
handle_call({submit, _, _, _, _, _}, _From, S) ->
    {reply, {error, invalid_provider_session}, S};
handle_call({stats, SessionRef}, _From, S=#{session_ref := SessionRef}) ->
    {reply, public_stats(S), S};
handle_call({stats, _}, _From, S) -> {reply, #{state => down}, S};
handle_call({close, SessionRef}, From, S=#{session_ref := SessionRef}) ->
    close_request(From, S);
handle_call({close, _}, _From, S) ->
    {reply, {error, invalid_provider_session}, S};
handle_call(_, _From, S) -> {reply, {error, unsupported_request}, S}.

accept_submission(ReplyTo, Input, Request, Timeout, S=#{phase := ready,
                                                       recycle_pending := false}) ->
    Active = new_request(ReplyTo, Input, Request, Timeout, S),
    case dispatch_request(Active, S) of
        {ok, S1} -> {reply, {ok, maps:get(ref, Active)}, S1};
        {error, Reason, S1} -> {reply, {error, Reason}, S1}
    end;
accept_submission(ReplyTo, Input, Request, Timeout, S=#{phase := recycling,
                                                        pending_request := undefined}) ->
    Active = new_request(ReplyTo, Input, Request, Timeout, S),
    {reply, {ok, maps:get(ref, Active)}, S#{pending_request => Active}};
accept_submission(ReplyTo, Input, Request, Timeout,
                  S=#{phase := stopping, cleanup_kind := recycle,
                      pending_request := undefined}) ->
    Active = new_request(ReplyTo, Input, Request, Timeout, S),
    {reply, {ok, maps:get(ref, Active)}, S#{pending_request => Active}};
accept_submission(_ReplyTo, _Input, _Request, _Timeout, S) ->
    {reply, {error, busy}, S}.

validate_submission(ReplyTo, Input, Request, Timeout, S) ->
    Limits = maps:get(limits, maps:get(core_context, maps:get(provider, S))),
    try
        true = is_pid(ReplyTo),
        true = byte_size(Input) =< maps:get(input_bytes, Limits),
        true = erlang:external_size(Request) =< ?MAX_REQUEST,
        true = efz_gleam_adapter:portable(Request),
        true = integer(Timeout, 1, 60000),
        true
    catch _:_ -> {error, invalid_provider_request}
    end.

new_request(ReplyTo, Input, Request, Timeout, S) ->
    Ref = make_ref(), Epoch = maps:get(epoch, S), Number = maps:get(request_number, S),
    Monitor = erlang:monitor(process, ReplyTo),
    #{ref => Ref, reply_to => ReplyTo, reply_monitor => Monitor,
      input => Input, request => Request, request_number => Number, epoch => Epoch,
      submitted_us => now_us(), deadline_ms => now_ms() + Timeout,
      timer => erlang:send_after(Timeout, self(), {request_deadline, Epoch, Ref}),
      input_bytes => byte_size(Input)}.

dispatch_request(Active, S) ->
    Request = #{type => mutate, epoch => maps:get(epoch, Active),
        request_number => maps:get(request_number, Active),
        context_id => maps:get(config_identity, maps:get(core_context,
                                                         maps:get(provider, S))),
        input => maps:get(input, Active), request => maps:get(request, Active)},
    case send_frame(maps:get(socket, S), Request) of
        {ok, EncodeUs, SendUs, FrameBytes} ->
            {ok, S#{phase => busy, active => Active#{encode_us => EncodeUs,
                send_us => SendUs, request_frame_bytes => FrameBytes}}};
        {error, _} -> {error, {infrastructure, provider_transport},
                       S#{active => Active}}
    end.

handle_cast({cancel, SessionRef, Ref}, S=#{session_ref := SessionRef}) ->
    case maps:get(active, S, undefined) of
        #{ref := Ref} -> {noreply, begin_failure(cancelled, S)};
        _ -> case maps:get(pending_request, S, undefined) of
            #{ref := Ref} = Pending ->
                reply_request(Pending, cancelled,
                    #{request_total_us => max(0, now_us() - maps:get(submitted_us, Pending))}),
                {noreply, S#{pending_request => undefined}};
            _ -> {noreply, S}
        end
    end;
handle_cast({abort_open, OpenRef}, S=#{open_ref := OpenRef}) ->
    {noreply, begin_failure({error, provider_startup_timeout},
        S#{open_notified => true, close_requested => true})};
handle_cast(_, S) -> {noreply, S}.

close_request(_From, S=#{phase := down}) -> {reply, {ok, public_stats(S)}, S};
close_request(From, S=#{phase := stopping, cleanup_kind := recycle}) ->
    close_recycling(From,S);
close_request(From, S=#{phase := stopping}) ->
    {noreply, S#{close_from => From}};
close_request(From, S=#{phase := ready}) ->
    self() ! graceful_stop,
    {noreply, S#{phase => stopping, close_from => From, cleanup_kind => close,
                 cleanup_started_us => now_us()}};
close_request(From, S=#{phase := busy}) ->
    {noreply, begin_failure(cancelled, S#{close_from => From, close_requested => true,
                                         cleanup_kind => close})};
close_request(From, S=#{phase := recycling}) ->
    close_recycling(From,S);
close_request(From, S) ->
    {noreply, begin_failure({error, provider_session_closed},
                            S#{close_from => From, close_requested => true})}.

close_recycling(From,S) ->
    case maps:get(pending_request, S, undefined) of
        Pending when is_map(Pending) ->
            cancel_timer(maps:get(timer, Pending)),
            reply_request(Pending, cancelled, #{cleanup_confirmed => false}),
            {noreply, S#{close_from => From, close_requested => true,
                         pending_request => undefined}};
        _ -> {noreply, S#{close_from => From, close_requested => true}}
    end.

handle_info(start_vm, S) -> start_vm(S);
handle_info({startup_deadline, Epoch}, S=#{epoch := Epoch, phase := Phase})
  when Phase =:= starting; Phase =:= accepting; Phase =:= hello;
       Phase =:= starting_handshake -> startup_failed(startup_timeout, S);
handle_info(accept_poll, S=#{phase := accepting}) -> accept_poll(S);
handle_info({tcp, Socket, Bytes}, S=#{socket := Socket}) -> socket_frame(Bytes, S);
handle_info({tcp_closed, Socket}, S=#{socket := Socket}) ->
    case maps:get(phase, S) of
        stopping -> maybe_finish_instance(S#{socket => undefined});
        _ -> {noreply, begin_failure({error, provider_closed}, S#{socket => undefined})}
    end;
handle_info({tcp_error, Socket, Reason}, S=#{socket := Socket}) ->
    {noreply, begin_failure({error, {provider_transport, Reason}}, S#{socket => undefined})};
handle_info({Port, {data, {eol, Line}}}, S=#{port := Port}) ->
    port_line(Line, S);
handle_info({Port, {data, _}}, S=#{port := Port}) ->
    {noreply, begin_failure({error, provider_launcher_protocol}, S)};
handle_info({Port, {exit_status, Status}}, S=#{port := Port}) ->
    maybe_finish_instance(S#{port_exit => true, port_status => Status});
handle_info({'EXIT', Port, _}, S=#{port := Port}) -> {noreply, S};
handle_info({request_deadline, Epoch, Ref}, S) ->
    case maps:get(active, S, undefined) of
        #{ref := Ref, epoch := Epoch, deadline_ms := Deadline} ->
            case Deadline =< now_ms() of
                true -> {noreply, begin_failure({timeout, deadline}, S)};
                false -> {noreply, S}
            end;
        _ -> case maps:get(pending_request, S, undefined) of
            #{ref := Ref, epoch := Epoch, deadline_ms := Deadline} ->
                case Deadline =< now_ms() of
                    true ->
                        Pending = maps:get(pending_request, S),
                        reply_request(Pending, {timeout, recycle_deadline},
                            #{request_total_us => max(0, now_us() -
                                maps:get(submitted_us, Pending))}),
                        {noreply, S#{pending_request => undefined}};
                    false -> {noreply, S}
                end;
            _ -> {noreply, S}
        end
    end;
handle_info(request_deadline, S) -> {noreply, S};
handle_info(recycle_vm, S=#{phase := recycling}) -> begin_recycle(S);
handle_info(graceful_stop, S=#{phase := stopping}) -> graceful_stop(S);
handle_info(cleanup_deadline, S=#{phase := stopping}) -> cleanup_deadline(S);
handle_info(hard_cleanup_deadline, S=#{phase := stopping}) -> cleanup_unconfirmed(S);
handle_info({session_directory, Token, Dir, OwnerPid}, S=#{dir_token := Token}) ->
    create_vm(Dir, OwnerPid, Token, S#{dir => Dir, dir_owner => OwnerPid});
handle_info({session_directory_error, Token}, S=#{dir_token := Token}) ->
    startup_failed(directory_unavailable, S);
handle_info({session_directory_cleaned, Token}, S=#{dir_token := Token}) ->
    cleanup_complete(S);
handle_info(directory_cleanup_deadline, S=#{phase := cleaning_directory}) ->
    remove_directory(maps:get(dir, S, undefined)),
    cleanup_finish(S#{directory_cleanup_forced => true});
handle_info({'DOWN', Monitor, process, Owner, _},
            S=#{owner_monitor := Monitor, owner := Owner}) ->
    {noreply, begin_failure(owner_down, S#{close_requested => true})};
handle_info({'DOWN', Monitor, process, ReplyTo, _}, S=#{active := Active})
  when is_map(Active) ->
    case {maps:get(reply_monitor, Active, undefined), maps:get(reply_to, Active, undefined)} of
        {Monitor, ReplyTo} -> {noreply, begin_failure(cancelled, S)};
        _ -> {noreply, S}
    end;
handle_info({'DOWN', _Monitor, process, _Pid, _}, S) -> {noreply, S};
handle_info(_, S) -> {noreply, S}.

start_vm(S0) ->
    Epoch = crypto:strong_rand_bytes(16),
    Token = make_ref(),
    Manager = self(),
    Owner = spawn(fun() -> session_directory_owner(Manager, Token) end),
    Timeout = maps:get(startup_timeout, maps:get(provider, S0), 10000),
    Timer = erlang:send_after(Timeout, self(), {startup_deadline, Epoch}),
    S = S0#{phase => starting, epoch => Epoch, startup_started_us => now_us(),
            port_exit => false, cleanup => undefined, socket => undefined,
            listener => undefined, port => undefined, os_pid => undefined,
            launcher_pid => undefined, force_sent => false,
            dir_token => Token, dir_owner => Owner, startup_timer => Timer},
    {noreply, S}.

create_vm(Dir, DirOwner, Token, S) ->
    try
        CorePath = path(maps:get(core_path, maps:get(provider, S))),
        SocketPath = filename:join(Dir, "socket"),
        {ok, Listener} = gen_tcp:listen(0, [binary, {packet, 4},
            {packet_size, ?MAX_FRAME}, {active, false}, {backlog, 1},
            {ifaddr, {local, SocketPath}}]),
        Nonce = crypto:strong_rand_bytes(32),
        Ebin = filename:dirname(code:which(efz_provider_port)),
        Default = ["+S", "1:1", "+A", "1", "-noshell", "-noinput",
            "-pa", Ebin, CorePath, "-s", "efz_provider_port", "persistent_main",
            "-extra", SocketPath, binary_to_list(binary:encode_hex(Nonce)), CorePath],
        Launch = maps:get(launch, S),
        Args = case Launch of default -> Default;
            _ -> Launch(SocketPath, binary_to_list(binary:encode_hex(Nonce)), Default) end,
        true = valid_args(Args),
        Erl = os:find_executable("erl"), true = is_list(Erl),
        Python = os:find_executable("python3"), true = is_list(Python),
        Port = open_port({spawn_executable, Python},
            [binary, exit_status, use_stdio, stderr_to_stdout, {line, 16384},
             {env, [{"ERL_CRASH_DUMP", "/dev/null"}]},
             {args, ["-u", efz_mutation_request:bootstrap_path(),
                     efz_mutation_request:launcher_path(), Erl | Args]}]),
        erlang:send_after(0, self(), accept_poll),
        {noreply, S#{phase => accepting, listener => Listener, port => Port,
            nonce => Nonce, dir => Dir, dir_owner => DirOwner, dir_token => Token,
            requests_this_vm => 0}}
    catch Class:Reason:Stack ->
        _ = catch gen_tcp:close(maps:get(listener, S, undefined)),
        Owner = DirOwner, Owner ! {session_directory_cleanup, Token},
        {noreply, begin_failure({startup_error,
                                {provider_setup_failed, Class, bounded_reason(Reason),
                                 lists:sublist(Stack, 4)}},
            S#{dir => Dir, dir_owner => DirOwner, dir_token => Token})}
    end.

accept_poll(S) ->
    case gen_tcp:accept(maps:get(listener, S), 0) of
        {ok, Socket} ->
            _ = catch gen_tcp:close(maps:get(listener, S)),
            ok = inet:setopts(Socket, [{active, once}, {send_timeout, 1000},
                                       {send_timeout_close, true}]),
            {noreply, S#{phase => hello, listener => undefined, socket => Socket}};
        {error, timeout} -> erlang:send_after(10, self(), accept_poll), {noreply, S};
        {error, Reason} -> startup_failed({listen, Reason}, S)
    end.

socket_frame(Bytes, S=#{phase := hello}) ->
    case efz_provider_wire:decode(Bytes) of
        {ok, #{hello := Nonce} = Hello} when map_size(Hello) =:= 1 ->
            case Nonce =:= maps:get(nonce, S) of
                true -> send_initialize(S);
                false -> startup_failed(provider_handshake, S)
            end;
        _ -> startup_failed(provider_handshake, S)
    end;
socket_frame(Bytes, S=#{phase := starting_handshake}) ->
    DecodeStarted = now_us(),
    case efz_provider_wire:decode(Bytes) of
        {ok, #{type := ready, status := ok, epoch := Epoch,
               identity := Identity, context_id := ContextId,
               prepare_timing := PrepareTiming} = Reply}
          when map_size(Reply) =:= 6, Epoch =:= map_get(epoch, S),
               is_map(Identity), is_binary(ContextId), is_map(PrepareTiming) ->
            P = maps:get(provider, S),
            ExpectedContext = maps:get(config_identity, maps:get(core_context, P)),
            case Identity =:= maps:get(core_identity, P) andalso
                 ContextId =:= ExpectedContext of
                true -> startup_ready(PrepareTiming, max(0, now_us() - DecodeStarted), S);
                false -> startup_failed(version_mismatch, S)
            end;
        {ok, #{type := ready, status := error, reason := Reason}} ->
            startup_failed(bounded_reason(Reason), S);
        _ -> startup_failed(provider_handshake, S)
    end;
socket_frame(Bytes, S=#{phase := busy, active := Active}) when is_map(Active) ->
    request_frame(Bytes, Active, S);
socket_frame(Bytes, S=#{phase := stopping}) ->
    case efz_provider_wire:decode(Bytes) of
        {ok, #{type := stopped, epoch := Epoch} = Reply}
          when map_size(Reply) =:= 2, Epoch =:= map_get(epoch, S) ->
            _ = gen_tcp:close(maps:get(socket, S)),
            maybe_finish_instance(S#{socket => undefined, stop_ack => true});
        _ -> maybe_finish_instance(begin_force_stop(S))
    end;
socket_frame(_, S) -> {noreply, begin_failure({error, invalid_provider_reply}, S)}.

send_initialize(S) ->
    P = maps:get(provider, S), Context = maps:get(core_context, P),
    Message = #{type => initialize, epoch => maps:get(epoch, S),
        request_number => maps:get(request_number, S),
        options => maps:get(options, P), limits => maps:get(limits, P),
        identity => maps:get(core_identity, P),
        context_id => maps:get(config_identity, Context)},
    case send_frame(maps:get(socket, S), Message) of
        {ok, _EncodeUs, _SendUs, _Bytes} ->
            ok = inet:setopts(maps:get(socket, S), [{active, once}]),
            {noreply, S#{phase => starting_handshake}};
        {error, _} -> startup_failed(provider_transport, S)
    end.

startup_ready(PrepareTiming, DecodeUs, S0) ->
    cancel_timer(maps:get(startup_timer, S0, undefined)),
    ok = inet:setopts(maps:get(socket, S0), [{active, once}]),
    StartupUs = max(0, now_us() - maps:get(startup_started_us, S0)),
    StartedCount = maps:get(vm_starts, S0) + 1,
    Runtime = #{worker_startup_us => StartupUs,
        handshake_prepare_us => maps:get(prepare_total_us, PrepareTiming, 0),
        identity_check_us => maps:get(identity_check_us, PrepareTiming, 0),
        core_prepare_us => maps:get(core_prepare_us, PrepareTiming, 0),
        recycle_cleanup_us => maps:get(last_recycle_cleanup_us, S0, 0),
        handshake_decode_us => DecodeUs, vm_starts => StartedCount,
        restarts => maps:get(restarts, S0), epoch => maps:get(epoch, S0)},
    S1 = add_startup(Runtime, S0#{phase => ready, vm_starts => StartedCount,
        last_cleanup_confirmed => true, startup_timer => undefined}),
    case maps:get(initial_open, S1) of
        true ->
            Caller = maps:get(open_caller, S1), OpenRef = maps:get(open_ref, S1),
            Caller ! {efz_mutation_session_open, OpenRef, self(),
                {ok, maps:get(session_ref, S1), Runtime}},
            {noreply, S1#{initial_open => false, open_notified => true}};
        false ->
            maps:get(owner, S1) ! {efz_mutation_session_event,
                maps:get(session_ref, S1), Runtime#{type => recycle}},
            case maps:get(close_requested, S1) of
                true -> self() ! graceful_stop, {noreply, S1#{phase => stopping}};
                false -> dispatch_pending(S1)
            end
    end.

request_frame(Bytes, Active, S) ->
    DecodeStarted = now_us(),
    case efz_provider_wire:decode(Bytes) of
        {ok, #{type := reply, epoch := Epoch, request_number := Number,
               result := Result0, core_us := CoreUs,
               provider_encode_us := ProviderEncodeUs,
               request_decode_us := RequestDecodeUs,
               request_validation_us := RequestValidationUs,
               identity_check_us := IdentityUs, direct_core_mutation_us := DirectCoreUs,
               result_validation_us := ResultValidationUs,
               request_frame_bytes := RequestFrameBytes, input_bytes := InputBytes,
               output_bytes := OutputBytes} = Reply}
          when map_size(Reply) =:= 14, Epoch =:= map_get(epoch, S),
               Number =:= map_get(request_number, Active),
               is_integer(CoreUs), CoreUs >= 0,
               is_integer(ProviderEncodeUs), ProviderEncodeUs >= 0,
               is_integer(RequestDecodeUs), RequestDecodeUs >= 0,
               is_integer(RequestValidationUs), RequestValidationUs >= 0,
               is_integer(IdentityUs), IdentityUs >= 0,
               is_integer(DirectCoreUs), DirectCoreUs >= 0,
               is_integer(ResultValidationUs), ResultValidationUs >= 0,
               is_integer(RequestFrameBytes), RequestFrameBytes >= 0,
               is_integer(InputBytes), InputBytes >= 0,
               is_integer(OutputBytes), OutputBytes >= 0 ->
            case now_ms() < maps:get(deadline_ms, Active) of
                false -> {noreply, begin_failure({timeout, deadline}, S)};
                true ->
                    Result = validate_result(Result0,
                        maps:get(core_context, maps:get(provider, S))),
                    case Result of
                        {error, invalid_provider_result} ->
                            {noreply, begin_failure({error, invalid_provider_result}, S)};
                        _ ->
                            cancel_timer(maps:get(timer, Active)),
                            erlang:demonitor(maps:get(reply_monitor, Active), [flush]),
                            Runtime = #{request_total_us => max(0, now_us() -
                                maps:get(submitted_us, Active)), core_us => CoreUs,
                                identity_check_us => IdentityUs,
                                direct_core_mutation_us => DirectCoreUs,
                                provider_encode_us => ProviderEncodeUs,
                                request_decode_us => RequestDecodeUs,
                                request_validation_us => RequestValidationUs,
                                result_validation_us => ResultValidationUs,
                                parent_encode_us => maps:get(encode_us, Active),
                                parent_send_us => maps:get(send_us, Active),
                                parent_decode_us => max(0, now_us() - DecodeStarted),
                                request_frame_bytes => RequestFrameBytes,
                                response_frame_bytes => byte_size(Bytes),
                                input_bytes => InputBytes, output_bytes => OutputBytes,
                                epoch => Epoch, request_number => Number,
                                vm_start_number => maps:get(vm_starts, S),
                                requests_per_vm => maps:get(requests_this_vm, S) + 1,
                                request_process_exit_confirmed => true},
                            reply_request(Active, Result, Runtime),
                            ok = inet:setopts(maps:get(socket, S), [{active, once}]),
                            Completed = maps:get(completed_requests, S) + 1,
                            PerVm = maps:get(requests_this_vm, S) + 1,
                            Recycle = PerVm >= maps:get(max_requests,
                                maps:get(provider, S), 10000),
                            Next0 = S#{phase => ready, active => undefined,
                                completed_requests => Completed,
                                requests_this_vm => PerVm,
                                request_number => Number + 1,
                                recycle_pending => false},
                            Next = case Recycle of
                                true -> self() ! recycle_vm,
                                    Next0#{phase => recycling};
                                false -> Next0
                            end,
                            {noreply, record_request(Runtime, Next)}
                    end
            end;
        _ -> {noreply, begin_failure({error, invalid_provider_reply}, S)}
    end.

dispatch_pending(S=#{pending_request := undefined}) -> {noreply, S#{phase => ready}};
dispatch_pending(S=#{pending_request := Pending}) ->
    case now_ms() < maps:get(deadline_ms, Pending) of
        false ->
            cancel_timer(maps:get(timer, Pending)),
            reply_request(Pending, {timeout, recycle_deadline},
                #{request_total_us => max(0, now_us() - maps:get(submitted_us, Pending)),
                  cleanup_confirmed => true}),
            {noreply, S#{phase => ready, pending_request => undefined,
                         recycle_pending => false}};
        true ->
            %% A request submitted while the old VM is stopping was correlated
            %% with that epoch. Bind it to the newly handshaken epoch and
            %% re-arm its original absolute deadline before sending it.
            Epoch = maps:get(epoch, S), Number = maps:get(request_number, S),
            cancel_timer(maps:get(timer, Pending, undefined)),
            Remaining = max(0, maps:get(deadline_ms, Pending) - now_ms()),
            Timer = erlang:send_after(Remaining, self(),
                {request_deadline, Epoch, maps:get(ref, Pending)}),
            Bound = Pending#{epoch => Epoch, request_number => Number, timer => Timer},
            case dispatch_request(Bound, S#{pending_request => undefined}) of
                {ok, S1} -> {noreply, S1#{phase => busy, active =>
                    maps:merge(Bound, maps:get(active, S1, #{}))}};
                {error, Reason, S1} ->
                    reply_request(Pending, {error, Reason}, #{}),
                    {noreply, begin_failure({error, provider_transport},
                                            S1#{pending_request => undefined})}
            end
    end.

code_change(_, S, _) -> {ok, S}.

terminate(_, S) ->
    close_instance(S),
    _ = case maps:get(dir_owner, S, undefined) of
        Pid when is_pid(Pid) -> Pid ! {session_directory_cleanup, maps:get(dir_token, S)};
        _ -> ok
    end,
    case maps:get(owner_monitor, S, undefined) of
        Ref when is_reference(Ref) -> erlang:demonitor(Ref, [flush]);
        _ -> ok
    end,
    ok.

integer(Value, Minimum, Maximum) ->
    is_integer(Value) andalso Value >= Minimum andalso Value =< Maximum.

now_us() -> erlang:monotonic_time(microsecond).
now_ms() -> erlang:monotonic_time(millisecond).

path(Bin) when is_binary(Bin) -> path(binary_to_list(Bin));
path(Path) when is_list(Path), Path =/= [], length(Path) =< 4096 ->
    true = lists:all(fun(C) -> is_integer(C) andalso C > 0 andalso C =< 255 end, Path),
    true = filename:pathtype(Path) =:= absolute,
    Path;
path(_) -> error(invalid_core_path).

valid_args(Args) when is_list(Args), length(Args) =< 64 ->
    lists:all(fun(A) -> is_list(A) andalso A =/= [] andalso length(A) =< 4096
        andalso lists:all(fun(C) -> is_integer(C) andalso C > 0 andalso C =< 255 end, A)
    end, Args);
valid_args(_) -> false.

session_directory_owner(Manager, Token) ->
    Monitor = erlang:monitor(process, Manager),
    try
        Dir = private_directory(4),
        Manager ! {session_directory, Token, Dir, self()},
        receive
            {session_directory_cleanup, Token} ->
                remove_directory(Dir),
                Manager ! {session_directory_cleaned, Token};
            {'DOWN', Monitor, process, Manager, _} -> remove_directory(Dir)
        end
    catch _:_ -> Manager ! {session_directory_error, Token} end.

private_directory(0) -> error(directory_unavailable);
private_directory(Tries) ->
    Name = "/tmp/efz-persistent-" ++
        binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(12))),
    case file:make_dir(Name) of
        ok ->
            case file:change_mode(Name, 8#700) of
                ok -> Name;
                _ -> _ = file:del_dir(Name), error(directory_permissions)
            end;
        {error, eexist} -> private_directory(Tries - 1);
        _ -> error(directory_unavailable)
    end.

remove_directory(undefined) -> ok;
remove_directory(Dir) ->
    _ = file:delete(filename:join(Dir, "socket")),
    _ = file:del_dir(Dir),
    ok.

send_frame(Socket, Message) when is_port(Socket) ->
    Started = now_us(),
    case efz_provider_wire:encode(Message) of
        {ok, Bytes} ->
            EncodeUs = max(0, now_us() - Started),
            SendStarted = now_us(),
            case gen_tcp:send(Socket, Bytes) of
                ok -> {ok, EncodeUs, max(0, now_us() - SendStarted), byte_size(Bytes)};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} -> {error, Reason}
    end;
send_frame(_, _) -> {error, socket_down}.

cancel_timer(undefined) -> ok;
cancel_timer(Ref) -> _ = erlang:cancel_timer(Ref), ok.

reply_request(Request, Result, Runtime0) ->
    cancel_timer(maps:get(timer, Request, undefined)),
    case maps:get(reply_monitor, Request, undefined) of
        Ref when is_reference(Ref) -> erlang:demonitor(Ref, [flush]);
        _ -> ok
    end,
    Runtime = maps:merge(#{request_total_us => max(0,
        now_us() - maps:get(submitted_us, Request))}, Runtime0),
    maps:get(reply_to, Request) ! {efz_mutation_reply, maps:get(ref, Request), Result, Runtime},
    ok.

validate_result({ok, Candidate, Metadata} = Result, Context)
  when is_binary(Candidate), is_map(Metadata) ->
    Limits = maps:get(limits, Context),
    case byte_size(Candidate) =< maps:get(output_bytes, Limits) andalso
         erlang:external_size(Metadata) =< 65536 andalso
         efz_gleam_adapter:portable(Metadata) of
        true -> Result;
        false -> {error, invalid_provider_result}
    end;
validate_result({skip, Reason} = Result, _) when is_atom(Reason) -> Result;
validate_result({error, Reason} = Result, _) ->
    case efz_gleam_adapter:portable(Reason) andalso erlang:external_size(Reason) =< 1024 of
        true -> Result;
        false -> {error, invalid_provider_result}
    end;
validate_result(_, _) -> {error, invalid_provider_result}.

port_line(Line, S) ->
    case efz_control_json:decode(Line) of
        {ok, #{<<"pid">> := Pid, <<"launcher_pid">> := Launcher} = Ready}
          when map_size(Ready) =:= 2, is_integer(Pid), Pid > 0,
               is_integer(Launcher), Launcher > 0 ->
            {noreply, S#{os_pid => Pid, launcher_pid => Launcher}};
        {ok, #{<<"cleanup_confirmed">> := Confirmed, <<"exit_code">> := Exit,
               <<"signal">> := Signal, <<"wait_status">> := Wait,
               <<"launcher_kill">> := Kill, <<"log_bytes">> := LogBytes,
               <<"tail_hex">> := Tail} = Cleanup}
          when map_size(Cleanup) =:= 7, is_boolean(Confirmed),
               is_integer(Exit), is_integer(Signal), is_integer(Wait),
               is_boolean(Kill), is_integer(LogBytes), LogBytes >= 0,
               is_binary(Tail), byte_size(Tail) =< 8192 ->
            maybe_finish_instance(S#{cleanup => #{confirmed => Confirmed,
                exit_code => Exit, signal => Signal}});
        _ -> {noreply, begin_failure({error, provider_launcher_protocol}, S)}
    end.

startup_failed(Reason, S) ->
    _ = case maps:get(initial_open, S) of
        true ->
            maps:get(open_caller, S) ! {efz_mutation_session_open,
                maps:get(open_ref, S), self(), {error, {infrastructure, Reason}}};
        false -> ok
    end,
    {noreply, begin_failure({error, {infrastructure, Reason}},
        S#{initial_open => false, open_notified => true, close_requested => true,
           cleanup_kind => failure})}.

begin_failure(_Reason, S=#{phase := down}) -> S;
begin_failure(Reason, S=#{phase := cleaning_directory}) ->
    S#{terminal_result => choose_terminal(Reason, maps:get(terminal_result, S, undefined))};
begin_failure(Reason, S=#{phase := stopping}) ->
    S#{terminal_result => choose_terminal(Reason, maps:get(terminal_result, S, undefined)),
       cleanup_kind => failure, close_requested => true};
begin_failure(Reason, S) ->
    cancel_timer(maps:get(startup_timer, S, undefined)),
    case maps:get(port, S, undefined) of
        Port when is_port(Port) -> _ = catch port_command(Port, <<0>>);
        _ -> ok
    end,
    Counted = case Reason of
        cancelled -> S#{cancellation_count => maps:get(cancellation_count,S)+1};
        {timeout,_} -> S#{timeout_count => maps:get(timeout_count,S)+1};
        _ -> S#{error_count => maps:get(error_count,S)+1}
    end,
    S0 = Counted#{phase => stopping, cleanup_kind => failure,
        terminal_result => choose_terminal(Reason, maps:get(terminal_result, S, undefined)),
        close_requested => true, startup_timer => undefined,
        cleanup_started_us => now_us()},
    case is_port(maps:get(port, S0, undefined)) of
        true ->
            Timeout = maps:get(cleanup_timeout, maps:get(provider, S0), 3000),
            Timer = erlang:send_after(Timeout, self(), cleanup_deadline),
            S0#{cleanup_timer => Timer};
        false ->
            case maps:get(dir_owner, S0, undefined) of
                Pid when is_pid(Pid) ->
                    Pid ! {session_directory_cleanup, maps:get(dir_token, S0)},
                    erlang:send_after(1000, self(), directory_cleanup_deadline),
                    S0#{phase => cleaning_directory, port_exit => true,
                        cleanup => #{confirmed => false}, cleanup_timer => undefined};
                _ -> self() ! directory_cleanup_deadline,
                    S0#{phase => cleaning_directory, port_exit => true,
                        cleanup => #{confirmed => false}, cleanup_timer => undefined}
            end
    end.

choose_terminal(cancelled, undefined) -> cancelled;
choose_terminal({timeout, _} = Timeout, undefined) -> Timeout;
choose_terminal(Reason, undefined) -> Reason;
choose_terminal(_LaterReason, Existing) -> Existing.

graceful_stop(S=#{socket := Socket}) when is_port(Socket) ->
    cancel_timer(maps:get(startup_timer, S, undefined)),
    _ = send_frame(Socket, #{type => stop, epoch => maps:get(epoch, S)}),
    Timeout = maps:get(cleanup_timeout, maps:get(provider, S), 3000),
    Timer = erlang:send_after(Timeout, self(), cleanup_deadline),
    %% Every ready/recycling transition arms {active, once} before exposing
    %% the state. The child may answer and close immediately after send; a
    %% second setopts here can then observe {error,closed} despite a valid ack.
    {noreply, S#{phase => stopping, cleanup_kind =>
        maps:get(cleanup_kind, S, close), cleanup_timer => Timer,
        cleanup_started_us => maps:get(cleanup_started_us, S, now_us())}};
graceful_stop(S) -> {noreply, begin_failure({error, provider_shutdown},
    S#{failure_origin => graceful_stop_without_socket})}.

cleanup_deadline(S) ->
    cancel_timer(maps:get(cleanup_timer, S, undefined)),
    case maps:get(port, S, undefined) of
        Port when is_port(Port) -> _ = catch port_close(Port);
        _ -> ok
    end,
    close_socket(S),
    Timer = erlang:send_after(2000, self(), hard_cleanup_deadline),
    {noreply, S#{cleanup_timer => Timer, force_sent => true,
                 cleanup_forced => true}}.

cleanup_unconfirmed(S) ->
    cancel_timer(maps:get(cleanup_timer, S, undefined)),
    S1 = S#{port_exit => true, cleanup => #{confirmed => false}},
    case maps:get(dir_owner, S1, undefined) of
        Pid when is_pid(Pid) ->
            Pid ! {session_directory_cleanup, maps:get(dir_token, S1)},
            erlang:send_after(1000, self(), directory_cleanup_deadline),
            {noreply, S1#{phase => cleaning_directory}};
        _ -> cleanup_finish(S1#{phase => cleaning_directory})
    end.

begin_recycle(S=#{phase := recycling}) ->
    S1 = S#{phase => stopping, cleanup_kind => recycle, terminal_result => undefined,
            cleanup_started_us => now_us()},
    case maps:get(socket, S1, undefined) of
        Socket when is_port(Socket) ->
            _ = send_frame(Socket, #{type => stop, epoch => maps:get(epoch, S1)}),
            Timeout = maps:get(cleanup_timeout, maps:get(provider, S1), 3000),
            Timer = erlang:send_after(Timeout, self(), cleanup_deadline),
            {noreply, S1#{cleanup_timer => Timer}};
        _ -> {noreply, begin_failure({error, provider_recycle}, S1)}
    end.

maybe_finish_instance(S=#{phase := Phase})
  when Phase =:= stopping; Phase =:= recycling ->
    case {maps:get(port_exit, S, false), maps:get(cleanup, S, undefined)} of
        {true, Cleanup} when is_map(Cleanup) ->
            cancel_timer(maps:get(cleanup_timer, S, undefined)),
            Token = maps:get(dir_token, S, undefined),
            case maps:get(dir_owner, S, undefined) of
                Pid when is_pid(Pid) ->
                    Pid ! {session_directory_cleanup, Token},
                    erlang:send_after(1000, self(), directory_cleanup_deadline),
                    {noreply, S#{phase => cleaning_directory, cleanup_timer => undefined}};
                _ -> cleanup_finish(S#{phase => cleaning_directory})
            end;
        {true, undefined} ->
            cleanup_unconfirmed(S#{phase => stopping});
        _ -> {noreply, S}
    end;
maybe_finish_instance(S) ->
    case maps:get(phase, S) of
        down -> {noreply, S};
        _ -> {noreply, begin_failure({error, provider_worker_exit}, S)}
    end.

cleanup_complete(S) -> cleanup_finish(S).

cleanup_finish(S) ->
    Cleanup = maps:get(cleanup, S, #{}),
    Confirmed = maps:get(confirmed, Cleanup, false) andalso
        maps:get(port_exit, S, false) andalso
        not maps:get(directory_cleanup_forced, S, false),
    CleanupUs = max(0, now_us() - maps:get(cleanup_started_us, S,
                                            maps:get(startup_started_us, S))),
    Kind = maps:get(cleanup_kind, S, failure),
    S0 = S#{phase => down, last_cleanup_confirmed => Confirmed,
        instance_cleanup_us => CleanupUs, port => undefined,
        socket => undefined, listener => undefined, dir => undefined,
        dir_owner => undefined, dir_token => undefined,
        cleanup_timer => undefined},
    case {Kind, Confirmed, maps:get(close_requested, S0)} of
        {recycle, true, false} ->
            S1 = add_recycle(#{recycle_cleanup_us => CleanupUs},
                S0#{restarts => maps:get(restarts, S0) + 1,
                    last_recycle_cleanup_us => CleanupUs,
                    phase => starting, cleanup => undefined,
                    port_exit => false, cleanup_kind => undefined,
                    startup_started_us => now_us()}),
            start_vm(S1);
        {recycle, true, true} -> finish_session(cancelled, S0);
        {close, true, _} -> finish_session(ok, S0);
        _ ->
            Failure = case Confirmed of
                true -> maps:get(terminal_result, S0, {error, provider_stopped});
                false -> {error, {infrastructure, {cleanup_unconfirmed,
                    maps:get(terminal_result, S0, unknown_failure)}}}
            end,
            finish_session(Failure, S0)
    end.

finish_session(Result, S0) ->
    Active = maps:get(active, S0, undefined),
    Pending = maps:get(pending_request, S0, undefined),
    Runtime = #{cleanup_us => maps:get(instance_cleanup_us, S0),
        cleanup_confirmed => maps:get(last_cleanup_confirmed, S0),
        vm_starts => maps:get(vm_starts, S0), restarts => maps:get(restarts, S0),
        failure_origin => maps:get(failure_origin, S0, none)},
    lists:foreach(fun(Request) ->
        case Request of
            R when is_map(R) -> reply_request(R, Result, Runtime);
            _ -> ok
        end
    end, [Active, Pending]),
    CloseResult = case maps:get(last_cleanup_confirmed, S0) of
        true -> {ok, public_stats(S0)};
        false -> {error, {infrastructure, cleanup_unconfirmed}}
    end,
    case maps:get(close_from, S0, undefined) of
        undefined -> ok;
        From -> gen_server:reply(From, CloseResult)
    end,
    _ = case maps:get(open_notified, S0, false) of
        false ->
            maps:get(open_caller, S0) ! {efz_mutation_session_open,
                maps:get(open_ref, S0), self(), {error, Result}};
        true -> ok
    end,
    _ = case maps:get(owner, S0) of
        Owner when is_pid(Owner) -> Owner ! {efz_mutation_session_event,
            maps:get(session_ref, S0), #{type => down, result => Result,
                cleanup_confirmed => maps:get(last_cleanup_confirmed, S0)}};
        _ -> ok
    end,
    {stop, normal, S0#{phase => down, active => undefined,
                       pending_request => undefined, close_from => undefined}}.

close_socket(S) ->
    lists:foreach(fun(Key) ->
        case maps:get(Key, S, undefined) of
            Socket when is_port(Socket) -> _ = catch gen_tcp:close(Socket);
            _ -> ok
        end
    end, [socket, listener]),
    ok.

close_instance(S) ->
    close_socket(S),
    case maps:get(port, S, undefined) of
        Port when is_port(Port) -> _ = catch port_close(Port);
        _ -> ok
    end,
    ok.

record_request(Runtime, S) ->
    Samples = maps:get(request_samples, S, []),
    S#{request_samples => bounded_prepend(Runtime, Samples, 1024)}.

add_startup(Runtime, S) ->
    Samples = maps:get(startup_samples, S, []),
    S#{startup_samples => bounded_prepend(Runtime, Samples, 128)}.

add_recycle(Runtime, S) ->
    Samples = maps:get(recycle_samples, S, []),
    S#{recycle_samples => bounded_prepend(Runtime, Samples, 128)}.

bounded_prepend(Value, Values, Maximum) when length(Values) < Maximum ->
    [Value | Values];
bounded_prepend(_, Values, _) -> Values.

bounded_reason(Reason) ->
    case efz_gleam_adapter:portable(Reason) andalso erlang:external_size(Reason) =< 1024 of
        true -> Reason;
        false -> invalid_provider_result
    end.

begin_force_stop(S) ->
    case maps:get(port, S, undefined) of
        Port when is_port(Port) -> _ = catch port_command(Port, <<0>>);
        _ -> ok
    end,
    S1 = begin_failure({error, provider_shutdown}, S#{failure_origin => unexpected_stop_reply}),
    case maps:get(cleanup_timer, S1, undefined) of
        undefined ->
            Timer = erlang:send_after(100, self(), cleanup_deadline),
            S1#{cleanup_timer => Timer};
        _ -> S1
    end.

public_stats(S) ->
    maps:with([phase, vm_starts, restarts, completed_requests, requests_this_vm,
        timeout_count, cancellation_count, error_count, last_cleanup_confirmed,
        instance_cleanup_us, request_samples, startup_samples, recycle_samples,
        os_pid, launcher_pid], S).
