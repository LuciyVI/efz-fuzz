%% Benchmark-only observer. Selected target modules have no EFZ/observer calls.
-module(efz_count_bench_harness).
-export([run/1]).
run(Input) ->
    {Target,Observer}=persistent_term:get({?MODULE,target}),
    Result=Target:run(Input),
    case Result of deep->Observer!{deep,erlang:monotonic_time(microsecond),Input};_->ok end,
    Result.
