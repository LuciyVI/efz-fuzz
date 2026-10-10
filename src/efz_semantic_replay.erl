%% Replay/minimization of the explicit pure property, through EFZ's executor.
%% Artifact terms never select a target, plugin or callback.
-module(efz_semantic_replay).
-export([expectation/3, encode/1, load/1, run/5, minimize/6]).
expectation(#{execution_identities:=#{harness:=H},builds:=Bs},Meta,Hash)->
    P=maps:get(gleam_layer,Meta),
    Common=#{input_hash=>Hash,
        harness=>(maps:with([beam_md5,attributes_sha256,build_id],H))#{module=>atom_to_binary(maps:get(module,H),utf8)},
        target_builds=>efz_recipe:build_ids(Bs),max_input_bytes=>maps:get(bytes,maps:get(limits,P))},
    case maps:get(legacy_qs,P,false) of
        false->Common#{schema_version=>2,property=>portable_property(maps:get(property,Meta)),
            adapter_identity=>efz_gleam_adapter:identity(P)};
        true->#{schema_version=>1,property=>maps:get(property,Meta),layer_versions=>maps:get(layer_versions,Meta),
        limits=>efz_qs_legacy:provider_limits(efz_gleam_adapter:limits(P)),input_hash=>Hash,
        harness=>(maps:with([beam_md5,attributes_sha256,build_id],H))#{module=>atom_to_binary(maps:get(module,H),utf8)},
        target_builds=>efz_recipe:build_ids(Bs),max_input_bytes=>maps:get(bytes,maps:get(limits,P))}
    end.
encode(E)->P=term_to_binary(E),<<"EFZS",1,(byte_size(P)):32,(crypto:hash(sha256,P))/binary,P/binary>>.
load(Path)->
    case efz_fs:read_bounded(Path,1048576) of
        {ok,B}->try
            <<"EFZS",1,N:32,H:32/binary,P:N/binary>>=B,
            true=crypto:hash(sha256,P)=:=H,<<131,116,_/binary>>=P,
            _=code:ensure_loaded(efz_replay),_=code:ensure_loaded(efz_gleam_adapter),
            E=binary_to_term(P,[safe]),true=valid(E),{ok,E}
        catch error:_->{error,invalid_semantic_expectation} end;
        Error->Error
    end.
valid(#{schema_version:=1}=E)->efz_qs_legacy:valid_expectation(E);
valid(#{schema_version:=2,property:={Id,V},adapter_identity:=I,input_hash:=H,
    max_input_bytes:=Max,harness:=Harness,target_builds:=Bs}=E)->
    map_size(E)=:=7 andalso is_binary(Id) andalso byte_size(Id)>0 andalso byte_size(Id)=<64
    andalso is_integer(V) andalso V>0 andalso V=<65535
    andalso efz_gleam_adapter:identity_valid(I)
    andalso lists:member({Id,V},maps:get(properties,maps:get(descriptor,I)))
    andalso is_binary(H) andalso byte_size(H)=:=32 andalso efz_input:valid_limit(Max)
    andalso valid_harness(Harness) andalso valid_builds(Bs);
valid(_)->false.
portable_property({P,V}) when is_atom(P)->{atom_to_binary(P,utf8),V};
portable_property(P)->P.
run(Input,Target,Artifacts,Expected,Options) ->
    try
        true=whereis(efz_fuzzer)=:=undefined,
        true=valid(Expected),
        true=crypto:hash(sha256,Input)=:=maps:get(input_hash,Expected),
        case replay_context(Input,Target,Artifacts,Expected,Options) of
            {ok,O}->check_input(Input,Target,Artifacts,Expected,O);
            Error->Error
        end
    catch error:_ -> {error,incompatible_semantic_replay} end.
replay_context(_,_,_,#{schema_version:=1}=E,Options)->
    case maps:get(layer_versions,E)=:=efz_gleam_adapter:versions() of
        false->{error,incompatible_semantic_replay};
        true->case efz_gleam_adapter:capability() of
            ok->{ok,Options};{error,Why}->{error,{semantic_replay_capability,Why}} end
    end;
replay_context(Input,Target,Artifacts,#{schema_version:=2}=E,Options)->
    case maps:find(gleam_layer,Options) of
        error->{error,semantic_replay_requires_adapter_configuration};
        {ok,Raw} when is_map(Raw),is_map_key(adapter,Raw)->
            C=#{target=>Target,seeds=>[Input],artifacts=>Artifacts,
                max_input_bytes=>maps:get(max_input_bytes,E),mutation_mode=>random,
                coverage_backend=>maps:get(coverage_backend,Options,ets),
                gleam_layer=>Raw#{structured_fraction=>0,oracle=>inline,feedback=>disabled}},
            case efz_config:prepare(C) of
                {ok,#{gleam_layer:=P}}->case efz_gleam_adapter:identity(P)=:=maps:get(adapter_identity,E) of
                    true->{ok,Options#{semantic_context=>P}};
                    false->{error,semantic_replay_identity_mismatch} end;
                {error,Why}->{error,{semantic_replay_configuration,Why}}
            end;
        _->{error,semantic_replay_requires_explicit_adapter}
    end.
check_input(Input,Target,Artifacts,E,Options)->
    O=(maps:without([minimization_timeout_ms,gleam_layer,semantic_context],Options))#{expected_harness=>maps:get(harness,E)},
    case efz_recipe:execute(Input,Target,Artifacts,maps:get(target_builds,E),O) of
        {ok,#{outcome:={infrastructure,Why}}}->{error,{replay_infrastructure,Why}};
        {ok,#{coverage_status:={error,Why}}}->{error,{replay_coverage,Why}};
        {ok,R}->
            Layer=case maps:get(schema_version,E) of 1->maps:get(limits,E);
                2->maps:get(semantic_context,Options) end,
            Check=efz_gleam_adapter:oracle(Input,maps:get(outcome,R),Layer),
            case Check of
                {fail,P}->case portable_property(legacy_property(P))=:=portable_property(maps:get(property,E)) of
                    true->{ok,#{status=>reproduced,input=>Input,target_executions=>1}};
                    false->{error,semantic_replay_property_mismatch} end;
                {pass,P}->case portable_property(legacy_property(P))=:=portable_property(maps:get(property,E)) of
                    true->{ok,#{status=>not_reproduced,target_executions=>1}};
                    false->{error,semantic_replay_property_mismatch} end;
                {inconclusive,Why}->{ok,#{status=>inconclusive,reason=>Why,target_executions=>1}};
                {error,Why}->{error,{semantic_layer_error,Why}}
            end;
        Error->Error
    end.
legacy_property(P) when is_atom(P)->{P,1};
legacy_property(P)->P.
%% Budgets include initial reproduction and final raw verification. The deadline
%% stops scheduling new calls; each in-flight target still uses EFZ's timeout.
minimize(Input,Target,Artifacts,E,Options,Budget) when is_integer(Budget),Budget>=1,Budget=<10000 ->
    Ms=maps:get(minimization_timeout_ms,Options,30000),
    case is_integer(Ms) andalso Ms>=1 andalso Ms=<300000 of
        false->{error,invalid_minimization_deadline};
        true->
            Start=erlang:monotonic_time(microsecond),Deadline=Start+Ms*1000,
            case prepare_minimization(Input,Target,Artifacts,E,Options) of
                {ok,O} -> case check_input(Input,Target,Artifacts,E,O) of
                {ok,#{status:=reproduced}} ->
                    Left=max(0,Budget-2),
                    State=#{start=>Start,deadline=>Deadline,used=>1,left=>Left,
                        budget=>Budget,original_hash=>crypto:hash(sha256,Input),trace=>[]},
                    minimize_structured(Input,Target,Artifacts,E,O,State);
                Other->Other
            end;
                Error->Error
            end
    end;
minimize(_,_,_,_,_,_)->{error,invalid_minimization_budget}.
prepare_minimization(Input,T,As,E,O)->
    case valid(E) andalso whereis(efz_fuzzer)=:=undefined
        andalso crypto:hash(sha256,Input)=:=maps:get(input_hash,E) of
        true->replay_context(Input,T,As,E,O);false->{error,incompatible_semantic_replay} end.
minimize_structured(B,T,As,E,O,S)->
    case {maps:get(left,S)>0,erlang:monotonic_time(microsecond)<maps:get(deadline,S),maps:find(semantic_context,O)} of
        {true,true,{ok,P}}->case efz_gleam_adapter:shrink(B,P) of
            {ok,Bs}->minimize_candidates([X||X<-Bs,byte_size(X)<byte_size(B)],B,T,As,E,O,S);
            {skip,_}->minimize_bytes(B,0,T,As,E,O,S);
            {error,Why}->{error,{semantic_layer_error,Why}} end;
        _->minimize_bytes(B,0,T,As,E,O,S)
    end.
minimize_candidates([],B,T,As,E,O,S)->minimize_bytes(B,0,T,As,E,O,S);
minimize_candidates([C|Rest],B,T,As,E,O,S)->
    case maps:get(left,S)>0 andalso erlang:monotonic_time(microsecond)<maps:get(deadline,S) of
        false->minimize_bytes(B,0,T,As,E,O,S);
        true->case check_input(C,T,As,E,O) of
            {ok,#{status:=Status}}->Tr=maps:get(trace,S),
                Row=#{kind=>structure,size=>byte_size(C),status=>Status,input_hash=>crypto:hash(sha256,C)},
                S1=S#{left=>maps:get(left,S)-1,used=>maps:get(used,S)+1,
                    trace=>case length(Tr)<128 of true->[Row|Tr];false->Tr end},
                case Status of reproduced->minimize_structured(C,T,As,E,O,S1);
                    _->minimize_candidates(Rest,B,T,As,E,O,S1) end;
            Error->Error end
    end.
minimize_bytes(B,Offset,T,As,E,O,S)->
    Status=case erlang:monotonic_time(microsecond)>=maps:get(deadline,S) of
        true->deadline_exhausted;
        false->case Offset>=byte_size(B) of
            true->minimal_by_single_byte_deletion;
            false->case maps:get(left,S) of 0->budget_exhausted;_->continue end
        end
    end,
    case Status of
        continue->
            <<Prefix:Offset/binary,_,Suffix/binary>>=B,Candidate= <<Prefix/binary,Suffix/binary>>,
            case check_input(Candidate,T,As,E,O) of
                {ok,#{status:=Result}}->
                    Tr=maps:get(trace,S),
                    Row=#{offset=>Offset,size=>byte_size(Candidate),status=>Result,
                        input_hash=>crypto:hash(sha256,Candidate)},
                    S1=S#{left=>maps:get(left,S)-1,used=>maps:get(used,S)+1,
                        trace=>case length(Tr)<128 of true->[Row|Tr];false->Tr end},
                    case Result of
                        reproduced->minimize_bytes(Candidate,0,T,As,E,O,S1);
                        _->minimize_bytes(B,Offset+1,T,As,E,O,S1)
                    end;
                Error->Error
            end;
        _->finish_minimization(B,Status,T,As,E,O,S)
    end.
finish_minimization(B,Status,T,As,E,O,S)->
    Hash=crypto:hash(sha256,B),Expected=E#{input_hash=>Hash},
    CanVerify=maps:get(used,S)<maps:get(budget,S)
        andalso erlang:monotonic_time(microsecond)<maps:get(deadline,S),
    {Verification,Used}=case CanVerify of
        true->{check_input(B,T,As,Expected,O),maps:get(used,S)+1};
        false->{{skipped,case maps:get(used,S)>=maps:get(budget,S) of
            true->budget;false->deadline end},maps:get(used,S)}
    end,
    {ok,#{input=>B,status=>Status,target_executions=>Used,
        original_hash=>maps:get(original_hash,S),minimized_hash=>Hash,
        verification=>Verification,expectation=>Expected,
        trace=>lists:reverse(maps:get(trace,S)),trace_limit=>128,
        trace_dropped=>max(0,maps:get(used,S)-1-128),
        elapsed_us=>erlang:monotonic_time(microsecond)-maps:get(start,S),
        target=>T,artifact_count=>length(As),property=>maps:get(property,E)}}.

valid_harness(#{module:=M,beam_md5:=MD5,attributes_sha256:=A,build_id:=B}=H)->
    map_size(H)=:=4 andalso name(M) andalso hash(MD5,16) andalso hash(A,32)
        andalso (B=:=undefined orelse hash(B,32));
valid_harness(_)->false.
valid_builds(Bs)->is_list(Bs) andalso length(Bs)=<4096 andalso Bs=:=lists:usort(Bs)
    andalso lists:all(fun({M,B})->name(M) andalso hash(B,32);(_)->false end,Bs)
    andalso length(Bs)=:=length(lists:usort([M||{M,_}<-Bs])).
name(B)->is_binary(B) andalso byte_size(B)>0 andalso byte_size(B)=<255.
hash(B,N)->is_binary(B) andalso byte_size(B)=:=N.
