%% Serial, explicit source compilation. Never starts EFZ or loads per iteration.
-module(efz_instrument).
-export([compile/2, load/1, preflight/1, discover/1]).

%% Discover descriptors without autoloading ordinary code from the directory.
%% preflight/1 remains responsible for loading and checking the paired sidecars.
discover(Dir) ->
    case file:list_dir(Dir) of
        {ok, Names} ->
            Beams = lists:sort([filename:join(Dir, N) || N <- Names, filename:extension(N) =:= ".beam"]),
            case Beams of
                [] -> {error, {no_instrumented_beams, Dir}};
                _ -> discover_beams(Beams, [])
            end;
        {error, Why} -> {error, {artifact_directory, Dir, Why}}
    end.
discover_beams([], Acc) -> {ok, lists:reverse(Acc)};
discover_beams([Path | Rest], Acc) ->
    Sidecar = filename:rootname(Path) ++ ".efz-manifest",
    %% Avoid reading directories, devices or pipes as either artifact file.
    case [P || P <- [Path, Sidecar], not filelib:is_regular(P)] of
        [] -> discover_beam(Path, Sidecar, Rest, Acc);
        Bad -> {error, {missing_or_nonregular_artifact_files, Bad}}
    end.
discover_beam(Path, Sidecar, Rest, Acc) ->
    case efz_cov_manifest:from_beam(Path) of
        {ok, #{module := M, build_id := B}} ->
            A = #{module => M, build_id => B, beam => filename:absname(Path),
                  manifest => filename:absname(Sidecar)},
            discover_beams(Rest, [A | Acc]);
        {error, Why} -> {error, {invalid_instrumented_beam, Path, Why}}
    end.

compile(File, C) ->
    try compile_target(File, C)
    catch error:Reason -> {error, Reason} end.

compile_target(File, #{modules := Modules, outdir := Out} = C) ->
    true = is_list(Modules) andalso Modules =/= [],
    Opts = maps:get(erl_opts, C, [debug_info, warnings_as_errors]),
    %% Other transforms and output modes need a separately verified ordering.
    case [O || O <- Opts, forbidden(O)] of
        [] -> ok;
        Bad -> error({unsupported_compiler_options, Bad})
    end,
    {module, efz_instrument_pt} = code:ensure_loaded(efz_instrument_pt),
    case application:load(compiler) of
        ok -> ok;
        {error, {already_loaded, compiler}} -> ok
    end,
    Root = filename:absname(maps:get(source_root, C, filename:dirname(File))),
    AbsOut = filename:absname(Out),
    case AbsOut =:= filename:absname(filename:dirname(File)) orelse
         lists:member(AbsOut, [filename:absname(P) || P <- code:get_path()]) of
        true -> error({output_must_be_separate, AbsOut});
        false -> ok
    end,
    OldPath = code:get_path(),
    try
        lists:foreach(fun(P) -> true = code:add_patha(filename:absname(P)) end,
                      maps:get(code_paths, C, [])),
        ok = check_source_options(File, Opts),
        ok = check_output(AbsOut),
        IdentityOpts = [O || O <- Opts, relevant(O)],
        CompileOpts = Opts ++ [binary, return_errors, return_warnings,
            {error_location, column}, {parse_transform, efz_instrument_pt},
            {efz_modules, Modules}, {efz_source_root, Root},
            {efz_identity_options, IdentityOpts}, {efz_strict, maps:get(strict, C, true)}],
        Result = compile:noenv_file(File, CompileOpts),
        case Result of
            {ok, M, Beam, Warnings} -> write_artifact(M, Beam, Out, Warnings);
            {error, Errors, Warnings} -> {error, {compilation, Errors, Warnings}};
            Other -> {error, {compilation, Other}}
        end
    after true = code:set_path(OldPath) end;
compile_target(_, _) -> error({configuration, required_modules_and_outdir}).

check_source_options(File, Opts) ->
    %% The compiler removes -compile(parse_transform) attributes before calling
    %% transforms. Inspect preprocessed source first, so a later transform cannot
    %% change code behind EFZ's manifest. Use the same includes/macros/features.
    {ok, {Features, Reserved}} = erl_features:keyword_fun(Opts, fun erl_scan:f_reserved_word/1),
    Macros = [case D of {d, N} -> N; {d, N, V} -> {N, V} end ||
              D <- Opts, is_tuple(D), element(1, D) =:= d],
    Includes = [".", filename:dirname(File) | [I || {i, I} <- Opts]],
    case epp:parse_file(File, [{includes, Includes}, {macros, Macros},
                             {features, Features}, {reserved_word_fun, Reserved}]) of
        {ok, Forms} ->
            SourceOpts = lists:append([case X of L when is_list(L) -> L; _ -> [X] end ||
                                       {attribute, _, compile, X} <- Forms]),
            case [O || O <- SourceOpts, forbidden(O)] of
                [] -> ok;
                Bad -> error({unsupported_source_compiler_options, Bad})
            end;
        {error, Why} -> error({source_preprocessing, Why})
    end.
check_output(Out) ->
    Beams = filelib:wildcard(filename:join(Out, "*.beam")),
    case [B || B <- Beams, element(1, efz_cov_manifest:from_beam(B)) =/= ok] of
        [] -> ok;
        _ -> error({ordinary_artifact_directory, Out})
    end.

forbidden({parse_transform, _}) -> true;
forbidden({outdir, _}) -> true;
forbidden({source, _}) -> true;
forbidden({error_location, _}) -> true;
forbidden(O) -> lists:member(O, [binary, makedep, to_pp, to_core, to_asm, 'P', 'E', 'S']).
relevant({i, _}) -> false; % Expanded header contents are already hashed.
relevant(O) -> not lists:member(O, [debug_info, warnings_as_errors, report,
                                   report_errors, report_warnings, return_errors, return_warnings]).

write_artifact(M, Beam, Out, Warnings) ->
    {ok, Manifest} = efz_cov_manifest:from_beam(Beam),
    BeamPath = filename:absname(filename:join(Out, atom_to_list(M) ++ ".beam")),
    ManifestPath = filename:rootname(BeamPath) ++ ".efz-manifest",
    ok = filelib:ensure_dir(BeamPath),
    ok = file:write_file(BeamPath, Beam),
    ok = file:write_file(ManifestPath, term_to_binary(Manifest)),
    {ok, #{module => M, beam => BeamPath, manifest => ManifestPath,
           build_id => maps:get(build_id, Manifest), warnings => Warnings}}.

load(A = #{module := M, beam := Path, manifest := ManifestPath, build_id := B}) ->
    case {file:read_file(Path), file:read_file(ManifestPath)} of
        {{ok, Beam}, {ok, Sidecar}} ->
            case efz_cov_manifest:from_beam(Beam) of
                {ok, #{module := M, build_id := B} = Manifest} ->
                    %% ETF map ordering can differ across VMs. Compare exact
                    %% terms; safe decoding cannot introduce new atoms/funs.
                    case matching_sidecar(Sidecar, Manifest) of
                        true -> load_checked(M, Path, Beam, Manifest);
                        false -> {error, {manifest_artifact_mismatch, M}}
                    end;
                Other -> {error, {artifact_identity, A, Other}}
            end;
        Other -> {error, {missing_artifacts, M, Other}}
    end;
load(_) -> {error, invalid_artifact_descriptor}.

matching_sidecar(Bytes, Manifest) ->
    try binary_to_term(Bytes, [safe]) =:= Manifest
    catch error:badarg -> false end.

load_checked(M, Path, Beam, Manifest) ->
    case code:is_loaded(M) of
        false ->
            case code:load_binary(M, Path, Beam) of
                {module, M} -> loaded_manifest(M, Manifest, Beam);
                Error -> {error, {load, M, Error}}
            end;
        _ -> loaded_manifest(M, Manifest, Beam)
    end.
loaded_manifest(M, Expected, Beam) ->
    {ok,{M,Md5}}=beam_lib:md5(Beam),
    Info=erlang:get_module_info(M),
    case {proplists:get_value(efz_manifest,proplists:get_value(attributes,Info)),
          proplists:get_value(md5,Info)} of
        {[Expected],Md5} -> {ok, Expected};
        _ -> {error, {loaded_module_identity_mismatch, M}}
    end.

preflight([]) -> {error, automatic_coverage_requires_artifacts};
preflight(Artifacts) when is_list(Artifacts) -> preflight(Artifacts, #{}, []);
preflight(_) -> {error, invalid_artifacts}.
preflight([], _, Ms) -> {ok, lists:reverse(Ms)};
preflight([A | As], Seen, Ms) ->
    case load(A) of
        {ok, #{module := M} = Manifest} ->
            case maps:is_key(M, Seen) of
                true -> {error, {duplicate_selected_module, M}};
                false -> preflight(As, Seen#{M => true}, [Manifest | Ms])
            end;
        Error -> Error
    end.
