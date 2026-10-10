%% Standard adapter: argument constraints and a portable term input, no API model.
-module(efz_term_api_adapter).
-behaviour(efz_semantic_adapter).
-export([descriptor/0, prepare/3, generate/2, mutate/4, observe/3, oracle/3,
    shrink/2, execute/2, seed/3,code_dependencies/1]).

descriptor() -> #{id=><<"efz.term_api">>,api_version=>1,model_version=>1,
    observer_version=>1,recipe_version=>1,operations_version=>1,
    capabilities=>[generation,mutation,observation,oracle,shrink],
    operations=>[0,1,2,3,4],model_modules=>[efz_term_model],
    properties=>[{generic_custom_property,1}]}.

prepare(Target,Options,Limits) when is_map(Options),is_map(Limits) ->
    try
        Unknown=maps:keys(maps:without([entrypoint,arguments,property],Options)),
        require(Unknown=:=[],{unknown_term_api_options,Unknown}),
        {M,F,A}=maps:get(entrypoint,Options),
        true=is_atom(M),true=is_atom(F),true=is_integer(A),true=A>=0,
        Specs=maps:get(arguments,Options),
        true=is_list(Specs),true=length(Specs)=:=A,
        L=efz_term_codec:limits(Limits),
        ok=efz_term_codec:validate_specs(Specs,L),
        require(code:ensure_loaded(M)=:={module,M},{entrypoint_module_unavailable,M}),
        require(erlang:function_exported(M,F,A),{entrypoint_unavailable,{M,F,A}}),
        {module,Target}=code:ensure_loaded(Target),
        require(erlang:function_exported(Target,semantic_contract,0),{missing_semantic_contract,Target}),
        Contract=Target:semantic_contract(),
        require(is_map(Contract) andalso maps:get(kind,Contract,undefined)=:=term_api
            andalso maps:get(entrypoint,Contract,undefined)=:={M,F,A}
            andalso maps:get(arguments,Contract,undefined)=:=Specs,
            {term_api_contract_mismatch,Target}),
        InputLimits=harness_input_limits(Contract),
        require(lists:all(fun(K)->maps:get(K,L)=<maps:get(K,InputLimits) end,
            [bytes,depth,nodes,collection]),term_api_input_limits_mismatch),
        Handles=efz_term_codec:resources(Specs),
        require(Handles=:=[] orelse (maps:get(resource_lifetime,Contract,undefined)=:=execution
            andalso is_list(maps:get(resource_handles,Contract,undefined))
            andalso lists:all(fun(H)->lists:member(H,maps:get(resource_handles,Contract)) end,Handles)),
            {resource_harness_required,Handles}),
        ExecutionModules=maps:get(execution_modules,Contract,[]),
        require(is_list(ExecutionModules) andalso length(ExecutionModules)=<31
            andalso lists:all(fun is_atom/1,ExecutionModules),invalid_execution_modules),
        ok=validate_property(maps:get(property,Options,disabled)),
        ok=validate_model(),
        {ok,#{target=>Target,options=>Options,entrypoint=>{M,F,A},specs=>Specs,
            limits=>L,input_limits=>InputLimits,property=>maps:get(property,Options,disabled),
            execution_modules=>ExecutionModules}}
    catch
        throw:{configuration,Why} -> {error,Why};
        error:{badkey,Key} -> {error,{missing_term_api_option,Key}};
        error:{badmatch,{error,Why}} -> {error,Why};
        _:_ -> {error,{invalid_term_api_configuration,Target}}
    end;
prepare(_,_,_) -> {error,invalid_term_api_configuration}.

require(true,_) -> ok;
require(false,Why) -> throw({configuration,Why}).

harness_input_limits(Contract) ->
    Raw=maps:get(input_limits,Contract,#{}),
    require(is_map(Raw),invalid_term_api_input_limits),
    require(maps:keys(Raw)--[bytes,depth,nodes,collection,operations]=:=[],
        invalid_term_api_input_limits),
    L=efz_term_codec:limits(Raw),
    require(valid_input_limits(L),invalid_term_api_input_limits),L.
valid_input_limits(#{bytes:=B,depth:=D,nodes:=N,collection:=C,operations:=1}) ->
    bounded_integer(B,0,1048576) andalso bounded_integer(D,1,16)
        andalso bounded_integer(N,1,4096) andalso bounded_integer(C,1,256);
valid_input_limits(_) -> false.
bounded_integer(N,Min,Max) -> is_integer(N) andalso N>=Min andalso N=<Max.

%% Cold identity declaration. Custom property code is semantic, never measured
%% as target coverage. Harnesses declare unmeasured execution dependencies here.
code_dependencies(#{entrypoint:={M,_,_},property:=P,execution_modules:=Ms}) ->
    Semantic=case P of disabled->[efz_term_codec];
        #{callback:={PM,_}}->lists:usort([efz_term_codec,PM]) end,
    #{semantic=>Semantic,target=>lists:usort([M|Ms])}.

validate_model() ->
    case code:ensure_loaded(efz_term_model) of
        {module,efz_term_model}->
            lists:foreach(fun({F,A})->
                require(erlang:function_exported(efz_term_model,F,A),
                    {term_api_model_callback_unavailable,F,A})
            end,[{scalar,4},{observe,6}]),ok;
        {error,Why}->throw({configuration,{term_api_model_unavailable,Why}})
    end.

validate_property(disabled) -> ok;
validate_property(#{callback:={M,F}}=P) ->
    true=lists:sort(maps:keys(P))=:=[callback],
    true=is_atom(M),true=is_atom(F),
    {module,M}=code:ensure_loaded(M),true=erlang:function_exported(M,F,2),ok.

%% Compatibility helper. New harnesses call the model-free codec directly so
%% raw execution does not require the semantic adapter BEAM on the code path.
execute(Raw,Options) -> efz_term_codec:execute(Raw,Options).

seed(Index,#{arguments:=Specs},Limits) when is_integer(Index),Index>=0 ->
    L=efz_term_codec:limits(Limits),
    try
        {Args,_}=make_many(Specs,Index,1,maps:get(nodes,L),L,[]),
        efz_term_codec:encode(Args,Specs,L)
    catch throw:limit -> {skip,limit} end.
generate(Index,#{options:=Options,limits:=L}) -> seed(Index,Options,L).

make_many([],_,_,Budget,_,Acc) -> {lists:reverse(Acc),Budget};
make_many([S|Rest],I,D,B,L,Acc) ->
    {T,B1}=make(S,I,D,B,L),make_many(Rest,I+1,D,B1,L,[T|Acc]).
make(_,_,D,B,L) when D>map_get(depth,L); B=<0 -> throw(limit);
make(S,I,D,B,L) ->
    K=maps:get(kind,S),
    case K of
        integer ->
            Min=maps:get(min,S,-1000000),Max=maps:get(max,S,1000000),
            V=case I rem 5 of 0->Min;1->Max;2->0;3->1;4->-1 end,
            {clamp(V,Min,Max),B-1};
        float ->
            Min=maps:get(min,S,-1000000.0),Max=maps:get(max,S,1000000.0),
            {clamp(float((I rem 5)-2),Min,Max),B-1};
        boolean -> {I rem 2=:=0,B-1};
        atom -> {pick(maps:get(values,S),I),B-1};
        resource -> {{'$efz_resource',pick(maps:get(values,S),I)},B-1};
        binary -> N=make_length(S,I,L),{binary:copy(<<(I rem 256)>>,N),B-1};
        charlist -> N=make_length(S,I,L),
            case B>N of true->{lists:duplicate(N,32+(I rem 95)),B-N-1};false->throw(limit) end;
        list ->
            N=make_length(S,I,L), make_many(lists:duplicate(N,maps:get(item,S)),I+1,D+1,B-1,L,[]);
        tuple ->
            {Ts,B1}=make_many(maps:get(items,S),I+1,D+1,B-1,L,[]),{list_to_tuple(Ts),B1};
        map -> make_map(make_length(S,I,L),S,I,D,B-1,L,#{},0);
        term ->
            %% Dynamic term trees use only supported finite variants; deep nodes
            %% become scalars and all allocation consumes the shared node budget.
            Choice=case D>=maps:get(depth,L)-1 of true->I rem 4;false->I rem 8 end,
            Next=case Choice of 0->S#{kind=>integer};1->S#{kind=>boolean};
                2->S#{kind=>binary};3->S#{kind=>float};
                4->S#{kind=>list,item=>S};
                5->#{kind=>tuple,items=>[S,S]};
                6->S#{kind=>map,key=>#{kind=>integer},value=>S};
                7->case maps:get(atoms,S,[]) of []->S#{kind=>integer};Vs->#{kind=>atom,values=>Vs} end end,
            make(Next,I+1,D,B,L)
    end.
make_map(0,_,_,_,B,_,M,_) -> {M,B};
make_map(N,S,I,D,B,L,M,Attempts) when Attempts<map_get(collection,L)*2 ->
    {K,B1}=make(maps:get(key,S),I,D+1,B,L),
    {V,B2}=make(maps:get(value,S),I+1,D+1,B1,L),
    case maps:is_key(K,M) of
        true->make_map(N,S,I+2,D,B2,L,M,Attempts+1);
        false->make_map(N-1,S,I+2,D,B2,L,M#{K=>V},Attempts+1)
    end;
make_map(_,_,_,_,_,_,_,_) -> throw(limit).
make_length(S,I,L) ->
    Min=maps:get(min_length,S,0),Max=maps:get(max_length,S,maps:get(collection,L)),
    Min+I rem (min(Max-Min,2)+1).
pick(Xs,I) -> lists:nth(I rem length(Xs)+1,Xs).
clamp(V,Min,Max) -> max(Min,min(Max,V)).

mutate(Raw,Op,#{choice:=Choice},#{specs:=Specs,limits:=L})
    when is_integer(Choice),Choice>=0,Choice=<65535 ->
    case efz_term_codec:decode(Raw,Specs,L) of
        {skip,_}=Skip -> Skip;
        {ok,Args} ->
            Paths=lists:flatmap(fun({T,S,N})->locations(T,S,[{arg,N}]) end,
                zip_args(Args,Specs,1)),
            Candidates=[P||P={_,S,T}<-Paths,operation_applicable(Op,S,T)],
            case Candidates of
                []->{skip,unsupported_operation};
                _ ->
                    {Path,Spec,Old}=pick(Candidates,Choice),
                    try
                        New=change(Op,Old,Spec,Choice,L),
                        Result=replace_args(Args,Path,New),
                        case efz_term_codec:encode(Result,Specs,L) of
                            %% The deterministic choice reconstructs selection;
                            %% do not duplicate input-dependent map keys in recipes.
                            {ok,Bin}->{ok,Bin,#{path=>recipe_path(Path),choice=>Choice}};
                            {skip,_}=Skip->Skip
                        end
                    catch throw:limit->{skip,limit} end
            end
    end;
mutate(_,_,_,_) -> {error,invalid_mutation_params}.

recipe_path(Path) -> [case Step of {map_key,_}->map_key;
    {map_value,_}->map_value;_->Step end||Step<-Path].

zip_args([],[],_) -> [];
zip_args([T|Ts],[S|Ss],N) -> [{T,S,N}|zip_args(Ts,Ss,N+1)].
locations(T,#{kind:=term}=S,Path) -> locations(T,concrete_spec(T,S),Path);
locations(T,S,Path) ->
    Self=[{Path,S,T}],
    Children=case maps:get(kind,S) of
        list -> lists:flatmap(fun({X,N})->locations(X,maps:get(item,S),Path++[{list,N}]) end,
            lists:zip(T,lists:seq(1,length(T))));
        tuple -> lists:flatmap(fun({X,I,N})->locations(X,I,Path++[{tuple,N}]) end,
            zip_args(tuple_to_list(T),maps:get(items,S),1));
        map -> lists:flatmap(fun({K,V})->
            locations(K,maps:get(key,S),Path++[{map_key,K}])++
            locations(V,maps:get(value,S),Path++[{map_value,K}])
        end,lists:sort(maps:to_list(T)));
        _ -> []
    end,
    Self++Children.
concrete_spec(T,S) when is_integer(T) -> S#{kind=>integer};
concrete_spec(T,S) when is_float(T) -> S#{kind=>float};
concrete_spec(T,S) when T=:=true;T=:=false -> S#{kind=>boolean};
concrete_spec(T,S) when is_atom(T) -> #{kind=>atom,values=>maps:get(atoms,S,[])};
concrete_spec(T,S) when is_binary(T) -> S#{kind=>binary};
concrete_spec(T,S) when is_list(T) -> S#{kind=>list,item=>S};
concrete_spec(T,S) when is_tuple(T) -> #{kind=>tuple,items=>lists:duplicate(tuple_size(T),S)};
concrete_spec(T,S) when is_map(T) -> S#{kind=>map,key=>S,value=>S}.

operation_applicable(0,#{kind:=K},_) -> lists:member(K,[integer,float,boolean,binary,charlist,atom]);
operation_applicable(1,#{kind:=K},_) -> lists:member(K,[list,map,binary,charlist]);
operation_applicable(2,#{kind:=K},T) -> case K of list->T=/=[];map->map_size(T)>0;
    binary->byte_size(T)>0;charlist->T=/=[];_->false end;
operation_applicable(3,_,_) -> true;
operation_applicable(4,#{kind:=K},_) -> K=:=list orelse K=:=tuple;
operation_applicable(_,_,_) -> false.

change(0,T,#{kind:=integer}=S,C,_) ->
    %% Optional model modules must remain absent from an ordinary build.
    model(scalar,[T,C,maps:get(min,S,-1000000),maps:get(max,S,1000000)]);
change(0,T,#{kind:=float}=S,C,_) ->
    clamp(T+case C rem 2 of 0->1.0;1->-1.0 end,maps:get(min,S,-1000000.0),maps:get(max,S,1000000.0));
change(0,T,#{kind:=boolean},_,_) -> not T;
change(0,_,#{kind:=atom,values:=Vs},C,_) -> pick(Vs,C);
change(0,T,#{kind:=binary},C,_) -> case T of
    <<>>-><<C:8>>;<<B,Rest/binary>>-><<(B bxor (1 bsl (C rem 8))),Rest/binary>> end;
change(0,T,#{kind:=charlist},C,_) -> case T of []->[C rem 128];[_|R]->[C rem 128|R] end;
change(1,T,#{kind:=list,item:=I},C,L) ->
    {X,_}=make(I,C,1,maps:get(nodes,L),L),T++[X];
change(1,T,#{kind:=map,key:=K,value:=V},C,L) ->
    {Key,B}=make(K,C,1,maps:get(nodes,L),L),{Value,_}=make(V,C+1,1,B,L),T#{Key=>Value};
change(1,T,#{kind:=binary},C,_) -> <<T/binary,C:8>>;
change(1,T,#{kind:=charlist},C,_) -> T++[C rem 128];
change(2,T,#{kind:=list},C,_) -> delete_nth(T,C rem length(T)+1);
change(2,T,#{kind:=charlist},C,_) -> delete_nth(T,C rem length(T)+1);
change(2,T,#{kind:=binary},C,_) ->
    Pos=C rem byte_size(T),<<A:Pos/binary,_,B/binary>>=T,<<A/binary,B/binary>>;
change(2,T,#{kind:=map},C,_) -> {K,_}=pick(lists:sort(maps:to_list(T)),C),maps:remove(K,T);
change(3,_,S,C,L) -> {X,_}=make(S,C,1,maps:get(nodes,L),L),X;
change(4,T,#{kind:=list},_,_) -> lists:reverse(T);
change(4,T,#{kind:=tuple,items:=Is},C,L) -> case Is of []->T;_->
    N=C rem length(Is)+1,{X,_}=make(lists:nth(N,Is),C+1,1,maps:get(nodes,L),L),setelement(N,T,X) end.
delete_nth([_|T],1) -> T;
delete_nth([H|T],N) -> [H|delete_nth(T,N-1)].
replace_args(Args,[{arg,N}|Path],New) -> replace_nth(Args,N,fun(T)->replace(T,Path,New) end).
replace(T,[],New) -> _=T,New;
replace(T,[{list,N}|Path],New) -> replace_nth(T,N,fun(X)->replace(X,Path,New) end);
replace(T,[{tuple,N}|Path],New) -> setelement(N,T,replace(element(N,T),Path,New));
replace(T,[{map_value,K}|Path],New) -> T#{K=>replace(maps:get(K,T),Path,New)};
replace(T,[{map_key,K}|Path],New) ->
    Key=replace(K,Path,New), (maps:remove(K,T))#{Key=>maps:get(K,T)}.
replace_nth([H|T],1,F) -> [F(H)|T];
replace_nth([H|T],N,F) -> [H|replace_nth(T,N-1,F)].

observe(_Raw,Outcome,#{limits:=L}) ->
    {Status,Value}=case Outcome of {ok,{efz_term_input_rejected,_}}->{1,undefined};{ok,V}->{0,V};
        {timeout,_}->{2,undefined};timeout->{2,undefined};
        {crash,_,_,_}->{3,undefined};{exit,_}->{4,undefined};_->{5,undefined} end,
    %% Conventional result tags are features only, never assertions/rejections.
    ResultClass=case Value of {ok,_}->0;{error,_}->1;error->1;_->2 end,
    S=efz_term_codec:summary(Value,L),
    {ok,model(observe,[Status,maps:get(classes,S),maps:get(nodes,S),
        maps:get(depth,S),maps:get(truncated,S),ResultClass])}.

oracle(_,_,#{property:=disabled}) -> {inconclusive,no_property};
oracle(Raw,Outcome,#{property:=#{callback:={M,F}},specs:=Specs,limits:=L}) ->
    case efz_term_codec:decode(Raw,Specs,L) of
        {skip,_}->{inconclusive,unsupported};
        {ok,Args}->case M:F(Args,Outcome) of
            true->{pass,{generic_custom_property,1}};
            false->{fail,{generic_custom_property,1}};
            inconclusive->{inconclusive,custom_property_inconclusive};
            _->{error,invalid_custom_property_result}
        end
    end.

shrink(Raw,#{specs:=Specs,limits:=L}=Context) ->
    case efz_term_codec:decode(Raw,Specs,L) of
        {skip,_}=Skip->Skip;
        {ok,_}->
            Results=[Bin||Op<-[2,3],C<-lists:seq(0,7),
                {ok,Bin,_}<-[mutate(Raw,Op,#{choice=>C},Context)],byte_size(Bin)<byte_size(Raw)],
            {ok,lists:usort(Results)}
    end.

model(F,Args) -> erlang:apply(efz_term_model,F,Args).
