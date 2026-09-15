#!/usr/bin/env escript
-mode(compile).
main([Dir]) ->
    true = code:add_patha("_build/default/lib/efz/ebin"),
    F = filename:join(Dir, "audit_harness.erl"),
    {ok, audit_harness, Beam} = compile:noenv_file(F, [binary, debug_info]),
    {module, audit_harness} = code:load_binary(audit_harness, F, Beam),
    {ok, AB} = file:read_file(filename:join(Dir, "artifact.term")),
    Artifact = binary_to_term(AB),
    [RecipeFile] = filelib:wildcard(filename:join([Dir, "crashes", "*.recipe"])),
    {ok, Recipe} = efz_recipe:load(RecipeFile),
    {ok, Input} = efz_recipe:regenerate(Recipe),
    {ok, Input} = file:read_file(filename:rootname(RecipeFile) ++ ".input"),
    {ok, Result} = efz_recipe:execute(Input, audit_harness, [Artifact],
        maps:get(target_builds, Recipe), #{timeout => 1000}),
    {crash, error, test_crash, _} = maps:get(outcome, Result),
    ok = maps:get(coverage_status, Result),
    io:format("FRESH_VM_REPLAY_PASS input=~p bytes=~p coverage=~p~n",
        [Input,byte_size(Input),length(maps:get(coverage,Result))]).
