%% Optional result observation for bounded payload-to-XML-RPC API flows.
-module(efz_xmlrpc_flow_adapter).
-behaviour(efz_semantic_adapter).
-export([descriptor/0, prepare/3, code_dependencies/1, generate/2, mutate/4,
    observe/3, shrink/2]).

descriptor() -> #{id => <<"xmlrpc_data_flow">>, api_version => 1,
    model_version => 1, observer_version => 1, recipe_version => 1,
    operations_version => 1, capabilities => [generation, mutation, observation, shrink],
    operations => [0, 1, 2], model_modules => [efz_term_model], properties => []}.

prepare(Target, #{surface := Surface} = Options, #{bytes := Max}) ->
    case map_size(Options) =:= 1 andalso lists:member(Surface, efz_xmlrpc_suite:surfaces())
        andalso Target =:= efz_xmlrpc_suite:target(Surface)
        andalso is_integer(Max) andalso Max >= 1 andalso Max =< 512 of
        true -> {ok, #{surface => Surface, max_bytes => Max}};
        false -> {error, invalid_xmlrpc_flow_adapter}
    end;
prepare(_, _, _) -> {error, invalid_xmlrpc_flow_adapter}.

code_dependencies(#{surface := Surface}) ->
    #{semantic => [efz_term_codec, efz_xmlrpc_suite],
      target => lists:usort([efz_xmlrpc_flow | efz_xmlrpc_suite:modules(Surface)])}.

generate(I, #{surface := Surface, max_bytes := Max}) when is_integer(I), I >= 0 ->
    {ok, bounded(efz_xmlrpc_flow:sample(Surface, I), Max)}.

mutate(Input, Op, #{choice := Choice}, #{surface := Surface, max_bytes := Max})
    when is_binary(Input), is_integer(Choice), Choice >= 0, Choice =< 65535,
         is_integer(Op), Op >= 0, Op =< 2 ->
    Output = case Op of
        0 -> case Input of <<>> -> <<(Choice rem 8)>>;
            <<_, Tail/binary>> -> <<(Choice rem 8), Tail/binary>> end;
        1 -> bounded(<<Input/binary, (Choice rem 256)>>, Max);
        2 -> bounded(efz_xmlrpc_flow:sample(Surface, Choice), Max)
    end,
    {ok, Output, #{choice => Choice, operation => Op}};
mutate(_, _, _, _) -> {error, invalid_xmlrpc_flow_mutation}.

observe(_Input, Outcome, _) ->
    {Status, Value, Class} = case Outcome of
        {ok, {accepted, V}} -> {0, V, 0};
        {ok, {rejected, V}} -> {1, V, 1};
        {ok, {incomplete, V}} -> {2, V, 2};
        {crash, _, _, _} -> {3, undefined, 2};
        {exit, _} -> {3, undefined, 2};
        {timeout, _} -> {4, undefined, 2};
        _ -> {5, undefined, 2}
    end,
    Actual = case Value of #{payload := Payload} -> Payload; _ -> Value end,
    S = efz_term_codec:summary(Actual, #{nodes => 128, depth => 8,
        bytes => 512, collection => 32, operations => 1}),
    Base = model(observe, [Status, maps:get(classes, S), maps:get(nodes, S),
        maps:get(depth, S), maps:get(truncated, S), Class]),
    {ok, lists:usort(Base ++ result_features(Value))}.

result_features(Value) when is_map(Value) ->
    Type = case maps:find(type, Value) of
        {ok, Kind} -> [80 + type_index(Kind)]; error -> [] end,
    Count = case maps:find(count, Value) of
        {ok, N} when is_integer(N), N >= 0 -> [112 + bucket(N)]; _ -> [] end,
    Size = case maps:find(encoded_bytes, Value) of
        {ok, N2} when is_integer(N2), N2 >= 0 -> [128 + bucket(N2)]; _ -> [] end,
    ErrorMatch = case maps:find(expected_error_match, Value) of
        {ok, true} -> [144]; {ok, false} -> [145]; error -> [] end,
    Method = case maps:find(method, Value) of
        {ok, echo} -> [104]; {ok, sum} -> [105]; _ -> [] end,
    Type ++ Count ++ Size ++ ErrorMatch ++ Method;
result_features(_) -> [].

type_index(integer) -> 0;
type_index(boolean) -> 1;
type_index(string) -> 2;
type_index(double) -> 3;
type_index(date) -> 4;
type_index(base64) -> 5;
type_index(array) -> 6;
type_index(struct) -> 7;
type_index(fault) -> 8;
type_index(echo) -> 9;
type_index(sum) -> 10;
type_index(bad_payload) -> 12;
type_index(bad_value) -> 13;
type_index(invalid_name) -> 14;
type_index(unknown_member) -> 15;
type_index(bad_array_value) -> 16;
type_index(bad_fault_string) -> 17;
type_index(multiple_response_params) -> 18;
type_index(invalid_method_name) -> 19;
type_index(_) -> 11.
bucket(0) -> 0;
bucket(1) -> 1;
bucket(N) when N =< 4 -> 2;
bucket(N) when N =< 16 -> 3;
bucket(N) when N =< 64 -> 4;
bucket(N) when N =< 255 -> 5;
bucket(N) when N =< 1024 -> 6;
bucket(_) -> 7.

shrink(Input, _) when is_binary(Input) ->
    N = byte_size(Input),
    {ok, lists:usort([binary:part(Input, 0, K) || K <- [0, N div 2, max(0, N - 1)],
        K < N])}.
bounded(B, Max) -> binary:part(B, 0, min(byte_size(B), Max)).
model(Function, Arguments) -> erlang:apply(efz_term_model, Function, Arguments).
