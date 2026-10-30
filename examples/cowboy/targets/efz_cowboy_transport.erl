%% In-memory Ranch transport for one HTTP/1 request. No listener or socket.
-module(efz_cowboy_transport).
-export([name/0, secure/0, peername/1, sockname/1, messages/0,
         setopts/2, send/2, shutdown/2]).

name() -> tcp.
secure() -> false.
peername(_) -> {ok, {{127,0,0,1}, 12345}}.
sockname(_) -> {ok, {{127,0,0,1}, 80}}.
messages() -> {cowboy_bench_data, cowboy_bench_closed,
               cowboy_bench_error, cowboy_bench_passive}.
setopts(_, _) -> ok.
send(_, _) -> ok.
shutdown(_, _) -> ok.
