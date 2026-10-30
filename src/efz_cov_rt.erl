-module(efz_cov_rt).
-export([hit/1]).

%% Registry membership is independent of the mutable target dictionary. Missing
%% context is inactive only outside an executor-owned process.
hit(Id) ->
    case persistent_term:get({efz_target_vm,window},undefined) of
        {Controller,WindowRef,Context} ->
            case get('$efz_execution_context') of
                Context -> ok;
                _ -> Controller!{efz_target_window_failure,WindowRef,self()},
                     error({efz_infrastructure,persistent_window_unattached})
            end;
        _ -> ok
    end,
    case efz_cov_integrity:expected() of
        {ok,Expected} -> ok=efz_cov_integrity:check(Expected);
        none -> ok
    end,
    efz_coverage:hit(Id,get('$efz_execution_context')).
