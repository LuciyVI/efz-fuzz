#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).

%% Compile the supplied pinned checkout. This command never downloads code.
main([]) -> main(["_build/xmlrpc-dependency"]);
main([Source0]) ->
    try
        Source = filename:absname(Source0),
        Pin = <<"fb46463b2acadf164ec534d9e2033e194341c507">>,
        {0, Commit} = git(Source, ["rev-parse", "HEAD"]),
        true = string:trim(Commit) =:= Pin,
        Names = ["src/xmlrpc_decode.erl", "src/xmlrpc_encode.erl",
                 "src/xmlrpc_util.erl", "src/log.hrl"],
        {0, <<>>} = git(Source, ["diff", "--exit-code", "HEAD", "--" | Names]),
        Src = filename:join(Source, "src"),
        Ebin = filename:absname("_build/xmlrpc-example/dependency-ebin"),
        ok = filelib:ensure_dir(filename:join(Ebin, "placeholder")),
        Modules = [xmlrpc_decode, xmlrpc_encode, xmlrpc_util],
        lists:foreach(fun(M) ->
            File = filename:join(Src, atom_to_list(M) ++ ".erl"),
            case compile:noenv_file(File, [debug_info, warnings_as_errors,
                return_errors, return_warnings, {i, Src}, {outdir, Ebin}]) of
                {ok, M, []} -> ok;
                Other -> error({dependency_compile_failed, M, Other})
            end
        end, Modules),
        Identity = #{schema_version => 1, repository => <<"https://github.com/etnt/xmlrpc">>,
            commit => Pin, sources => [{Name, hash(filename:join(Source, Name))} || Name <- Names],
            beams => [{M, hash(filename:join(Ebin, atom_to_list(M) ++ ".beam"))} || M <- Modules]},
        ok = file:write_file("_build/xmlrpc-example/flow-dependency-identity.term",
            unicode:characters_to_binary(io_lib:format("~tp.~n", [Identity]))),
        io:format("Prepared pinned XML-RPC encode/decode/util in ~ts~n", [Ebin])
    catch Class:Reason ->
        io:format(standard_error, "XML-RPC flow preparation failed: ~p:~tp~n", [Class, Reason]),
        halt(1)
    end;
main(_) ->
    io:format(standard_error, "Usage: examples/xmlrpc/prepare_flows.escript [PINNED_CHECKOUT]~n", []),
    halt(2).

hash(Path) -> {ok, Bytes} = file:read_file(Path), crypto:hash(sha256, Bytes).
git(Source, Args) ->
    Exe = os:find_executable("git"),
    true = is_list(Exe),
    Port = open_port({spawn_executable, Exe}, [binary, exit_status, use_stdio,
        stderr_to_stdout, {args, ["-C", Source | Args]}]),
    collect(Port, <<>>).
collect(Port, Output) ->
    receive
        {Port, {data, Data}} when byte_size(Output) + byte_size(Data) =< 65536 ->
            collect(Port, <<Output/binary, Data/binary>>);
        {Port, {data, _}} -> port_close(Port), error(git_output_limit);
        {Port, {exit_status, Status}} -> {Status, Output}
    after 10000 -> port_close(Port), error(git_timeout)
    end.
