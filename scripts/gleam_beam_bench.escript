#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).
%% Diagnostic-only counters/timings. No production telemetry or RNG draws.
main([Build,Out]) ->
    Root=filename:dirname(filename:dirname(filename:absname(escript:script_name()))),
    true=code:add_patha(filename:join([Build,"lib","efz","ebin"])),
    {module,efz_qs_model}=code:ensure_loaded(efz_qs_model),
    %% Private validation functions are exported only inside this diagnostic VM.
    {ok,efz_gleam_adapter,Adapter}=compile:noenv_file(
        filename:join([Root,"src","efz_gleam_adapter.erl"]),[binary,export_all,nowarn_export_all]),
    {module,efz_gleam_adapter}=code:load_binary(efz_gleam_adapter,"diagnostic_export_all",Adapter),
    {efz_qs_model,Beam,_}=code:get_object_code(efz_qs_model),
    L={limits,4096,32,128,1}, B= <<"a=%00%FF">>,
    {ok,M}=efz_gleam_adapter:decode(B,L), {query,Fields,canonical}=M,
    Fs=[{boundary_validation,fun()->efz_gleam_adapter:valid_bytes(B,L)
                    andalso efz_gleam_adapter:valid_model(M,L) end,true},
        {core_decode,fun()->efz_qs_model:decode(B,L) end,{ok,M}},
        {adapter_decode,fun()->efz_gleam_adapter:decode(B,L) end,{ok,M}},
        {core_encode,fun()->efz_qs_model:encode(M,L) end,{ok,B}},
        {adapter_encode,fun()->efz_gleam_adapter:encode(M,L) end,{ok,B}},
        {core_check,fun()->efz_qs_model:check(M,Fields) end,true},
        {adapter_oracle,fun()->efz_gleam_adapter:oracle(B,{ok,{accepted,[{<<"a">>,<<0,255>>}]}},L) end,
            {pass,query_model_agreement}}],
    Rows=[measure(Name,F,Expected,I,20000)||I<-lists:seq(1,5),
        {Name,F,Expected}<-rotate(Fs,I rem length(Fs))],
    Large=max_input(),{ok,LargeM}=efz_gleam_adapter:decode(Large,L),
    LargeRows=[measure(Name,F,Expected,I,500)||I<-lists:seq(1,5),
        {Name,F,Expected}<-[
            {max_core_decode,fun()->efz_qs_model:decode(Large,L) end,{ok,LargeM}},
            {max_adapter_decode,fun()->efz_gleam_adapter:decode(Large,L) end,{ok,LargeM}}]],
    Diagnostic=diagnostics(L,B,M,Large),
    Result=#{schema_version=>1,mode=>diagnostic_only,production_export_all=>false,
        versions=>tuple_to_list(efz_qs_model:versions()),
        model_sha256=>binary:encode_hex(crypto:hash(sha256,Beam),lowercase),
        input_bytes=>byte_size(B),maximum_input_bytes=>byte_size(Large),
        trials=>Rows++LargeRows,counters=>Diagnostic,
        additional_layer_workers=>0,message_transport=>false,
        limitation=><<"Batch ns/call includes the common loop; diagnostic samples include clock overhead and are collected separately. No campaign throughput claim.">>},
    ok=file:write_file(Out,json:encode(Result)),
    io:format("~p batch samples; ~p diagnostic calls; output ~s~n",
        [length(Rows)+length(LargeRows),maps:get(calls,Diagnostic),Out]);
main(_)->io:format("Usage: gleam_beam_bench.escript ENGINE_BUILD OUTPUT.json~n"),halt(2).
rotate(L,0)->L;
rotate(L,N)->{A,B}=lists:split(N,L),B++A.
measure(Name,F,Expected,I,N) ->
    Expected=loop(100,F), Control=fun()->Expected end,
    {First,Second}=case I rem 2 of 0->{F,Control};_->{Control,F} end,
    {T1,Expected}=timer:tc(fun()->loop(N,First) end),
    {T2,Expected}=timer:tc(fun()->loop(N,Second) end),
    {ActualUs,ControlUs}=case I rem 2 of 0->{T1,T2};_->{T2,T1} end,
    #{component=>Name,trial=>I,calls=>N,actual_ns=>ActualUs*1000/N,
        control_ns=>ControlUs*1000/N,delta_ns=>(ActualUs-ControlUs)*1000/N}.
loop(1,F)->F();
loop(N,F)->_=F(),loop(N-1,F).
diagnostics(L,B,M,Large) ->
    Cases=[{decode,B,fun()->efz_gleam_adapter:decode(B,L) end},
           {decode,<<"name_only">>,fun()->efz_gleam_adapter:decode(<<"name_only">>,L) end},
           {decode,<<Large/binary,0>>,fun()->efz_gleam_adapter:decode(<<Large/binary,0>>,L) end},
           {decode,<<1:1>>,fun()->efz_gleam_adapter:decode(<<1:1>>,L) end},
           {encode,undefined,fun()->efz_gleam_adapter:encode(M,L) end},
           {encode,undefined,fun()->efz_gleam_adapter:encode({query,[{field,"text",<<>>}],canonical},L) end}],
    Numbered=lists:zip(lists:seq(1,48),lists:flatten(lists:duplicate(8,Cases))),
    lists:foldl(fun({I,{Name,Input,F}},S) ->
        {Result,Samples}=case I rem 7=:=0 andalso length(maps:get(samples,S))<6 of
            true->Start=erlang:monotonic_time(nanosecond),R=F(),
                Ns=erlang:monotonic_time(nanosecond)-Start,
                {R,[#{ordinal=>I,callback=>Name,elapsed_ns=>Ns}|maps:get(samples,S)]};
            false->{F(),maps:get(samples,S)}
        end,
        InBytes=case is_binary(Input) of true->byte_size(Input);false->0 end,
        OutBytes=case Result of {ok,Output} when is_binary(Output)->byte_size(Output);_->0 end,
        Category=case Result of {ok,_}->ok;{skip,limit}->limit;{skip,unsupported}->unsupported;
            {error,boundary}->boundary;{error,{semantic_layer_error,_,_}}->semantic_layer_error end,
        Counts=maps:get(results,S), Calls=maps:get(callbacks,S),
        S#{calls=>I,callbacks=>Calls#{Name=>maps:get(Name,Calls,0)+1},
            results=>Counts#{Category=>maps:get(Category,Counts,0)+1},
            input_bytes=>maps:get(input_bytes,S)+InBytes,output_bytes=>maps:get(output_bytes,S)+OutBytes,
            samples=>Samples}
    end,#{calls=>0,callbacks=>#{},results=>#{semantic_layer_error=>0},input_bytes=>0,output_bytes=>0,
          sample_every=>7,sample_limit=>6,samples=>[]},Numbered).
max_input() ->
    First= <<(binary:copy(<<"a">>,127))/binary,"=",(binary:copy(<<"v">>,128))/binary>>,
    Rest= <<(binary:copy(<<"a">>,126))/binary,"=",(binary:copy(<<"v">>,128))/binary>>,
    iolist_to_binary(lists:join(<<"&">>,[First|lists:duplicate(15,Rest)])).
