%% A scenario is one primary EFZ execution; it contains bounded API operations.
-module(efz_stateful_target).
-export([run/1,options/0,semantic_contract/0,scenario/1,property/2]).
options() -> #{entrypoint=>{?MODULE,scenario,1},arguments=>[
    #{kind=>list,max_length=>16,item=>#{kind=>tuple,items=>[
        #{kind=>resource,values=>[counter]},
        #{kind=>atom,values=>[get,put,add,reset]},
        #{kind=>integer,min=>-1000,max=>1000}]}}]}.
semantic_contract() -> (options())#{kind=>term_api,
    resource_lifetime=>execution,resource_handles=>[counter],
    execution_modules=>[efz_stateful_counter]}.
run(Raw) -> efz_term_codec:execute(Raw,options()).
scenario(Commands) ->
    {ok,Pid}=start_counter(),
    try
        %% Symbolic handle resolution happens here, never in the portable codec.
        Trace=[efz_stateful_counter:command(resolve(Handle,Pid),Name,Value)
            ||{Handle,Name,Value}<-Commands],
        #{scenario_executions=>1,library_operations=>length(Commands),trace=>Trace}
    after
        %% No registration, global state, persistence or process literals in input.
        case catch gen_server:stop(Pid,normal,1000) of
            ok->ok;_->exit(Pid,kill)
        end
    end.

%% EFZ owns descendant admission. The ordinary gen_server starter performs an
%% uncontrolled spawn, so this OTP-27 fixture bridges an admitted child into
%% public gen_server:enter_loop/3. The two dictionary entries below are proc_lib
%% metadata required by gen:get_parent/0 and diagnostics; this is deliberately
%% documented as an OTP-version-specific harness bootstrap, not a core engine.
start_counter() ->
    Parent=self(),Tag=make_ref(),
    try
        Pid=efz_target:spawn_link(fun()->
            _=process_flag(trap_exit,true),
            _=put('$ancestors',[Parent]),
            _=put('$initial_call',{efz_stateful_counter,init,1}),
            {ok,Initial}=efz_stateful_counter:init([]),
            Parent!{counter_ready,Tag,self()},
            gen_server:enter_loop(efz_stateful_counter,[],Initial)
        end),
        receive {counter_ready,Tag,Pid}->{ok,Pid}
        after 1000->exit(Pid,kill),error(counter_setup_timeout) end
    catch
        %% No child was spawned: efz_target rejected the missing execution owner.
        error:{efz_infrastructure,no_execution_owner}->efz_stateful_counter:start_link()
    end.
resolve({'$efz_resource',counter},Pid) -> Pid.

%% Explicit user-selected property. It reads the existing outcome only.
property([Commands],{ok,#{trace:=Actual,library_operations:=N}}) ->
    {Expected,_}=lists:mapfoldl(fun({{'$efz_resource',counter},Name,Value},State)->
        Next=case Name of get->State;put->Value;add->State+Value;reset->0 end,
        {Next,Next}
    end,0,Commands),
    Actual=:=Expected andalso N=:=length(Commands);
property(_,_) -> inconclusive.
