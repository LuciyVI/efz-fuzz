%% Compatibility data is separate from raw diagnostic ETF (which may contain
%% arbitrary reasons/runtime objects). Neither artifact selects executable code.
-module(efz_replay).
-export([expectation/5, encode/1, load/1, harness_identity/1, pin/3, run/6, runtime/4]).
-define(MAX_EXPECTATION,2097152).

portable(#{module:=M}=I) -> (maps:with([beam_md5,attributes_sha256,build_id],I))#{module=>atom_to_binary(M,utf8)}.
harness_identity(M) ->
    _=code:ensure_loaded(M),
    case efz_cov_integrity:identity(M) of {ok,I}->{ok,portable(I)};Error->Error end.
pin(Target,Ms,Expected) ->
    case efz_cov_integrity:selected(Ms) of
        {ok,Selected}->case efz_cov_integrity:pin(Target,Selected) of
            {ok,#{harness:=H}=Pins}->case portable(H)=:=Expected of
                true->{ok,Pins};false->{error,replay_harness_mismatch}
            end;
            Error->Error
        end;
        Error->Error
    end.
expectation(#{execution_identities:=#{harness:=H},builds:=Bs},Policy,InputHash,Signature,Max) when map_size(Bs)>0 ->
    #{schema_version=>1,status=>ready,harness=>portable(H),target_builds=>efz_recipe:build_ids(Bs),
      input_hash=>InputHash,signature_id=>Signature,crash_policy=>Policy,max_input_bytes=>Max};
expectation(_,_,_,_,_) -> #{schema_version=>1,status=>unavailable}.
encode(E) ->
    B=term_to_binary(E),<<"EFZX",1,(byte_size(B)):32,(crypto:hash(sha256,B))/binary,B/binary>>.
load(Path) ->
    case efz_fs:read_bounded(Path,?MAX_EXPECTATION) of
        {ok,B}->decode(B);
        Error->Error
    end.
decode(B) ->
    try
        %% Load only the fixed policy schema before safe ETF decoding. A fresh
        %% replay VM need not have used crash storage (or interned its atoms).
        {module,efz_crash}=code:ensure_loaded(efz_crash),
        <<"EFZX",1,N:32,H:32/binary,Payload:N/binary>>=B,
        true=crypto:hash(sha256,Payload)=:=H,
        %% No compressed ETF; no target-derived atoms are needed to decode.
        <<131,116,_/binary>>=Payload,
        E=binary_to_term(Payload,[safe]),true=valid(E),{ok,E}
    catch error:_->{error,invalid_replay_expectation} end.
valid(#{schema_version:=1,status:=unavailable}=E) -> map_size(E)=:=2;
valid(#{schema_version:=1,status:=ready,harness:=H,target_builds:=Bs,input_hash:=I,
        signature_id:=Sig,crash_policy:=P,max_input_bytes:=Max}=E) ->
    map_size(E)=:=8 andalso valid_harness(H) andalso hash(I,32) andalso hash(Sig,32) andalso
    efz_input:valid_limit(Max) andalso efz_crash:prepare(P)=:={ok,P} andalso
    is_list(Bs) andalso length(Bs)>0 andalso length(Bs)=<4096 andalso
    lists:all(fun({M,B})->name(M) andalso hash(B,32);(_)->false end,Bs) andalso
    Bs=:=lists:usort(Bs) andalso length(Bs)=:=length(lists:usort([M||{M,_}<-Bs]));
valid(_) -> false.
valid_harness(#{module:=M,beam_md5:=Md5,attributes_sha256:=A,build_id:=B}=H) ->
    map_size(H)=:=4 andalso name(M) andalso hash(Md5,16) andalso hash(A,32) andalso (B=:=undefined orelse hash(B,32));
valid_harness(_)->false.
name(B)->is_binary(B) andalso byte_size(B)>0 andalso byte_size(B)=<255.
hash(B,N)->is_binary(B) andalso byte_size(B)=:=N.

run(Kind,Path,Target,Artifacts,#{status:=ready}=Expected,Options) ->
    case valid(Expected) of
        false->{error,invalid_replay_expectation};
        true->Max=maps:get(max_input_bytes,Options,maps:get(max_input_bytes,Expected)),
            case input(Kind,Path,Max) of
                {ok,B}->case crypto:hash(sha256,B)=:=maps:get(input_hash,Expected) of
                    false->{error,replay_input_hash_mismatch};
                    true->execute(B,Target,Artifacts,Expected,Options#{max_input_bytes=>Max})
                end;
                Error->Error
            end
    end;
run(_,_,_,_,_,_) -> {error,missing_replay_compatibility}.
input(raw,Path,Max) -> efz_input:read_file(Path,Max,replay);
input(recipe,Path,Max) ->
    case efz_recipe:load(Path) of {ok,R}->efz_recipe:regenerate(R,#{max_input_bytes=>Max});Error->Error end;
input(_,_,_) -> {error,invalid_replay_kind}.
execute(B,Target,Artifacts,E,Options) ->
    case efz_recipe:execute(B,Target,Artifacts,maps:get(target_builds,E),
                          Options#{expected_harness=>maps:get(harness,E)}) of
        {ok,#{outcome:={infrastructure,Why}}=R}->{error,#{kind=>replay_infrastructure,reason=>Why,result=>R,input=>B}};
        {ok,#{coverage_status:={error,Why}}=R}->{error,#{kind=>replay_infrastructure,reason=>Why,result=>R,input=>B}};
        {ok,R}->
            Actual=case maps:get(outcome,R) of
                {ok,_}->none;
                O->element(1,efz_crash:signature(O,maps:get(crash_policy,E)))
            end,
            {ok,#{status=>case Actual=:=maps:get(signature_id,E) of true->reproduced;false->not_reproduced end,
                input_hash=>crypto:hash(sha256,B),expected_signature=>maps:get(signature_id,E),
                actual_signature=>Actual,compatibility=>verified,result=>R}};
        Error->Error
    end.

%% Runtime artifacts use the same pinned executor, with an independent diagnostic policy.
runtime(Path,Target,Artifacts,Options)->efz_runtime_replay:run(Path,Target,Artifacts,Options).
