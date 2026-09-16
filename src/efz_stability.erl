%% Diagnostic repeats never touch corpus, feedback, mutation state or rand.
-module(efz_stability).
-export([snapshot/2, summarize/2, outcome/1, bounded_return/1, usable/1, failure/1, repeat/6]).
outcome({ok,_})->ok;
outcome({crash,C,R,_})->{crash,C,reason(R)};
outcome({exit,R})->{exit,reason(R)};
outcome({timeout,_})->timeout;
outcome({infrastructure,_})->infrastructure.
reason(A) when is_atom(A)->A;
reason(T) when is_tuple(T),tuple_size(T)>0,is_atom(element(1,T))->{tag,element(1,T)};
reason(_)->other.
%% Fixed node/byte budget; runtime identities and floats (often timestamps) are unsupported.
bounded_return(T) ->
    try {V,_}=bound(T,1024),{comparable,crypto:hash(sha256,term_to_binary(V,[deterministic]))}
    catch throw:not_comparable->not_comparable end.
bound(_,N) when N=<0->throw(not_comparable);
bound(T,N) when is_atom(T)->{T,N-1};
bound(T,N) when is_integer(T),T>=-9223372036854775808,T=<9223372036854775807->{T,N-1};
bound(T,N) when is_binary(T),byte_size(T)=<N->{T,N-byte_size(T)-1};
bound([],N)->{[],N-1};
bound([H|T],N)->{A,N1}=bound(H,N-1),{B,N2}=bound(T,N1),{[A|B],N2};
bound(T,N) when is_tuple(T),tuple_size(T)=<N->
    {L,N1}=bound(tuple_to_list(T),N-1),{list_to_tuple(L),N1};
bound(T,N) when is_map(T),map_size(T)=<N div 3->
    {L,N1}=bound(lists:sort(maps:to_list(T)),N-1),{maps:from_list(L),N1};
bound(_,_)->throw(not_comparable).
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
