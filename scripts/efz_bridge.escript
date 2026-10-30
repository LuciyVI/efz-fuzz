#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).
%% Fixed entrypoint: stdin/stdout carry framed JSON; diagnostics use stderr.
main(Paths) ->
    Root=filename:dirname(filename:dirname(filename:absname(escript:script_name()))),
    Build=filename:join([Root,"_build","default","lib","*","ebin"]),
    [true=code:add_pathz(P)||P<-filelib:wildcard(Build)++Paths],
    case code:ensure_loaded(efz_control) of
        {module,efz_control}->efz_control:main();
        _->io:put_chars(standard_error,"EFZ control: build EFZ first (rebar3 compile)\n"),halt(2)
    end.
