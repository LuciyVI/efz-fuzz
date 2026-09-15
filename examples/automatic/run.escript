#!/usr/bin/env escript
%% Run from repository root after rebar3 compile.
main(_) ->
    true = code:add_patha("_build/default/lib/efz/ebin"),
    {ok, Artifact} = efz_instrument:compile("examples/simple_parser/efz_example_parser.erl",
        #{modules => [efz_example_parser], source_root => ".", outdir => "_build/instrumented-example"}),
    {ok, _} = efz:start(#{target => efz_example_target, artifacts => [Artifact],
        seeds => [<<0>>], max_iterations => 500, timeout => 100,
        random_seed => {17, 23, 41}, crash_dir => "_build/example-crashes"}),
    Report = efz:await(30000),
    io:format("~p~n", [Report]),
    ok = file:write_file("_build/example-report.term", term_to_binary(Report)),
    ok = efz:stop().
