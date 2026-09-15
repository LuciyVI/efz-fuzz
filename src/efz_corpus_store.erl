%% Reusable inputs, not a campaign checkpoint. Published entries are immutable.
-module(efz_corpus_store).
-include_lib("kernel/include/file.hrl").
-export([identity/1, restore/3, restore/4, save/4]).
-define(MAX_META, 67108864).

identity(#{target := M, coverage := Mode, manifests := Ms}) ->
    #{target => atom_to_binary(M, utf8), callback => {<<"run">>, 1},
      target_md5 => M:module_info(md5), coverage => Mode,
      builds => efz_recipe:build_ids(maps:from_list([{maps:get(module, X), maps:get(build_id, X)} || X <- Ms]))}.

restore(Dir, Identity, Policy) -> restore(Dir, Identity, Policy, efz_input:default_limit()).
restore(Dir0, Identity, Policy, Max) -> protect(fun() ->
    check(efz_input:valid_limit(Max), invalid_max_input_bytes),
    Dir = filename:absname(Dir0),
    check(lists:member(Policy, [reject, recalibrate]), invalid_corpus_build_policy),
    valid_identity(Identity),
    Names = case file:list_dir(Dir) of
        {ok, Ns} -> lists:sort(Ns);
        {error, enoent} -> [];
        {error, Why} -> error({corpus_directory, Dir, Why})
    end,
    {Rows, Ds} = lists:foldl(fun(Name, {Acc, Diagnostics}) ->
        Path = filename:join(Dir, Name),
        case lists:prefix(".tmp-", Name) of
            true -> {Acc, [{interrupted_corpus_write, Path} | Diagnostics]};
            false ->
                check(valid_name(Name), {unexpected_corpus_entry, Path}),
                Row = load_entry(Path, Name, Max),
                D = compatible(maps:get(record, Row), Identity, Policy, Path),
                {[Row | Acc], D ++ Diagnostics}
        end
    end, {[], []}, Names),
    {ok, lists:reverse(Rows), lists:reverse(Ds)}
end).

%% Meta contains only historical discovery data. No process refs or target
%% return values enter the durable representation; recipes use their own codec.
save(#{dir := Dir, identity := Identity} = Store, Input, QueueId, Meta) -> protect(fun() ->
    ok = need(efz_input:check(Input,maps:get(max_input_bytes,Store,efz_input:default_limit()),corpus_store), input_limit),
    Hash = crypto:hash(sha256, Input), Name = hex(Hash), Path = filename:join(Dir, Name),
    Recipe = case maps:find(mutation, Meta) of
        error -> none;
        {ok, R} -> need(efz_recipe:encode(R), recipe_encoding)
    end,
    {Origin, Parent, Discovery} = case maps:get(retention_reason, Meta, initial_seed) of
        initial_seed -> {initial, none, #{new_probes => [], phase => initial}};
        new_coverage ->
            {discovery, #{content_hash => maps:get(parent_content, Meta), queue_id => maps:get(parent, Meta)},
             #{new_probes => [probe(P) || P <- maps:get(new_probes, Meta)], phase => mutation}}
    end,
    Record = #{schema_version => 1, content_hash => Hash, input_size => byte_size(Input),
               queue_id => QueueId, origin => Origin, parent => Parent,
               discovery => Discovery, identity => Identity, recipe => Recipe},
    valid_record(Record, Input),
    ensure_directory(Dir),
    case file:read_link_info(Path) of
        {error, enoent} -> publish(Store, Name, Input, Record);
        {ok, _} -> existing(Store, Path, Name, Input);
        {error, Why} -> error({corpus_entry, Path, Why})
    end
end).

publish(Store = #{dir := Dir}, Name, Input, Record) ->
    Temp = filename:join(Dir, ".tmp-" ++ hex(crypto:strong_rand_bytes(16))),
    ok = need(file:make_dir(Temp), {create_staging_directory, Temp}),
    %% On failure leave the staging directory for explicit diagnostics. A VM
    %% killed before rename likewise cannot expose a half-published entry.
    write_synced(filename:join(Temp, "input"), Input),
    Payload = term_to_binary(Record),
    check(byte_size(Payload) + 41 =< ?MAX_META, corpus_metadata_size_limit),
    Encoded = <<"EFZC", 1, (byte_size(Payload)):32, (crypto:hash(sha256, Payload))/binary, Payload/binary>>,
    write_synced(filename:join(Temp, "metadata"), Encoded),
    sync_dir(Temp),
    Dest = filename:join(Dir, Name),
    case file:rename(Temp, Dest) of
        ok -> sync_dir(Dir), {ok, Record};
        {error, Why} when Why =:= eexist; Why =:= enotempty ->
            %% Concurrent publishers of identical content cannot replace an
            %% existing nonempty entry. Validate the winner before deduplication.
            Result = existing(Store, Dest, Name, Input),
            ok = need(file:del_dir_r(Temp), {remove_duplicate_staging, Temp}),
            sync_dir(Dir), Result;
        {error, Why} -> error({publish_corpus_entry, Dest, Why})
    end.
existing(#{identity := Identity} = Store, Path, Name, Input) ->
    #{input := Input, record := Record} = load_entry(Path, Name, maps:get(max_input_bytes,Store,efz_input:default_limit())),
    _ = compatible(Record, Identity, maps:get(build_policy, Store, reject), Path),
    %% Also covers retry after rename succeeded but its parent fsync failed.
    sync_dir(filename:dirname(Path)),
    {ok, Record}.

load_entry(Path, Name, Max) ->
    check(file_type(Path) =:= directory, {invalid_corpus_entry_directory, Path}),
    InputPath = filename:join(Path,"input"),
    check(file_type(InputPath) =:= regular, {invalid_corpus_file,InputPath}),
    Input = need(efz_input:read_file(InputPath,Max,corpus_restore), corpus_input),
    Encoded = read_bounded(filename:join(Path, "metadata"), ?MAX_META),
    Record = decode(Encoded, Path),
    try valid_record(Record, Input)
    catch error:Why -> error({invalid_corpus_metadata, Path, Why}) end,
    check(hex(maps:get(content_hash, Record)) =:= Name, {corpus_content_name_mismatch, Path}),
    #{input => Input, record => Record}.
decode(<<"EFZC", Version, _/binary>>, Path) when Version =/= 1 ->
    error({incompatible_corpus_schema, Path, Version});
decode(<<"EFZC", 1, N:32, Hash:32/binary, Payload:N/binary>>, Path) ->
    check(crypto:hash(sha256, Payload) =:= Hash, {corpus_metadata_checksum, Path}),
    try
        <<131, Term/binary>> = Payload,
        {<<>>, _} = scan(Term, 0, 1000000),
        binary_to_term(Payload, [safe])
    catch error:_ -> error({invalid_corpus_encoding, Path}) end;
decode(_, Path) -> error({truncated_or_invalid_corpus_metadata, Path}).

valid_record(R = #{schema_version := Version}, _) when Version =/= 1 ->
    error({incompatible_corpus_schema, maps:get(schema_version, R)});
valid_record(R = #{schema_version := 1, content_hash := Hash, input_size := Size,
                  queue_id := Q, origin := Origin, parent := Parent, discovery := Discovery,
                  identity := Identity, recipe := Recipe}, Input) ->
    check(lists:sort(maps:keys(R)) =:= lists:sort([schema_version, content_hash, input_size,
        queue_id, origin, parent, discovery, identity, recipe]), invalid_metadata_keys),
    check(is_binary(Input) andalso byte_size(Input) =< efz_input:hard_limit(), corpus_input_size_limit),
    check(Size =:= byte_size(Input), corpus_input_size_mismatch),
    check(Hash =:= crypto:hash(sha256, Input), corpus_input_hash_mismatch),
    check(is_integer(Q) andalso Q > 0, invalid_queue_provenance),
    valid_identity(Identity),
    case {Origin, Parent, Discovery} of
        {initial, none, #{new_probes := [], phase := initial}} ->
            check(map_size(Discovery) =:= 2 andalso Recipe =:= none, invalid_initial_provenance);
        {discovery, #{content_hash := PH, queue_id := PQ}, #{new_probes := Ps, phase := mutation}} ->
            check(hash(PH) andalso is_integer(PQ) andalso PQ > 0 andalso map_size(Parent) =:= 2,
                  invalid_parent_provenance),
            check(is_list(Ps) andalso Ps =/= [] andalso map_size(Discovery) =:= 2, invalid_discovery),
            lists:foreach(fun valid_probe/1, Ps),
            valid_recipe(Recipe, Input, PH, PQ, maps:get(builds, Identity));
        _ -> error(invalid_corpus_origin)
    end;
valid_record(_, _) -> error(invalid_metadata_shape).
valid_identity(#{target := M, callback := {<<"run">>, 1}, target_md5 := MD5,
                 coverage := Mode, builds := Bs} = I) ->
    check(map_size(I) =:= 5 andalso is_binary(M) andalso byte_size(M) > 0 andalso
          is_binary(MD5) andalso byte_size(MD5) =:= 16 andalso
          lists:member(Mode, [automatic, manual]) andalso is_list(Bs), invalid_target_identity),
    check(lists:all(fun({Name, H}) -> is_binary(Name) andalso byte_size(Name) > 0 andalso hash(H);
                      (_) -> false end, Bs), invalid_build_identity),
    check(Bs =:= lists:usort(Bs) andalso length(Bs) =:= length(lists:usort([Name || {Name,_} <- Bs])),
          duplicate_build_identity);
valid_identity(_) -> error(invalid_target_identity).
valid_recipe(none, _, _, _, _) -> ok;
valid_recipe(Bytes, Input, PH, PQ, Builds) ->
    R = need(efz_recipe:decode(Bytes), invalid_corpus_recipe),
    check(efz_recipe:regenerate(R) =:= {ok, Input} andalso maps:get(primary_id, R) =:= PH
          andalso maps:get(parent, R) =:= PQ andalso maps:get(target_builds, R) =:= Builds,
          corpus_recipe_provenance_mismatch).
probe({manual, Id}) -> {manual, term_to_binary(Id)};
probe({M, B, N}) when is_atom(M) -> {atom_to_binary(M, utf8), B, N}.
valid_probe({manual, B}) when is_binary(B) -> ok; % Opaque historical ID, never decoded.
valid_probe({M, B, N}) when is_binary(M), is_integer(N), N > 0 ->
    check(byte_size(M) > 0 andalso hash(B), invalid_probe);
valid_probe(_) -> error(invalid_probe).
compatible(#{identity := I}, I, _, _) -> [];
compatible(#{identity := Old}, New, recalibrate, Path) -> [{corpus_build_mismatch, Path, Old, New}];
compatible(#{identity := Old}, New, reject, Path) -> error({corpus_build_mismatch, Path, Old, New}).

ensure_directory(Dir) -> need(efz_fs:directory(Dir), {create_corpus_directory,Dir}).
write_synced(Path,Bytes) -> need(efz_fs:write_file(Path,Bytes), {write_corpus_file,Path}).
sync_dir(Dir) -> need(efz_fs:sync_directory(Dir), {sync_corpus_directory,Dir}).
file_type(Path) ->
    Info = need(file:read_link_info(Path), {corpus_file, Path}), Info#file_info.type.
read_bounded(Path, Max) ->
    check(file_type(Path) =:= regular, {invalid_corpus_file, Path}),
    case efz_fs:read_bounded(Path,Max) of
        {ok,B} -> B;
        {error,#{reason:=file_size_limit}} -> error({corpus_file_size_limit,Path});
        {error,E} -> error(E)
    end.
hash(B) -> is_binary(B) andalso byte_size(B) =:= 32.
hex(B) -> binary_to_list(binary:encode_hex(B, lowercase)).
valid_name(N) -> length(N) =:= 64 andalso lists:all(fun(C) ->
    (C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) end, N).
need(ok, _) -> ok;
need({ok, V}, _) -> V;
need({error, Why}, _) when is_map(Why) -> error(Why);
need({error, Why}, Context) -> error({Context, Why}).
check(true, _) -> ok;
check(false, Why) -> error(Why).
protect(F) -> try F() catch error:Why -> {error, Why} end.

%% Bounded ETF scan precedes safe decoding: no compression, process objects,
%% atom creation or unbounded container/depth declarations from disk.
scan(_, D, _) when D > 24 -> error(metadata_depth);
scan(_, _, B) when B =< 0 -> error(metadata_terms);
scan(<<97,_:8,R/binary>>,_,B)->{R,B-1};
scan(<<98,_:32,R/binary>>,_,B)->{R,B-1};
scan(<<110,N:8,S:8,_:N/binary,R/binary>>,_,B) when N=<8,S=<1->{R,B-1};
scan(<<119,N:8,_:N/binary,R/binary>>,_,B) when N=<128->{R,B-1};
scan(<<118,N:16,_:N/binary,R/binary>>,_,B) when N=<128->{R,B-1};
scan(<<100,N:16,_:N/binary,R/binary>>,_,B) when N=<128->{R,B-1};
scan(<<109,N:32,_:N/binary,R/binary>>,_,B) when N=< ?MAX_META->{R,B-1};
scan(<<107,N:16,_:N/binary,R/binary>>,_,B) when N=<4096->{R,B-1};
scan(<<106,R/binary>>,_,B)->{R,B-1};
scan(<<104,N:8,R/binary>>,D,B) when N=<16->scan_n(N,R,D+1,B-1);
scan(<<108,N:32,R/binary>>,D,B) when N=<1000000->scan_n(N+1,R,D+1,B-1);
scan(<<116,N:32,R/binary>>,D,B) when N=<64->scan_n(N*2,R,D+1,B-1);
scan(_,_,_)->error(unsupported_metadata_term).
scan_n(0,R,_,B)->{R,B};
scan_n(N,Data,D,B)->{R,B1}=scan(Data,D,B),scan_n(N-1,R,D,B1).
