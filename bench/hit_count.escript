#!/usr/bin/env escript
%%! +S 4:4
-mode(compile).
main([Stage,Out]) ->
    true=code:add_patha("_build/default/lib/efz/ebin"),
    lists:foreach(fun(File)->
        {ok,M,B}=compile:file(File,[binary,debug_info,warnings_as_errors,report]),
        {module,M}=code:load_binary(M,File,B)
    end,["bench/efz_hit_count_micro.erl","bench/efz_hit_count_experiment.erl"]),
    case Stage of
        "micro"->efz_hit_count_micro:run(Out);
        "executor"->efz_hit_count_experiment:run(executor,Out);
        "campaign"->efz_hit_count_experiment:run(campaign,Out);
        "stress"->efz_hit_count_experiment:run(stress,Out);
        "large_loops"->efz_hit_count_experiment:run(large_loops,Out);
        "report"->efz_hit_count_experiment:report(Out)
    end;
main(_) -> io:format("Usage: escript bench/hit_count.escript micro|executor|campaign|stress|large_loops|report OUT~n"),halt(2).
