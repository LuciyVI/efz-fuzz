%%%-------------------------------------------------------------------
%% @doc efz public API
%% @end
%%%-------------------------------------------------------------------

-module(efz_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    efz_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
