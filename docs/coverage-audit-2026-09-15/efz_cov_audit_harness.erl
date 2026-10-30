%% Keep dispatch/loop control outside the selected instrumentation scope so
%% LOOP1 vs LOOP1000 differ only in multiplicity of the SAME x/0 probe.
-module(efz_cov_audit_harness).
-export([run/1]).
run(<<"ERASE">>) ->
    efz_cov_audit_sites:a(),erase('$efz_execution_context'),
    catch efz_cov_audit_sites:b();
run(Input) when is_binary(Input) ->
    put(audit_x_calls,0),Value=dispatch(Input),
    {efz_context,1,_,Backend,_}=Context=get('$efz_execution_context'),
    Table=case Backend of {ets_member,T}->T;T->T end,
    #{value=>Value,input=>Input,context=>Context,rows=>lists:sort(ets:tab2list(Table)),
      owner=>ets:info(Table,owner),type=>ets:info(Table,type),
      size=>ets:info(Table,size),memory_words=>ets:info(Table,memory),
      x_calls=>get(audit_x_calls)}.
dispatch(<<"A">>) -> efz_cov_audit_sites:a();
dispatch(<<"B">>) -> efz_cov_audit_sites:b();
dispatch(<<"AB">>) -> efz_cov_audit_sites:a(),efz_cov_audit_sites:b();
dispatch(<<"ABC">>) -> efz_cov_audit_sites:a(),efz_cov_audit_sites:b(),efz_cov_audit_sites:c();
dispatch(<<"BA">>) -> efz_cov_audit_sites:b(),efz_cov_audit_sites:a();
dispatch(<<"AC">>) -> efz_cov_audit_sites:a(),efz_cov_audit_sites:c();
dispatch(<<"LOOP",Digits/binary>>) -> loop(binary_to_integer(Digits));
dispatch(<<"CRASH">>) -> efz_cov_audit_sites:x(),error(audit_crash);
dispatch(<<"TIMEOUT">>) -> efz_cov_audit_sites:x(),receive never -> ok end;
dispatch(<<"CHILD">>) -> controlled(false);
dispatch(<<"LINKED">>) -> controlled(true);
dispatch(<<"NESTED">>) ->
    Root=self(),
    efz_target:spawn(fun()->
        efz_target:spawn(fun()->child(Root) end),receive never -> ok end
    end),
    receive {child,_,_}=Message -> Message end;
dispatch(<<"UNCONTROLLED">>) ->
    spawn(fun()->efz_cov_audit_sites:c(),receive never -> ok end end),
    receive never -> ok end;
dispatch(_) -> unknown.
loop(0) -> ok;
loop(N) -> efz_cov_audit_sites:x(),loop(N-1).
controlled(Link) ->
    Root=self(),Fun=fun()->child(Root) end,
    case Link of true->efz_target:spawn_link(Fun);false->efz_target:spawn(Fun) end,
    receive {child,_,_}=Message -> Message end.
child(Root) ->
    efz_cov_audit_sites:c(),Root!{child,self(),get('$efz_execution_context')},
    receive never -> ok end.
