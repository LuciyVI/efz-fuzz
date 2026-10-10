-module(efz_term_tuple_library).
-export([combine/2]).
combine(Map,{Key,Default}) ->
    {maps:get(Key,Map,Default),maps:size(Map),{Key,Default}}.
