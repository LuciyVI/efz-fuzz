%% Public plugin contract. All target execution remains owned by EFZ.
-module(efz_semantic_adapter).
-export_type([property/0, capability/0]).
-type property() :: {atom() | binary(), pos_integer()}.
-type capability() :: generation | mutation | observation | oracle | shrink.
-callback descriptor() -> map().
-callback prepare(module(), map(), map()) -> {ok, term()} | {error, term()}.
-callback code_dependencies(term()) -> #{semantic := [module()], target := [module()]}.
-callback generate(non_neg_integer(), term()) -> {ok, binary()} | {skip, atom()} | {error, term()}.
-callback mutate(binary(), non_neg_integer(), map(), term()) ->
    {ok, binary(), map()} | {skip, atom()} | {error, term()}.
-callback observe(binary(), term(), term()) -> {ok, [0..255]} | {skip, atom()} | {error, term()}.
-callback oracle(binary(), term(), term()) ->
    {pass, property()} | {fail, property()} | {inconclusive, atom()} | {error, term()}.
-callback shrink(binary(), term()) -> {ok, [binary()]} | {skip, atom()} | {error, term()}.
-optional_callbacks([code_dependencies/1, generate/2, mutate/4, observe/3, oracle/3, shrink/2]).
