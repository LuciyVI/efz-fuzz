%% Diagnostic repeats never touch corpus, feedback, mutation state or rand.
-module(efz_stability).
-export([snapshot/2, summarize/2, outcome/1, bounded_return/1, usable/1, failure/1, repeat/6,
         new/2, observe/7, complete/3, end_audit/2, public/1]).
outcome({ok,_})->ok;
outcome({crash,C,R,_})->{crash,C,reason(R)};
outcome({exit,R})->{exit,reason(R)};
outcome({timeout,_})->timeout;
outcome({infrastructure,_})->infrastructure.
reason(A) when is_atom(A)->A;
reason(T) when is_tuple(T),tuple_size(T)>0,is_atom(element(1,T))->{tag,element(1,T)};
reason(_)->other.
%% Validate before canonical serialization. Unordered map iteration does not
%% compare arbitrary keys. No container conversion/sort or binary scan occurs
%% before validation. Independent budgets: nodes, binary bytes, elements, depth.
bounded_return(T) ->
    try _=bound(T,{1024,1024,1024},64),
        {comparable,crypto:hash(sha256,term_to_binary(T,[deterministic]))}
    catch throw:not_comparable->not_comparable end.
bound(_, {N,_,_}, _) when N=<0->throw(not_comparable);
bound(_, _, D) when D=<0->throw(not_comparable);
bound(T,{N,B,E},_) when is_atom(T)->{N-1,B,E};
bound(T,{N,B,E},_) when is_integer(T),T>=-9223372036854775808,T=<9223372036854775807->{N-1,B,E};
bound(T,{N,B,E},_) when is_binary(T),byte_size(T)=<B->{N-1,B-byte_size(T),E};
bound([],{N,B,E},_)->{N-1,B,E};
bound([H|T],{N,B,E},D) when E>0->
    S=bound(H,{N-1,B,E-1},D-1),bound(T,S,D-1);
bound(T,{N,B,E},D) when is_tuple(T),tuple_size(T)=<E,tuple_size(T)<N->
    bound_tuple(T,1,{N-1,B,E-tuple_size(T)},D-1);
bound(T,{N,B,E},D) when is_map(T),map_size(T)=<E div 2,map_size(T)<N div 2->
    bound_map(maps:iterator(T),{N-1,B,E-2*map_size(T)},D-1);
bound(_,_,_)->throw(not_comparable).
bound_tuple(T,I,S,_) when I>tuple_size(T)->S;
bound_tuple(T,I,S,D)->bound_tuple(T,I+1,bound(element(I,T),S,D),D).
bound_map(It,S,D)->case maps:next(It) of
    none->S;
    {K,V,Next}->S1=bound(K,S,D),S2=bound(V,S1,D),bound_map(Next,S2,D)
end.
failure(#{outcome:={infrastructure,Why}})->{error,Why};
failure(#{runner_reusable:=false}=R)->{error,{runner_not_reusable,maps:get(cleanup,R,#{})}};
failure(#{coverage_status:={error,Why}})->{error,{coverage_failure,Why}};
failure(_)->ok.
usable(R)->failure(R)=:=ok andalso maps:get(coverage_status,R,undefined)=:=ok andalso
    maps:get(classification,maps:get(coverage_observation,R,#{}),unknown)=/=unstarted_coverage_observation.
snapshot(R,P)->
    Base=#{outcome=>outcome(maps:get(outcome,R)),valid=>usable(R),
      completed=>failure(R)=:=ok,coverage=>lists:usort(maps:get(coverage,R,[])),
      builds=>maps:get(builds,R,#{}),elapsed_us=>maps:get(elapsed_us,R,0),
      coverage_status=>maps:get(coverage_status,R,unknown),cleanup=>maps:get(status,maps:get(cleanup,R,#{}),unknown),
      runtime=>maps:get(runtime_observations,R,#{categories=>[]})},
    case {maps:get(compare_return,maps:get(stability,P)),maps:get(outcome,R)} of
        {true,{ok,V}}->Base#{return=>bounded_return(V)};
        _->Base#{return=>not_compared}
    end.
summarize(Rows,Requested)->
    Completed=[R||R<-Rows,maps:get(completed,R)],Valid=[R||R<-Completed,maps:get(valid,R)],
    N=length(Valid),
    Base=#{schema_version=>1,requested=>Requested,attempted=>length(Rows),completed=>length(Completed),
        valid=>N,failed=>length(Rows)-length(Completed),skipped=>max(0,Requested-length(Rows)),
        samples=>Rows,status=>case N>=2 of true->measured;false->insufficient_samples end},
    case N of
        0->Base#{categories=>[]};
        _->Cs=[maps:get(coverage,R)||R<-Valid],
           Union=lists:foldl(fun ordsets:union/2,[],Cs),
           Intersection=lists:foldl(fun ordsets:intersection/2,hd(Cs),tl(Cs)),
           OP=repeatability([maps:get(outcome,R)||R<-Completed]),
           CP=repeatability([{maps:get(builds,R),maps:get(coverage,R)}||R<-Valid]),
           Ret=[V||#{return:={comparable,V}}<-Valid],
           Categories=[K||{K,B}<-[{unstable_outcome,N>=2 andalso OP<100},
                {unstable_coverage,N>=2 andalso CP<100},
                {unstable_return,length(Ret)>=2 andalso repeatability(Ret)<100}],B],
           Base#{outcome_repeatability=>OP,coverage_repeatability=>CP,stable_probes=>Intersection,
             variable_probes=>ordsets:subtract(Union,Intersection),
             stable_probe_ratio=>case Union of []->100.0;_->100*length(Intersection)/length(Union) end,
             valid_empty_coverage=>Union=:=[],return_comparable=>length(Ret),
             return_repeatability=>case Ret of []->not_comparable;_->repeatability(Ret) end,categories=>Categories}
    end.
repeatability([])->100.0;
repeatability(L)->F=lists:foldl(fun(X,A)->maps:update_with(X,fun(N)->N+1 end,1,A) end,#{},L),
    100*lists:max(maps:values(F))/length(L).
%% Replay helper; campaign uses streaming persistence so a verification crash is saved immediately.
repeat(Target,Input,Timeout,Options,N,P)->repeat_loop(Target,Input,Timeout,Options,N,P,[]).
repeat_loop(_,_,_,_,0,_,Rows)->{ok,lists:reverse(Rows)};
repeat_loop(M,B,T,O,N,P,Rows)->R=efz_executor:run(M,B,T,O),S=snapshot(R,P),
    case failure(R) of ok->repeat_loop(M,B,T,O,N-1,P,[S|Rows]);
        {error,Why}->{error,Why,lists:reverse([S|Rows])} end.

%% Exact, bounded per-input presence sets. This is the authoritative formula;
%% stable_probe_ratio above retains its historical empty-union convention.
new(Policy, Backend) ->
    St=maps:get(stability,Policy),
    Enabled=maps:get(enabled,Policy) andalso maps:get(enabled,St),
    Kind=case Backend of
        {_,none}->unsupported;
        {manual,_}->manual_unit_presence;
        {_,otp_native_public}->line_presence;
        otp_native_public->line_presence;
        manual->manual_unit_presence;
        none->unsupported;
        _->probe_presence
    end,
    Status=case {Enabled,Kind} of
        {false,_}->disabled;{true,unsupported}->unsupported_backend;
        _->insufficient_samples
    end,
    #{schema_version=>1,feature_kind=>Kind,scope=>audited_inputs,status=>Status,
      collection_status=>case Enabled of true->collecting;false->disabled end,
      groups=>#{},max_groups=>maps:get(max_groups,St),
      max_features_per_group=>maps:get(max_features_per_group,St),
      stable_feature_pairs=>0,observed_feature_pairs=>0,invalid_attempts=>0,
      invalid_reasons=>#{},
      groups_skipped=>0,revision=>0,last_measurement_elapsed_ms=>null,current=>null,
      current_group_id=>undefined,current_episode_requested=>undefined}.

observe(#{status:=Status}=S,_,_,_,_,_,_) when Status=:=disabled;Status=:=unsupported_backend -> S;
observe(S,GroupId,InputId,ExecutionId,Requested,Features,ElapsedMs) ->
    Groups=maps:get(groups,S),
    MaxGroups=maps:get(max_groups,S),
    case maps:find(GroupId,Groups) of
        error when map_size(Groups)>=MaxGroups ->
            S#{groups_skipped=>maps:get(groups_skipped,S)+1,revision=>maps:get(revision,S)+1,
               collection_status=>capped,
               current_group_id=>undefined,current_episode_requested=>Requested,
               current=>#{input_id=>InputId,valid_runs=>0,attempted_runs=>0,
                   requested_runs=>Requested,percent=>null,status=>capped,provisional=>false}};
        Found ->
            G0=case Found of
                {ok,Existing}->Existing;
                error->#{input_id=>InputId,valid=>0,attempted=>0,union=>[],intersection=>[],
                         union_count=>0,intersection_count=>0,
                         variable_counts=>#{},
                         seen=>#{},status=>insufficient_samples,requested=>Requested,
                         episode_open=>true}
            end,
            Seen=maps:get(seen,G0),
            case {maps:is_key(ExecutionId,Seen),maps:get(status,G0)=:=capped,
                  map_size(Seen)>=256} of
                {true,_,_}->S;
                {_,true,_}->S;
                {_,_,true}->S#{collection_status=>capped,
                    groups_skipped=>maps:get(groups_skipped,S)+1,
                    revision=>maps:get(revision,S)+1};
                _->observe_new(S,Groups,GroupId,G0,ExecutionId,Requested,Features,ElapsedMs)
            end
    end.

observe_new(S,Groups,GroupId,G0,ExecutionId,Requested,Features,ElapsedMs) ->
    OldU=maps:get(union,G0),OldI=maps:get(intersection,G0),
    Old=contribution(G0),
    Attempted=maps:get(attempted,G0)+1,
    TotalRequested=case maps:get(episode_open,G0) of
        true->maps:get(requested,G0);
        false->maps:get(requested,G0)+Requested
    end,
    G1=G0#{attempted=>Attempted,requested=>TotalRequested,episode_open=>true,
        seen=>(maps:get(seen,G0))#{ExecutionId=>true}},
    {G2,Invalid}=case Features of
        {ok,Points} when is_list(Points) ->
            F=ordsets:from_list(Points),
            NewU=ordsets:union(OldU,F),
            UnionCount=length(NewU),
            case UnionCount=<maps:get(max_features_per_group,S) of
                true->N=maps:get(valid,G0),
                    NewI=case N of 0->F;_->ordsets:intersection(OldI,F) end,
                    Variables=ordsets:subtract(NewU,NewI),
                    Sample=lists:sublist(Variables,64),
                    PreviousCounts=maps:get(variable_counts,G0,#{}),
                    Counts=maps:from_list([{X,
                        maps:get(X,PreviousCounts,
                            case ordsets:is_element(X,OldI) of true->N;false->0 end)+
                        case ordsets:is_element(X,F) of true->1;false->0 end}
                        || X<-Sample]),
                    {G1#{valid=>N+1,union=>NewU,intersection=>NewI,
                        variable_counts=>Counts,
                        union_count=>UnionCount,intersection_count=>length(NewI)},0};
                false->{G1#{status=>capped,union=>[],intersection=>[],
                    union_count=>0,intersection_count=>0,variable_counts=>#{}},0}
            end;
        {limit,feature_limit}->{G1#{status=>capped,union=>[],intersection=>[],
            union_count=>0,intersection_count=>0,variable_counts=>#{}},0};
        _->{G1,1}
    end,
    New=contribution(G2),
    Stable=maps:get(stable_feature_pairs,S)-element(1,Old)+element(1,New),
    Observed=maps:get(observed_feature_pairs,S)-element(2,Old)+element(2,New),
    Status=group_status(G2),
    Valid=maps:get(valid,G2),
    Current=#{input_id=>maps:get(input_id,G2),valid_runs=>Valid,
        attempted_runs=>Attempted,requested_runs=>TotalRequested,status=>Status,
        percent=>percent(element(1,New),element(2,New)),
        provisional=>Status=:=measured andalso Valid<TotalRequested},
    Last=case Status of measured->ElapsedMs;_->maps:get(last_measurement_elapsed_ms,S) end,
    Reasons=case Invalid of
        0->maps:get(invalid_reasons,S);
        _->Reason=invalid_reason(Features),
            maps:update_with(Reason,fun(N)->N+1 end,1,maps:get(invalid_reasons,S))
    end,
    S#{groups=>Groups#{GroupId=>G2},stable_feature_pairs=>Stable,
      observed_feature_pairs=>Observed,invalid_attempts=>maps:get(invalid_attempts,S)+Invalid,
      invalid_reasons=>Reasons,
      groups_skipped=>maps:get(groups_skipped,S)+case maps:get(status,G2)=:=capped andalso
          maps:get(status,G0)=/=capped of true->1;false->0 end,
      revision=>maps:get(revision,S)+1,last_measurement_elapsed_ms=>Last,
      collection_status=>case maps:get(status,G2) of capped->capped;_->collecting end,
      current=>Current,current_group_id=>GroupId,current_episode_requested=>Requested}.

complete(S,Requested,CollectionStatus) ->
    case maps:get(current_episode_requested,S) of
        Requested ->
            Id=maps:get(current_group_id,S),Groups=maps:get(groups,S),
            Updated=case maps:find(Id,Groups) of
                {ok,G}->Groups#{Id=>G#{episode_open=>false}};
                error->Groups
            end,
            Current=maps:get(current,S),
            Status=case Current of
                #{status:=capped}->capped;
                #{valid_runs:=V,requested_runs:=R} when CollectionStatus=:=complete,V<R->partial;
                _->CollectionStatus
            end,
            S#{groups=>Updated,collection_status=>Status,revision=>maps:get(revision,S)+1,
                current_episode_requested=>undefined};
        _ -> S
    end.

end_audit(S,Status) ->
    Groups=maps:map(fun(_,G)->G#{episode_open=>false} end,maps:get(groups,S)),
    S#{groups=>Groups,collection_status=>Status,revision=>maps:get(revision,S)+1}.

public(S) ->
    GroupPairs=maps:to_list(maps:get(groups,S)),
    Groups=[G||{_,G}<-GroupPairs],
    Measured=[G||G<-Groups,group_status(G)=:=measured],
    Stable=maps:get(stable_feature_pairs,S),Observed=maps:get(observed_feature_pairs,S),
    Status=case maps:get(status,S) of
        disabled->disabled;unsupported_backend->unsupported_backend;
        _ when Observed>0->measured;
        _->case lists:any(fun(G)->group_status(G)=:=no_observed_features end,Groups) of
            true->no_observed_features;false->insufficient_samples end
    end,
    (maps:without([groups,max_groups,max_features_per_group,current_group_id,
        current_episode_requested],S))#{
        status=>Status,percent=>percent(Stable,Observed),
        variable_feature_pairs=>Observed-Stable,groups_measured=>length(Measured),
        groups_unstable=>length([G||G<-Measured,maps:get(intersection_count,G)<maps:get(union_count,G)]),
        groups_incomplete=>length([G||G<-Groups,group_status(G)=:=insufficient_samples]),
        groups_no_features=>length([G||G<-Groups,group_status(G)=:=no_observed_features]),
        variable_examples=>lists:sublist([#{group_id=>Id,feature=>X,
            observed_runs=>Count,valid_runs=>maps:get(valid,G)}
            ||{Id,G}<-GroupPairs,group_status(G)=:=measured,
              {X,Count}<-lists:sort(maps:to_list(maps:get(variable_counts,G,#{})))],16)}.

contribution(G) ->
    case group_status(G) of
        measured->{maps:get(intersection_count,G),maps:get(union_count,G)};
        _->{0,0}
    end.
group_status(#{status:=capped})->capped;
group_status(#{valid:=N}) when N<2->insufficient_samples;
group_status(#{union:=[]})->no_observed_features;
group_status(_)->measured.
invalid_reason({invalid,build_mismatch})->build_mismatch;
invalid_reason({invalid,missing_full_coverage})->missing_full_coverage;
invalid_reason({invalid,damaged_full_coverage})->damaged_full_coverage;
invalid_reason({invalid,runner_not_reusable})->runner_not_reusable;
invalid_reason({invalid,coverage_failure})->coverage_failure;
invalid_reason({invalid,execution_failure})->execution_failure;
invalid_reason({invalid,invalid_coverage_window})->invalid_coverage_window;
invalid_reason(_)->invalid_coverage_window.
percent(_,0)->null;
percent(I,U)->100.0*I/U.
