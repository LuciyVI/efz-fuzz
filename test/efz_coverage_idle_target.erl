-module(efz_coverage_idle_target).
-export([run/1]).

run(<<1>>) -> efz_cov:hit(late), ok;
run(_) -> efz_cov:hit(always), ok.
