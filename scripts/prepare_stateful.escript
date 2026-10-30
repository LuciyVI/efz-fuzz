#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).
main([]) -> main(["_build/persistent-target-demo"]);
main([Out]) ->
    Root=filename:dirname(filename:dirname(filename:absname(escript:script_name()))),
    true=code:add_patha(filename:join([Root,"_build","default","lib","efz","ebin"])),
    {ok,_}=application:ensure_all_started(crypto),
    Source=filename:join([Root,"examples","stateful","efz_persistent_fixture.erl"]),
    case efz_instrument:compile(Source,#{modules=>[efz_persistent_fixture],
            source_root=>Root,outdir=>Out}) of
        {ok,A}->io:format("Prepared ~s (build ~s)~n",[maps:get(beam,A),
            binary:encode_hex(maps:get(build_id,A),lowercase)]);
        Error->io:format(standard_error,"Prepare failed: ~0p~n",[Error]),halt(1)
    end;
main(_)->io:format("Usage: escript scripts/prepare_stateful.escript [ARTIFACT_DIR]~n"),halt(2).
