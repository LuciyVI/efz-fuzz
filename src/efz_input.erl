%% One byte limit for campaign ingestion, execution and replay. Never truncate.
-module(efz_input).
-export([default_limit/0, hard_limit/0, valid_limit/1, check/3, read_file/3]).

default_limit() -> 4096.
hard_limit() -> 1048576.
valid_limit(N) -> is_integer(N) andalso N >= 0 andalso N =< hard_limit().
check(B, Max, Operation) ->
    case {valid_limit(Max), is_binary(B)} of
        {false, _} -> {error, #{kind => input_limit, operation => Operation, reason => invalid_limit,
                               max_input_bytes => Max}};
        {true, false} -> {error, #{kind => input_limit, operation => Operation, reason => nonbinary_input}};
        {true, true} when byte_size(B) =< Max -> ok;
        {true, true} -> {error, #{kind => input_limit, operation => Operation, reason => input_too_large,
                                 input_bytes => byte_size(B), max_input_bytes => Max,
                                 input_hash => crypto:hash(sha256, B)}}
    end.

%% Bounded read: do not allocate an arbitrarily large seed/replay file. The
%% prefix is never returned as input and its hash is never called a content ID.
read_file(Path, Max, Operation) ->
    case valid_limit(Max) of
        false -> check(<<>>, Max, Operation);
        true -> case efz_fs:read_bounded(Path, Max) of
            {error, #{reason := file_size_limit} = E} ->
                {error, E#{kind => input_limit, operation => Operation, reason => input_too_large,
                           max_input_bytes => Max, input_bytes_at_least => Max + 1}};
            Result -> Result
        end
    end.
