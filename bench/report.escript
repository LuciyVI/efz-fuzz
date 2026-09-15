#!/usr/bin/env escript
-mode(compile).
main([Dir]) ->
    lists:foreach(fun(Stage) ->
        case file:read_file(filename:join(Dir,Stage++".term")) of
            {ok,B}->Rows=binary_to_term(B),io:format("~n~s~n",[Stage]),
                lists:foreach(fun show/1,Rows);
            {error,enoent}->ok
        end
    end,["hooks","executor","campaign"]);
main(_) -> error("usage: escript bench/report.escript ARTIFACT_DIR").
show(R=#{median_us:=Us,raw_us:=Raw}) ->
    Count=maps:get(executions,R,maps:get(calls,R,maps:get(iterations,R,1))),
    io:format("~p median_us=~B us_per_op=~.4f ops_per_second=~.1f raw=~w~n",
        [maps:without([samples,median_us,min_us,max_us,raw_us],R),Us,Us/Count,Count*1000000/Us,Raw]).
