-module(efz_cov_rt).
-export([hit/1]).

%% Registry membership is independent of the mutable target dictionary. Missing
%% context is inactive only outside an executor-owned process.
hit(Id) ->
    case efz_cov_integrity:expected() of
        {ok,Expected} -> ok=efz_cov_integrity:check(Expected);
        none -> ok
    end,
    publish(Id,get('$efz_execution_context')).
publish(Id,Context) ->
    case Context of
        undefined -> ok;
        {efz_context, 1, Ref, {ets_member, Table}, Owner} ->
            %% No target-local cache: every completed duplicate verifies the
            %% externally held observation, and bad tables cannot be hidden.
            try
                case ets:member(Table, {probe, Id}) of
                    true -> ok;
                    false -> insert(Id,Ref,Table,Owner)
                end
            catch error:badarg ->
                Owner ! {efz_cov_failure, Ref, invalid_table},
                error({efz_infrastructure, invalid_coverage_table})
            end;
        {efz_context, 1, Ref, Table, Owner} ->
            try insert(Id,Ref,Table,Owner) of
                ok -> ok
            catch error:badarg ->
                Owner ! {efz_cov_failure, Ref, invalid_table},
                error({efz_infrastructure, invalid_coverage_table})
            end;
        _ -> error({efz_infrastructure, invalid_coverage_context})
    end.
insert(Id,Ref,Table,Owner) ->
    case ets:insert_new(Table,{{probe,Id}}) of
        true -> Owner!{efz_cov_observed,Ref,Id},ok;
        false -> ok
    end.
