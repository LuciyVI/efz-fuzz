-module(efz_config).
-export([defaults/0, prepare/1]).

defaults() -> #{max_input_bytes => efz_input:default_limit(), timeout => 100, workers => 1, mutator => efz_mutator_random, mutation_mode => random,
                coverage => automatic, coverage_backend => ets, coverage_validation => prepared, coverage_policy => diagnostic, max_iterations => infinity,
                crash_dir => "_build/efz-crashes",crash_policy=>efz_crash:defaults()}.
prepare(C0) when is_map(C0) ->
    Allowed = maps:keys(defaults()) ++ [target, seeds, artifacts, mutation, random_seed, selection_seed,
                                      corpus_dir, corpus_build_policy],
    case lists:sort(maps:keys(C0) -- Allowed) of
        [] -> prepare_known(C0);
        Unknown -> {error, {unknown_campaign_keys, Unknown}}
    end;
prepare(_) -> {error, campaign_configuration_must_be_map}.
prepare_known(C0) ->
    Merged = maps:merge(defaults(), C0),
    C = case {maps:get(mutation_mode,Merged),maps:is_key(max_iterations,C0)} of
        {staged,false}->Merged#{max_iterations=>1000}; _->Merged
    end,
    case [K || K <- [target, seeds], not maps:is_key(K, C)] of
        [] -> case [K || {K,V} <- lists:sort(maps:to_list(C)), not valid_field(K,V)] of
            [] -> case {maps:get(seeds, C), maps:is_key(corpus_dir, C), maps:is_key(corpus_build_policy, C)} of
                {[], false, _} -> {error, {invalid_campaign_option, seeds}};
                {_, false, true} -> {error, corpus_build_policy_requires_corpus_dir};
                {Seeds, true, _} -> prepare_inputs(C#{seeds=>unique_inputs(Seeds)});
                _ -> prepare_inputs(C)
            end;
            [Bad | _] -> {error, {invalid_campaign_option, Bad}}
        end;
        Missing -> {error, {missing_campaign_keys, Missing}}
    end.
prepare_inputs(C) ->
    case [E || B <- maps:get(seeds,C), {error,E} <- [efz_input:check(B,maps:get(max_input_bytes,C),initial_seed)]] of
        [] -> case efz_crash:prepare(maps:get(crash_policy,C)) of
            {ok,P}->prepare_mutation(C#{crash_policy=>P}); Error->Error end;
        [Why|_] -> {error,Why}
    end.
prepare_mutation(#{mutation_mode:=random}=C) ->
    case maps:is_key(mutation,C) of
        true->{error,mutation_options_require_staged_mode};
        false->prepare_coverage(C)
    end;
prepare_mutation(#{mutation_mode:=staged,max_iterations:=N,mutator:=efz_mutator_random}=C)
  when is_integer(N),N>=0,N=<1000000 ->
    Options = maps:get(mutation,C,#{}),
    case maps:is_key(max_input_bytes,Options) of
        true -> {error,{campaign_level_option,max_input_bytes}};
        false -> case efz_mutation_plan:prepare(Options#{max_input_bytes=>maps:get(max_input_bytes,C)},maps:get(seeds,C)) of
            {ok,Mutation}->prepare_coverage(C#{mutation=>Mutation});
            Error->Error
        end
    end;
prepare_mutation(_) -> {error,invalid_mutation_mode_or_budget}.
valid_field(target, V) -> is_atom(V);
valid_field(mutator, V) -> is_atom(V);
valid_field(workers, V) -> V =:= 1;
valid_field(seeds, V) -> is_list(V) andalso lists:all(fun is_binary/1, V);
valid_field(max_input_bytes, V) -> efz_input:valid_limit(V);
valid_field(timeout, V) -> is_integer(V) andalso V >= 0;
valid_field(max_iterations, V) -> V =:= infinity orelse (is_integer(V) andalso V >= 0);
valid_field(mutation_mode, V) -> lists:member(V, [random, staged]);
valid_field(mutation, V) -> is_map(V);
valid_field(coverage, V) -> lists:member(V, [automatic, manual]);
valid_field(coverage_backend, V) -> lists:member(V, [ets, ets_member]);
valid_field(coverage_validation, V) -> lists:member(V, [per_execution, prepared]);
valid_field(coverage_policy, V) -> lists:member(V, [diagnostic, strict]);
valid_field(crash_policy,V) -> is_map(V);
valid_field(artifacts, V) -> is_list(V) andalso lists:all(fun is_map/1, V);
valid_field(corpus_dir, V) -> valid_field(crash_dir, V);
valid_field(corpus_build_policy, V) -> lists:member(V, [reject, recalibrate]);
valid_field(crash_dir, V) when is_binary(V) -> byte_size(V) > 0 andalso binary:match(V, <<0>>) =:= nomatch;
valid_field(crash_dir, V) -> is_list(V) andalso V =/= [] andalso
    lists:all(fun(C) -> is_integer(C) andalso C > 0 andalso C =< 16#10ffff end, V);
valid_field(selection_seed, undefined) -> true;
valid_field(K, {A,B,C}) when K =:= random_seed; K =:= selection_seed ->
    lists:all(fun(N) -> is_integer(N) andalso N >= 0 end, [A,B,C]);
valid_field(_, _) -> false.
prepare_coverage(#{coverage := manual} = C) -> check_target(C#{manifests => []});
prepare_coverage(#{coverage := automatic} = C) ->
    case efz_instrument:preflight(maps:get(artifacts, C, [])) of
        {ok, Ms} -> check_target(C#{manifests => Ms});
        Error -> Error
    end;
prepare_coverage(_) -> {error, unsupported_coverage_mode}.
check_target(#{target := M, mutator := Mu} = C) ->
    case callback(target, M, run, 1) of
        ok -> case callback(mutator, Mu, mutate, 2) of
            ok -> pin_target(C);
            Error -> Error
        end;
        Error -> Error
    end.

pin_target(#{target:=M,manifests:=Ms}=C) ->
    case efz_cov_integrity:selected(Ms) of
        {ok,Selected} -> case efz_cov_integrity:pin(M,Selected) of
            {ok,Pins} -> prepare_corpus(C#{execution_identities=>Pins});
            Error -> Error
        end;
        Error -> Error
    end.

prepare_corpus(#{corpus_dir := Dir0} = C) ->
    Dir = filename:absname(Dir0), Identity = efz_corpus_store:identity(C),
    Policy = maps:get(corpus_build_policy, C, reject),
    case efz_corpus_store:restore(Dir, Identity, Policy, maps:get(max_input_bytes,C)) of
        {ok, Rows, Diagnostics} ->
            %% Keep initial insertion order, then append saved contents in hash
            %% order. Integer IDs are assigned afresh by the corpus owner.
            Seeds = unique_inputs(maps:get(seeds, C) ++ [maps:get(input, R) || R <- Rows]),
            case Seeds of
                [] -> {error, {empty_persistent_corpus,Dir}};
                _ -> {ok, C#{seeds => Seeds, corpus_store => #{dir => Dir, identity => Identity,
                    max_input_bytes => maps:get(max_input_bytes,C),
                    build_policy => Policy, restored => Rows, restored_inputs => length(Rows),
                    diagnostics => Diagnostics}}}
            end;
        {error, Why} -> {error, {corpus_restore, Why}}
    end;
prepare_corpus(C) -> {ok, C}.
unique_inputs(Inputs) ->
    {_, Rev} = lists:foldl(fun(B, {Seen, Acc}) ->
        H = crypto:hash(sha256,B),
        case maps:is_key(H,Seen) of true->{Seen,Acc}; false->{Seen#{H=>true},[B|Acc]} end
    end, {#{},[]}, Inputs),
    lists:reverse(Rev).
callback(Kind, M, F, A) ->
    case code:ensure_loaded(M) of
        {module, M} -> case erlang:function_exported(M, F, A) of
            true -> ok;
            false -> {error, {missing_callback, Kind, M, F, A}}
        end;
        {error, Why} -> {error, {module_unavailable, Kind, M, Why}}
    end.
