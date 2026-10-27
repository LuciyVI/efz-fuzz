%% Bounded, data-only ETF for the private mutation-provider socket.
%% The structural walk runs before binary_to_term so declared container sizes,
%% compressed terms, and runtime objects cannot reach the native decoder.
-module(efz_provider_wire).
-export([encode/1, decode/1, scan/1]).

-define(MAX_BYTES, 1200000).
-define(MAX_BINARY, 1048576).
-define(MAX_DEPTH, 32).
-define(MAX_NODES, 16384).
-define(MAX_CONTAINER, 256).

encode(Term) ->
    try
        require(efz_gleam_adapter:portable(Term), wire_nonportable),
        require(erlang:external_size(Term) =< ?MAX_BYTES, wire_size),
        Binary = term_to_binary(Term, [deterministic, {minor_version, 2}]),
        case scan(Binary) of
            ok -> {ok, Binary};
            {error, _} = Error -> Error
        end
    catch
        throw:{wire, Reason} -> {error, Reason};
        error:_ -> {error, wire_nonportable}
    end.

decode(Binary) ->
    case scan(Binary) of
        ok ->
            try binary_to_term(Binary, [safe]) of
                Term ->
                    case efz_gleam_adapter:portable(Term) of
                        true -> {ok, Term};
                        false -> {error, wire_nonportable}
                    end
            catch error:_ -> {error, wire_format} end;
        {error, _} = Error -> Error
    end.

scan(Binary) when is_binary(Binary), byte_size(Binary) =< ?MAX_BYTES ->
    try
        case Binary of
            <<131, Body/binary>> ->
                {Rest, _Nodes} = term(Body, 0, ?MAX_NODES),
                require(Rest =:= <<>>, wire_format),
                ok;
            _ -> fail(wire_format)
        end
    catch
        throw:{wire, Reason} -> {error, Reason};
        error:_ -> {error, wire_format}
    end;
scan(Binary) when is_binary(Binary) -> {error, wire_size};
scan(_) -> {error, wire_format}.

require(true, _) -> ok;
require(false, Reason) -> fail(Reason).
fail(Reason) -> throw({wire, Reason}).

term(_, Depth, _) when Depth > ?MAX_DEPTH -> fail(wire_depth);
term(_, _, Nodes) when Nodes =< 0 -> fail(wire_nodes);
term(<<97, _:8, Rest/binary>>, _, Nodes) -> {Rest, Nodes - 1};
term(<<98, _:32, Rest/binary>>, _, Nodes) -> {Rest, Nodes - 1};
term(<<70, _Sign:1, Exponent:11, _Fraction:52, Rest/binary>>, _, Nodes) ->
    require(Exponent =/= 2047, wire_nonportable),
    {Rest, Nodes - 1};
term(<<100, Length:16, Rest/binary>>, _, Nodes) -> atom_bytes(Length, Rest, Nodes);
term(<<115, Length:8, Rest/binary>>, _, Nodes) -> atom_bytes(Length, Rest, Nodes);
term(<<118, Length:16, Rest/binary>>, _, Nodes) -> atom_bytes(Length, Rest, Nodes);
term(<<119, Length:8, Rest/binary>>, _, Nodes) -> atom_bytes(Length, Rest, Nodes);
term(<<104, Count:8, Rest/binary>>, Depth, Nodes) -> tuple_terms(Count, Rest, Depth, Nodes);
term(<<105, Count:32, Rest/binary>>, Depth, Nodes) -> tuple_terms(Count, Rest, Depth, Nodes);
term(<<106, Rest/binary>>, _, Nodes) -> {Rest, Nodes - 1};
term(<<107, Length:16, Rest/binary>>, Depth, Nodes) ->
    %% STRING_EXT expands to a proper byte list: account for every cons cell
    %% and integer plus its terminal nil before permitting native allocation.
    Cost = Length * 2 + 1,
    require(Cost =< Nodes, wire_nodes),
    require(Length =:= 0 orelse Depth < ?MAX_DEPTH, wire_depth),
    {take(Length, Rest), Nodes - Cost};
term(<<108, Count:32, Rest/binary>>, Depth, Nodes) ->
    require(Count * 2 + 1 =< Nodes, wire_nodes),
    {Tail, Nodes1} = terms(Count, Rest, Depth + 1, Nodes - Count),
    require(Nodes1 > 0, wire_nodes),
    case Tail of
        <<106, Remaining/binary>> -> {Remaining, Nodes1 - 1};
        _ -> fail(wire_nonportable)
    end;
term(<<109, Length:32, Rest/binary>>, _, Nodes) ->
    require(Length =< ?MAX_BINARY, wire_size),
    {take(Length, Rest), Nodes - 1};
term(<<110, Length:8, Sign:8, Rest/binary>>, _, Nodes) -> bigint(Length, Sign, Rest, Nodes);
term(<<111, Length:32, Sign:8, Rest/binary>>, _, Nodes) -> bigint(Length, Sign, Rest, Nodes);
term(<<116, Count:32, Rest/binary>>, Depth, Nodes) ->
    require(Count =< ?MAX_CONTAINER, wire_container),
    require(Count * 2 + 1 =< Nodes, wire_nodes),
    terms(Count * 2, Rest, Depth + 1, Nodes - 1);
term(<<80, _/binary>>, _, _) -> fail(wire_compressed);
term(<<Tag, _/binary>>, _, _) when
        Tag =:= 88; Tag =:= 89; Tag =:= 90; Tag =:= 101; Tag =:= 102;
        Tag =:= 103; Tag =:= 112; Tag =:= 113; Tag =:= 114; Tag =:= 117;
        Tag =:= 120 ->
    fail(wire_runtime_object);
term(_, _, _) -> fail(wire_format).

atom_bytes(Length, Rest, Nodes) ->
    require(Length =< 255, wire_size),
    {take(Length, Rest), Nodes - 1}.

bigint(Length, Sign, Rest, Nodes) ->
    require(Length =< 8 andalso (Sign =:= 0 orelse Sign =:= 1), wire_nonportable),
    {take(Length, Rest), Nodes - 1}.

tuple_terms(Count, Rest, Depth, Nodes) ->
    require(Count =< ?MAX_CONTAINER, wire_container),
    require(Count + 1 =< Nodes, wire_nodes),
    terms(Count, Rest, Depth + 1, Nodes - 1).

terms(0, Rest, _, Nodes) -> {Rest, Nodes};
terms(Count, Binary, Depth, Nodes) ->
    {Rest, Nodes1} = term(Binary, Depth, Nodes),
    terms(Count - 1, Rest, Depth, Nodes1).

take(Length, Binary) ->
    require(Length =< byte_size(Binary), wire_format),
    <<_:Length/binary, Rest/binary>> = Binary,
    Rest.
