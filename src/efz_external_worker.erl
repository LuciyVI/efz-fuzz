%% Private entrypoint and mandatory executor gate. Fixed wire schema, never ETF.
-module(efz_external_worker).
-behaviour(gen_server).
-export([main/0,ready/0,quarantined/1,execution/4]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,code_change/3]).
-spec main() -> no_return().
main()->
    [Path,Gen,Expected,Q,FilesCount|Rest]=init:get_plain_arguments(),
    {Files,["--"|Args]}=lists:split(list_to_integer(FilesCount),Rest),
    Hashes=[begin {ok,B}=file:read_file(F),crypto:hash(sha256,B) end||F<-Files],
    Identity=crypto:hash(sha256,iolist_to_binary(Hashes)),
    Identity=binary:decode_hex(list_to_binary(Expected)),
    true=os:putenv("EFZ_EXTERNAL_REQUIRED","1"),
    ConfigHash=crypto:hash(sha256,iolist_to_binary([begin B=unicode:characters_to_binary(A),
        <<(byte_size(B)):32,B/binary>> end||A<-Args])),
    {ok,_}=gen_server:start({local,?MODULE},?MODULE,{Path,list_to_integer(Gen),Identity,ConfigHash,Q},[]),
    Exit=efz_cli:main(Args),ok=gen_server:call(?MODULE,{done,Exit},infinity),halt(Exit).
ready()->case whereis(?MODULE) of undefined->ok;_->gen_server:call(?MODULE,ready,infinity) end.
quarantined(B)->case whereis(?MODULE) of
    undefined->false;_->gen_server:call(?MODULE,{quarantined,crypto:hash(sha256,B)},infinity) end.
execution(Input,Timeout,O,Fun)->
    case whereis(?MODULE) of
        undefined->case os:getenv("EFZ_EXTERNAL_REQUIRED") of false->Fun();_->error(external_barrier_unavailable) end;
        _ -> true=is_binary(Input),
            Run=gen_server:call(?MODULE,{prepare,Input,Timeout,maps:get(execution_origin,O,verification),
                maps:get(execution_recipe,O,undefined)},infinity),
            R=Fun(),ok=gen_server:call(?MODULE,{result,Run,R},infinity),R
    end.
init({Path,G,Identity,ConfigHash,Q})->
    {ok,S}=gen_tcp:connect({local,Path},0,[binary,{active,false},{packet,raw}],5000),
    OTP=list_to_binary(erlang:system_info(otp_release)),ERTS=list_to_binary(erlang:system_info(version)),
    Pid=list_to_integer(os:getpid()),
    send(S,1,G,0,<<"EFZ1",Identity/binary,ConfigHash/binary,Pid:32,(byte_size(OTP)):8,OTP/binary,(byte_size(ERTS)):8,ERTS/binary>>),
    <<11,G:32,0:64>>=recv(S,13),
    Quarantine=[binary:decode_hex(list_to_binary(H))||H<-string:tokens(Q,",")],
    {ok,#{socket=>S,generation=>G,quarantine=>Quarantine,run=>none}}.
handle_call({quarantined,H},_,S)->{reply,lists:member(H,maps:get(quarantine,S)),S};
handle_call(ready,_,S=#{socket:=Socket,generation:=G})->
    send(Socket,2,G,0,<<>>),<<11,G:32,0:64>>=recv(Socket,13),{reply,ok,S};
handle_call({prepare,B,T,Phase,Recipe},_,S=#{socket:=Socket,generation:=G,run:=none})->
    H=crypto:hash(sha256,B),P=phase(Phase),{RecipeStatus,Encoded}=recipe(Recipe),
    send(Socket,3,G,0,<<P:8,T:32,H/binary,(byte_size(B)):32,(byte_size(Encoded)):32,RecipeStatus:8,B/binary,Encoded/binary>>),
    case recv(Socket,45) of
        <<10,G:32,Run:64,H:32/binary>>->{reply,Run,S#{run=>Run}};
        <<12,G:32,0:64>>->halt(0)
    end;
handle_call({result,Run,R},_,S=#{socket:=Socket,generation:=G,run:=Run})->
    Outcome=outcome(maps:get(outcome,R)),Target=outcome(maps:get(target_outcome,R,maps:get(outcome,R))),
    Dirty=case maps:get(runner_reusable,R,true) of true->0;false->1 end,
    Cats=efz_runtime:categories(R),
    Timeout=case {lists:member(timeout_busy,Cats),lists:member(timeout_waiting,Cats),lists:member(timeout_unknown,Cats)} of
        {true,_,_}->1;{_,true,_}->2;{_,_,true}->3;_->0 end,
    send(Socket,4,G,Run,<<Outcome:8,Target:8,Dirty:8,Timeout:8>>),
    <<11,G:32,Run:64>>=recv(Socket,13),{reply,ok,S#{run=>none}};
handle_call({done,Exit},_,S=#{socket:=Socket,generation:=G,run:=none})->
    send(Socket,5,G,0,<<Exit:8>>),<<11,G:32,0:64>>=recv(Socket,13),{reply,ok,S}.
handle_cast(_,S)->{noreply,S}.
handle_info(_,S)->{noreply,S}.
terminate(_,#{socket:=S})->gen_tcp:close(S).
code_change(_,S,_)->{ok,S}.
phase(calibration)->1;phase(mutation)->2;phase(verification)->3;phase(_)->4.
recipe(undefined)->{0,<<>>};
recipe(R)->case efz_recipe:encode(R) of
    {ok,B} when byte_size(B)=<65536->{1,B};_->{2,<<>>} end.
outcome({ok,_})->0;outcome({crash,_,_,_})->1;outcome({exit,_})->2;
outcome({timeout,_})->3;outcome({infrastructure,_})->4.
send(S,T,G,R,B)->Payload= <<T:8,G:32,R:64,B/binary>>,
    ok=gen_tcp:send(S,<<(byte_size(Payload)):32,Payload/binary>>).
recv(S,Limit)->{ok,<<N:32>>}=gen_tcp:recv(S,4,10000),
    true=N>=13 andalso N=<Limit,{ok,B}=gen_tcp:recv(S,N,10000),B.
