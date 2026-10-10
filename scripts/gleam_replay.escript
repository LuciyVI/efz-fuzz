#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).

%% Cold, explicit replay entry point. Findings contain data, never code choices.
main(["--help"]) -> usage(),halt(0);
main([[$-|_]|_]=Args) ->
    try
        Options=parse(Args,#{code_paths=>[]}),
        required(Options,[config,finding,budget,out]),
        replay(Options)
    catch
        throw:{replay_cli,Status,Reason}->
            io:format(standard_error,"Semantic replay: ~tp~n",[Reason]),halt(Status);
        Class:Reason->
            io:format(standard_error,"Semantic replay: ~tp~n",[{Class,Reason}]),halt(2)
    end;
main([_,_,_,_,_]=Args) -> legacy(Args);
main(_) -> usage(),halt(2).

usage() -> io:format(
    "Usage: gleam_replay.escript --config FILE --finding PREFIX --budget N --out NEWDIR\n"
    "                           [--code-path DIR ...]\n"
    "Budget 1..10000 counts initial replay and all minimizer target executions.\n"
    "Budget 1 saves a reproduced replay only; larger budgets also minimize.\n"
    "NEWDIR must not exist. Only PREFIX.input and PREFIX.semantic are read.\n"
    "Legacy helper: gleam_replay.escript PREFIX NATIVE_ARTIFACT_DIR TARGET BUDGET OUT\n").

parse([],Options) -> Options;
parse(["--code-path",Path|Rest],Options) ->
    parse(Rest,Options#{code_paths=>maps:get(code_paths,Options)++[Path]});
parse([Flag,Value|Rest],Options) ->
    Key=case Flag of
        "--config"->config;"--finding"->finding;"--budget"->budget;"--out"->out;
        _->fail({unknown_replay_option,Flag})
    end,
    case maps:is_key(Key,Options) of
        true->fail({duplicate_replay_option,Flag});
        false->parse(Rest,Options#{Key=>Value})
    end;
parse(Args,_) -> fail({incomplete_replay_options,Args}).
required(Options,Keys) ->
    case [Key||Key<-Keys,not maps:is_key(Key,Options)] of
        []->ok;Missing->fail({missing_replay_options,Missing})
    end.

replay(Options) ->
    Root=filename:dirname(filename:dirname(filename:absname(escript:script_name()))),
    add_path(filename:join([Root,"_build","default","lib","efz","ebin"])),
    lists:foreach(fun add_path/1,maps:get(code_paths,Options)),
    Budget=budget(maps:get(budget,Options)),
    Out=filename:absname(maps:get(out,Options)),
    require_new_output(Out),
    Config=configuration(maps:get(config,Options)),
    Target=maps:get(target,Config,undefined),
    case is_atom(Target) andalso Target=/=undefined of
        true->ok;false->fail(missing_replay_target)
    end,
    Layer=case maps:get(gleam_layer,Config,false) of
        #{adapter:=_}=Explicit->Explicit;
        _->fail(semantic_replay_requires_explicit_adapter)
    end,
    Artifacts=maps:get(artifacts,Config,[]),
    case is_list(Artifacts) andalso lists:all(fun is_map/1,Artifacts) of
        true->ok;false->fail(invalid_replay_artifacts)
    end,
    Prefix=maps:get(finding,Options),
    Expected=read_ok(efz_semantic_replay:load(Prefix++".semantic")),
    case maps:get(schema_version,Expected) of
        2->ok;_->fail(legacy_finding_requires_legacy_helper)
    end,
    Max=maps:get(max_input_bytes,Config,maps:get(max_input_bytes,Expected)),
    case efz_input:valid_limit(Max) of true->ok;false->fail(invalid_max_input_bytes) end,
    Input=read_ok(efz_input:read_file(Prefix++".input",Max,semantic_replay)),
    ReplayOptions=#{timeout=>maps:get(timeout,Config,100),
        coverage_backend=>maps:get(coverage_backend,Config,ets),
        max_input_bytes=>Max,gleam_layer=>constrained_layer(Layer,Max)},
    case lists:member(maps:get(coverage_backend,ReplayOptions),
        [ets,ets_member,otp_native_public,none]) of
        true->ok;false->fail({unsupported_semantic_replay_backend,
            maps:get(coverage_backend,ReplayOptions)})
    end,
    trusted_identity(Input,Target,Artifacts,Expected,ReplayOptions),
    Result=runtime_ok(efz_semantic_replay:run(Input,Target,Artifacts,Expected,ReplayOptions)),
    io:format("Replay: ~tp~n",[maps:without([input],Result)]),
    reproduced(Result),
    case Budget of
        1->publish_replay(Out,Input,Expected,Result);
        _->Min=runtime_ok(efz_semantic_replay:minimize(Input,Target,Artifacts,
                Expected,ReplayOptions,Budget-1)),
            case maps:is_key(expectation,Min) andalso maps:is_key(input,Min) of
                true->publishable_minimization(Min),publish_minimization(Out,Min,Result,Budget);
                false->stop({minimization_not_reproduced,Min})
            end
    end.

add_path(Path) ->
    case code:add_patha(filename:absname(Path)) of
        true->ok;_->fail({invalid_replay_code_path,Path})
    end.
configuration(Path) ->
    _=read_ok(efz_fs:read_bounded(Path,1048576)),
    case file:consult(Path) of
        {ok,[Config]} when is_map(Config)->Config;
        Other->fail({invalid_replay_config,Other})
    end.
budget(Text) ->
    N=try list_to_integer(Text) catch error:_->fail(invalid_replay_budget) end,
    case N>=1 andalso N=<10000 of true->N;false->fail(invalid_replay_budget) end.
constrained_layer(Layer,Max) ->
    Limits=maps:get(limits,Layer,#{}),
    case is_map(Limits) of true->ok;false->fail(invalid_replay_layer_limits) end,
    Bytes=maps:get(bytes,Limits,4096),
    case is_integer(Bytes) andalso Bytes>=0 of true->ok;false->fail(invalid_replay_layer_limits) end,
    %% Preserve the campaign's effective byte cap before the replay API checks
    %% its recorded identity. A tighter trusted config must not silently regain
    %% the finding's larger semantic envelope.
    Layer#{limits=>Limits#{bytes=>min(Bytes,Max)}}.
trusted_identity(Input,Target,Artifacts,Expected,Options) ->
    Layer=maps:get(gleam_layer,Options),
    %% The replay API uses the finding's recorded byte cap while rebuilding its
    %% context. Validate the caller's actual effective limits first, so raising
    %% a trusted campaign limit cannot be silently clamped back to that cap.
    %% This is cold preparation only; it performs no target execution.
    C=#{target=>Target,seeds=>[Input],artifacts=>Artifacts,
        max_input_bytes=>maps:get(max_input_bytes,Options),mutation_mode=>random,
        timeout=>maps:get(timeout,Options),
        coverage_backend=>maps:get(coverage_backend,Options),
        gleam_layer=>Layer#{structured_fraction=>0,oracle=>inline,feedback=>disabled}},
    case efz_config:prepare(C) of
        {ok,#{gleam_layer:=Prepared}}->
            case efz_gleam_adapter:identity(Prepared)=:=maps:get(adapter_identity,Expected) of
                true->ok;false->stop(semantic_replay_identity_mismatch)
            end;
        {error,Why}->fail({semantic_replay_configuration,Why})
    end.
require_new_output(Out) ->
    case file:read_link_info(Out) of
        {error,enoent}->ok;
        {ok,_}->fail({replay_output_exists,Out});
        Error->fail({replay_output_unavailable,Out,Error})
    end.
reproduced(#{status:=reproduced}) -> ok;
reproduced(#{status:=not_reproduced}) -> stop(not_reproduced);
reproduced(#{status:=inconclusive}=Result) -> stop({inconclusive,maps:get(reason,Result,unknown)});
reproduced(Result) -> stop({unexpected_replay_result,Result}).
publishable_minimization(#{verification:={ok,#{status:=reproduced}}}) -> ok;
publishable_minimization(#{verification:={skipped,Reason}})
  when Reason=:=budget;Reason=:=deadline -> ok;
publishable_minimization(#{verification:=Other}) -> stop({minimization_verification,Other}).

new_output(Out) ->
    ok=filelib:ensure_dir(filename:join(filename:dirname(Out),".replay-parent")),
    case file:make_dir(Out) of ok->ok;Error->fail({cannot_create_replay_output,Out,Error}) end.
publish_replay(Out,Input,Expected,Replay) ->
    new_output(Out),
    ok=efz_fs:atomic_file(filename:join(Out,"replay.input"),Input),
    ok=efz_fs:atomic_file(filename:join(Out,"replay.semantic"),efz_semantic_replay:encode(Expected)),
    ok=efz_fs:atomic_file(filename:join(Out,"replay.term"),
        term_to_binary(Replay#{budget=>1,total_target_executions=>1})),
    io:format("Reproduced; budget exhausted before minimization. Output: ~ts~n",[Out]).
publish_minimization(Out,Min,Replay,Budget) ->
    Total=maps:get(target_executions,Replay)+maps:get(target_executions,Min),
    case Total=<Budget of true->ok;false->stop(replay_execution_budget_exceeded) end,
    new_output(Out),
    ok=efz_fs:atomic_file(filename:join(Out,"minimized.input"),maps:get(input,Min)),
    ok=efz_fs:atomic_file(filename:join(Out,"minimized.semantic"),
        efz_semantic_replay:encode(maps:get(expectation,Min))),
    ok=efz_fs:atomic_file(filename:join(Out,"minimization.term"),
        term_to_binary(Min#{workflow_budget=>Budget,total_target_executions=>Total})),
    ok=efz_fs:atomic_file(filename:join(Out,"replay.term"),term_to_binary(Replay)),
    io:format("Minimization: ~p executions, ~tp; workflow total ~p/~p. Output: ~ts~n",
        [maps:get(target_executions,Min),maps:get(status,Min),Total,Budget,Out]).
read_ok({ok,Value}) -> Value;
read_ok({error,Reason}) -> fail(Reason).
runtime_ok({ok,Value}) -> Value;
runtime_ok({error,Reason}) -> stop(Reason).
fail(Reason) -> throw({replay_cli,2,Reason}).
stop(Reason) -> throw({replay_cli,1,Reason}).

%% Historical source/artifact choices live only in this explicit legacy helper.
legacy(Args) ->
    Helper=filename:join(filename:dirname(filename:absname(escript:script_name())),
        "gleam_replay_legacy.escript"),
    case os:find_executable("escript") of
        false->io:format(standard_error,"escript executable unavailable~n"),halt(2);
        Exe->Port=open_port({spawn_executable,Exe},[binary,exit_status,use_stdio,
            stderr_to_stdout,{args,[Helper|Args]}]),legacy_output(Port)
    end.
legacy_output(Port) -> receive
    {Port,{data,Data}}->io:put_chars(Data),legacy_output(Port);
    {Port,{exit_status,Status}}->halt(Status)
end.
