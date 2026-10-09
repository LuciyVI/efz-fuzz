%% Replay/minimization of the explicit pure property, through EFZ's executor.
%% Artifact terms never select a target, plugin or callback.
-module(efz_semantic_replay).
-export([expectation/3, encode/1, load/1, run/5, minimize/6]).
expectation(#{execution_identities:=#{harness:=H},builds:=Bs},Meta,Hash)->
    #{schema_version=>1,property=>maps:get(property,Meta),layer_versions=>maps:get(layer_versions,Meta),
        limits=>efz_gleam_adapter:limits(maps:get(gleam_layer,Meta)),input_hash=>Hash,
        harness=>(maps:with([beam_md5,attributes_sha256,build_id],H))#{module=>atom_to_binary(maps:get(module,H),utf8)},
        target_builds=>efz_recipe:build_ids(Bs),max_input_bytes=>maps:get(bytes,maps:get(limits,maps:get(gleam_layer,Meta)))}.
encode(E)->P=term_to_binary(E),<<"EFZS",1,(byte_size(P)):32,(crypto:hash(sha256,P))/binary,P/binary>>.
load(Path)->
    case efz_fs:read_bounded(Path,65536) of
        {ok,B}->try
            <<"EFZS",1,N:32,H:32/binary,P:N/binary>>=B,
            true=crypto:hash(sha256,P)=:=H,<<131,116,_/binary>>=P,
            _=code:ensure_loaded(efz_replay),E=binary_to_term(P,[safe]),true=valid(E),{ok,E}
        catch error:_->{error,invalid_semantic_expectation} end;
        Error->Error
    end.
valid(#{schema_version:=1,property:={query_model_agreement,1},layer_versions:={1,1,1,1,1,1},
    input_hash:=H,limits:={limits,B,F,C,1},max_input_bytes:=Max,harness:=Harness,target_builds:=Bs}=E)->
    map_size(E)=:=8 andalso is_binary(H) andalso byte_size(H)=:=32
    andalso is_integer(B) andalso B>=0 andalso B=<4096 andalso is_integer(F) andalso F>=1 andalso F=<32
    andalso is_integer(C) andalso C>=1 andalso C=<128 andalso efz_input:valid_limit(Max)
    andalso is_map(Harness) andalso map_size(Harness)=:=4 andalso is_list(Bs) andalso length(Bs)=<4096;
valid(_)->false.
run(Input,Target,Artifacts,Expected,Options) ->
    try
        true=whereis(efz_fuzzer)=:=undefined,
        true=valid(Expected),
        {Property,1}=maps:get(property,Expected),true=Property=:=query_model_agreement,
        true=maps:get(layer_versions,Expected)=:=efz_gleam_adapter:versions(),
        true=crypto:hash(sha256,Input)=:=maps:get(input_hash,Expected),
        case efz_gleam_adapter:capability() of
            ok->check_input(Input,Target,Artifacts,Expected,Options);
            {error,Why}->{error,{semantic_replay_capability,Why}}
        end
    catch error:_ -> {error,incompatible_semantic_replay} end.
check_input(Input,Target,Artifacts,E,Options)->
    O=(maps:remove(minimization_timeout_ms,Options))#{expected_harness=>maps:get(harness,E)},
    case efz_recipe:execute(Input,Target,Artifacts,maps:get(target_builds,E),O) of
        {ok,#{outcome:={infrastructure,Why}}}->{error,{replay_infrastructure,Why}};
        {ok,#{coverage_status:={error,Why}}}->{error,{replay_coverage,Why}};
        {ok,R}->
            case efz_gleam_adapter:oracle(Input,maps:get(outcome,R),maps:get(limits,E)) of
                {fail,query_model_agreement}->{ok,#{status=>reproduced,input=>Input,target_executions=>1}};
                {pass,_}->{ok,#{status=>not_reproduced,target_executions=>1}};
                {inconclusive,Why}->{ok,#{status=>inconclusive,reason=>Why,target_executions=>1}};
                {error,Why}->{error,{semantic_layer_error,Why}}
            end;
        Error->Error
    end.
%% Budgets include initial reproduction and final raw verification. The deadline
%% stops scheduling new calls; each in-flight target still uses EFZ's timeout.
minimize(Input,Target,Artifacts,E,Options,Budget) when is_integer(Budget),Budget>=1,Budget=<10000 ->
    Ms=maps:get(minimization_timeout_ms,Options,30000),
    case is_integer(Ms) andalso Ms>=1 andalso Ms=<300000 of
        false->{error,invalid_minimization_deadline};
        true->
            Start=erlang:monotonic_time(microsecond),Deadline=Start+Ms*1000,
            case run(Input,Target,Artifacts,E,Options) of
                {ok,#{status:=reproduced}} ->
                    Left=max(0,Budget-2),
                    State=#{start=>Start,deadline=>Deadline,used=>1,left=>Left,
                        budget=>Budget,original_hash=>crypto:hash(sha256,Input),trace=>[]},
                    minimize_bytes(Input,0,Target,Artifacts,E,Options,State);
                Other->Other
            end
    end;
minimize(_,_,_,_,_,_)->{error,invalid_minimization_budget}.
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
        true->{run(B,T,As,Expected,O),maps:get(used,S)+1};
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
