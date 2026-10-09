#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).
%% Separate bounded diagnostics; no target, worker, campaign or implicit RNG.
main([Build,OriginalPath,Out])->
    true=code:add_patha(filename:join([Build,"lib","efz","ebin"])),
    {module,efz_qs_model}=code:ensure_loaded(efz_qs_model),
    {efz_qs_model,Current,File}=code:get_object_code(efz_qs_model),
    L={limits,4096,32,128,1},
    Inputs=[begin {ok,B}=efz_gleam_adapter:generate(I,L),B end||I<-lists:seq(0,11)],
    Models=[M||B<-Inputs,{ok,M}<-[efz_gleam_adapter:decode(B,L)]],
    Cases=[{M,Op,Limit}||M<-Models,Op<-lists:seq(0,5),
        Limit<-[L,{limits,4095,32,128,1},{limits,4096,31,128,1},{limits,4096,32,127,1}]],
    New=[outcome(M,Op,Limit)||{M,Op,Limit}<-Cases],
    {ok,Original}=file:read_file(OriginalPath),
    replace(Original,"p2_evidence"),
    Old=[outcome(M,Op,Limit)||{M,Op,Limit}<-Cases],
    true=Old=:=New,replace(Current,File),
    Rows=lists:append([components(B,L,I)||{B,I}<- [{lists:nth(3,Inputs),1},{lists:nth(11,Inputs),10}]]),
    Samples=[sample(B,L,Op,I)||{B,I}<-lists:zip(Inputs,lists:seq(1,12)),Op<-[0,4,5]],
    Result=#{schema_version=>1,mode=>diagnostic_only,mutator_equivalence_cases=>length(Cases),
        p2_model_sha256=>hex(Original),p3_model_sha256=>hex(Current),trials=>Rows,
        samples=>Samples,additional_target_executions=>0,additional_workers=>0,
        limits=>[4096,32,128,1],sample_policy=><<"36 fixed input/operation pairs; no RNG sampling">>,
        limitation=><<"Component batches and ordinal clock samples are separate from campaign throughput; no speedup claim.">>},
    ok=file:write_file(Out,json:encode(Result)),
    io:format("~p equivalent mutation cases, ~p timing batches, ~p diagnostic samples~n",
        [length(Cases),length(Rows),length(Samples)]);
main(_)->io:format("Usage: gleam_provider_probe.escript BUILD P2_MODEL_BEAM OUTPUT.json~n"),halt(2).
replace(Beam,Name)->code:purge(efz_qs_model),code:delete(efz_qs_model),
    {module,efz_qs_model}=code:load_binary(efz_qs_model,Name,Beam).
outcome(M,Op,L)->case efz_qs_model:mutate(M,Op,L) of
    {ok,N}->{ok,N,efz_qs_model:encode(N,L)};Error->Error end.
components(B,L,Op)->
    {ok,M}=efz_gleam_adapter:decode(B,L),
    Operation=case Op of 10->1;_->4 end,
    {ok,Next}=efz_qs_model:mutate(M,Operation,L),
    Fs=[{decode,fun()->efz_gleam_adapter:decode(B,L) end},
        {mutate_core,fun()->efz_qs_model:mutate(M,Operation,L) end},
        {encode,fun()->efz_gleam_adapter:encode(Next,L) end},
        {provider,fun()->efz_gleam_adapter:mutate(B,Operation,L) end}],
    N=case byte_size(B)>1000 of true->500;false->10000 end,
    [measure(Name,F,I,N,byte_size(B),Operation)||I<-lists:seq(1,5),{Name,F}<-Fs].
measure(Name,F,I,N,Bytes,Op)->
    Expected=loop(100,F),Control=fun()->Expected end,
    {First,Second}=case I rem 2 of 0->{F,Control};_->{Control,F} end,
    {T1,Expected}=timer:tc(fun()->loop(N,First) end),
    {T2,Expected}=timer:tc(fun()->loop(N,Second) end),
    {Actual,Base}=case I rem 2 of 0->{T1,T2};_->{T2,T1} end,
    #{component=>Name,trial=>I,calls=>N,input_bytes=>Bytes,operation=>Op,
        actual_ns=>Actual*1000/N,control_ns=>Base*1000/N,delta_ns=>(Actual-Base)*1000/N}.
loop(1,F)->F();
loop(N,F)->_=F(),loop(N-1,F).
sample(B,L,Op,I)->
    Start=erlang:monotonic_time(nanosecond),Result=efz_gleam_adapter:mutate(B,Op,L),
    Elapsed=erlang:monotonic_time(nanosecond)-Start,
    {Kind,OutputBytes}=case Result of {ok,Out,_}->{success,byte_size(Out)};{skip,Why}->{Why,0} end,
    #{input_ordinal=>I,input_bytes=>byte_size(B),operation=>Op,result=>Kind,
        output_bytes=>OutputBytes,elapsed_ns=>Elapsed}.
hex(B)->binary:encode_hex(crypto:hash(sha256,B),lowercase).
