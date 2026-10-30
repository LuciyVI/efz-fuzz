-module(efz_replay_cli).
-export([main/1]).

main(["--help"]) -> io:put_chars(help()),0;
main(["--external-finding"|Rest])->efz_external:main(["--supervised","--external-finding"|Rest]);
main([R,O|Rest]) when hd(R)=/=$-,hd(O)=/=$- -> regenerate(R,O,Rest);
main(Args) ->
    try launch(parse(Args,#{}))
    catch
        throw:{usage,Why}->io:format(standard_error,"EFZ replay: ~ts~n",[Why]),2;
        Class:Why->io:format(standard_error,"EFZ replay infrastructure: ~tp:~tp~n",[Class,Why]),1
    end.
help() ->
    "Usage: replay.escript --input FILE.input | --recipe FILE.recipe\n"
    "       --target MODULE --artifacts DIR [--code-path DIR] [--expect FILE.replay]\n"
    "       Or: --runtime-finding DIRECTORY --target MODULE --artifacts DIR [--runs N]\n"
    "       Or: --external-finding DIRECTORY --target MODULE --artifacts DIR --out DIR [--reproduce-runs N]\n"
    "       [--timeout MS] [--max-input-bytes N]\n"
    "Expected build, harness identity and crash signature are required; default expectation\n"
    "is the sibling .replay file. Raw .input is authoritative and does not need .recipe/.term.\n"
    "--code-path is repeatable. Target contract is Module:run(binary()).\n"
    "Exit: 0 reproduced; 3 not-reproduced; 2 invalid invocation/compatibility; 1 infrastructure.\n"
    "Bytes only (legacy): replay.escript RECIPE OUTPUT_INPUT [--max-input-bytes N]\n"
    "Verify provider generation: --recipe FILE.recipe --provider-config TRUSTED.term\n"
    "       --provider-regenerate NEW_OUTPUT [--max-input-bytes N]\n"
    "Provider regeneration runs no target and requires matching build/config identities.\n".
parse([],O)->O;
parse([Flag,Value|Rest],O)->
    Key=case Flag of
        "--runtime-finding"->runtime_finding;"--runs"->runs;
        "--input"->raw;"--recipe"->recipe;"--target"->target;"--artifacts"->artifacts;
        "--expect"->expect;"--code-path"->code_paths;"--timeout"->timeout;
        "--provider-config"->provider_config;"--provider-regenerate"->provider_regenerate;
        "--max-input-bytes"->max_input_bytes;_->usage("Unknown option: "++Flag)
    end,
    case Value of "--"++_->usage("Missing value: "++Flag);[]->usage("Empty value: "++Flag);_->ok end,
    V=case Key of
        runs->number(Value);timeout->number(Value);max_input_bytes->number(Value);
        target when length(Value)=<255->Value;
        target->usage("Target module name is too long");_->Value
    end,
    case Key of
        code_paths->parse(Rest,O#{Key=>maps:get(Key,O,[])++[V]});
        _->case maps:is_key(Key,O) of true->usage("Duplicate option: "++Flag);false->parse(Rest,O#{Key=>V}) end
    end;
parse(_,_) -> usage("Missing option value; use --help").
number(S)->case S=/=[] andalso lists:all(fun(C)->C>=$0 andalso C=<$9 end,S) of
    true->list_to_integer(S);false->usage("Expected nonnegative integer") end.
launch(#{provider_regenerate:=Out}=O)->provider_regenerate(Out,O);
launch(#{runtime_finding:=Path}=O)->
    case maps:keys(O)--[runtime_finding,target,artifacts,code_paths,runs] of
        []->ok;_->usage("Runtime replay accepts only --runtime-finding, --target, --artifacts, --code-path, --runs") end,
    lists:foreach(fun(P)->true=code:add_pathz(filename:absname(P)) end,maps:get(code_paths,O,[])),
    case maps:is_key(target,O) andalso maps:is_key(artifacts,O) of
        false->usage("--target and --artifacts are required");true->ok end,
    case efz_instrument:discover(maps:get(artifacts,O)) of
        {ok,As}->case efz_cli:local_target(maps:get(target,O),As) of
            {ok,M}->case efz_replay:runtime(Path,M,As,maps:with([runs],O)) of
                {ok,R}->io:format("~tp~n",[R]),case maps:get(status,R) of observed->0;_->3 end;
                Error->result(Error) end;
            Error->result(Error) end;
        Error->result(Error) end;
launch(O)->
    case maps:is_key(provider_config,O) of true->usage("--provider-config requires --provider-regenerate");false->ok end,
    case maps:is_key(runs,O) of true->usage("--runs requires --runtime-finding");false->ok end,
    case [K||K<-[target,artifacts],not maps:is_key(K,O)] of
        []->ok;_->usage("--target and --artifacts are required") end,
    {Kind,Path}=case {maps:find(raw,O),maps:find(recipe,O)} of
        {{ok,P},error}->{raw,P};{error,{ok,P}}->{recipe,P};_->usage("Specify exactly one of --input / --recipe")
    end,
    lists:foreach(fun(P)->case code:add_pathz(filename:absname(P)) of true->ok;_->usage("Invalid code path: "++P) end end,
        maps:get(code_paths,O,[])),
    ExpectPath=maps:get(expect,O,filename:rootname(Path)++".replay"),
    case {efz_replay:load(ExpectPath),efz_instrument:discover(maps:get(artifacts,O))} of
        {{ok,E},{ok,As}} -> case efz_cli:local_target(maps:get(target,O),As) of
            {ok,M}->result(efz_replay:run(Kind,Path,M,As,E,maps:with([timeout,max_input_bytes],O)));
            Error->result(Error) end;
        {{error,Why},_}->rejected(Why);
        {_,{error,Why}}->rejected(Why)
    end.
provider_regenerate(Out,O)->
    case maps:keys(O)--[recipe,provider_config,provider_regenerate,max_input_bytes] of
        []->ok;_->usage("Provider regeneration accepts only --recipe, --provider-config, --provider-regenerate, --max-input-bytes")
    end,
    case maps:is_key(recipe,O) andalso maps:is_key(provider_config,O) of
        true->ok;false->usage("Provider regeneration requires --recipe and --provider-config")
    end,
    ConfigPath=maps:get(provider_config,O),
    case efz_fs:read_bounded(ConfigPath,1048576) of
        {ok,_}->case file:consult(ConfigPath) of
            {ok,[#{mutation_provider:=Provider}=C]}->
                provider_generate(Out,O,Provider,maps:get(max_input_bytes,C,efz_input:default_limit()));
            {ok,[Provider]} when is_map(Provider);Provider=:=erlamsa;Provider=:=hybrid->
                provider_generate(Out,O,Provider,efz_input:default_limit());
            _->usage("Trusted provider config must contain one provider map or campaign map with mutation_provider")
        end;
        E->result(E)
    end.
provider_generate(Out,O,Provider,DefaultMax)->
    Max=maps:get(max_input_bytes,O,DefaultMax),
    case efz_recipe:load(maps:get(recipe,O)) of
        {ok,R}->case efz_recipe:regenerate(R,#{max_input_bytes=>Max}) of
            {ok,_}->case efz_mutation_provider:prepare(Provider,Max) of
                {ok,P}->case efz_recipe:regenerate_provider(R,P) of
                    {ok,B}->case efz_fs:write_file(Out,B) of
                        ok->io:format("Provider generation verified; ~B bytes; SHA-256 ~s~n",
                            [byte_size(B),binary:encode_hex(crypto:hash(sha256,B),lowercase)]),0;
                        E->result(E)
                    end;
                    E->result(E)
                end;
                E->result(E)
            end;
            E->result(E)
        end;
        E->result(E)
    end.
result({ok,#{status:=Status,input_hash:=H}})->
    Text=case Status of reproduced->"reproduced";not_reproduced->"not-reproduced" end,
    io:format("~s; build/harness compatibility verified; input SHA-256 ~s~n",[Text,binary:encode_hex(H,lowercase)]),
    case Status of reproduced->0;not_reproduced->3 end;
result({error,Why})->rejected(Why).
rejected(Why)->
    io:format(standard_error,"EFZ replay rejected: ~tp~n",[Why]),
    error_exit(Why).
error_exit(#{kind:=filesystem,reason:=file_size_limit})->2;
error_exit(#{kind:=K}) when K=:=filesystem;K=:=replay_infrastructure->1;
error_exit({provider_recipe_error,_})->1;
error_exit({provider_recipe_timeout,_})->1;
error_exit(provider_recipe_cancelled)->1;
%% Discovery/preflight retain the existing instrumentation error protocol.
%% Its IO failures are infrastructure failures too, not build mismatches.
error_exit({artifact_directory,_,_})->1;
error_exit({missing_artifacts,_,_})->1;
error_exit({invalid_instrumented_beam,_,{beam_attributes,{error,beam_lib,{file_error,_,_}}}})->1;
error_exit(_)->2.
regenerate(R,O,Rest)->
    try
        Max=case Rest of []->efz_input:default_limit();["--max-input-bytes",N]->number(N);_->usage("Invalid byte regeneration arguments") end,
        {ok,Recipe}=efz_recipe:load(R),{ok,B}=efz_recipe:regenerate(Recipe,#{max_input_bytes=>Max}),
        ok=efz_fs:atomic_file(O,B),
        io:format("Regenerated ~B bytes, SHA-256 ~s~n",[byte_size(B),binary:encode_hex(crypto:hash(sha256,B),lowercase)]),0
    catch Class:Why->io:format(standard_error,"EFZ replay: ~tp:~tp~n",[Class,Why]),1 end.
-spec usage(string()) -> no_return().
usage(Why)->throw({usage,Why}).
