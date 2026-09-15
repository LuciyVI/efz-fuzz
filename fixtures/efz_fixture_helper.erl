-module(efz_fixture_helper).
-export([classify/1]).
classify(0) -> helper_zero;
classify(_) -> helper_other.
