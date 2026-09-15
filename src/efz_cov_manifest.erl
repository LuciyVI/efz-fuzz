-module(efz_cov_manifest).
-export([validate/1, identities/1, validate_observed/3, from_beam/1, prepare/2, release/1, validate_prepared/3, builds/1, pinned/1]).

validate(#{schema_version := 1, instrumentation_version := 1,
           metric := clause_outcome_probe, module := M, build_id := B,
           probes := Ps, limitations := Ds}) when is_atom(M), is_binary(B),
                                                  byte_size(B) =:= 32, is_list(Ps), is_list(Ds) ->
    Ids = [I || #{probe_id := I, function := F, arity := A, kind := K,
                 structural_location := P, source_file := File, line := L,
                 column := _} <- Ps,
                is_integer(I), I > 0, is_atom(F), is_integer(A), A >= 0,
                is_atom(K), is_list(P), is_list(File), is_integer(L)],
    Paths = [P || #{structural_location := P} <- Ps],
    case length(Ids) =:= length(Ps) andalso
         length(lists:usort(Ids)) =:= length(Ids) andalso
         length(Paths) =:= length(Ps) andalso
         length(lists:usort(Paths)) =:= length(Paths) of
        true -> ok;
        false -> {error, invalid_or_duplicate_probe}
    end;
validate(_) -> {error, incompatible_manifest}.

identities(#{module := M, build_id := B, probes := Ps}) ->
    [{M, B, maps:get(probe_id, P)} || P <- Ps].

validate_observed(manual, Observed, _) ->
    case lists:all(fun({manual, _}) -> true; (_) -> false end, Observed) of
        true -> ok;
        false -> {error, automatic_probe_in_manual_campaign}
    end;
validate_observed(automatic, Observed, Manifests) ->
    Allowed = sets:from_list(lists:append([identities(M) || M <- Manifests])),
    case [P || P <- Observed, not sets:is_element(P, Allowed)] of
        [] -> ok;
        Bad -> {error, {unexpected_probe_or_build, Bad}}
    end.

from_beam(Beam) ->
    case beam_lib:chunks(Beam, [attributes]) of
        {ok, {_, [{attributes, Attrs}]}} ->
            case proplists:get_value(efz_manifest, Attrs) of
                [M] -> case validate(M) of ok -> {ok, M}; Error -> Error end;
                _ -> {error, missing_instrumentation}
            end;
        Error -> {error, {beam_attributes, Error}}
    end.

%% Prepared plans contain the same exact allowed identities as validate_observed.
%% A protected owner-held table avoids copying source manifests into every
%% coordinator. Preparation is explicit; no global cache or buffer reuse exists.
prepare(Mode, Manifests) when Mode =:= automatic; Mode =:= manual ->
    case [Error || M <- Manifests, (Error = validate(M)) =/= ok] of
        [] ->
            case {Mode, Manifests} of
                {automatic, []} -> {error, automatic_coverage_requires_manifests};
                _ -> make_plan(Mode, Manifests)
            end;
        Errors -> {error, {invalid_manifests, Errors}}
    end.
make_plan(Mode, Manifests) ->
    Bs = maps:from_list([{maps:get(module, M), maps:get(build_id, M)} || M <- Manifests]),
    case map_size(Bs) =:= length(Manifests) of
        false -> {error, duplicate_selected_module};
        true ->
            T = ets:new(efz_coverage_plan, [set, protected]),
            true = ets:insert(T, [{'$efz_plan', {Mode, Bs}} |
                [{Id} || M <- Manifests, Id <- identities(M)]]),
            true = ets:insert(T, {'$efz_identities',efz_cov_integrity:selected(Manifests)}),
            {ok, {efz_cov_plan, 1, T, Bs}}
    end.
pinned({efz_cov_plan,1,T,Bs}) ->
    try case {ets:lookup(T,'$efz_plan'),ets:lookup(T,'$efz_identities')} of
        {[{'$efz_plan',{_,Bs}}],[{'$efz_identities',Pins}]} -> Pins;
        _ -> {error,invalid_coverage_plan}
    end catch error:badarg -> {error,invalid_coverage_plan} end;
pinned(_) -> {error,invalid_coverage_plan}.
builds({efz_cov_plan, 1, _, Bs}) -> Bs.
release({efz_cov_plan, 1, T, _}) -> ets:delete(T), ok.
validate_prepared(Mode, Observed, {efz_cov_plan, 1, T, Bs}) ->
    try case ets:lookup(T, '$efz_plan') of
        [{'$efz_plan', {Mode, Bs}}] ->
            case Mode of
                manual -> validate_observed(manual, Observed, []);
                automatic ->
                    case [Id || Id <- Observed, not ets:member(T, Id)] of
                        [] -> ok;
                        Bad -> {error, {unexpected_probe_or_build, Bad}}
                    end
            end;
        _ -> {error, invalid_coverage_plan}
    end catch error:badarg -> {error, invalid_coverage_plan} end;
validate_prepared(_, _, _) -> {error, invalid_coverage_plan}.
