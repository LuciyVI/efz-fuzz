%% Contract v1: checked Erlang terms -> pure compiled Gleam, within this VM.
-module(efz_gleam_adapter).
-export([defaults/0, prepare/2, limits/1, decode/2, encode/2, normalize/2,
         mutate/3, generate/2, observe/3, oracle/3, versions/0, capability/0]).

versions() -> {1,1,1,1,1,1}.
defaults() -> #{structured_fraction=>10,feedback=>disabled,oracle=>disabled,
    oracle_budget=>64,limits=>#{bytes=>4096,fields=>32,component=>128,operations=>1}}.
prepare(false,C) -> {ok,C};
prepare(Options,C) when is_map(Options) ->
    try
        require(maps:keys(Options)--maps:keys(defaults())=:=[],unknown_gleam_options),
        P0=maps:merge(defaults(),Options),
        L0=maps:get(limits,P0), require(is_map(L0),invalid_gleam_limits),
        require(maps:keys(L0)--maps:keys(maps:get(limits,defaults()))=:=[],invalid_gleam_limits),
        L=maps:merge(maps:get(limits,defaults()),L0),
        require(valid_limits(limits(P0#{limits=>L})),invalid_gleam_limits),
        P=P0#{limits=>L#{bytes=>min(maps:get(bytes,L),maps:get(max_input_bytes,C))}},
        require(valid_limits(limits(P)),invalid_gleam_limits),
        F=maps:get(structured_fraction,P),require(is_integer(F) andalso F>=0 andalso F=<100,invalid_structured_fraction),
        require(lists:member(maps:get(feedback,P),[disabled,observation_only,guided]),unsupported_gleam_feedback),
        require(lists:member(maps:get(oracle,P),[disabled,inline]),unsupported_gleam_oracle_policy),
        B=maps:get(oracle_budget,P),require(is_integer(B) andalso B>=0 andalso B=<10000,invalid_gleam_oracle_budget),
        require(F=:=0 orelse maps:get(mutation_mode,C)=:=staged,structured_requires_staged_mode),
        require(lists:member(maps:get(target,C),[efz_qs_target,efz_qs_defect_target]),unsupported_gleam_target),
        %% Coverage selection must never include helpers/observer/oracle.
        require(lists:all(fun(M)->maps:get(module,M)=:=cow_qs end,maps:get(manifests,C)),invalid_gleam_coverage_selection),
        case capability() of ok->ok;{error,CapabilityWhy}->error(CapabilityWhy) end,
        MC=case maps:get(mutation_mode,C) of
            staged when F>0 -> WithProvider=(maps:get(mutation,C))#{gleam_layer=>P},
                WithProvider#{config_id=>efz_mutation_plan:config_identity(WithProvider)};
            _ -> maps:get(mutation,C,undefined)
        end,
        C1=C#{gleam_layer=>P},
        {ok,case MC of undefined->C1;_->C1#{mutation=>MC} end}
    catch error:Why -> {error,{gleam_configuration,reason(Why)}} end;
prepare(_,_) -> {error,invalid_gleam_configuration}.
%% Cold/startup only; ordinary raw replay and runtime-off never call this.
capability() ->
    try
        case code:ensure_loaded(efz_qs_model) of
            {module,efz_qs_model}->ok;
            {error,LoadWhy}->error({gleam_package_unavailable,LoadWhy})
        end,
        require_export(versions,0),
        require(call(versions,[])=:=versions(),incompatible_gleam_versions),
        lists:foreach(fun({F,A})->require_export(F,A) end,
            [{decode,2},{encode,2},{normalize,1},{generate,2},{mutate,3},{observe,4},{check,2}]),
        ok
    catch error:Why->{error,reason(Why)} end.
require(true,_) -> ok;
require(false,Why) -> error(Why).
require_export(F,A) ->
    case erlang:function_exported(efz_qs_model,F,A) of
        true->ok;false->error({gleam_callback_unavailable,F,A})
    end.
limits(#{limits:=#{bytes:=B,fields:=F,component:=C,operations:=O}}) -> {limits,B,F,C,O}.
valid_limits({limits,B,F,C,1}) -> is_integer(B) andalso B>=0 andalso B=<4096
    andalso is_integer(F) andalso F>=1 andalso F=<32
    andalso is_integer(C) andalso C>=1 andalso C=<128;
valid_limits(_) -> false.
valid_bytes(B,{limits,Max,_,_,_}=L) -> valid_limits(L) andalso is_binary(B) andalso byte_size(B)=<Max.
valid_model({query,Fs,Wire},{limits,_,N,C,_}) ->
    lists:member(Wire,[canonical,bad_escape]) andalso fields(Fs,N,C);
valid_model(_,_) -> false.
fields([],_,_) -> true;
fields([{field,K,V}|Rest],N,C) when N>0,is_binary(K),byte_size(K)>0,byte_size(K)=<C,
                                  is_binary(V),byte_size(V)=<C -> fields(Rest,N-1,C);
fields(_,_,_) -> false.
decode(B,L) ->
    case valid_limits(L) of
        false -> {error,boundary};
        true -> case valid_bytes(B,L) of
        false when is_binary(B) -> {skip,limit};
        false -> {error,boundary};
        true -> checked(decode,[B,L],fun(M)->valid_model(M,L) andalso element(3,M)=:=canonical end)
        end
    end.
encode(M,L) ->
    case valid_limits(L) andalso valid_model(M,L) of
        true -> checked(encode,[M,L],fun(B)->valid_bytes(B,L) end);
        false -> {error,boundary}
    end.
normalize(M,L) ->
    case valid_limits(L) andalso valid_model(M,L) of
        true -> protect(fun()->N=call(normalize,[M]),true=valid_model(N,L),{ok,N} end);
        false -> {error,boundary}
    end.
mutate(B,Op,L) when is_integer(Op),Op>=0,Op<6 ->
    case decode(B,L) of
        {ok,M} -> case checked(mutate,[M,Op,L],fun(N)->valid_model(N,L) end) of
            {ok,N} -> case encode(N,L) of
                {ok,Out}->{ok,Out,#{schema_version=>1,versions=>versions(),operation=>Op}};
                E -> E
            end;
            E -> E
        end;
        E -> E
    end;
mutate(_,_,_) -> {error,boundary}.
generate(I,L) when is_integer(I),I>=0,I<4096 ->
    case valid_limits(L) of
        true -> checked(generate,[I,L],fun(B)->valid_bytes(B,L) end);
        false -> {error,boundary}
    end;
generate(_,_) -> {error,boundary}.

%% This observer never decodes the input. Parser outputs are bounded by the
%% fixed harness and checked again here before crossing the typed boundary.
observe(B,_,{limits,Max,_,_,_}) when is_binary(B),byte_size(B)>Max -> {skip,limit};
observe(B,Outcome,L) -> protect(fun()->
    true=valid_bytes(B,L),
    {Status,Count,Empty,NonAscii}=summary(Outcome),
    Fs=call(observe,[Status,Count,Empty,NonAscii]),
    true=features(Fs,4),
    {ok,lists:usort([{<<"cow_qs">>,1,I}||I<-Fs])}
end).
summary({ok,{accepted,Pairs}}) -> pair_summary(Pairs,0,false,false);
summary({ok,rejected}) -> {1,0,false,false};
summary({timeout,_}) -> {2,0,false,false};
summary({crash,_,_,_}) -> {3,0,false,false};
summary({exit,_}) -> {3,0,false,false};
summary(_) -> error(invalid_target_outcome).
pair_summary([],N,E,B) -> {0,N,E,B};
pair_summary([{K,V}|Rest],N,E,B) when N<100,is_binary(K),byte_size(K)=<4096,
                                    is_binary(V),byte_size(V)=<4096 ->
    pair_summary(Rest,N+1,E orelse V=:=<<>>,B orelse non_ascii(K) orelse non_ascii(V));
pair_summary([{K,true}|Rest],N,E,B) when N<100,is_binary(K),byte_size(K)=<4096 ->
    pair_summary(Rest,N+1,E,B orelse non_ascii(K));
pair_summary(_,_,_,_) -> error(invalid_parser_result).
non_ascii(B) -> non_ascii_bytes(B).
non_ascii_bytes(<<>>) -> false;
non_ascii_bytes(<<B,_/binary>>) when B>=128 -> true;
non_ascii_bytes(<<_,Rest/binary>>) -> non_ascii_bytes(Rest).
features([],_) -> true;
features([I|Rest],N) when N>0,is_integer(I),I>=0,I<12 -> features(Rest,N-1);
features(_,_) -> false.

oracle(B,Outcome,L) ->
    case decode(B,L) of
        {ok,M} -> oracle_model(M,Outcome,L);
        {skip,Why} -> {inconclusive,Why};
        E -> E
    end.
oracle_model(_, {timeout,_},_) -> {inconclusive,target_timeout};
oracle_model(_, {crash,_,_,_},_) -> {inconclusive,target_exception};
oracle_model(_, {exit,_},_) -> {inconclusive,target_exception};
oracle_model(M,{ok,{accepted,Pairs}},L) -> protect(fun()->
    _=summary({ok,{accepted,Pairs}}),
    case actual_fields(Pairs,L,[]) of
        {ok,Actual}->case call(check,[M,Actual]) of true->{pass,query_model_agreement};
            false->{fail,query_model_agreement};_ -> error(invalid_oracle_result) end;
        unsupported->{fail,query_model_agreement}
    end
end);
oracle_model(_,{ok,rejected},_) -> {fail,query_model_agreement};
oracle_model(_,_,_) -> {error,invalid_target_outcome}.
actual_fields([],_,Acc)->{ok,lists:reverse(Acc)};
actual_fields([{K,V}|Rest],{limits,B,N,C,O},Acc) when N>0,is_binary(K),byte_size(K)>0,
  byte_size(K)=<C,is_binary(V),byte_size(V)=<C -> actual_fields(Rest,{limits,B,N-1,C,O},[{field,K,V}|Acc]);
actual_fields(_,_,_)->unsupported.
checked(F,Args,Validate) -> protect(fun()->
    case call(F,Args) of
        {ok,V} -> true=Validate(V),{ok,V};
        {error,unsupported} -> {skip,unsupported};
        {error,limit} -> {skip,limit};
        _ -> error(invalid_callback_result)
    end
end).
call(F,Args) -> apply(efz_qs_model,F,Args).
protect(F) -> try F() catch Class:Why -> {error,{semantic_layer_error,Class,reason(Why)}} end.
reason(A) when is_atom(A) -> A;
reason({badmatch,_}) -> badmatch;
reason({badkey,K}) when is_atom(K) -> {badkey,K};
reason({semantic_layer_error,C,R}) when (C=:=error orelse C=:=exit orelse C=:=throw),
                                      is_atom(R) -> {semantic_layer_error,C,R};
reason({gleam_package_unavailable,R}) when is_atom(R)->{gleam_package_unavailable,R};
reason({gleam_callback_unavailable,F,A}) when is_atom(F),is_integer(A),A>=0,A=<4->
    {gleam_callback_unavailable,F,A};
reason(_) -> invalid_boundary.
