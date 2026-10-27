%% Fixed entrypoint for a single isolated local mutation request. The lifecycle
%% owner launches this VM with trusted argv; no message selects code or paths.
-module(efz_provider_port).
-export([main/0]).

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
    Prepared = try efz_erlamsa:prepare(#{}, #{}, CorePath)
               catch _:_ -> {error, provider_initialization_failed}
               end,
    ok = send(Socket, #{hello => Nonce}),
    case Prepared of
        {ok, Subset} -> receive_request(Socket, Subset);
        {error, Reason} ->
            send(Socket, #{result => {error, bounded_reason(Reason)}, core_us => 0})
    end.

receive_request(Socket, Subset) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, Bytes} ->
            case efz_provider_wire:decode(Bytes) of
                {ok, Envelope} ->
                    {Result, CoreUs} = invoke(Envelope, Subset),
                    send(Socket, #{result => Result, core_us => CoreUs});
                {error, _} ->
                    send(Socket, #{result => {error, invalid_provider_request}, core_us => 0})
            end;
        {error, _} -> ok
    end.

invoke(#{input := Input, request := Request, context := Context,
         identity := Expected} = Envelope, Subset) when map_size(Envelope) =:= 4 ->
    case valid_request(Input, Request, Context) of
        false -> {{error, invalid_provider_request}, 0};
        true ->
            case Expected =:= maps:get(core_identity, Subset) of
                false -> {{error, version_mismatch}, 0};
                true ->
                    Started = erlang:monotonic_time(microsecond),
                    Result = try
                        %% Only the context is supplied by the wire. The code,
                        %% identity and path remain the cold-prepared subset.
                        efz_erlamsa:mutate(Input, Request,
                                          Subset#{core_context => Context})
                    catch _:_ -> {error, provider_core_failure}
                    end,
                    CoreUs = max(0, erlang:monotonic_time(microsecond) - Started),
                    {checked_result(Result, Context), CoreUs}
            end
    end;
invoke(_, _) -> {{error, invalid_provider_request}, 0}.

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
