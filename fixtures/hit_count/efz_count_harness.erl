%% Dispatch/loop control is deliberately outside the selected probe scope.
-module(efz_count_harness).
-export([run/1]).
run(<<"PAIR",A:16,B:16>>) ->
    repeat(A,fun efz_count_sites:a/0),repeat(B,fun efz_count_sites:b/0),{A,B};
run(<<"CHILD">>) ->
    Root=self(),
    Ps=[efz_target:spawn(fun()->repeat(500,fun efz_count_sites:x/0),Root!{done,self()} end)||_<-[1,2]],
    [receive {done,P}->ok end||P<-Ps],ok;
run(<<"CRASH">>) -> efz_count_sites:x(),error(count_crash);
run(<<"TIMEOUT">>) -> efz_count_sites:x(),receive never->ok end;
run(<<"CORRUPT">>) ->
    efz_count_sites:x(),
    {efz_context,1,_,{ets_count,T},_}=get('$efz_execution_context'),
    [{{probe,Id},_}]=ets:tab2list(T),ets:insert(T,{{probe,Id},0}),ok;
run(<<"L",Digits/binary>>=Input) ->
    case catch binary_to_integer(Digits) of
        N when is_integer(N),N>0,N=<1000000 -> repeat(N,fun efz_count_sites:x/0),{Input,N};
        _ -> ignored
    end;
run(_) -> ignored.
repeat(0,_) -> ok;
repeat(N,F) -> F(),repeat(N-1,F).
