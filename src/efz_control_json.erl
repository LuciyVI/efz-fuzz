%% The local control wire is data-only. Never turn client text into atoms.
-module(efz_control_json).
-export([decode/1, encode/1, request/1, campaign/1, provider/1,
         mutation_request/1, bytes/2, portable/1, text/1, keys/2,
         path/1, integer/3, enum/2]).
-define(MAX_FRAME, 8388608).

decode(B) when is_binary(B), byte_size(B) =< ?MAX_FRAME ->
    try
        scan(B, 0, false, false, 0),
        Push = fun(K, V, Acc) ->
            case lists:keymember(K, 1, Acc) of
                true -> error(duplicate_json_key);
                false -> [{K,V}|Acc]
            end
        end,
        {Value, _, Rest} = json:decode(B, ok, #{object_push => Push}),
        true = string:trim(Rest) =:= <<>>,
        {ok, Value}
    catch _:_ -> {error, invalid_json} end;
decode(_) -> {error, frame_limit}.

%% Bound nesting before asking the JSON decoder to allocate terms.
scan(<<>>, 0, false, false, _) -> ok;
scan(<<>>, _, _, _, _) -> error(invalid_json);
scan(_, D, _, _, N) when D > 24; N > 32768 -> error(json_complexity_limit);
scan(<<_,Rest/binary>>, D, true, true, N) -> scan(Rest,D,true,false,N);
scan(<<$\\,Rest/binary>>, D, true, false, N) -> scan(Rest,D,true,true,N);
scan(<<$",Rest/binary>>, D, S, false, N) -> scan(Rest,D,not S,false,N);
scan(<<C,Rest/binary>>, D, false, false, N) when C =:= ${; C =:= $[ ->
    scan(Rest,D+1,false,false,N+1);
scan(<<C,Rest/binary>>, D, false, false, N) when C =:= $}; C =:= $] ->
    true = D > 0, scan(Rest,D-1,false,false,N);
scan(<<_,Rest/binary>>, D, S, E, N) -> scan(Rest,D,S,E,N).

encode(Value) -> iolist_to_binary(json:encode(Value)).
request(M) ->
    keys(M,[<<"version">>,<<"id">>,<<"op">>,<<"args">>]),
    1 = maps:get(<<"version">>,M),
    Id = integer(maps:get(<<"id">>,M),0,9007199254740991),
    Op = enum(maps:get(<<"op">>,M),[start,stats,request_stop,await_result,close,
                                   mutate,mutate_batch,cancel,results,raw_replay,
                                   sequence_replay]),
    Args = maps:get(<<"args">>,M,#{}), true = is_map(Args),
    {Id,Op,Args}.
keys(M, Allowed) when is_map(M) ->
    case maps:keys(M) -- Allowed of [] -> ok; Other -> error({unsupported_keys,Other}) end;
keys(_,_) -> error(expected_object).
integer(N,Min,Max) when is_integer(N), N>=Min, N=<Max -> N;
integer(_,_,_) -> error(invalid_integer).
path(B) when is_binary(B), byte_size(B)>0, byte_size(B)=<4096 ->
    nomatch = binary:match(B,<<0>>),
    P=unicode:characters_to_list(B), true=is_list(P), P;
path(_) -> error(invalid_path).
enum(B, Atoms) when is_binary(B) ->
    case [A || A <- Atoms, atom_to_binary(A,utf8) =:= B] of
        [A] -> A; _ -> error({unsupported_value,B})
    end;
enum(_,_) -> error(expected_string).
bytes(#{<<"base64">>:=B}=M, Max) when is_binary(B) ->
    keys(M,[<<"base64">>]),
    true = byte_size(B) =< 4*((Max+2) div 3),
    Raw = base64:decode(B), true = byte_size(Raw)=<Max,
    true = base64:encode(Raw) =:= B, Raw;
bytes(_,_) -> error(expected_base64_bytes).

campaign(M) ->
    Allowed=[target,seeds,benchmark_replay_inputs,artifacts,code_paths,out,timeout,workers,max_iterations,
        max_input_bytes,mutation_mode,mutation_provider,mutation,coverage,
        coverage_backend,coverage_feedback,coverage_bitmap_bits,coverage_validation,
        coverage_policy,corpus_dir,corpus_build_policy,random_seed,selection_seed,
        monitoring,gleam_layer,crash_policy,runtime_oracles,execution],
    keys(M,[atom_to_binary(A,utf8)||A<-Allowed]),
    Max=integer(maps:get(<<"max_input_bytes">>,M,4096),0,1048576),
    maps:from_list([{K,campaign_value(K,V,Max)} || K<-Allowed,
        {ok,V}<-[maps:find(atom_to_binary(K,utf8),M)]]).
campaign_value(target,V,_) ->
    true=is_binary(V) andalso byte_size(V)>0 andalso byte_size(V)=<255, binary_to_list(V);
campaign_value(seeds,V,Max) ->
    true=is_list(V) andalso length(V)=<4096,
    Bs=[bytes(B,Max)||B<-V], true=lists:sum([byte_size(B)||B<-Bs])=<4194304, Bs;
campaign_value(benchmark_replay_inputs,V,Max) ->
    true=is_list(V) andalso V=/=[] andalso length(V)=<10000,
    Bs=[bytes(B,Max)||B<-V],true=lists:sum([byte_size(B)||B<-Bs])=<4194304,Bs;
campaign_value(K,V,_) when K=:=artifacts;K=:=out;K=:=corpus_dir -> path(V);
campaign_value(code_paths,V,_) -> true=is_list(V) andalso length(V)=<64,[path(P)||P<-V];
campaign_value(max_iterations,<<"infinity">>,_) -> infinity;
campaign_value(max_input_bytes,V,_) -> integer(V,0,1048576);
campaign_value(K,V,_) when K=:=timeout;K=:=max_iterations;K=:=coverage_bitmap_bits -> integer(V,0,1000000000);
campaign_value(workers,1,_) -> 1;
campaign_value(monitoring,V,_) when is_boolean(V) -> V;
campaign_value(mutation_mode,V,_) -> enum(V,[staged,random]);
campaign_value(mutation_provider,V,_) -> provider(V);
campaign_value(coverage,V,_) -> enum(V,[automatic,manual]);
campaign_value(coverage_backend,V,_) -> enum(V,[ets,ets_member,bitmap,otp_native_public,none]);
campaign_value(coverage_feedback,V,_) -> enum(V,[presence,hit_count]);
campaign_value(coverage_validation,V,_) -> enum(V,[prepared,per_execution]);
campaign_value(coverage_policy,V,_) -> enum(V,[diagnostic,strict]);
campaign_value(corpus_build_policy,V,_) -> enum(V,[reject,recalibrate]);
campaign_value(K,V,_) when K=:=random_seed;K=:=selection_seed -> seed(V);
campaign_value(mutation,V,_) -> mutation(V);
campaign_value(gleam_layer,V,_) -> gleam(V);
campaign_value(crash_policy,V,_) -> object(V,#{reason=>fun(X)->enum(X,[category,exact,ignore]) end,
    max_frames=>fun(X)->integer(X,1,32) end,max_representatives=>fun(X)->integer(X,1,32) end});
campaign_value(runtime_oracles,V,_) -> runtime(V);
campaign_value(execution,V,_) -> object(V,#{
    mode=>fun(X)->enum(X,[isolated,persistent_vm]) end,
    state_policy=>fun(X)->enum(X,[accumulate]) end,
    target_init=>fun(X)->target_init(X) end,
    max_journal_bytes=>fun(X)->integer(X,4096,67108864) end,
    max_result_bytes=>fun(X)->integer(X,1024,8388608) end,
    durability=>fun(X)->enum(X,[buffered,fsynced]) end,
    max_iterations_per_epoch=>fun(<<"infinity">>)->infinity;
        (X)->integer(X,1,1000000) end,
    max_epoch_ms=>fun(X)->integer(X,1,3600000) end,
    max_vm_memory_bytes=>fun(X)->integer(X,1048576,1099511627776) end,
    max_processes=>fun(X)->integer(X,1,1000000) end,
    max_ets_tables=>fun(X)->integer(X,1,1000000) end,
    max_ports=>fun(X)->integer(X,0,1000000) end,
    max_driver_mailbox=>fun(X)->integer(X,0,1000000) end});
campaign_value(K,_,_) -> error({invalid_campaign_option,K}).

target_init(V) when is_map(V),map_size(V)=<32 ->
    true=lists:all(fun(K)->is_binary(K) andalso byte_size(K)=<64 end,maps:keys(V)),
    maps:from_list([{K,target_init_value(X)}||{K,X}<-maps:to_list(V)]);
target_init(_) -> error(invalid_target_init).
target_init_value(X) when is_binary(X),byte_size(X)=<4096 -> X;
target_init_value(X) when is_integer(X),X>=0,X=<1000000000 -> X;
target_init_value(X) when is_boolean(X) -> X;
target_init_value(_) -> error(invalid_target_init_value).

provider(V) when is_binary(V) -> enum(V,[native,erlamsa,hybrid]);
provider(V) -> object(V,#{mode=>fun(X)->enum(X,[native,erlamsa,hybrid]) end,
    weights=>fun(X)->weights(X,[native,erlamsa]) end,options=>fun provider_options/1,
    limits=>fun(X)->integer_object(X,[input_bytes,output_bytes,intermediate_bytes,depth,nodes,
        entries,entry_bytes,unpacked_bytes,expansion_ratio,operations,repeats,block_bytes]) end,
    timeout=>fun(X)->integer(X,1,60000) end,on_skip=>fun(X)->enum(X,[native,skip]) end,
    transport=>fun(X)->enum(X,[disposable,persistent]) end,
    startup_timeout=>fun(X)->integer(X,1,60000) end,
    cleanup_timeout=>fun(X)->integer(X,1,30000) end,
    max_requests=>fun(X)->integer(X,1,1000000) end,
    core_path=>fun(X)->P=path(X),true=filename:pathtype(P)=:=absolute,P end}).
provider_options(V) -> object(V,#{profile=>fun(X)->enum(X,[balanced,bytes,formats,fields]) end,
    strategy=>fun(X)->enum(X,[preserve,perturb,mixed]) end,
    operators=>fun(X)->weights(X,operators()) end,
    patterns=>fun(X)->weights(X,[once,many,burst,skip]) end,
    field=>fun field/1,inner_operator=>fun(X)->enum(X,[auto,byte_flip]) end}).
operators() -> [byte_flip,byte_insert,byte_drop,block_repeat,block_drop,block_swap,
    line_repeat,line_drop,line_swap,number,delimiter,unicode,json,sgml,base64,
    gzip,zlib,zip,length,xor8,crc32].
field(<<"auto">>) -> auto;
field(V) -> object(V,#{offset=>fun(X)->integer(X,0,1048576) end,
    width=>fun(X)->true=lists:member(X,[8,16,32,64]),X end,
    endian=>fun(X)->enum(X,[big,little]) end,
    payload_offset=>fun(X)->integer(X,0,1048576) end,
    payload_length=>fun(X)->integer(X,0,1048576) end}).
mutation_request(V) -> object(V,#{seed=>fun seed/1,
    operator=>fun(X)->enum(X,[auto|operators()]) end,
    pattern=>fun pattern/1,
    strategy=>fun(X)->enum(X,[auto,preserve,perturb,mixed]) end,
    budget=>fun(X)->integer(X,1,64) end}).
pattern(X) when is_list(X),X=/=[],length(X)=<4 -> [enum(P,[once,many,burst,skip])||P<-X];
pattern(X) -> enum(X,[auto,once,many,burst,skip]).
seed([A,B,C]) -> list_to_tuple([integer(X,0,18446744073709551615)||X<-[A,B,C]]);
seed(_) -> error(invalid_seed).
weights(V, Names) ->
    true=is_list(V) andalso V=/=[] andalso length(V)=<128,
    Ws=[begin [Name,N]=P,{enum(Name,Names),integer(N,0,1000000)} end||P<-V],
    true=length(Ws)=:=length(lists:usort([K||{K,_}<-Ws])),
    true=lists:sum([N||{_,N}<-Ws])>0,Ws.
mutation(V) ->
    Numbers=[max_block_bytes,max_token_bytes,max_tokens,max_dictionary_bytes,max_delta,
        attempts_per_visit,havoc_depth,random_retries,max_idle_visits,trace_limit],
    Fs=maps:from_list([{K,fun(X)->integer(X,0,1048576) end}||K<-Numbers]),
    object(V,Fs#{seed=>fun seed/1,prng=>fun(X)->enum(X,[exsplus]) end,
        stages=>fun(X)->true=is_list(X),[enum(S,[bitflip,byteflip,arithmetic,boundary,
            dictionary_insert,dictionary_overwrite,havoc,splice])||S<-X] end,
        dictionary=>fun(X)->true=is_list(X) andalso length(X)=<4096,[bytes(B,65536)||B<-X] end,
        dictionary_file=>fun path/1}).
gleam(false) -> false;
gleam(V) -> object(V,#{adapter=>fun(X)->enum(X,[efz_qs_adapter]) end,
    structured_fraction=>fun(X)->integer(X,0,100) end,
    feedback=>fun(X)->enum(X,[disabled,observation_only,guided]) end,
    oracle=>fun(X)->enum(X,[disabled,inline]) end,oracle_budget=>fun(X)->integer(X,0,10000) end,
    adapter_options=>fun(X)->object(X,#{fields=>fun(Y)->integer(Y,1,32) end,
        component=>fun(Y)->integer(Y,1,128) end,legacy_contract=>fun boolean/1}) end,
    limits=>fun(X)->integer_object(X,[bytes,depth,nodes,collection,operations,fields,component]) end}).
boolean(B) when is_boolean(B) -> B;
boolean(_) -> error(expected_boolean).
runtime(V) -> object(V,#{enabled=>fun boolean/1,
    stability=>fun(X)->runtime_stability(X) end,
    resources=>fun(X)->runtime_part(X,[enabled],
        [sample_interval_ms,max_samples,max_sampled_processes,ets_interval_ms,
         max_ets_tables,memory_bytes,mailbox_messages,ets_memory_bytes,
         residual_memory_bytes,quiescence_ms,memory_observation_timeout_ms]) end,
    hangs=>fun(X)->runtime_part(X,[enabled],
        [max_stack_frames,busy_reductions,max_sample_age_ms]) end}).
runtime_stability(V) ->
    Fs=runtime_part(maps:remove(<<"sequence">>,V),[enabled,compare_return],
        [seed_runs,interesting_runs,suspicious_runs,failure_runs,max_extra_executions,
         max_groups,max_features_per_group]),
    case maps:find(<<"sequence">>,V) of
        {ok,Seq}->Fs#{sequence=>object(Seq,#{
            policy=>fun(X)->enum(X,[off,deferred,preflight_and_deferred]) end,
            repeats=>fun(X)->integer(X,2,256) end,
            max_calls=>fun(X)->integer(X,0,100000) end,
            max_elapsed_ms=>fun(X)->integer(X,100,3600000) end})};
        error->Fs
    end.
runtime_part(V,Bools,Ints)->
    BooleanFields=maps:from_list([{K,fun boolean/1}||K<-Bools]),
    IntegerFields=maps:from_list([{K,fun(X)->integer(X,0,1099511627776) end}||K<-Ints]),
    object(V,maps:merge(BooleanFields,IntegerFields)).
integer_object(V,Ks) -> object(V,maps:from_list([{K,fun(X)->integer(X,0,1073741824) end}||K<-Ks])).
object(V,Fs) ->
    keys(V,[atom_to_binary(K,utf8)||K<-maps:keys(Fs)]),
    maps:from_list([{K,F(X)}||{K,F}<-maps:to_list(Fs),{ok,X}<-[maps:find(atom_to_binary(K,utf8),V)]]).

%% Only summaries and bounded provenance use this conversion, never report ETF.
portable(V) -> portable(V,0).
portable(_,D) when D>12 -> <<"<depth limit>">>;
portable(M,D) when is_map(M),map_size(M)=<128 ->
    maps:from_list([{key(K),portable(V,D+1)}||{K,V}<-maps:to_list(M)]);
portable(L,D) when is_list(L) -> [portable(V,D+1)||V<-lists:sublist(L,128)];
portable(T,D) when is_tuple(T) -> #{<<"tuple">>=>[portable(V,D+1)||V<-tuple_to_list(T)]};
portable(A,_) when A=:=true;A=:=false;A=:=null -> A;
portable(A,_) when is_atom(A) -> atom_to_binary(A,utf8);
portable(B,_) when is_binary(B),byte_size(B)=<65536 -> #{<<"base64">>=>base64:encode(B)};
portable(N,_) when is_integer(N);is_float(N) -> N;
portable(V,_) -> text(V).
key(A) when is_atom(A) -> atom_to_binary(A,utf8);
key(B) when is_binary(B) -> B;
key(K) -> text(K).
text(T) -> unicode:characters_to_binary(io_lib:format("~0P",[T,6],[{chars_limit,1024}])).
