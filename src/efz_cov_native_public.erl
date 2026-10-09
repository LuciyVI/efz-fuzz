%% Experimental OTP 27 line coverage. Only documented code:* coverage APIs
%% touch VM coverage storage; all state returned to EFZ is owned Erlang data.
-module(efz_cov_native_public).
-export([compile/2, compile/3, preflight/1, prepare/1, valid/2, live/1, open/1, open_profiled/1, attach/1,
         collect/1, close/1, has_new/2, unseen/2, merge/2, decode/2,
         empty/1, count/1, modules/2, read_raw/1, convert_raw/2,
         collect_profiled/1]).

compile(Source, Out) -> compile(Source,Out,[]).
%% Ordinary parser dependencies may have headers outside their source directory.
compile(Source, Out, Includes) ->
    case compile:noenv_file(Source, [binary, line_coverage, debug_info,
                                      warnings_as_errors, return_errors]++[{i,D}||D<-Includes]) of
        {ok,M,Beam} -> write_artifact(M,Beam,Out);
        {ok,M,Beam,[]} -> write_artifact(M,Beam,Out);
        Error -> {error,{native_compilation,Error}}
    end.
write_artifact(M,Beam,Out) ->
    Path=filename:absname(filename:join(Out,atom_to_list(M)++".beam")),
    ok=filelib:ensure_dir(Path),
    ok=file:write_file(Path,Beam),
    {ok,{M,MD5}}=beam_lib:md5(Beam),
    {ok,#{module=>M,beam=>Path,build_id=>crypto:hash(sha256,Beam),
           beam_md5=>MD5,coverage_kind=>otp_native_line}}.

preflight([]) -> {error,automatic_coverage_requires_artifacts};
preflight(Artifacts) when is_list(Artifacts) ->
    Support=try {code:coverage_support(),code:get_coverage_mode()}
            catch error:undef -> unavailable end,
    case Support of
        {true,none} ->
            %% OTP 27.0 documents and accepts 'line', but code.erl's
            %% coverage_mode() spec spells it 'line_coverage'. This startup
            %% apply avoids a false Dialyzer contract error for that OTP bug.
            _=apply(code,set_coverage_mode,[line]),
            preflight_modules(Artifacts,#{},[]);
        {true,Mode} -> case atom_to_binary(Mode,utf8) of
            <<"line">> -> preflight_modules(Artifacts,#{},[]);
            _ -> {error,{otp_native_line_unavailable,Support}}
        end;
        Other -> {error,{otp_native_line_unavailable,Other}}
    end;
preflight(_) -> {error,invalid_artifacts}.
preflight_modules([],_,Acc) -> {ok,lists:reverse(Acc)};
preflight_modules([#{module:=M,beam:=Path,build_id:=Build,beam_md5:=MD5,
                     coverage_kind:=otp_native_line}|Rest],Seen,Acc) when is_atom(M) ->
    case maps:is_key(M,Seen) of
        true -> {error,{duplicate_selected_module,M}};
        false ->
            case file:read_file(Path) of
                {ok,Beam} -> case crypto:hash(sha256,Beam)=:=Build of
                    true ->
                    case beam_lib:md5(Beam) of
                        {ok,{M,MD5}} ->
                            case ensure_loaded(M,Path,Beam,MD5) of
                                ok -> case atom_to_binary(code:get_coverage_mode(M),utf8) of
                                <<"line">> ->
                                            Lines=code:get_coverage(line,M),
                                            case lists:all(fun({L,V})->is_integer(L) andalso L>0 andalso
                                                      is_boolean(V) end,Lines) of
                                                true -> Entry=#{module=>M,beam=>Path,build_id=>Build,
                                                    beam_md5=>MD5,coverage_kind=>otp_native_line,
                                                    lines=>[L||{L,_}<-Lines]},
                                                    preflight_modules(Rest,Seen#{M=>true},[Entry|Acc]);
                                                false -> {error,{invalid_native_lines,M}}
                                            end;
                                    Mode -> {error,{invalid_native_coverage_mode,M,Mode}}
                                end;
                                Error -> Error
                            end;
                        _ -> {error,{native_artifact_identity,M}}
                    end;
                    false -> {error,{native_artifact_identity,M}}
                end;
                _ -> {error,{native_artifact_identity,M}}
            end
    end;
preflight_modules(_,_,_) -> {error,invalid_native_artifacts}.
ensure_loaded(M,Path,Beam,MD5) ->
    case code:is_loaded(M) of
        false -> case code:load_binary(M,Path,Beam) of
            {module,M} -> ok;
            Error -> {error,{native_load,M,Error}}
        end;
        _ -> case erlang:get_module_info(M,md5) of
            MD5 -> ok;
            _ -> {error,{native_module_already_loaded,M}}
        end
    end.

prepare(Manifests) ->
    Entries=[{maps:get(module,X),maps:get(build_id,X),maps:get(beam_md5,X),
              maps:get(lines,X)} || X<-Manifests],
    %% Corpus metadata requires a positive integer in the third identity
    %% position. For this backend it denotes an OTP executable line.
    Slots=[{M,B,L} || {M,B,_,Ls}<-Entries,L<-Ls],
    Bits=length(Slots),
    Bytes=(Bits+7) div 8,
    Fingerprint=crypto:hash(sha256,term_to_binary({Entries,Slots,Bits,Bytes},[deterministic])),
    #{kind=>otp_native_line,entries=>Entries,slots=>Slots,bits=>Bits,
      bytes=>Bytes,fingerprint=>Fingerprint}.
valid(#{kind:=otp_native_line,entries:=Entries,fingerprint:=Hash}=Schema,Builds) ->
    try
    Slots=maps:get(slots,Schema),Bits=maps:get(bits,Schema),Bytes=maps:get(bytes,Schema),
    Hash=:=crypto:hash(sha256,term_to_binary({Entries,Slots,Bits,Bytes},[deterministic])) andalso
    Bytes=:=(Bits+7) div 8 andalso Bits=:=length(Slots) andalso
    Builds=:=maps:from_list([{M,B} || {M,B,_,_}<-Entries]) andalso
    live(Schema)
    catch _:_ -> false end;
valid(_,_) -> false.
live(#{kind:=otp_native_line,entries:=Entries}) ->
    try lists:all(fun({M,_,MD5,_})->
        try erlang:get_module_info(M,md5)=:=MD5 andalso
            atom_to_binary(code:get_coverage_mode(M),utf8)=:=<<"line">>
        catch _:_ -> false end
    end,Entries) catch _:_ -> false end;
live(_) -> false.

open(Schema) ->
    case live(Schema) of
        true ->
            lists:foreach(fun({M,_,_,_})->ok=code:reset_coverage(M) end,
                          maps:get(entries,Schema)),
            {efz_context,1,make_ref(),{otp_native_public,Schema},self()};
        false -> error({efz_infrastructure,invalid_native_schema})
    end.
open_profiled(Schema) ->
    case live(Schema) of
        true ->
            Start=erlang:monotonic_time(microsecond),
            lists:foreach(fun({M,_,_,_})->ok=code:reset_coverage(M) end,
                          maps:get(entries,Schema)),
            ResetUs=erlang:monotonic_time(microsecond)-Start,
            {{efz_context,1,make_ref(),{otp_native_public,Schema},self()},ResetUs};
        false -> error({efz_infrastructure,invalid_native_schema})
    end.
attach({efz_context,1,Ref,{otp_native_public,_},Owner}=Context)
  when is_reference(Ref),is_pid(Owner) ->
    put('$efz_execution_context',Context),ok.
close(_) -> ok.

collect(Schema) ->
    case read_raw(Schema) of
        {ok,Raw} -> convert_raw(Schema,Raw);
        Error -> Error
    end.
collect_profiled(Schema) ->
    Start=erlang:monotonic_time(microsecond),
    case live(Schema) of
        false -> {error,invalid_native_schema};
        true ->
            case read_entries_profiled(maps:get(entries,Schema),[],0) of
                {ok,Raw,GetUs} ->
                    ReadUs=erlang:monotonic_time(microsecond)-Start,
                    ConvertStart=erlang:monotonic_time(microsecond),
                    case convert_raw(Schema,Raw) of
                        {ok,Bits} ->
                            {ok,Bits,#{native_read_us=>ReadUs,
                                get_coverage_us=>GetUs,
                                conversion_us=>erlang:monotonic_time(microsecond)-ConvertStart}};
                        Error -> Error
                    end;
                Error -> Error
            end
    end.
read_entries_profiled([],Acc,GetUs) -> {ok,lists:reverse(Acc),GetUs};
read_entries_profiled([{M,_,_,_}|Rest],Acc,GetUs) ->
    Start=erlang:monotonic_time(microsecond),
    try code:get_coverage(line,M) of
        Raw when is_list(Raw) ->
            Delta=erlang:monotonic_time(microsecond)-Start,
            read_entries_profiled(Rest,[{M,Raw}|Acc],GetUs+Delta)
    catch _:_ -> {error,{native_coverage_read,M}} end.
read_raw(Schema) ->
    case live(Schema) of
        false -> {error,invalid_native_schema};
        true -> read_entries(maps:get(entries,Schema),[])
    end.
read_entries([],Acc) -> {ok,lists:reverse(Acc)};
read_entries([{M,_,_,_}|Rest],Acc) ->
    try code:get_coverage(line,M) of
        Raw when is_list(Raw) -> read_entries(Rest,[{M,Raw}|Acc])
    catch _:_ -> {error,{native_coverage_read,M}} end.
convert_raw(Schema,Raw) ->
    case convert_entries(maps:get(entries,Schema),Raw,[]) of
        {ok,Rev} -> finish_conversion(Rev,Schema);
        Error -> Error
    end.
finish_conversion(Rev,Schema) ->
    Flags=lists:reverse(Rev),
    Bits=encode(Flags),
    case byte_size(Bits)=:=maps:get(bytes,Schema) of
        true -> {ok,Bits};
        false -> {error,invalid_native_observation_size}
    end.
convert_entries([],[],Rev) -> {ok,Rev};
convert_entries([{M,_,_,Lines}|Rest],[{M,Raw}|Rows],Rev) ->
    case append_flags(Lines,Raw,Rev) of
        {ok,Next} -> convert_entries(Rest,Rows,Next);
        error -> {error,{native_line_layout_changed,M}}
    end;
convert_entries(_,_,_) -> {error,invalid_native_observation}.
append_flags([],[],Acc) -> {ok,Acc};
append_flags([L|Ls],[{L,V}|Rs],Acc) when is_boolean(V) ->
    append_flags(Ls,Rs,[V|Acc]);
append_flags(_,_,_) -> error.
encode(Flags) -> list_to_binary(lists:reverse(encode_bytes(Flags,[]))).
encode_bytes([],Acc) -> Acc;
encode_bytes(Flags,Acc) ->
    {Remaining,Byte}=take_byte(Flags,0,0),
    encode_bytes(Remaining,[Byte|Acc]).
take_byte([],_,Byte) -> {[],Byte};
take_byte(Flags,8,Byte) -> {Flags,Byte};
take_byte([V|Rest],N,Byte) ->
    take_byte(Rest,N+1,Byte bor (case V of true -> 1 bsl N; false -> 0 end)).

empty(Schema) -> binary:copy(<<0>>,maps:get(bytes,Schema)).
has_new(<<>>,<<>>) -> false;
has_new(<<G,GR/binary>>,<<C,CR/binary>>) ->
    ((C band (bnot G))=/=0) orelse has_new(GR,CR).
unseen(Global,Current) -> combine(Global,Current,diff,[]).
merge(Global,Current) -> combine(Global,Current,union,[]).
combine(<<>>,<<>>,_,Acc) -> list_to_binary(lists:reverse(Acc));
combine(<<G,GR/binary>>,<<C,CR/binary>>,diff,Acc) ->
    combine(GR,CR,diff,[(C band (bnot G)) band 255|Acc]);
combine(<<G,GR/binary>>,<<C,CR/binary>>,union,Acc) ->
    combine(GR,CR,union,[G bor C|Acc]).
count(Bits) -> lists:sum([popcount(B,0) || <<B>> <= Bits]).
popcount(0,N) -> N;
popcount(B,N) -> popcount(B band (B-1),N+1).
decode(Schema,Bits) -> decode(maps:get(slots,Schema),Bits,0,[]).
decode([],_,_,Acc) -> lists:reverse(Acc);
decode([Slot|Rest],Bits,N,Acc) ->
    Byte=binary:at(Bits,N div 8),
    decode(Rest,Bits,N+1,case Byte band (1 bsl (N rem 8)) of
        0 -> Acc;
        _ -> [Slot|Acc]
    end).
modules(Schema,Bits) ->
    modules(maps:get(entries,Schema),Bits,0,[]).
modules([],_,_,Acc) -> lists:reverse(Acc);
modules([{M,_,_,Lines}|Rest],Bits,Start,Acc) ->
    Count=length(Lines),
    Next=case any_set(Bits,Start,Count) of true -> [M|Acc];false -> Acc end,
    modules(Rest,Bits,Start+Count,Next).
any_set(_,_,0) -> false;
any_set(Bits,Index,Remaining) ->
    Byte=binary:at(Bits,Index div 8),
    case Byte band (1 bsl (Index rem 8)) of
        0 -> any_set(Bits,Index+1,Remaining-1);
        _ -> true
    end.
