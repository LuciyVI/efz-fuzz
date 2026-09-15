%% Artificial binary record parser. No EFZ calls or external inputs.
-module(efz_perf_parser).
-export([run/1]).
run(B) when is_binary(B) -> parse(B, 0, 0).
parse(<<>>, Count, Sum) -> {ok, Count, Sum};
parse(<<0, N:16, Rest/binary>>, Count, Sum) -> parse(Rest, Count + 1, Sum + N);
parse(<<1, N:8, Rest/binary>>, Count, Sum) ->
    Value = if N < 32 -> N * 2; N < 128 -> N + 1; true -> N - 1 end,
    parse(Rest, Count + 1, Sum + Value);
parse(<<2, Size:8, Rest/binary>>, Count, Sum) ->
    case Rest of
        <<Value:Size/binary, Tail/binary>> ->
            Class = case Value of <<>> -> 0; <<$a, _/binary>> -> 1; _ -> 2 end,
            parse(Tail, Count + 1, Sum + Size + Class);
        _ -> {truncated, Count, Sum}
    end;
parse(<<3, Flags:8, Rest/binary>>, Count, Sum) ->
    Extra = case Flags band 3 of 0 -> 7; 1 -> 11; 2 -> 13; 3 -> 17 end,
    parse(Rest, Count + 1, Sum + Extra);
parse(<<255, 0, _/binary>>, _, _) -> error(artificial_parser_exception);
parse(_, Count, Sum) -> {invalid, Count, Sum}.
