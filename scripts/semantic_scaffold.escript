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
main(["domain", Dir]) -> domain(Dir, "efz_generated_target");
main(["domain", Dir, Name]) -> domain(Dir, Name);
main(_) ->
    io:format(standard_error,
        "Usage: semantic_scaffold.escript generic OUTDIR [HARNESS_MODULE [OPTIONS.term]]~n"
        "       semantic_scaffold.escript domain OUTDIR [HARNESS_MODULE]~n", []), halt(2).

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
generic(Dir, Name, Options) ->
    M = module(Name), load_efz(),
    case Options of
        #{entrypoint := {Library, Function, Arity}, arguments := Specs}
                when is_atom(Library), is_atom(Function), is_integer(Arity), Arity >= 0,
                     is_list(Specs), length(Specs) =:= Arity ->
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
                {"seeds/00", Seed}, {"README.md", readme(Name, generic)}]);
        _ -> fail(invalid_entrypoint_or_argument_count)
    end.

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
        "include the adapter or models. Existing files are never overwritten.\n",
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
