%% Independent sequential replay epochs. Primary input/result are not reused as
%% samples; all observations come from identical init + exact journal bytes.
-module(efz_sequence_audit).
-export([run/5, run_inputs/5, replay/3, group_id/4]).

run(Path,C,FS,StartedUs,Progress) when is_function(Progress,2) ->
    case efz_sequence_journal:steps(Path,C) of
        {ok,Inputs} -> run_inputs(Inputs,C,FS,StartedUs,Progress);
        {error,Why} -> {error,Why,FS}
    end.

replay(Path,C,ToStep) when is_integer(ToStep),ToStep>0 ->
    case efz_sequence_journal:steps(Path,C) of
        {ok,Inputs} when ToStep=<length(Inputs) ->
            case efz_target_session:open(C) of
                {ok,Session} ->
                    try replay_loop(lists:sublist(Inputs,ToStep),Session,
                        maps:get(timeout,C),1,[])
                    after efz_target_session:close(Session) end;
                Error->Error
            end;
        {ok,_}->{error,step_out_of_range};
        Error->Error
    end;
replay(_,_,_)->{error,invalid_step}.

replay_loop([],_,_,_,Acc)->{ok,lists:reverse(Acc)};
replay_loop([Input|Rest],Session,Timeout,N,Acc)->
    case efz_target_session:run(Session,Input,Timeout) of
        {ok,R}->case maps:get(runner_reusable,R,false) of
            true->replay_loop(Rest,Session,Timeout,N+1,[R#{step=>N}|Acc]);
            false->{partial,lists:reverse([R#{step=>N}|Acc]),N}
        end;
        {error,Why}->{error,{step_failed,N,Why}}
    end.

run_inputs(Inputs,C,FS,StartedUs,Progress) ->
    Seq=maps:get(sequence,maps:get(stability,maps:get(runtime_oracles,C))),
    Repeats=maps:get(repeats,Seq),
    MaxCalls=min(maps:get(max_calls,Seq),maps:get(max_extra_executions,
        maps:get(stability,maps:get(runtime_oracles,C)))),
    Deadline=erlang:monotonic_time(millisecond)+maps:get(max_elapsed_ms,Seq),
    State=#{calls=>0,vm_starts=>0,unreached_steps=>0,completed_repetitions=>0,
        requested_repetitions=>Repeats,steps=>length(Inputs),status=>collecting},
    Audit=make_ref(),
    loop_repeats(1,Repeats,Inputs,C,FS,StartedUs,Progress,Audit,MaxCalls,Deadline,State).

loop_repeats(N,Max,_,_,FS,_,Progress,_,_,_,Stats) when N>Max ->
    Done=efz_stability:end_audit(FS,complete),Progress(Done,Stats#{status=>complete}),
    {ok,Done,Stats#{status=>complete}};
loop_repeats(N,Max,Inputs,C,FS,StartedUs,Progress,Audit,MaxCalls,Deadline,Stats) ->
    case budget(Stats,MaxCalls,Deadline) of
        exhausted -> finish_budget(FS,Stats,Progress);
        stopped -> finish_stopped(FS,Stats,Progress);
        ok -> case efz_target_session:open(C) of
            {ok,Session}->
                Started=Stats#{vm_starts=>maps:get(vm_starts,Stats)+1,
                    repetition=>N,step=>0,status=>collecting},
                Progress(FS,Started),
                Result=try loop_steps(Inputs,C,Session,FS,StartedUs,Progress,
                    Audit,N,Max,MaxCalls,Deadline,Started,1,efz_sequence_journal:initial_hash())
                after efz_target_session:close(Session) end,
                case Result of
                    {ok,NextFS,NextStats}->
                        loop_repeats(N+1,Max,Inputs,C,NextFS,StartedUs,Progress,
                            Audit,MaxCalls,Deadline,NextStats#{completed_repetitions=>N});
                    {budget,NextFS,NextStats}->finish_budget(NextFS,NextStats,Progress);
                    {stopped,NextFS,NextStats}->finish_stopped(NextFS,NextStats,Progress);
                    {error,Why,NextFS,NextStats}->
                        Done=efz_stability:end_audit(NextFS,partial),
                        ErrorStats=NextStats#{status=>partial,error=>Why},
                        Progress(Done,ErrorStats),{error,Why,Done,ErrorStats}
                end;
            {error,Why} ->
                Done=efz_stability:end_audit(FS,partial),
                ErrorStats=Stats#{status=>partial,error=>Why},
                Progress(Done,ErrorStats),{error,Why,Done,ErrorStats}
        end
    end.

loop_steps([],_,_,FS,_,_,_,_,_,_,_,Stats,_,_)->{ok,FS,Stats};
loop_steps([Input|Rest],C,Session,FS,StartedUs,Progress,Audit,Rep,Repeats,
           MaxCalls,Deadline,Stats,Index,Prefix) ->
    case budget(Stats,MaxCalls,Deadline) of
        exhausted->{budget,FS,Stats};
        stopped->{stopped,FS,Stats};
        ok ->
            Start=erlang:monotonic_time(microsecond),
            Result=efz_target_session:run(Session,Input,maps:get(timeout,C)),
            efz_stats:inc(verification_executions),
            efz_stats:add(verification_elapsed_us,erlang:monotonic_time(microsecond)-Start),
            NextStats=Stats#{calls=>maps:get(calls,Stats)+1,step=>Index},
            case Result of
                {ok,R} ->
                    Group=group_id(C,Prefix,Index,Input),
                    Features=features(R,C),
                    Elapsed=max(0,(erlang:monotonic_time(microsecond)-StartedUs) div 1000),
                    NextFS=efz_stability:observe(FS,Group,crypto:hash(sha256,Input),
                        {Audit,Rep,Index},Repeats,Features,Elapsed),
                    Progress(NextFS,NextStats),
                    case maps:get(runner_reusable,R,false) of
                        true -> loop_steps(Rest,C,Session,NextFS,StartedUs,Progress,
                            Audit,Rep,Repeats,MaxCalls,Deadline,NextStats,Index+1,
                            efz_sequence_journal:next_hash(Prefix,Input));
                        false -> {ok,NextFS,NextStats#{unreached_steps=>
                            maps:get(unreached_steps,NextStats)+length(Rest)}}
                    end;
                {error,Why}->{error,{step_failed,Index,Why},FS,NextStats}
            end
    end.

features(R,C) ->
    Expected=efz_executor:builds(C),
    Max=maps:get(max_features_per_group,maps:get(stability,maps:get(runtime_oracles,C))),
    case {maps:get(builds,R,undefined)=:=Expected,efz_stability:usable(R)} of
        {false,_}->{invalid,build_mismatch};
        {_,false}->{invalid,invalid_coverage_window};
        {true,true}->
            case maps:find(coverage,R) of
                {ok,Points} when is_list(Points),length(Points)=<Max ->
                    Schema=crypto:hash(sha256,term_to_binary(Expected,[deterministic])),
                    {ok,[{maps:get(coverage_backend,C),Schema,Point}||Point<-Points]};
                {ok,_}->{limit,feature_limit};
                error->{invalid,missing_full_coverage}
            end
    end.

group_id(C,Prefix,Index,Input) ->
    Functional=maps:with([target,execution_identities,coverage_backend,
        coverage_feedback,coverage_validation,timeout],C),
    Init=maps:get(target_init,maps:get(execution,C),#{}),
    crypto:hash(sha256,term_to_binary({audited_sequence_steps,Functional,Init,
        Prefix,Index,crypto:hash(sha256,Input)},[deterministic])).

budget(Stats,MaxCalls,Deadline) ->
    receive {'$gen_cast',request_stop}->stopped
    after 0 ->
        case maps:get(calls,Stats)>=MaxCalls orelse
             erlang:monotonic_time(millisecond)>=Deadline of
            true->exhausted;false->ok end
    end.
finish_budget(FS,Stats,Progress) ->
    Done=efz_stability:end_audit(FS,budget_exhausted),
    Final=Stats#{status=>budget_exhausted},Progress(Done,Final),
    {ok,Done,Final}.
finish_stopped(FS,Stats,Progress) ->
    Done=efz_stability:end_audit(FS,stopped),
    Final=Stats#{status=>stopped},Progress(Done,Final),
    {ok,Done,Final}.
