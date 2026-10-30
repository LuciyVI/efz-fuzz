%% A synchronous stream sink: Cowboy still parses request framing and body.
-module(efz_cowboy_stream).
-behaviour(cowboy_stream).
-export([init/3, data/4, info/3, terminate/3, early_error/5]).

init(_, Req, Opts) ->
    try
        case cowboy_router:execute(Req, maps:get(env, Opts)) of
            {stop, _} ->
                put(efz_cowboy_bench_result, rejected),
                {[stop], done};
            {ok, Routed, _} ->
                _ = cowboy_req:method(Routed),
                _ = cowboy_req:parse_qs(Routed),
                _ = cowboy_req:body_length(Routed),
                case cowboy_req:has_body(Routed) of
                    true -> {[], {body, 0}};
                    false -> put(efz_cowboy_bench_result, {accepted, 0}),
                             {[{response, 204, #{}, <<>>}, stop], done}
                end
        end
    catch
        _:{request_error, _, _} ->
            put(efz_cowboy_bench_result, rejected),
            {[{response, 400, #{}, <<>>}, stop], done};
        Class:Reason:Stack ->
            put(efz_cowboy_bench_result, {unexpected, Class, Reason, Stack}),
            {[{response, 500, #{}, <<>>}, stop], done}
    end.

data(_, IsFin, Body, {body, N}) ->
    Total = N + byte_size(Body),
    case IsFin of
        fin -> put(efz_cowboy_bench_result, {accepted, Total}),
               {[{response, 204, #{}, <<>>}, stop], done};
        nofin -> {[], {body, Total}}
    end;
data(_, _, _, State) -> {[], State}.
info(_, _, State) -> {[], State}.
terminate(_, _, _) -> ok.
early_error(_, _, _, Response, _) -> Response.
