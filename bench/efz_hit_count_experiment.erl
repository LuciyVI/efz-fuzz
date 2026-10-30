%% Controlled quality comparison uses ONLY the production staged/random engines.
-module(efz_hit_count_experiment).
-export([run/2,report/1]).

run(Stage,Out) ->
    _=application:ensure_all_started(crypto),ok=logger:set_primary_config(level,error),
    ok=filelib:ensure_dir(filename:join(Out,"x")),
    load("fixtures/hit_count/efz_count_harness.erl"),load("bench/efz_count_bench_harness.erl"),
    Fs=fixtures(Out),
    Results=case Stage of
        executor -> executor(Fs);
        campaign -> campaigns(Fs,Out);
        stress -> stress(Fs,Out);
        large_loops -> large_loops(Out)
    end,
    save(Out,atom_to_list(Stage),Results),Results.
fixtures(Out) ->
    [begin
        File="fixtures/hit_count/"++atom_to_list(M)++".erl",
        {ok,A}=efz_instrument:compile(File,#{modules=>[M],source_root=>".",outdir=>filename:join(Out,"targets")}),
        {ok,Manifest}=efz_instrument:load(A),
        {ok,Source}=file:read_file(File),
        #{target=>M,seed=>Seed,token=>Token,artifact=>A,manifest=>Manifest,
          source_sha256=>crypto:hash(sha256,Source)}
    end || {M,Seed,Token}<-[{efz_count_repeat,<<>>,<<"A">>},
        {efz_count_records,<<>>,<<1,1,65>>},{efz_count_machine,<<"C">>,<<"TA">>}]].

campaigns(Fs,Out) ->
    %% Three independent seeds, paired mode order alternated. Both modes always
    %% receive the same execution budget, mutation config and RNG initial state.
    [begin
        Modes=case Round rem 2 of 0->[hit_count,presence];_->[presence,hit_count] end,
        Pair=[campaign(F,Mode,staged,Round,3000,Out)||Mode<-Modes],
        [A,B]=Pair,true=maps:remove(coverage_feedback,maps:get(config,A))=:=
                        maps:remove(coverage_feedback,maps:get(config,B)),Pair
    end || F<-Fs,Round<-lists:seq(1,3)].
config(F,Mode,MutationMode,Round,N,Out) ->
    Base=#{target=>efz_count_bench_harness,artifacts=>[maps:get(artifact,F)],
        seeds=>[maps:get(seed,F)],coverage_feedback=>Mode,mutation_mode=>MutationMode,
        max_input_bytes=>128,max_iterations=>N,timeout=>1000,
        crash_dir=>filename:join(Out,"crashes"),
        random_seed=>{17*Round,23,41},selection_seed=>{101,109*Round,113}},
    case MutationMode of random->Base;
        staged->Base#{mutation=>#{seed=>{17*Round,23,41},stages=>[dictionary_insert,havoc],
            dictionary=>[maps:get(token,F)],havoc_depth=>1,max_block_bytes=>32,trace_limit=>N}}
    end.
campaign(F,Mode,MutationMode,Round,N,Out) ->
    M=maps:get(target,F),persistent_term:put({efz_count_bench_harness,target},{M,self()}),
    C=config(F,Mode,MutationMode,Round,N,Out),
    {ok,_}=efz:start(C),R=efz:await(120000),ok=efz:stop(),
    Events=deep_events([]),persistent_term:erase({efz_count_bench_harness,target}),
    #{status:=completed,stats:=Stats,timing:=Timing}=R,
    N=maps:get(executions,Stats),0=maps:get(infrastructure_failures,Stats),
    First=case Events of []->not_reached;[{T,Input}|_]->
        Index=first_index(crypto:hash(sha256,Input),maps:get(mutation_trace,R,[]),1),
        #{mutation_index=>Index,us=>T-(maps:get(calibration_started_at,Timing)+maps:get(calibration_us,Timing)),
          input=>Input}
    end,
    Es=maps:get(corpus,R),
    Row=#{target=>M,coverage_feedback=>Mode,mutation_mode=>MutationMode,round=>Round,
        config=>C,final_probes=>length(maps:get(coverage,R)),coverage=>maps:get(coverage,R),
        discoveries=>maps:get(discoveries,Stats),corpus_size=>length(Es),
        corpus_bytes=>lists:sum([byte_size(maps:get(input,E))||E<-Es]),
        first_deep=>First,executions=>N,mutation_us=>maps:get(mutation_us,Timing),
        executions_per_second=>N*1000000/maps:get(mutation_us,Timing),
        unique_crashes=>maps:get(unique_crashes,Stats),count_only=>maps:get(count_only_discoveries,Stats,0),
        features=>length(maps:get(count_features,R,[])),
        source_sha256=>maps:get(source_sha256,F),build_id=>maps:get(build_id,maps:get(manifest,F))},
    Name=atom_to_list(M)++"-"++atom_to_list(MutationMode)++"-"++atom_to_list(Mode)++"-"++integer_to_list(Round),
    save(Out,Name,R),
    io:format("~p ~p ~p ~B: probes=~B discoveries=~B corpus=~B count_only=~B deep=~tp eps=~.1f~n",
        [M,MutationMode,Mode,Round,maps:get(final_probes,Row),maps:get(discoveries,Row),length(Es),
         maps:get(count_only,Row),First,maps:get(executions_per_second,Row)]),Row.
deep_events(Acc) -> receive {deep,T,B}->deep_events([{T,B}|Acc]) after 0->lists:reverse(Acc) end.
first_index(_,[],_) -> unavailable;
first_index(H,[#{output_hash:=H}|_],N) -> N;
first_index(H,[_|Ts],N) -> first_index(H,Ts,N+1).

%% Frozen-input executor batches separate counting overhead from the changed
%% scheduler/corpus. They include context creation, all hooks, validation,
%% snapshot, descendant cleanup and guardian DOWN, not feedback/storage.
executor(Fs) ->
    [Repeat]=[F||#{target:=efz_count_repeat}=F<-Fs],
    F=Repeat,Ms=[maps:get(manifest,F)],
    [begin
        Input=binary:copy(<<"A">>,N),{ok,Plan}=efz_cov_manifest:prepare(automatic,Ms),
        O=#{coverage=>automatic,coverage_plan=>Plan,max_input_bytes=>1048576},
        Count=min(200,max(10,200000 div N)),
        Expected=maps:get(coverage,efz_executor:run(efz_count_repeat,Input,1000,O)),
        _=[executor_batch(min(20,Count),Input,O#{coverage_feedback=>Mode},Expected)||Mode<-[presence,hit_count]],
        Samples=lists:foldl(fun(Round,Acc)->
            Order=case Round rem 2 of 0->[hit_count,presence];_->[presence,hit_count] end,
            lists:foldl(fun(Mode,A)->{Us,ok}=timer:tc(fun()->executor_batch(Count,Input,O#{coverage_feedback=>Mode},Expected) end),
                A#{Mode=>[Us|maps:get(Mode,A,[])]} end,Acc,Order)
        end,#{},lists:seq(1,5)),
        ok=efz_cov_manifest:release(Plan),
        [begin Ss=maps:get(Mode,Samples),Row=#{repeated_calls=>N,mode=>Mode,executions=>Count,
            median_us_per_execution=>lists:nth(3,lists:sort(Ss))/Count,samples_us=>Ss},
            io:format("Executor ~p ~B: ~.1f us/input~n",[Mode,N,maps:get(median_us_per_execution,Row)]),Row
        end || Mode<-[presence,hit_count]]
    end || N<-[1,1000,100000]].
executor_batch(0,_,_,_)->ok;
executor_batch(N,B,O,Expected)->R=efz_executor:run(efz_count_repeat,B,5000,O#{max_input_bytes=>1048576}),
    {ok,_}=maps:get(outcome,R),ok=maps:get(coverage_status,R),Expected=maps:get(coverage,R),
    executor_batch(N-1,B,O,Expected).

stress(Fs,Out) ->
    %% Random mode compatibility and a larger count-only corpus opportunity.
    %% Random has no dictionary/duplicate operator: this is also a negative control.
    [campaign(F,Mode,random,1,3000,Out)||F<-Fs,Mode<-[presence,hit_count]].
large_loops(Out) ->
    {ok,A}=efz_instrument:compile("fixtures/hit_count/efz_count_sites.erl",
        #{modules=>[efz_count_sites],source_root=>".",outdir=>filename:join(Out,"targets")}),
    Tokens=[iolist_to_binary(["L",integer_to_list(N)])||N<-[1,2,4,8,16,32,64,128,1000,100000,1000000]],
    [begin
        C=#{target=>efz_count_harness,artifacts=>[A],seeds=>[<<>>],coverage_feedback=>Mode,
            mutation_mode=>staged,max_iterations=>256,timeout=>5000,max_input_bytes=>8,
            mutation=>#{seed=>{17,23,41},stages=>[dictionary_insert],dictionary=>Tokens,trace_limit=>256}},
        {ok,_}=efz:start(C),R=efz:await(120000),ok=efz:stop(),
        Stats=maps:get(stats,R),0=maps:get(infrastructure_failures,Stats),
        true=lists:member(maps:get(status,R),[completed,{mutation_exhausted,mutation_exhausted}]),
        Trace=maps:get(mutation_trace,R),
        true=lists:any(fun(T)->efz_recipe:regenerate(T)=:={ok,<<"L1000000">>} end,Trace),
        Es=maps:get(corpus,R),
        Row=#{mode=>Mode,status=>maps:get(status,R),executions=>maps:get(executions,Stats),probes=>length(maps:get(coverage,R)),
            corpus_size=>length(Es),count_only=>maps:get(count_only_discoveries,Stats,0),
            count_features=>length(maps:get(count_features,R,[])),mutation_us=>maps:get(mutation_us,maps:get(timing,R))},
        io:format("Large loop ~tp~n",[Row]),save(Out,"large-loops-"++atom_to_list(Mode),R),Row
    end || Mode<-[presence,hit_count]].
load(File)->{ok,M,B}=compile:file(File,[binary,debug_info,warnings_as_errors]),{module,M}=code:load_binary(M,File,B),ok.
save(Out,Name,Term)->
    ok=file:write_file(filename:join(Out,Name++".term"),term_to_binary(Term)),
    ok=file:write_file(filename:join(Out,Name++".txt"),io_lib:format("~tp.~n",[Term])).

report(Out) ->
    Data=maps:from_list([begin
        {ok,B}=file:read_file(filename:join(Out,Name++".term")),
        {list_to_binary(Name),binary_to_term(B)}
    end || Name<-["micro","executor","campaign","stress","large_loops"]]),
    ok=file:write_file(filename:join(Out,"summary.json"),json:encode(json_term(Data))),ok.
json_term(T) when is_map(T) -> maps:from_list([{json_key(K),json_term(V)}||{K,V}<-maps:to_list(T)]);
json_term(T) when is_tuple(T) -> [json_term(V)||V<-tuple_to_list(T)];
json_term(T) when is_list(T) -> [json_term(V)||V<-T];
json_term(T) when is_binary(T) -> #{<<"hex">>=>binary:encode_hex(T,lowercase)};
json_term(T) when is_atom(T) -> atom_to_binary(T,utf8);
json_term(T) -> T.
json_key(K) when is_atom(K)->atom_to_binary(K,utf8);
json_key(K) when is_binary(K)->K.
