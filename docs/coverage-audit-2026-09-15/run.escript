#!/usr/bin/env escript
%%! +S 4:4
-mode(compile).
main(Args) ->
    Dir=filename:dirname(filename:absname(escript:script_name())),
    Root=filename:dirname(filename:dirname(Dir)),
    ok=file:set_cwd(Root),true=code:add_patha(filename:join([Root,"_build","default","lib","efz","ebin"])),
    Out=filename:join([Root,"_build","coverage-audit-2026-09-15"]),
    {ok,_}=application:ensure_all_started(crypto),
    {ok,A}=efz_instrument:compile(filename:join(Dir,"efz_cov_audit_sites.erl"),
        #{modules=>[efz_cov_audit_sites],source_root=>Root,outdir=>filename:join(Out,"target")}),
    {ok,efz_cov_audit_harness,Beam}=compile:noenv_file(filename:join(Dir,"efz_cov_audit_harness.erl"),[binary,debug_info,warnings_as_errors]),
    {module,efz_cov_audit_harness}=code:load_binary(efz_cov_audit_harness,"audit-harness",Beam),
    {ok,Ms}=efz_instrument:preflight([A]),
    {ok,P}=efz_cov_manifest:prepare(automatic,Ms),
    Base=#{coverage=>automatic,coverage_plan=>P,max_input_bytes=>128},
    try
        case Args of
            ["uncontrolled"] -> uncontrolled(Base,Out);
            [] ->
                Results=[suite(Base#{coverage_backend=>B}) || B<-[ets,ets_member]],
                save(filename:join(Out,"experiments"),#{otp=>erlang:system_info(otp_release),manifests=>Ms,backends=>Results}),
                fresh(Out),io:format("ALL COVERAGE AUDIT ASSERTIONS PASSED~n");
            _ -> error({usage,"run.escript [uncontrolled]"})
        end
    after efz_cov_manifest:release(P) end.
suite(O) ->
    Backend=maps:get(coverage_backend,O),
    {ok,Corpus}=efz_corpus:start_link([<<>>],{17,23,41}),
    F0=efz_feedback:new(efz_cov_manifest:builds(maps:get(coverage_plan,O))),
    try
        Inputs=[<<"AB">>,<<"AB">>,<<"ABC">>,<<"BA">>,<<"AC">>,
                <<"LOOP1">>,<<"LOOP2">>,<<"LOOP3">>,<<"LOOP8">>,<<"LOOP10">>,<<"LOOP1000">>],
        {Rows,F}=lists:mapfoldl(fun(I,Acc)->step(I,O,Acc) end,F0,Inputs),
        [new_coverage,equivalent_coverage,new_coverage,equivalent_coverage,equivalent_coverage,
         new_coverage,equivalent_coverage,equivalent_coverage,equivalent_coverage,equivalent_coverage,equivalent_coverage]
            =[maps:get(retention_reason,maps:get(decision,R)) || R<-Rows],
        [2,2,3,3,3,4,4,4,4,4,4]=[maps:get(corpus_size,R)||R<-Rows],
        Loops=lists:nthtail(5,Rows),[1,2,3,8,10,1000]=[maps:get(x_calls,maps:get(witness,R))||R<-Loops],
        [X]=lists:usort([maps:get(coverage,R)||R<-Loops]),1=length(X),
        [1]=lists:usort([maps:get(size,maps:get(witness,R))||R<-Loops]),
        Contexts=[maps:get(context,maps:get(witness,R)) || R<-Rows],
        true=length(Contexts)=:=length(lists:usort(Contexts)),
        %% Separate executions, no residual A in B, and a valid empty observation.
        A=execute(<<"A">>,O),B=execute(<<"B">>,O),A2=execute(<<"A">>,O),Z=execute(<<>>,O),
        HA=maps:get(coverage,A),HA=maps:get(coverage,A2),HB=maps:get(coverage,B),
        []=ordsets:intersection(HA,HB),[]=maps:get(coverage,Z),
        valid_empty_coverage=maps:get(classification,maps:get(coverage_observation,Z)),
        {ok,FCal,DCal}=efz_feedback:evaluate(F0,A,calibration),seed_calibration=maps:get(retention_reason,DCal),
        HA=lists:sort(sets:to_list(maps:get(global,FCal))),
        Failures=[failure(I,O,F0)||I<-[<<"CRASH">>,<<"TIMEOUT">>,<<"ERASE">>]],
        Children=[child_check(I,O,N)||{I,N}<-[{<<"CHILD">>,2},{<<"LINKED">>,2},{<<"NESTED">>,3}]],
        %% The real scheduler can consume retained rows, not a mock queue.
        {ok,MC}=efz_mutation_plan:prepare(#{stages=>[bitflip],seed=>{17,23,41}},[<<>>]),
        Entries=efz_corpus:mutation_entries(),
        {candidate,_,Provenance,_}=next_candidate(efz_mutation_plan:new(MC),Entries),
        <<"AB">>=maps:get(primary,Provenance),2=maps:get(parent,Provenance),
        io:format("~p: LOOP counts 1/2/3/8/10/1000 -> same one-row set; corpus sizes ~p; retained AB selected as parent 2~n",
                  [Backend,[maps:get(corpus_size,R)||R<-Rows]]),
        #{backend=>Backend,rows=>Rows,global=>lists:sort(sets:to_list(maps:get(global,F))),
          retained_parent=>Provenance,aba=>[A,B,A2],valid_empty=>Z,calibration=>DCal,
          failures=>Failures,children=>Children}
    after gen_server:stop(Corpus) end.
step(Input,O,F) ->
    R=execute(Input,O),{ok,W}=maps:get(outcome,R),
    {ok,Next,D}=efz_feedback:evaluate(F,R,mutation),
    case maps:get(retention_reason,D) of
        new_coverage -> {ok,_}=efz_corpus:add(Input,D#{parent=>1});
        equivalent_coverage -> ok
    end,
    Row=#{input=>Input,coverage=>maps:get(coverage,R),witness=>W,decision=>D,
          before=>lists:sort(sets:to_list(maps:get(global,F))),
          after_global=>lists:sort(sets:to_list(maps:get(global,Next))),corpus_size=>efz_corpus:size()},
    {Row,Next}.
execute(Input,O) ->
    T=case Input of <<"TIMEOUT">>->50;_->1000 end,
    R=efz_executor:run(efz_cov_audit_harness,Input,T,O),
    #{status:=confirmed,survivors:=[],processes:=Pids}=maps:get(cleanup,R),
    true=lists:all(fun(P)->not is_process_alive(P) end,Pids),
    undefined=ets:whereis(efz_coverage_observers),
    []=[T0||T0<-ets:all(),ets:info(T0,name)=:=efz_execution_coverage],
    case maps:get(outcome,R) of
        {ok,#{context:={efz_context,1,_,Backend,Owner},rows:=Rows,input:=Input,owner:=Owner,type:=set}} ->
            Table=case Backend of {ets_member,Tab}->Tab;Tab->Tab end,
            undefined=ets:info(Table),false=is_process_alive(Owner),
            Hits=maps:get(coverage,R),Hits=lists:sort([Id||{{probe,Id}}<-Rows]);
        _ -> ok
    end,R.
failure(I,O,F) ->
    R=execute(I,O),
    case I of
        <<"ERASE">> -> {infrastructure,_}=maps:get(outcome,R),{error,_}=efz_feedback:evaluate(F,R,mutation);
        _ -> {ok,F,D}=efz_feedback:evaluate(F,R,mutation),
             target_failure=maps:get(retention_reason,D),[]=maps:get(new_probes,D),
             1=length(maps:get(coverage,R))
    end,
    #{input=>I,result=>R,feedback=>efz_feedback:evaluate(F,R,mutation)}.
child_check(I,O,Count) ->
    R=execute(I,O),{ok,#{value:={child,Child,Context},context:=Context}}=maps:get(outcome,R),
    Ps=maps:get(processes,maps:get(cleanup,R)),true=lists:member(Child,Ps),Count=length(Ps),
    [{efz_cov_audit_sites,_,3}]=maps:get(coverage,R),#{input=>I,result=>R}.
next_candidate(S,Es) ->
    case efz_mutation_plan:next(S,Es) of {skip,_,Next}->next_candidate(Next,Es);Candidate->Candidate end.
uncontrolled(O,Out) ->
    R=efz_executor:run(efz_cov_audit_harness,<<"UNCONTROLLED">>,1000,O),
    {infrastructure,_}=maps:get(outcome,R),false=maps:get(runner_reusable,R),
    []=maps:get(coverage,R),Ps=maps:get(processes,maps:get(cleanup,R)),
    true=length(Ps)>=2,true=lists:all(fun(P)->not is_process_alive(P) end,Ps),
    Again=efz_executor:run(efz_cov_audit_harness,<<"A">>,1000,O),
    not_started=maps:get(status,maps:get(cleanup,Again)),
    save(filename:join(Out,"uncontrolled"),#{first=>R,reuse=>Again}),
    io:format("uncontrolled child: no coverage, infrastructure outcome, all ~B known processes dead, reuse rejected~n",[length(Ps)]).
fresh(Out) ->
    Port=open_port({spawn_executable,os:find_executable("escript")},[binary,exit_status,stderr_to_stdout,
        {args,[filename:absname(escript:script_name()),"uncontrolled"]}]),
    {0,Text}=wait_port(Port,<<>>),ok=file:write_file(filename:join(Out,"uncontrolled.log"),Text),io:put_chars(Text).
wait_port(P,Acc) -> receive
    {P,{data,B}}->wait_port(P,<<Acc/binary,B/binary>>);
    {P,{exit_status,N}}->{N,Acc}
    after 30000->port_close(P),error(child_vm_timeout) end.
save(Path,Term) ->
    ok=file:write_file(Path++".term",term_to_binary(Term)),
    ok=file:write_file(Path++".txt",unicode:characters_to_binary(io_lib:format("~tp.~n",[Term]))).
