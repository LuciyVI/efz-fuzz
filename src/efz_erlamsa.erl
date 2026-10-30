%% The optional, trusted-local Erlamsa core. This module starts no application.
%% Operational calls use the fixed local-data API in EFZ's request child.
-module(efz_erlamsa).
-export([prepare/3, prepare_timed/3, mutate/3, mutate_timed/3, mutate_session_timed/3,
         core_option_atoms/0, identity_valid/1, live/1]).
-include_lib("kernel/include/file.hrl").

-define(MAX_FILE, 2097152).
-define(MAX_APP, 65536).

prepare(Options, Limits, CorePath) when is_map(Options), is_map(Limits) ->
    {Result, _Timing} = prepare_timed(Options, Limits, CorePath),
    Result;
prepare(_, _, _) -> {error, invalid_core_configuration}.

prepare_timed(Options, Limits, CorePath) when is_map(Options), is_map(Limits) ->
    Started = erlang:monotonic_time(microsecond),
    try
        Root = absolute_path(CorePath),
        require(filelib:is_dir(Root), missing_core),
        Ebin = find_ebin(Root),
        App = read_bounded(filename:join(Ebin, "erlamsa_core.app"), ?MAX_APP),
        Modules = app_modules(App),
        ensure_complete_modules(Ebin, Modules),
        Revision = source_revision(Root),
        Artifacts = [read_artifact(M, Ebin) || M <- Modules],
        lists:foreach(fun loaded_compatible/1, Artifacts),
        require(code:add_patha(Ebin) =:= true, unavailable_build),
        lists:foreach(fun load_artifact/1, Artifacts),
        Versions = core_call(versions, []),
        require(Versions =:= expected_versions(), version_mismatch),
        Identity = #{schema => 1, source_revision => Revision, source_clean => true,
            modules => [maps:with([module, beam_sha256, beam_md5], A) || A <- Artifacts],
            app_sha256 => crypto:hash(sha256, App), versions => Versions,
            otp_release => list_to_binary(erlang:system_info(otp_release)),
            erts_version => list_to_binary(erlang:system_info(version))},
        require(identity_valid(Identity), version_mismatch),
        IdentityUs = max(0, erlang:monotonic_time(microsecond) - Started),
        ContextStarted = erlang:monotonic_time(microsecond),
        case core_call(prepare, [Options, Limits]) of
            {ok, Context} ->
                require(valid_context(Context, Versions), version_mismatch),
                RuntimeModules = [{maps:get(atom, A), maps:get(beam_md5, A)} || A <- Artifacts],
                Result = {ok, #{core_context => Context, core_identity => Identity,
                                core_path => Root, runtime_modules => RuntimeModules}},
                Timing = #{identity_check_us => IdentityUs,
                    core_prepare_us => max(0, erlang:monotonic_time(microsecond) - ContextStarted),
                    prepare_total_us => max(0, erlang:monotonic_time(microsecond) - Started)},
                {Result, Timing};
            {error, CoreReason} when is_atom(CoreReason) ->
                { {error, CoreReason}, #{identity_check_us => IdentityUs,
                    core_prepare_us => max(0, erlang:monotonic_time(microsecond) - ContextStarted),
                    prepare_total_us => max(0, erlang:monotonic_time(microsecond) - Started)} };
            _ ->
                { {error, version_mismatch}, #{identity_check_us => IdentityUs,
                    core_prepare_us => max(0, erlang:monotonic_time(microsecond) - ContextStarted),
                    prepare_total_us => max(0, erlang:monotonic_time(microsecond) - Started)} }
        end
    catch
        throw:{erlamsa_configuration, Reason} ->
            {{error, Reason}, #{identity_check_us => max(0,
                erlang:monotonic_time(microsecond) - Started), core_prepare_us => 0,
                prepare_total_us => max(0, erlang:monotonic_time(microsecond) - Started)}};
        _:_ ->
            {{error, unavailable_build}, #{identity_check_us => max(0,
                erlang:monotonic_time(microsecond) - Started), core_prepare_us => 0,
                prepare_total_us => max(0, erlang:monotonic_time(microsecond) - Started)}}
    end;
prepare_timed(_, _, _) -> {{error, invalid_core_configuration},
    #{identity_check_us => 0, core_prepare_us => 0, prepare_total_us => 0}}.

mutate(Input, Request, #{core_context := Context, core_identity := Identity}) ->
    {Result, _Timing} = mutate_timed(Input, Request,
        #{core_context => Context, core_identity => Identity}),
    Result;
mutate(_, _, _) -> {error, invalid_core_context}.

%% Keep the historical mutate/3 wrapper intact while exposing phase timings.
%% The direct timer surrounds only erlamsa_core:mutate/3; runtime_live/1 is
%% reported separately and remains enforced on every request.
mutate_timed(Input, Request, #{core_context := Context, core_identity := Identity}) ->
    IdentityStarted = erlang:monotonic_time(microsecond),
    Live = runtime_live(Identity),
    IdentityUs = max(0, erlang:monotonic_time(microsecond) - IdentityStarted),
    case Live of
        true ->
            CoreStarted = erlang:monotonic_time(microsecond),
            Result = core_call(mutate, [Input, Request, Context]),
            CoreUs = max(0, erlang:monotonic_time(microsecond) - CoreStarted),
            {Result, #{identity_check_us => IdentityUs,
                       direct_core_mutation_us => CoreUs}};
        false ->
            {{error, version_mismatch}, #{identity_check_us => IdentityUs,
                                          direct_core_mutation_us => 0}}
    end;
mutate_timed(_, _, _) ->
    {{error, invalid_core_context}, #{identity_check_us => 0,
                                     direct_core_mutation_us => 0}}.

%% Persistent sessions have already validated the complete source/build identity
%% during handshake. On each request retain a cheap loaded-code fingerprint
%% check: a module replacement or runtime mismatch still fails closed, while
%% filesystem, Git, regex/schema and full core-version checks stay at startup.
mutate_session_timed(Input, Request,
        #{core_context := Context, runtime_modules := RuntimeModules,
          core_identity := Identity}) ->
    IdentityStarted = erlang:monotonic_time(microsecond),
    Live = loaded_identity_live(Identity, RuntimeModules),
    IdentityUs = max(0, erlang:monotonic_time(microsecond) - IdentityStarted),
    case Live of
        true ->
            CoreStarted = erlang:monotonic_time(microsecond),
            Result = core_call(mutate, [Input, Request, Context]),
            CoreUs = max(0, erlang:monotonic_time(microsecond) - CoreStarted),
            {Result, #{identity_check_us => IdentityUs,
                       direct_core_mutation_us => CoreUs}};
        false -> {{error, version_mismatch},
                  #{identity_check_us => IdentityUs, direct_core_mutation_us => 0}}
    end;
mutate_session_timed(_, _, _) ->
    {{error, invalid_core_context}, #{identity_check_us => 0,
                                     direct_core_mutation_us => 0}}.

loaded_identity_live(Identity, RuntimeModules) ->
    try
        maps:get(otp_release, Identity) =:= list_to_binary(erlang:system_info(otp_release))
        andalso maps:get(erts_version, Identity) =:= list_to_binary(erlang:system_info(version))
        andalso lists:all(fun({Module, MD5}) ->
            code:is_loaded(Module) =/= false andalso
            erlang:get_module_info(Module, md5) =:= MD5
        end, RuntimeModules)
    catch _:_ -> false
    end.

%% Loading this EFZ-owned module interns only the finite option/operator names
%% used by the fixed core API before safe ETF decoding of the startup frame.
core_option_atoms() ->
    [profile, balanced, bytes, formats, fields, strategy, preserve, perturb,
     mixed, operators, patterns, inner_operator, auto, byte_flip, byte_insert,
     byte_drop, block_repeat, block_drop, block_swap, line_repeat, line_drop,
     line_swap, number, delimiter, unicode, json, sgml, base64, gzip, zlib,
     zip, length, xor8, crc32, field_operator, length_field, xor8_field,
     crc32_field, offset, width, endian, big, little, payload_offset,
     payload_length, once, many, burst, skip].

live(#{core_identity := Identity}) -> live(Identity);
live(Identity) ->
    try
        runtime_live(Identity) andalso
        lists:all(fun(Entry) ->
            Module = existing_core_module(maps:get(module, Entry)),
            case code:is_loaded(Module) of
                {file, Path} when is_list(Path) ->
                    Beam = read_bounded(Path, ?MAX_FILE),
                    crypto:hash(sha256, Beam) =:= maps:get(beam_sha256, Entry);
                _ -> false
            end
        end, maps:get(modules, Identity))
    catch _:_ -> false
    end.

runtime_live(Identity) ->
    try
        identity_valid(Identity) andalso
        maps:get(otp_release, Identity) =:= list_to_binary(erlang:system_info(otp_release))
        andalso maps:get(erts_version, Identity) =:= list_to_binary(erlang:system_info(version))
        andalso lists:all(fun(Entry) ->
            Module = existing_core_module(maps:get(module, Entry)),
            code:is_loaded(Module) =/= false andalso
            erlang:get_module_info(Module, md5) =:= maps:get(beam_md5, Entry)
        end, maps:get(modules, Identity))
        andalso core_call(versions, []) =:= maps:get(versions, Identity)
    catch _:_ -> false
    end.

identity_valid(Identity) when is_map(Identity) ->
    try
        true = lists:sort(maps:keys(Identity)) =:= lists:sort([schema, source_revision,
            source_clean, modules, app_sha256, versions, otp_release, erts_version]),
        1 = maps:get(schema, Identity),
        true = maps:get(source_clean, Identity),
        Revision = maps:get(source_revision, Identity),
        true = is_binary(Revision) andalso
               (byte_size(Revision) =:= 40 orelse byte_size(Revision) =:= 64),
        match = re:run(Revision, <<"^[0-9a-f]+$">>, [{capture, none}]),
        true = hash(maps:get(app_sha256, Identity), 32),
        true = maps:get(versions, Identity) =:= expected_versions(),
        true = small_binary(maps:get(otp_release, Identity), 32),
        true = small_binary(maps:get(erts_version, Identity), 64),
        Modules = maps:get(modules, Identity),
        true = is_list(Modules) andalso length(Modules) > 0 andalso length(Modules) =< 32,
        true = lists:all(fun valid_module_identity/1, Modules),
        Names = [maps:get(module, M) || M <- Modules],
        true = Names =:= lists:usort(Names),
        true = lists:all(fun(Name) -> lists:member(Name, Names) end, required_module_names()),
        true = erlang:external_size(Identity) =< 65536,
        true
    catch _:_ -> false
    end;
identity_valid(_) -> false.

valid_module_identity(#{module := Name, beam_sha256 := SHA, beam_md5 := MD5} = Entry) ->
    map_size(Entry) =:= 3 andalso valid_module_name(Name)
    andalso hash(SHA, 32) andalso hash(MD5, 16);
valid_module_identity(_) -> false.

valid_context(#{core_context := 1, options := O, limits := L,
                versions := Versions, config_identity := Hash} = Context, Versions) ->
    map_size(Context) =:= 5 andalso is_map(O) andalso is_map(L) andalso hash(Hash, 32)
    andalso efz_gleam_adapter:portable(Context) andalso erlang:external_size(Context) =< 65536;
valid_context(_, _) -> false.

expected_versions() ->
    #{api => 1, library => <<"0.1.0">>, rng => <<"splitmix64-v1">>,
      catalogue => 1, patterns => 1, limits => 1}.

%% These fixed atoms exist before any trusted .app metadata is read.
required_module_names() ->
    [atom_to_binary(M, utf8) || M <- [erlamsa_core, erlamsa_core_bytes,
        erlamsa_core_fields, erlamsa_core_json, erlamsa_core_ops, erlamsa_core_pack,
        erlamsa_core_rng, erlamsa_core_sgml, erlamsa_core_tree]].

valid_module_name(Name) ->
    is_binary(Name) andalso byte_size(Name) > 0 andalso byte_size(Name) =< 64
    andalso re:run(Name, <<"^erlamsa_core(?:_[a-z0-9_]+)?$">>, [{capture, none}]) =:= match.

existing_core_module(Name) ->
    require(valid_module_name(Name), version_mismatch),
    try binary_to_existing_atom(Name, utf8)
    catch error:badarg -> fail(version_mismatch)
    end.

absolute_path(Path) when is_binary(Path), byte_size(Path) > 0, byte_size(Path) =< 4096 ->
    absolute_path(binary_to_list(Path));
absolute_path(Path) when is_list(Path), length(Path) > 0, length(Path) =< 4096 ->
    require(lists:all(fun(C) -> is_integer(C) andalso C > 0 andalso C =< 255 end, Path),
            missing_core),
    filename:absname(Path);
absolute_path(_) -> fail(missing_core).

find_ebin(Root) ->
    Candidates = [filename:join([Root, "core", "_build", "default", "lib", "erlamsa_core", "ebin"]),
        filename:join([Root, "_build", "default", "lib", "erlamsa_core", "ebin"]), Root],
    case [P || P <- Candidates, filelib:is_regular(filename:join(P, "erlamsa_core.app"))] of
        [Ebin | _] -> Ebin;
        [] -> fail(unavailable_build)
    end.

app_modules(App) ->
    %% file:consult/1 would intern atoms before validation, so parse only the
    %% generated module list and convert its names through existing atoms.
    require(re:run(App, <<"\\{\\s*application\\s*,\\s*erlamsa_core\\s*,\\s*\\[">>,
                   [{capture, none}]) =:= match, unavailable_build),
    case re:run(App, <<"\\{\\s*modules\\s*,\\s*\\[([^\\]]*)\\]\\s*\\}">>,
                [global, {capture, [1], binary}]) of
        {match, [[Body]]} ->
            Names = [trim(Name) || Name <- binary:split(Body, <<",">>, [global])],
            require(length(Names) > 0 andalso length(Names) =< 32, unavailable_build),
            require(length(Names) =:= length(lists:usort(Names)), unavailable_build),
            Modules = [existing_core_module(Name) || Name <- Names],
            require(lists:all(fun(Name) -> lists:member(Name, Names) end,
                              required_module_names()), version_mismatch),
            lists:sort(Modules);
        _ -> fail(unavailable_build)
    end.

trim(Bin) ->
    re:replace(Bin, <<"^[\\s]+|[\\s]+$">>, <<>>, [global, {return, binary}]).

ensure_complete_modules(Ebin, Modules) ->
    case file:list_dir(Ebin) of
        {ok, Files} when length(Files) =< 64 ->
            CoreBeams = lists:sort([list_to_binary(filename:basename(F, ".beam"))
                || F <- Files, filename:extension(F) =:= ".beam",
                   lists:prefix("erlamsa_core", F)]),
            require(CoreBeams =:= lists:sort([atom_to_binary(M, utf8) || M <- Modules]),
                    unavailable_build);
        _ -> fail(unavailable_build)
    end.

read_artifact(Module, Ebin) ->
    Path = filename:join(Ebin, atom_to_list(Module) ++ ".beam"),
    Beam = read_bounded(Path, ?MAX_FILE),
    case beam_lib:md5(Beam) of
        {ok, {Module, MD5}} ->
            #{module => atom_to_binary(Module, utf8), beam_sha256 => crypto:hash(sha256, Beam),
              beam_md5 => MD5, atom => Module, path => Path, beam => Beam};
        _ -> fail(unavailable_build)
    end.

loaded_compatible(#{atom := Module, beam_md5 := MD5, beam_sha256 := SHA}) ->
    case code:is_loaded(Module) of
        false -> ok;
        {file, Path} when is_list(Path) ->
            Existing = try read_bounded(Path, ?MAX_FILE)
                catch _:_ -> fail(version_mismatch)
                end,
            require(erlang:get_module_info(Module, md5) =:= MD5 andalso
                    crypto:hash(sha256, Existing) =:= SHA, version_mismatch);
        _ -> fail(version_mismatch)
    end.

load_artifact(#{atom := Module, path := Path, beam := Beam, beam_md5 := MD5}) ->
    case code:is_loaded(Module) of
        false -> require(code:load_binary(Module, Path, Beam) =:= {module, Module},
                         unavailable_build);
        _ -> ok
    end,
    require(erlang:get_module_info(Module, md5) =:= MD5, version_mismatch).

read_bounded(Path, Maximum) ->
    case file:read_file_info(Path) of
        {ok, #file_info{type = regular, size = Size}} when Size =< Maximum ->
            case file:read_file(Path) of
                {ok, Bytes} when byte_size(Bytes) =< Maximum -> Bytes;
                _ -> fail(unavailable_build)
            end;
        _ -> fail(unavailable_build)
    end.

source_revision(Root) ->
    Git = case os:find_executable("git") of false -> fail(unavailable_build); P -> P end,
    Prefix = ["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", Root],
    Revision = trim(git(Git, Prefix ++ ["rev-parse", "--verify", "HEAD"], 128)),
    require((byte_size(Revision) =:= 40 orelse byte_size(Revision) =:= 64) andalso
            re:run(Revision, <<"^[0-9a-f]+$">>, [{capture, none}]) =:= match,
            unavailable_build),
    Status = git(Git, Prefix ++ ["status", "--porcelain", "--untracked-files=normal"], 8192),
    require(Status =:= <<>>, dirty),
    Revision.

git(Executable, Args, Maximum) ->
    Port = open_port({spawn_executable, Executable},
        [binary, exit_status, use_stdio, stderr_to_stdout, {args, Args}]),
    Deadline = erlang:monotonic_time(millisecond) + 3000,
    try git_output(Port, Deadline, Maximum, [])
    after
        _ = catch port_close(Port),
        flush_port(Port)
    end.

flush_port(Port) ->
    receive
        {Port, _} -> flush_port(Port);
        {'EXIT', Port, _} -> flush_port(Port)
    after 0 -> ok
    end.

git_output(Port, Deadline, Remaining, Acc) ->
    Wait = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Bytes}} when byte_size(Bytes) =< Remaining ->
            git_output(Port, Deadline, Remaining - byte_size(Bytes), [Bytes | Acc]);
        {Port, {data, _}} -> fail(unavailable_build);
        {Port, {exit_status, 0}} -> iolist_to_binary(lists:reverse(Acc));
        {Port, {exit_status, _}} -> fail(unavailable_build)
    after Wait -> fail(unavailable_build)
    end.

core_call(Function, Arguments) -> apply(erlamsa_core, Function, Arguments).
small_binary(B, Maximum) -> is_binary(B) andalso byte_size(B) > 0 andalso byte_size(B) =< Maximum.
hash(B, Size) -> is_binary(B) andalso byte_size(B) =:= Size.
require(true, _) -> ok;
require(false, Reason) -> fail(Reason).
-spec fail(term()) -> no_return().
fail(Reason) -> throw({erlamsa_configuration, Reason}).
