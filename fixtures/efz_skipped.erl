-module(efz_skipped).
-feature(maybe_expr, enable).
-export([run/1]).
run({list, Xs}) -> [case X of 0 -> zero; _ -> other end || X <- Xs];
run({binary, Xs}) -> << <<X>> || X <- Xs >>;
run({map, Xs}) -> #{X => X + 1 || X <- Xs};
run({maybe_it, X}) -> maybe {ok, N} ?= X, N + 1 else _ -> no end.
