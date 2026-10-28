%% Fixed fault injector for the isolated mutation child. This module is selected
%% only by the trusted start_test API, never by a mutation recipe or wire term.
-module(efz_provider_fault_fixture).
-export([main/0]).

main() ->
    Exit = try
        [Path, NonceHex, _CorePath, Mode] = init:get_plain_arguments(),
        %% This scripted transport fixture deliberately does not prepare or
        %% call the optional core. Real core preparation is exercised by the
        %% integration tests; these cases isolate guardian lifecycle behavior.
        {module, efz_mutation_request_tests} =
            code:ensure_loaded(efz_mutation_request_tests),
        _ = code:ensure_loaded(efz_provider_port),
        Nonce = binary:decode_hex(list_to_binary(NonceHex)),
        {ok, Socket} = gen_tcp:connect({local, Path}, 0,
            [binary, {packet, 4}, {packet_size, 1200000}, {active, false},
             {send_timeout, 1000}, {send_timeout_close, true}], 5000),
        try
            ok = send(Socket, #{hello => Nonce, prepare_timing =>
                #{identity_check_us => 0, core_prepare_us => 0, prepare_total_us => 0}}),
            {ok, Frame} = gen_tcp:recv(Socket, 0, 5000),
            {ok, Envelope} = efz_provider_wire:decode(Frame),
            Input = maps:get(input, Envelope),
            true = is_binary(Input),
            fault(Mode, Socket, Input)
        after gen_tcp:close(Socket) end,
        0
    catch _:_ -> 2
    end,
    halt(Exit).

fault("success", Socket, Input) -> success(Socket, Input);
fault("skip", Socket, _) -> reply(Socket, {skip, fixture_skip});
fault("error", Socket, _) -> reply(Socket, {error, fixture_error});
fault("hang", _, _) -> hang();
fault("crash", _, _) -> halt(17);
fault("malformed_type", Socket, _) -> reply(Socket, {ok, 42, #{}});
fault("malformed_frame", Socket, _) -> gen_tcp:send(Socket, <<131, 80, 0:32>>);
fault("late", Socket, Input) ->
    receive after 200 -> success(Socket, Input) end;
fault("native_hang", _, _) -> native_hang();
fault(_, _, _) -> halt(64).

success(Socket, Input) ->
    reply(Socket, {ok, <<Input/binary, 0>>, #{operation => fixture}}).

reply(Socket, Result) -> send(Socket, #{result => Result, core_us => 0,
    request_validation_us => 0, identity_check_us => 0,
    direct_core_mutation_us => 0, result_validation_us => 0,
    provider_encode_us => 0, request_decode_us => 0,
    request_frame_bytes => 0}).

send(Socket, Message) ->
    {ok, Frame} = efz_provider_wire:encode(Message),
    gen_tcp:send(Socket, Frame).

hang() -> receive fixture_finish -> ok end.

native_hang() ->
    %% The existing test NIF is loaded only in this disposable VM. A harness
    %% places its fixed beam/shared library on the child-only code path.
    %% Missing native support fails explicitly: never substitute an Erlang
    %% receive loop for the unschedulable native hard-stop test.
    os:unsetenv("EFZ_NATIVE_MARKER"),
    os:unsetenv("EFZ_NATIVE_STARTUP_CRASH"),
    case code:ensure_loaded(efz_native_fixture) of
        {module, efz_native_fixture} -> efz_native_fixture:act(<<"HANG">>);
        {error, _} -> halt(65)
    end.
