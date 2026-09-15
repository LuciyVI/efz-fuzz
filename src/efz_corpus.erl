-module(efz_corpus).
-behaviour(gen_server).
-export([start_link/1,start_link/2,start_link/3,start_link/4,add/2,select/0,size/0,all/0,mutation_entries/0]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,code_change/3]).
start_link(Seeds)->start_link(Seeds,undefined).
start_link(Seeds,SelectionSeed)->start_link(Seeds,SelectionSeed,undefined).
start_link(Seeds,SelectionSeed,Store)->start_link(Seeds,SelectionSeed,Store,efz_input:default_limit()).
start_link(Seeds,SelectionSeed,Store,Max)->gen_server:start_link({local,?MODULE},?MODULE,{Seeds,SelectionSeed,Store,Max},[]).
add(B,Meta)->gen_server:call(?MODULE,{add,B,Meta},infinity). select()->gen_server:call(?MODULE,select). size()->gen_server:call(?MODULE,size). all()->gen_server:call(?MODULE,all).
mutation_entries()->gen_server:call(?MODULE,mutation_entries).
init({Seeds,SelectionSeed,Store,Max})->
 case SelectionSeed of undefined->ok; _->_=rand:seed(exsplus,SelectionSeed),ok end,
    try
        lists:foreach(fun(B) -> case efz_input:check(B,Max,initial_seed) of ok->ok;{error,E}->error(E) end end,Seeds),
        Rows = case Store of undefined -> []; _ -> maps:get(restored, Store, []) end,
        Saved = maps:from_list([{maps:get(content_hash, maps:get(record, R)), maps:get(record, R)} || R <- Rows]),
        Es = [initial(B,I,Store,Saved) || {B,I} <- lists:zip(Seeds,lists:seq(1,length(Seeds)))],
        Compact = case Store of undefined -> undefined; _ -> maps:remove(restored,Store) end,
        {ok,#{entries=>Es,next=>length(Seeds)+1,store=>Compact,max_input_bytes=>Max}}
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
handle_cast(_,S)->{noreply,S}. handle_info(_,S)->{noreply,S}. terminate(_,_) -> ok. code_change(_,S,_) -> {ok,S}.
