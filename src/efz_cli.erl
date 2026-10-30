%% Filesystem/argument adapter only. The existing campaign owns all fuzzing work.
-module(efz_cli).
-export([main/1, local_target/2, provider_options/2]).

main(Args) ->
    case lists:member("--supervised",Args) of true->efz_external:main(Args);false->main_local(Args) end.
main_local(Args) ->
    try
        case parse(Args, #{}) of
            help -> io:put_chars(help()), 0;
            Options -> launch(Options)
        end
    catch
        throw:{cli_error, Message} -> io:format(standard_error, "EFZ: ~ts~n", [Message]), 2;
        Class:Reason -> io:format(standard_error, "EFZ infrastructure error: ~tp:~tp~n", [Class, Reason]), 1
    end.

help() ->
    "Usage: escript scripts/fuzz.escript --target MODULE --out DIR --artifacts DIR [--seeds DIR | --corpus-dir DIR] [options]\n"
    "\nTarget contract: MODULE:run(binary()) -> term(). Coverage is automatic.\n"
    "  --config FILE            Trusted campaign map (efz:start schema); requires --out\n"
    "  --target MODULE          Harness or instrumented target exporting run/1 (required)\n"
    "  --seeds DIR              Read raw seed files (required unless --corpus-dir is supplied)\n"
    "  --corpus-dir DIR         Load/store reusable successful corpus, not a campaign checkpoint\n"
    "  --corpus-build-policy reject|recalibrate  Build mismatch policy (default: reject)\n"
    "  --out DIR                Create/use DIR; write report.term and crashes/ (required)\n"
    "  --artifacts DIR          Instrumented .beam files with paired .efz-manifest files (required)\n"
    "  --coverage-policy diagnostic|strict  No-probe campaign policy (default: diagnostic)\n"
    "  --coverage-feedback presence|hit_count  Experimental count feedback (default: presence)\n"
    "  --code-path DIR          Ordinary harness/dependency BEAM directory (repeatable)\n"
    "  --mutation staged|random Default: staged\n"
    "  --mutation-provider native|erlamsa|hybrid  Byte mutation source (default: native)\n"
    "  --erlamsa-profile balanced|bytes|formats|fields  Provider profile (default: balanced)\n"
    "  --provider-strategy preserve|perturb|mixed  Structure policy (default: mixed)\n"
    "  --provider-timeout MS    Isolated provider request deadline, 1..60000 (default: 1000)\n"
    "  --provider-transport disposable|persistent  Reuse one isolated VM per campaign\n"
    "  --provider-startup-timeout MS  Persistent startup/handshake budget (default: 10000)\n"
    "  --provider-cleanup-timeout MS  Bounded worker shutdown/recycle budget (default: 3000)\n"
    "  --provider-max-requests N  Recycle between requests; default: 10000\n"
    "  --provider-core PATH     Trusted local Erlamsa core root or ebin directory\n"
    "                           Enabled providers require staged mode; Gleam is independent\n"
    "  --timeout MS             Per-input timeout, nonnegative integer (default: 100)\n"
    "  --max-iterations N|infinity  Mutation limit; infinity runs until stopped\n"
    "                           Stop infinity campaigns with OUT/stop.request\n"
    "  --max-input-bytes N      Campaign/replay input bound, 0..1048576 (default: 4096)\n"
    "  --gleam-layer            Enable legacy optional QS layer; new adapters use --config (build profile gleam)\n"
    "  --structured-fraction N  Structured branch percent 0..100 (default: 10)\n"
    "  --semantic-feedback disabled|observation_only|guided (default: disabled)\n"
    "  --semantic-oracle disabled|inline (default: disabled)\n"
    "  --oracle-budget N        Maximum inline checks 0..10000 (default: 64)\n"
    "  --runtime-diagnostics    Enable automatic runtime observations and bounded verification\n"
    "  --runtime-runs N         Total runs per selected input, including original (1..16)\n"
    "  --verification-budget N  Maximum extra executions (0..1000000)\n"
    "  --sample-interval MS     Process sampling interval (1..10000)\n"
    "  --help                   Show this help\n"
    "  --supervised             Linux external VM supervisor (see docs/p1-01-external-supervisor.md)\n"
    "  --restart-budget N       Supervised worker restarts, 0..128 (default: 8)\n"
    "  --supervised-runs N      Total supervised execution cap, 1..100000\n"
    "  --campaign-ms MS         Absolute supervised campaign deadline\n"
    "  --startup-ms MS          Worker startup/idle deadline\n"
    "  --ipc-grace-ms MS        Bounded IPC/finalization deadline allowance\n"
    "  --journal-bytes N        Durable external journal byte budget\n"
    "\nSeed directories are not recursive; subdirectories are ignored. Empty files are valid seeds;\n"
    "a directory without seed files is an error.\n"
    "Exit: 0 completed/exhausted/idle stop (including target crashes); 2 invalid invocation/config;\n"
    "1 runtime infrastructure or report-storage failure. Existing report.term is replaced.\n"
    "\nFinite: fuzz.escript --target MODULE --artifacts DIR --seeds DIR --out OUT --mutation-provider hybrid --max-iterations 1000\n"
    "Continuous: use the same command with --max-iterations infinity; touch OUT/stop.request to stop and save.\n".

parse([], Options) -> Options;
parse(["--help"], _) -> help;
parse(["--gleam-layer"|Rest],Options)->
    case maps:is_key(gleam_enabled,Options) of
        true->fail("Duplicate option: --gleam-layer",[]);
        false->parse(Rest,Options#{gleam_enabled=>true}) end;
parse(["--runtime-diagnostics"|Rest],Options) ->
    case maps:is_key(runtime_enabled,Options) of
        true->fail("Duplicate option: --runtime-diagnostics",[]);
        false->parse(Rest,Options#{runtime_enabled=>true}) end;
parse([Option | Rest], Options) ->
    Key = option(Option),
    case Rest of
        [] -> fail("Missing value for ~ts", [Option]);
        ["--" ++ _ | _] -> fail("Missing value for ~ts", [Option]);
        [Value | Tail] ->
            case Key of
                code_paths -> parse(Tail, Options#{Key => maps:get(Key, Options, []) ++ [value(Key, Value)]});
                _ -> case maps:is_key(Key, Options) of
                    true -> fail("Duplicate option: ~ts", [Option]);
                    false -> parse(Tail, Options#{Key => value(Key, Value)})
                end
            end
    end.
option("--config") -> config_file;
option("--runtime-runs") -> runtime_runs;
option("--structured-fraction") -> structured_fraction;
option("--semantic-feedback") -> semantic_feedback;
option("--semantic-oracle") -> semantic_oracle;
option("--oracle-budget") -> oracle_budget;
option("--verification-budget") -> verification_budget;
option("--sample-interval") -> sample_interval;
option("--target") -> target;
option("--seeds") -> seeds;
option("--corpus-dir") -> corpus_dir;
option("--corpus-build-policy") -> corpus_build_policy;
option("--out") -> out;
option("--artifacts") -> artifacts;
option("--coverage-policy") -> coverage_policy;
option("--coverage-feedback") -> coverage_feedback;
option("--code-path") -> code_paths;
option("--mutation") -> mutation_mode;
option("--mutation-provider") -> provider_mode;
option("--erlamsa-profile") -> provider_profile;
option("--provider-strategy") -> provider_strategy;
option("--provider-timeout") -> provider_timeout;
option("--provider-transport") -> provider_transport;
option("--provider-startup-timeout") -> provider_startup_timeout;
option("--provider-cleanup-timeout") -> provider_cleanup_timeout;
option("--provider-max-requests") -> provider_max_requests;
option("--provider-core") -> provider_core;
option("--timeout") -> timeout;
option("--max-iterations") -> max_iterations;
option("--max-input-bytes") -> max_input_bytes;
option(Unknown) -> fail("Unknown option: ~ts (use --help)", [Unknown]).
value(target, Name) when Name =/= [], length(Name) =< 255 -> Name;
value(target, _) -> fail("--target must be a module name of 1..255 characters", []);
value(semantic_feedback,"disabled")->disabled;
value(semantic_feedback,"observation_only")->observation_only;
value(semantic_feedback,"guided")->guided;
value(semantic_feedback,_)->fail("Invalid --semantic-feedback",[]);
value(semantic_oracle,"disabled")->disabled;
value(semantic_oracle,"inline")->inline;
value(semantic_oracle,_)->fail("Invalid --semantic-oracle",[]);
value(mutation_mode, "staged") -> staged;
value(mutation_mode, "random") -> random;
value(mutation_mode, _) -> fail("--mutation must be staged or random", []);
value(provider_mode,"native")->native;
value(provider_mode,"erlamsa")->erlamsa;
value(provider_mode,"hybrid")->hybrid;
value(provider_mode,_)->fail("--mutation-provider must be native, erlamsa or hybrid",[]);
value(provider_profile,"balanced")->balanced;
value(provider_profile,"bytes")->bytes;
value(provider_profile,"formats")->formats;
value(provider_profile,"fields")->fields;
value(provider_profile,_)->fail("--erlamsa-profile must be balanced, bytes, formats or fields",[]);
value(provider_strategy,"preserve")->preserve;
value(provider_strategy,"perturb")->perturb;
value(provider_strategy,"mixed")->mixed;
value(provider_strategy,_)->fail("--provider-strategy must be preserve, perturb or mixed",[]);
value(provider_timeout,Text)->
    case Text=/=[] andalso lists:all(fun(C)->C>=$0 andalso C=<$9 end,Text) of
        true->case list_to_integer(Text) of N when N>=1,N=<60000->N;
            _->fail("--provider-timeout must be 1..60000",[]) end;
        false->fail("--provider-timeout must be 1..60000",[]) end;
value(provider_transport,"disposable")->disposable;
value(provider_transport,"persistent")->persistent;
value(provider_transport,_)->fail("--provider-transport must be disposable or persistent",[]);
value(provider_startup_timeout,Text)->provider_integer(Text,1,60000,"--provider-startup-timeout");
value(provider_cleanup_timeout,Text)->provider_integer(Text,1,30000,"--provider-cleanup-timeout");
value(provider_max_requests,Text)->provider_integer(Text,1,1000000,"--provider-max-requests");
value(provider_core,[])->fail("--provider-core must not be empty",[]);
value(provider_core,Text)->filename:absname(Text);
value(corpus_build_policy, "reject") -> reject;
value(corpus_build_policy, "recalibrate") -> recalibrate;
value(corpus_build_policy, _) -> fail("--corpus-build-policy must be reject or recalibrate", []);
value(coverage_policy, "diagnostic") -> diagnostic;
value(coverage_policy, "strict") -> strict;
value(coverage_policy, _) -> fail("--coverage-policy must be diagnostic or strict", []);
value(coverage_feedback, "presence") -> presence;
value(coverage_feedback, "hit_count") -> hit_count;
value(coverage_feedback, _) -> fail("--coverage-feedback must be presence or hit_count", []);
value(max_iterations,"infinity")->infinity;
value(K, Text) when K =:= timeout; K =:= max_iterations; K =:= max_input_bytes; K =:= runtime_runs; K =:= verification_budget; K =:= sample_interval; K=:=structured_fraction; K=:=oracle_budget ->
    case Text =/= [] andalso lists:all(fun(C) -> C >= $0 andalso C =< $9 end, Text) of
        true -> list_to_integer(Text);
        false -> fail("~ts must be a nonnegative integer", [flag(K)])
    end;
value(_, []) -> fail("Directory arguments must not be empty", []);
value(_, Text) -> Text.
provider_integer(Text,Min,Max,Flag)->
    case Text=/=[] andalso lists:all(fun(C)->C>=$0 andalso C=<$9 end,Text) of
        true->case list_to_integer(Text) of N when N>=Min,N=<Max->N;
            _->fail("~ts must be in range ~B..~B",[Flag,Min,Max]) end;
        false->fail("~ts must be in range ~B..~B",[Flag,Min,Max]) end.
flag(runtime_runs) -> "--runtime-runs";
flag(structured_fraction)->"--structured-fraction";
flag(oracle_budget)->"--oracle-budget";
flag(verification_budget) -> "--verification-budget";
flag(sample_interval) -> "--sample-interval";
flag(timeout) -> "--timeout";
flag(max_iterations) -> "--max-iterations";
flag(max_input_bytes) -> "--max-input-bytes".

launch(#{config_file:=Path}=O) ->
    lists:foreach(fun add_code_path/1,maps:get(code_paths,O,[])),
    case efz_fs:read_bounded(Path,1048576) of {ok,_}->ok;{error,E}->fail("Cannot read config: ~tp",[E]) end,
    C0=case file:consult(Path) of {ok,[C]} when is_map(C)->C;
        Other->fail("Config must contain one campaign map: ~tp",[Other]) end,
    case maps:find(out,O) of error->fail("--config requires --out",[]);{ok,_}->ok end,
    C1=maps:merge(C0,maps:with([corpus_dir,corpus_build_policy,coverage_policy,coverage_feedback,
        mutation_mode,timeout,max_iterations,max_input_bytes],O)),
    C2=case maps:find(artifacts,O) of error->C1;{ok,Dir}->
        C1#{artifacts=>require(efz_instrument:discover(Dir),"Invalid artifacts")} end,
    C3=case maps:find(target,O) of error->C2;{ok,Name}->
        C2#{target=>require(local_target(Name,maps:get(artifacts,C2,[])),"Invalid target")} end,
    C4=case maps:find(seeds,O) of error->C3;{ok,Dir2}->
        C3#{seeds=>read_seeds(Dir2,maps:get(max_input_bytes,C3,efz_input:default_limit()))} end,
    Keys=[gleam_enabled,structured_fraction,semantic_feedback,semantic_oracle,oracle_budget],
    C5=case maps:with(Keys,O) of
        None when map_size(None)=:=0->C4;
        _->Layer0=maps:get(gleam_layer,C4,#{}),
            Layer=case Layer0 of false->#{};_->Layer0 end,
            Pairs=[{case K of semantic_feedback->feedback;semantic_oracle->oracle;_->K end,V}
                ||{K,V}<-maps:to_list(maps:with(tl(Keys),O))],
            C4#{gleam_layer=>maps:merge(Layer,maps:from_list(Pairs))}
    end,
    RuntimeKeys=[runtime_enabled,runtime_runs,verification_budget,sample_interval],
    C6=case maps:with(RuntimeKeys,O) of
        NoneRuntime when map_size(NoneRuntime)=:=0->C5;
        _->C5#{runtime_oracles=>runtime_options(O)}
    end,
    C7=with_provider(C6,O),
    Out=filename:absname(maps:get(out,O)),Crashes=filename:join(Out,"crashes"),
    writable_directory(Out),writable_directory(Crashes),
    try case efz:start(C7#{crash_dir=>Crashes}) of
        {ok,_}->finish(await_campaign(C7,Out),Out);
        {error,Why}->fail("Cannot start campaign: ~ts",[start_error(Why)]) end
    after _=efz:stop() end;
launch(O) ->
    lists:foreach(fun(K) ->
        case maps:is_key(K, O) of
            true -> ok;
            false -> fail("Missing required option: --~s", [K])
        end
    end, [target, out, artifacts]),
    lists:foreach(fun add_code_path/1, maps:get(code_paths, O, [])),
    Max = maps:get(max_input_bytes,O,efz_input:default_limit()),
    case efz_input:valid_limit(Max) of true->ok;false->fail("--max-input-bytes must be 0..1048576",[]) end,
    Seeds = case maps:find(seeds, O) of
        {ok, SeedDir} -> read_seeds(SeedDir,Max);
        error -> case maps:is_key(corpus_dir, O) of
            true -> [];
            false -> fail("Missing required option: --seeds (or --corpus-dir)", [])
        end
    end,
    Artifacts = require(efz_instrument:discover(maps:get(artifacts, O)), "Invalid artifacts"),
    Mode = maps:get(mutation_mode, O, staged),
    Target=case local_target(maps:get(target,O),Artifacts) of
        {ok,Local}->Local;
        {error,local_target_not_found}->fail("target module ~ts could not be loaded; use --code-path for ordinary BEAM files",[maps:get(target,O)]);
        {error,TargetError}->fail("Invalid local target: ~tp",[TargetError]) end,
    Runtime=runtime_options(O),
    C0 = #{target => Target, runtime_oracles=>Runtime, gleam_layer=>gleam_options(O), seeds => Seeds, artifacts => Artifacts,
           mutation_mode => Mode, timeout => maps:get(timeout, O, 100),
           max_iterations => maps:get(max_iterations, O, 1000)},
    C = with_provider(C0#{max_input_bytes => Max},O),
    Out = filename:absname(maps:get(out, O)),
    Crashes = filename:join(Out, "crashes"),
    writable_directory(Out), writable_directory(Crashes),
    try
        case efz:start(maps:merge(C#{crash_dir => Crashes}, maps:with([corpus_dir,corpus_build_policy,coverage_policy,coverage_feedback],O))) of
            {ok, _} -> finish(await_campaign(C,Out), Out);
            {error, Why} -> fail("Cannot start campaign: ~ts", [start_error(Why)])
        end
    after _ = efz:stop() end.

%% Explicit CLI values override only their own nested provider fields. The
%% trusted map's source weights, limits and other options remain caller-owned.
with_provider(C,O)->
    Keys=[provider_mode,provider_profile,provider_strategy,provider_timeout,provider_core,
          provider_transport,provider_startup_timeout,provider_cleanup_timeout,provider_max_requests],
    case maps:with(Keys,O) of
        M when map_size(M)=:=0->C;
        Overrides->C#{mutation_provider=>provider_options(maps:get(mutation_provider,C,native),Overrides)}
    end.
provider_options(Base,O)->
    Keys=[provider_mode,provider_profile,provider_strategy,provider_timeout,provider_core,
          provider_transport,provider_startup_timeout,provider_cleanup_timeout,provider_max_requests],
    case maps:with(Keys,O) of
        M when map_size(M)=:=0->Base;
        Overrides->
            B=case Base of
                A when A=:=native;A=:=erlamsa;A=:=hybrid->#{mode=>A};
                P when is_map(P)->P;
                _->fail("Invalid trusted mutation_provider configuration",[])
            end,
            Mode=maps:get(provider_mode,Overrides,maps:get(mode,B,hybrid)),
            Tuning=maps:remove(provider_mode,Overrides),
            case {Mode,map_size(Tuning)} of
                {native,0}->native;
                {native,_}->fail("Provider tuning flags require --mutation-provider erlamsa or hybrid",[]);
                _->
                    Options0=maps:get(options,B,#{}),
                    case is_map(Options0) of true->ok;false->fail("Provider options must be a map",[]) end,
                    Options=lists:foldl(fun({From,To},Acc)->case maps:find(From,Overrides) of
                        {ok,V}->Acc#{To=>V};error->Acc end end,Options0,
                        [{provider_profile,profile},{provider_strategy,strategy}]),
                    Result=B#{mode=>Mode,options=>Options},
                    TuningResult=lists:foldl(fun({From,To},Acc)->case maps:find(From,Overrides) of
                        {ok,V}->Acc#{To=>V};error->Acc end end,Result,
                        [{provider_timeout,timeout},{provider_core,core_path}]),
                    lists:foldl(fun({From,To},Acc)->case maps:find(From,Overrides) of
                        {ok,V}->Acc#{To=>V};error->Acc end end,TuningResult,
                        [{provider_transport,transport},
                         {provider_startup_timeout,startup_timeout},
                         {provider_cleanup_timeout,cleanup_timeout},
                         {provider_max_requests,max_requests}])
            end
    end.

await_campaign(C,Out)->
    Default=case maps:get(mutation_mode,C,random) of staged->1000;random->infinity end,
    case maps:get(max_iterations,C,Default) of
        infinity->await_continuous(Out);
        _->efz:await(infinity)
    end.
await_continuous(Out)->
    case filelib:is_regular(filename:join(Out,"stop.request")) of
        true->ok=efz:request_stop(),efz:await(infinity);
        false->case efz_fuzzer:status() of
            finished->efz:await(infinity);
            running->receive after 250->await_continuous(Out) end
        end
    end.

gleam_options(O)->
    Keys=[structured_fraction,semantic_feedback,semantic_oracle,oracle_budget],
    case maps:get(gleam_enabled,O,false) of
        false->case maps:with(Keys,O) of M when map_size(M)=:=0->false;
            _->fail("Semantic options require --gleam-layer",[]) end;
        true->maps:from_list([{case K of semantic_feedback->feedback;semantic_oracle->oracle;_->K end,V}
            ||{K,V}<-maps:to_list(maps:with(Keys,O))])
    end.

add_code_path(Dir) ->
    case code:add_pathz(filename:absname(Dir)) of
        true -> ok;
        {error, Why} -> fail("Cannot add code path ~ts: ~tp", [Dir, Why])
    end.
read_seeds(Dir,Max) ->
    Names = require(file:list_dir(Dir), io_lib:format("Cannot read seed directory ~ts", [Dir])),
    Inputs = lists:filtermap(fun(Name) ->
        Path = filename:join(Dir, Name),
        case filelib:is_dir(Path) of
            true -> false;
            false ->
                case filelib:is_regular(Path) of
                    true -> {true, require(efz_input:read_file(Path,Max,seed_ingestion), io_lib:format("Cannot read seed file ~ts", [Path]))};
                    false -> fail("Seed entry is not a readable regular file: ~ts", [Path])
                end
        end
    end, lists:sort(Names)),
    case Inputs of [] -> fail("Empty corpus: no seed files in ~ts", [Dir]); _ -> Inputs end.

writable_directory(Dir) ->
    Probe = filename:join(Dir, ".efz-write-check-" ++ integer_to_list(erlang:unique_integer([positive]))),
    case filelib:ensure_dir(Probe) of
        ok -> ok;
        {error, Why} -> fail("Output directory unavailable ~ts: ~tp", [Dir, Why])
    end,
    case file:open(Probe, [write, binary, exclusive]) of
        {ok, F} ->
            Write = file:write(F, <<"EFZ">>), Close = file:close(F), Delete = file:delete(Probe),
            case {Write, Close, Delete} of
                {ok, ok, ok} -> ok;
                Other -> fail("Output directory is not writable ~ts: ~tp", [Dir, Other])
            end;
        {error, Why2} -> fail("Output directory is not writable ~ts: ~tp", [Dir, Why2])
    end.
finish(Report, Out) ->
    Path = filename:join(Out, "report.term"),
    case efz_fs:atomic_file(Path, term_to_binary(Report)) of
        ok -> ok;
        {error, Why} ->
            %% Keep a preceding crash/corpus failure primary even if writing the
            %% final report also fails. The exception carries the in-memory
            %% report (including exact triggering bytes) to the CLI diagnostic.
            Primary=efz_stats:failure(Why),
            Failed=Report#{status=>{infrastructure_failure,Primary},stats=>efz_stats:get(),report_storage_error=>Why},
            error({report_storage,Path,Why,Failed})
    end,
    Status = maps:get(status, Report),
    io:format("Status: ~tp~nStats: ~tp~nReport: ~ts~n", [Status, maps:get(stats, Report), Path]),
    case maps:get(coverage_diagnostics,Report,#{unused_artifacts=>[]}) of
        #{unused_artifacts:=[]} -> ok;
        Diagnostic -> io:format(standard_error,"EFZ coverage diagnostic: ~tp~n",[Diagnostic])
    end,
    case Status of
        completed -> 0;
        stopped_by_user -> 0;
        {mutation_exhausted, _} -> 0;
        {mutation_stopped, idle_budget_exhausted} -> 0;
        _ -> io:format(standard_error, "EFZ infrastructure failure: ~tp~n", [Status]), 1
    end.

%% supervisor:start_child wraps a start_link validation error in its child spec.
start_error({Why, {child, _, _, _, _, _, _, _, _}}) -> start_error(Why);
start_error({module_unavailable, Kind, M, Why}) ->
    io_lib:format("~p module ~p could not be loaded (~tp); use --code-path for ordinary BEAM files", [Kind, M, Why]);
start_error({missing_callback, Kind, M, F, A}) ->
    io_lib:format("~p module ~p must export ~p/~B", [Kind, M, F, A]);
start_error({gleam_configuration,unsupported_gleam_target}) ->
    "This target requires an explicit gleam_layer.adapter in --config; the implicit QS adapter is legacy-only";
start_error(Why) -> io_lib:format("~tp", [Why]).
require({ok, Value}, _) -> Value;
require({error, Why}, Context) -> fail("~ts: ~tp", [Context, Why]).
-spec fail(string(), [term()]) -> no_return().
fail(Format, Args) -> throw({cli_error, io_lib:format(Format, Args)}).

runtime_options(O)->
    Has=lists:any(fun(K)->maps:is_key(K,O) end,[runtime_runs,verification_budget,sample_interval]),
    case Has andalso not maps:get(runtime_enabled,O,false) of
        true->fail("Runtime options require --runtime-diagnostics",[]);false->ok end,
    N=maps:get(runtime_runs,O,3),I=maps:get(sample_interval,O,20),
    #{enabled=>maps:get(runtime_enabled,O,false),
      stability=>#{seed_runs=>N,interesting_runs=>N,suspicious_runs=>N,failure_runs=>N,
          max_extra_executions=>maps:get(verification_budget,O,1000)},
      resources=>#{sample_interval_ms=>I},hangs=>#{max_sample_age_ms=>max(100,I)}}.
%% Only trusted local BEAM files can introduce module atoms. CLI text is never interned.
local_target(Name,Artifacts) when is_list(Name),Name=/=[],length(Name)=<255->
    case lists:all(fun(C)->(C>=$a andalso C=<$z) orelse (C>=$A andalso C=<$Z) orelse
                          (C>=$0 andalso C=<$9) orelse C=:=$_ orelse C=:=$@ end,Name) of
        false->{error,invalid_target_name};
        true->case efz_instrument:preflight(Artifacts) of
            {ok,Ms}->case [maps:get(module,M)||M<-Ms,atom_to_list(maps:get(module,M))=:=Name] of
                [M]->{ok,M};
                []->case code:where_is_file(Name++".beam") of
                    non_existing->{error,local_target_not_found};
                    File->case code:load_abs(filename:rootname(File)) of
                        {module,M}->case atom_to_list(M)=:=Name of true->{ok,M};false->{error,target_name_mismatch} end;
                        Error->Error end
                end
            end;
            Error->Error
        end
    end;
local_target(_,_) -> {error,invalid_target_name}.
