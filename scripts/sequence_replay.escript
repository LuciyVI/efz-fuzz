#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).
%% Exact-byte stateful replay from a trusted local campaign map.
main(["--help"]) -> usage(0);
main([ConfigPath,ArtifactsDir,Journal,StepText|Paths]) ->
    try
        Root=filename:dirname(filename:dirname(filename:absname(escript:script_name()))),
        Ebin=filename:join([Root,"_build","default","lib","efz","ebin"]),
        [true=code:add_patha(P)||P<-[Ebin,ArtifactsDir|Paths]],
        {Step,[]}=string:to_integer(StepText),true=Step>0,
        {ok,[C0]}=file:consult(ConfigPath),true=is_map(C0),
        {ok,Artifacts}=efz_instrument:discover(ArtifactsDir),
        {ok,C}=efz_config:prepare((maps:remove(artifacts_dir,C0))#{
            artifacts=>Artifacts,seeds=>[<<>>],
            max_iterations=>0}),
        persistent_vm=maps:get(mode,maps:get(execution,C)),
        case efz_sequence_audit:replay(Journal,C,Step) of
            {ok,Results}->
                lists:foreach(fun(R)->io:format("step=~B pid=~p driver=~p outcome=~0p coverage=~B~n",
                    [maps:get(step,R),maps:get(os_pid,R),maps:get(driver,R),
                     maps:get(outcome,R),length(maps:get(coverage,R,[]))]) end,Results),
                halt(0);
            {partial,Results,Failed}->
                io:format("partial at step ~B after ~B result(s)~n",[Failed,length(Results)]),halt(1);
            {error,Why}->io:format(standard_error,"sequence replay: ~0p~n",[Why]),halt(1)
        end
    catch Class:Reason ->
        io:format(standard_error,"sequence replay: ~0p:~0p~n",[Class,Reason]),halt(2)
    end;
main(_) -> usage(2).

usage(Code)->
    io:format("Usage: escript scripts/sequence_replay.escript CONFIG ARTIFACTS JOURNAL STEP [CODE_PATH ...]~n"
              "CONFIG is a trusted Erlang campaign map selecting persistent_vm and the same target build.~n"),
    halt(Code).
