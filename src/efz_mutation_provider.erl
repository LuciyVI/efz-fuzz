%% Mutation sources are separate from semantic interpretation and targets.
%% Only trusted configuration selects code; saved provenance is data only.
-module(efz_mutation_provider).
-export([prepare/2, mutate/3, mutate_session/6, valid_recipe_data/1, operators/0, effective/1]).
-define(MIB,1048576).

operators() -> [byte_flip,byte_insert,byte_drop,block_repeat,block_drop,block_swap,
    line_repeat,line_drop,line_swap,number,delimiter,unicode,json,sgml,base64,
    gzip,zlib,zip,length,xor8,crc32].

prepare(Mode,Max) when Mode=:=native;Mode=:=erlamsa;Mode=:=hybrid -> prepare(#{mode=>Mode},Max);
prepare(O,Max) when is_map(O),is_integer(Max),Max>=0,Max=< ?MIB ->
    try
        known(O,[mode,weights,options,limits,timeout,on_skip,core_path,transport,
                 startup_timeout,cleanup_timeout,max_requests]),
        Mode=maps:get(mode,O,hybrid),
        require(lists:member(Mode,[native,erlamsa,hybrid]),invalid_mode),
        case Mode of
            native -> known(O,[mode]),
                {ok,#{mode=>native,limits=>#{input_bytes=>Max,output_bytes=>Max}}};
            _ -> prepare_enabled(O,Mode,Max)
        end
    catch throw:{configuration,R}->{error,{mutation_provider_configuration,R}};
          error:R->{error,{mutation_provider_configuration,bounded_reason(R)}} end;
prepare(_,_) -> {error,{mutation_provider_configuration,invalid_options}}.

prepare_enabled(O,Mode,Max) ->
    require(Max>0,nonzero_input_limit_required),
    case efz_mutation_request:availability() of
        ok->ok;
        {error,Unavailable}->throw({configuration,Unavailable})
    end,
    Timeout=maps:get(timeout,O,1000),require(integer(Timeout,1,60000),invalid_timeout),
    Transport=maps:get(transport,O,disposable),
    require(lists:member(Transport,[disposable,persistent]),invalid_transport),
    StartupTimeout=maps:get(startup_timeout,O,10000),
    require(integer(StartupTimeout,1,60000),invalid_startup_timeout),
    CleanupTimeout=maps:get(cleanup_timeout,O,3000),
    require(integer(CleanupTimeout,1,30000),invalid_cleanup_timeout),
    MaxRequests=maps:get(max_requests,O,10000),
    require(integer(MaxRequests,1,1000000),invalid_max_requests),
    OnSkip=maps:get(on_skip,O,native),require(lists:member(OnSkip,[native,skip]),invalid_skip_policy),
    Weights=weights(maps:get(weights,O,[{native,70},{erlamsa,30}])),
    CoreOptions=maps:get(options,O,#{}),require(is_map(CoreOptions),invalid_core_options),
    Raw=maps:get(limits,O,#{}),require(is_map(Raw),invalid_limits),known(Raw,maps:keys(default_limits(Max))),
    Limits=maps:merge(default_limits(Max),Raw),require(valid_limits(Limits),invalid_limits),
    require(maps:get(input_bytes,Limits)=<Max andalso maps:get(output_bytes,Limits)=<Max,
        provider_limits_exceed_campaign),
    Path=maps:get(core_path,O,filename:absname("vendor/erlamsa")),
    case efz_erlamsa:prepare(CoreOptions,Limits,Path) of
        {error,R}->throw({configuration,R});
        {ok,Core}->
            C=maps:get(core_context,Core),
            Base=#{mode=>Mode,weights=>Weights,options=>maps:get(options,C),limits=>maps:get(limits,C),
                timeout=>Timeout,on_skip=>OnSkip,core_identity=>maps:get(core_identity,Core)},
            Id=crypto:hash(sha256,term_to_binary(canonical(Base),[deterministic])),
            Runtime=#{transport=>Transport,startup_timeout=>StartupTimeout,
                cleanup_timeout=>CleanupTimeout,max_requests=>MaxRequests},
            {ok,maps:merge(Core,maps:merge(Base#{config_identity=>Id},Runtime))}
    end.

weights(L) when is_list(L),length(L)=<2 ->
    P=lists:foldl(fun
        ({Name,W},A)->require(lists:member(Name,[native,erlamsa]),unknown_source_weight),
            require(not maps:is_key(Name,A),duplicate_source_weight),
            require(integer(W,0,1000000),invalid_source_weight),A#{Name=>W};
        (_,_) -> throw({configuration,invalid_source_weights})
    end,#{},L),
    require(lists:sum(maps:values(P))>0,zero_source_weight_mass),
    [{Name,maps:get(Name,P,0)}||Name<-[native,erlamsa]];
weights(_) -> throw({configuration,invalid_source_weights}).

default_limits(Max)->#{input_bytes=>Max,output_bytes=>Max,intermediate_bytes=>max(65536,Max),
    depth=>4,nodes=>1024,entries=>16,entry_bytes=>16384,unpacked_bytes=>65536,
    expansion_ratio=>32,operations=>8,repeats=>4,block_bytes=>128}.
valid_limits(L) when is_map(L)->
    Keys=maps:keys(default_limits(4096)),
    lists:sort(maps:keys(L))=:=lists:sort(Keys) andalso
        lists:all(fun(K)->integer(maps:get(K,L),1,limit_max(K)) end,Keys);
valid_limits(_)->false.
limit_max(depth)->16;
limit_max(nodes)->8192;
limit_max(entries)->256;
limit_max(expansion_ratio)->1024;
limit_max(operations)->64;
limit_max(repeats)->16;
limit_max(_)->?MIB.

mutate(Input,Request,#{mode:=native,limits:=L})->native(Input,Request,L);
mutate(Input,Request,P=#{mode:=Mode,limits:=L})
  when is_binary(Input),is_map(Request),(Mode=:=erlamsa orelse Mode=:=hybrid)->
    case valid_request(Request) andalso byte_size(Input)=<maps:get(input_bytes,L) of
        false when byte_size(Input)>map_get(input_bytes,L)->{skip,input_limit};
        false->{error,invalid_provider_request};
        true->case Mode=:=hybrid andalso native_selected(Request,P) of
            true->native(Input,Request,L);
            false->validate_result(efz_mutation_request:run(Input,Request,P),Input,L)
        end
    end;
mutate(_,_,_)->{error,invalid_provider_request}.

%% The session handle is runtime-only and must never enter recipes or config.
mutate_session(Input,Request,P,SessionPid,SessionRef,Timeout)
  when is_pid(SessionPid),is_reference(SessionRef),is_binary(Input),is_map(Request),
       is_map(P) ->
    Limits=maps:get(limits,P,#{}),
    InputMax=maps:get(input_bytes,Limits,0),
    case valid_request(Request) andalso byte_size(Input)=<InputMax of
        false when byte_size(Input)>InputMax->{skip,input_limit};
        false->{error,invalid_provider_request};
        true->case efz_mutation_session:run(SessionPid,SessionRef,Input,Request,Timeout) of
            {ok,Result,_Runtime}->validate_result(Result,Input,Limits);
            {error,_}=Error->Error
        end
    end;
mutate_session(_,_,_,_,_,_)->{error,invalid_provider_session}.
native_selected(#{seed:=Seed},#{weights:=W})->
    {N,_}=rand:uniform_s(lists:sum([V||{_,V}<-W]),rand:seed_s(exsplus,Seed)),
    N=<proplists:get_value(native,W,0).
native(Input,Request,L) when is_binary(Input),is_map(Request)->
    case valid_request(Request) andalso byte_size(Input)=<maps:get(input_bytes,L) of
        false->{error,invalid_native_request};
        true when map_get(output_bytes,L)=:=0->{skip,output_limit};
        true->
            R=rand:seed_s(exsplus,maps:get(seed,Request)),
            Op=case Input of
                <<>>->{N,_}=rand:uniform_s(256,R),{insert,0,<<(N-1)>>};
                _->{N,_}=rand:uniform_s(bit_size(Input),R),{flip_bits,N-1,1}
            end,
            C=#{max_input_bytes=>maps:get(output_bytes,L),max_block_bytes=>128,
                max_delta=>8,max_token_bytes=>128},
            case efz_mutation:apply_operation(Input,Op,C) of
                {ok,Out}->{ok,Out,#{source=>native,operation=>Op,seed=>maps:get(seed,Request)}};
                Other->Other
            end
    end;
native(_,_,_)->{error,invalid_native_request}.
validate_result({ok,B,M},Input,L) when is_binary(B),is_map(M)->
    case {B=:=Input,byte_size(B)=<maps:get(output_bytes,L),
        efz_gleam_adapter:portable(M) andalso erlang:external_size(M)=<4096} of
        {true,_,_}->{skip,no_change};
        {_,false,_}->{error,provider_output_limit_violation};
        {_,_,false}->{error,invalid_provider_metadata};
        _->{ok,B,M}
    end;
validate_result({skip,R},_,_) when is_atom(R)->{skip,R};
validate_result({error,R},_,_)->{error,bounded_reason(R)};
validate_result({timeout,R},_,_)->{timeout,bounded_reason(R)};
validate_result(cancelled,_,_)->cancelled;
validate_result(_,_,_)->{error,invalid_provider_result}.

valid_request(R) when is_map(R)->
    (maps:keys(R)--[seed,operator,pattern,strategy,budget])=:=[] andalso
    valid_seed(maps:get(seed,R,undefined)) andalso
    lists:member(maps:get(operator,R,auto),[auto|operators()]) andalso
    valid_pattern(maps:get(pattern,R,auto)) andalso
    lists:member(maps:get(strategy,R,auto),[auto,preserve,perturb,mixed]) andalso
    integer(maps:get(budget,R,1),1,64);
valid_request(_)->false.
valid_seed({A,B,C})->lists:all(fun(N)->integer(N,0,(1 bsl 64)-1) end,[A,B,C]);
valid_seed(_)->false.
valid_pattern(P) when is_atom(P)->lists:member(P,[auto,once,many,burst,skip]);
valid_pattern(P) when is_list(P),length(P)>0,length(P)=<4->
    lists:all(fun(N)->lists:member(N,[once,many,burst,skip]) end,P);
valid_pattern(_)->false.

valid_recipe_data(D) when is_map(D)->
    try
        Keys=[schema_version,wrapper_version,source,mode,identity,config_identity,
            request,request_number,recipe,limits,fallback],
        true=lists:sort(maps:keys(D))=:=lists:sort(Keys),
        1=maps:get(schema_version,D),1=maps:get(wrapper_version,D),
        Source=maps:get(source,D),true=lists:member(Source,[native,erlamsa]),
        true=lists:member(maps:get(mode,D),[erlamsa,hybrid]),
        true=efz_erlamsa:identity_valid(maps:get(identity,D)),
        Id=maps:get(config_identity,D),true=is_binary(Id) andalso byte_size(Id)=:=32,
        true=valid_limits(maps:get(limits,D)),Meta=maps:get(recipe,D),
        true=valid_core_recipe(Meta),
        Request=maps:get(request,D),Number=maps:get(request_number,D),
        case Request of
            none->native=Source,none=Number,true=map_size(Meta)=:=0,none=maps:get(fallback,D);
            _->true=valid_request(Request),true=integer(Number,1,(1 bsl 64)-1),
                true=maps:get(budget,Request,1)=<maps:get(operations,maps:get(limits,D))
        end,
        Fallback=maps:get(fallback,D),
        case Source of
            erlamsa->true=Request=/=none,none=Fallback;
            native->true=map_size(Meta)=:=0,
                true=(is_atom(Fallback) orelse (is_binary(Fallback) andalso byte_size(Fallback)=<256))
        end,
        true=efz_gleam_adapter:portable(D),true=erlang:external_size(D)=<65536,true
    catch _:_ -> false end;
valid_recipe_data(_)->false.

valid_core_recipe(B) when is_binary(B)->byte_size(B)=<4096;
valid_core_recipe(M) when is_map(M)->
    efz_gleam_adapter:portable(M) andalso erlang:external_size(M)=<4096;
valid_core_recipe(_)->false.

effective(native)->#{mode=>native};
effective(P) when is_map(P)->maps:without([core_path,core_context,runtime_modules],P).
known(M,A)->require((maps:keys(M)--A)=:=[],unknown_option).
require(true,_)->ok;
require(false,R)->throw({configuration,R}).
integer(N,Min,Max)->is_integer(N) andalso N>=Min andalso N=<Max.
bounded_reason(R)->case efz_gleam_adapter:portable(R) andalso erlang:external_size(R)=<1024 of
    true->R;false->provider_error end.
canonical(M) when is_map(M)->[{canonical(K),canonical(V)}||{K,V}<-lists:sort(maps:to_list(M))];
canonical(T) when is_tuple(T)->list_to_tuple([canonical(V)||V<-tuple_to_list(T)]);
canonical(L) when is_list(L)->[canonical(V)||V<-L];
canonical(V)->V.
