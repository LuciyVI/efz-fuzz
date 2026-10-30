#!/usr/bin/env escript
-mode(compile).

main([Dir]) ->
    {ok,[P]}=file:consult(filename:join(Dir,"profile.term")),
    Total=total(P,iteration_total),
    Calls=calls(P,iteration_total),
    io:format("iterations=~B total_us=~B mean_iteration_us=~.1f~n",
              [Calls,Total,Total/max(1,Calls)]),
    io:format("Nested stages; percentages below use iteration wall time and must not be summed across levels.~n"),
    Groups=[{"Worker",[corpus_select,mutation,input_preparation,executor,
                         feedback,corpus_decision,corpus_store,worker_unaccounted]},
            {"Guardian",[guardian_prepare_us,trace_setup_us,shared_baseline_us,
                          admit_us,target_us,cleanup_wait_us,guardian_finish_us,
                          integrity_validate_us,trace_destroy_us,shared_check_us,
                          guardian_unaccounted_us,executor_outer_us]},
            {"OTP coverage",[coverage_open_us,native_read_us,get_coverage_us,
                              conversion_us,novelty_us,merge_us]}],
    lists:foreach(fun({Name,Keys})->
        io:format("~s~n",[Name]),
        lists:foreach(fun(K)->row(K,P,Total) end,Keys)
    end,Groups),
    Worker=sum(P,[corpus_select,mutation,input_preparation,executor,
                  feedback,corpus_decision,worker_unaccounted]),
    Guardian=sum(P,[guardian_prepare_us,target_us,cleanup_wait_us,
                    guardian_finish_us,guardian_unaccounted_us]),
    Coverage=sum(P,[coverage_open_us,get_coverage_us,conversion_us,
                    novelty_us,merge_us]),
    io:format("worker accounting: ~.2f% (difference ~B us)~n",
        [100.0*Worker/max(1,Total),Total-Worker]),
    io:format("guardian accounting: ~.2f% of guardian_total (difference ~B us)~n",
        [100.0*Guardian/max(1,total(P,guardian_total_us)),
         total(P,guardian_total_us)-Guardian]),
    io:format("measured OTP coverage pipeline: ~.3f% (~.2f us/iteration)~n",
        [100.0*Coverage/max(1,Total),Coverage/max(1,Calls)]);
main(_) ->
    io:format(standard_error,"usage: escript scripts/print_engine_profile.escript RUN_DIR~n",[]),
    halt(2).

row(K,P,Iteration) ->
    case maps:find(K,P) of
        {ok,#{calls:=N,total_us:=Us,mean_us:=Mean,median_us:=Median,
              p90_us:=P90,p99_us:=P99}} ->
            io:format("  ~-25s calls=~B total=~B us mean=~.1f median=~B p90=~B p99=~B pct=~.3f~n",
                [atom_to_list(K),N,Us,Mean,Median,P90,P99,
                 100.0*Us/max(1,Iteration)]);
        error -> ok
    end.
sum(P,Keys) -> lists:sum([total(P,K)||K<-Keys]).
total(P,K) -> maps:get(total_us,maps:get(K,P,#{}),0).
calls(P,K) -> maps:get(calls,maps:get(K,P,#{}),0).
