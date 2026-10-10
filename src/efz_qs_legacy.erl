%% Historical QS-only configuration and signatures, never used to admit plugins.
-module(efz_qs_legacy).
-export([defaults/0, prepare/2, limits/1, provider_limits/1, operations/0, valid_features/1, metadata/1, features/1, compatible_target/1, valid_expectation/1, outcome_counters/2]).
defaults() -> #{structured_fraction=>10,feedback=>disabled,oracle=>disabled,
    oracle_budget=>64,limits=>#{bytes=>4096,fields=>32,component=>128,operations=>1}}.
limits(#{limits:=#{bytes:=B,fields:=F,component:=C,operations:=O}}) -> {limits,B,F,C,O}.
prepare(false,C) -> {ok,C};
prepare(Options,C) when is_map(Options) ->
    try
        true=maps:keys(Options)--maps:keys(defaults())=:=[],
        P=maps:merge(defaults(),Options),
        L0=maps:get(limits,P),true=is_map(L0),
        true=maps:keys(L0)--maps:keys(maps:get(limits,defaults()))=:=[],
        L=maps:merge(maps:get(limits,defaults()),L0),
        case maps:get(oracle,P) of disabled->ok;inline->ok;_->error(unsupported_gleam_oracle_policy) end,
        case maps:get(structured_fraction,P) of
            F when is_integer(F),F>=0,F=<100->case F>0 andalso maps:get(mutation_mode,C)=/=staged of
                true->error(structured_requires_staged_mode);false->ok end;
            _->error(invalid_structured_fraction) end,
        %% Only historical targets have the implicit default. Explicit adapters
        %% validate harness metadata themselves and never consult this list.
        case lists:member(maps:get(target,C),[efz_qs_target,efz_qs_defect_target]) of
            false->{error,{gleam_configuration,unsupported_gleam_target}};
            true->Result=efz_gleam_adapter:prepare(P#{adapter=>efz_qs_adapter,
                adapter_options=>(maps:with([fields,component],L))#{legacy_contract=>true},legacy_qs=>true,
                limits=>maps:without([fields,component],L)},C),
                case Result of
                    {error,{gleam_configuration,{adapter_module_unavailable,efz_qs_model,E}}}->
                        {error,{gleam_configuration,{gleam_package_unavailable,E}}};
                    _->Result end
        end
    catch error:Why when Why=:=unsupported_gleam_oracle_policy;Why=:=structured_requires_staged_mode;
                           Why=:=invalid_structured_fraction ->{error,{gleam_configuration,Why}};
          error:_->{error,{gleam_configuration,invalid_gleam_limits}} end;
prepare(_,_) -> {error,invalid_gleam_configuration}.

provider_limits(#{adapter_context:=#{qs_limits:=L}})->L;
provider_limits(L)->L.
operations()->lists:seq(0,5).

%% Only the historical configuration assigned meaning to a bare rejected atom.
%% New plugins observe their own outcome contract through finite local features.
outcome_counters(#{legacy_qs:=true},{ok,rejected})->[expected_rejections];
outcome_counters(_,_)->[].

valid_features(Fs)->
    case lists:all(fun({Id,V,_})->Id=:=<<"cow_qs">> andalso V=:=1;(_)->false end,Fs) of
        false->true;
        true->length(Fs)=<12 andalso lists:all(fun({_,_,I})->is_integer(I) andalso I>=0 andalso I<12 end,Fs)
    end.
metadata(Fs)->
    case lists:all(fun({Id,V,_})->Id=:=<<"cow_qs">> andalso V=:=1 end,Fs) of
        true->{ok,#{schema_version=>1,namespace=><<"cow_qs">>,feature_version=>1,features=>lists:usort(Fs)}};
        false->not_legacy
    end.
features(#{schema_version:=1,namespace:=<<"cow_qs">>,feature_version:=1,features:=Fs}=M)->
    case map_size(M)=:=4 andalso is_list(Fs) andalso length(Fs)=<12 andalso
        lists:all(fun({<<"cow_qs">>,1,I})->is_integer(I) andalso I>=0 andalso I<12;(_)->false end,Fs)
        andalso Fs=:=lists:usort(Fs) of true->Fs;false->error(invalid_semantic_metadata) end;
features(_)->error(incompatible_semantic_schema).

compatible_target(T)->lists:member(T,[efz_qs_target,efz_qs_defect_target]).

valid_expectation(#{schema_version:=1,property:={query_model_agreement,1},layer_versions:={1,1,1,1,1,1},
    input_hash:=H,limits:={limits,B,F,C,1},max_input_bytes:=Max,harness:=Harness,target_builds:=Bs}=E)->
    map_size(E)=:=8 andalso is_binary(H) andalso byte_size(H)=:=32
    andalso is_integer(B) andalso B>=0 andalso B=<4096 andalso is_integer(F) andalso F>=1 andalso F=<32
    andalso is_integer(C) andalso C>=1 andalso C=<128 andalso efz_input:valid_limit(Max)
    andalso is_map(Harness) andalso map_size(Harness)=:=4 andalso is_list(Bs) andalso length(Bs)=<4096;
valid_expectation(_)->false.
