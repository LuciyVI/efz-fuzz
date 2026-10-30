%% Bounded cold byte deletion, exact existing EFZ fingerprint predicate.
%% Caller chooses target/artifacts; no callbacks are selected by artifact terms.
-module(efz_finding_minimize).
-export([run/6]).
run(B,T,As,E,O,Limits)->
    try
        Budget=maps:get(executions,Limits,64),Ms=maps:get(timeout_ms,Limits,30000),
        Repeat=maps:get(repeat,Limits,3),
        true=is_integer(Budget) andalso Budget>=1 andalso Budget=<10000,
        true=is_integer(Ms) andalso Ms>=1 andalso Ms=<300000,
        true=is_integer(Repeat) andalso Repeat>=2 andalso Repeat=<10,
        true=is_binary(B) andalso crypto:hash(sha256,B)=:=maps:get(input_hash,E),
        Start=erlang:monotonic_time(millisecond),
        %% One initial raw replay determines whether repeat policy applies.
        {ok,R}=efz_replay:run_input(B,T,As,E,O),
        case maps:get(status,R) of
            not_reproduced->{ok,#{status=>not_reproduced,target_executions=>1}};
            reproduced->
                N=case maps:get(outcome,maps:get(result,R)) of {timeout,_}->Repeat;_->1 end,
                S=#{used=>1,budget=>Budget,repeat=>N,deadline=>Start+Ms,start=>Start,
                    original_hash=>crypto:hash(sha256,B),trace=>[]},
                case check(B,T,As,E,O,N-1,S) of
                    {reproduced,S1}->walk(B,0,T,As,E,O,S1);
                    {Why,S1}->finish(B,Why,T,As,E,O,S1,false)
                end
        end
    catch error:Failure->{error,{finding_minimization,Failure}} end.
check(_,_,_,_,_,0,S)->{reproduced,S};
check(B,T,As,E,O,N,S)->
    case available(S,1) of
        false->{budget_or_deadline_exhausted,S};
        true->{ok,R}=efz_replay:run_input(B,T,As,E#{input_hash=>crypto:hash(sha256,B)},O),
            S1=S#{used=>maps:get(used,S)+1},
            case maps:get(status,R) of
                reproduced->check(B,T,As,E,O,N-1,S1);
                _->{case maps:get(repeat,S)>1 of true->unstable;false->not_reproduced end,S1}
            end
    end.
available(S,N)->maps:get(used,S)+N=<maps:get(budget,S)
    andalso erlang:monotonic_time(millisecond)<maps:get(deadline,S).
walk(B,Offset,T,As,E,O,S)->
    N=maps:get(repeat,S),
    case Offset>=byte_size(B) of
        true->finish(B,minimal_by_single_byte_deletion,T,As,E,O,S,true);
        false->case available(S,2*N) of
            false->finish(B,budget_or_deadline_exhausted,T,As,E,O,S,true);
            true-><<Prefix:Offset/binary,_,Suffix/binary>>=B,Next= <<Prefix/binary,Suffix/binary>>,
                {Result,S1}=check(Next,T,As,E,O,N,S),Tr=maps:get(trace,S1),
                Row=#{size=>byte_size(Next),offset=>Offset,status=>Result,input_hash=>crypto:hash(sha256,Next)},
                S2=S1#{trace=>case length(Tr)<128 of true->[Row|Tr];false->Tr end},
                case Result of
                    reproduced->walk(Next,0,T,As,E,O,S2);
                    budget_or_deadline_exhausted->finish(B,Result,T,As,E,O,S2,true);
                    _->walk(B,Offset+1,T,As,E,O,S2)
                end
        end
    end.
finish(B,Status,T,As,E,O,S,Verify)->
    {V,S1}=case Verify of
        true->check(B,T,As,E,O,maps:get(repeat,S),S);
        false->{skipped,S}
    end,
    {ok,#{schema_version=>1,status=>Status,input=>B,verification=>V,
        original_hash=>maps:get(original_hash,S),minimized_hash=>crypto:hash(sha256,B),
        expectation=>E#{input_hash=>crypto:hash(sha256,B)},fingerprint=>maps:get(signature_id,E),
        repeat_policy=>maps:get(repeat,S),target_executions=>maps:get(used,S1),
        elapsed_ms=>erlang:monotonic_time(millisecond)-maps:get(start,S),
        trace=>lists:reverse(maps:get(trace,S1)),trace_limit=>128}}.
