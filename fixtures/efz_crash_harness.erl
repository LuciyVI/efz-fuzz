-module(efz_crash_harness).
-export([run/1]).
-ifdef(ALTERNATE).
-define(PREFIX, <<"changed">>).
-else.
-define(PREFIX, <<>>).
-endif.
run(B) when is_binary(B) ->
    case os:getenv("EFZ_REPLAY_TEST_RESULT") of
        "ok" -> ok;
        "different" -> error(different_bug);
        "infrastructure" -> error({efz_infrastructure,replay_test_infrastructure});
        _ -> efz_crash_target:parse(<<?PREFIX/binary,B/binary>>)
    end.
