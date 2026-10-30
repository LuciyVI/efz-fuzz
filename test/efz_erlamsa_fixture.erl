%% A bounded synthetic manual-coverage fixture, used only for lifecycle tests.
%% Each first-byte value is an explicit diagnostic point, not target code coverage.
-module(efz_erlamsa_fixture).
-export([run/1]).
run(<<First,_/binary>>=Input)->
    efz_cov:hit({first_byte,First}),
    {accepted,byte_size(Input)};
run(<<>>)->efz_cov:hit(empty),{accepted,0}.
