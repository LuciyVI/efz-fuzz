%% Explicit cold operation. Replay bounded raw seeds, write a NEW normal EFZ
%% store, restart it and verify both namespaces. Never delete a source store.
-module(efz_semantic_corpus).
-export([reduce/3]).

reduce(Config,Destination,Limits) ->
    try
        true=whereis(efz_fuzzer)=:=undefined,
        false=filelib:is_dir(Destination),false=filelib:is_file(Destination),
        false=maps:is_key(corpus_dir,Config),
        Max=maps:get(entries,Limits,256),Bytes=maps:get(bytes,Limits,1048576),
        Ms=maps:get(timeout_ms,Limits,30000),
        true=is_integer(Max) andalso Max>=1 andalso Max=<512,
        true=is_integer(Bytes) andalso Bytes>=0 andalso Bytes=<2097152,
        true=is_integer(Ms) andalso Ms>=1 andalso Ms=<300000,
        Seeds=bounded(maps:get(seeds,Config),Max,Bytes,[]),
        %% Two complete calibrations, with no online mutations or oracle.
        Start=erlang:monotonic_time(millisecond),Deadline=Start+Ms,
        C=Config#{seeds=>Seeds,max_iterations=>0,
            gleam_layer=>#{structured_fraction=>0,feedback=>guided,oracle=>disabled}},
        {ok,Prepared}=efz_config:prepare(C),
        Before=calibrate(C,Deadline),
        Entries=[eligible(E)||E<-maps:get(corpus,Before)],
        {Kept,_,_}=efz_semantic:cover(Entries),true=Kept=/=[],
        check_deadline(Deadline),
        Store=#{dir=>Destination,identity=>efz_corpus_store:identity(Prepared),
            max_input_bytes=>maps:get(max_input_bytes,Prepared)},
        [First|_]=Kept,Parent=crypto:hash(sha256,maps:get(input,First)),
        lists:foreach(fun({E,Id})->
            check_deadline(Deadline),M=maps:get(metadata,E),
            Reason=case Id of 1->initial_seed;_->case maps:get(new_probes,M,[]) of
                []->new_semantic;_->new_coverage end end,
            Meta=M#{retention_reason=>Reason,parent=>1,parent_content=>Parent},
            StoredMeta=case Id of 1->maps:remove(semantic,Meta);_->Meta end,
            {ok,_}=efz_corpus_store:save(Store,maps:get(input,E),Id,StoredMeta)
        end,lists:zip(Kept,lists:seq(1,length(Kept)))),
        After=calibrate(C#{seeds=>[],corpus_dir=>Destination},Deadline),
        true=maps:get(coverage,Before)=:=maps:get(coverage,After),
        true=maps:get(semantic_features,Before)=:=maps:get(semantic_features,After),
        {ok,#{schema_version=>1,destination=>filename:absname(Destination),
            before_entries=>length(maps:get(corpus,Before)),after_entries=>length(Kept),
            target_executions=>maps:get(calibrations,maps:get(stats,Before))+
                maps:get(calibrations,maps:get(stats,After)),online_executions=>0,
            elapsed_ms=>erlang:monotonic_time(millisecond)-Start,
            coverage=>maps:get(coverage,After),features=>maps:get(semantic_features,After),
            before=>Before,restarted=>After}}
    catch error:Why->{error,{corpus_reduction,Why}};
          exit:Why->{error,{corpus_reduction,Why}}
    end.
bounded([],_,_,Acc)->lists:usort(Acc);
bounded([B|Rest],N,Bytes,Acc) when N>0,is_binary(B),byte_size(B)=<4096,byte_size(B)=<Bytes ->
    bounded(Rest,N-1,Bytes-byte_size(B),[B|Acc]);
bounded(_,_,_,_)->error(corpus_reduction_input_limit).
eligible(#{metadata:=#{semantic:=_,outcome:={ok,_}}=M}=E)->E#{metadata=>M#{phase=>mutation}};
eligible(E)->E.
check_deadline(D)->case erlang:monotonic_time(millisecond)<D of
    true->ok;false->error(corpus_reduction_deadline) end.
calibrate(C,D)->
    check_deadline(D),
    try
        {ok,_}=efz:start(C),R=efz:await(max(1,D-erlang:monotonic_time(millisecond))),
        true=maps:get(status,R)=:=completed,
        true=maps:get(infrastructure_failures,maps:get(stats,R))=:=0,R
    after efz:stop() end.
