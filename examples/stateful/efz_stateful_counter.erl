%% Test API: unregistered process; no state shared between scenario executions.
-module(efz_stateful_counter).
-behaviour(gen_server).
-export([start_link/0,command/3]).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,code_change/3]).
start_link() -> gen_server:start_link(?MODULE,[],[]).
command(Pid,Name,Value) -> gen_server:call(Pid,{Name,Value},1000).
init([]) -> {ok,0}.
handle_call({get,_},_,State) -> {reply,State,State};
handle_call({put,Value},_,_) -> {reply,Value,Value};
handle_call({add,Value},_,State) -> Next=State+Value,{reply,Next,Next};
handle_call({reset,_},_,_) -> {reply,0,0}.
handle_cast(_,State) -> {noreply,State}.
handle_info(_,State) -> {noreply,State}.
terminate(_,_) -> ok.
code_change(_,State,_) -> {ok,State}.
