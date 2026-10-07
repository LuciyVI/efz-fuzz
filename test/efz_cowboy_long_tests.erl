-module(efz_cowboy_long_tests).
-include_lib("eunit/include/eunit.hrl").

cowboy_raw_http_test_() ->
    {setup, fun setup/0, fun teardown/1, fun(_) ->
        Dir = "test/targets/cowboy/seeds",
        {ok, Names} = file:list_dir(Dir),
        Expected = #{"03-post-length.http" => {ok,{accepted,5}},
                     "08-malformed-line.http" => {ok,rejected},
                     "09-malformed-header.http" => {ok,rejected},
                     "11-chunked.http" => {ok,{accepted,4}}},
        [?_test(begin
            {ok, Input} = file:read_file(filename:join(Dir, Name)),
            ?assertEqual(maps:get(Name,Expected,{ok,{accepted,0}}),
                         efz_cowboy_long_target:run(Input)),
            ?assertEqual(undefined, get(efz_cowboy_bench_result)),
            ?assertEqual(0, mailbox_len())
        end) || Name <- lists:sort(Names)]
    end}.

setup() ->
    lists:foreach(fun(M) ->
        Src = filename:join("test/targets/cowboy", atom_to_list(M) ++ ".erl"),
        {ok,M,Beam} = compile:noenv_file(Src,[binary,debug_info,warnings_as_errors]),
        {module,M} = code:load_binary(M,Src,Beam)
    end, [efz_cowboy_transport,efz_cowboy_stream,efz_cowboy_long_target]),
    efz_cowboy_long_target:setup().
teardown(_) -> efz_cowboy_long_target:teardown().
mailbox_len() -> {message_queue_len,N} = process_info(self(),message_queue_len), N.
