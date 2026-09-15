#!/usr/bin/env escript
%% Thin launcher: regeneration and execution use the existing EFZ core.
-mode(compile).
main(Args) ->
    Root=filename:dirname(filename:dirname(filename:absname(escript:script_name()))),
    true=code:add_patha(filename:join([Root,"_build","default","lib","efz","ebin"])),
    halt(efz_replay_cli:main(Args)).
