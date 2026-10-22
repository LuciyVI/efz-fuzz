#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).

%% Trusted local scaffold, not a package manager. Never replace existing files.
main(["generic", Dir]) -> generic(Dir, "efz_generated_target", default_options());
main(["generic", Dir, Name]) -> generic(Dir, Name, default_options());
main(["generic", Dir, Name, OptionsFile]) ->
    case file:consult(OptionsFile) of
        {ok, [Options]} when is_map(Options) -> generic(Dir, Name, Options);
        Failure -> fail({invalid_options_file, OptionsFile, Failure})
    end;
main(["from-beam", Dir, Name, Beam, Function, Arity]) ->
    from_beam(Dir, Name, Beam, Function, Arity);
main(["domain", Dir]) -> domain(Dir, "efz_generated_target");
main(["domain", Dir, Name]) -> domain(Dir, Name);
main(_) ->
    io:format(standard_error,
        "Usage: semantic_scaffold.escript generic OUTDIR [HARNESS_MODULE [OPTIONS.term]]~n"
        "       semantic_scaffold.escript domain OUTDIR [HARNESS_MODULE]~n"
        "       semantic_scaffold.escript from-beam OUTDIR HARNESS_MODULE BEAM FUNCTION ARITY~n", []), halt(2).

default_options() -> #{entrypoint => {lists, reverse, 1},
    arguments => [#{kind => list, item => #{kind => integer}}]}.
limits() -> #{bytes => 4096, depth => 8, nodes => 128, collection => 32, operations => 1}.
module(Name) ->
    case Name =/= [] andalso length(Name) =< 128 andalso hd(Name) >= $a andalso hd(Name) =< $z
        andalso lists:all(fun(C) -> (C >= $a andalso C =< $z) orelse
            (C >= $0 andalso C =< $9) orelse C =:= $_ end, Name) of
        true -> list_to_atom(Name); %% Trusted command-line module name, never input bytes.
        false -> fail({invalid_scaffold_module, Name})
    end.

load_efz() ->
    Root = filename:dirname(filename:dirname(filename:absname(escript:script_name()))),
    true = code:add_patha(filename:join([Root, "_build", "default", "lib", "efz", "ebin"])),
    case code:ensure_loaded(efz_term_codec) of
        {module, efz_term_codec} -> ok;
        _ -> fail(build_efz_with_rebar3_compile_first)
    end.
generic(Dir, Name, Options) -> generic(Dir, Name, Options, []).
generic(Dir, Name, Options, ExtraFiles) ->
    M = module(Name), load_efz(),
    case Options of
        #{entrypoint := {Library, Function, Arity}, arguments := Specs}
                when is_atom(Library), is_atom(Function), is_integer(Arity), Arity >= 0,
                     is_list(Specs), length(Specs) =:= Arity ->
            case Library =:= M of
                true -> fail({harness_module_conflicts_with_entrypoint, Library});
                false -> ok
            end,
            case maps:keys(Options) -- [entrypoint, arguments] of
                [] -> ok;
                Unknown -> fail({unsupported_scaffold_options, Unknown})
            end,
            case efz_term_codec:validate_specs(Specs, limits()) of
                ok -> ok;
                Error -> fail(Error)
            end,
            case efz_term_codec:resources(Specs) of
                [] -> ok;
                Handles -> fail({resource_harness_required, Handles})
            end,
            Seed = case efz_term_api_adapter:seed(0, Options, limits()) of
                {ok, Bytes} -> Bytes;
                Failure -> fail({unable_to_generate_initial_seed, Failure})
            end,
            Source = io_lib:format(
                "%% Generated generic harness. Edit options and campaign together.\n"
                "-module(~p).\n-export([run/1, options/0, semantic_contract/0]).\n"
                "options() -> ~tp.\n"
                "semantic_contract() -> (options())#{kind => term_api}.\n"
                "run(Raw) -> efz_term_codec:execute(Raw, options()).\n", [M, Options]),
            Config = campaign(M, [Seed], efz_term_api_adapter, Options, 10),
            create(Dir, [{Name ++ ".erl", Source}, {"campaign.term", term(Config)},
                {"seeds/00", Seed}, {"README.md", readme(Name, generic)}] ++ ExtraFiles);
        _ -> fail(invalid_entrypoint_or_argument_count)
    end.

%% Inspect trusted BEAM metadata only. Loading the library is deliberately left
%% to the caller; extracting a spec must not run its on_load callback.
from_beam(Dir, Name, Beam, Function, ArityText) ->
    try
        Arity = list_to_integer(ArityText),
        true = Arity >= 0 andalso Arity =< 32,
        {ok, {Library, Chunks}} = beam_lib:chunks(Beam, [abstract_code, exports]),
        Forms = case proplists:get_value(abstract_code, Chunks) of
            {raw_abstract_v1, Fs} -> Fs;
            _ -> throw(missing_debug_info)
        end,
        Matches = [{F, A} || {F, A} <- proplists:get_value(exports, Chunks),
            atom_to_list(F) =:= Function, A =:= Arity],
        F = case Matches of [{Found, Arity}] -> Found; _ -> throw(entrypoint_not_exported) end,
        Signatures = [Ts || {attribute, _, spec, {{SF, SA}, Ts}} <- Forms,
            SF =:= F, SA =:= Arity],
        Args = case Signatures of
            [[{type, _, 'fun', [{type, _, product, As}, _Return]}]] -> As;
            [] -> throw(missing_spec);
            _ -> throw(overloaded_or_constrained_spec)
        end,
        Types = maps:from_list([{{T, length(Vars)}, {Body, Vars}} ||
            {attribute, _, type, {T, Body, Vars}} <- Forms]),
        Specs = [infer_type(A, Types, #{}, [], 0) || A <- Args],
        %% Both metadata and source remain reviewable without copying executable
        %% library code. Bounded defaults are a test envelope, not inferred API
        %% preconditions or a correctness oracle.
        Options = #{entrypoint => {Library, F, Arity}, arguments => Specs},
        {ok, Bytes} = file:read_file(Beam),
        Evidence = #{schema_version => 1, entrypoint => {Library, F, Arity},
            beam_sha256 => crypto:hash(sha256, Bytes), source => filename:absname(Beam),
            limits => limits(), inferred_arguments => Specs,
            limitations => [bounded_defaults, no_semantic_preconditions, no_correctness_oracle]},
        generic(Dir, Name, Options, [{"inference.term", term(Evidence)}])
    catch
        throw:Why -> fail({cannot_infer_connector, Why});
        error:{badmatch, _} -> fail({cannot_infer_connector, invalid_beam_or_arity});
        error:badarg -> fail({cannot_infer_connector, invalid_beam_or_arity})
    end.

infer_type(_, _, _, _, Depth) when Depth > 8 -> throw(type_depth_exceeded);
infer_type({ann_type, _, [_, T]}, Types, Vars, Stack, D) -> infer_type(T, Types, Vars, Stack, D);
infer_type({var, _, V}, _, Vars, _, _) ->
    case maps:find(V, Vars) of
        {ok, {schema, S}} -> S;
        error -> throw({unbound_type_variable, V})
    end;
infer_type({user_type, _, Name, Args}, Types, Vars, Stack, D) ->
    Key = {Name, length(Args)},
    case lists:member(Key, Stack) of true -> throw({recursive_type, Key}); false -> ok end,
    case maps:find(Key, Types) of
        {ok, {Body, Params}} ->
            Resolved = [infer_type(A, Types, Vars, Stack, D + 1) || A <- Args],
            Bindings = maps:from_list([{V, {schema, S}} || {{var, _, V}, S} <- lists:zip(Params, Resolved)]),
            infer_type(Body, Types, Bindings, [Key | Stack], D + 1);
        error -> throw({unknown_or_opaque_type, Key})
    end;
infer_type({type, _, integer, []}, _, _, _, _) -> integer_schema(-1000000, 1000000);
infer_type({type, _, non_neg_integer, []}, _, _, _, _) -> integer_schema(0, 1000000);
infer_type({type, _, pos_integer, []}, _, _, _, _) -> integer_schema(1, 1000000);
infer_type({type, _, neg_integer, []}, _, _, _, _) -> integer_schema(-1000000, -1);
infer_type({type, _, byte, []}, _, _, _, _) -> integer_schema(0, 255);
infer_type({type, _, char, []}, _, _, _, _) -> integer_schema(0, 16#10ffff);
infer_type({type, _, range, [A, B]}, _, _, _, _) -> integer_schema(integer_literal(A), integer_literal(B));
infer_type({integer, _, N}, _, _, _, _) -> integer_schema(N, N);
infer_type({op, _, '-', {integer, _, N}}, _, _, _, _) -> integer_schema(-N, -N);
infer_type({type, _, float, []}, _, _, _, _) -> #{kind => float, min => -1000000.0, max => 1000000.0};
infer_type({type, _, boolean, []}, _, _, _, _) -> #{kind => boolean};
infer_type({type, _, binary, []}, _, _, _, _) -> sized(binary, 0);
infer_type({type, _, binary, [{integer, _, 0}, {integer, _, 8}]}, _, _, _, _) -> sized(binary, 0);
infer_type({type, _, string, []}, _, _, _, _) -> sized(charlist, 0);
infer_type({type, _, nonempty_string, []}, _, _, _, _) -> sized(charlist, 1);
infer_type({type, _, nil, []}, _, _, _, _) -> #{kind => list, item => integer_schema(0, 0), max_length => 0};
infer_type({type, _, K, [T]}, Types, Vars, Stack, D) when K =:= list; K =:= nonempty_list ->
    (sized(list, case K of list -> 0; nonempty_list -> 1 end))#{item => infer_type(T, Types, Vars, Stack, D + 1)};
infer_type({type, _, tuple, Ts}, Types, Vars, Stack, D) when is_list(Ts) ->
    #{kind => tuple, items => [infer_type(T, Types, Vars, Stack, D + 1) || T <- Ts]};
infer_type({atom, _, A}, _, _, _, _) -> #{kind => atom, values => [A]};
infer_type({type, _, union, Ts}, _, _, _, _) ->
    case lists:all(fun({atom, _, _}) -> true; (_) -> false end, Ts) of
        true -> #{kind => atom, values => lists:usort([A || {atom, _, A} <- Ts])};
        false -> throw(unsupported_union)
    end;
infer_type({remote_type, _, _}, _, _, _, _) -> throw(remote_type_requires_explicit_schema);
infer_type({type, _, Name, _}, _, _, _, _) -> throw({unsupported_type, Name});
infer_type(_, _, _, _, _) -> throw(unsupported_type_expression).

integer_literal({integer, _, N}) -> N;
integer_literal({op, _, '-', {integer, _, N}}) -> -N;
integer_literal(_) -> throw(unsupported_range_bound).
integer_schema(Min, Max) when Min >= -9223372036854775808, Max =< 9223372036854775807, Min =< Max ->
    #{kind => integer, min => Min, max => Max};
integer_schema(_, _) -> throw(integer_range_outside_codec).
sized(Kind, Min) -> #{kind => Kind, min_length => Min, max_length => maps:get(collection, limits())}.

domain(Dir, Name) ->
    case length(Name) =< 48 of true -> ok; false -> fail(domain_module_name_exceeds_48_characters) end,
    M = module(Name), Adapter = module(Name ++ "_adapter"),
    TargetSource = io_lib:format(
        "%% Working bounded length-prefix fixture; replace run/1 with your API.\n"
        "-module(~p).\n-export([run/1, semantic_contract/0]).\n"
        "semantic_contract() -> #{kind => length_prefix, version => 1}.\n"
        "run(<<N:16, Payload:N/binary>>) -> {accepted, Payload};\n"
        "run(Raw) when is_binary(Raw) -> rejected.\n", [M]),
    AdapterSource = io_lib:format(
        "%% Minimal observer-only plugin: no model, generation, mutation or oracle.\n"
        "-module(~p).\n-behaviour(efz_semantic_adapter).\n"
        "-export([descriptor/0, prepare/3, observe/3]).\n"
        "descriptor() -> #{id => <<\"~s\">>, api_version => 1, model_version => 1,\n"
        "    observer_version => 1, recipe_version => 1, operations_version => 1,\n"
        "    capabilities => [observation], operations => [], model_modules => [], properties => []}.\n"
        "prepare(Target, Options, Limits) when is_map(Options), map_size(Options) =:= 0 ->\n"
        "    _ = code:ensure_loaded(Target),\n"
        "    case erlang:function_exported(Target, semantic_contract, 0) of\n"
        "        false -> {error, missing_semantic_contract};\n"
        "        true -> case Target:semantic_contract() of\n"
        "            #{kind := length_prefix, version := 1} -> {ok, #{bytes => maps:get(bytes, Limits)}};\n"
        "            _ -> {error, incompatible_harness}\n"
        "        end\n"
        "    end;\n"
        "prepare(_, _, _) -> {error, invalid_options}.\n"
        "observe(_, {ok, {accepted, Payload}}, #{bytes := Max}) when is_binary(Payload), byte_size(Payload) =< Max ->\n"
        "    Bucket = case byte_size(Payload) of 0 -> 4; N when N < 8 -> 5; _ -> 6 end,\n"
        "    {ok, [0, Bucket]};\n"
        "observe(_, {ok, rejected}, _) -> {ok, [1]};\n"
        "observe(_, {timeout, _}, _) -> {ok, [2]};\n"
        "observe(_, timeout, _) -> {ok, [2]};\n"
        "observe(_, _, _) -> {ok, [3]}.\n",
        [Adapter, Name ++ ".length_prefix"]),
    Seed = <<3:16, "abc">>,
    Config = campaign(M, [Seed], Adapter, #{}, 0),
    create(Dir, [{Name ++ ".erl", TargetSource}, {Name ++ "_adapter.erl", AdapterSource},
        {"campaign.term", term(Config)}, {"seeds/00", Seed}, {"README.md", readme(Name, domain)}]).

campaign(Target, Seeds, Adapter, Options, Fraction) ->
    #{target => Target, seeds => Seeds, artifacts => [], coverage_backend => none,
      mutation_mode => staged, mutation => #{seed => {17, 23, 41}, stages => [havoc]},
      timeout => 1000, max_input_bytes => 4096, max_iterations => 100,
      gleam_layer => #{adapter => Adapter, adapter_options => Options,
          structured_fraction => Fraction, feedback => guided, oracle => disabled,
          oracle_budget => 64, limits => limits()}}.
term(T) -> io_lib:format("~tp.~n", [T]).
readme(Name, Kind) ->
    {Build, ModelPath} = case Kind of
        generic -> {"GLEAM_BIN=/path/to/gleam-1.10.0 ERL_FLAGS='+S 2:2' rebar3 as gleam compile\n",
                    " --code-path _build/gleam/lib/efz/ebin"};
        domain -> {"ERL_FLAGS='+S 2:2' rebar3 compile\n", ""}
    end,
    io_lib:format(
        "# Generated ~p example\n\n"
        "Compile from the EFZ repository root (replace OUTDIR):\n\n"
        "```sh\n~smkdir -p OUTDIR/ebin\n"
        "erlc +debug_info +warnings_as_errors -pa _build/default/lib/efz/ebin -o OUTDIR/ebin OUTDIR/*.erl\n"
        "ERL_FLAGS='+S 2:2' escript scripts/fuzz.escript --config OUTDIR/campaign.term --code-path OUTDIR/ebin~s --out OUTDIR/run\n```\n\n"
        "Harness: `~s`. Generic mode uses the shared term adapter and optional\n"
        "Gleam build; domain mode advertises observation only and requires no\n"
        "model BEAM. Neither skeleton declares a correctness oracle.\n\n"
        "`coverage_backend => none` makes this an execution/semantic smoke test.\n"
        "Prepare target-only coverage artifacts before measuring coverage; do not\n"
        "include the adapter or models. Add `--code-path LIBRARY_EBIN` when the API\n"
        "module is not already available. Review inferred bounded constraints and\n"
        "add any semantic preconditions explicitly. Existing files are never overwritten.\n",
        [Kind, Build, ModelPath, Name]).

create(Dir0, Files) ->
    Dir = filename:absname(Dir0),
    Paths = [{filename:join(Dir, Name), Data} || {Name, Data} <- Files],
    lists:foreach(fun({Path, _}) ->
        case file:read_link_info(Path) of
            {error, enoent} -> ok;
            _ -> fail({already_exists, Path})
        end
    end, Paths),
    lists:foreach(fun({Path, Data}) ->
        ok = filelib:ensure_dir(Path),
        case file:open(Path, [write, binary, exclusive]) of
            {ok, F} -> ok = file:write(F, Data), ok = file:close(F);
            Error -> fail({cannot_create, Path, Error})
        end
    end, Paths),
    io:format("Created ~B files in ~ts. Compile instructions: ~ts~n", [length(Paths), Dir, filename:join(Dir, "README.md")]).
fail(Reason) -> io:format(standard_error, "Semantic scaffold: ~tp~n", [Reason]), halt(2).
