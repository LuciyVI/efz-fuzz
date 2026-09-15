%% Ordinary binary harness. Only efz_integrity_target is instrumented.
-module(efz_integrity_harness).
-export([run/1]).
-ifdef(ALTERNATE).
-define(DISCONNECTED, changed).
-else.
-define(DISCONNECTED, disconnected).
-endif.
run(<<"skip">>) -> ?DISCONNECTED;
run(<<"zero">>) -> zero();
run(<<>>) -> zero();
run(<<"probe_crash">>) -> a=efz_integrity_target:parse(<<"A">>),error(after_probe);
run(<<"erase_all">>) -> erase(),ok;
run(<<"erase_key">>) -> erase('$efz_execution_context'),ok;
run(<<"detach">>) -> efz_cov:detach();
run(<<"malformed">>) -> put('$efz_execution_context',malformed),ok;
run(<<"caught_hook">>) ->
    put('$efz_execution_context',malformed),caught();
run(<<"erased_hook">>) -> erase('$efz_execution_context'),caught();
run(<<"erase_restore">>) ->
    C=get('$efz_execution_context'),erase(),put('$efz_execution_context',C),
    efz_integrity_target:parse(<<"A">>);
run(<<"lose_hits">>) ->
    a=efz_integrity_target:parse(<<"A">>),
    {efz_context,1,_,T,_}=get('$efz_execution_context'),
    true=ets:delete_all_objects(case T of {ets_member,Table}->Table;_->T end),ok;
run(<<"child_context">>) ->
    P=efz_target:spawn(fun()->put('$efz_execution_context',malformed),caught() end),
    R=monitor(process,P),receive {'DOWN',R,process,P,_}->ok end;
run(<<"erase_wait">>) -> erase(),wait();
run(<<"wait">>) -> wait(),efz_integrity_target:parse(<<"A">>);
run(<<"wait_zero">>) -> wait(),zero();
run(B) when is_binary(B) -> efz_integrity_target:parse(B).
zero() ->
    %% A genuine call that never enters any instrumented clause body.
    try efz_integrity_target:parse(<<"unmatched">>)
    catch error:function_clause -> zero end.
caught() ->
    try efz_integrity_target:parse(<<"A">>)
    catch error:{efz_infrastructure,_} -> caught end.
wait() ->
    whereis(efz_integrity_observer)!{ready,self()},receive finish->ok end.
