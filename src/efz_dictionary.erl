%% EFZ hex dictionary; deliberately not an expression or AFL dictionary parser.
-module(efz_dictionary).
-export([normalize/2, load/2]).

normalize(Tokens,L) when is_list(Tokens) ->
    case length(Tokens) =< maps:get(max_tokens,L) andalso
         lists:all(fun(T)->is_binary(T) andalso byte_size(T)>0 andalso
            byte_size(T)=<min(maps:get(max_token_bytes,L),maps:get(max_block_bytes,L)) end,Tokens) of
        false -> {error,invalid_dictionary_tokens};
        true -> case lists:sum([byte_size(T)||T<-Tokens]) =< maps:get(max_dictionary_bytes,L) of
            false -> {error,dictionary_size_limit};
            true -> Sorted=lists:usort(Tokens),
                {ok,Sorted,efz_mutation:hash(term_to_binary(Sorted))}
        end
    end;
normalize(_,_) -> {error,invalid_dictionary}.
load(Path,L) ->
    %% Bounded read, including comments/whitespace. No unbounded read_file first.
    Max=2*maps:get(max_dictionary_bytes,L)+128*maps:get(max_tokens,L)+4096,
    case file:open(Path,[read,raw,binary]) of
        {ok,F}->try
            case file:read(F,Max+1) of
                eof -> normalize([],L);
                {ok,B} when byte_size(B)=<Max -> parse(binary:split(B,<<"\n">>,[global]),1,[],L);
                {ok,_} -> {error,dictionary_file_size_limit};
                {error,R} -> {error,{dictionary_file,R}}
            end
        after ok=file:close(F) end;
        {error,R}->{error,{dictionary_file,R}}
    end.
parse([],_,Ts,L)->normalize(lists:reverse(Ts),L);
parse([Line|Rest],N,Ts,L)->
    Trim=list_to_binary(string:trim(binary_to_list(Line))),
    case Trim of
        <<>> -> parse(Rest,N+1,Ts,L);
        <<$#,_/binary>> -> parse(Rest,N+1,Ts,L);
        _ when byte_size(Trim)>2*map_get(max_token_bytes,L);
               byte_size(Trim)>2*map_get(max_block_bytes,L) -> {error,{token_size_limit,N}};
        _ when length(Ts)>=map_get(max_tokens,L) -> {error,token_count_limit};
        _ -> case byte_size(Trim) rem 2=:=0 andalso
                  lists:all(fun hex/1,binary_to_list(Trim)) of
            false->{error,{invalid_hex_line,N}};
            true->parse(Rest,N+1,[binary:decode_hex(Trim)|Ts],L)
        end
    end.
hex(C)->(C>=$0 andalso C=<$9) orelse (C>=$a andalso C=<$f) orelse (C>=$A andalso C=<$F).
