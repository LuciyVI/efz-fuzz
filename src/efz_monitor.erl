%% Opt-in, bounded read-only presentation data. No target calls or RNG draws.
-module(efz_monitor).
-export([prepare/1,record/4,snapshot/1]).
prepare(#{monitoring:=true,manifests:=Ms}) ->
    maps:from_list([{{maps:get(module,M),maps:get(build_id,M),maps:get(probe_id,P)},
        iolist_to_binary(io_lib:format("~s:~s/~B",[maps:get(module,M),maps:get(function,P),maps:get(arity,P)]))}
        ||M<-Ms,P<-maps:get(probes,M,[])]);
prepare(_) -> #{}.
record(_,_,_,#{monitoring:=false}=S) -> S;
record(Input,R,Meta,S) ->
    N=min(512,byte_size(Input)),
    Last0=#{bytes=>byte_size(Input),preview_hex=>binary:encode_hex(binary:part(Input,0,N),lowercase),
        truncated=>byte_size(Input)>N,phase=>maps:get(phase,Meta),
        parent=>maps:get(parent,Meta),outcome=>text(maps:get(outcome,R)),
        outcome_class=>class(maps:get(outcome,R)),
        functions=>functions(maps:get(coverage,R,[]),maps:get(monitor_index,S))},
    Last=case maps:find(mutation,Meta) of
        {ok,#{provider:=#{source:=Source}}}->Last0#{mutation_source=>Source};
        _->Last0
    end,
    Counts=maps:get(monitor_counts,S,#{}),K=class(maps:get(outcome,R)),
    S#{monitor_last=>Last,monitor_counts=>Counts#{K=>maps:get(K,Counts,0)+1}}.
snapshot(S) ->
    Coverage=efz_coverage:global_snapshot(maps:get(global,maps:get(feedback,S))),
    Total=case maps:get(coverage_backend,S) of
        B when B=:=ets;B=:=ets_member;B=:=bitmap -> map_size(maps:get(monitor_index,S));
        _ -> 0 end,
    Base=#{schema_version=>1,target=>maps:get(target,S),status=>running,
      max_iterations=>maps:get(max_iterations,S),
      elapsed_ms=>max(0,(erlang:monotonic_time(microsecond)-maps:get(calibration_started_at,S)) div 1000),
      coverage_count=>length(Coverage),coverage_total=>Total,
      coverage_unit=>case {maps:get(coverage,S),maps:get(coverage_backend,S)} of
          {manual,_}->manual_units;{_,otp_native_public}->lines;{_,none}->disabled;_->probes end,
      covered_functions=>functions(Coverage,maps:get(monitor_index,S)),
      stats=>maps:remove(primary_infrastructure_failure,efz_stats:get()),corpus_size=>efz_corpus:size(),
      outcomes=>maps:get(monitor_counts,S,#{}),last=>maps:get(monitor_last,S,null),
      feature_stability=>efz_stability:public(maps:get(feature_stability,S))},
    case maps:find(provider,maps:get(mutation,S,#{})) of
        {ok,P}->Base#{provider=>maps:without([core_context,core_path],P),
            provider_stats=>maps:get(provider_stats,S,#{})};
        error->Base
    end.
functions(Points,Index) ->
    lists:sublist(lists:usort([maps:get(P,Index)||P<-Points,maps:is_key(P,Index)]),64).
class({ok,{efz_term_input_rejected,_}})->codec_rejected;
class({ok,rejected})->target_rejected;
class({ok,{rejected,_}})->target_rejected;
class({ok,_})->returned;
class({timeout,_})->timeout;
class({crash,_,_,_})->exception;
class({exit,_})->exception;
class(_)->other.
text(T)->unicode:characters_to_binary(io_lib:format("~0P",[T,5],[{chars_limit,240}])).
