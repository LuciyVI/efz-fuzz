#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).
main([Dir]) -> main([Dir,"12"]);
main([Dir,CountText]) ->
    Root=filename:dirname(filename:dirname(filename:absname(escript:script_name()))),
    true=code:add_patha(filename:join([Root,"_build","gleam","lib","efz","ebin"])),
    Count=list_to_integer(CountText),true=Count>=1 andalso Count=<64,
    {ok,_}=efz_gleam_adapter:prepare(#{structured_fraction=>0},
        #{target=>efz_qs_target,mutation_mode=>staged,max_input_bytes=>4096,manifests=>[],mutation=>#{}}),
    true=erlang:function_exported(efz_qs_model,generator_version,0),
    2=efz_qs_model:generator_version(),
    false=filelib:is_dir(Dir),false=filelib:is_file(Dir++".manifest.term"),
    ok=filelib:ensure_dir(filename:join(Dir,"0.qs")),
    L=efz_gleam_adapter:limits(efz_gleam_adapter:defaults()),
    {Rows,Total}=generate(0,Count,Dir,L,[],0),
    Manifest=#{schema_version=>2,versions=>efz_gleam_adapter:versions(),generator=>indices,
        generator_version=>2,indices=>{0,Count-1},target=><<"cow_qs">>,
        gleam=>"1.10.0",limits=>L,total_bytes=>Total,max_total_bytes=>65536,seeds=>Rows},
    ok=efz_fs:atomic_file(Dir++".manifest.term",term_to_binary(Manifest)),
    io:format("Generated ~p raw seeds (~p bytes); manifest ~ts.manifest.term~n",[Count,Total,Dir]);
main(_)->io:format("Usage: escript scripts/gleam_seeds.escript NEW_DIRECTORY [COUNT]\n"),halt(2).

generate(Count,Count,_,_,Rows,Total)->{lists:reverse(Rows),Total};
generate(I,Count,Dir,L,Rows,Total)->
        {ok,B}=efz_gleam_adapter:generate(I,L),
        %% Count/individual-byte checks precede core allocation; total is
        %% checked before this seed is written to the new output directory.
        NextTotal=Total+byte_size(B),true=NextTotal=<65536,
        Path=filename:join(Dir,integer_to_list(I)++".qs"),
        %% Refuse overwrite of any existing user's seed.
        {ok,F}=file:open(Path,[write,binary,exclusive]),ok=file:write(F,B),ok=file:close(F),
        generate(I+1,Count,Dir,L,[{I,crypto:hash(sha256,B),byte_size(B)}|Rows],NextTotal).
