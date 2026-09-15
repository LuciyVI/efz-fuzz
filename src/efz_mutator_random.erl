-module(efz_mutator_random).
-behaviour(efz_mutator).
-export([mutate/2]).
mutate(B, #{seed:=Seed}=Opts)->_ = rand:seed(exsplus,Seed), mutate(B,maps:remove(seed,Opts));
mutate(B,Opts)->
 Max=maps:get(max_input_bytes,Opts,efz_input:default_limit()),
 case efz_input:check(B,Max,random_primary) of
  ok->mutate_bounded(B,Max);
  {error,Why}->error({input_limit,Why})
 end.
mutate_bounded(<<>>,0)-><<>>;
mutate_bounded(<<>>,_)-><<0>>;
mutate_bounded(B,Max)->
 N=byte_size(B), Choice=rand:uniform(4),
 %% A full input can be overwritten, flipped or shrunk. Never truncate a
 %% generated input: choose an applicable operation before producing bytes.
 Op=case Choice=:=3 andalso N=:=Max of true->2;false->Choice end,
 Pos=rand:uniform(N), L=binary_to_list(B), I=Pos-1,
 case Op of
  1 -> list_to_binary(lists:sublist(L,I) ++ [lists:nth(Pos,L) bxor (1 bsl (rand:uniform(8)-1))] ++ lists:nthtail(Pos,L));
  2 -> list_to_binary(lists:sublist(L,I) ++ [rand:uniform(256)-1] ++ lists:nthtail(Pos,L));
  3 -> list_to_binary(lists:sublist(L,I) ++ [rand:uniform(256)-1] ++ lists:nthtail(I,L));
  4 -> list_to_binary(lists:sublist(L,I) ++ lists:nthtail(Pos,L))
 end.
