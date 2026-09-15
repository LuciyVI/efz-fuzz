%% Filesystem failures are values. A close/cleanup error must never replace the
%% primary failure. Publication uses same-filesystem rename and directory fsync.
-module(efz_fs).
-include_lib("kernel/include/file.hrl").
-export([atomic_file/2, atomic_group/3, validate_group/1, read_bounded/2, directory/1, write_file/2, sync_directory/1]).

directory(Dir) -> protect(fun() -> ensure_directory(Dir) end).
write_file(Path, Bytes) -> protect(fun() -> write_synced(Path,Bytes) end).
sync_directory(Dir) -> protect(fun() -> sync_dir(Dir) end).

atomic_file(Path0, Bytes) -> protect(fun() ->
    Path = filename:absname(Path0), Dir = filename:dirname(Path),
    ensure_directory(Dir), Temp = filename:join(Dir, temporary_name()),
    staged(Temp, fun() ->
        write_synced(Temp, Bytes),
        need(file:rename(Temp, Path), rename, Path), sync_dir(Dir), ok
    end, fun() -> file:delete(Temp) end)
end).

%% Immutable group keyed by caller-supplied publication identity. The first file
%% is the identity payload (crash input). Repeated publication validates ALL
%% committed files against their manifest and that payload before deduplicating.
atomic_group(Dir0, Name, Files = [{IdentityFile, IdentityBytes} | _]) -> protect(fun() ->
    Dir = filename:absname(Dir0), Dest = filename:join(Dir, Name),
    ensure_directory(Dir), Temp = filename:join(Dir, temporary_name()),
    need(file:make_dir(Temp), make_dir, Temp),
    staged(Temp, fun() ->
        lists:foreach(fun({File, B}) -> write_synced(filename:join(Temp, File), B) end, Files),
        Manifest = [{File, byte_size(B), crypto:hash(sha256, B)} || {File, B} <- Files],
        write_synced(filename:join(Temp, "manifest"), term_to_binary({efz_artifacts, 1, Manifest})),
        sync_dir(Temp),
        case file:rename(Temp, Dest) of
            ok -> ok;
            {error, Why} when Why =:= eexist; Why =:= enotempty ->
                verify_group(Dest, IdentityFile, IdentityBytes),
                need(file:del_dir_r(Temp), remove_staging, Temp);
            {error, Why} -> fail(rename, Dest, Why)
        end,
        sync_dir(Dir), {ok, Dest}
    end, fun() -> file:del_dir_r(Temp) end)
end).

validate_group(Dir) -> protect(fun()->
    Input=need(read_bounded(filename:join(Dir,"artifact.input"),efz_input:hard_limit()),read_input,Dir),
    verify_group(Dir,"artifact.input",Input)
end).
verify_group(Dir, IdentityFile, IdentityBytes) ->
    Path = filename:join(Dir, "manifest"),
    Encoded = need(read_bounded(Path, 8192), read_manifest, Path),
    Manifest = try
        {efz_artifacts, 1, Ms} = binary_to_term(Encoded, [safe]),
        true = is_list(Ms) andalso length(Ms) >= 2 andalso length(Ms) =< 4,
        true = lists:all(fun({F,N,H}) ->
            lists:member(F, ["artifact.input", "artifact.term", "artifact.recipe", "artifact.replay"]) andalso
            is_integer(N) andalso N >= 0 andalso is_binary(H) andalso byte_size(H) =:= 32;
            (_) -> false end, Ms),
        true = length(Ms) =:= length(lists:usort([F || {F,_,_} <- Ms])),
        true = lists:keymember("artifact.term", 1, Ms),
        Ms
    catch error:_ -> fail(validate_group, Path, invalid_artifact_manifest) end,
    case lists:keyfind(IdentityFile, 1, Manifest) of
        {IdentityFile, N, H} when N =:= byte_size(IdentityBytes) ->
            case H =:= crypto:hash(sha256, IdentityBytes) of
                true -> ok; false -> fail(validate_group, Path, artifact_identity_mismatch)
            end;
        _ -> fail(validate_group, Path, artifact_identity_mismatch)
    end,
    lists:foreach(fun({F,N,H}) ->
        P = filename:join(Dir,F),
        %% Never allocate a manifest-controlled byte count during validation.
        case digest_file(P) =:= {N,H} of
            true -> ok; false -> fail(validate_group,P,artifact_checksum_mismatch)
        end
    end, Manifest).
digest_file(Path) ->
    F = need(file:open(Path,[read,raw,binary]),open,Path),
    with_file(F,Path,fun()->digest_chunks(F,Path,0,crypto:hash_init(sha256)) end).
digest_chunks(F,Path,N,Hash) ->
    case file:read(F,65536) of
        eof -> {N,crypto:hash_final(Hash)};
        {ok,B} -> digest_chunks(F,Path,N+byte_size(B),crypto:hash_update(Hash,B));
        {error, Why} -> fail(read,Path,Why)
    end.

read_bounded(Path, Max) -> protect(fun() ->
    F = need(file:open(Path, [read, raw, binary]), open, Path),
    with_file(F, Path, fun() ->
        case file:read(F, Max + 1) of
            eof -> {ok, <<>>};
            {ok, B} when byte_size(B) =< Max -> {ok, B};
            {ok, _} -> fail(read, Path, file_size_limit);
            {error, Why} -> fail(read, Path, Why)
        end
    end)
end).

ensure_directory(Dir) ->
    case file:read_file_info(Dir) of
        {ok, #file_info{type = directory}} -> ok;
        {error, enoent} ->
            Parent = filename:dirname(Dir), ensure_directory(Parent),
            case file:make_dir(Dir) of ok -> ok; {error,eexist} -> ensure_directory(Dir);
                {error, Why} -> fail(make_dir, Dir, Why) end,
            sync_dir(Parent);
        {ok, _} -> fail(make_dir, Dir, enotdir);
        {error, Why} -> fail(stat, Dir, Why)
    end.
write_synced(Path, Bytes) ->
    F = need(file:open(Path, [write, raw, binary, exclusive]), open, Path),
    with_file(F, Path, fun() ->
        need(file:write(F,Bytes), write, Path), need(file:sync(F), fsync, Path)
    end).
sync_dir(Dir) ->
    F = need(file:open(Dir, [read, raw, directory]), open_directory, Dir),
    with_file(F, Dir, fun() -> need(file:sync(F), fsync_directory, Dir) end).
with_file(F, Path, Fun) ->
    Result = protect(Fun), Close = file:close(F),
    case Result of
        {error, E} -> throw({filesystem, secondary(E, close_error, Close)});
        _ -> need(Close, close, Path), Result
    end.
staged(Temp, Fun, Cleanup) ->
    case protect(Fun) of
        {error, E} ->
            Clean = case Cleanup() of {error,enoent} -> ok; X -> X end,
            throw({filesystem, secondary(E#{staging_path=>Temp}, cleanup_error, Clean)});
        R -> R
    end.
secondary(E, _, ok) -> E;
secondary(E, K, Error) -> E#{K => Error}.
temporary_name() -> ".tmp-" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(16), lowercase)).
need(ok, _, _) -> ok;
need({ok, V}, _, _) -> V;
need({error, E}, _, _) when is_map(E) -> throw({filesystem, E});
need({error, Why}, Op, Path) -> fail(Op, Path, Why).
-spec fail(atom(), file:filename_all(), term()) -> no_return().
fail(Op, Path, Why) -> throw({filesystem, #{kind => filesystem, operation => Op, path => Path, reason => Why}}).
protect(F) -> try F() catch throw:{filesystem, E} -> {error, E} end.
