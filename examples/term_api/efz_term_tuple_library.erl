-module(efz_term_tuple_library).
-export([combine/2]).

-type key() :: a | b.
-spec combine(#{key() => integer()}, {key(), integer()}) ->
    {integer(), non_neg_integer(), {key(), integer()}}.
combine(Map,{Key,Default}) ->
    {maps:get(Key,Map,Default),maps:size(Map),{Key,Default}}.
