#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).
main(Args)->
    Root=filename:dirname(filename:dirname(filename:absname(escript:script_name()))),
    Ebin=filename:join([Root,"_build","default","lib","efz","ebin"]),
    case code:add_patha(Ebin) of
        true->case code:ensure_loaded(efz_mutate_cli) of
            {module,efz_mutate_cli}->halt(efz_mutate_cli:main(Args));
            _->missing(Root)
        end;
        _->missing(Root)
    end.
missing(Root)->io:format(standard_error,"EFZ mutate: run rebar3 compile in ~ts~n",[Root]),halt(2).
