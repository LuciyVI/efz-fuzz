%% Diagnostic harness only. The measured library and coverage domain are cow_qs.
-module(efz_benchmark_erlamsa_target).
-export([run/1, semantic_contract/0]).

semantic_contract() -> #{kind => query_string, outcome => accepted_pairs}.

run(Input) ->
    Result = efz_qs_target:run(Input),
    Kind = case Result of {accepted, _} -> accepted; rejected -> rejected end,
    case whereis(efz_erlamsa_benchmark_collector) of
        undefined -> ok;
        Collector -> Collector ! {benchmark_decode, Kind, byte_size(Input)}
    end,
    Result.
