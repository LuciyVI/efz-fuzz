-module(efz_external_tests).
-include_lib("eunit/include/eunit.hrl").
legacy_gate_test()->
    ?assertEqual(ok,efz_external_worker:ready()),
    ?assertEqual(false,efz_external_worker:quarantined(<<>>)),
    ?assertEqual(unchanged,efz_external_worker:execution(<<>>,10,#{},fun()->unchanged end)).
