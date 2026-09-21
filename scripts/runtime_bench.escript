#!/usr/bin/env escript
-mode(compile).
main([ModeText,Out|Optional])->
    Root=filename:dirname(filename:dirname(filename:absname(escript:script_name()))),
    Mode=case ModeText of "baseline"->baseline;"off"->off;"stability"->stability;
        "resources"->resources;"full"->full;_->error(invalid_mode) end,
    Ebin=case Optional of []->filename:join([Root,"_build","default","lib","efz","ebin"]);
        [Dir]->filename:absname(Dir);_->error(invalid_arguments) end,
    true=code:add_patha(Ebin),
    {ok,M,B}=compile:file(filename:join(Root,"bench/efz_runtime_bench.erl"),[binary,debug_info]),
    {module,M}=code:load_binary(M,"runtime-bench",B),
    _=efz_runtime_bench:run(Mode,Root,filename:absname(Out)),ok;
main(_)->io:put_chars("Usage: runtime_bench.escript baseline|off|stability|resources|full OUT [EFZ_EBIN]\n"),halt(2).
