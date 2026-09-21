-module(efz_runtime_replay).
-export([run/4, verdict/3]).
run(Path,Target,Artifacts,Options) when is_atom(Target),is_map(Options)->
    case efz_runtime_store:load(Path) of
        {ok,E,Input}->prepare(E,Input,Target,Artifacts,Options);
        Error->Error
    end.
prepare(E,Input,Target,Artifacts,Options)->
    P=maps:get(policy,E),St=maps:get(stability,P),N=maps:get(runs,Options,maps:get(interesting_runs,St)),
    case maps:keys(Options)--[runs]=:=[] andalso is_integer(N) andalso N>=1 andalso N=<16 of
        false->{error,invalid_runtime_replay_options};
        true->case efz_config:prepare(#{target=>Target,artifacts=>Artifacts,seeds=>[Input],
                coverage=>maps:get(coverage_mode,E,automatic),max_iterations=>0,max_input_bytes=>maps:get(max_input_bytes,E),runtime_oracles=>P}) of
            {ok,C}->
                {ok,H}=efz_replay:harness_identity(Target),
                Bs=efz_recipe:build_ids(maps:from_list([{maps:get(module,M),maps:get(build_id,M)}||M<-maps:get(manifests,C)])),
                case {H=:=maps:get(harness,E),Bs=:=maps:get(target_builds,E)} of
                    {false,_}->{error,replay_harness_mismatch};
                    {_,false}->{error,replay_build_mismatch};
                    {true,true}->
                        {ok,Plan}=efz_cov_manifest:prepare(maps:get(coverage,C),maps:get(manifests,C)),
                        O=(maps:with([runtime_oracles,max_input_bytes,execution_identities],C))#{execution_origin=>verification,coverage=>maps:get(coverage,C),coverage_plan=>Plan},
                        try case efz_stability:repeat(Target,Input,maps:get(timeout,E),O,N,P) of
                            {ok,Rows}->Summary=efz_stability:summarize(Rows,N),
                                {ok,(verdict(maps:get(category,E),Rows,Summary))#{summary=>Summary,
                                    input_hash=>maps:get(input_hash,E),compatibility=>verified}};
                            {error,Why,Rows}->{error,#{kind=>replay_infrastructure,reason=>Why,
                                summary=>efz_stability:summarize(Rows,N)}}
                        end after efz_cov_manifest:release(Plan) end
                end;
            Error->Error
        end
    end.
verdict(C,Rows,S) when C=:=unstable_outcome;C=:=unstable_coverage;C=:=unstable_return->
    Enough=maps:get(valid,S)>=2 andalso (C=/=unstable_return orelse maps:get(return_comparable,S,0)>=2),
    Seen=lists:member(C,maps:get(categories,S)),
    Metric=case C of unstable_outcome->outcome_repeatability;unstable_coverage->coverage_repeatability;unstable_return->return_repeatability end,
    #{status=>case {Enough,Seen} of {false,_}->inconclusive;{true,true}->observed;_->not_observed end,
      category=>C,sample_count=>length(Rows),repeatability=>maps:get(Metric,S,undefined),
      variable_fraction=>case maps:get(Metric,S,undefined) of V when is_number(V)->(100-V)/100;_->undefined end,
      interpretation=>finite_sample_only};
verdict(C,Rows,_)->
    N=length([ok||R<-Rows,lists:member(C,maps:get(categories,maps:get(runtime,R),[]))]),
    Complete=Rows=/=[] andalso lists:all(fun(R)->
        Rt=maps:get(runtime,R),maps:get(valid,R) andalso not maps:get(partial,Rt,true) andalso
        case C of
            child_abnormal_exit->true;descendant_activity->true;
            ets_growth_suspected->maps:get(ets_scans,Rt,0)>0;
            _->maps:get(sample_count,Rt,0)>=2
        end end,Rows),
    #{status=>case {N,Complete} of {0,false}->inconclusive;{0,true}->not_observed;_->observed end,
      category=>C,observed=>N,sample_count=>length(Rows),fraction=>case Rows of []->0.0;_->N/length(Rows) end}.
