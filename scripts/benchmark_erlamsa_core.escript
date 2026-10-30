#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).

%% Direct-core profiling. Identity verification and preparation happen before
%% the timed batches. Results are consumed and reported for every request.
main([Engine, Core, Output]) ->
    Paths = filelib:wildcard(filename:join([Engine,"lib","*","ebin"])),
    true = Paths =/= [], [true = code:add_patha(P) || P <- Paths],
    Options=#{profile=>bytes,operators=>[{byte_flip,1},{line_repeat,1},
        {crc32,1},{json,1},{gzip,1}],patterns=>[{once,1}],inner_operator=>byte_flip},
    {Result, PrepareTiming} = efz_erlamsa:prepare_timed(Options,
        limits(), Core),
    {ok, Prepared} = Result,
    Context = maps:get(core_context, Prepared),
    Inputs = fixtures(),
    Rows = [measure(Name, Input, Operator, Context, Prepared)
        || {Name,Input,Operator} <- Inputs],
    Manifest = #{schema_version=>1,
        otp=>erlang:system_info(otp_release),erts=>erlang:system_info(version),
        schedulers=>erlang:system_info(schedulers_online),
        engine=>filename:absname(Engine),core=>filename:absname(Core),
        core_identity=>portable(maps:get(core_identity,Prepared)),
        prepare_timing_us=>PrepareTiming,
        timed_function=><<"erlamsa_core:mutate/3" >>,
        batch_size=>1000,repeats=>7,fixtures=>Rows},
    ok = file:write_file(Output,json:encode(portable(Manifest))),
    io:format("Wrote direct-core measurements to ~s~n",[Output]);
main(_) ->
    io:format("Usage: benchmark_erlamsa_core.escript EFZ_BUILD CORE_ROOT OUTPUT.json~n"),
    halt(2).

limits() -> #{input_bytes=>1048576,output_bytes=>1048576,
    intermediate_bytes=>1048576,depth=>4,nodes=>1024,entries=>16,
    entry_bytes=>262144,unpacked_bytes=>1048576,expansion_ratio=>128,
    operations=>8,repeats=>4,block_bytes=>128}.

fixtures() ->
    Sizes=[64,4096,65536],
    lists:append([[{<<"byte_",(integer_to_binary(N))/binary>>,bytes(N),byte_flip},
        {<<"line_",(integer_to_binary(N))/binary>>,lines(N),line_repeat},
        {<<"checksum_",(integer_to_binary(N))/binary>>,checksum(N),crc32},
        {<<"json_",(integer_to_binary(N))/binary>>,json(N),json},
        {<<"gzip_",(integer_to_binary(N))/binary>>,zlib:gzip(bytes(N)),gzip}]
        || N <- Sizes]).

bytes(N) -> << <<((I*73 + (I div 7)*19) band 255)>> || I <- lists:seq(0,N-1) >>.
lines(N) ->
    Unit = <<"name=value&other=123456789\n" >>,
    binary:part(binary:copy(Unit,(N div byte_size(Unit))+1),0,N).
json(N) ->
    Prefix = <<"{\"n\":123,\"pad\":\"">>, Suffix = <<"\"}">>,
    Payload = binary:copy(<<$a>>,max(0,N-byte_size(Prefix)-byte_size(Suffix))),
    <<Prefix/binary,Payload/binary,Suffix/binary>>.
checksum(N) ->
    Payload=bytes(max(1,N-4)), <<Payload/binary,(erlang:crc32(Payload)):32/big>>.

measure(Name, Input, Operator, Context, Prepared) ->
    Request = #{seed=>{17,29,43},operator=>Operator,pattern=>once,
        strategy=>preserve,budget=>8},
    {DirectBatches,{DirectCounts,DirectHash}} = timed(7,fun() ->
        core_batch(1000,Input,Request,Context,#{success=>0,skip=>0,error=>0},undefined)
    end),
    Wrapper = [begin
        {Result,Timing}=efz_erlamsa:mutate_session_timed(Input,Request,Prepared),
        {Timing,result_kind(Result),result_hash(Result)}
    end || _ <- lists:seq(1,1000)],
    WrapperDirect = [maps:get(direct_core_mutation_us,T)||{T,_,_}<-Wrapper],
    WrapperIdentity = [maps:get(identity_check_us,T)||{T,_,_}<-Wrapper],
    #{name=>Name,operator=>Operator,input_bytes=>byte_size(Input),
      input_sha256=>hex(crypto:hash(sha256,Input)),batch_size=>1000,repeats=>7,
      direct_core_batch_us=>DirectBatches,
      direct_core_us_per_call=>quantile(DirectBatches,0.5)/1000,
      direct_core_success=>maps:get(success,DirectCounts),direct_core_skips=>maps:get(skip,DirectCounts),
      direct_core_errors=>maps:get(error,DirectCounts),direct_core_last_hash=>DirectHash,
      session_wrapper_identity_check_p50_us=>quantile(WrapperIdentity,0.5),
      session_wrapper_direct_core_p50_us=>quantile(WrapperDirect,0.5),
      session_wrapper_samples=>length(Wrapper),
      outcomes=>counts([Kind||{_,Kind,_}<-Wrapper]),
      wrapper_last_hash=>last_hash(Wrapper)}.

timed(Repeats,F) -> timed(Repeats,F,[],undefined).
timed(0,_F,Times,Last) -> {Times,Last};
timed(Repeats,F,Times,_Last) ->
    {Us,Value}=timer:tc(F),timed(Repeats-1,F,[Us|Times],Value).

core_batch(0,_Input,_Request,_Context,Counts,Last)->{Counts,Last};
core_batch(N,Input,Request,Context,Counts,_Last)->
    Result=erlamsa_core:mutate(Input,Request,Context),
    Kind=result_kind(Result),
    core_batch(N-1,Input,Request,Context,
        Counts#{Kind=>maps:get(Kind,Counts)+1},result_hash(Result)).

result_kind({ok,_,_})->success;
result_kind({skip,_})->skip;
result_kind(_)->error.
result_hash({ok,B,_})->hex(crypto:hash(sha256,B));
result_hash(_)->null.
last_hash([])->null;
last_hash(Values)->element(3,lists:last(Values)).
counts(Kinds)->maps:from_list([{K,length([ok||X<-Kinds,X=:=K])}
    ||K<-[success,skip,error]]).
quantile([],_) -> null;
quantile(Values,P)->Sorted=lists:sort(Values),lists:nth(max(1,ceil(length(Values)*P)),Sorted).
hex(Binary)->binary:encode_hex(Binary,lowercase).
portable(Binary) when is_binary(Binary) ->
    case unicode:characters_to_binary(Binary,utf8,utf8) of
        Binary->Binary;_->#{hex=>hex(Binary)} end;
portable(Tuple) when is_tuple(Tuple)->[portable(V)||V<-tuple_to_list(Tuple)];
portable(Map) when is_map(Map)->maps:from_list([{key(K),portable(V)}||{K,V}<-maps:to_list(Map)]);
portable(List) when is_list(List)->[portable(V)||V<-List];
portable(A) when is_atom(A)->atom_to_binary(A,utf8);
portable(V)->V.
key(K) when is_atom(K)->atom_to_binary(K,utf8);
key(K) when is_binary(K)->K.
