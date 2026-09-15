-module(efz_crash_target).
-export([parse/1]).
-ifdef(ALTERNATE).
-define(BUG, changed_parser_failure).
-else.
-define(BUG, parser_failure).
-endif.
parse(<<"OK">>) -> ok;
parse(<<"WAIT">>) ->
    whereis(efz_crash_observer)!{ready,self()},receive continue->error(wait_crash) end;
parse(B) when is_binary(B) -> error({?BUG,B}).
