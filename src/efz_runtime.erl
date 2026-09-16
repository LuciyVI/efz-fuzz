%% Guardian lifecycle hooks. Sampling never runs in the deadline owner.
-module(efz_runtime).
-export([start/1, admit/2, down/4, stop/1, sampler_down/2, finish/3, categories/1,
         timeout/3, process_sample/2, table_sample/2]).
start(#{runtime_oracles:=#{enabled:=true}=P}=Options)->
    Tab=ets:new(efz_runtime_buffer,[public,set]),
    Base=#{scope=>target_owned,known_processes=>0,memory_bytes=>0,ets_tables=>0,
           vm_global=>vm_context()},
    true=ets:insert(Tab,{summary,#{samples=>[],sample_count=>0,sampling_us=>0,peak=>#{},ets_scans=>0,missed_sample_ticks=>0}}),
    G=self(),
    Sampling=maps:get(enabled,maps:get(resources,P)) orelse maps:get(enabled,maps:get(hangs,P)),
    {Pid,Mon}=case Sampling of
        true->spawn_monitor(fun()->GM=monitor(process,G),
            sampler(Tab,P,GM,now_ms()+maps:get(ets_interval_ms,maps:get(resources,P))) end);
        false->{undefined,undefined} end,
    #{tab=>Tab,pid=>Pid,mon=>Mon,alive=>Sampling,policy=>P,baseline=>Base,origin=>maps:get(execution_origin,Options,standalone),
      created=>0,live=>0,peak_live=>0,children=>[],child_dropped=>0,sampler_status=>case Sampling of true->running;false->disabled end};
start(_)->disabled.
admit(_,disabled)->disabled;
admit(P,R=#{tab:=T,created:=N,live:=L})->
    true=ets:insert(T,{{owned,P},N}),R#{created=>N+1,live=>L+1,peak_live=>max(L+1,maps:get(peak_live,R))}.
down(_,_,_,disabled)->disabled;
down(P,Why,Phase,R=#{tab:=T,children:=Cs})->
    Role=case ets:lookup(T,{owned,P}) of [{{owned,P},0}]->root;_->child end,
    true=ets:delete(T,{owned,P}),
    R1=R#{live=>max(0,maps:get(live,R)-1)},
    case Role of
        root->R1;
        child->
            E=#{reason=>efz_stability:outcome({exit,Why}),phase=>Phase,
                classification=>case {Phase,Why} of
                    {running,normal}->normal;
                    {running,_}->abnormal_during_execution;
                    {cleaning,_}->unknown
                end,kill_requested=>Phase=:=cleaning,initiator=>unknown},
            case length(Cs)<256 of true->R1#{children=>[E|Cs]};
                false->R1#{child_dropped=>maps:get(child_dropped,R)+1} end
    end.
stop(disabled)->disabled;
stop(R=#{pid:=undefined})->R#{cutoff_ms=>now_ms()};
stop(R=#{pid:=P})->exit(P,kill),R#{cutoff_ms=>now_ms()}.
sampler_down(Why,R)->R#{alive=>false,sampler_status=>case maps:is_key(cutoff_ms,R) of
    true->stopped;false->{failed,efz_stability:outcome({exit,Why})} end}.
finish(disabled,_,_)->#{};
finish(R=#{tab:=T,policy:=P},Outcome,Cleanup)->
    [{summary,S}]=ets:lookup(T,summary),
    BufferBytes=ets:info(T,memory)*erlang:system_info(wordsize),
    true=ets:delete(T),
    Samples=maps:get(samples,S),Peak=maps:get(peak,S),Cs=lists:reverse(maps:get(children,R)),
    Resources=maps:get(resources,P),
    Facts=case maps:get(enabled,Resources) of
        false->[];
        true->thresholds(Peak,Resources,Samples)
    end,
    ChildCats=case lists:any(fun(#{classification:=C})->C=:=abnormal_during_execution end,Cs) of
        true->[child_abnormal_exit];false->[] end,
    Activity=case maps:get(created,R)>1 of true->[descendant_activity];false->[] end,
    Hang=case {Outcome,maps:get(enabled,maps:get(hangs,P))} of
        {{timeout,_},true}->timeout(Samples,maps:get(cutoff_ms,R,now_ms()),maps:get(hangs,P));
        _->#{categories=>[]}
    end,
    #{runtime_observations=>S#{schema_version=>1,origin=>maps:get(origin,R),scope=>target_owned,baseline=>maps:get(baseline,R),
        sampling_status=>case {maps:get(sampler_status,R),Samples} of {disabled,_}->disabled;{_,[]}->not_sampled;_->sampled end,
        sampler_status=>maps:get(sampler_status,R),diagnostic_buffer_bytes=>BufferBytes,
        children=>Cs,children_dropped=>maps:get(child_dropped,R),
        descendants_created=>max(0,maps:get(created,R)-1),
        descendants_peak_live=>max(0,maps:get(peak_live,R)-1),
        before_cleanup=>case Samples of []->not_sampled;[Last|_]->Last end,
        after_cleanup=>#{status=>maps:get(status,Cleanup),known_survivors=>length(maps:get(survivors,Cleanup)),
            ets_state=>case maps:get(status,Cleanup) of confirmed->owners_terminated;_->unconfirmed end},
        thresholds=>Facts,timeout=>Hang,
        categories=>lists:usort([maps:get(category,F)||F<-Facts]++ChildCats++Activity++maps:get(categories,Hang)),
        partial=>maps:get(child_dropped,R)>0 orelse not lists:member(maps:get(sampler_status,R),[stopped,disabled]) orelse lists:any(fun(X)->maps:get(partial,X) end,Samples)}}.
categories(R)->maps:get(categories,maps:get(runtime_observations,R,#{}),[]).
thresholds(P,R,Samples)->
    Rules=[{memory_pressure,memory_bytes,memory_bytes},{mailbox_pressure,mailbox_messages,mailbox_messages},
           {ets_growth_suspected,ets_memory_bytes,ets_memory_bytes}],
    Fs=[#{category=>C,scope=>target_owned,baseline=>0,observed=>maps:get(K,P),threshold=>maps:get(T,R),
          interpretation=>observed_peak,defect=>unproven}||{C,K,T}<-Rules,maps:is_key(K,P),maps:get(K,P)>=maps:get(T,R)],
    case Samples of
        [Last, _|_]->First=lists:last(Samples),D=maps:get(memory_bytes,Last)-maps:get(memory_bytes,First),
            case D>=maps:get(memory_bytes,R) of
                true->[#{category=>memory_growth_suspected,scope=>target_owned,
                    baseline=>maps:get(memory_bytes,First),observed=>maps:get(memory_bytes,Last),
                    threshold=>maps:get(memory_bytes,R),interpretation=>within_execution_growth,defect=>unproven}|Fs];
                false->Fs end;
        _->Fs end.
vm_context()->#{scope=>vm_global,process_count=>erlang:system_info(process_count),
    atom_count=>erlang:system_info(atom_count),atom_limit=>erlang:system_info(atom_limit)}.
sampler(T,P,GM,NextETS)->
    R=maps:get(resources,P),
    receive {'DOWN',GM,process,_,_}->ok
    after maps:get(sample_interval_ms,R)->
        case maps:get(enabled,R) orelse maps:get(enabled,maps:get(hangs,P)) of
            false->receive {'DOWN',GM,process,_,_}->ok end;
            true->Start=erlang:monotonic_time(microsecond),
                Owned=ets:match_object(T,{{owned,'_'},'_'}),Known=length(Owned),
                Pids=[Pid||{{owned,Pid},_}<-lists:sublist(lists:keysort(2,Owned),maps:get(max_sampled_processes,R))],
                Ids=maps:from_list([{Pid,Id}||{{owned,Pid},Id}<-Owned]),
                Ps=[X#{process_id=>maps:get(Pid,Ids)}||Pid<-Pids,
                    X<-[process_sample(Pid,maps:get(max_stack_frames,maps:get(hangs,P)))],X=/=unavailable],
                Time=now_ms(),DoETS=maps:get(enabled,R) andalso Time>=NextETS,
                ETS=case DoETS of true->tables(Owned,maps:get(max_ets_tables,R));false->#{status=>not_sampled} end,
                S0=#{at_ms=>Time,known_processes=>Known,observed_processes=>length(Ps),
                    processes=>Ps,memory_bytes=>sum(memory,Ps),mailbox_messages=>sum(message_queue_len,Ps),
                    ets=>ETS,partial=>length(Ps)<Known orelse maps:get(partial,ETS,false)},
                S=case ETS of #{memory_bytes:=E}->S0#{ets_memory_bytes=>E};_->S0 end,
                [{summary,Old}]=ets:lookup(T,summary),
                Samples=lists:sublist([S|maps:get(samples,Old)],maps:get(max_samples,R)),
                Peak=maps:fold(fun(K,V,A)->case is_integer(V) of true->A#{K=>max(V,maps:get(K,A,0))};false->A end end,
                    maps:get(peak,Old),maps:with([memory_bytes,mailbox_messages,ets_memory_bytes],S)),
                New=Old#{samples=>Samples,peak=>Peak,sample_count=>maps:get(sample_count,Old)+1,
                    ets_scans=>maps:get(ets_scans,Old)+case DoETS of true->1;false->0 end,
                    sampling_us=>maps:get(sampling_us,Old)+erlang:monotonic_time(microsecond)-Start},
                Published=case Ps of
                    []->Old#{missed_sample_ticks=>maps:get(missed_sample_ticks,Old)+1,
                        sampling_us=>maps:get(sampling_us,New)};
                    _->New end,
                true=ets:insert(T,{summary,Published}),
                sampler(T,P,GM,case DoETS of true->Time+maps:get(ets_interval_ms,R);false->NextETS end)
        end
    end.
process_sample(P,N)->
    try process_info(P,[memory,message_queue_len,reductions,status,current_function,current_stacktrace]) of
        undefined->unavailable;
        L->M=maps:from_list(L),Stack=lists:sublist(maps:get(current_stacktrace,M,[]),N),
           M#{pid=>P,current_stacktrace=>[{Mod,F,case A of X when is_integer(X)->X;_->unknown end}||{Mod,F,A,_}<-Stack]}
    catch error:badarg->unavailable end.
sum(K,Ps)->lists:sum([maps:get(K,P,0)||P<-Ps]).
tables(Owned,Limit)->
    Owners=maps:from_list([{P,Id}||{{owned,P},Id}<-Owned]),All=ets:all(),
    Candidates=lists:sublist(All,Limit),
    Measured=[table_sample(T,Owners)||T<-Candidates],
    Rows=[X||X<-Measured,is_map(X)],
    #{status=>sampled,scope=>target_owned,known_vm_tables=>length(All),scanned_vm_tables=>length(Candidates),
      observed_tables=>length(Rows),tables=>Rows,memory_bytes=>sum(memory_bytes,Rows),size=>sum(size,Rows),
      partial=>length(All)>Limit orelse lists:member(unavailable,Measured) orelse lists:any(fun(T)->ets:info(T)=:=undefined end,Candidates)}.
table_sample(T,Owners)->
    try
        Owner=ets:info(T,owner),
        case maps:is_key(Owner,Owners) of
            false->unowned;
            true->Words=ets:info(T,memory),Size=ets:info(T,size),true=is_integer(Words) andalso is_integer(Size),
                true=ets:info(T,owner)=:=Owner,
                #{owner=>Owner,owner_id=>maps:get(Owner,Owners),memory_words=>Words,memory_bytes=>Words*erlang:system_info(wordsize),size=>Size}
        end
    catch error:_->unavailable end.
timeout([Last,Prev|_],Now,H)->
    Age=max(0,Now-maps:get(at_ms,Last)),
    Ps=maps:get(processes,Last),Earlier=maps:from_list([{maps:get(pid,P),maps:get(reductions,P)}||P<-maps:get(processes,Prev)]),
    Deltas=[max(0,maps:get(reductions,P)-maps:get(maps:get(pid,P),Earlier))||P<-Ps,maps:is_key(maps:get(pid,P),Earlier)],
    D=lists:sum(Deltas),Statuses=[maps:get(status,P)||P<-Ps],
    Cat=case Age=<maps:get(max_sample_age_ms,H) andalso
        Now-maps:get(at_ms,Prev)=<2*maps:get(max_sample_age_ms,H) andalso
        maps:get(at_ms,Last)>maps:get(at_ms,Prev) andalso length(Deltas)>0 of
        false->timeout_unknown;
        true->case D>=maps:get(busy_reductions,H) of
            true->timeout_busy;
            false->case not maps:get(partial,Last) andalso not maps:get(partial,Prev) andalso
                length(Deltas)=:=length(Ps) andalso lists:all(fun(X)->X=:=waiting end,Statuses) of
                true->timeout_waiting;false->timeout_unknown end end
    end,
    #{categories=>[Cat],sample_age_ms=>Age,interval_ms=>maps:get(at_ms,Last)-maps:get(at_ms,Prev),
      observed_processes=>length(Ps),matched_processes=>length(Deltas),reductions_delta=>D,statuses=>Statuses,
      evidence=>Ps,interpretation=>observation_only};
timeout(_,_,_)->#{categories=>[timeout_unknown],reason=>insufficient_samples}.
now_ms()->erlang:monotonic_time(millisecond).
