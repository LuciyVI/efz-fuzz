%% Optional, bounded wall-clock samples for benchmark runs only.
-module(efz_perf_profile).
-export([measure/2, add/3, add_state/3, summary/1]).
-define(MAX_SAMPLES, 20000).

measure(false, Fun) -> {Fun(),0};
measure(true, Fun) ->
    Start=erlang:monotonic_time(microsecond),
    Value=Fun(),
    {Value,erlang:monotonic_time(microsecond)-Start}.

add(Profile,_,Us) when Us < 0 -> Profile;
add(Profile,Stage,Us) ->
    Old=maps:get(Stage,Profile,#{calls=>0,total_us=>0,samples=>[]}),
    Calls=maps:get(calls,Old)+1,
    Samples=case Calls =< ?MAX_SAMPLES of
        true -> [Us|maps:get(samples,Old)];
        false -> maps:get(samples,Old)
    end,
    Profile#{Stage=>Old#{calls=>Calls,total_us=>maps:get(total_us,Old)+Us,
                         samples=>Samples}}.

add_state(#{performance_profile:=true,profile:=Profile}=S,Stage,Us) ->
    S#{profile=>add(Profile,Stage,Us)};
add_state(S,_,_) -> S.

summary(Profile) ->
    Iteration=maps:get(total_us,maps:get(iteration_total,Profile,#{total_us=>0})),
    maps:map(fun(_,#{calls:=Calls,total_us:=Total,samples:=Samples}) ->
        Sorted=lists:sort(Samples),
        #{calls=>Calls,total_us=>Total,mean_us=>Total/max(1,Calls),
          median_us=>quantile(Sorted,0.5),p90_us=>quantile(Sorted,0.9),
          p99_us=>quantile(Sorted,0.99),samples=>length(Sorted),
          percent_of_iteration=>case Iteration of
              0 -> 0.0; _ -> 100.0*Total/Iteration end}
    end,Profile).

quantile([],_) -> 0;
quantile(List,P) ->
    lists:nth(max(1,ceil(length(List)*P)),List).
