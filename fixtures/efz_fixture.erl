-module(efz_fixture).
-export([run/1, tail/2, self_call/1]).
-include("efz_fixture.hrl").

run({clauses, 0}) -> zero;
run({clauses, N}) when is_integer(N), N > 0 -> positive;
run({clauses, _}) -> negative;
run({nested, X}) ->
    {identity(case X of 0 -> zero; _ -> other end),
     #{(case X of 0 -> a; _ -> b end) =>
        if X > 0 -> case X rem 2 of 0 -> even; _ -> odd end; true -> nonpositive end}};
run({binary, <<N:8, Tail/binary>>}) -> <<(case N of 0 -> 1; _ -> N end):8, Tail/binary>>;
run({funs, N}) ->
    A = fun(0) -> zero; (X) when X > 0 -> positive; (_) -> negative end,
    F = fun Sum(0, Acc) -> Acc; Sum(X, Acc) -> Sum(X - 1, Acc + X) end,
    {A(N), F(abs(N), 0), (fun ?MODULE:self_call/1)(N)};
run({try_it, X}) ->
    put(events, []),
    Result = try note(body), exceptional(X) of
        ok -> note(of_ok), success;
        N when is_integer(N) -> note(of_number), {number, N}
    catch
        throw:Why -> note(caught_throw), {throw, Why};
        error:Why -> note(caught_error), {error, Why};
        exit:Why -> note(caught_exit), {exit, Why}
    after note(after_body) end,
    {Result, lists:reverse(get(events))};
run({exception, X}) -> exceptional(X);
run({receive_it, Messages}) ->
    lists:foreach(fun(M) -> self() ! M end, Messages),
    First = receive {take, X} when is_integer(X) -> {taken, X} after 0 -> absent end,
    Rest = receive M -> M after 0 -> empty end,
    {First, Rest};
run(receive_timeout) ->
    put(events, []),
    R = receive {take, X} -> X after begin note(timeout_expression), 0 end -> note(after_receive), expired end,
    {R, lists:reverse(get(events))};
run({short, X}) ->
    put(events, []),
    R = {(X andalso begin note(rhs_and), case X of true -> true; _ -> false end end),
         (X orelse begin note(rhs_or), false end)},
    {R, lists:reverse(get(events))};
run({tail, N}) -> tail(N, 0);
run({included, N}) -> ?INCLUDED(N);
run({record_it, X}) ->
    R = #item{value = case X of 0 -> 1; _ -> X end},
    R2 = R#item{tag = changed},
    {R2#item.value, #item.value, R2};
run({cross, X}) -> efz_fixture_helper:classify(X);
run({legacy_catch, X}) -> catch exceptional(X);
run({sync, Owner, Action}) ->
    %% Entry probe has completed before this message is sent.
    Owner ! {probe_recorded, self()},
    receive continue -> ok end,
    case Action of
        return -> done;
        fail -> error(controlled_failure);
        block -> receive finish -> done end
    end;
run({wait, Owner}) ->
    Owner ! {probe_recorded, self()},
    receive finish -> done end.

identity(X) -> X.
self_call(X) -> X.
tail(0, Acc) -> {Acc, element(2, process_info(self(), stack_size))};
tail(N, Acc) -> tail(N - 1, Acc + 1).
exceptional(ok) -> ok;
exceptional(throw) -> throw(fixture_throw);
exceptional(error) -> error(fixture_error);
exceptional(exit) -> exit(fixture_exit);
exceptional(N) -> N.
note(E) -> put(events, [E | get(events)]), ok.
