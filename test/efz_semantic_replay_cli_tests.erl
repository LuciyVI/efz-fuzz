-module(efz_semantic_replay_cli_tests).
-include_lib("eunit/include/eunit.hrl").

replay_cli_test_()->{timeout,60,fun replay_cli/0}.
replay_cli()->
    D=filename:absname("_build/replay-cli-"++integer_to_list(erlang:system_time(microsecond))),
    ok=filelib:ensure_dir(D++"/placeholder"),
    Raw= <<4:16,"abcd">>,
    Layer=#{adapter=>efz_plugin_oracle_adapter,adapter_options=>#{fail=>true},
        structured_fraction=>0,oracle=>inline},
    C=#{target=>efz_plugin_length_target,seeds=>[Raw],coverage_backend=>none,
        max_iterations=>0,timeout=>1000,gleam_layer=>Layer,crash_dir=>D++"/findings"},
    R=try {ok,_}=efz:start(C),efz:await(5000) after efz:stop() end,
    [Finding]=maps:get(crashes,R),Prefix=maps:get(path,Finding),
    Config=D++"/campaign.term",ok=file:write_file(Config,io_lib:format("~tp.~n",[C])),
    Args=["--config",Config,"--finding",Prefix,"--code-path",
        filename:dirname(code:which(efz_plugin_oracle_adapter))],
    {0,_}=cli(Args++["--budget","1","--out",D++"/one"]),
    One=read_term(D++"/one/replay.term"),?assertEqual(1,maps:get(total_target_executions,One)),
    ?assertEqual({ok,Raw},file:read_file(D++"/one/replay.input")),
    {0,_}=cli(Args++["--budget","16","--out",D++"/min"]),
    Min=read_term(D++"/min/minimization.term"),
    ?assert(maps:get(total_target_executions,Min)=<16),
    ?assert(byte_size(maps:get(input,Min))<byte_size(Raw)),
    ?assertMatch({ok,#{status:=reproduced}},maps:get(verification,Min)),
    {2,_}=cli(Args++["--budget","0","--out",D++"/invalid"]),
    ?assertNot(filelib:is_dir(D++"/invalid")),
    {2,_}=cli(Args++["--budget","1","--out",D++"/one"]),
    ?assertEqual({ok,Raw},file:read_file(D++"/one/replay.input")),
    {ok,Bytes}=file:read_file(Prefix++".input"),ok=file:write_file(Prefix++".input",<<Bytes/binary,0>>),
    {1,_}=cli(Args++["--budget","1","--out",D++"/corrupt"]),
    ?assertNot(filelib:is_dir(D++"/corrupt")),
    ok=file:write_file(Prefix++".input",Bytes),
    {0,_}=cli(["--help"]),
    %% Five positional arguments must actually forward to the legacy helper.
    {Status,Output}=cli([D++"/missing",D,"efz_qs_target","1",D++"/legacy"]),
    ?assert(Status=/=0),
    ?assertNotEqual(nomatch,binary:match(Output,<<"gleam_replay_legacy.escript">>)).

legacy_success_test_()->case code:which(efz_qs_model) of
    non_existing->[];
    _->{timeout,60,fun legacy_success/0}
end.
legacy_success()->
    D=filename:absname("_build/replay-legacy-"++integer_to_list(erlang:system_time(microsecond))),
    ok=filelib:ensure_dir(D++"/placeholder"),
    Source=filename:absname("test/efz_qs_defect_target.erl"),
    {ok,efz_qs_defect_target,Beam}=compile:file(Source,[binary,debug_info]),
    Original=code:get_object_code(efz_qs_defect_target),
    code:purge(efz_qs_defect_target),code:delete(efz_qs_defect_target),
    {module,efz_qs_defect_target}=code:load_binary(efz_qs_defect_target,"explicit_artificial_fixture",Beam),
    try
        Cow=filename:absname("_build/default/lib/cowlib/src/cow_qs.erl"),
        {ok,A}=efz_cov_native_public:compile(Cow,D++"/native",[filename:dirname(Cow)++"/../include"]),
        C=#{target=>efz_qs_defect_target,seeds=>[<<"bug=11&x=2">>],artifacts=>[A],
            coverage_backend=>otp_native_public,max_iterations=>0,timeout=>1000,
            crash_dir=>D++"/findings",gleam_layer=>#{structured_fraction=>0,oracle=>inline}},
        R=try {ok,_}=efz:start(C),efz:await(5000) after efz:stop() end,
        [Finding]=maps:get(crashes,R),Prefix=maps:get(path,Finding),
        %% Diagnostics are optional and must not block portable replay.
        ok=file:delete(Prefix++".term"),
        {Status,Output}=cli([Prefix,D++"/native","efz_qs_defect_target","32",D++"/out"]),
        ok=file:write_file(D++"/legacy-output.log",Output),
        ?assertEqual({0,true},{Status,binary:match(Output,<<"Minimization:">>)=/=nomatch}),
        Min=read_term(D++"/out/minimization.term"),
        ?assertMatch({ok,#{status:=reproduced}},maps:get(verification,Min)),
        ?assert(maps:get(target_executions,Min)=<32)
    after
        code:purge(efz_qs_defect_target),code:delete(efz_qs_defect_target),
        case Original of {efz_qs_defect_target,B,F}->code:load_binary(efz_qs_defect_target,F,B);_->ok end
    end.

read_term(Path)->{ok,B}=file:read_file(Path),binary_to_term(B). %% Trusted output of the test-owned subprocess.
cli(Args)->
    Exe=os:find_executable("escript"),
    Port=open_port({spawn_executable,Exe},[binary,exit_status,use_stdio,stderr_to_stdout,
        {args,["scripts/gleam_replay.escript"|Args]}]),
    collect(Port,<<>>).
collect(Port,B)->receive
    {Port,{data,D}}->collect(Port,<<B/binary,D/binary>>);
    {Port,{exit_status,S}}->{S,B}
    after 20000->port_close(Port),error(replay_cli_timeout)
end.
