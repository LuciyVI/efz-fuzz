-module(efz_feedback).
-export([new/1, new/2, new/3, evaluate/3]).

new(Builds) -> #{builds => Builds, global => efz_coverage:new_global()}.
new(Builds,none) -> #{builds=>Builds,coverage_backend=>none,
                      global=>efz_coverage:new_global()};
new(Builds,presence) -> new(Builds);
new(Builds,hit_count) -> (new(Builds))#{coverage_feedback=>hit_count,global_features=>efz_coverage:new_global()}.
new(Builds,presence,#{kind:=otp_native_line}=Schema) ->
    #{builds=>Builds,native_schema=>Schema,
      global=>{efz_native_schema,Schema,efz_coverage:native_empty(Schema)}};
new(Builds,presence,Schema) ->
    #{builds=>Builds,bitmap_schema=>Schema,
      global=>{efz_bitmap_schema,Schema,efz_coverage:new_global(Schema)}}.

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
evaluate(#{builds:=Builds,coverage_backend:=none}=State,
         #{builds:=Builds,outcome:=Outcome},Phase) ->
    case Outcome of
        {ok,_} ->
            Reason=case Phase of calibration->seed_calibration;
                                 _->equivalent_coverage end,
            {ok,State,#{new_probes=>[],retention_reason=>Reason}};
        _ -> {ok,State,#{new_probes=>[],retention_reason=>target_failure}}
    end;
evaluate(#{builds:=Builds,native_schema:=Schema,
           global:={efz_native_schema,Schema,Global}}=State,
         #{builds:=Builds,outcome:=Outcome,coverage_status:=Status}=Result,Phase) ->
    case {Status,Outcome} of
        {ok,{ok,_}} -> native_success(State,Schema,Global,Result,Phase);
        {{error,Why},_} -> {error,{coverage_failure,Why}};
        {_,{infrastructure,Why}} -> {error,{infrastructure,Why}};
        _ -> {ok,State,#{new_probes=>[],retention_reason=>target_failure}}
    end;
evaluate(#{builds:=Builds,bitmap_schema:=Schema,
           global:={efz_bitmap_schema,Schema,GlobalBits}}=State,
         #{builds:=Builds,outcome:=Outcome,coverage_status:=Status}=Result,Phase) ->
    case {Status,Outcome} of
        {ok,{ok,_}} -> bitmap_success(State,Schema,GlobalBits,Result,Phase);
        {{error,Why},_} -> {error,{coverage_failure,Why}};
        {_,{infrastructure,Why}} -> {error,{infrastructure,Why}};
        _ -> {ok,State,#{new_probes=>[],retention_reason=>target_failure}}
    end;
evaluate(#{builds := Builds, global := Global} = State,
         #{builds := Builds, outcome := Outcome, coverage_status := Status, coverage := Observed}=Result, Phase) ->
    case {Status, Outcome} of
        {ok, {ok, _}} ->
            New = efz_coverage:unseen(Global, Observed),
            successful(State,Result,Phase,New);
        {{error, Why}, _} -> {error, {coverage_failure, Why}};
        {_, {infrastructure, Why}} -> {error, {infrastructure, Why}};
        _ -> {ok, State, #{new_probes => [], retention_reason => target_failure}}
    end;
evaluate(_, _, _) -> {error, instrumentation_build_mismatch}.

native_success(State,Schema,Global,Result,Phase) ->
    case maps:find(coverage_native,Result) of
        {ok,Current} when byte_size(Current)=:=byte_size(Global) ->
            case efz_coverage:valid_native(Schema,maps:get(builds,State)) of
                true ->
                    Profile=maps:get(performance_profile,State,false),
                    {Novel,NoveltyUs}=efz_perf_profile:measure(Profile,
                        fun()->efz_coverage:native_has_new(Global,Current) end),
                    case Novel of
                        false ->
                            Reason=case Phase of
                                calibration->seed_calibration;
                                _->equivalent_coverage
                            end,
                            {ok,native_profile(State,Profile,#{novelty_us=>NoveltyUs}),
                                #{new_probes=>[],retention_reason=>Reason}};
                        true ->
                            NewBits=efz_coverage:native_unseen(Global,Current),
                            New=efz_coverage:native_decode(Schema,NewBits),
                            {Merged,MergeUs}=efz_perf_profile:measure(Profile,
                                fun()->efz_coverage:native_merge(Global,Current) end),
                            Reason=case Phase of
                                calibration->seed_calibration;
                                _->new_coverage
                            end,
                            {ok,native_profile(State#{global=>{efz_native_schema,Schema,Merged}},
                                    Profile,#{novelty_us=>NoveltyUs,merge_us=>MergeUs}),
                                 #{new_probes=>New,retention_reason=>Reason}}
                    end;
                false -> {error,{coverage_failure,invalid_native_schema}}
            end;
        _ -> {error,{coverage_failure,invalid_native_observation}}
    end.

native_profile(State,true,Times) -> State#{profile_last=>Times};
native_profile(State,false,_) -> State.

bitmap_success(State,Schema,GlobalBits,Result,Phase) ->
    case maps:find(coverage_sealed,Result) of
        {ok,Sealed} -> bitmap_sealed_success(State,Schema,GlobalBits,Sealed,Phase);
        error -> bitmap_snapshot_success(State,Schema,GlobalBits,Result,Phase)
    end.

bitmap_sealed_success(State,Schema,GlobalBits,Sealed,Phase) ->
    case efz_coverage:has_new(GlobalBits,Sealed) of
        {ok,false} ->
            Reason=case Phase of calibration->seed_calibration;_->equivalent_coverage end,
            {ok,State,#{new_probes=>[],retention_reason=>Reason}};
        {ok,true} ->
            case efz_coverage:unseen_sealed(GlobalBits,Sealed) of
                {ok,NewBits} ->
                    case efz_coverage:decode_new(Schema,NewBits) of
                        {ok,New} ->
                            case efz_coverage:commit_sealed(GlobalBits,Sealed) of
                                {ok,Merged} ->
                                    Reason=case Phase of calibration->seed_calibration;_->new_coverage end,
                                    {ok,State#{global=>{efz_bitmap_schema,Schema,Merged}},
                                        #{new_probes=>New,retention_reason=>Reason}};
                                {error,Why} -> {error,{coverage_failure,Why}}
                            end;
                        {error,Why} -> {error,{coverage_failure,Why}}
                    end;
                {error,Why} -> {error,{coverage_failure,Why}}
            end;
        {error,Why} -> {error,{coverage_failure,Why}}
    end.

bitmap_snapshot_success(State,Schema,GlobalBits,Result,Phase) ->
    Local = maps:get(coverage_bits,Result,undefined),
    case efz_coverage:unseen_bits(GlobalBits,Local) of
        {ok,NewBits} ->
            case {efz_coverage:decode_new(Schema,NewBits),
                  efz_coverage:merge_bits(GlobalBits,Local)} of
                {{ok,New},{ok,Merged}} ->
                    Reason = case {Phase,New} of
                        {calibration,_}->seed_calibration;
                        {_,[]}->equivalent_coverage;
                        _->new_coverage
                    end,
                    {ok,State#{global=>{efz_bitmap_schema,Schema,Merged}},
                        #{new_probes=>New,retention_reason=>Reason}};
                {{error,Why},_} -> {error,{coverage_failure,Why}};
                {_,{error,Why}} -> {error,{coverage_failure,Why}}
            end;
        {error,Why} -> {error,{coverage_failure,Why}}
    end.

successful(#{coverage_feedback:=hit_count,global_features:=GlobalFeatures}=State,Result,Phase,New) ->
    Hits=maps:get(coverage,Result),
    case {maps:get(coverage_feedback,Result,presence),efz_coverage:count_features(Hits,maps:get(hit_counts,Result,undefined))} of
        {hit_count,{ok,Features}} ->
            NewFeatures=efz_coverage:unseen(GlobalFeatures,Features),
            Reason=case {Phase,New,NewFeatures} of
                {calibration,_,_}->seed_calibration;
                {_,[_|_],_}->new_probe;
                {_,[],[_|_]}->new_hit_count;
                {_,[],[]}->equivalent_coverage
            end,
            {ok,State#{global=>efz_coverage:merge(maps:get(global,State),Hits),
                       global_features=>efz_coverage:merge(GlobalFeatures,Features)},
             #{coverage_feedback=>hit_count,new_probes=>New,new_count_features=>NewFeatures,
               retention_reason=>Reason}};
        _ -> {error,{coverage_failure,invalid_hit_counts}}
    end;
successful(#{global:=Global}=State,#{coverage:=Observed},Phase,New) ->
            Reason = case {Phase, New} of
                {calibration, _} -> seed_calibration;
                {_, []} -> equivalent_coverage;
                _ -> new_coverage
            end,
            {ok, State#{global => efz_coverage:merge(Global, Observed)},
             #{new_probes => New, retention_reason => Reason}}.
