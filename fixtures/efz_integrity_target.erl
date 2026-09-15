-module(efz_integrity_target).
-export([parse/1]).
-ifdef(ALTERNATE).
-define(A_VALUE, alternate).
-else.
-define(A_VALUE, a).
-endif.
parse(<<"A">>) -> ?A_VALUE;
parse(<<"B">>) -> b.
