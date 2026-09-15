#!/usr/bin/env escript
-mode(compile).
main(Args) ->
    Root = filename:dirname(filename:dirname(filename:absname(escript:script_name()))),
    Ebin = filename:join([Root, "_build", "default", "lib", "efz", "ebin"]),
    case code:add_patha(Ebin) of
        true ->
            case code:ensure_loaded(efz_cli) of
                {module, efz_cli} -> halt(efz_cli:main(Args));
                _ -> missing_build(Root)
            end;
        _ -> missing_build(Root)
    end.
missing_build(Root) ->
    io:format(standard_error, "EFZ: build the launcher with 'rebar3 compile' in ~ts~n", [Root]),
    halt(2).
