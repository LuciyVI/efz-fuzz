%% Integrity evidence lives outside target process dictionaries. This is a
%% correctness guard for the controlled shared-VM backend, not a hostile-code sandbox.
-module(efz_cov_integrity).
-export([identity/1, selected/1, pin/2, validate/1, options/2,
         open/2, admit/2, close/0, expected/0, check/1, fail/2,
         trace_setup/3, trace_event/3, observation/3]).
-define(REGISTRY, efz_coverage_observers).
-define(KEY, '$efz_execution_context').

identity(M) ->
    try erlang:get_module_info(M) of
        Info ->
            Attrs=proplists:get_value(attributes,Info,[]),
            Build=case proplists:get_value(efz_manifest,Attrs) of
                [#{build_id:=B}] -> B; _ -> undefined
            end,
            {ok,#{module=>M,beam_md5=>proplists:get_value(md5,Info),build_id=>Build,
                %% Attributes contain manifest maps; default ETF map ordering
                %% depends on the VM atom table and cannot identify a replay build.
                attributes_sha256=>crypto:hash(sha256,term_to_binary(Attrs,[deterministic])),
                compile=>proplists:get_value(compile,Info,[])}}
    catch error:badarg -> {error,{module_unavailable,M}} end.
selected(Ms) -> selected(Ms,#{}).
selected([],Acc) -> {ok,Acc};
selected([#{module:=M,build_id:=B}|Rest],Acc) ->
    case identity(M) of
        {ok,#{build_id:=B}=I} -> selected(Rest,Acc#{M=>I});
        Other -> {error,{instrumented_identity_mismatch,M,B,Other}}
    end.
pin(M,Selected) ->
    case identity(M) of
        {ok,H} -> {ok,#{harness=>H,modules=>Selected}};
        Error -> Error
    end.
validate(#{harness:=#{module:=M}=H,modules:=Selected}) ->
    validate_list([{M,H}|lists:sort(maps:to_list(Selected))]);
validate(_) -> {error,invalid_execution_identities}.
validate_list([]) -> ok;
validate_list([{M,Expected}|Rest]) ->
    case identity(M) of
        {ok,Expected} -> validate_list(Rest);
        Actual -> {error,#{kind=>module_identity_changed,module=>M,expected=>Expected,actual=>Actual}}
    end.
options(M,#{execution_identities:=Pins}=O) ->
    case Pins of
        #{harness:=#{module:=M}} -> {ok,O};
        _ -> {error,invalid_execution_identities}
    end;
options(M,O) ->
    Selected=case O of
        #{coverage_plan:=Plan} -> efz_cov_manifest:pinned(Plan);
        _ -> selected(maps:get(manifests,O,[]))
    end,
    case Selected of
        %% Preserve the low-level validator's error and observed snapshot for
        %% invalid/dead plans. A valid plan always supplies pinned identities.
        {error,invalid_coverage_plan} -> options_pin(M,#{},O);
        {ok,Is} -> options_pin(M,Is,O);
        Error -> Error
    end.
options_pin(M,Is,O) ->
    case pin(M,Is) of {ok,P}->{ok,O#{execution_identities=>P}};Error->Error end.

open(Context,Pins) ->
    ?REGISTRY=ets:new(?REGISTRY,[named_table,set,protected,{read_concurrency,true}]),
    true=ets:insert(?REGISTRY,{identities,Pins}),
    Context.
admit(Pid,Context) -> true=ets:insert(?REGISTRY,{Pid,Context}),ok.
close() -> ets:delete(?REGISTRY),ok.
expected() ->
    try ets:lookup(?REGISTRY,self()) of [{_,C}]->{ok,C};[]->none
    catch error:badarg->none end.
check(Context) ->
    case get(?KEY) of
        Context -> ok;
        undefined -> fail(Context,detached_coverage_context);
        _ -> fail(Context,invalid_coverage_context)
    end.
-spec fail(tuple(),term()) -> no_return().
fail({efz_context,1,Ref,_,Owner},Why) ->
    Owner!{efz_cov_failure,Ref,Why},
    error({efz_infrastructure,Why}).

trace_setup(Session,Context,#{harness:=#{module:=M},modules:=Selected}) ->
    %% A trace remains observable if erase() is caught, restored, or followed
    %% by kill. Per-process delivered barriers in the guardian drain it.
    1=trace:function(Session,{erlang,erase,0},true,[local]),
    1=trace:function(Session,{erlang,erase,1},[{[?KEY],[],[]}],[local]),
    1=trace:function(Session,{erlang,put,2},[{[?KEY,'_'],[],[]}],[local]),
    %% The OTP 27 code server is the commit path for public code loading APIs,
    %% including already prepared atomic loads. Arity tracing avoids copying
    %% the server state or code blobs into trace messages.
    Mods=lists:usort([M|maps:keys(Selected)]),
    Loads=[{[{load_module,'_',Mod,'_','_','_'},'_','_'],[],[{message,{const,{efz_code_change,Mod}}}]} || Mod<-Mods],
    Deletes=[{[{delete,Mod},'_','_'],[],[{message,{const,{efz_code_change,Mod}}}]} || Mod<-Mods],
    Atomic={[{finish_loading,'$1','_'},'_','_'],[],[{message,{{efz_code_batch,'$1'}}}]},
    1=trace:function(Session,{code_server,handle_call,3},Loads++Deletes++[Atomic],[local]),
    1=trace:process(Session,whereis(code_server),true,[call,arity]),
    %% Direct ERTS commits bypass the public code server. Prepared-code handles
    %% do not expose module identities: conservatively reject such a commit
    %% during a case, including a transient replacement restored before return.
    Direct=[{'_',[{'=/=',{self},{const,whereis(code_server)}}],[]}],
    1=trace:function(Session,{erlang,finish_loading,1},Direct,[meta]),
    lists:foreach(fun(F)->
        {Arity,Tail}=case F of delete_module->{1,[]};finish_after_on_load->{2,['_']} end,
        Patterns=[{[Mod|Tail],[],[]} || Mod<-Mods],
        1=trace:function(Session,{erlang,F,Arity},Patterns,[meta])
    end,[delete_module,finish_after_on_load]),
    Context.

trace_event({trace,Pid,call,{erlang,put,[?KEY,Context]}},Context,Seen) ->
    case maps:get(Pid,Seen,unknown) of controlled->{attached,Pid};_->ignore end;
trace_event({trace,Pid,call,{erlang,put,[?KEY,_]}},_,Seen) ->
    context_event(Pid,invalid_coverage_context,Seen);
trace_event({trace,Pid,call,{erlang,erase,_}},_,Seen) ->
    context_event(Pid,detached_coverage_context,Seen);
trace_event({trace,_,call,{code_server,handle_call,3},{efz_code_change,M}},_,_) ->
    {failed,{module_load_during_execution,M}};
trace_event({trace,_,call,{code_server,handle_call,3},{efz_code_batch,Prepared}},_,_) ->
    [{identities,#{harness:=#{module:=M},modules:=Ms}}]=ets:lookup(?REGISTRY,identities),
    case [Mod || {Mod,_}<-Prepared,Mod=:=M orelse maps:is_key(Mod,Ms)] of
        [] -> ignore;
        Changed -> {failed,{module_load_during_execution,Changed}}
    end;
trace_event({trace_ts,Pid,call,{erlang,finish_loading,_},_},_,_) ->
    {failed,{unsupported_direct_code_loading,Pid}};
trace_event({trace_ts,_,call,{erlang,F,[M|_]},_},_,_)
  when F=:=delete_module;F=:=finish_after_on_load ->
    {failed,{module_load_during_execution,M}};
trace_event(_,_,_) -> ignore.
context_event(Pid,Why,Seen) ->
    case maps:get(Pid,Seen,unknown) of controlled->{failed,Why};_->ignore end.

observation([],ok,[]) ->
    #{classification=>unstarted_coverage_observation,state=>unattached,attached_processes=>[],probe_count=>0};
observation(Hits,ok,Attached) ->
    #{classification=>case Hits of []->valid_empty_coverage;_->observed_coverage end,
      state=>case Hits of []->attached;_->observed end,attached_processes=>Attached,
      probe_count=>length(Hits)};
observation(Hits,{error,Why},Attached) ->
    State=case Why of detached_coverage_context->detached;invalid_coverage_context->invalid;_->failed end,
    #{classification=>broken_coverage_observation,state=>State,reason=>Why,
      attached_processes=>Attached,probe_count=>length(Hits)}.
