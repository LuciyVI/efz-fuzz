%% Artificial property defect, solely for finding/replay/minimizer wiring tests.
-module(efz_qs_defect_target).
-export([run/1, semantic_contract/0]).
semantic_contract() -> #{kind=>query_string,outcome=>accepted_pairs}.
run(Input)->case efz_qs_target:run(Input) of
    {accepted,[{<<"bug">>,V}|Rest]} when is_binary(V)->{accepted,[{<<"bug">>,<<V/binary,0>>}|Rest]};
    R->R end.
