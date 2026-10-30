%% Fixed entrypoint for a single isolated local mutation request. The lifecycle
%% owner launches this VM with trusted argv; no message selects code or paths.
-module(efz_provider_port).
-export([main/0, persistent_main/0]).

-define(MAX_FRAME, 1200000).
-define(MAX_INPUT, 1048576).
-define(MAX_CONTEXT, 65536).
-define(MAX_METADATA, 4096).

-spec main() -> no_return().
main() ->
    Exit = try
        [SocketPath, NonceHex, CorePath] = init:get_plain_arguments(),
        true = valid_path(SocketPath),
        true = valid_path(CorePath),
        Nonce = nonce(NonceHex),
        case gen_tcp:connect({local, SocketPath}, 0,
                [binary, {packet, 4}, {packet_size, ?MAX_FRAME},
                 {active, false}, {send_timeout, 1000},
                 {send_timeout_close, true}], 5000) of
            {ok, Socket} ->
                _ = try session(Socket, Nonce, CorePath)
                after gen_tcp:close(Socket) end,
                0;
            {error, _} -> 2
        end
    catch _:_ -> 2
    end,
    halt(Exit).

valid_path(Path) when is_list(Path), length(Path) > 0, length(Path) =< 4096 ->
    lists:all(fun(C) -> is_integer(C) andalso C > 0 andalso C =< 255 end, Path);
valid_path(_) -> false.

nonce(Hex) when is_list(Hex), length(Hex) >= 32, length(Hex) =< 64,
                length(Hex) rem 2 =:= 0 ->
    true = lists:all(fun(C) -> (C >= $0 andalso C =< $9) orelse
                              (C >= $a andalso C =< $f) orelse
                              (C >= $A andalso C =< $F) end, Hex),
    binary:decode_hex(list_to_binary(Hex)).

session(Socket, Nonce, CorePath) ->
    %% Loading all fixed core modules interns their atoms before safe ETF
    %% decoding. The default context is used only for this cold identity check.
    {Prepared, PrepareTiming} = try efz_erlamsa:prepare_timed(#{}, #{}, CorePath)
               catch _:_ -> {{error, provider_initialization_failed},
                   #{identity_check_us => 0, core_prepare_us => 0, prepare_total_us => 0}}
               end,
    ok = send(Socket, #{hello => Nonce, prepare_timing => PrepareTiming}),
    case Prepared of
        {ok, Subset} -> receive_request(Socket, Subset);
        {error, Reason} ->
            send_timed(Socket, #{result => {error, bounded_reason(Reason)}, core_us => 0,
                request_validation_us => 0, identity_check_us => 0,
                direct_core_mutation_us => 0, result_validation_us => 0})
    end.

%% Long-lived mode. The parent performs the one-time identity/config handshake;
%% each accepted request is dispatched to a fresh Erlang process in this VM.
-spec persistent_main() -> no_return().
persistent_main() ->
    Exit = try
        [SocketPath, NonceHex, CorePath] = init:get_plain_arguments(),
        true = valid_path(SocketPath),
        true = valid_path(CorePath),
        Nonce = nonce(NonceHex),
        {module, efz_erlamsa} = code:ensure_loaded(efz_erlamsa),
        {module, efz_mutation_provider} = code:ensure_loaded(efz_mutation_provider),
        {module, efz_provider_wire} = code:ensure_loaded(efz_provider_wire),
        _ = efz_erlamsa:core_option_atoms(),
        case gen_tcp:connect({local, SocketPath}, 0,
                [binary, {packet, 4}, {packet_size, ?MAX_FRAME},
                 {active, false}, {send_timeout, 1000},
                 {send_timeout_close, true}], 5000) of
            {ok, Socket} ->
                _ = try persistent_handshake(Socket, Nonce, CorePath)
                    after gen_tcp:close(Socket) end,
                0;
            {error, _} -> 2
        end
    catch _:_ -> 2
    end,
    halt(Exit).

persistent_handshake(Socket, Nonce, CorePath) ->
    ok = send(Socket, #{hello => Nonce}),
    case gen_tcp:recv(Socket, 0, 10000) of
        {ok, Bytes} ->
            case efz_provider_wire:decode(Bytes) of
                {ok, Init} -> persistent_prepare(Socket, Init, CorePath);
                {error, _} -> send(Socket, #{type => ready, status => error,
                                             reason => invalid_startup_frame})
            end;
        {error, _} -> ok
    end.

persistent_prepare(Socket,
        #{type := initialize, epoch := Epoch, request_number := RequestNumber,
          options := Options, limits := Limits,
          identity := Expected, context_id := ExpectedContext} = Init, CorePath)
  when map_size(Init) =:= 7, is_binary(Epoch), byte_size(Epoch) =:= 16,
       is_integer(RequestNumber), RequestNumber > 0,
       is_map(Options), is_map(Limits), is_map(Expected),
       is_binary(ExpectedContext), byte_size(ExpectedContext) =:= 32 ->
    case efz_erlamsa:identity_valid(Expected) of
        false -> send(Socket, #{type => ready, status => error, reason => version_mismatch});
        true ->
            {PreparedResult, PrepareTiming} = efz_erlamsa:prepare_timed(Options, Limits, CorePath),
            case PreparedResult of
                {ok, Prepared} ->
                    ActualIdentity = maps:get(core_identity, Prepared),
                    ActualContext = maps:get(config_identity, maps:get(core_context, Prepared)),
                    case ActualIdentity =:= Expected andalso ActualContext =:= ExpectedContext of
                        true ->
                            Reply = #{type => ready, status => ok, epoch => Epoch,
                                identity => ActualIdentity, context_id => ActualContext,
                                prepare_timing => PrepareTiming},
                            case send(Socket, Reply) of
                                ok -> persistent_requests(Socket, Epoch, ExpectedContext,
                                                           Prepared, RequestNumber);
                                _ -> ok
                            end;
                        false -> send(Socket, #{type => ready, status => error,
                                                reason => version_mismatch})
                    end;
                {error, Reason} -> send(Socket, #{type => ready, status => error,
                                                  reason => bounded_reason(Reason)})
            end
    end;
persistent_prepare(Socket, _, _) ->
    send(Socket, #{type => ready, status => error, reason => invalid_startup_frame}).

persistent_requests(Socket, Epoch, ContextId, Prepared, NextNumber) ->
    case gen_tcp:recv(Socket, 0, infinity) of
        {ok, Bytes} ->
            DecodeStarted = erlang:monotonic_time(microsecond),
            case efz_provider_wire:decode(Bytes) of
                {ok, #{type := stop, epoch := Epoch} = Stop} when map_size(Stop) =:= 2 ->
                    _ = send(Socket, #{type => stopped, epoch => Epoch}), ok;
                {ok, Envelope} ->
                    DecodeUs = elapsed(DecodeStarted),
                    case persistent_request(Socket, Envelope, Bytes, DecodeUs, Epoch,
                                             ContextId, Prepared, NextNumber) of
                        {ok, Next} -> persistent_requests(Socket, Epoch, ContextId, Prepared, Next);
                        stop -> ok
                    end;
                {error, _} -> send(Socket, #{type => error, epoch => Epoch,
                                             request_number => NextNumber,
                                             reason => invalid_provider_frame})
            end;
        {error, _} -> ok
    end.

persistent_request(Socket,
        #{type := mutate, epoch := Epoch, request_number := Number,
          context_id := ContextId, input := Input, request := Request} = Envelope,
        Frame, DecodeUs, Epoch, ContextId, Prepared, NextNumber)
  when map_size(Envelope) =:= 6, is_integer(Number), Number =:= NextNumber ->
    ValidationStarted = erlang:monotonic_time(microsecond),
    Context = maps:get(core_context, Prepared),
    case valid_request(Input, Request, Context) of
        false ->
            Reply = #{type => reply, epoch => Epoch, request_number => Number,
                result => {error, invalid_provider_request}, core_us => 0,
                request_validation_us => elapsed(ValidationStarted), identity_check_us => 0,
                direct_core_mutation_us => 0, result_validation_us => 0,
                request_decode_us => DecodeUs, request_frame_bytes => byte_size(Frame),
                input_bytes => input_size(Input), output_bytes => 0},
            case send_reply(Socket, Reply) of
                {ok, _EncodeUs, _SendUs, _FrameBytes} -> {ok, NextNumber + 1};
                _ -> stop
            end;
        true ->
            RequestValidationUs = elapsed(ValidationStarted),
            Parent = self(), WorkerRef = make_ref(),
            {Worker, Monitor} = spawn_monitor(fun() ->
                Started = erlang:monotonic_time(microsecond),
                {Result, Timing} = try efz_erlamsa:mutate_session_timed(Input, Request, Prepared)
                    catch _:_ -> {{error, provider_core_failure},
                        #{identity_check_us => 0, direct_core_mutation_us => 0}}
                    end,
                Parent ! {persistent_mutation_done, WorkerRef, Result, Timing,
                    elapsed(Started)}
            end),
            case await_mutation_worker(WorkerRef, Worker, Monitor) of
                {ok, CoreResult, MutationTiming, CoreUs} ->
                    ResultStarted = erlang:monotonic_time(microsecond),
                    Result = checked_result(CoreResult, Context),
                    ResultValidationUs = elapsed(ResultStarted),
                    Reply = #{type => reply, epoch => Epoch, request_number => Number,
                        result => Result, core_us => CoreUs,
                        request_validation_us => RequestValidationUs,
                        identity_check_us => maps:get(identity_check_us, MutationTiming, 0),
                        direct_core_mutation_us => maps:get(direct_core_mutation_us,
                                                            MutationTiming, 0),
                        result_validation_us => ResultValidationUs,
                        request_decode_us => DecodeUs,
                        request_frame_bytes => byte_size(Frame),
                        input_bytes => byte_size(Input), output_bytes => output_size(Result)},
                    case send_reply(Socket, Reply) of
                        {ok, _EncodeUs, _SendUs, _FrameBytes} -> {ok, NextNumber + 1};
                        _ -> stop
                    end;
                {error, Reason} ->
                    _ = send_reply(Socket, #{type => reply, epoch => Epoch, request_number => Number,
                        result => {error, Reason}, core_us => 0,
                        request_validation_us => RequestValidationUs, identity_check_us => 0,
                        direct_core_mutation_us => 0, result_validation_us => 0,
                        request_decode_us => DecodeUs,
                        request_frame_bytes => byte_size(Frame), input_bytes => byte_size(Input),
                        output_bytes => 0}),
                    {ok, NextNumber + 1}
            end
    end;
persistent_request(Socket, Envelope, Frame, DecodeUs, Epoch, _ContextId, _Prepared, NextNumber) ->
    _ = send_reply(Socket, #{type => reply, epoch => Epoch, request_number => NextNumber,
        result => {error, invalid_provider_request}, core_us => 0,
        request_validation_us => 0, identity_check_us => 0,
        direct_core_mutation_us => 0, result_validation_us => 0, request_decode_us => DecodeUs,
        request_frame_bytes => byte_size(Frame), input_bytes => input_size(
            case Envelope of #{input := B} -> B; _ -> undefined end), output_bytes => 0}),
    {ok, NextNumber + 1}.

await_mutation_worker(Ref, Worker, Monitor) ->
    receive
        {persistent_mutation_done, Ref, Result, Timing, CoreUs} ->
            receive
                {'DOWN', Monitor, process, Worker, _} -> {ok, Result, Timing, CoreUs}
            after 1000 ->
                exit(Worker, kill),
                {error, provider_request_process_unreaped}
            end;
        {'DOWN', Monitor, process, Worker, _} -> {error, provider_core_failure}
    end.

send_reply(Socket, Reply) ->
    EncodeStarted = erlang:monotonic_time(microsecond),
    case efz_provider_wire:encode(Reply) of
        {ok, _} ->
            EncodeUs = elapsed(EncodeStarted),
            Final = Reply#{provider_encode_us => EncodeUs},
            case efz_provider_wire:encode(Final) of
                {ok, Bytes} ->
                    SendStarted = erlang:monotonic_time(microsecond),
                    case gen_tcp:send(Socket, Bytes) of
                        ok -> {ok, EncodeUs, elapsed(SendStarted), byte_size(Bytes)};
                        {error, _} = Error -> Error
                    end;
                {error, _} = Error -> Error
            end;
        {error, _} = Error -> Error
    end.

input_size(B) when is_binary(B) -> byte_size(B);
input_size(_) -> 0.
output_size({ok, Candidate, _}) when is_binary(Candidate) -> byte_size(Candidate);
output_size(_) -> 0.

receive_request(Socket, Subset) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, Bytes} ->
            DecodeStarted = erlang:monotonic_time(microsecond),
            case efz_provider_wire:decode(Bytes) of
                {ok, Envelope} ->
                    DecodeUs = elapsed(DecodeStarted),
                    {Result, Metrics} = invoke(Envelope, Subset),
                    {_Reply, _EncodeUs, _SendUs} = send_timed(Socket,
                        maps:merge(#{result => Result, request_decode_us => DecodeUs,
                                     request_frame_bytes => byte_size(Bytes)}, Metrics));
                {error, _} ->
                    send_timed(Socket, #{result => {error, invalid_provider_request}, core_us => 0,
                        request_validation_us => 0, identity_check_us => 0,
                        direct_core_mutation_us => 0, result_validation_us => 0,
                        request_decode_us => elapsed(DecodeStarted),
                        request_frame_bytes => byte_size(Bytes)})
            end;
        {error, _} -> ok
    end.

invoke(#{input := Input, request := Request, context := Context,
         identity := Expected} = Envelope, Subset) when map_size(Envelope) =:= 4 ->
    ValidationStarted = erlang:monotonic_time(microsecond),
    case valid_request(Input, Request, Context) of
        false -> {{error, invalid_provider_request}, #{core_us => 0,
            request_validation_us => elapsed(ValidationStarted), identity_check_us => 0,
            direct_core_mutation_us => 0, result_validation_us => 0}};
        true ->
            case Expected =:= maps:get(core_identity, Subset) of
                false -> {{error, version_mismatch}, #{core_us => 0,
                    request_validation_us => elapsed(ValidationStarted), identity_check_us => 0,
                    direct_core_mutation_us => 0, result_validation_us => 0}};
                true ->
                    RequestValidationUs = elapsed(ValidationStarted),
                    Started = erlang:monotonic_time(microsecond),
                    {Result0, MutationTiming} = try
                        %% The context is supplied by the wire. The code,
                        %% identity and path remain the cold-prepared subset.
                        efz_erlamsa:mutate_timed(Input, Request,
                            Subset#{core_context => Context})
                    catch _:_ -> {{error, provider_core_failure},
                                  #{identity_check_us => 0, direct_core_mutation_us => 0}}
                    end,
                    CoreUs = elapsed(Started),
                    Validation = erlang:monotonic_time(microsecond),
                    Result = checked_result(Result0, Context),
                    Metrics = #{core_us => CoreUs,
                        request_validation_us => RequestValidationUs,
                        identity_check_us => maps:get(identity_check_us, MutationTiming, 0),
                        direct_core_mutation_us => maps:get(direct_core_mutation_us, MutationTiming, 0),
                        result_validation_us => elapsed(Validation)},
                    {Result, Metrics}
            end
    end;
invoke(_, _) -> {{error, invalid_provider_request}, #{core_us => 0,
    request_validation_us => 0, identity_check_us => 0,
    direct_core_mutation_us => 0, result_validation_us => 0}}.

valid_request(Input, Request, Context) ->
    try
        true = is_binary(Input) andalso byte_size(Input) =< ?MAX_INPUT,
        true = is_map(Request) andalso erlang:external_size(Request) =< ?MAX_METADATA,
        true = efz_gleam_adapter:portable(Request),
        true = is_map(Context) andalso map_size(Context) =:= 5,
        1 = maps:get(core_context, Context),
        true = is_map(maps:get(options, Context)),
        true = is_map(maps:get(versions, Context)),
        ConfigIdentity = maps:get(config_identity, Context),
        true = is_binary(ConfigIdentity) andalso byte_size(ConfigIdentity) =:= 32,
        Limits = maps:get(limits, Context),
        true = is_map(Limits),
        Maximum = maps:get(output_bytes, Limits),
        true = is_integer(Maximum) andalso Maximum > 0 andalso Maximum =< ?MAX_INPUT,
        true = erlang:external_size(Context) =< ?MAX_CONTEXT,
        true = efz_gleam_adapter:portable(Context),
        true
    catch _:_ -> false
    end.

checked_result({ok, Candidate, Metadata}, Context) when is_binary(Candidate), is_map(Metadata) ->
    Maximum = maps:get(output_bytes, maps:get(limits, Context)),
    case byte_size(Candidate) =< Maximum andalso
         erlang:external_size(Metadata) =< ?MAX_METADATA andalso
         efz_gleam_adapter:portable(Metadata) of
        true -> {ok, Candidate, Metadata};
        false -> {error, invalid_provider_result}
    end;
checked_result({skip, Reason}, _) when is_atom(Reason) -> {skip, Reason};
checked_result({error, Reason}, _) -> {error, bounded_reason(Reason)};
checked_result(_, _) -> {error, invalid_provider_result}.

bounded_reason(Reason) ->
    case efz_gleam_adapter:portable(Reason) andalso erlang:external_size(Reason) =< 1024 of
        true -> Reason;
        false -> invalid_provider_result
    end.

send(Socket, Message) ->
    case efz_provider_wire:encode(Message) of
        {ok, Bytes} -> gen_tcp:send(Socket, Bytes);
        {error, _} -> {error, invalid_provider_result}
    end.

send_timed(Socket, Message) ->
    EncodeStarted = erlang:monotonic_time(microsecond),
    case efz_provider_wire:encode(Message) of
        {ok, _FirstPass} ->
            EncodeUs = elapsed(EncodeStarted),
            %% The payload carries this first-pass duration. The second encode
            %% is included in end-to-end latency; the value is an estimate of
            %% the final encode cost, avoiding a second protocol frame.
            case efz_provider_wire:encode(Message#{provider_encode_us => EncodeUs}) of
                {ok, Bytes} -> send_encoded(Socket, Bytes, EncodeUs);
                {error, _} -> {{error, invalid_provider_result}, EncodeUs, 0}
            end;
        {error, _} -> {{error, invalid_provider_result}, elapsed(EncodeStarted), 0}
    end.

send_encoded(Socket, Bytes, EncodeUs) ->
            SendStarted = erlang:monotonic_time(microsecond),
            case gen_tcp:send(Socket, Bytes) of
                ok -> {ok, EncodeUs, elapsed(SendStarted)};
                {error, _} -> {{error, provider_transport}, EncodeUs, elapsed(SendStarted)}
            end.

elapsed(Started) -> max(0, erlang:monotonic_time(microsecond) - Started).
