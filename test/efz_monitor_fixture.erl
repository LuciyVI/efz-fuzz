-module(efz_monitor_fixture).
-export([run/1]).
run(<<0>>)->zero;
run(<<1>>)->one;
run(_)->other.
