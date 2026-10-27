%% Lazy staged planning. All randomness is state-threaded and owned by this state.
-module(efz_mutation_plan).
-export([prepare/2, defaults/0, new/1, next/2, next_continuous/2, deterministic/4,
         config_identity/1, complete_provider/4]).

defaults()->#{max_input_bytes=>efz_input:default_limit(),max_block_bytes=>128,max_token_bytes=>128,
    max_tokens=>256,max_dictionary_bytes=>16384,max_delta=>8,attempts_per_visit=>8,
    havoc_depth=>8,random_retries=>4,max_idle_visits=>256,trace_limit=>0,
    stages=>[bitflip,byteflip,arithmetic,boundary,dictionary_insert,dictionary_overwrite,havoc,splice],
    dictionary=>[],seed=>undefined,prng=>exsplus}.
prepare(Options,Seeds) when is_map(Options) ->
    try
        Allowed=[dictionary_file|maps:keys(defaults())],
        []=maps:keys(maps:without(Allowed,Options)),
        C0=maps:merge(defaults(),Options),
        lists:foreach(fun({K,Min,Max})->V=maps:get(K,C0),
            case is_integer(V) andalso V>=Min andalso V=<Max of true->ok;false->error({invalid_limit,K}) end
        end,[{max_input_bytes,0,efz_input:hard_limit()},{max_block_bytes,1,65536},{max_token_bytes,1,65536},
            {max_tokens,0,4096},{max_dictionary_bytes,0,1048576},{max_delta,1,128},
            {attempts_per_visit,1,1024},{havoc_depth,1,32},{random_retries,1,128},
            {max_idle_visits,1,100000},{trace_limit,0,10000}]),
        true=length(Seeds)=<4096,
        case lists:all(fun(B)->is_binary(B) andalso byte_size(B)=<maps:get(max_input_bytes,C0) end,Seeds) of
            true->ok;false->error(oversized_initial_seed)
        end,
        Stages=maps:get(stages,C0),true=is_list(Stages) andalso Stages=/=[],
        true=length(Stages)=:=length(lists:usort(Stages)),
        true=lists:all(fun(S)->lists:member(S,maps:get(stages,defaults())) end,Stages),
        exsplus=maps:get(prng,C0),
        Seed=case maps:get(seed,C0) of
            undefined-> <<A:64,B:64,D:64>>=crypto:strong_rand_bytes(24),{A,B,D};
            {A,B,D}=X when is_integer(A),A>=0,A<1 bsl 64,is_integer(B),B>=0,B<1 bsl 64,
                           is_integer(D),D>=0,D<1 bsl 64 -> X;
            _->error(invalid_mutation_seed)
        end,
        {ok,Inline,_}=efz_dictionary:normalize(maps:get(dictionary,C0),C0),
        {ok,FileTokens,_}=case maps:find(dictionary_file,Options) of
            error->efz_dictionary:normalize([],C0);
            {ok,Path}->efz_dictionary:load(Path,C0)
        end,
        {ok,Tokens,DictId}=efz_dictionary:normalize(Inline++FileTokens,C0),
        C=(maps:remove(dictionary_file,C0))#{seed=>Seed,dictionary=>Tokens,dictionary_id=>DictId,engine_version=>1},
        {ok,C#{config_id=>config_identity(C)}}
    catch error:Why->{error,{mutation_configuration,Why}} end;
prepare(_,_) -> {error,invalid_mutation_configuration}.
config_identity(C)->
    %% Sorted pairs avoid ETF map ordering differences between VMs. Trace is observational.
    Portable=case maps:find(provider,C) of
        {ok,P}->C#{provider=>maps:without([core_context,core_path],P)};
        error->C
    end,
    efz_mutation:hash(term_to_binary(lists:sort(maps:to_list(maps:without([trace_limit,config_id],Portable))))).
new(C)->Base=#{config=>C,rng=>rand:seed_s(exsplus,maps:get(seed,C)),pending_entries=>[],
          cursors=>#{},corpus_size=>0,idle=>0,idle_visits=>#{},
          counts=>#{visits=>0,mutation_attempts=>0,operation_attempts=>0,
          skipped_operations=>0,skipped_candidates=>0,generated_candidates=>0,skip_reasons=>#{}}},
    case maps:is_key(provider,C) of
        false->Base;
        true->Base#{provider_sequence=>0,provider_counts=>#{requests=>0,changed=>0,skips=>0,
            errors=>0,timeouts=>0,cancelled=>0,fallbacks=>0,skip_reasons=>#{},
            selected=>#{native=>0,erlamsa=>0},generated=>#{native=>0,erlamsa=>0}}}
    end.
next(S,[]) -> {done,empty_corpus,S};
next(S=#{config:=C,corpus_size:=Size},Entries) ->
    %% The active corpus is append-only. New inputs can supply both finite work
    %% and splice donors, so an old idle sweep cannot describe the grown corpus.
    CurrentSize=length(Entries),
    S0=case CurrentSize=:=Size of
        true->S;
        false->progress(S#{corpus_size=>CurrentSize})
    end,
    case native_pending(S0,Entries) of
        true->visit(S0,Entries);
        false->case maps:is_key(provider,C) orelse lists:any(fun random_stage/1,maps:get(stages,C)) of
            false->{done,mutation_exhausted,S0};
            true->case maps:get(idle,S0)>=maps:get(max_idle_visits,C) andalso
                       idle_sweep_complete(S0,Entries) of
                true->{done,idle_budget_exhausted,S0};
                false->visit(S0,Entries)
            end
        end
    end.
%% Finite planning stays unchanged. A continuous idle sweep yields a guaranteed
%% real mutation, preserving RNG, all content cursors and admission history.
next_continuous(S=#{config:=#{max_input_bytes:=0}},_)->
    {error,continuous_requires_nonzero_input_limit,S};
next_continuous(S=#{config:=#{provider:=_}},Entries)->
    case next(S,Entries) of
        {done,Why,Next} when Why=:=idle_budget_exhausted;Why=:=mutation_exhausted ->
            %% An enabled provider keeps its selected schedule. In particular,
            %% skip policy never silently switches an Erlamsa-only run to bytes.
            visit(progress(Next),Entries);
        Other->Other
    end;
next_continuous(S,Entries)->
    case next(S,Entries) of
        {done,Why,Next} when Why=:=idle_budget_exhausted;Why=:=mutation_exhausted ->
            continuous_fallback(Next,Entries);
        Other->Other
    end.
continuous_fallback(S=#{config:=C,rng:=R},Entries)->
    {E,R1}=choose(Entries,R),B=maps:get(input,E),
    {Op,R2}=case B of
        <<>>->{Byte,RR}=zero(255,R1),{{insert,0,<<Byte>>},RR};
        _->{Bit,RR}=zero(bit_size(B)-1,R1),{{flip_bits,Bit,1},RR}
    end,
    {ok,Out}=efz_mutation:apply_operation(B,Op,C),
    P=#{primary=>B,primary_id=>efz_mutation:hash(B),parent=>maps:get(id,E),stage=>havoc,
        operations=>[Op],config_id=>maps:get(config_id,C),dictionary_id=>maps:get(dictionary_id,C)},
    Next=inc(continuous_fallbacks,inc(generated_candidates,inc(mutation_attempts,
        inc(operation_attempts,progress(S#{rng=>R2}))))),
    {candidate,Out,P,Next}.

random_stage(Stage)->Stage=:=havoc orelse Stage=:=splice.
native_pending(#{config:=#{provider:=P}}=S,Es)->
    case maps:get(mode,P) of
        erlamsa->false;
        hybrid->case proplists:get_value(native,maps:get(weights,P),0)>0 of
            true->deterministic_pending(S,Es);false->false end
    end;
native_pending(S,Es)->deterministic_pending(S,Es).
deterministic_pending(#{config:=C,cursors:=Cs},Es)->
    lists:any(fun(E)->B=maps:get(input,E),Key={efz_mutation:hash(B),maps:get(config_id,C)},
        Cur=maps:get(Key,Cs,#{}),
        lists:any(fun(Stage)->not random_stage(Stage) andalso
            maps:get(Stage,Cur,0)<stage_count(Stage,byte_size(B),C) end,maps:get(stages,C))
    end,Es).
idle_sweep_complete(#{config:=C,idle_visits:=Vs},Es)->
    %% Each content cursor cycles through every lane. A full cycle since the
    %% last progress event gives even a late random lane a chance before stop.
    Lanes=length(maps:get(stages,C)),
    lists:all(fun(E)->Key={efz_mutation:hash(maps:get(input,E)),maps:get(config_id,C)},
        maps:get(Key,Vs,0)>=Lanes
    end,Es).
progress(S)->S#{idle=>0,idle_visits=>#{}}.
idle_visit(Key,S=#{idle:=Idle,idle_visits:=Vs})->
    S#{idle=>Idle+1,idle_visits=>Vs#{Key=>maps:get(Key,Vs,0)+1}}.
visit(S=#{pending_entries:=Pending,config:=C,cursors:=Cs},Entries)->
    %% Corpus supplies insertion order and content; no ETS or map enumeration.
    %% Snapshot each round so continual corpus growth cannot starve old entries.
    [Id|Rest]=case Pending of []->[maps:get(id,E)||E<-Entries];_->Pending end,
    [E]=[Entry||Entry<-Entries,maps:get(id,Entry)=:=Id],B=maps:get(input,E),
    Key={efz_mutation:hash(B),maps:get(config_id,C)},Cur=maps:get(Key,Cs,#{lane=>0}),
    Stages=maps:get(stages,C),Lane=maps:get(lane,Cur),Stage=lists:nth((Lane rem length(Stages))+1,Stages),
    S0=inc(visits,S#{pending_entries=>Rest,cursors=>Cs#{Key=>Cur#{lane=>Lane+1}}}),
    {Result,S1}=attempts(maps:get(attempts_per_visit,C),Stage,B,Entries,Key,S0),
    finish_visit(Result,S1,E,Stage,Key,Cur,Entries).
finish_visit(Result,S1,E,Stage,Key,Cur,Entries)->
    C=maps:get(config,S1),B=maps:get(input,E),
    case Result of
        {provider_request,Request,Data}->
            P=provenance(E,Stage,C),
            Continuation=#{entry=>E,stage=>Stage,key=>Key,cursor=>Cur,entries=>Entries,
                provenance=>P,provider=>Data},
            {provider_request,B,Request,P#{source_kind=>provider,provider=>Data},Continuation,S1};
        {ok,Candidate,Ops,{provider,Data}}->
            P=(provenance(E,Stage,C))#{operations=>Ops,source_kind=>provider,provider=>Data},
            {candidate,Candidate,P,provider_generated(maps:get(source,Data),
                inc(generated_candidates,progress(S1)))};
        {ok,Candidate,Ops,Structured}->
            P=#{primary=>B,primary_id=>efz_mutation:hash(B),parent=>maps:get(id,E),stage=>Stage,
                operations=>Ops,config_id=>maps:get(config_id,C),dictionary_id=>maps:get(dictionary_id,C),
                source_kind=>structured,structured=>Structured},
            {candidate,Candidate,P,inc(generated_candidates,progress(S1))};
        {ok,Candidate,Ops}->
            P=#{primary=>B,primary_id=>efz_mutation:hash(B),parent=>maps:get(id,E),stage=>Stage,
                operations=>Ops,config_id=>maps:get(config_id,C),dictionary_id=>maps:get(dictionary_id,C)},
            {candidate,Candidate,P,inc(generated_candidates,progress(S1))};
        {skip,Why}->
            %% Rejecting a finite operation still advances its cursor toward
            %% exhaustion. Random retries and visits to an empty lane do not.
            NextCur=maps:get(Key,maps:get(cursors,S1)),
            S2=case maps:get(Stage,NextCur,0)>maps:get(Stage,Cur,0) of
                true->progress(S1);
                false->idle_visit(Key,S1)
            end,
            {skip,Why,inc(skipped_candidates,S2)};
        {error,Why}->{error,Why,S1}
    end.
provenance(E,Stage,C)->B=maps:get(input,E),
    #{primary=>B,primary_id=>efz_mutation:hash(B),parent=>maps:get(id,E),stage=>Stage,
      config_id=>maps:get(config_id,C),dictionary_id=>maps:get(dictionary_id,C)}.
attempts(0,_,_,_,_,S)->{{skip,visit_budget},S};
attempts(N,Stage,B,Es,Key,S=#{config:=C})->
    case structured(B,C,S) of
        {ordinary,SOrdinary}->ordinary_source(N,Stage,B,Es,Key,SOrdinary);
        Result->Result
    end.
ordinary_source(N,Stage,B,Es,Key,S=#{config:=#{provider:=P},rng:=R})->
    {Source,R1}=case maps:get(mode,P) of
        erlamsa->{erlamsa,R};
        hybrid->Weights=maps:get(weights,P),Total=lists:sum([W||{_,W}<-Weights]),
            {Pick,NextR}=zero(Total-1,R),{weighted_source(Pick,Weights),NextR}
    end,
    S0=provider_selected(Source,S#{rng=>R1}),
    case Source of
        native->Data=provider_data(P,none,none),
            native_source(N,Stage,B,Es,Key,Data#{source=>native},S0);
        erlamsa->
            {A,R2}=zero((1 bsl 64)-1,R1),{D,R3}=zero((1 bsl 64)-1,R2),
            {F,R4}=zero((1 bsl 64)-1,R3),
            Request=#{seed=>{A,D,F},operator=>auto,pattern=>auto,strategy=>auto,
                budget=>maps:get(operations,maps:get(limits,P))},
            Number=maps:get(provider_sequence,S0)+1,Data=provider_data(P,Request,Number),
            Next=provider_inc(requests,inc(mutation_attempts,inc(operation_attempts,
                S0#{rng=>R4,provider_sequence=>Number}))),
            {{provider_request,Request,Data},Next}
    end;
ordinary_source(N,Stage,B,Es,Key,S)->ordinary_attempts(N,Stage,B,Es,Key,S).
weighted_source(Pick,[{Source,Weight}|_]) when Pick<Weight->Source;
weighted_source(Pick,[{_,Weight}|Rest])->weighted_source(Pick-Weight,Rest).
provider_data(P,Request,Number)->
    #{schema_version=>1,wrapper_version=>1,source=>erlamsa,mode=>maps:get(mode,P),
      identity=>maps:get(core_identity,P),config_identity=>maps:get(config_identity,P),
      request=>Request,request_number=>Number,recipe=>#{},limits=>maps:get(limits,P),fallback=>none}.
native_source(N,Stage,B,Es,Key,Data,S)->
    case ordinary_attempts(N,Stage,B,Es,Key,S) of
        {{ok,Out,Ops},Next}->{{ok,Out,Ops,{provider,Data}},Next};
        Other->Other
    end.

%% Only the worker completes an already selected local request. The continuation
%% contains trusted planner state; no artifact can select a callback here.
complete_provider(Result,_RuntimeMeta,Cont,S)->
    case Result of
        {ok,Out,CoreRecipe} when is_binary(Out),is_map(CoreRecipe)->
            E=maps:get(entry,Cont),B=maps:get(input,E),C=maps:get(config,S),
            P=maps:get(provider,C),Max=min(maps:get(max_input_bytes,C),
                maps:get(output_bytes,maps:get(limits,P))),
            case {byte_size(Out)=<Max,Out=:=B,efz_gleam_adapter:portable(CoreRecipe),
                    erlang:external_size(CoreRecipe)=<4096} of
                {false,_,_,_}->provider_error(oversized_output,S);
                {_,true,_,_}->provider_skip(no_change,Cont,S);
                {_,_,true,true}->
                    %% Opaque bounded data keeps optional-library atoms out of
                    %% the outer recipe. Raw replay never needs their code.
                    Data=(maps:get(provider,Cont))#{recipe=>term_to_binary(CoreRecipe,[deterministic])},
                    Op={provider_replace,1,efz_mutation:hash(Out),Out},
                    finish_provider_visit({ok,Out,[Op],{provider,Data}},Cont,provider_inc(changed,S));
                _->provider_error(invalid_recipe_data,S)
            end;
        {skip,Why} when is_atom(Why)->provider_skip(Why,Cont,S);
        {error,Why}->provider_error(Why,S);
        {timeout,Why}->provider_error({timeout,Why},provider_inc(timeouts,S));
        cancelled->{skip,provider_cancelled,provider_inc(cancelled,S)};
        _->provider_error(invalid_reply,S)
    end.
provider_skip(Why0,Cont,S=#{config:=#{provider:=P}})->
    Why=portable_skip_reason(Why0),Counts=maps:get(provider_counts,S),
    Reasons=maps:get(skip_reasons,Counts),
    S0=provider_inc(skips,S#{provider_counts=>Counts#{skip_reasons=>
        Reasons#{Why=>maps:get(Why,Reasons,0)+1}}}),
    case maps:get(on_skip,P) of
        skip->finish_provider_visit({skip,{provider,Why}},Cont,reason({provider,Why},S0));
        native->
            E=maps:get(entry,Cont),Data=(maps:get(provider,Cont))#{source=>native,
                recipe=>#{},fallback=>Why},C=maps:get(config,S0),
            {Result,Next}=native_source(maps:get(attempts_per_visit,C),maps:get(stage,Cont),
                maps:get(input,E),maps:get(entries,Cont),maps:get(key,Cont),Data,
                provider_inc(fallbacks,S0)),
            finish_provider_visit(Result,Cont,Next)
    end.
%% Core reason atoms are optional-library data. A saved recipe must decode
%% safely in a fresh VM that has never loaded that library.
portable_skip_reason(Why) when is_atom(Why)->atom_to_binary(Why,utf8);
portable_skip_reason(Why) when is_binary(Why),byte_size(Why)=<256->Why;
portable_skip_reason(_)-><<"other_skip">>.
finish_provider_visit(Result,Cont,S)->finish_visit(Result,S,maps:get(entry,Cont),
    maps:get(stage,Cont),maps:get(key,Cont),maps:get(cursor,Cont),maps:get(entries,Cont)).
provider_error(Why,S)->{error,{mutation_provider,Why},provider_inc(errors,S)}.
provider_inc(K,S=#{provider_counts:=Counts})->S#{provider_counts=>Counts#{K=>maps:get(K,Counts,0)+1}}.
provider_selected(Source,S=#{provider_counts:=Counts})->Selected=maps:get(selected,Counts),
    S#{provider_counts=>Counts#{selected=>Selected#{Source=>maps:get(Source,Selected,0)+1}}}.
provider_generated(Source,S=#{provider_counts:=Counts})->Generated=maps:get(generated,Counts),
    S#{provider_counts=>Counts#{generated=>Generated#{Source=>maps:get(Source,Generated,0)+1}}}.
ordinary_attempts(0,_,_,_,_,S)->{{skip,visit_budget},S};
ordinary_attempts(N,Stage,B,Es,Key,S=#{config:=C,cursors:=Cs})->
    case Stage=:=havoc orelse Stage=:=splice of
        true->random_attempts(min(N,maps:get(random_retries,C)),Stage,B,Es,S);
        false->Cur=maps:get(Key,Cs),Index=maps:get(Stage,Cur,0),
            case deterministic(Stage,B,Index,C) of
                done->{{skip,stage_done},S};
                {operation,Op}->
                    S0=inc(operation_attempts,inc(mutation_attempts,S#{cursors=>Cs#{Key=>Cur#{Stage=>Index+1}}})),
                    case efz_mutation:apply_operation(B,Op,C) of
                        {ok,Next}->{{ok,Next,[Op]},S0};
                        {skip,Why}->ordinary_attempts(N-1,Stage,B,Es,Key,skip(Why,S0));
                        Error->{Error,S0}
                    end
            end
    end.
%% Off/fraction-zero is a single lookup, with no additional random draws.
structured(B,#{gleam_layer:=#{structured_fraction:=F}=P},S=#{rng:=R}) when F>0 ->
    {Branch,R1}=uniform(100,R),S1=S#{rng=>R1},
    case Branch=<F of
        false->{ordinary,S1};
        true ->
            Catalogue=efz_gleam_adapter:operations(P),
            {Index,R2}=zero(length(Catalogue)-1,R1),Operation=lists:nth(Index+1,Catalogue),
            Legacy=maps:get(legacy_qs,P,not maps:is_key(adapter,P)),
            {Params,R3}=case Legacy of true->{#{choice=>0},R2};false->
                {Choice,NextR}=zero(65535,R2),{#{choice=>Choice},NextR} end,
            S2=semantic_operation(Operation,semantic_count(attempts,inc(mutation_attempts,S1#{rng=>R3}))),
            Limits=efz_gleam_adapter:limits(P),
            Start=erlang:monotonic_time(microsecond),
            Result=case Legacy of true->efz_gleam_adapter:mutate(B,Operation,Limits);
                false->efz_gleam_adapter:mutate(B,Operation,Params,P) end,
            Timed=semantic_time(callback_us,erlang:monotonic_time(microsecond)-Start,S2),
            case Result of
                {ok,B,_} -> {ordinary,semantic_count(fallbacks,semantic_count(no_change,Timed))};
                {ok,Out,Recipe} ->
                    {Replacement,Provenance}=case Legacy of
                        true->V=efz_gleam_adapter:versions(),LL=efz_qs_legacy:provider_limits(Limits),
                            {{structured_replace,1,V,Operation,Out},
                                #{schema_version=>1,versions=>V,operation=>Operation,limits=>LL,
                                    fraction=>F,rng_before=>rng_words(R),rng_after=>rng_words(R3)}};
                        false->Identity=efz_gleam_adapter:identity(P),
                            {{structured_replace,2,Identity,Operation,Out},
                                #{schema_version=>2,identity=>Identity,operation=>Operation,
                                    params=>Params,recipe=>term_to_binary(Recipe,[deterministic]),limits=>maps:get(limits,P),fraction=>F,
                                    rng_before=>rng_words(R),rng_after=>rng_words(R3)}}
                    end,
                    {{ok,Out,[Replacement],Provenance},
                        semantic_time(generated_bytes,byte_size(Out),semantic_count(successes,Timed))};
                {skip,Why}->{ordinary,semantic_count(fallbacks,semantic_count(Why,Timed))};
                {error,Why}->{{error,{semantic_layer_error,Why}},semantic_count(errors,Timed)}
            end
    end;
structured(_,_,S)->{ordinary,S}.
semantic_count(K,S)->Cs=maps:get(structured_counts,S,#{}),S#{structured_counts=>Cs#{K=>maps:get(K,Cs,0)+1}}.
semantic_time(K,V,S)->Cs=maps:get(structured_counts,S,#{}),S#{structured_counts=>Cs#{K=>maps:get(K,Cs,0)+V}}.
semantic_operation(Op,S)->Cs=maps:get(structured_counts,S,#{}),Ops=maps:get(operations,Cs,#{}),
    S#{structured_counts=>Cs#{operations=>Ops#{Op=>maps:get(Op,Ops,0)+1}}}.
%% OTP exsplus exports two 58-bit words as an improper list. Persist a proper
%% bounded list, retaining the exact state rather than reseeding from a triplet.
rng_words(R)->{exsplus,[A|B]}=rand:export_seed_s(R),[A,B].
random_attempts(0,_,_,_,S)->{{skip,random_retry_budget},S};
random_attempts(N,Stage,B,Es,S=#{config:=C,rng:=R})->
    {Depth,R1}=case Stage of havoc->uniform(maps:get(havoc_depth,C),R);splice->{1,R} end,
    S0=inc(mutation_attempts,S#{rng=>R1}),
    case stack(Depth,Stage,B,B,Es,[],S0) of
        {{ok,B,_},S1}->random_attempts(N-1,Stage,B,Es,reason(no_change,S1));
        {{ok,Next,Ops},S1}->{{ok,Next,Ops},S1};
        Error->Error
    end.
stack(0,_,_,B,_,Ops,S)->{{ok,B,lists:reverse(Ops)},S};
stack(N,Stage,Primary,B,Es,Ops,S=#{config:=C,rng:=R})->
    {Kind,R1}=case Stage of
        splice->{splice,R};
        havoc->choose([flip_bits,invert_bytes,add,set_integer,overwrite,insert,delete,duplicate,
                       dictionary_insert,dictionary_overwrite,splice],R)
    end,
    {Choice,R2}=random_operation(Kind,B,Primary,Es,C,R1),
    S0=inc(operation_attempts,S#{rng=>R2}),
    case Choice of
        {skip,Why}->stack(N-1,Stage,Primary,B,Es,Ops,skip(Why,S0));
        Op->case efz_mutation:apply_operation(B,Op,C) of
            {ok,Next}->stack(N-1,Stage,Primary,Next,Es,[Op|Ops],S0);
            {skip,Why}->stack(N-1,Stage,Primary,B,Es,Ops,skip(Why,S0));
            Error->{Error,S0}
        end
    end.
uniform(N,R)->rand:uniform_s(N,R).
zero(N,R)->{X,R1}=uniform(N+1,R),{X-1,R1}.
choose(List,R)->{I,R1}=uniform(length(List),R),{lists:nth(I,List),R1}.
random_operation(flip_bits,B,_,_,_,R)->{W,R1}=choose([1,2,4],R),{Off,R2}=zero(max(0,bit_size(B)-W),R1),{{flip_bits,Off,W},R2};
random_operation(invert_bytes,B,_,_,_,R)->{W,R1}=choose([1,2,4],R),{Off,R2}=zero(max(0,byte_size(B)-W),R1),{{invert_bytes,Off,W},R2};
random_operation(K,B,_,_,C,R) when K=:=add;K=:=set_integer ->
    {{W,Endian},R1}=choose(fields(),R),{Off,R2}=zero(max(0,byte_size(B)-W div 8),R1),
    {V,R3}=case K of add->choose(deltas(C),R2);set_integer->choose(efz_mutation:boundaries(W),R2) end,
    {{K,Off,W,Endian,V},R3};
random_operation(K,B,_,_,C,R) when K=:=insert;K=:=overwrite ->
    Available=case K of insert->maps:get(max_input_bytes,C)-byte_size(B);overwrite->byte_size(B) end,
    case Available of
        0->{{skip,case K of insert->size_limit;overwrite->insufficient_length end},R};
        _->{Len,R1}=uniform(min(Available,maps:get(max_block_bytes,C)),R),
            End=case K of insert->byte_size(B);overwrite->byte_size(B)-Len end,
            {Off,R2}=zero(End,R1),{Bytes,R3}=literal_bytes(Len,R2,[]),{{K,Off,Bytes},R3}
    end;
random_operation(K,B,_,_,C,R) when K=:=delete;K=:=duplicate ->
    case byte_size(B) of
        0->{{skip,insufficient_length},R};
        Size->{Len,R1}=uniform(min(Size,maps:get(max_block_bytes,C)),R),{Off,R2}=zero(Size-Len,R1),
            case K of delete->{{delete,Off,Len},R2};
                duplicate->{At,R3}=zero(Size,R2),{{duplicate,Off,Len,At},R3} end
    end;
random_operation(K,B,_,_,C,R) when K=:=dictionary_insert;K=:=dictionary_overwrite ->
    case maps:get(dictionary,C) of
        []->{{skip,dictionary_unavailable},R};
        Tokens->{Token,R1}=choose(Tokens,R),End=case K of dictionary_insert->byte_size(B);_->max(0,byte_size(B)-byte_size(Token)) end,
            {Off,R2}=zero(End,R1),{{K,Off,Token},R2}
    end;
random_operation(splice,B,Primary,Es,_,R)->
    Donors=lists:usort([maps:get(input,E)||E<-Es,maps:get(input,E)=/=Primary]),
    case Donors of
        []->{{skip,donor_unavailable},R};
        _->{Donor,R1}=choose(Donors,R),{A,R2}=zero(byte_size(B),R1),{D,R3}=zero(byte_size(Donor),R2),
            {{splice,A,D,Donor,efz_mutation:hash(Donor)},R3}
    end.
literal_bytes(0,R,Acc)->{list_to_binary(lists:reverse(Acc)),R};
literal_bytes(N,R,Acc)->{X,R1}=zero(255,R),literal_bytes(N-1,R1,[X|Acc]).

%% Width/field order outermost, offset next, value/token innermost.
deterministic(Stage,B,I,C) when is_integer(I),I>=0 ->
    N=byte_size(B),
    case I<stage_count(Stage,N,C) of
        false->done;
        true->{operation,det_op(Stage,N,I,C)}
    end.
fields()->[{8,big},{16,little},{16,big},{32,little},{32,big}].
deltas(C)->lists:append([[D,-D]||D<-lists:seq(1,maps:get(max_delta,C))]).
stage_count(bitflip,N,_)->lists:sum([max(0,8*N-W+1)||W<-[1,2,4]]);
stage_count(byteflip,N,_)->lists:sum([max(0,N-W+1)||W<-[1,2,4]]);
stage_count(arithmetic,N,C)->lists:sum([max(0,N-W div 8+1)*2*maps:get(max_delta,C)||{W,_}<-fields()]);
stage_count(boundary,N,_)->lists:sum([max(0,N-W div 8+1)*length(efz_mutation:boundaries(W))||{W,_}<-fields()]);
stage_count(dictionary_insert,N,C)->(N+1)*length(maps:get(dictionary,C));
stage_count(dictionary_overwrite,N,C)->lists:sum([max(0,N-byte_size(T)+1)||T<-maps:get(dictionary,C)]).
det_op(bitflip,N,I,_)->{W,Off}=locate([{W,max(0,8*N-W+1)}||W<-[1,2,4]],I),{flip_bits,Off,W};
det_op(byteflip,N,I,_)->{W,Off}=locate([{W,max(0,N-W+1)}||W<-[1,2,4]],I),{invert_bytes,Off,W};
det_op(K,N,I,C) when K=:=arithmetic;K=:=boundary ->
    Specs=[begin Values=case K of arithmetic->deltas(C);boundary->efz_mutation:boundaries(W) end,
        {{W,E,Values},max(0,N-W div 8+1)*length(Values)} end||{W,E}<-fields()],
    {{W,E,Values},Local}=locate(Specs,I),Count=length(Values),
    Tag=case K of arithmetic->add;boundary->set_integer end,
    {Tag,Local div Count,W,E,lists:nth((Local rem Count)+1,Values)};
det_op(dictionary_insert,_,I,C)->Ts=maps:get(dictionary,C),K=length(Ts),{dictionary_insert,I div K,lists:nth((I rem K)+1,Ts)};
det_op(dictionary_overwrite,N,I,C)->{Token,Off}=locate([{T,max(0,N-byte_size(T)+1)}||T<-maps:get(dictionary,C)],I),
    {dictionary_overwrite,Off,Token}.
locate([{Key,N}|_],I) when I<N->{Key,I};
locate([{_,N}|Rest],I)->locate(Rest,I-N).
inc(K,S=#{counts:=Counts})->S#{counts=>Counts#{K=>maps:get(K,Counts,0)+1}}.
reason(Why,S=#{counts:=Counts})->Rs=maps:get(skip_reasons,Counts),S#{counts=>Counts#{skip_reasons=>Rs#{Why=>maps:get(Why,Rs,0)+1}}}.
skip(Why,S)->reason(Why,inc(skipped_operations,S)).
