%% Controlled raw provider for P4 wiring only; parent selection remains EFZ's.
-module(efz_gleam_feedback_mutator).
-behaviour(efz_mutator).
-export([mutate/2]).
mutate(<<"bug=",_/binary>>=Input,_) -> Input;
mutate(_,_) -> <<"a=",255>>.
