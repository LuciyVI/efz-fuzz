%% Benchmark-only prerecorded candidate stream; not a production mutator.
-module(efz_perf_replay).
-export([mutate/2, install/1, clear/0]).
install(Inputs) -> persistent_term:put({?MODULE, candidates}, list_to_tuple(Inputs)).
clear() -> persistent_term:erase({?MODULE, candidates}), ok.
mutate(_, #{iteration := N}) ->
    T = persistent_term:get({?MODULE, candidates}),
    element(1 + ((N - 1) rem tuple_size(T)), T).
