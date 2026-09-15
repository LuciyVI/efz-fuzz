-module(efz_cowboy_target).
-behaviour(efz_target).
-export([run/1]).

-spec run(binary()) -> {ok, [{binary(), binary() | true}]} | {invalid, atom()}.
run(Input) when is_binary(Input) ->
    try cowboy_req:parse_qs(#{qs => Input}) of
        Pairs -> {ok, Pairs}
    catch
        exit:{request_error, Reason, _} when Reason =:= qs; Reason =:= limit_reached ->
            {invalid, Reason}
    end.
