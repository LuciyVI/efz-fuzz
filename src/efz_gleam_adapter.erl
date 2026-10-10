%% Checked, explicitly selected semantic plugin. Historical signatures delegate
%% to the isolated QS compatibility interface; operational dispatch is generic.
-module(efz_gleam_adapter).
-export([defaults/0, prepare/2, limits/1, decode/2, encode/2, normalize/2,
    mutate/3, mutate/4, generate/2, observe/3, oracle/3, shrink/2,
    versions/0, capability/0, identity/1, configuration/1, operations/1,
    portable/1, descriptor_valid/1, identity_valid/1]).

defaults() -> efz_qs_legacy:defaults().
versions() -> efz_qs_adapter:versions().
capability() -> efz_qs_adapter:capability().
decode(B,L) -> efz_qs_adapter:decode(B,L).
encode(M,L) -> efz_qs_adapter:encode(M,L).
normalize(M,L) -> efz_qs_adapter:normalize(M,L).
limits(#{adapter_context:=_}=P) -> P;
limits(P) -> efz_qs_legacy:limits(P).
common_defaults() -> #{structured_fraction=>10,feedback=>disabled,oracle=>disabled,
    oracle_budget=>64,adapter_options=>#{},
    limits=>#{bytes=>4096,depth=>8,nodes=>128,collection=>32,operations=>1}}.
prepare(false,C) -> {ok,C};
prepare(Options,C) when is_map(Options),not is_map_key(adapter,Options) ->
    efz_qs_legacy:prepare(Options,C);
prepare(Options,C) when is_map(Options) ->
    try
        require(maps:keys(Options)--[adapter,legacy_qs|maps:keys(common_defaults())]=:=[],unknown_gleam_options),
        P0=maps:merge(common_defaults(),Options),
        L0=maps:get(limits,P0),require(is_map(L0),invalid_gleam_limits),
        require(maps:keys(L0)--maps:keys(maps:get(limits,common_defaults()))=:=[],invalid_gleam_limits),
        L1=maps:merge(maps:get(limits,common_defaults()),L0),
        require(valid_limits(L1),invalid_gleam_limits),
        L=L1#{bytes=>min(maps:get(bytes,L1),maps:get(max_input_bytes,C))},
        F=maps:get(structured_fraction,P0),require(is_integer(F) andalso F>=0 andalso F=<100,invalid_structured_fraction),
        require(lists:member(maps:get(feedback,P0),[disabled,observation_only,guided]),unsupported_gleam_feedback),
        require(lists:member(maps:get(oracle,P0),[disabled,inline]),unsupported_gleam_oracle_policy),
        require(integer(maps:get(oracle_budget,P0),0,10000),invalid_gleam_oracle_budget),
        require(F=:=0 orelse maps:get(mutation_mode,C)=:=staged,structured_requires_staged_mode),
        M=maps:get(adapter,P0),require(is_atom(M),invalid_adapter_module),
        load(M),require_export(M,descriptor,0),require_export(M,prepare,3),
        D=M:descriptor(),require(descriptor_valid(D),invalid_adapter_descriptor),
        lists:foreach(fun({Cap,Fun,Arity})->case has(Cap,D) of
            true->require_export(M,Fun,Arity);false->ok end end,
            [{generation,generate,2},{mutation,mutate,4},{observation,observe,3},{oracle,oracle,3},{shrink,shrink,2}]),
        require(F=:=0 orelse has(mutation,D),missing_mutation_capability),
        require(maps:get(feedback,P0)=:=disabled orelse has(observation,D),missing_observation_capability),
        require(maps:get(oracle,P0)=:=disabled orelse has(oracle,D),missing_oracle_capability),
        lists:foreach(fun load/1,maps:get(model_modules,D)),
        Excluded=[M|maps:get(model_modules,D)],
        require(lists:all(fun(X)->not lists:member(maps:get(module,X),Excluded) andalso not core_module(maps:get(module,X)) end,
            maps:get(manifests,C,[])),invalid_gleam_coverage_selection),
        A=maps:get(adapter_options,P0),require(is_map(A) andalso portable(A),invalid_adapter_options),
        Context=case M:prepare(maps:get(target,C),A,L) of
            {ok,Ctx}->require(portable(Ctx),invalid_adapter_context),Ctx;
            {error,E}->error(E);_->error(invalid_prepare_result) end,
        Deps=case erlang:function_exported(M,code_dependencies,1) of
            false->#{semantic=>[],target=>[]};true->M:code_dependencies(Context) end,
        require(is_map(Deps) andalso lists:sort(maps:keys(Deps))=:=[semantic,target],invalid_code_dependencies),
        lists:foreach(fun(K)->Xs=maps:get(K,Deps),require(is_list(Xs) andalso length(Xs)=<32
            andalso lists:all(fun is_atom/1,Xs),invalid_code_dependencies) end,[semantic,target]),
        require(lists:all(fun(X)->not lists:member(maps:get(module,X),maps:get(semantic,Deps)) end,
            maps:get(manifests,C,[])),invalid_gleam_coverage_selection),
        All=lists:usort(Excluded++maps:get(semantic,Deps)++maps:get(target,Deps)),
        Is=[begin load(X),{ok,I}=efz_replay:harness_identity(X),I end||X<-All],
        DurableD=D#{model_modules=>[atom_to_binary(X,utf8)||X<-maps:get(model_modules,D)],
            properties=>[{property_name(X),V}||{X,V}<-maps:get(properties,D)]},
        OptionBytes=term_to_binary(A,[deterministic]),require(byte_size(OptionBytes)=<65536,adapter_options_size_limit),
        ContextBytes=term_to_binary(Context,[deterministic]),
        require(byte_size(ContextBytes)=<1048576,adapter_context_size_limit),
        Identity=#{descriptor=>DurableD,code=>Is,options=>OptionBytes,limits=>L,
            prepared_context_sha256=>crypto:hash(sha256,ContextBytes)},
        P=P0#{limits=>L,adapter_context=>Context,adapter_descriptor=>D,adapter_identity=>Identity},
        C1=C#{gleam_layer=>P},
        case {maps:get(mutation_mode,C),F} of
            {staged,N} when N>0->MC=(maps:get(mutation,C))#{gleam_layer=>P},
                {ok,C1#{mutation=>MC#{config_id=>efz_mutation_plan:config_identity(MC)}}};
            _->{ok,C1}
        end
    catch Class:Why->{error,{gleam_configuration,bounded_reason(Class,Why)}} end;
prepare(_,_) -> {error,invalid_gleam_configuration}.
require(true,_) -> ok;
require(false,E) -> error(E).
load(M) -> case code:is_loaded(M) of false->case code:ensure_loaded(M) of
    {module,M}->ok;{error,E}->error({adapter_module_unavailable,M,E}) end;_->ok end.
require_export(M,F,A)->require(erlang:function_exported(M,F,A),{adapter_callback_unavailable,M,F,A}).
has(C,D)->lists:member(C,maps:get(capabilities,D)).
integer(N,Min,Max)->is_integer(N) andalso N>=Min andalso N=<Max.
valid_limits(#{bytes:=B,depth:=D,nodes:=N,collection:=C,operations:=1}) ->
    integer(B,0,1048576) andalso integer(D,1,16) andalso integer(N,1,4096) andalso integer(C,1,256);
valid_limits(_) -> false.
descriptor_valid(D) when is_map(D) ->
    try
        true=lists:sort(maps:keys(D))=:=lists:sort([id,api_version,model_version,observer_version,
            recipe_version,operations_version,capabilities,operations,model_modules,properties]),
        Id=maps:get(id,D),true=is_binary(Id) andalso byte_size(Id)>0 andalso byte_size(Id)=<64,
        1=maps:get(api_version,D),
        true=lists:all(fun(K)->integer(maps:get(K,D),1,65535) end,
            [model_version,observer_version,recipe_version,operations_version]),
        Caps=maps:get(capabilities,D),true=is_list(Caps) andalso length(Caps)=<5,
        true=Caps=:=lists:usort(Caps) orelse length(Caps)=:=length(lists:usort(Caps)),
        true=lists:all(fun(C)->lists:member(C,[generation,mutation,observation,oracle,shrink]) end,Caps),
        Ops=maps:get(operations,D),true=is_list(Ops) andalso length(Ops)=<256,
        true=length(Ops)=:=length(lists:usort(Ops)),true=lists:all(fun(O)->integer(O,0,65535) end,Ops),
        true=not lists:member(mutation,Caps) orelse Ops=/=[],
        Ms=maps:get(model_modules,D),true=is_list(Ms) andalso length(Ms)=<32 andalso lists:all(fun is_atom/1,Ms),
        Ps=maps:get(properties,D),true=is_list(Ps) andalso length(Ps)=<32,
        true=lists:all(fun({I,V})->(is_atom(I) orelse (is_binary(I) andalso byte_size(I)>0 andalso byte_size(I)=<64))
            andalso integer(V,1,65535);(_)->false end,Ps),
        true=length(Ps)=:=length(lists:usort([{property_name(I),V}||{I,V}<-Ps])),
        true=not lists:member(oracle,Caps) orelse Ps=/=[],true
    catch _:_ -> false end;
descriptor_valid(_) -> false.
identity(#{adapter_identity:=I}) -> I.
configuration(P) -> maps:with([adapter,adapter_options,limits,structured_fraction,feedback,oracle,oracle_budget,legacy_qs],P).
operations(#{adapter_descriptor:=D}) -> maps:get(operations,D);
operations(_) -> efz_qs_legacy:operations(). %% historical direct provider tests only

mutate(B,O,#{adapter_context:=_}=P) -> mutate(B,O,#{choice=>0},P);
mutate(B,O,L) -> efz_qs_adapter:mutate(B,O,L).
mutate(B,O,Params,#{adapter_descriptor:=D}=P) ->
    case is_binary(B) andalso lists:member(O,maps:get(operations,D)) andalso
        is_map(Params) andalso maps:keys(Params)=:=[choice] andalso integer(maps:get(choice,Params,-1),0,65535) of
        true->invoke(mutation,mutate,[B,O,Params],P);
        false->{error,boundary}
    end.
generate(I,#{adapter_context:=_}=P) when is_integer(I),I>=0,I<4096 -> invoke(generation,generate,[I],P);
generate(I,#{adapter_context:=_}) -> {error,{invalid_generation_index,I}};
generate(I,L) -> efz_qs_adapter:generate(I,L).
observe(B,O,#{adapter_context:=_}=P) -> invoke(observation,observe,[B,O],P);
observe(B,O,L) -> efz_qs_adapter:observe(B,O,L).
oracle(B,O,#{adapter_context:=_}=P) -> invoke(oracle,oracle,[B,O],P);
oracle(B,O,L) -> efz_qs_adapter:oracle(B,O,L).
shrink(B,P) -> invoke(shrink,shrink,[B],P).
invoke(Cap,F,Args,#{adapter:=M,adapter_context:=C,adapter_descriptor:=D,limits:=L}=P) ->
    case has(Cap,D) of
        false->case Cap of oracle->{inconclusive,capability_disabled};_->{skip,capability_disabled} end;
        true->case F=:=generate orelse (is_binary(hd(Args)) andalso byte_size(hd(Args))=<maps:get(bytes,L)) of
            false->{skip,limit};
            true->try validate(F,apply(M,F,Args++[C]),P)
                catch Class:Why->{error,{semantic_layer_error,Class,bounded_reason(Class,Why)}} end
        end
    end.
validate(_, {skip,R},_) when is_atom(R) -> {skip,R};
validate(_, {error,R},_) -> {error,bounded_reason(error,R)};
validate(generate,{ok,B},P) -> require(valid_bytes(B,P),invalid_generated_input),{ok,B};
validate(mutate,{ok,B,R},P) ->
    require(valid_bytes(B,P) andalso is_map(R) andalso portable(R) andalso
        erlang:external_size(R)=<4096,invalid_mutation_result),{ok,B,R};
validate(observe,{ok,Fs},#{adapter_descriptor:=D}) ->
    require(is_list(Fs) andalso length(Fs)=<64 andalso
        lists:all(fun(I)->integer(I,0,255) end,Fs),invalid_observer_result),
    {ok,lists:usort([{maps:get(id,D),maps:get(observer_version,D),I}||I<-Fs])};
validate(oracle,{Verdict,Property},#{adapter_descriptor:=D}) when Verdict=:=pass;Verdict=:=fail ->
    require(lists:member(Property,maps:get(properties,D)),invalid_oracle_property),{Verdict,Property};
validate(oracle,{inconclusive,R},_) when is_atom(R) -> {inconclusive,R};
validate(shrink,{ok,Bs},P) -> require(is_list(Bs) andalso length(Bs)=<64 andalso
    lists:all(fun(B)->valid_bytes(B,P) end,Bs),invalid_shrink_result),{ok,Bs};
validate(_,_,_) -> error(invalid_callback_result).
valid_bytes(B,#{limits:=L})->is_binary(B) andalso byte_size(B)=<maps:get(bytes,L).
bounded_reason(_,R) -> case portable(R) andalso erlang:external_size(R)=<1024 of
    true->R;false->invalid_boundary end.
%% Finite immutable data only, including explicit existing atoms in trusted config.
portable(T) -> try _=data(T,0,8192),true catch _:_ -> false end.
data(_,D,_) when D>24 -> error(depth);
data(_,_,N) when N=<0 -> error(nodes);
data(T,_,N) when is_atom(T);is_integer(T),T>=-(1 bsl 63),T<(1 bsl 64) -> N-1;
data(T,_,N) when is_float(T) -> require(T=:=T andalso abs(T)=<1.7976931348623157e308,nonfinite),N-1;
data(T,_,N) when is_binary(T),byte_size(T)=<1048576 -> N-1;
data(T,D,N) when is_tuple(T),tuple_size(T)=<256 -> data(tuple_to_list(T),D+1,N-1);
data(T,D,N) when is_map(T),map_size(T)=<256 -> data(maps:to_list(T),D+1,N-1);
data([],_,N)->N-1;
data([H|T],D,N)->N1=data(H,D+1,N-1),data(T,D,N1);
data(_,_,_)->error(nonportable).

property_name(X) when is_atom(X)->atom_to_binary(X,utf8);
property_name(X)->X.
identity_valid(#{descriptor:=D,code:=Is,options:=A,limits:=L,prepared_context_sha256:=Ctx}=I) ->
    try
        true=map_size(I)=:=5,true=is_binary(A) andalso byte_size(A)=<65536,
        true=is_binary(Ctx) andalso byte_size(Ctx)=:=32,
        true=valid_limits(L),true=is_list(Is) andalso length(Is)=<97,
        true=lists:all(fun(#{module:=M,beam_md5:=Md5,attributes_sha256:=H,build_id:=B}=X)->
            map_size(X)=:=4 andalso is_binary(M) andalso byte_size(M)>0 andalso byte_size(M)=<255
            andalso is_binary(Md5) andalso byte_size(Md5)=:=16 andalso is_binary(H) andalso byte_size(H)=:=32
            andalso (B=:=undefined orelse (is_binary(B) andalso byte_size(B)=:=32));(_)->false end,Is),
        Ms=maps:get(model_modules,D),true=is_list(Ms) andalso length(Ms)=<32
            andalso lists:all(fun(X)->is_binary(X) andalso byte_size(X)>0 andalso byte_size(X)=<255 end,Ms),
        %% Validate the remaining descriptor without converting names to atoms.
        true=descriptor_valid(D#{model_modules=>[]}),true
    catch _:_ -> false end;
identity_valid(_)->false.

%% Identify engine sources by compile identity, not by a library name allowlist.
%% Example library source directories remain selectable for target coverage.
core_module(M)->
    try
        load(M),Engine=proplists:get_value(source,efz:module_info(compile)),
        Source=proplists:get_value(source,M:module_info(compile)),
        is_list(Source) andalso is_list(Engine) andalso filename:dirname(Source)=:=filename:dirname(Engine)
    catch _:_ -> false end.
