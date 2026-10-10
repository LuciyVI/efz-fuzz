#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).
main([Prefix,ArtifactDir,TargetName,BudgetText,Out])->
    Root=filename:dirname(filename:dirname(filename:absname(escript:script_name()))),
    true=code:add_patha(filename:join([Root,"_build","gleam","lib","efz","ebin"])),
    true=code:add_patha(filename:join([Root,"_build","default","lib","cowlib","ebin"])),
    Target=case TargetName of
        "efz_qs_target"->efz_qs_target;
        "efz_qs_defect_target"->
            {ok,efz_qs_defect_target,Beam}=compile:file(filename:join([Root,"test","efz_qs_defect_target.erl"]),[binary,debug_info]),
            {module,efz_qs_defect_target}=code:load_binary(efz_qs_defect_target,"explicit_artificial_fixture",Beam),
            efz_qs_defect_target
    end,
    {ok,E}=efz_semantic_replay:load(Prefix++".semantic"),
    {ok,B}=efz_input:read_file(Prefix++".input",maps:get(max_input_bytes,E),semantic_replay),
    Path=filename:join(ArtifactDir,"cow_qs.beam"),{ok,Raw}=file:read_file(Path),
    {ok,{cow_qs,MD5}}=beam_lib:md5(Raw),
    A=#{module=>cow_qs,beam=>filename:absname(Path),beam_md5=>MD5,
        build_id=>crypto:hash(sha256,Raw),coverage_kind=>otp_native_line},
    Budget=list_to_integer(BudgetText),
    O=#{timeout=>1000,coverage_backend=>otp_native_public,max_input_bytes=>maps:get(max_input_bytes,E)},
    {ok,Replay}=efz_semantic_replay:run(B,Target,[A],E,O),
    io:format("Replay: ~p~n",[Replay]),
    {ok,Min}=efz_semantic_replay:minimize(B,Target,[A],E,O,Budget),
    false=filelib:is_dir(Out),false=filelib:is_file(Out),
    ok=filelib:ensure_dir(filename:join(Out,"minimized.input")),
    ok=efz_fs:atomic_file(filename:join(Out,"minimized.input"),maps:get(input,Min)),
    ok=efz_fs:atomic_file(filename:join(Out,"minimized.semantic"),
        efz_semantic_replay:encode(maps:get(expectation,Min))),
    ok=efz_fs:atomic_file(filename:join(Out,"minimization.term"),term_to_binary(Min)),
    {ok,Payload}=efz_fs:read_bounded(Prefix++".term",67108864),
    _=code:ensure_loaded(efz_worker),Finding=binary_to_term(Payload,[safe]),Meta=maps:get(metadata,Finding),
    Info=#{schema_version=>1,input_sha256=>crypto:hash(sha256,B),input_path=>Prefix++".input",
        target=>Target,entrypoint=>{Target,run,1},expectation=>E,
        primary_outcome=>maps:get(target_original_outcome,Meta),
        normalized_failure_fingerprint=>maps:get(crash_signature,Finding),
        original_execution_id=>maps:get(execution_ref,Meta),
        layer=>maps:get(gleam_layer,Meta),recipe=>maps:get(mutation,Meta,unavailable),
        replay=>Replay,minimization=>maps:without([input],Min),diagnostics=>Prefix++".term",
        otp=>erlang:system_info(otp_release),erts=>erlang:system_info(version)},
    ok=file:write_file(filename:join(Out,"replay.json"),json:encode(portable(Info))),
    io:format("Minimization: ~p executions, ~p~n",[maps:get(target_executions,Min),maps:get(status,Min)]);
main(_)->io:format("Usage: gleam_replay.escript ARTIFACT_PREFIX NATIVE_ARTIFACT_DIR TARGET BUDGET OUTPUT_DIR\n"),halt(2).
portable(B) when is_binary(B)->binary:encode_hex(B,lowercase);
portable(T) when is_tuple(T)->[portable(X)||X<-tuple_to_list(T)];
portable(M) when is_map(M)->maps:map(fun(_,V)->portable(V) end,M);
portable(L) when is_list(L)->[portable(X)||X<-L];
portable(X) when is_reference(X)->list_to_binary(erlang:ref_to_list(X));
portable(X) when is_pid(X)->list_to_binary(pid_to_list(X));
portable(A) when A=:=true;A=:=false;A=:=null->A;
portable(A) when is_atom(A)->atom_to_binary(A,utf8);
portable(N)->N.
