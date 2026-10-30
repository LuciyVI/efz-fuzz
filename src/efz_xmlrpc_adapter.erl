%% XML-RPC is a wire-format plugin, not a generic term codec. The Gleam model
%% parses/serializes a bounded independent subset; only the harness calls XML-RPC.
-module(efz_xmlrpc_adapter).
-behaviour(efz_semantic_adapter).
-export([descriptor/0, prepare/3, code_dependencies/1, generate/2, mutate/4, observe/3, oracle/3, shrink/2]).

descriptor() ->
    #{id => <<"efz.xmlrpc.method_call">>, api_version => 1, model_version => 1,
      observer_version => 1, recipe_version => 1, operations_version => 1,
      capabilities => [generation, mutation, observation, oracle, shrink],
      operations => [0, 1, 2, 3, 4, 5], model_modules => [efz_xmlrpc_model],
      properties => [{xmlrpc_model_agreement, 1}]}.

code_dependencies(_) ->
    #{semantic => [], target => [xmlrpc_decode, xmlrpc_util, xmerl_scan]}.

prepare(Target, Options, Limits) when is_atom(Target), is_map(Options), is_map(Limits) ->
    String = maps:get(string_bytes, Options, 128),
    Methods = maps:get(methods, Options, [<<"echo">>, <<"efz_missing_name">>]),
    Unknown = maps:keys(maps:without([string_bytes, methods], Options)),
    case Unknown =:= [] andalso is_integer(String) andalso String > 0 andalso String =< 4096
         andalso valid_methods(Methods, String, 0) andalso valid_limits(Limits) of
        false -> {error, {invalid_xmlrpc_options, Options, Limits}};
        true ->
            _ = code:ensure_loaded(Target),
            case erlang:function_exported(Target, semantic_contract, 0) of
                false -> {error, {xmlrpc_harness_contract_missing, Target}};
                true ->
                    case Target:semantic_contract() of
                        #{format := xmlrpc_method_call, version := 1,
                          entrypoint := {xmlrpc_decode, payload, 1}, encoding := ascii} ->
                            case code:ensure_loaded(xmlrpc_decode) of
                                {module, xmlrpc_decode} ->
                                    case erlang:function_exported(xmlrpc_decode, payload, 1) of
                                        true -> case model_available() of
                                            ok -> {ok, #{limits => model_limits(Limits, String),
                                                          methods => Methods}};
                                            Error -> Error
                                        end;
                                        false -> {error, xmlrpc_payload_missing}
                                    end;
                                Error -> {error, {xmlrpc_dependency_unavailable, Error}}
                            end;
                        Metadata -> {error, {incompatible_xmlrpc_harness, Metadata}}
                    end
            end
    end;
prepare(_, _, _) -> {error, invalid_xmlrpc_prepare_arguments}.

model_available() ->
    case code:ensure_loaded(efz_xmlrpc_model) of
        {module, efz_xmlrpc_model} ->
            Exports=[{version,0},{decode,2},{encode,2},{generate,3},
                {mutate,4},{check,2},{observe,2}],
            case lists:all(fun({F,A})->erlang:function_exported(efz_xmlrpc_model,F,A) end,Exports) of
                true -> case model(version,[]) of
                    1 -> ok; _ -> {error,xmlrpc_model_version_mismatch} end;
                false -> {error,xmlrpc_model_abi_mismatch}
            end;
        _ -> {error,xmlrpc_model_unavailable}
    end.

valid_limits(L) ->
    lists:all(fun({Key, Max}) ->
        Value = maps:get(Key, L, 0),
        is_integer(Value) andalso Value > 0 andalso Value =< Max
    end, [{bytes, 1048576}, {depth, 32}, {nodes, 4096}, {collection, 1024}])
        andalso maps:get(operations, L, 0) =:= 1.
model_limits(L, S) ->
    {limits, maps:get(bytes, L), maps:get(depth, L), maps:get(nodes, L),
     maps:get(collection, L), S}.
valid_methods([], _, N) -> N > 0;
valid_methods([B | Rest], S, N) when is_binary(B), byte_size(B) > 0, byte_size(B) =< S, N < 16 ->
    ascii(B) andalso valid_methods(Rest, S, N + 1);
valid_methods(_, _, _) -> false.
ascii(<<>>) -> true;
ascii(<<B, Rest/binary>>) when B >= 32, B =< 126 -> ascii(Rest);
ascii(_) -> false.

generate(Index, #{limits := Limits, methods := Methods}) when is_integer(Index), Index >= 0 ->
    Method = lists:nth(1 + ((Index div 9) rem length(Methods)), Methods),
    model_result(model(generate, [Index, Method, Limits])).

mutate(Raw, Operation, #{choice := Choice}, #{limits := Limits})
        when is_binary(Raw), is_integer(Operation), Operation >= 0, Operation =< 5,
             is_integer(Choice), Choice >= 0, Choice =< 65535 ->
    case model(decode, [Raw, Limits]) of
        {ok, Model} ->
            case model(mutate, [Model, Operation, Choice, Limits]) of
                {ok, Next} ->
                    case model(encode, [Next, Limits]) of
                        {ok, Out} -> {ok, Out, #{schema => 1, choice => Choice}};
                        {error, Why} -> {skip, Why}
                    end;
                {error, Why} -> {skip, Why}
            end;
        {error, Why} -> {skip, Why}
    end;
mutate(_, _, _, _) -> {error, invalid_xmlrpc_mutation}.

observe(_Raw, Outcome, #{limits := Limits}) ->
    %% Summarize the already obtained actual result. In an observer+oracle
    %% iteration the raw model is parsed only by the oracle, not a second time
    %% merely to obtain result-structure features.
    case normalize_outcome(Outcome, Limits) of
        {ok, Model} -> {ok, lists:usort(model(observe, [0, Model]))};
        {error, _} -> {ok, outcome_features(Outcome)}
    end.
outcome_features({ok, {accepted, {call, _, _}}}) -> [0, 4];
outcome_features({ok, {accepted, {response, {fault, _, _}}}}) -> [0, 5, 6];
outcome_features({ok, {accepted, {response, _}}}) -> [0, 5];
outcome_features(Outcome) -> [status(Outcome)].
status({ok, {accepted, _}}) -> 0;
status({ok, {rejected, _}}) -> 1;
status({ok, rejected}) -> 1;
status({timeout, _}) -> 2;
status(timeout) -> 2;
status(_) -> 3.

oracle(Raw, {ok, _}=Outcome, #{limits := Limits}) ->
    Property = {xmlrpc_model_agreement, 1},
    case model(decode, [Raw, Limits]) of
        {error, Why} -> {inconclusive, Why};
        {ok, Expected} ->
            case normalize_outcome(Outcome, Limits) of
                {ok, Actual} ->
                    case model(check, [Expected, Actual]) of
                        true -> {pass, Property};
                        false -> {fail, Property}
                    end;
                {error, _} -> {fail, Property}
            end
    end;
oracle(_, _, _) -> {inconclusive,primary_outcome_unavailable}.

normalize_outcome({ok, {accepted, {call, Name, Values}}},
                  {limits, _, Depth, Nodes, Collection, String}) ->
    case {name(Name, String), normalize_values(Values, 1, Nodes - 1, Depth, Collection, String, 0, [])} of
        {{ok, N}, {ok, Vs, _}} -> {ok, {call, N, Vs}};
        _ -> {error, unsupported_target_result}
    end;
normalize_outcome(_, _) -> {error, target_not_accepted_call}.

name(Atom, String) when is_atom(Atom) -> bounded_binary(atom_to_binary(Atom, utf8), String);
name(List, String) when is_list(List) -> charlist(List, String, []);
name(_, _) -> {error, unsupported_name}.
bounded_binary(B, String) when byte_size(B) =< String ->
    case ascii(B) of true -> {ok, B}; false -> {error, unsupported_text} end;
bounded_binary(_, _) -> {error, text_limit}.
charlist([], _, Acc) -> {ok, list_to_binary(lists:reverse(Acc))};
charlist([C | Rest], Remaining, Acc) when is_integer(C), C >= 32, C =< 126, Remaining > 0 ->
    charlist(Rest, Remaining - 1, [C | Acc]);
charlist(_, _, _) -> {error, unsupported_text}.

normalize_values([], _, Nodes, _, _, _, _, Acc) -> {ok, lists:reverse(Acc), Nodes};
normalize_values([V | Rest], D, Nodes, Depth, Collection, String, Count, Acc) when Count < Collection ->
    case normalize_value(V, D, Nodes, Depth, Collection, String) of
        {ok, Value, Left} -> normalize_values(Rest, D, Left, Depth, Collection, String, Count + 1, [Value | Acc]);
        Error -> Error
    end;
normalize_values(_, _, _, _, _, _, _, _) -> {error, collection_limit}.
normalize_value(_, D, Nodes, Depth, _, _) when D > Depth; Nodes =< 0 -> {error, structure_limit};
normalize_value(V, _, Nodes, _, _, _) when is_integer(V), V >= -2147483648, V =< 2147483647 ->
    {ok, {xint, V}, Nodes - 1};
normalize_value(V, _, Nodes, _, _, _) when is_boolean(V) -> {ok, {xbool, V}, Nodes - 1};
normalize_value(V, _, Nodes, _, _, String) when is_list(V) ->
    case charlist(V, String, []) of {ok, S} -> {ok, {xstring, S}, Nodes - 1}; Error -> Error end;
normalize_value({array, Values}, D, Nodes, Depth, Collection, String) ->
    case normalize_values(Values, D + 1, Nodes - 1, Depth, Collection, String, 0, []) of
        {ok, Vs, Left} -> {ok, {xarray, Vs}, Left}; Error -> Error
    end;
normalize_value({struct, Members}, D, Nodes, Depth, Collection, String) ->
    case normalize_members(Members, D + 1, Nodes - 1, Depth, Collection, String, 0, []) of
        {ok, Ms, Left} -> {ok, {xstruct, Ms}, Left}; Error -> Error
    end;
normalize_value(_, _, _, _, _, _) -> {error, unsupported_value}.
normalize_members([], _, Nodes, _, _, _, _, Acc) -> {ok, lists:reverse(Acc), Nodes};
normalize_members([{N, V} | Rest], D, Nodes, Depth, Collection, String, Count, Acc)
        when Count < Collection, Nodes > 0 ->
    case {name(N, String), normalize_value(V, D, Nodes - 1, Depth, Collection, String)} of
        {{ok, Name}, {ok, Value, Left}} ->
            normalize_members(Rest, D, Left, Depth, Collection, String, Count + 1, [{member, Name, Value} | Acc]);
        _ -> {error, unsupported_member}
    end;
normalize_members(_, _, _, _, _, _, _, _) -> {error, member_limit}.

shrink(Raw, #{limits := Limits}) ->
    case model(decode, [Raw, Limits]) of
        {ok, {call, Name, Values}} ->
            Models = [{call, Name, []}] ++ case Values of
                [] -> [];
                [_ | Rest] -> [{call, Name, Rest}, {call, Name, [{xint, 0}]}]
            end,
            {ok, lists:usort([Bytes || Model <- Models,
                {ok, Bytes} <- [model(encode, [Model, Limits])],
                byte_size(Bytes) < byte_size(Raw)])};
        {error, Why} -> {skip, Why}
    end.
model_result({ok, Bytes}) -> {ok, Bytes};
model_result({error, Why}) -> {skip, Why}.

%% Optional model dependency is loaded by cold preflight, never an off-build.
model(Function, Args) -> erlang:apply(efz_xmlrpc_model, Function, Args).
