-module(efz_runtime_sites).
-export([run/1, branch/1]).
run(<<"deterministic">>)->ok;
run(<<"reference">>)->make_ref();
run(<<"vary">>)->
    %% Test-only deterministic source, independent of mutation RNG/scheduler timing.
    whereis(efz_runtime_test_source)!{next,self()},
    receive {turn,N}->branch(N) end;
run(<<"vary_dirty">>)->
    whereis(efz_runtime_test_source)!{next,self()},
    receive {turn,1}->ok;{turn,_}->efz_target:dirty(verification_dirty),ok end;
run(<<"memory">>)->
    L=lists:seq(1,100000),receive after 100->ok end,
    X=lists:sum(L),erlang:garbage_collect(),receive after 100->ok end,X;
run(<<"mailbox_ets">>)->
    T=ets:new(runtime_fixture,[]),
    fill_ets(T,1000),
    fill_mailbox(100),
    receive after 160->ets:delete(T) end,ok;
run(<<"live_children">>)->
    children(4),receive after 100->ok end;
run(<<"child">>)->
    C=efz_target:spawn(fun()->receive after 1000->ok end end),is_pid(C);
run(<<"abnormal_child">>)->
    C=efz_target:spawn(fun()->receive go->exit(expected_child_exit) end end),
    Mon=monitor(process,C),C!go,
    receive {'DOWN',Mon,process,C,_}->receive after 30->ok end end;
run(<<"waiting">>)->receive never->ok end;
run(<<"busy">>)->busy(0);
run(<<"dirty">>)->efz_target:dirty(test_primary),ok;
run(_)->ok.
branch(1)->ok;
branch(2)->error(verification_only);
branch(_)->different_return.
busy(N)->busy(N+1).

fill_ets(_,0)->ok;
fill_ets(T,N)->ets:insert(T,{N,<<0:2048>>}),fill_ets(T,N-1).
fill_mailbox(0)->ok;
fill_mailbox(N)->self()!{bounded_message,N},fill_mailbox(N-1).

children(0)->ok;
children(N)->efz_target:spawn(fun()->receive never->ok end end),children(N-1).
