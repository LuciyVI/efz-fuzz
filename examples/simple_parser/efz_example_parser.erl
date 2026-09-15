%% Ordinary application code: no EFZ API, behaviour, or coverage dependency.
-module(efz_example_parser).
-export([classify/1, run/1]).

%% Retained entry point for the original example's callers.
run(Input) -> classify(Input).
classify(<<>>) -> empty;
classify(<<0, Rest/binary>>) ->
    case Rest of <<>> -> zero; _ -> {zero_payload, byte_size(Rest)} end;
classify(<<1, N, _/binary>>) when N > 0 -> {positive, N};
classify(<<16#ff, _/binary>>) ->
    %% Deliberate artificial exception for demonstrating crash handling.
    error(artificial_example_exception);
classify(<<C, _/binary>>) when C >= $a, C =< $z -> text;
classify(_) -> unknown.
