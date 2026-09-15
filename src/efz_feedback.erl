-module(efz_feedback).
-export([new/1, evaluate/3]).

new(Builds) -> #{builds => Builds, global => sets:new()}.

%% A retired runner has not executed the requested build. Its lifecycle
%% failure must remain primary even when no build map could be produced.
evaluate(_, #{outcome := {infrastructure, #{kind := dirty_runner} = Why}}, _) -> {error, Why};
%% Execution/storage failure is primary, even if no expected build was run.
evaluate(_,#{outcome:={infrastructure,Why}}=Result,_) ->
    case maps:get(coverage_status,Result,ok) of
        {error,Why} -> {error,{coverage_failure,Why}};
        _ -> {error,{infrastructure,Why}}
    end;
evaluate(_,#{coverage_status:={error,Why}},_) -> {error,{coverage_failure,Why}};
evaluate(#{builds := Builds, global := Global} = State,
         #{builds := Builds, outcome := Outcome, coverage_status := Status, coverage := Observed}, Phase) ->
    case {Status, Outcome} of
        {ok, {ok, _}} ->
            New = lists:sort(sets:to_list(sets:subtract(sets:from_list(Observed), Global))),
            Reason = case {Phase, New} of
                {calibration, _} -> seed_calibration;
                {_, []} -> equivalent_coverage;
                _ -> new_coverage
            end,
            {ok, State#{global => efz_cov:merge(Global, Observed)},
             #{new_probes => New, retention_reason => Reason}};
        {{error, Why}, _} -> {error, {coverage_failure, Why}};
        {_, {infrastructure, Why}} -> {error, {infrastructure, Why}};
        _ -> {ok, State, #{new_probes => [], retention_reason => target_failure}}
    end;
evaluate(_, _, _) -> {error, instrumentation_build_mismatch}.
