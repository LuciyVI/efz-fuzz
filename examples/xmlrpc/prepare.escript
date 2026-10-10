#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).

%% No downloader/build-system integration: the caller supplies a pinned checkout.
main([Source]) -> prepare(filename:absname(Source));
main([]) -> prepare(filename:absname("_build/xmlrpc-dependency"));
main(_) -> io:format(standard_error, "Usage: examples/xmlrpc/prepare.escript [etnt-xmlrpc-checkout]~n", []), halt(2).

prepare(Source) ->
    Pin = <<"fb46463b2acadf164ec534d9e2033e194341c507">>,
    case git(Source, ["rev-parse", "HEAD"]) of
        {0, CommitOut} ->
            case list_to_binary(string:trim(binary_to_list(CommitOut))) =:= Pin of
                true -> ok;
                false -> fail({xmlrpc_commit_mismatch, Pin, CommitOut})
            end;
        Error -> fail({xmlrpc_checkout_unavailable, Source, Error})
    end,
    case git(Source, ["diff", "--exit-code", "HEAD", "--", "src/xmlrpc_decode.erl", "src/xmlrpc_util.erl", "src/log.hrl"]) of
        {0, _} -> ok;
        Diff -> fail({xmlrpc_dependency_modified, Diff})
    end,
    Root = filename:dirname(filename:dirname(filename:dirname(filename:absname(escript:script_name())))),
    true = code:add_patha(filename:join([Root, "_build", "default", "lib", "efz", "ebin"])),
    Base = filename:join([Root, "_build", "xmlrpc-example"]),
    DependencyEbin = filename:join(Base, "dependency-ebin"),
    HarnessEbin = filename:join(Base, "harness-ebin"),
    lists:foreach(fun(Dir) -> ok = filelib:ensure_dir(filename:join(Dir, "placeholder")) end,
                  [DependencyEbin, HarnessEbin]),
    SrcDir = filename:join(Source, "src"),
    lists:foreach(fun(Name) ->
        compile_file(filename:join(SrcDir, atom_to_list(Name) ++ ".erl"), DependencyEbin,
                     [{i, SrcDir}])
    end, [xmlrpc_decode, xmlrpc_util]),
    compile_file(filename:join([Root, "examples", "xmlrpc", "efz_xmlrpc_target.erl"]), HarnessEbin, []),
    Artifacts = filename:join(Base, "instrumented"),
    lists:foreach(fun(Module) ->
        File = filename:join(SrcDir, atom_to_list(Module) ++ ".erl"),
        %% xmerl.hrl record defaults require preserved declarations; executable
        %% decoder clauses remain probed. xmerl itself is an ordinary OTP dependency.
        case efz_instrument:compile(File,
            #{modules => [Module], source_root => Source, outdir => Artifacts,
              erl_opts => [debug_info, warnings_as_errors, {i, SrcDir}],
              code_paths => [DependencyEbin], strict => false}) of
            {ok, _} -> ok;
            Failure -> fail({xmlrpc_instrumentation_failed, Module, Failure})
        end
    end, [xmlrpc_decode, xmlrpc_util]),
    Seeds = filename:join(Base, "seeds"),
    ok = filelib:ensure_dir(filename:join(Seeds, "placeholder")),
    Cases = [
        {"00-empty-call", <<"<methodCall><methodName>echo</methodName><params></params></methodCall>">>},
        {"01-int", <<"<methodCall><methodName>echo</methodName><params><param><value><int>42</int></value></param></params></methodCall>">>},
        {"02-string", <<"<methodCall><methodName>echo</methodName><params><param><value><string>&lt;&amp;&gt;</string></value></param></params></methodCall>">>},
        {"03-array", <<"<methodCall><methodName>echo</methodName><params><param><value><array><data><value><int>1</int></value><value><boolean>1</boolean></value></data></array></value></param></params></methodCall>">>},
        {"04-struct", <<"<methodCall><methodName>echo</methodName><params><param><value><struct><member><name>key</name><value><string>value</string></value></member></struct></value></param></params></methodCall>">>}
    ],
    %% Refuse to replace an existing seed with different bytes.
    lists:foreach(fun({Name, Bytes}) ->
        Path = filename:join(Seeds, Name),
        case file:read_file(Path) of
            {ok, Bytes} -> ok;
            {error, enoent} -> ok = file:write_file(Path, Bytes);
            Existing -> fail({seed_already_exists, Path, Existing})
        end
    end, Cases),
    Identity = #{repository => <<"https://github.com/etnt/xmlrpc">>, commit => Pin,
        sources => [{Module, hash(filename:join(SrcDir, atom_to_list(Module) ++ ".erl"))}
                    || Module <- [xmlrpc_decode, xmlrpc_util]]},
    ok = file:write_file(filename:join(Base, "dependency-identity.term"), io_lib:format("~tp.~n", [Identity])),
    io:format("Prepared pinned XML-RPC dependency, target-only coverage artifacts and ~B seeds in ~ts~n", [length(Cases), Base]).

compile_file(Source, Ebin, Extra) ->
    case compile:file(Source, [debug_info, warnings_as_errors, return_errors, return_warnings,
                               {outdir, Ebin} | Extra]) of
        {ok, _, []} -> ok;
        Other -> fail({xmlrpc_compile_failed, Source, Other})
    end.
hash(Path) -> {ok, Bytes} = file:read_file(Path), crypto:hash(sha256, Bytes).
fail(Why) -> io:format(standard_error, "XML-RPC preparation failed: ~tp~n", [Why]), halt(1).
git(Source, Args) ->
    case os:find_executable("git") of
        false -> fail(git_executable_missing);
        Git ->
            Port = open_port({spawn_executable, Git}, [binary, exit_status, use_stdio,
                stderr_to_stdout, {args, ["-C", Source | Args]}]),
            collect(Port, <<>>)
    end.
collect(Port, Output) ->
    receive
        {Port, {data, Data}} when byte_size(Output) + byte_size(Data) =< 65536 ->
            collect(Port, <<Output/binary, Data/binary>>);
        {Port, {data, _}} -> port_close(Port), fail(git_output_limit);
        {Port, {exit_status, Status}} -> {Status, Output}
    after 10000 -> port_close(Port), fail(git_timeout)
    end.
