%% Bounded payload-to-library data flow. The input is data, never XML markup.
%% All element, method and member names below belong to a fixed finite set.
%% These synchronous fixtures use no sockets or external callbacks.
-module(efz_xmlrpc_flow).
-export([run/2, setup/1, teardown/1, counters/1, seeds/1, sample/2, modules/1]).

setup(Surface) ->
    case ets:whereis(efz_xmlrpc_flow_counts) of
        undefined -> _ = ets:new(efz_xmlrpc_flow_counts, [named_table, public, set]), ok;
        _ -> ok
    end,
    lists:foreach(fun(Kind) ->
        ets:insert(efz_xmlrpc_flow_counts, {{Surface, Kind}, 0})
    end, [invocations, accepted, rejected]),
    ok.

teardown(Surface) ->
    case ets:whereis(efz_xmlrpc_flow_counts) of
        undefined -> ok;
        _ -> ets:match_delete(efz_xmlrpc_flow_counts, {{Surface, '_'}, '_'})
    end,
    ok.

counters(Surface) ->
    case ets:whereis(efz_xmlrpc_flow_counts) of
        undefined -> #{};
        _ -> maps:from_list([{Kind, Count} || {{S, Kind}, Count} <-
            ets:tab2list(efz_xmlrpc_flow_counts), S =:= Surface])
    end.

run(Surface, Input) when is_binary(Input), byte_size(Input) =< 512 ->
    count(Surface, invocations),
    Result = flow(Surface, Input),
    count(Surface, element(1, Result)),
    Result.

count(Surface, Kind) ->
    case ets:whereis(efz_xmlrpc_flow_counts) of
        undefined -> ok;
        _ -> _ = ets:update_counter(efz_xmlrpc_flow_counts, {Surface, Kind}, 1,
            {{Surface, Kind}, 0}), ok
    end.

modules(call) -> [xmlrpc_decode];
modules(response) -> [xmlrpc_decode];
modules(fault) -> [xmlrpc_decode, xmlrpc_util];
modules(roundtrip) -> [xmlrpc_encode, xmlrpc_decode, xmlrpc_util];
modules(dispatch) -> [xmlrpc_encode, xmlrpc_decode, xmlrpc_util];
modules(encoder_validation) -> [xmlrpc_encode, xmlrpc_util].

seeds(Surface) ->
    [<<>>] ++ [sample(Surface, I) || I <-
        [0, 9, 18, 27, 36, 45, 54, 63, 22, 23, 38, 39]] ++
        [<<2, "<>&\"'", 0, 255>>, binary:copy(<<255>>, 512)].

sample(_Surface, Index) when is_integer(Index), Index >= 0 ->
    Length = lists:nth((Index div 8) rem 8 + 1, [0, 1, 4, 16, 64, 126, 255, 511]),
    Pattern = <<0, 255, $<, $>, $&, $", $', (Index rem 256)>>,
    Payload = binary:part(binary:copy(Pattern, (Length + 7) div 8), 0, Length),
    <<(Index rem 8), Payload/binary>>.

flow(call, Input) ->
    {Selector, Payload} = split(Input),
    {Type, Value} = typed_value(Selector rem 8, Payload),
    Expected = {call, echo, [Value]},
    Wire = ["<?xml version=\"1.0\"?><methodCall><methodName>echo</methodName>",
        "<params><param><value>", value_xml(Value),
        "</value></param></params></methodCall>"],
    manual_decode(call, Type, Input, Wire, Expected, call_payload);
flow(response, Input) ->
    {Selector, Payload} = split(Input),
    {Type, Value} = typed_value(Selector rem 8, Payload),
    %% The pinned decoder requires one successful response parameter. Its
    %% encoder's empty-response form is deliberately outside this fixture.
    Expected = {response, [Value]},
    Wire = ["<?xml version=\"1.0\"?><methodResponse><params><param><value>",
        value_xml(Value), "</value></param></params></methodResponse>"],
    manual_decode(response, Type, Input, Wire, Expected, response_payload);
flow(fault, Input) ->
    {Selector, Payload} = split(Input),
    Code = -32000 - (Selector rem 8),
    String = printable(Payload),
    Expected = {response, {fault, Code, String}},
    Wire = ["<?xml version=\"1.0\"?><methodResponse><fault><value><struct>",
        "<member><name>faultCode</name><value><int>", integer_to_list(Code),
        "</int></value></member><member><name>faultString</name><value><string>",
        escape(String), "</string></value></member></struct></value></fault>",
        "</methodResponse>"],
    manual_decode(fault, fault, Input, Wire, Expected, fault_payload);
flow(roundtrip, Input) ->
    {Selector, Payload} = split(Input),
    {Type, Value} = typed_value(Selector rem 8, Payload),
    Call = {call, echo, [Value]},
    case encode_decode(Call, roundtrip_call) of
        {ok, Actual, Bytes} ->
            accepted(roundtrip, Type, Input, Actual, #{encoded_bytes => Bytes});
        {error, Reason} -> rejected(roundtrip, Type, Input, Reason)
    end;
flow(dispatch, Input) ->
    {Selector, Payload} = split(Input),
    {Type, Call, ExpectedResponse} = dispatch_case(Selector, Payload),
    case encode_decode(Call, dispatch_call) of
        {ok, ActualCall, CallBytes} ->
            Response = fixture_dispatch(ActualCall),
            check(Response =:= ExpectedResponse, dispatch_result),
            case encode_decode(Response, dispatch_response) of
                {ok, ActualResponse, ResponseBytes} ->
                    {call, Method, _} = ActualCall,
                    accepted(dispatch, Type, Input, ActualResponse,
                        #{method => Method, request => ActualCall,
                          encoded_bytes => CallBytes + ResponseBytes});
                {error, Reason} -> rejected(dispatch, Type, Input, Reason)
            end;
        {error, Reason} -> rejected(dispatch, Type, Input, Reason)
    end;
flow(encoder_validation, Input) ->
    {Selector, Payload} = split(Input),
    {Type, Term, Expected} = invalid_case(Selector rem 8, printable(Payload)),
    Observation = #{surface => encoder_validation, type => Type, payload => Term,
        value => Term, count => 1, input_bytes => byte_size(Input), expected => Expected},
    case library(xmlrpc_encode, payload, Term) of
        {error, Actual} ->
            {rejected, Observation#{reason => Actual,
                expected_error_match => Actual =:= Expected}};
        {ok, Wire} ->
            {accepted, Observation#{encoded_bytes => iolist_size(Wire),
                expected_error_match => false}}
    end.

manual_decode(Surface, Type, Input, Wire, Expected, Property) ->
    case checked_decode(Wire, Expected, Property) of
        {ok, Actual} ->
            accepted(Surface, Type, Input, Actual, #{encoded_bytes => iolist_size(Wire)});
        {error, Reason} -> rejected(Surface, Type, Input, Reason)
    end.

encode_decode(Term, Property) ->
    case library(xmlrpc_encode, payload, Term) of
        {ok, Wire} ->
            case checked_decode(Wire, Term, Property) of
                {ok, Actual} -> {ok, Actual, iolist_size(Wire)};
                {error, Reason} -> {error, {decode, Reason}}
            end;
        {error, Reason} -> {error, {encode, Reason}}
    end.

checked_decode(Wire, Expected, Property) ->
    case library(xmlrpc_decode, payload, lists:flatten(Wire)) of
        {ok, Actual} ->
            check(Actual =:= Expected, Property),
            {ok, Actual};
        {error, Reason} -> {error, Reason}
    end.

%% Keep optional dependency calls dynamic so ordinary builds need no XML-RPC.
library(Module, Function, Argument) -> erlang:apply(Module, Function, [Argument]).

accepted(Surface, Type, Input, Actual, Extra) ->
    Value = decoded_value(Actual),
    {accepted, maps:merge(#{surface => Surface, type => Type, payload => Actual,
        value => Value, count => value_count(Value), input_bytes => byte_size(Input)}, Extra)}.

rejected(Surface, Type, Input, Reason) ->
    {rejected, #{surface => Surface, type => Type, reason => Reason,
        input_bytes => byte_size(Input)}}.

decoded_value({call, echo, [Value]}) -> Value;
decoded_value({response, [Value]}) -> Value;
decoded_value({response, {fault, Code, String}}) -> {fault, Code, String}.

value_count({array, Values}) -> length(Values);
value_count({struct, Members}) -> length(Members);
value_count({fault, _, _}) -> 2;
value_count(_) -> 1.

split(<<Selector, Payload/binary>>) -> {Selector, Payload};
split(<<>>) -> {0, <<>>}.

typed_value(0, Payload) -> {integer, integer_value(Payload)};
typed_value(1, Payload) -> {boolean, boolean_value(Payload)};
typed_value(2, Payload) -> {string, printable(Payload)};
typed_value(3, Payload) -> {double, integer_value(Payload) / 8};
typed_value(4, Payload) -> {date, {date, date_value(Payload)}};
typed_value(5, Payload) -> {base64, {base64, binary_to_list(base64:encode(Payload))}};
typed_value(6, Payload) ->
    Values = [integer_value(Payload), printable(Payload), boolean_value(Payload),
        {struct, [{value, printable(Payload)}]}],
    {array, {array, lists:sublist(Values, byte_size(Payload) rem 5)}};
typed_value(7, Payload) ->
    Members = [{value, printable(Payload)}, {count, byte_size(Payload)},
        {enabled, boolean_value(Payload)},
        {items, {array, [integer_value(Payload), integer_value(Payload) / 8]}}],
    {struct, {struct, lists:sublist(Members, byte_size(Payload) rem 5)}}.

integer_value(Payload) ->
    lists:foldl(fun(Byte, Acc) -> (Acc * 257 + Byte) rem 2000001 end,
        0, binary_to_list(Payload)) - 1000000.

boolean_value(Payload) -> checksum(Payload) rem 2 =:= 0.
checksum(Payload) -> lists:sum(binary_to_list(Payload)).

printable(Payload) ->
    [case Byte >= 32 andalso Byte =< 126 of
        true -> Byte;
        false -> 32 + Byte rem 95
    end || Byte <- binary_to_list(Payload)].

date_value(Payload) ->
    Sum = checksum(Payload),
    Length = byte_size(Payload),
    lists:flatten(io_lib:format("~4..0B~2..0B~2..0BT~2..0B:~2..0B:~2..0B",
        [2000 + Sum rem 30, 1 + Length rem 12, 1 + Sum rem 28,
         Sum rem 24, Length rem 60, Sum rem 60])).

dispatch_case(Selector, Payload) ->
    case byte_size(Payload) rem 2 of
        0 ->
            {Type, Value} = typed_value(Selector rem 8, Payload),
            {Type, {call, echo, [Value]}, {response, [Value]}};
        1 ->
            Numbers = [Byte - 128 || Byte <-
                lists:sublist(binary_to_list(Payload), 4)],
            Expected = lists:foldl(fun(N, Acc) -> Acc + N end, 0, Numbers),
            {integer, {call, sum, Numbers}, {response, [Expected]}}
    end.

fixture_dispatch({call, echo, [Value]}) -> {response, [Value]};
fixture_dispatch({call, sum, Numbers}) -> {response, [lists:sum(Numbers)]}.

invalid_case(0, String) ->
    Term = {invalid_payload, String},
    {bad_payload, Term, {bad_payload, Term}};
invalid_case(1, String) ->
    Value = #{value => String},
    {bad_value, {call, echo, [Value]}, {bad_value, Value}};
invalid_case(2, String) ->
    {invalid_name, {call, echo, [{struct, [{"value", String}]}]},
        {invalid_name, "value"}};
invalid_case(3, _String) ->
    {unknown_member, {call, echo, [{struct, [invalid_member]}]},
        {unknown_member, [invalid_member]}};
invalid_case(4, String) ->
    {bad_array_value, {call, echo, [{array, [String, invalid_value]}]},
        {bad_value, invalid_value}};
invalid_case(5, String) ->
    Value = {invalid_string, String},
    {bad_fault_string, {response, {fault, -32000, Value}}, {bad_string, Value}};
invalid_case(6, String) ->
    Term = {response, [String, String]},
    {multiple_response_params, Term, {bad_payload, Term}};
invalid_case(7, String) ->
    Term = {call, "echo", [String]},
    {invalid_method_name, Term, {bad_payload, Term}}.

%% Independent XML construction for the three decoder fixtures. Data is
%% escaped once and the only markup is these fixed literal fragments.
value_xml({struct, Members}) ->
    ["<struct>", [["<member><name>", member_name(Name), "</name><value>",
        value_xml(Value), "</value></member>"] || {Name, Value} <- Members], "</struct>"];
value_xml({array, Values}) ->
    ["<array><data>", [["<value>", value_xml(Value), "</value>"] ||
        Value <- Values], "</data></array>"];
value_xml(Value) when is_integer(Value) -> ["<int>", integer_to_list(Value), "</int>"];
value_xml(true) -> "<boolean>1</boolean>";
value_xml(false) -> "<boolean>0</boolean>";
value_xml(Value) when is_float(Value) ->
    ["<double>", float_to_list(Value, [short]), "</double>"];
value_xml({date, Date}) -> ["<dateTime.iso8601>", Date, "</dateTime.iso8601>"];
value_xml({base64, Value}) -> ["<base64>", Value, "</base64>"];
value_xml(Value) when is_list(Value) -> ["<string>", escape(Value), "</string>"].

member_name(value) -> "value";
member_name(count) -> "count";
member_name(enabled) -> "enabled";
member_name(items) -> "items".

escape([]) -> [];
escape([$& | Rest]) -> ["&amp;", escape(Rest)];
escape([$< | Rest]) -> ["&lt;", escape(Rest)];
escape([$> | Rest]) -> ["&gt;", escape(Rest)];
escape([$" | Rest]) -> ["&quot;", escape(Rest)];
escape([$' | Rest]) -> ["&apos;", escape(Rest)];
escape([Byte | Rest]) -> [Byte | escape(Rest)].

check(true, _Property) -> ok;
check(false, Property) -> error({xmlrpc_flow_contract, Property}).
