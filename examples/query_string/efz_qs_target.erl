%% Ordinary Cowlib parser harness. It has no Gleam dependency.
-module(efz_qs_target).
-export([run/1]).
run(Input) when is_binary(Input) ->
    try cow_qs:parse_qs(Input) of Pairs -> {accepted,Pairs}
    catch
        error:function_clause -> rejected;
        error:badarg -> rejected;
        error:{invalid_byte,_} -> rejected;
        %% Pinned cow_inline.hrl UNHEX has no non-hex clause.
        error:{case_clause,Byte} when is_integer(Byte), Byte>=0, Byte=<255 -> rejected;
        error:limit_reached -> rejected
    end.
