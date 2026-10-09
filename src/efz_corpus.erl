-module(efz_corpus).
-behaviour(gen_server).
-export([start_link/1,start_link/2,start_link/3,start_link/4,start_link/5,add/2,select/0,size/0,all/0,mutation_entries/0,
         admit_semantic/4, semantic_state/0, semantic_representatives/0]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,code_change/3]).
start_link(Seeds)->start_link(Seeds,undefined).
start_link(Seeds,SelectionSeed)->start_link(Seeds,SelectionSeed,undefined).
start_link(Seeds,SelectionSeed,Store)->start_link(Seeds,SelectionSeed,Store,efz_input:default_limit()).
start_link(Seeds,SelectionSeed,Store,Max)->start_link(Seeds,SelectionSeed,Store,Max,false).
start_link(Seeds,SelectionSeed,Store,Max,Layer)->gen_server:start_link({local,?MODULE},?MODULE,{Seeds,SelectionSeed,Store,Max,Layer},[]).
admit_semantic(B,Meta,Fs,Keep)->gen_server:call(?MODULE,{admit_semantic,B,Meta,Fs,Keep},infinity).
semantic_state()->gen_server:call(?MODULE,semantic_state).
semantic_representatives()->gen_server:call(?MODULE,semantic_representatives).
add(B,Meta)->gen_server:call(?MODULE,{add,B,Meta},infinity). select()->gen_server:call(?MODULE,select). size()->gen_server:call(?MODULE,size). all()->gen_server:call(?MODULE,all).
mutation_entries()->gen_server:call(?MODULE,mutation_entries).
init({Seeds,SelectionSeed,Store,Max,Layer})->
 case SelectionSeed of undefined->ok; _->_=rand:seed(exsplus,SelectionSeed),ok end,
    try
        lists:foreach(fun(B) -> case efz_input:check(B,Max,initial_seed) of ok->ok;{error,E}->error(E) end end,Seeds),
        Rows = case Store of undefined -> []; _ -> maps:get(restored, Store, []) end,
        Saved = maps:from_list([{maps:get(content_hash, maps:get(record, R)), maps:get(record, R)} || R <- Rows]),
        Es = [initial(B,I,Store,Saved) || {B,I} <- lists:zip(Seeds,lists:seq(1,length(Seeds)))],
        Compact = case Store of undefined -> undefined; _ -> maps:remove(restored,Store) end,
        State=#{entries=>Es,next=>length(Seeds)+1,store=>Compact,max_input_bytes=>Max},
        {ok,case Layer of #{feedback:=guided}->State#{semantic_seen=>[]};_->State end}
    catch error:Why -> {stop,{corpus_persistence,Why}} end.
initial(B,I,Store,Saved) ->
    Meta = case maps:find(crypto:hash(sha256,B),Saved) of
        {ok,R} -> #{restored=>true,persistence=>R};
        error -> case persist(Store,B,I,#{}) of
            {ok,M}->M; {error,Why}->error(Why)
        end
    end,
    entry(B,I,Meta).
entry(B,I,Meta)->#{id=>I,input=>B,metadata=>Meta,added_at=>erlang:system_time(millisecond)}.
persist(undefined,_,_,Meta)->{ok,Meta};
persist(Store,B,I,Meta)->
    case efz_corpus_store:save(Store,B,I,Meta) of
        {ok,R}->{ok,Meta#{persistence=>R}};
        {error,Why}->{error,{corpus_persistence,Why}}
    end.
handle_call(mutation_entries,_,S=#{entries:=Es})->{reply,[maps:with([id,input],E)||E<-Es],S};
handle_call(semantic_state,_,S)->{reply,maps:get(semantic_seen,S,disabled),S};
handle_call(semantic_representatives,_,S=#{semantic_seen:=Seen,entries:=Es})->
    Index=efz_semantic:representatives(Es),
    Reply=case Seen--maps:keys(Index) of []->{ok,Index};_-> {error,missing_semantic_representative} end,
    {reply,Reply,S};
handle_call(semantic_representatives,_,S)->{reply,disabled,S};
handle_call({admit_semantic,B,Meta,Fs,Keep},_,S=#{semantic_seen:=Seen,max_input_bytes:=Max}) ->
    case efz_input:check(B,Max,corpus_insert)=:=ok andalso efz_semantic:valid(Fs) andalso is_boolean(Keep) of
        false->{reply,{error,invalid_semantic_admission},S};
        true->semantic_admission(B,Meta,lists:usort(Fs),Keep,Seen,S)
    end;
handle_call({add,B,Meta},_,S=#{max_input_bytes:=Max})->
    case efz_input:check(B,Max,corpus_insert) of
        ok -> add_checked(B,Meta,S);
        {error,Why} -> {reply,{error,Why},S}
    end;
handle_call(select,_,#{entries:=[]} = S)->{reply,empty,S}; handle_call(select,_,#{entries:=Es}=S)->{reply,lists:nth(rand:uniform(length(Es)),Es),S}; handle_call(size,_,S)->{reply,length(maps:get(entries,S)),S}; handle_call(all,_,S)->{reply,maps:get(entries,S),S}; handle_call(_,_,S)->{reply,ok,S}.
add_checked(B,Meta,S=#{entries:=Es,next:=N,store:=Store})->
    case lists:any(fun(E)->maps:get(input,E)=:=B end,Es) of
        true->{reply,{existing,B},S};
        false ->
            ParentMeta = case Store of
                undefined -> Meta;
                _ -> [Parent] = [E || E <- Es, maps:get(id,E) =:= maps:get(parent,Meta)],
                     Meta#{parent_content=>crypto:hash(sha256,maps:get(input,Parent))}
            end,
            case persist(Store,B,N,ParentMeta) of
                {ok,StoredMeta}->{reply,{ok,N},S#{entries=>Es++[entry(B,N,StoredMeta)],next=>N+1}};
                {error,Why}->{reply,{error,Why},S}
            end
    end.
semantic_admission(B,Meta,Fs,Keep,Seen,S=#{entries:=Es})->
    New=Fs--Seen,Calibration=maps:get(phase,Meta)=:=calibration,
    M=Meta#{semantic=>efz_semantic:metadata(Fs),new_semantic_features=>New},
    case [E||E<-Es,maps:get(input,E)=:=B] of
        [Existing|_] ->
            %% Initial bytes are already durable; rebuild annotations by replay.
            Old=maps:get(metadata,Existing),Union=lists:usort(efz_semantic:features(Old)++Fs),
            Updated=Existing#{metadata=>semantic_annotation(Old,M,Union,Calibration)},
            Next=[case maps:get(id,E)=:=maps:get(id,Existing) of true->Updated;false->E end||E<-Es],
            {reply,{existing,maps:get(id,Existing),M},S#{entries=>Next,semantic_seen=>lists:usort(Seen++Fs)}};
        [] when Calibration -> {reply,{error,missing_calibration_entry},S};
        [] when not Keep,New=:=[] -> {reply,{rejected,M},S};
        [] ->
            WithReason=case Keep of true->M;false->M#{retention_reason=>new_semantic} end,
            case add_checked(B,WithReason,S) of
                {reply,{ok,Id},Next}->{reply,{ok,Id,WithReason},Next#{semantic_seen=>lists:usort(Seen++Fs)}};
                {reply,Error,_}->{reply,Error,S}
            end
    end.
semantic_annotation(Old,M,Union,Calibration)->
    %% Iteration decisions must not erase a representative's admission evidence.
    Base=case Calibration of true->maps:merge(Old,M);false->Old end,
    Annotated=Base#{semantic=>efz_semantic:metadata(Union),
        new_probes=>lists:usort(maps:get(new_probes,Old,[])++maps:get(new_probes,M,[]))},
    WithCounts=case maps:is_key(new_count_features,Old) orelse maps:is_key(new_count_features,M) of
        true->Annotated#{new_count_features=>lists:usort(maps:get(new_count_features,Old,[])++maps:get(new_count_features,M,[]))};
        false->Annotated end,
    Discovery=maps:get(discovery,maps:get(persistence,Old,#{}),#{}),
    case maps:get(retention_reason,Old,maps:get(retention_reason,Discovery,undefined)) of
        new_semantic->WithCounts#{retention_reason=>new_semantic};
        _->WithCounts
    end.
handle_cast(_,S)->{noreply,S}. handle_info(_,S)->{noreply,S}. terminate(_,_) -> ok. code_change(_,S,_) -> {ok,S}.
