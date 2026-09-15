%% Reproducible local performance driver. Not part of the EFZ application.
-module(efz_perf).
-export([main/3, canonical/1]).

main(Stage, Out, Variants) ->
    ok = filelib:ensure_dir(filename:join(Out, "x")),
    _ = application:ensure_all_started(crypto),
    ok = logger:set_primary_config(level, warning),
    Start = now_us(), Fs = fixtures(Out), CompileUs = now_us() - Start,
    Env = environment(),
    save(Out, "environment", Env#{fixture_build_us => CompileUs,
                                  fixtures => [maps:without([plain, manifest, input], F) || F <- Fs]}),
    Stages = case Stage of all -> [hooks, executor, campaign]; _ -> [Stage] end,
    lists:foreach(fun(S) ->
        io:format("Running ~p: ~p~n", [S, Variants]),
        Result = case S of
            hooks -> hooks(Fs, Variants);
            executor -> executors(Fs, Variants);
            campaign -> campaigns(Fs, Variants, Out);
            startup -> startups(Fs, Variants, Out);
            memory -> memory(Fs, Variants, Out)
        end,
        save(Out, atom_to_list(S), Result),
        io:format("Saved ~s/~p.term~n", [Out, S])
    end, Stages).

fixtures(Out) ->
    Specs = [{loop, efz_bench_fixture, "fixtures/efz_bench_fixture.erl", 1024},
             {parser, efz_perf_parser, "fixtures/performance/efz_perf_parser.erl",
              binary:copy(<<0,0,7,1,35,2,2,97,98,3,2>>, 32)},
             {sparse, efz_perf_sparse, "fixtures/performance/efz_perf_sparse.erl", <<0,7>>}],
    [begin
        {ok, M, Plain} = compile:noenv_file(File, [binary, debug_info, warnings_as_errors]),
        {module, M} = code:load_binary(M, File, Plain),
        Value = M:run(Input),
        true = code:delete(M), _ = code:purge(M),
        {ok, A} = efz_instrument:compile(File, #{modules => [M], source_root => ".",
                                              outdir => filename:join(Out, "targets")}),
        {ok, Manifest} = efz_instrument:load(A),
        Value = M:run(Input),
        {ok, Source} = file:read_file(File),
        #{name => Name, module => M, source => File, source_sha256 => digest(Source),
          input => Input, input_sha256 => digest(term_to_binary(Input)), value => Value,
          artifact => A, manifest => Manifest, probes => length(maps:get(probes, Manifest)),
          plain => Plain}
    end || {Name, M, File, Input} <- Specs].

backend(member) -> ets_member;
backend(prepared_member) -> ets_member;
backend(_) -> ets.
prepared(prepared) -> true;
prepared(prepared_member) -> true;
prepared(_) -> false.
options(F, V) ->
    Ms = [maps:get(manifest, F)], B = backend(V),
    case prepared(V) of
        true ->
            {ok, Plan} = efz_cov_manifest:prepare(automatic, Ms),
            #{coverage => automatic, coverage_backend => B, coverage_plan => Plan};
        false -> #{coverage => automatic, coverage_backend => B, manifests => Ms}
    end.
release(#{coverage_plan := Plan}) -> efz_cov_manifest:release(Plan);
release(_) -> ok.
open(ets) -> efz_cov:open();
open(B) -> efz_cov:open(B).
table({efz_context, 1, _, {ets_member, T}, _}) -> T;
table({efz_context, 1, _, T, _}) -> T.

%% A: same call loop for inactive/reference/member. Full identities come from
%% the actual generated manifest. First-hit batches use fresh preallocated
%% contexts, so no target flush, shared buffer, or reset trick is benchmarked.
hooks(Fs, Variants) ->
    [Sparse] = [F || #{name := sparse} = F <- Fs],
    AllIds = efz_cov_manifest:identities(maps:get(manifest, Sparse)),
    Backends = lists:usort([backend(V) || V <- Variants]),
    Repeated = lists:append([begin
        Ids = lists:sublist(AllIds, D),
        Cases = [{#{kind => repeated, backend => B, calls => Calls, distinct => D,
                    manifest_probes => length(AllIds)},
                  fun() -> repeated_sample(B, Calls, Ids) end}
                 || B <- [inactive | Backends]],
        paired_samples(Cases)
    end || D <- [1,8,64,1024], Calls <- [500000,2000000]]),
    First = lists:append([begin
        Ids = lists:sublist(AllIds, D),
        Cases = [{#{kind => first_observations, backend => B, calls => Calls,
                    distinct_per_context => D, contexts => Calls div D,
                    manifest_probes => length(AllIds)},
                  fun() -> first_sample(B, Calls div D, Ids) end} || B <- Backends],
        paired_samples(Cases)
    end || D <- [64,1024], Calls <- [131072,524288]]),
    %% The existing ordinary/instrumented fixture also receives long batches.
    [Loop] = [F || #{name := loop} = F <- Fs],
    Repeated ++ First ++ loop_modes(Loop, Backends).

repeated_sample(inactive, N, Ids) ->
    ok = efz_cov:detach(),
    {Us, ok} = timer:tc(fun() -> hit_calls(N, Ids) end),
    #{us => Us};
repeated_sample(B, N, Ids) ->
    C = open(B), ok = efz_cov:attach(C),
    %% Repeat mode pre-publishes all distinct probes outside timing.
    hit_loop(1, Ids),
    {Us, ok} = timer:tc(fun() -> hit_calls(N, Ids) end),
    {ok, Hits} = efz_cov:snapshot(C), true = lists:sort(Ids) =:= Hits,
    Words = ets:info(table(C), memory),
    efz_cov:detach(), efz_cov:close(C),
    #{us => Us, live_table_words => Words}.
first_sample(B, Count, Ids) ->
    Contexts = [open(B) || _ <- lists:seq(1, Count)],
    {Us, ok} = timer:tc(fun() -> lists:foreach(fun(C) ->
        efz_cov:attach(C), hit_loop(1, Ids)
    end, Contexts) end),
    efz_cov:detach(),
    lists:foreach(fun(C) -> {ok, Hs} = efz_cov:snapshot(C),
        true = Hs =:= lists:sort(Ids), efz_cov:close(C)
    end, Contexts),
    #{us => Us}.
hit_calls(N,Ids) ->
    hit_loop(N div length(Ids),Ids),hit_ids(lists:sublist(Ids,N rem length(Ids))).
hit_loop(0, _) -> ok;
hit_loop(N, Ids) -> hit_ids(Ids), hit_loop(N - 1, Ids).
hit_ids([]) -> ok;
hit_ids([Id | Rest]) -> ok = efz_cov_rt:hit(Id), hit_ids(Rest).

loop_modes(F, Backends) ->
    M = maps:get(module, F),
    %% Safely unload only between synchronous calls, with no active targets.
    true = code:delete(M), _ = code:purge(M),
    {module, M} = code:load_binary(M, "ordinary-benchmark", maps:get(plain, F)),
    Ordinary = row(#{kind => repeated_loop, backend => ordinary, iterations => 20000000},
        repeated_samples(fun() -> loop_sample(M, inactive, 20000000) end)),
    true = code:delete(M), _ = code:purge(M), {ok, _} = efz_instrument:load(maps:get(artifact, F)),
    [Ordinary | paired_samples([{#{kind => repeated_loop, backend => B, iterations => 20000000},
        fun() -> loop_sample(M, B, 20000000) end} || B <- [inactive | Backends]])].
loop_sample(M, inactive, N) ->
    {Us, Value} = timer:tc(M, run, [N]), true = Value =:= (N div 4) * 9,
    #{us => Us};
loop_sample(M, B, N) ->
    C = open(B), efz_cov:attach(C),
    R = loop_sample(M, inactive, N),
    {ok, [_ | _]} = efz_cov:snapshot(C), efz_cov:detach(), efz_cov:close(C), R.

%% B: timer encloses every run/4 from context creation to coordinator DOWN.
executors(Fs, Variants) ->
    lists:append([paired_executor(F, Variants) || F <- Fs]).
paired_executor(F, Variants) ->
    Prepared = [{V, prepare_options(F,V)} || V <- Variants],
    Rows = [begin
        #{options := O, setup_us := Setup} = Data,
        Expected = canonical(efz_executor:run(maps:get(module,F), maps:get(input,F),100,O)),
        Expected = canonical(efz_executor:run(maps:get(module,F), maps:get(input,F),100,
            #{coverage=>automatic, manifests=>[maps:get(manifest,F)]})),
        N = batch_size(fun(K) -> executor_batch(K,F,O,Expected) end),
        {V, Data#{count=>N, expected=>Expected, samples=>[], setup_us=>Setup}}
    end || {V,Data} <- Prepared],
    %% Alternate order every round to reduce drift bias.
    Final = lists:foldl(fun(Round, Acc) ->
        Order = case Round rem 2 of 0 -> lists:reverse(Acc); _ -> Acc end,
        New = [{V, begin
            #{options:=O,count:=N,expected:=E,samples:=Ss} = D,
            S = timed(fun()->executor_batch(N,F,O,E) end), D#{samples=>[S|Ss]}
        end} || {V,D} <- Order],
        case Round rem 2 of 0 -> lists:reverse(New); _ -> New end
    end, Rows, lists:seq(1,5)),
    [begin
        release(maps:get(options,D)),
        row(#{fixture=>maps:get(name,F),variant=>V,executions=>maps:get(count,D),
              startup_plan_us=>maps:get(setup_us,D),manifest_probes=>maps:get(probes,F),
              observed_probes=>length(element(3,maps:get(expected,D)))}, lists:reverse(maps:get(samples,D)))
    end || {V,D} <- Final].
prepare_options(F,V) ->
    {Us,O}=timer:tc(fun()->options(F,V) end), #{setup_us=>Us,options=>O}.
executor_batch(0,_,_,_) -> ok;
executor_batch(N,F,O,Expected) ->
    Result=efz_executor:run(maps:get(module,F),maps:get(input,F),100,O),
    true = Expected =:= canonical(Result),
    executor_batch(N-1,F,O,Expected).
canonical(#{outcome:=O,coverage_status:=Status,coverage:=Hits}) ->
    {outcome(O),Status,lists:sort(Hits)}.
outcome({crash,C,R,St}) -> {crash,C,R,[{M,F,arity(A)} || {M,F,A,_} <- St, M =/= efz_executor]};
outcome(O) -> O.
arity(A) when is_list(A) -> length(A);
arity(A) -> A.

%% C: production mutation/feedback loop. Clock boundaries in the worker keep
%% calibration and final report generation out of steady mutation timing.
campaigns(Fs, Variants, Out) ->
    lists:append([campaign_fixture(F,Variants,Out) || F <- Fs]).
campaign_fixture(F,Variants,Out) ->
    Inputs = candidates(F), save(Out, atom_to_list(maps:get(name,F))++"-candidates",Inputs),
    efz_perf_replay:install(Inputs),
    Results = lists:append([campaign_mode(F, Mode, Variants, Out) || Mode <- [replay, real]]),
    efz_perf_replay:clear(), Results.
candidates(#{name:=loop}) -> [<<0>>,<<1>>,<<7>>,<<31>>,<<127>>,<<255>>,<<>>];
candidates(#{name:=parser}) ->
    Valid = [binary:copy(<<0,N:16,1,N,2,2,97,98,3,N>>,32) || N <- lists:seq(0,63)],
    Valid ++ [<<>>,<<5>>,<<255,0>>];
candidates(#{name:=sparse}) -> [<<I:16>> || I <- [0,1,2,7,31,127,777,2047,4095]].
campaign_mode(F,Mode,Variants,Out) ->
    %% Pilot/warmup discarded. Shared counts aim at 180 ms, capped at 2048
    %% so slow reference paths remain practical; report actual durations.
    Pilots = [{V, begin
        Pilot=campaign_sample(F,Mode,V,256,Out),
        Count=max(512,min(2048,ceil(180000*256/max(1,maps:get(us,Pilot))))),
        #{count=>Count,samples=>[]}
    end} || V<-Variants],
    SharedCount=lists:max([maps:get(count,D)||{_,D}<-Pilots]),
    States=[{V,D#{count=>SharedCount}}||{V,D}<-Pilots],
    io:format("Campaign ~p ~p: ~B candidates per sample~n",[maps:get(name,F),Mode,SharedCount]),
    Final=lists:foldl(fun(Round,Acc)->
        Order=case Round rem 2 of 0->lists:reverse(Acc);_->Acc end,
        New=[{V,begin #{count:=N,samples:=Ss}=D,
            Sample=campaign_sample(F,Mode,V,N,Out),D#{samples=>[Sample|Ss]}
        end} || {V,D}<-Order],
        case Round rem 2 of 0->lists:reverse(New);_->New end
    end,States,lists:seq(1,5)),
    Checks=[maps:get(check,Sample)||{_,D}<-Final,Sample<-maps:get(samples,D)],
    true=length(lists:usort(Checks))=:=1,
    [row(#{fixture=>maps:get(name,F),variant=>V,mode=>Mode,executions=>maps:get(count,D),
           manifest_probes=>maps:get(probes,F)},lists:reverse(maps:get(samples,D))) || {V,D}<-Final].
campaign_sample(F,Mode,V,N,Out) ->
    Mu=case Mode of replay->efz_perf_replay; real->efz_mutator_random end,
    {Target,Seed}=case maps:get(name,F) of
        loop->{efz_perf_loop_target,<<0>>}; _->{maps:get(module,F),maps:get(input,F)}
    end,
    C=#{target=>Target, artifacts=>[maps:get(artifact,F)],seeds=>[Seed],
        max_iterations=>N,mutator=>Mu,coverage_backend=>backend(V),
        coverage_validation=>case prepared(V) of true->prepared;false->per_execution end,
        random_seed=>{17,23,41},selection_seed=>{101,109,113},timeout=>100,
        crash_dir=>filename:join(Out,"crashes")},
    Start=now_us(), {ok,_}=efz:start(C), ApiUs=now_us()-Start,
    Report=efz:await(120000), #{status:=completed,timing:=Timing,stats:=Stats}=Report,
    N=maps:get(executions,Stats),0=maps:get(infrastructure_failures,Stats),
    %% Corpus/coverage/results are consumed outside the timed mutation interval.
    Check=campaign_check(Report),
    T0=now_us(),ok=efz:stop(),Cleanup=now_us()-T0,
    #{us=>maps:get(mutation_us,Timing),calibration_us=>maps:get(calibration_us,Timing),
      startup_us=>maps:get(calibration_started_at,Timing)-Start,api_start_us=>ApiUs,
      cleanup_us=>Cleanup,check=>Check}.
campaign_check(R) ->
    #{corpus=>lists:sort([maps:get(input,E)||E<-maps:get(corpus,R)]),
      coverage=>maps:get(coverage,R),
      decisions=>[{maps:get(input_id,D),maps:get(retention_reason,D),maps:get(new_probes,D)} || D<-maps:get(decisions,R)],
      crashes=>[{maps:get(input,C),canonical(maps:get(result,C))} || C<-maps:get(crashes,R)],
      stats=>maps:without([started_at],maps:get(stats,R))}.

%% Separate from throughput. VM totals and sampled peaks are deliberately named;
%% table bytes alone are not presented as the total campaign footprint.
%% Zero-mutation campaigns isolate startup/calibration after a preflight fix.
startups(Fs,Variants,Out) ->
    lists:append([paired_samples([
        {#{fixture=>maps:get(name,F),variant=>V,executions=>0,calibrations=>1},
         fun()->campaign_sample(F,real,V,0,Out) end} || V<-Variants]) || F<-Fs]).

memory(Fs,Variants,Out) ->
    [Sparse]=[F || #{name:=sparse}=F<-Fs],
    Ids=lists:sublist(efz_cov_manifest:identities(maps:get(manifest,Sparse)),8),
    [begin
        erlang:garbage_collect(), Before=mem(),
        O=options(Sparse,V),WithPlan=mem(),
        C=open(backend(V)),efz_cov:attach(C),hit_loop(10000,Ids),
        Live=mem(), Words=ets:info(table(C),memory),
        efz_cov:detach(),efz_cov:close(C),release(O),erlang:garbage_collect(),After=mem(),
        true=maps:get(coverage_tables,Before)=:=maps:get(coverage_tables,After),
        true=maps:get(plan_tables,Before)=:=maps:get(plan_tables,After),
        efz_perf_replay:install(candidates(Sparse)),
        Sampler=spawn(fun()->sample_memory(self(),#{samples=>0}) end),
        _=campaign_sample(Sparse,replay,V,5000,Out),
        Sampler!{stop,self()}, Peak=receive {memory_peak,Sampler,P}->P end,
        efz_perf_replay:clear(),erlang:garbage_collect(),AfterCampaign=mem(),
        true=maps:get(coverage_tables,Before)=:=maps:get(coverage_tables,AfterCampaign),
        true=maps:get(plan_tables,Before)=:=maps:get(plan_tables,AfterCampaign),
        #{variant=>V,before=>Before,with_plan=>WithPlan,live_context=>Live,
          context_table_bytes=>Words*erlang:system_info(wordsize),after_cleanup=>After,
          sampled_campaign_peak=>Peak,after_campaign_cleanup=>AfterCampaign}
    end || V<-Variants].
sample_memory(_,Acc) ->
    M=mem(),
    Next=maps:merge(Acc,#{samples=>maps:get(samples,Acc)+1,
        sampled_vm_total_peak=>max(maps:get(sampled_vm_total_peak,Acc,0),maps:get(vm_total,M)),
        sampled_ets_peak=>max(maps:get(sampled_ets_peak,Acc,0),maps:get(ets_total,M)),
        sampled_process_count_peak=>max(maps:get(sampled_process_count_peak,Acc,0),maps:get(process_count,M))}),
    receive {stop,To}->To!{memory_peak,self(),Next} after 2->sample_memory(undefined,Next) end.
mem() ->
    Memory=erlang:memory(),Tabs=ets:all(),
    #{vm_total=>proplists:get_value(total,Memory),ets_total=>proplists:get_value(ets,Memory),
      processes_total=>proplists:get_value(processes,Memory),process_count=>erlang:system_info(process_count),
      coverage_tables=>length([T||T<-Tabs,ets:info(T,name)=:=efz_execution_coverage]),
      plan_tables=>length([T||T<-Tabs,ets:info(T,name)=:=efz_coverage_plan]),
      proc_status=>read_text("/proc/self/status")}.

batch_size(Fun) ->
    {Us,ok}=timer:tc(fun()->Fun(128) end),
    max(128,min(20000,ceil(180000*128/max(1,Us)))).
paired_samples(Cases) ->
    Warm = [begin _=Fun(), {Params,Fun,[]} end || {Params,Fun}<-Cases],
    Final = lists:foldl(fun(Round,Acc)->
        Order = case Round rem 2 of 0->lists:reverse(Acc);_->Acc end,
        New=[{P,F,[F()|Ss]} || {P,F,Ss}<-Order],
        case Round rem 2 of 0->lists:reverse(New);_->New end
    end,Warm,lists:seq(1,5)),
    [row(P,lists:reverse(Ss))||{P,_,Ss}<-Final].
repeated_samples(Fun) ->
    _=Fun(), [Fun() || _<-lists:seq(1,5)].
timed(Fun) -> {Us,ok}=timer:tc(Fun),#{us=>Us}.
row(Params,Samples) ->
    Times=[maps:get(us,S)||S<-Samples],Sorted=lists:sort(Times),
    Params#{samples=>Samples,raw_us=>Times,median_us=>lists:nth(3,Sorted),
            min_us=>hd(Sorted),max_us=>lists:last(Sorted)}.
now_us() -> erlang:monotonic_time(microsecond).
digest(B) -> binary:encode_hex(crypto:hash(sha256,B),lowercase).
save(Out,Name,Term) ->
    ok=file:write_file(filename:join(Out,Name++".term"),term_to_binary(Term)),
    ok=file:write_file(filename:join(Out,Name++".txt"),io_lib:format("~tp.~n",[Term])).
read_text(P) -> case file:read_file(P) of {ok,B}->B;{error,R}->{unavailable,R} end.
environment() ->
    #{otp=>erlang:system_info(otp_release),erts=>erlang:system_info(version),
      architecture=>erlang:system_info(system_architecture),os=>os:type(),
      os_release=>read_text("/etc/os-release"),cpuinfo=>read_text("/proc/cpuinfo"),
      schedulers=>erlang:system_info(schedulers),online=>erlang:system_info(schedulers_online),
      dirty_cpu=>erlang:system_info(dirty_cpu_schedulers),emu=>erlang:system_info(emu_flavor),
      vm_arguments=>init:get_arguments(),erl_flags=>os:getenv("ERL_FLAGS"),
      rebar_version=>os:cmd("rebar3 version"),compiler_options=>[debug_info,warnings_as_errors],
      repeats=>5,warmup=>discarded_pilot_or_one_full_batch,minimum_batch_goal_us=>180000,
      campaign_batch_cap=>2048,
      input_hash_encoding=>erlang_external_term,word_bytes=>erlang:system_info(wordsize)}.
