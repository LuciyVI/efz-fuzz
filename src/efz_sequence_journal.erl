%% Append-only exact-byte sequence log. Dispatch is recorded before the target
%% call; buffered and fsynced modes have explicitly different durability.
-module(efz_sequence_journal).
-export([open/1, dispatch/3, completed/3, close/2, public/1, load/1, steps/2,
         initial_hash/0, next_hash/2]).

initial_hash() -> crypto:hash(sha256,<<"EFZ_SEQUENCE_1">>).
next_hash(Prefix,Input) when is_binary(Prefix),is_binary(Input) ->
    crypto:hash(sha256,<<Prefix/binary,(byte_size(Input)):64,Input/binary>>).

open(C) ->
    E=maps:get(execution,C),
    Root=filename:join(maps:get(crash_dir,C),"sequences"),
    Epoch=binary:encode_hex(crypto:strong_rand_bytes(16),lowercase),
    Path=filename:join(Root,binary_to_list(Epoch)++".jsonl"),
    case filelib:ensure_dir(Path) of
        ok -> case file:open(Path,[write,binary,raw,exclusive]) of
            {ok,Fd} ->
                Identity=crypto:hash(sha256,term_to_binary(
                    maps:get(execution_identities,C),[deterministic])),
                InitHash=crypto:hash(sha256,term_to_binary(
                    maps:get(target_init,E,#{}),[deterministic])),
                S=#{fd=>Fd,path=>Path,epoch=>Epoch,step=>0,prefix=>initial_hash(),
                    max_bytes=>maps:get(max_journal_bytes,E,16777216),bytes=>0,
                    durability=>maps:get(durability,E,buffered),complete=>false,
                    identity=>Identity,init_hash=>InitHash},
                Header=#{schema_version=>1,event=>header,epoch=>Epoch,
                    target=>atom_to_binary(maps:get(target,C),utf8),
                    identity_sha256=>binary:encode_hex(Identity,lowercase),
                    init_sha256=>binary:encode_hex(InitHash,lowercase),
                    coverage_backend=>atom_to_binary(maps:get(coverage_backend,C),utf8),
                    durability=>atom_to_binary(maps:get(durability,S),utf8)},
                case append(S,Header) of
                    {ok,Ready}->{ok,Ready};
                    {error,Why}->_=file:close(Fd),{error,Why}
                end;
            Error -> Error end;
        Error -> Error
    end.

dispatch(S,Input,Meta) when is_binary(Input),is_map(Meta) ->
    Step=maps:get(step,S)+1,Prefix=maps:get(prefix,S),Next=next_hash(Prefix,Input),
    Row0=#{schema_version=>1,event=>dispatch,epoch=>maps:get(epoch,S),
        step=>Step,prefix_sha256=>binary:encode_hex(Prefix,lowercase),
        next_sha256=>binary:encode_hex(Next,lowercase),
        input_sha256=>binary:encode_hex(crypto:hash(sha256,Input),lowercase),
        input_b64=>base64:encode(Input),
        phase=>atom_to_binary(maps:get(phase,Meta,mutation),utf8),
        parent=>maps:get(parent,Meta,0)},
    Row=maps:merge(Row0,recipe_fields(maps:get(recipe,Meta,undefined))),
    %% Reserve room for the completion and terminal rows so reaching the
    %% configured cap can still produce a complete replayable prefix.
    FrameBytes=byte_size(efz_control_json:encode(portable(Row)))+1,
    case maps:get(bytes,S)+FrameBytes+1024=<maps:get(max_bytes,S) of
        false->{error,journal_limit};
        true->case append(S,Row) of
            {ok,S1}->{ok,S1#{step=>Step,prefix=>Next}};
            Error->Error
        end
    end.

recipe_fields(#{rng:=#{seed:=Seed}}=Recipe) when is_tuple(Seed),tuple_size(Seed)=:=3 ->
    #{recipe_sha256=>binary:encode_hex(crypto:hash(sha256,
          term_to_binary(Recipe,[deterministic])),lowercase),
      recipe_schema=>maps:get(schema_version,Recipe,0),
      mutation_seed=>tuple_to_list(Seed),
      mutation_source=>atom_to_binary(maps:get(source_kind,Recipe,native),utf8)};
recipe_fields(_) -> #{}.

completed(S,Step,Result) ->
    Row=#{schema_version=>1,event=>completed,epoch=>maps:get(epoch,S),
        step=>Step,outcome=>outcome(maps:get(outcome,Result)),
        coverage_status=>case maps:get(coverage_status,Result,undefined) of
            ok-><<"ok">>;_-><<"invalid">> end,
        coverage_sha256=>binary:encode_hex(crypto:hash(sha256,
            term_to_binary(maps:get(coverage,Result,[]),[deterministic])),lowercase)},
    append(S,Row).

close(S,Reason) ->
    Row=#{schema_version=>1,event=>end_epoch,epoch=>maps:get(epoch,S),
        step=>maps:get(step,S),reason=>outcome(Reason),
        final_prefix_sha256=>binary:encode_hex(maps:get(prefix,S),lowercase)},
    Written=append(S,Row),
    _=file:close(maps:get(fd,S)),
    case Written of {ok,S1}->S1#{complete=>true,fd=>undefined,reason=>Reason};
        _->S#{complete=>false,fd=>undefined,reason=>Reason} end.

public(S) -> (maps:with([epoch,step,bytes,max_bytes,durability,complete,reason,
    identity,init_hash],S))#{path=>unicode:characters_to_binary(maps:get(path,S))}.

append(S,Row) ->
    Encoded=efz_control_json:encode(portable(Row)),
    Frame= <<Encoded/binary,"\n">>,
    case maps:get(bytes,S)+byte_size(Frame)=<maps:get(max_bytes,S) of
        false->{error,journal_limit};
        true->case file:write(maps:get(fd,S),Frame) of
            ok -> case sync(S) of
                ok->{ok,S#{bytes=>maps:get(bytes,S)+byte_size(Frame)}};
                Error->Error end;
            Error->Error end
    end.
sync(#{durability:=fsynced,fd:=Fd}) -> file:sync(Fd);
sync(_) -> ok.
portable(M) when is_map(M) -> maps:from_list([{key(K),portable(V)}||{K,V}<-maps:to_list(M)]);
portable(A) when is_atom(A)->atom_to_binary(A,utf8);
portable(V)->V.
key(A) when is_atom(A)->atom_to_binary(A,utf8);
key(B) when is_binary(B)->B.
outcome({ok,_})-><<"ok">>;
outcome({crash,_,_,_})-><<"crash">>;
outcome({timeout,_})-><<"timeout">>;
outcome({exit,_})-><<"exit">>;
outcome({infrastructure,_})-><<"infrastructure">>;
outcome(A) when is_atom(A)->atom_to_binary(A,utf8);
outcome(_)-><<"other">>.

load(Path) ->
    case file:read_file_info(Path) of
        {ok,Info} when element(2,Info)=<67108864 ->
            case file:read_file(Path) of
                {ok,Bytes}->decode_rows(binary:split(Bytes,<<"\n">>,[global]),[]);
                Error->Error end;
        {ok,_}->{error,journal_too_large};
        Error->Error
    end.
decode_rows([],Acc)->{ok,lists:reverse(Acc)};
decode_rows([<<>>],Acc)->{ok,lists:reverse(Acc)};
decode_rows([Line|Rest],Acc)->
    case efz_control_json:decode(Line) of
        {ok,Row} when is_map(Row)->decode_rows(Rest,[Row|Acc]);
        _->{error,damaged_journal}
    end.

steps(Path,C) ->
    case load(Path) of
        {ok,[Header|Rows]} ->
            Identity=binary:encode_hex(crypto:hash(sha256,term_to_binary(
                maps:get(execution_identities,C),[deterministic])),lowercase),
            Init=binary:encode_hex(crypto:hash(sha256,term_to_binary(
                maps:get(target_init,maps:get(execution,C),#{}),[deterministic])),lowercase),
            Backend=atom_to_binary(maps:get(coverage_backend,C),utf8),
            case {maps:get(<<"event">>,Header,undefined),
                  maps:get(<<"identity_sha256">>,Header,undefined),
                  maps:get(<<"init_sha256">>,Header,undefined),
                  maps:get(<<"coverage_backend">>,Header,undefined)} of
                {<<"header">>,Identity,Init,Backend}->read_steps(Rows,1,initial_hash(),[],false);
                _->{error,sequence_identity_mismatch}
            end;
        {ok,_}->{error,replay_incomplete};
        Error->Error
    end.
read_steps([],_,_,_,false)->{error,replay_incomplete};
read_steps([],_,_,_,true)->{error,damaged_journal};
read_steps([Row|Rest],Index,Prefix,Acc,_) ->
    case maps:get(<<"event">>,Row,undefined) of
        <<"dispatch">> ->
            try
                Index=maps:get(<<"step">>,Row),
                true=binary:encode_hex(Prefix,lowercase)=:=maps:get(<<"prefix_sha256">>,Row),
                B64=maps:get(<<"input_b64">>,Row),
                true=is_binary(B64) andalso byte_size(B64)=<1398104,
                Input=base64:decode(B64),
                B64=base64:encode(Input),
                true=binary:encode_hex(crypto:hash(sha256,Input),lowercase)=:=
                    maps:get(<<"input_sha256">>,Row),
                Next=next_hash(Prefix,Input),
                true=binary:encode_hex(Next,lowercase)=:=maps:get(<<"next_sha256">>,Row),
                read_steps(Rest,Index+1,Next,[Input|Acc],true)
            catch _:_->{error,damaged_journal} end;
        <<"completed">> -> read_steps(Rest,Index,Prefix,Acc,true);
        <<"end_epoch">> ->
            Hash=binary:encode_hex(Prefix,lowercase),
            case {Rest,maps:get(<<"step">>,Row,undefined),
                  maps:get(<<"final_prefix_sha256">>,Row,undefined)} of
                {[],End,Hash} when End=:=Index-1 ->
                    {ok,lists:reverse(Acc)};
                _->{error,damaged_journal}
            end;
        _->{error,damaged_journal}
    end.
