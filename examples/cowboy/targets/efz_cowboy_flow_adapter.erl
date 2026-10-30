%% Optional semantic feedback for native payload inputs. Ordinary harnesses
%% never call this module or the compiled Gleam model.
-module(efz_cowboy_flow_adapter).
-behaviour(efz_semantic_adapter).
-export([descriptor/0, prepare/3, code_dependencies/1, generate/2, mutate/4,
    observe/3, shrink/2]).

descriptor() -> #{id => <<"cowboy_data_flow">>, api_version => 1,
    model_version => 1, observer_version => 1, recipe_version => 1,
    operations_version => 1, capabilities => [generation, mutation, observation, shrink],
    operations => [0, 1, 2], model_modules => [efz_term_model], properties => []}.

prepare(Target, #{surface := Surface} = Options, #{bytes := Max}) ->
    case map_size(Options) =:= 1 andalso lists:member(Surface, efz_cowboy_suite:surfaces())
        andalso Target =:= efz_cowboy_suite:target(Surface)
        andalso Max =< 1024 andalso Max >= 1 of
        true -> {ok, #{surface => Surface, max_bytes => Max}};
        false -> {error, invalid_cowboy_flow_adapter}
    end;
prepare(_, _, _) -> {error, invalid_cowboy_flow_adapter}.

code_dependencies(#{surface := Surface}) ->
    Helpers = case Surface of
        http1 -> [efz_cowboy_long_target, efz_cowboy_stream, efz_cowboy_transport];
        _ -> []
    end,
    #{semantic => [efz_term_codec, efz_cowboy_suite], target => lists:usort(
        [efz_cowboy_flow | Helpers ++ efz_cowboy_suite:modules(Surface)])}.

generate(I, #{surface := Surface, max_bytes := Max}) when is_integer(I), I >= 0 ->
    {ok, bounded(efz_cowboy_flow:sample(Surface, I), Max)}.

mutate(Input, Op, #{choice := Choice}, #{surface := Surface, max_bytes := Max})
    when is_binary(Input), is_integer(Choice), Choice >= 0, Choice =< 65535 ->
    Output = case Op of
        0 -> case Input of <<>> -> <<(Choice rem 8)>>;
            <<_, Tail/binary>> -> <<(Choice rem 8), Tail/binary>> end;
        1 -> bounded(<<Input/binary, (Choice rem 256)>>, Max);
        2 -> bounded(efz_cowboy_flow:sample(Surface, Choice), Max)
    end,
    {ok, Output, #{choice => Choice, operation => Op}};
mutate(_, _, _, _) -> {error, invalid_cowboy_flow_mutation}.

observe(_Input, Outcome, _) ->
    {Status, Value} = case Outcome of
        {ok, {accepted, V}} -> {0, V};
        {ok, {rejected, _}} -> {1, undefined};
        {ok, {incomplete, _}} -> {2, undefined};
        {crash, _, _, _} -> {3, undefined};
        {exit, _} -> {3, undefined};
        {timeout, _} -> {4, undefined};
        _ -> {5, undefined}
    end,
    S = efz_term_codec:summary(Value, #{nodes => 128, depth => 8,
        bytes => 1024, collection => 32, operations => 1}),
    %% The generated module is deliberately absent in the default profile.
    Base = model(observe, [Status, maps:get(classes, S),
        maps:get(nodes, S), maps:get(depth, S), maps:get(truncated, S), 0]),
    {ok, lists:usort(Base ++ result_features(Value))}.

result_features(#{body := B}) when is_binary(B) -> [80 + bucket(byte_size(B))];
result_features(#{value := B}) when is_binary(B) -> [80 + bucket(byte_size(B))];
result_features(#{body_bytes := N, framing := F}) -> [80 + bucket(N), 96 + F];
result_features(#{route := R}) -> [case R of item -> 104; files -> 105; root -> 106 end];
result_features(#{header := Name}) -> [112 + header_index(Name)];
result_features(#{headers := Headers}) -> [128 + bucket(byte_size(
    proplists:get_value(<<"x-efz-value">>, Headers, <<>>)))];
result_features(_) -> [].
header_index(<<"content-length">>) -> 0;
header_index(<<"content-type">>) -> 1;
header_index(<<"range">>) -> 2;
header_index(<<"authorization">>) -> 3;
header_index(<<"accept-encoding">>) -> 4;
header_index(<<"connection">>) -> 5.
bucket(0) -> 0;
bucket(1) -> 1;
bucket(N) when N =< 4 -> 2;
bucket(N) when N =< 16 -> 3;
bucket(N) when N =< 64 -> 4;
bucket(N) when N =< 125 -> 5;
bucket(N) when N =< 255 -> 6;
bucket(_) -> 7.

shrink(Input, _) when is_binary(Input) ->
    N = byte_size(Input),
    {ok, lists:usort([binary:part(Input, 0, K) || K <- [0, N div 2, max(0, N - 1)],
        K < N])}.
bounded(B, Max) -> binary:part(B, 0, min(byte_size(B), Max)).
model(Function, Arguments) -> erlang:apply(efz_term_model, Function, Arguments).
