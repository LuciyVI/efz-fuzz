-module(efz_coverage_SUITE).
-export([all/0, init_per_suite/1, end_per_suite/1,
         automatic_campaign/1, crash_coverage/1, timeout_coverage/1]).

all() -> [automatic_campaign, crash_coverage, timeout_coverage].
init_per_suite(Config) ->
    Source = proplists:get_value(source, ?MODULE:module_info(compile)),
    Root = filename:dirname(filename:dirname(Source)),
    Out = proplists:get_value(priv_dir, Config),
    Parser = build(Root, "examples/simple_parser/efz_example_parser.erl", efz_example_parser, Out),
    Fixture = build(Root, "fixtures/efz_fixture.erl", efz_fixture, Out),
    {ok, Ms} = efz_instrument:preflight([Parser, Fixture]),
    [{parser, Parser}, {coverage, #{coverage => automatic, manifests => Ms}} | Config].
build(Root, Relative, M, Out) ->
    {ok, A} = efz_instrument:compile(filename:join(Root, Relative),
        #{modules => [M], source_root => Root, outdir => Out,
          erl_opts => [debug_info, warnings_as_errors,
                       {i, filename:join(Root, "fixtures/include")}, {d, 'MAGIC', 42}]}), A.
end_per_suite(_) ->
    efz:stop(),
    lists:foreach(fun(M) -> code:purge(M), code:delete(M), code:purge(M) end,
                  [efz_example_parser, efz_fixture]), ok.
automatic_campaign(Config) ->
    {ok, _} = efz:start(#{target => efz_example_target, seeds => [<<0>>],
        artifacts => [proplists:get_value(parser, Config)], mutator => efz_scripted_mutator,
        max_iterations => 5, crash_dir => filename:join(proplists:get_value(priv_dir, Config), "crashes")}),
    try
        #{status := completed, stats := #{calibrations := 1, executions := 5, discoveries := 2,
                                          crashes := 1, rejections := 2}, corpus := Corpus} = efz:await(5000),
        3 = length(Corpus), ok
    after efz:stop() end.
crash_coverage(Config) ->
    Opts = proplists:get_value(coverage, Config),
    #{outcome := {crash, error, artificial_example_exception, _},
      coverage_status := ok, coverage := [_ | _]} = efz_executor:run(efz_example_target, <<255>>, 1000, Opts), ok.
timeout_coverage(Config) ->
    Parent = self(), Opts = proplists:get_value(coverage, Config),
    {Caller, Monitor} = spawn_monitor(fun() ->
        Parent ! {done, efz_executor:run(efz_fixture, {wait, Parent}, 500, Opts)}
    end),
    Target = receive {probe_recorded, P} -> P after 2000 -> error(no_synchronized_probe) end,
    receive {done, #{outcome := {timeout, 500}, coverage_status := ok, coverage := [_ | _]}} -> ok
    after 3000 -> error(no_final_coverage) end,
    receive {'DOWN', Monitor, process, Caller, normal} -> ok end,
    false = is_process_alive(Target), ok.
