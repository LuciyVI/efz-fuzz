%% EFZR v1: checksummed, bounded, data-only recipes. Never dispatches artifact code.
-module(efz_recipe).
-export([make/4, regenerate/1, regenerate/2, encode/1, decode/1, save/2, load/1,
         execute/5, execute_file/5, build_ids/1]).
-define(MAX_FILE, 41943040).

make(P,B,C,Builds)->
    P#{schema_version=>1,engine_version=>1,operation_version=>1,
       limits=>maps:with([max_input_bytes,max_block_bytes,max_token_bytes,max_delta],C),
       output_size=>byte_size(B),output_hash=>efz_mutation:hash(B),target_builds=>build_ids(Builds),
       rng=>#{algorithm=>exsplus,seed=>maps:get(seed,C)}}.
build_ids(Bs)->lists:sort([{atom_to_binary(M,utf8),B}||{M,B}<-maps:to_list(Bs)]).
regenerate(R)->
    try regenerate_checked(R)
    catch error:Why->{error,{invalid_recipe,Why}} end.
%% Standalone recipe regeneration uses its recorded campaign limit. A replay
%% in another campaign must also satisfy that campaign's explicit limit.
regenerate(R, #{max_input_bytes:=Max}=Opts) when map_size(Opts)=:=1 ->
    case regenerate(R) of
        {ok,B} ->
            Inputs=[maps:get(primary,R),B] ++ [D || {splice,_,_,D,_} <- maps:get(operations,R)],
            case [E || I <- Inputs,{error,E} <- [efz_input:check(I,Max,recipe_replay)]] of
                [E|_] -> {error,E};
                [] ->
                    Limits=maps:get(limits,R),
                    %% Includes intermediate values in stacked mutations.
                    case efz_mutation:apply_operations(maps:get(primary,R),maps:get(operations,R),
                        Limits#{max_input_bytes=>min(Max,maps:get(max_input_bytes,Limits))}) of
                        {ok,B} -> {ok,B};
                        {error,Why} -> {error,#{kind=>input_limit,operation=>recipe_replay,
                            reason=>Why,max_input_bytes=>Max,input_hash=>crypto:hash(sha256,B)}}
                    end
            end;
        Error -> Error
    end;
regenerate(R, Opts) when is_map(Opts), map_size(Opts)=:=0 ->
    regenerate(R,#{max_input_bytes=>efz_input:default_limit()});
regenerate(_,_) -> {error,unsupported_replay_options}.
regenerate_checked(#{schema_version:=1,engine_version:=1,operation_version:=1,
    primary:=Primary,primary_id:=Id,operations:=Ops,limits:=Limits,output_size:=Size,
    output_hash:=Expected,config_id:=ConfigId,dictionary_id:=DictId,stage:=Stage,
    target_builds:=Bs,rng:=#{algorithm:=exsplus,seed:={A,B,D}},parent:=Parent}=R) ->
    true=lists:sort(maps:keys(R))=:=lists:sort([schema_version,engine_version,operation_version,
        primary,primary_id,operations,limits,output_size,output_hash,config_id,dictionary_id,stage,target_builds,rng,parent]),
    true=is_binary(Primary) andalso byte_size(Primary)=<efz_input:hard_limit(),
    true=is_integer(Size) andalso Size>=0,
    true=is_integer(Parent) andalso Parent>0,
    true=lists:all(fun(X)->is_binary(X) andalso byte_size(X)=:=32 end,[Id,Expected,ConfigId,DictId]),
    true=efz_mutation:hash(Primary)=:=Id,
    true=is_list(Ops) andalso length(Ops)>0 andalso length(Ops)=<32,
    true=lists:member(Stage,maps:get(stages,efz_mutation_plan:defaults())),
    true=lists:all(fun(X)->is_integer(X) andalso X>=0 andalso X<1 bsl 64 end,[A,B,D]),
    true=lists:sort(maps:keys(maps:get(rng,R)))=:=[algorithm,seed],
    true=is_list(Bs) andalso length(Bs)=<4096,
    true=lists:all(fun({M,H})->is_binary(M) andalso byte_size(M)>0 andalso byte_size(M)=<255
        andalso is_binary(H) andalso byte_size(H)=:=32;(_)->false end,Bs),
    true=length(lists:usort([M||{M,_}<-Bs]))=:=length(Bs),
    true=is_map(Limits) andalso lists:sort(maps:keys(Limits))=:=
        lists:sort([max_input_bytes,max_block_bytes,max_token_bytes,max_delta]),
    {ok,C}=efz_mutation_plan:prepare(Limits#{seed=>{A,B,D}},[Primary]),
    true=Size=<maps:get(max_input_bytes,C),
    case efz_mutation:apply_operations(Primary,Ops,C) of
        {ok,Candidate} when byte_size(Candidate)=:=Size ->
            case efz_mutation:hash(Candidate)=:=Expected of
                true->{ok,Candidate};false->{error,output_hash_mismatch}
            end;
        {ok,_}->{error,output_size_mismatch};
        {error,Why}->{error,{recipe_operation,Why}}
    end;
regenerate_checked(_) -> {error,incompatible_recipe}.
encode(R)->
    case regenerate(R) of
        {ok,_}->Payload=term_to_binary(R),
            case byte_size(Payload)+41=< ?MAX_FILE of
                true->{ok,<<"EFZR",1,(byte_size(Payload)):32,(efz_mutation:hash(Payload))/binary,Payload/binary>>};
                false->{error,recipe_size_limit}
            end;
        Error->Error
    end.
decode(B) when is_binary(B),byte_size(B)=< ?MAX_FILE ->
    try
        <<"EFZR",1,N:32,Hash:32/binary,Payload:N/binary>>=B,
        true=efz_mutation:hash(Payload)=:=Hash,
        <<131,Term/binary>>=Payload,
        %% Scan before decoding: reject compression, runtime objects, huge
        %% container declarations, deep nesting and excessive term counts.
        {<<>>,_}=scan(Term,0,20000),
        _=code:ensure_loaded(efz_mutation),_=code:ensure_loaded(efz_mutation_plan),
        R=binary_to_term(Payload,[safe]),
        case regenerate(R) of {ok,_}->{ok,R};Error->Error end
    catch error:_->{error,invalid_recipe_encoding} end;
decode(_) -> {error,recipe_size_limit}.
save(Path,R)->
    case encode(R) of
        {ok,B}->efz_fs:atomic_file(Path,B);
        Error->Error
    end.
load(Path)->case read_bounded(Path,?MAX_FILE) of {ok,B}->decode(B);Error->Error end.
read_bounded(Path,Max)->efz_fs:read_bounded(Path,Max).

%% Target and artifacts are supplied by the caller, never selected by the recipe.
%% Plans are freshly prepared and released; existing handles are not accepted.
execute(Input,Target,Artifacts,ExpectedBuilds,Opts) when is_binary(Input),is_atom(Target),is_map(Opts)->
    case maps:keys(maps:without([timeout,coverage_backend,max_input_bytes,expected_harness],Opts)) of
        []->Timeout=maps:get(timeout,Opts,100),Backend=maps:get(coverage_backend,Opts,ets),
            case is_integer(Timeout) andalso Timeout>=0 andalso lists:member(Backend,[ets,ets_member]) of
                true->Max=maps:get(max_input_bytes,Opts,efz_input:default_limit()),
                    case efz_input:check(Input,Max,replay) of
                        ok->execute_checked(Input,Target,Artifacts,ExpectedBuilds,Timeout,Backend,Max,maps:get(expected_harness,Opts,undefined));
                        Error->Error
                    end;
                false->{error,invalid_replay_options}
            end;
        _->{error,unsupported_replay_options}
    end;
execute(_,_,_,_,_)->{error,invalid_replay_arguments}.
execute_checked(Input,Target,Artifacts,Expected,Timeout,Backend,Max,Harness)->
    case efz_instrument:preflight(Artifacts) of
        {ok,Ms}->Actual=build_ids(maps:from_list([{maps:get(module,M),maps:get(build_id,M)}||M<-Ms])),
            case Actual=:=Expected of
                false->{error,replay_build_mismatch};
                true->_=code:ensure_loaded(Target),
                    case erlang:function_exported(Target,run,1) of
                        false->{error,missing_target_callback};
                        true->case Harness of
                            undefined->{error,missing_expected_harness_identity};
                            _->case efz_replay:pin(Target,Ms,Harness) of
                                {ok,Pins}->{ok,P}=efz_cov_manifest:prepare(automatic,Ms),
                                    try {ok,efz_executor:run(Target,Input,Timeout,#{coverage=>automatic,
                                        coverage_backend=>Backend,coverage_plan=>P,max_input_bytes=>Max,execution_identities=>Pins})}
                                    after efz_cov_manifest:release(P) end;
                                Error->Error
                            end
                        end
                    end
            end;
        Error->Error
    end.
execute_file(Path,Target,Artifacts,Expected,Opts) when is_map(Opts)->
    case efz_input:read_file(Path,maps:get(max_input_bytes,Opts,efz_input:default_limit()),replay) of
        {ok,B}->execute(B,Target,Artifacts,Expected,Opts);Error->Error
    end;
execute_file(_,_,_,_,_)->{error,invalid_replay_arguments}.

scan(_,D,_) when D>24 -> error(recipe_depth);
scan(_,_,Budget) when Budget=<0 -> error(recipe_terms);
scan(<<97,_:8,Rest/binary>>,_,B)->{Rest,B-1};
scan(<<98,_:32,Rest/binary>>,_,B)->{Rest,B-1};
scan(<<110,N:8,S:8,_:N/binary,Rest/binary>>,_,B) when N=<8,S=<1->{Rest,B-1};
scan(<<119,N:8,_:N/binary,Rest/binary>>,_,B) when N=<128->{Rest,B-1};
scan(<<118,N:16,_:N/binary,Rest/binary>>,_,B) when N=<128->{Rest,B-1};
scan(<<100,N:16,_:N/binary,Rest/binary>>,_,B) when N=<128->{Rest,B-1};
scan(<<109,N:32,_:N/binary,Rest/binary>>,_,B) when N=<1048576->{Rest,B-1};
scan(<<107,N:16,_:N/binary,Rest/binary>>,_,B) when N=<4096->{Rest,B-1};
scan(<<106,Rest/binary>>,_,B)->{Rest,B-1};
scan(<<104,N:8,Rest/binary>>,D,B)->scan_n(N,Rest,D+1,B-1);
scan(<<105,N:32,Rest/binary>>,D,B) when N=<64->scan_n(N,Rest,D+1,B-1);
scan(<<108,N:32,Rest/binary>>,D,B) when N=<4096->scan_n(N+1,Rest,D+1,B-1);
scan(<<116,N:32,Rest/binary>>,D,B) when N=<64->scan_n(N*2,Rest,D+1,B-1);
scan(_,_,_)->error(unsupported_recipe_term).
scan_n(0,Rest,_,B)->{Rest,B};
scan_n(N,Data,D,B)->{Rest,B1}=scan(Data,D,B),scan_n(N-1,Rest,D,B1).
