#!/usr/bin/env escript
-mode(compile).
main(Args) ->
    Ebin = case os:getenv("EFZ_PERF_EBIN") of false -> "_build/default/lib/efz/ebin"; P -> P end,
    true = code:add_patha(Ebin),
    {Workload, Prepared} = case Args of
        [W,"prepared"] -> {[W],true}; _ -> {Args,false}
    end,
    {Mode, M, File, Input, N} = case Workload of
        ["sparse"] -> {executor, efz_perf_sparse, "fixtures/performance/efz_perf_sparse.erl", <<0,7>>, 100};
        ["parser"] -> {executor, efz_perf_parser, "fixtures/performance/efz_perf_parser.erl", binary:copy(<<0,0,7,1,35,3,2>>, 32), 100};
        _ -> {hook, efz_bench_fixture, "fixtures/efz_bench_fixture.erl", 50000, 1}
    end,
    {ok, A} = efz_instrument:compile(File, #{modules => [M], source_root => ".", outdir => "_build/performance-profile"}),
    {ok, Ms} = efz_instrument:preflight([A]),
    Opts = case Prepared of
        true -> {ok,Plan}=efz_cov_manifest:prepare(automatic,Ms),#{coverage=>automatic,coverage_plan=>Plan};
        false -> #{coverage => automatic, manifests => Ms}
    end,
    %% Force code loading before tracing. Profile data is not throughput data.
    #{outcome := {ok, _}} = efz_executor:run(M, Input, 100, Opts),
    Work = fun() ->
        case Mode of
            hook ->
                C = efz_cov:open(), efz_cov:attach(C), _ = M:run(Input),
                {ok, [_ | _]} = efz_cov:snapshot(C), efz_cov:detach(), efz_cov:close(C);
            executor -> lists:foreach(fun(_) ->
                #{outcome := {ok, _}, coverage_status := ok} = efz_executor:run(M, Input, 100, Opts)
            end, lists:seq(1,N))
        end
    end,
    {ok, _} = eprof:profile(Work),
    ok = eprof:analyze(total, [{sort, time}]),
    stopped = eprof:stop(),
    case Opts of #{coverage_plan:=P1}->efz_cov_manifest:release(P1);_->ok end.
