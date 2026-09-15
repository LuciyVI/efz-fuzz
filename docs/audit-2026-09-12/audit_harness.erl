-module(audit_harness).
-behaviour(efz_target).
-export([run/1]).
run(Input) when is_binary(Input) ->
    case whereis(audit_observer) of
        undefined -> ok;
        Pid -> Pid ! {delivered, self(), Input}
    end,
    audit_target:parse(Input).
