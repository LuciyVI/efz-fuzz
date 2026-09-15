%% Source-level clause/outcome coverage. Compilation has no runtime dependency.
-module(efz_instrument_pt).
-export([parse_transform/2, parse_transform_info/0]).

parse_transform_info() -> #{error_location => column}.

parse_transform(Forms, Options) ->
    case [X || {attribute, _, efz_manifest, X} <- Forms] of
        [] -> ok;
        _ -> error(efz_already_instrumented)
    end,
    [M] = [X || {attribute, _, module, X} <- Forms],
    case lists:member(M, proplists:get_value(efz_modules, Options, [])) of
        true -> ok;
        false -> error({efz_module_not_selected, M})
    end,
    case code:which(M) of
        Path when is_list(Path) ->
            case lists:prefix(code:root_dir() ++ "/", Path) of
                true -> error({efz_otp_module, M});
                false -> ok
            end;
        preloaded -> error({efz_otp_module, M});
        _ -> ok
    end,
    case lists:prefix("efz_", atom_to_list(M)) andalso
         lists:member(M, [efz_instrument_pt, efz_instrument, efz_cov_rt, efz_cov,
                         efz_cov_manifest, efz_feedback, efz_executor, efz, efz_app,
                         efz_cli, efz_config, efz_corpus, efz_corpus_store, efz_crash, efz_crash_store, efz_fuzzer, efz_mutator,
                         efz_fs, efz_input, efz_guardian, efz_cov_integrity, efz_replay, efz_replay_cli,
                         efz_mutator_random, efz_stats, efz_sup, efz_target, efz_worker, efz_worker_sup,
                         efz_mutation, efz_mutation_plan, efz_dictionary, efz_recipe]) of
        true -> error({efz_internal_module, M});
        false -> ok
    end,
    Root = proplists:get_value(efz_source_root, Options, "."),
    Canonical = [canonical_form(F, Root) || F <- Forms],
    IdentityOpts = proplists:get_value(efz_identity_options, Options, []),
    CompilerVsn = compile:module_info(md5),
    Build = crypto:hash(sha256, term_to_binary({1, erlang:system_info(otp_release),
                                             CompilerVsn, Canonical, IdentityOpts})),
    S0 = #{module => M, build => Build, next => 1, probes => [],
           diagnostics => [], root => Root, file => undefined},
    {Transformed, S} = lists:mapfoldl(fun form/2, S0, Forms),
    Ds = lists:reverse(maps:get(diagnostics, S)),
    case {proplists:get_value(efz_strict, Options, true), Ds} of
        {true, [_ | _]} -> error({efz_incomplete_instrumentation, Ds});
        {false, [_ | _]} -> io:format(standard_error, "EFZ incomplete instrumentation ~p: ~p~n", [M, Ds]);
        _ -> ok
    end,
    Manifest = #{schema_version => 1, instrumentation_version => 1,
                 metric => clause_outcome_probe, module => M, build_id => Build,
                 toolchain => #{otp => erlang:system_info(otp_release), compiler => CompilerVsn},
                 probes => lists:reverse(maps:get(probes, S)), limitations => Ds},
    %% Attributes must precede function definitions for erl_lint.
    {Prefix, Rest} = lists:splitwith(fun(F) -> element(1, F) =/= function end, Transformed),
    Prefix ++ [{attribute, erl_anno:new(1), efz_manifest, Manifest} | Rest].

canonical_form({attribute, A, file, {File, Line}}, Root) ->
    {attribute, canonical_anno(A, Root), file, {source_file(File, Root), Line}};
canonical_form(F, Root) ->
    erl_parse:map_anno(fun(A) -> canonical_anno(A, Root) end, F).
canonical_anno(A, Root) ->
    case erl_anno:file(A) of
        undefined -> A;
        F -> erl_anno:set_file(source_file(F, Root), A)
    end.
source_file(File, Root) ->
    Abs = normalized_path(File),
    Prefix = normalized_path(Root) ++ "/",
    case lists:prefix(Prefix, Abs) of
        true -> lists:nthtail(length(Prefix), Abs);
        false -> Abs
    end.

normalized_path(Path) ->
    Parts = lists:foldl(fun
        (".", Acc) -> Acc;
        ("..", [_ | Rest]) -> Rest;
        (Part, Acc) -> [Part | Acc]
    end, [], filename:split(filename:absname(Path))),
    filename:join(lists:reverse(Parts)).

form({attribute, _, file, {File, _}} = F, S) ->
    {F, S#{file => source_file(File, maps:get(root, S))}};
form({attribute, A, record, {Name, Fields}} = F, S) ->
    case lists:all(fun literal_record_default/1, Fields) of
        true -> {F, S};
        false ->
            D = #{construct => record_default, structural_location => [{record, Name}],
                  line => erl_anno:line(A), source_file => maps:get(file, S),
                  reason => preserved_without_internal_probes},
            {F, S#{diagnostics => [D | maps:get(diagnostics, S)]}}
    end;
form({function, A, N, Ar, Cs}, S) ->
    {New, S1} = clauses(Cs, function_clause, [{function, N, Ar}], S#{function => {N, Ar}}),
    {{function, A, N, Ar, New}, S1};
form(F, S) -> {F, S}.

literal_record_default({typed_record_field, F, _}) -> literal_record_default(F);
literal_record_default({record_field, _, _}) -> true;
literal_record_default({record_field, _, _, V}) ->
    %% normalise accepts literal data and rejects executable expressions.
    try erl_parse:normalise(V) of _ -> true catch error:_ -> false end.

clauses(Cs, Kind, Path, S) ->
    indexed(Cs, fun({clause, A, Patterns, Guards, Body}, P, Acc) ->
        {B, Next} = body(Body, Kind, A, P, Acc),
        {{clause, A, Patterns, Guards, B}, Next}
    end, Path, S).
body(Es, Kind, A, Path, S) ->
    {Probe, S1} = probe(Kind, A, Path, S),
    {New, S2} = exprs(Es, Path ++ [body], S1),
    {[Probe | New], S2}.
probe(Kind, A, Path, S = #{next := Id, module := M, build := B, probes := Ps}) ->
    {F, Ar} = maps:get(function, S),
    Entry = #{probe_id => Id, function => F, arity => Ar, kind => Kind,
              structural_location => Path, source_file => maps:get(file, S),
              line => erl_anno:line(A), column => erl_anno:column(A)},
    Call = {call, A, {remote, A, {atom, A, efz_cov_rt}, {atom, A, hit}},
            [erl_parse:map_anno(fun(_) -> A end, erl_parse:abstract({M, B, Id}))]},
    {Call, S#{next => Id + 1, probes => [Entry | Ps]}}.

indexed(Es, Fun, Path, S) ->
    lists:mapfoldl(fun({E, I}, Acc) -> Fun(E, Path ++ [I], Acc) end,
                  S, lists:zip(Es, lists:seq(1, length(Es)))).
exprs(Es, P, S) -> indexed(Es, fun expr/3, P, S).

%% Only expression positions reach expr/3. Patterns, guards, record names and
%% binary type specifiers are deliberately never passed to it.
expr({T, _, _} = E, _, S) when T =:= var; T =:= atom; T =:= integer;
                                    T =:= float; T =:= char; T =:= string -> {E, S};
expr({nil, _} = E, _, S) -> {E, S};
expr({cons, A, H, T}, P, S) ->
    {[H1, T1], S1} = exprs([H, T], P, S), {{cons, A, H1, T1}, S1};
expr({tuple, A, Es}, P, S) ->
    {New, S1} = exprs(Es, P, S), {{tuple, A, New}, S1};
expr({block, A, Es}, P, S) ->
    {New, S1} = exprs(Es, P, S), {{block, A, New}, S1};
expr({match, A, Pattern, E}, P, S) ->
    {New, S1} = expr(E, P ++ [value], S), {{match, A, Pattern, New}, S1};
expr({op, A, Op, E}, P, S) ->
    {New, S1} = expr(E, P ++ [operand], S), {{op, A, Op, New}, S1};
expr({op, A, Op, L, R}, P, S) ->
    {[L1, R1], S1} = exprs([L, R], P, S), {{op, A, Op, L1, R1}, S1};
expr({call, A, F, Args}, P, S) ->
    {F1, S1} = expr(F, P ++ [callee], S),
    {Args1, S2} = exprs(Args, P ++ [arguments], S1), {{call, A, F1, Args1}, S2};
expr({remote, A, M, F}, P, S) ->
    {[M1, F1], S1} = exprs([M, F], P, S), {{remote, A, M1, F1}, S1};
expr({'case', A, E, Cs}, P, S) ->
    {E1, S1} = expr(E, P ++ [subject], S),
    {Cs1, S2} = clauses(Cs, case_clause, P ++ [case_clauses], S1),
    {{'case', A, E1, Cs1}, S2};
expr({'if', A, Cs}, P, S) ->
    {Cs1, S1} = clauses(Cs, if_clause, P ++ [if_clauses], S), {{'if', A, Cs1}, S1};
expr({'receive', A, Cs}, P, S) ->
    {Cs1, S1} = clauses(Cs, receive_clause, P ++ [receive_clauses], S),
    {{'receive', A, Cs1}, S1};
expr({'receive', A, Cs, Timeout, After}, P, S) ->
    {Cs1, S1} = clauses(Cs, receive_clause, P ++ [receive_clauses], S),
    {T1, S2} = expr(Timeout, P ++ [timeout], S1),
    {B1, S3} = body(After, receive_after, body_anno(After, A), P ++ [receive_after], S2),
    {{'receive', A, Cs1, T1, B1}, S3};
expr({'try', A, Es, Of, Catch, After}, P, S) ->
    {Es1, S1} = body(Es, try_body, body_anno(Es, A), P ++ [try_body], S),
    {Of1, S2} = clauses(Of, try_of_clause, P ++ [try_of], S1),
    {Catch1, S3} = clauses(Catch, catch_clause, P ++ [try_catch], S2),
    {After1, S4} = case After of
        [] -> {[], S3};
        _ -> body(After, try_after, body_anno(After, A), P ++ [try_after], S3)
    end,
    {{'try', A, Es1, Of1, Catch1, After1}, S4};
expr({'catch', A, E}, P, S) ->
    {E1, S1} = expr(E, P ++ [caught], S), {{'catch', A, E1}, S1};
expr({'fun', A, {clauses, Cs}}, P, S) ->
    {Cs1, S1} = clauses(Cs, fun_clause, P ++ [fun_clauses], S),
    {{'fun', A, {clauses, Cs1}}, S1};
expr({named_fun, A, Name, Cs}, P, S) ->
    {Cs1, S1} = clauses(Cs, named_fun_clause, P ++ [named_fun_clauses], S),
    {{named_fun, A, Name, Cs1}, S1};
expr({'fun', _, {function, _, _}} = E, _, S) -> {E, S};
expr({'fun', A, {function, M, F, Ar}}, P, S) ->
    {New, S1} = exprs([M, F, Ar], P, S),
    [M1, F1, Ar1] = New, {{'fun', A, {function, M1, F1, Ar1}}, S1};
expr({map, A, Fields}, P, S) ->
    {Fs, S1} = map_fields(Fields, P, S), {{map, A, Fs}, S1};
expr({map, A, Base, Fields}, P, S) ->
    {B1, S1} = expr(Base, P ++ [base], S),
    {Fs, S2} = map_fields(Fields, P ++ [fields], S1), {{map, A, B1, Fs}, S2};
expr({record, A, Name, Fields}, P, S) ->
    {Fs, S1} = record_fields(Fields, P, S), {{record, A, Name, Fs}, S1};
expr({record, A, Base, Name, Fields}, P, S) ->
    {B1, S1} = expr(Base, P ++ [base], S),
    {Fs, S2} = record_fields(Fields, P ++ [fields], S1), {{record, A, B1, Name, Fs}, S2};
expr({record_field, A, Base, Name, Field}, P, S) ->
    {B1, S1} = expr(Base, P ++ [base], S), {{record_field, A, B1, Name, Field}, S1};
expr({record_index, _, _, _} = E, _, S) -> {E, S};
expr({bin, A, Elements}, P, S) ->
    {New, S1} = indexed(Elements, fun({bin_element, BA, E, Size, Types}, BP, Acc) ->
        {E1, Acc1} = expr(E, BP ++ [value], Acc),
        {Size1, Acc2} = case Size of
            default -> {default, Acc1};
            _ -> expr(Size, BP ++ [size], Acc1)
        end,
        {{bin_element, BA, E1, Size1, Types}, Acc2}
    end, P, S), {{bin, A, New}, S1};
expr(E, P, S) ->
    %% Includes lc/bc/mc and maybe: preserve the entire expression, never
    %% accidentally instrument binding/filter/feature-dependent contexts.
    Tag = element(1, E),
    D = #{construct => Tag, structural_location => P, source_file => maps:get(file, S),
          line => erl_anno:line(element(2, E)), reason => preserved_without_internal_probes},
    {E, S#{diagnostics => [D | maps:get(diagnostics, S)]}}.

map_fields(Fs, P, S) ->
    indexed(Fs, fun({Kind, A, K, V}, FP, Acc) ->
        {[K1, V1], Next} = exprs([K, V], FP, Acc), {{Kind, A, K1, V1}, Next}
    end, P, S).
record_fields(Fs, P, S) ->
    indexed(Fs, fun({record_field, A, Name, V}, FP, Acc) ->
        {V1, Next} = expr(V, FP, Acc), {{record_field, A, Name, V1}, Next}
    end, P, S).
body_anno([E | _], _) -> element(2, E);
body_anno([], A) -> A.
