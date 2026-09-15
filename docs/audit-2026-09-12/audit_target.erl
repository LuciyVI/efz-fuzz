-module(audit_target).
-export([parse/1]).
parse(<<"A">>) -> path_a;
parse(<<"AB">>) -> path_ab;
parse(<<"ABC">>) -> path_abc;
parse(<<"CRASH">>) -> error(test_crash);
parse(_) -> unknown.
