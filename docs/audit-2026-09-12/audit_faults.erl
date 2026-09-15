-module(audit_faults).
-export([run/1]).
run(<<"state">>) ->
    case persistent_term:get({?MODULE, dirty}, false) of
        false -> audit_target:parse(<<"A">>);
        true -> audit_target:parse(<<"AB">>)
    end;
run(<<"dirty">>) -> persistent_term:put({?MODULE, dirty}, true), ok;
run(<<"child">>) -> child(false, false);
run(<<"linked_child">>) -> child(true, false);
run(<<"child_timeout">>) -> child(false, true);
run(<<"hold">>) ->
    {efz_context, 1, _, _, Owner} = get('$efz_execution_context'),
    whereis(audit_observer) ! {holding, self(), Owner},
    receive finish -> ok end;
run(<<"malformed">>) ->
    put('$efz_execution_context', invalid),
    try efz_cov_rt:hit({manual, bogus}) catch error:_ -> caught end;
run(<<"noop">>) -> ok;
run(<<"crash">>) -> error(test_crash);
run(<<"linked_exit">>) -> spawn_link(fun() -> exit(child_failed) end), receive never -> ok end;
run({raise, error, Reason}) -> error(Reason);
run({raise, throw, Reason}) -> throw(Reason);
run({raise, exit, Reason}) -> exit(Reason).
child(Linked, Wait) ->
    Root = self(), Observer = whereis(audit_observer),
    Fun = fun() ->
        Context = get('$efz_execution_context'),
        Value = audit_target:parse(<<"ABC">>),
        Observer ! {child, Root, self(), Context, Value},
        Root ! child_ready,
        receive finish -> ok end
    end,
    case Linked of true -> spawn_link(Fun); false -> spawn(Fun) end,
    receive child_ready -> ok end,
    case Wait of true -> receive never -> ok end; false -> ok end.
