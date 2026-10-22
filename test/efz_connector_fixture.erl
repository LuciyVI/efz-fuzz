-module(efz_connector_fixture).
-export([combine/2, strings/2, union/1, broad/1, recursive/1, overloaded/1]).
-type label() :: red | green | blue.
-type pair(T) :: {T, 1..9}.
-type nested_pair() :: pair(pair(label())).
-type recursive() :: {integer(), recursive()}.
-spec combine(nested_pair(), [0..255]) -> term().
combine(A, B) -> {A, B}.
-spec strings(binary(), nonempty_string()) -> term().
strings(A, B) -> {A, B}.
-spec union(integer() | binary()) -> term().
union(A) -> A.
-spec broad(term()) -> term().
broad(A) -> A.
-spec recursive(recursive()) -> term().
recursive(A) -> A.
-spec overloaded(integer()) -> integer(); (binary()) -> binary().
overloaded(A) -> A.
