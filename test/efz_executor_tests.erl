-module(efz_executor_tests). -include_lib("eunit/include/eunit.hrl").
-export([run/1]). run(<<"ok">>)->ok; run(<<"crash">>)->erlang:error(bad); run(<<"exit">>)->exit(bad); run(<<"sleep">>)->timer:sleep(100),ok.
executor_test_()->[?_assertEqual({ok,ok},efz_executor:run(?MODULE,<<"ok">>,50)),?_assertMatch({crash,_,_,_},efz_executor:run(?MODULE,<<"crash">>,50)),?_assertMatch({exit,_},efz_executor:run(?MODULE,<<"exit">>,50)),?_assertEqual({timeout,10},efz_executor:run(?MODULE,<<"sleep">>,10))].
