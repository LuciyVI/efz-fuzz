#!/usr/bin/env escript
-mode(compile).
main(Args) ->
    Ebin=case os:getenv("EFZ_PERF_EBIN") of false->"_build/default/lib/efz/ebin";P->P end,
    true = code:add_patha(Ebin),
    lists:foreach(fun(File) ->
        {ok, M, Beam} = compile:noenv_file(File, [binary, debug_info, warnings_as_errors]),
        {module, M} = code:load_binary(M, File, Beam)
    end, ["bench/efz_perf_replay.erl", "bench/efz_perf_loop_target.erl", "bench/efz_perf.erl"]),
    {Stage, Out, Variants} = case Args of
        [S, O] -> {list_to_existing_atom(S), O, [reference, member, prepared, prepared_member]};
        [S, O, "reference"] -> {list_to_existing_atom(S), O, [reference]};
        [S, O, "member"] -> {list_to_existing_atom(S), O, [member]};
        [S, O, "prepared"] -> {list_to_existing_atom(S), O, [prepared]};
        [S, O, "prepared_member"] -> {list_to_existing_atom(S), O, [prepared_member]};
        _ -> error("usage: escript bench/run.escript all|hooks|executor|campaign|memory|startup OUT [VARIANT]")
    end,
    efz_perf:main(Stage, Out, Variants).
