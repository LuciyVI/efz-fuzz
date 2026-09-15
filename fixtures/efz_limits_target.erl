-module(efz_limits_target).
-export([run/1]).
run(B) when is_binary(B) ->
    case whereis(efz_limits_observer) of
        undefined -> ok;
        Pid -> Pid ! {delivered_input, B}
    end,
    case B of
        <<"CRASH">> -> error({limits_test_crash,B});
        _ -> B
    end.
