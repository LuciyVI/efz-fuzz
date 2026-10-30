%% Local bytes only: no target, campaign or Erlang expression is evaluated.
-module(efz_mutate_cli).
-export([main/1]).

main(Args) ->
    try
        case parse(Args,#{}) of
            help->io:put_chars(help()),0;
            O->run(O)
        end
    catch
        throw:{mutation_cli,Code,R}->
            io:format(standard_error,"EFZ mutate: ~tp~n",[R]),Code;
        C:R->io:format(standard_error,"EFZ mutate infrastructure: ~tp:~tp~n",[C,R]),1
    end.

help()->
    "Usage: escript scripts/mutate.escript --input FILE --out NEWFILE --seed A,B,C [options]\n"
    "  --config FILE          Trusted provider map or #{mutation_provider => Map}\n"
    "  --mutation-provider native|erlamsa|hybrid (default: native)\n"
    "  --provider-core PATH   Trusted, compiled core checkout (required unless vendor/erlamsa)\n"
    "  --erlamsa-profile balanced|bytes|formats|fields\n"
    "  --provider-strategy preserve|perturb|mixed\n"
    "  --provider-timeout MS  Absolute isolated request deadline, 1..60000\n"
    "  --operator NAME       Enabled core operation; default: auto\n"
    "  --pattern once|many|burst|skip (default: auto)\n"
    "  --strategy preserve|perturb|mixed (default: auto)\n"
    "  --budget N            Maximum operations, 1..64 (default: 1)\n"
    "  --max-input-bytes N   Input/output bound, 0..1048576 (default: 4096)\n"
    "  --metadata NEWFILE    Optional bounded JSON result, effective config and identity\n"
    "CLI values override their own config fields; remaining config values override defaults.\n"
    "All three seed components are unsigned 64-bit integers. Outputs must not exist.\n"
    "Exit: 0 changed, 3 skipped (no output), 4 provider timeout, 2 bad config, 1 infrastructure failure.\n".

parse([],O)->O;
parse(["--help"],_)->help;
parse([Flag,Value|Rest],O)->
    K=key(Flag),
    require(not maps:is_key(K,O),{duplicate_option,Flag}),
    require(not lists:prefix("--",Value),{missing_value,Flag}),
    parse(Rest,O#{K=>value(K,Value)});
parse([Flag],_)->fail(2,{missing_value,Flag}).
key("--input")->input;
key("--out")->out;
key("--seed")->seed;
key("--config")->config;
key("--metadata")->metadata;
key("--mutation-provider")->provider_mode;
key("--provider-core")->provider_core;
key("--erlamsa-profile")->provider_profile;
key("--provider-strategy")->provider_strategy;
key("--provider-timeout")->provider_timeout;
key("--operator")->operator;
key("--pattern")->pattern;
key("--strategy")->strategy;
key("--budget")->budget;
key("--max-input-bytes")->max_input_bytes;
key(F)->fail(2,{unknown_option,F}).
value(seed,S)->
    case string:split(S,",",all) of
        [A,B,C]->list_to_tuple([number(X,0,(1 bsl 64)-1)||X<-[A,B,C]]);
        _->fail(2,invalid_seed)
    end;
value(provider_mode,S)->enum(S,[native,erlamsa,hybrid]);
value(provider_profile,S)->enum(S,[balanced,bytes,formats,fields]);
value(K,S) when K=:=provider_strategy;K=:=strategy->enum(S,[preserve,perturb,mixed]);
value(operator,S)->enum(S,[auto|efz_mutation_provider:operators()]);
value(pattern,S)->enum(S,[auto,once,many,burst,skip]);
value(provider_timeout,S)->number(S,1,60000);
value(budget,S)->number(S,1,64);
value(max_input_bytes,S)->number(S,0,1048576);
value(_,S)->require(S=/=[],empty_path),filename:absname(S).
number(S,Min,Max)->
    require(S=/=[] andalso lists:all(fun(C)->C>=$0 andalso C=<$9 end,S),invalid_integer),
    N=list_to_integer(S),require(N>=Min andalso N=<Max,{integer_range,Min,Max}),N.
enum(S,Allowed)->case [A||A<-Allowed,atom_to_list(A)=:=S] of
    [A]->A;_->fail(2,{unsupported_name,S}) end.

run(O)->
    [require(maps:is_key(K,O),{required,K})||K<-[input,out,seed]],
    Max=maps:get(max_input_bytes,O,4096),
    Input=need(efz_fs:read_bounded(maps:get(input,O),Max),2),
    Base=configuration(O),
    Provider=try efz_cli:provider_options(Base,O)
        catch throw:{cli_error,ConfigError}->fail(2,ConfigError) end,
    Prepared=need(efz_mutation_provider:prepare(Provider,Max),2),
    Request=maps:with([seed,operator,pattern,strategy,budget],O),
    case efz_mutation_provider:mutate(Input,Request,Prepared) of
        {ok,Bytes,Recipe}->
            need(efz_fs:write_file(maps:get(out,O),Bytes),1),
            metadata(O,#{status=>changed,input_sha256=>crypto:hash(sha256,Input),
                output_sha256=>crypto:hash(sha256,Bytes),request=>Request,
                provider=>efz_mutation_provider:effective(Prepared),recipe=>Recipe}),0;
        {skip,R}->metadata(O,#{status=>skipped,reason=>R}),fail(3,{skipped,R});
        {timeout,R}->fail(4,{provider_timeout,R});
        cancelled->fail(1,cancelled);
        {error,R}->fail(1,{provider_failure,R})
    end.
configuration(O)->case maps:find(config,O) of
    error->native;
    {ok,Path}->
        _=need(efz_fs:read_bounded(Path,1048576),2),
        case file:consult(Path) of
            {ok,[#{mutation_provider:=P}]}->P;
            {ok,[P]} when is_map(P);P=:=native;P=:=erlamsa;P=:=hybrid->P;
            Other->fail(2,{invalid_trusted_provider_config,Other})
        end
end.
metadata(O,M)->case maps:find(metadata,O) of
    error->ok;
    {ok,Path}->need(efz_fs:write_file(Path,efz_control_json:encode(efz_control_json:portable(M))),1)
end.
need(ok,_)->ok;
need({ok,V},_)->V;
need({error,R},Code)->fail(Code,R).
require(true,_)->ok;
require(false,R)->fail(2,R).
-spec fail(pos_integer(),term()) -> no_return().
fail(Code,R)->throw({mutation_cli,Code,R}).
