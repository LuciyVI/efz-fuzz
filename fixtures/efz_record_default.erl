-module(efz_record_default).
-export([run/1]).
-record(r, {value = case get(value) of undefined -> unset; _ -> set end}).
run(V) -> put(value, V), (#r{})#r.value.
