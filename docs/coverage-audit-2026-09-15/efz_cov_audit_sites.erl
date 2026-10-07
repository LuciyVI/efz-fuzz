%% Ordinary source: only these four functions are automatically instrumented.
-module(efz_cov_audit_sites).
-export([a/0,b/0,c/0,x/0]).
a() -> a.
b() -> b.
c() -> c.
%% Independent witness of invocation multiplicity, not a coverage hook/counter.
%% The uninstrumented harness initializes this target-local diagnostic field.
x() -> put(audit_x_calls,get(audit_x_calls)+1), x.
