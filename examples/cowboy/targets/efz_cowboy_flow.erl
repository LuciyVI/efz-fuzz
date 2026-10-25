%% Local data-flow checks. Inputs are payloads, not hostile wire packets.
%% Each path constructs a valid bounded message and checks its public API
%% round trip. No network, application callbacks or untrusted terms are used.
-module(efz_cowboy_flow).
-export([run/2, setup/1, teardown/1, counters/1, sample/2, seeds/1, modules/1]).

setup(Surface) ->
    case ets:whereis(efz_cowboy_flow_counts) of
        undefined -> _ = ets:new(efz_cowboy_flow_counts, [named_table, public, set]), ok;
        _ -> ok
    end,
    ets:insert(efz_cowboy_flow_counts, {{Surface, invocations}, 0}),
    ets:insert(efz_cowboy_flow_counts, {{Surface, accepted}, 0}),
    case Surface of
        http1 -> efz_cowboy_long_target:setup();
        router -> persistent_term:put({?MODULE, dispatch}, cowboy_router:compile([
            {"example.test", [
                {"/items/:id", [{id, int}], ?MODULE, item},
                {"/files/[...]", ?MODULE, files},
                {"/", ?MODULE, root}
            ]}]));
        _ -> ok
    end,
    ok.

teardown(Surface) ->
    case Surface of
        http1 -> efz_cowboy_long_target:teardown();
        router -> persistent_term:erase({?MODULE, dispatch});
        _ -> ok
    end,
    case ets:whereis(efz_cowboy_flow_counts) of
        undefined -> ok;
        _ -> ets:match_delete(efz_cowboy_flow_counts, {{Surface, '_'}, '_'})
    end,
    ok.

counters(Surface) ->
    case ets:whereis(efz_cowboy_flow_counts) of
        undefined -> #{};
        _ -> maps:from_list([{K, N} || {{S, K}, N} <-
            ets:tab2list(efz_cowboy_flow_counts), S =:= Surface])
    end.

run(Surface, Input) when is_binary(Input), byte_size(Input) =< 1024 ->
    count(Surface, invocations),
    Result = flow(Surface, Input),
    count(Surface, element(1, Result)),
    Result.

count(Surface, Kind) ->
    case ets:whereis(efz_cowboy_flow_counts) of
        undefined -> ok;
        _ -> _ = ets:update_counter(efz_cowboy_flow_counts, {Surface, Kind}, 1,
            {{Surface, Kind}, 0}), ok
    end.

modules(qs) -> [cowboy_req, cowboy_constraints, cow_qs];
modules(headers) -> [cowboy_req, cow_http_hd];
modules(cookies) -> [cowboy_req, cowboy_constraints, cow_cookie];
modules(router) -> [cowboy_router, cowboy_req, cowboy_constraints, cow_qs];
modules(http1) -> [cowboy_http, cowboy_req, cowboy_router, cowboy_stream,
    cow_http_hd, cow_http_te, cow_qs];
modules(http2) -> [cow_http2];
modules(http3) -> [cow_http3];
modules(websocket) -> [cow_ws];
modules(multipart) -> [cow_multipart];
modules(hpack) -> [cow_hpack];
modules(qpack) -> [cow_qpack].

seeds(Surface) -> [sample(Surface, I) || I <- [0, 1, 8, 17, 26, 35, 44, 53]].
sample(_Surface, I) when is_integer(I), I >= 0 ->
    N = lists:nth((I div 8) rem 7 + 1, [0, 1, 4, 16, 64, 126, 256]),
    <<(I rem 256), (binary:copy(<<(I rem 256)>>, N))/binary>>.

flow(qs, Input) ->
    %% Exactly the route used by a handler receiving a binary form value.
    Wire = <<"value=", (cow_qs:urlencode(Input))/binary>>,
    Req = request(#{qs => Wire}),
    Pairs = cowboy_req:parse_qs(Req),
    Match = cowboy_req:match_qs([value], Req),
    check(Pairs =:= [{<<"value">>, Input}] andalso
        Match =:= #{value => Input}, qs_roundtrip),
    {accepted, #{value => Input, fields => length(Pairs)}};
flow(cookies, Input) ->
    Value = binary:encode_hex(Input, lowercase),
    Req = request(#{headers => #{<<"cookie">> => <<"value=", Value/binary, "; other=1">>}}),
    Pairs = cowboy_req:parse_cookies(Req),
    Match = cowboy_req:match_cookies([value], Req),
    Filtered = cowboy_req:parse_cookies(cowboy_req:filter_cookies([value], Req)),
    check(lists:keyfind(<<"value">>, 1, Pairs) =:= {<<"value">>, Value}
        andalso Match =:= #{value => Value}
        andalso Filtered =:= [{<<"value">>, Value}], cookie_roundtrip),
    {accepted, #{value => Value, fields => length(Pairs)}};
flow(headers, Input) ->
    {Kind, Payload} = split(Input),
    {Name, Value} = header(Kind rem 6, Payload),
    Req = request(#{headers => #{Name => Value}}),
    Parsed = cowboy_req:parse_header(Name, Req),
    check(cowboy_req:header(Name, Req) =:= Value, header_lookup),
    case Name of
        <<"content-length">> -> check(Parsed =:= byte_size(Payload), content_length);
        _ -> ok
    end,
    {accepted, #{header => Name, parsed => Parsed}};
flow(router, Input) ->
    {Kind, Payload} = split(Input),
    {Path, Expected} = route(Kind rem 3, Payload),
    Req = request(#{host => <<"example.test">>, path => Path}),
    {ok, Routed, Env} = cowboy_router:execute(Req,
        #{dispatch => persistent_term:get({?MODULE, dispatch})}),
    check(maps:get(handler_opts, Env) =:= Expected, route_selection),
    case Expected of
        item -> check(cowboy_req:binding(id, Routed) =:= byte_size(Payload), route_binding);
        files -> check(cowboy_req:path_info(Routed) =:=
            [binary:encode_hex(Payload, lowercase)], route_tail);
        root -> ok
    end,
    {accepted, #{route => Expected, bindings => cowboy_req:bindings(Routed)}};
flow(http1, Input) ->
    {Kind, Payload} = split(Input),
    %% Real Cowboy HTTP/1 framing, stream handler, router, QS, and body delivery.
    %% The established in-memory transport has one message and one close.
    Path = <<"/api/", (integer_to_binary(Kind))/binary, "?value=",
        (cow_qs:urlencode(Payload))/binary>>,
    {BodyHeaders, Body} = case Kind rem 3 of
        0 -> {<<"Content-Length: ", (integer_to_binary(byte_size(Payload)))/binary,
            "\r\n">>, Payload};
        1 -> {<<"Transfer-Encoding: chunked\r\n">>, chunk(Payload)};
        2 -> {<<>>, <<>>}
    end,
    Wire = <<"POST ", Path/binary, " HTTP/1.1\r\nHost: example.test\r\n",
        BodyHeaders/binary, "\r\n", Body/binary>>,
    ExpectedBytes = case Kind rem 3 of 2 -> 0; _ -> byte_size(Payload) end,
    Result = efz_cowboy_long_target:run(Wire),
    check(Result =:= {ok, {accepted, ExpectedBytes}}, http1_body_delivery),
    {accepted, #{body_bytes => ExpectedBytes, framing => Kind rem 3}};
flow(http2, Input) ->
    Wire = iolist_to_binary(cow_http2:data(1, fin, Input)),
    Parsed = cow_http2:parse(Wire),
    check(Parsed =:= {ok, {data, 1, fin, Input}, <<>>}, http2_data_roundtrip),
    {accepted, #{body => Input, stream => 1}};
flow(http3, Input) ->
    Wire = iolist_to_binary(cow_http3:data(Input)),
    Parsed = cow_http3:parse(Wire),
    check(Parsed =:= {ok, {data, Input}, <<>>}, http3_data_roundtrip),
    {accepted, #{body => Input}};
flow(websocket, Input) ->
    {Kind, Payload} = split(Input),
    {Type, Data} = case Kind rem 3 of
        0 -> {text, binary:encode_hex(Payload, lowercase)};
        1 -> {binary, Payload};
        2 -> {ping, binary:part(Payload, 0, min(125, byte_size(Payload)))}
    end,
    Wire = iolist_to_binary(cow_ws:frame({Type, Data}, #{})),
    {Type, Frag, Rsv, Length, Mask, Tail} = cow_ws:parse_header(Wire, #{}, undefined),
    {ok, Actual, _, Rest} = cow_ws:parse_payload(Tail, Mask, 0, 0,
        Type, Length, Frag, #{}, Rsv),
    check(Actual =:= Data andalso Rest =:= <<>>, websocket_payload_roundtrip),
    {accepted, #{type => Type, body => Actual}};
flow(multipart, Input) ->
    Data = binary:encode_hex(Input, lowercase),
    Boundary = <<"efz-boundary">>,
    Disposition = <<"form-data; name=\"value\"">>,
    Wire = <<"--", Boundary/binary, "\r\ncontent-disposition: ", Disposition/binary,
        "\r\n\r\n", Data/binary, "\r\n--", Boundary/binary, "--\r\n">>,
    {ok, Headers, Tail} = cow_multipart:parse_headers(Wire, Boundary),
    {done, Body, Rest} = cow_multipart:parse_body(Tail, Boundary),
    {done, _} = cow_multipart:parse_headers(Rest, Boundary),
    CD = proplists:get_value(<<"content-disposition">>, Headers),
    check(Body =:= Data andalso cow_multipart:parse_content_disposition(CD)
        =:= {<<"form-data">>, [{<<"name">>, <<"value">>}]}, multipart_roundtrip),
    {accepted, #{body => Body, fields => length(Headers)}};
flow(hpack, Input) ->
    {Kind, Payload} = split(Input),
    Headers = compression_headers(Payload),
    {Wire1, Encoder} = cow_hpack:encode(Headers, cow_hpack:init(512),
        #{huffman => Kind rem 2 =:= 0}),
    {Decoded1, Decoder} = cow_hpack:decode(iolist_to_binary(Wire1), cow_hpack:init(512),
        #{max_headers => 16}),
    %% Second block reuses only this invocation's encoder and decoder tables.
    {Wire2, _} = cow_hpack:encode(Headers, Encoder),
    {Decoded2, _} = cow_hpack:decode(iolist_to_binary(Wire2), Decoder, #{max_headers => 16}),
    check(Decoded1 =:= Headers andalso Decoded2 =:= Headers, hpack_roundtrip),
    {accepted, #{headers => Decoded2, blocks => 2}};
flow(qpack, Input) ->
    {Kind, Payload} = split(Input),
    Headers = compression_headers(Payload),
    %% Zero table capacity exercises valid field sections without QUIC streams.
    {ok, Wire, Instructions, _} = cow_qpack:encode_field_section(Headers, 0,
        cow_qpack:init(encoder, 0, 0), #{huffman => Kind rem 2 =:= 0}),
    check(iolist_to_binary(Instructions) =:= <<>>, qpack_static_instructions),
    {ok, Decoded, _, _} = cow_qpack:decode_field_section(iolist_to_binary(Wire), 0,
        cow_qpack:init(decoder, 0, 0)),
    check(Decoded =:= Headers, qpack_roundtrip),
    {accepted, #{headers => Decoded}}.

split(<<Kind, Rest/binary>>) -> {Kind, Rest};
split(<<>>) -> {0, <<>>}.
%% A complete Cowboy Req shape keeps the public type contract intact even
%% though these synchronous field APIs need only a subset of its keys.
request(Fields) -> maps:merge(#{method => <<"GET">>, version => 'HTTP/1.1',
    peer => {{127, 0, 0, 1}, 12345}, sock => {{127, 0, 0, 1}, 80},
    scheme => <<"http">>, host => <<"example.test">>, port => 80,
    path => <<"/">>, qs => <<>>, headers => #{}, cert => undefined,
    pid => self(), streamid => 1, ref => efz_cowboy_flow,
    has_body => false, body_length => 0}, Fields).
header(0, B) -> {<<"content-length">>, integer_to_binary(byte_size(B))};
header(1, _) -> {<<"content-type">>, <<"text/plain; charset=utf-8">>};
header(2, B) -> {<<"range">>, <<"bytes=0-", (integer_to_binary(byte_size(B)))/binary>>};
header(3, B) -> {<<"authorization">>, <<"Basic ", (base64:encode(<<"user:", B/binary>>))/binary>>};
header(4, _) -> {<<"accept-encoding">>, <<"gzip, identity;q=0.5">>};
header(5, _) -> {<<"connection">>, <<"keep-alive, upgrade">>}.
route(0, B) -> {<<"/items/", (integer_to_binary(byte_size(B)))/binary>>, item};
route(1, <<>>) -> {<<"/">>, root};
route(1, B) -> {<<"/files/", (binary:encode_hex(B, lowercase))/binary>>, files};
route(2, _) -> {<<"/">>, root}.
chunk(<<>>) -> <<"0\r\n\r\n">>;
chunk(B) -> <<(integer_to_binary(byte_size(B), 16))/binary, "\r\n", B/binary,
    "\r\n0\r\n\r\n">>.
compression_headers(B) -> [{<<":method">>, <<"GET">>}, {<<":path">>, <<"/">>},
    {<<"x-efz-value">>, binary:encode_hex(B, lowercase)}].
check(true, _) -> ok;
check(false, Property) -> error({cowboy_flow_contract, Property}).
