%% Ordinary source instrumented by the regression suite. Descendant creation
%% uses the public lifecycle API; no manually generated coverage observations.
-module(efz_isolation_target).
-export([run/1]).

run(B) when is_binary(B) ->
    announce(root),
    case B of
        <<>> -> ok;
        <<"normal">> -> ok;
        <<"crash">> -> error(isolation_crash);
        <<"timeout">> -> wait();
        <<"trap_exit">> -> process_flag(trap_exit,true),wait();
        <<"linked">> -> child(true,0),ok;
        <<"unlinked">> -> child(false,0),ok;
        <<"nested">> -> child(false,2),ok;
        <<"hold">> -> child(true,1),ready(),wait();
        <<"dirty_hold">> -> persistent_term:put({?MODULE,dirty},true),child(true,1),ready(),wait();
        <<"timeout_spawn">> ->
            Parent=self(),
            efz_target:spawn(fun()->announce(spawner),Parent!spawner_ready,spawn_loop() end),
            receive spawner_ready->ok end,ready(),wait();
        <<"resources">> ->
            true=register(efz_isolation_root,self()),
            T=ets:new(efz_isolation_owned,[named_table,public]),ets:insert(T,{value,dirty}),
            put(isolation_dirty,true),self()!old_message,
            Parent=self(),efz_target:spawn(fun()->
                true=register(efz_isolation_child,self()),
                ets:new(efz_isolation_child_table,[named_table,public]),
                announce(registered_child),Parent!registered_ready,wait()
            end),receive registered_ready->ok end,ok;
        <<"A">> -> {persistent_term:get({?MODULE,dirty},false),
                     application:get_env(efz,isolation_dirty,false),
                     ets:lookup(efz_isolation_shared,value),get(isolation_dirty),
                     receive old_message->dirty_mailbox after 0->clean_mailbox end};
        <<"dirty_persistent">> -> persistent_term:put({?MODULE,dirty},true),ok;
        <<"dirty_env">> -> application:set_env(efz,isolation_dirty,true);
        <<"dirty_ets">> -> efz_target:dirty(shared_ets_write),ets:insert(efz_isolation_shared,{value,dirty}),ok;
        <<"escaped_ets">> ->
            Owner=whereis(efz_isolation_observer),
            ets:new(escaped,[public,{heir,Owner,escaped}]),ok;
        <<"escaped_name">> -> register(efz_isolation_escaped,persistent_term:get({?MODULE,external})),ok;
        <<"raw_spawn">> -> spawn(fun()->announce(raw_child),wait() end),ok;
        <<"raw_nested">> -> spawn(fun()->spawn(fun()->announce(raw_grandchild),wait() end),wait() end),wait()
    end.
child(Linked,Depth) ->
    Parent=self(),F=fun()->
        process_flag(trap_exit,true),announce({child,Depth}),
        case Depth of 0->ok;_->child(false,Depth-1) end,
        Parent!{child_ready,self()},wait()
    end,
    P=case Linked of true->efz_target:spawn_link(F);false->efz_target:spawn(F) end,
    receive {child_ready,P}->P end.
spawn_loop() -> child(false,0),receive after 1->spawn_loop() end.
announce(Label) ->
    {efz_context,1,Ref,_,Guardian}=get('$efz_execution_context'),
    whereis(efz_isolation_observer)!{owned,Label,self(),Guardian,Ref}.
ready() -> whereis(efz_isolation_observer)!{tree_ready,self()}.
wait() -> receive never->ok end.
