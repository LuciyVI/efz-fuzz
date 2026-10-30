%% Artificial lifecycle fixture; only cow_qs contributes target coverage.
-module(efz_gleam_feedback_target).
-export([run/1]).
run(<<"normal">>) -> cow_qs:parse_qs(<<"a=1">>);
run(Mode) ->
    Observer=whereis(efz_gleam_feedback_observer),
    Child=efz_target:spawn(fun()->
        receive after 200->
            _=efz_qs_target:run(<<"a=%">>),Observer!late_executed
        end
    end),
    Observer!{late_ready,self(),Child},
    case Mode of <<"hold">>->receive release->ok end;<<"late">>->ok end,
    cow_qs:parse_qs(<<"a=1">>).
