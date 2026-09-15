%% Lazy staged planning. All randomness is state-threaded and owned by this state.
-module(efz_mutation_plan).
-export([prepare/2, defaults/0, new/1, next/2, deterministic/4, config_identity/1]).

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
    efz_mutation:hash(term_to_binary(lists:sort(maps:to_list(maps:without([trace_limit,config_id],C))))).
new(C)->#{config=>C,rng=>rand:seed_s(exsplus,maps:get(seed,C)),pending_entries=>[],
          cursors=>#{},corpus_size=>0,idle=>0,idle_visits=>#{},
          counts=>#{visits=>0,mutation_attempts=>0,operation_attempts=>0,
          skipped_operations=>0,skipped_candidates=>0,generated_candidates=>0,skip_reasons=>#{}}}.
next(S,[]) -> {done,empty_corpus,S};
next(S=#{config:=C,corpus_size:=Size},Entries) ->
    %% The active corpus is append-only. New inputs can supply both finite work
    %% and splice donors, so an old idle sweep cannot describe the grown corpus.
    CurrentSize=length(Entries),
    S0=case CurrentSize=:=Size of
        true->S;
        false->progress(S#{corpus_size=>CurrentSize})
    end,
    case deterministic_pending(S0,Entries) of
        true->visit(S0,Entries);
        false->case lists:any(fun random_stage/1,maps:get(stages,C)) of
            false->{done,mutation_exhausted,S0};
            true->case maps:get(idle,S0)>=maps:get(max_idle_visits,C) andalso
                       idle_sweep_complete(S0,Entries) of
                true->{done,idle_budget_exhausted,S0};
                false->visit(S0,Entries)
            end
        end
    end.
random_stage(Stage)->Stage=:=havoc orelse Stage=:=splice.
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
    case Result of
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
attempts(0,_,_,_,_,S)->{{skip,visit_budget},S};
attempts(N,Stage,B,Es,Key,S=#{config:=C,cursors:=Cs})->
    case Stage=:=havoc orelse Stage=:=splice of
        true->random_attempts(min(N,maps:get(random_retries,C)),Stage,B,Es,S);
        false->Cur=maps:get(Key,Cs),Index=maps:get(Stage,Cur,0),
            case deterministic(Stage,B,Index,C) of
                done->{{skip,stage_done},S};
                {operation,Op}->
                    S0=inc(operation_attempts,inc(mutation_attempts,S#{cursors=>Cs#{Key=>Cur#{Stage=>Index+1}}})),
                    case efz_mutation:apply_operation(B,Op,C) of
                        {ok,Next}->{{ok,Next,[Op]},S0};
                        {skip,Why}->attempts(N-1,Stage,B,Es,Key,skip(Why,S0));
                        Error->{Error,S0}
                    end
            end
    end.
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
inc(K,S=#{counts:=Counts})->S#{counts=>Counts#{K=>maps:get(K,Counts)+1}}.
reason(Why,S=#{counts:=Counts})->Rs=maps:get(skip_reasons,Counts),S#{counts=>Counts#{skip_reasons=>Rs#{Why=>maps:get(Why,Rs,0)+1}}}.
skip(Why,S)->reason(Why,inc(skipped_operations,S)).
