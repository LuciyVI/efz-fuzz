%% Version 1 byte operations. No random choices or campaign dependencies.
-module(efz_mutation).
-export([apply_operation/3, apply_operations/3, boundaries/1, hash/1]).

hash(B) -> crypto:hash(sha256, B).
boundaries(W) when W =:= 8; W =:= 16; W =:= 32 ->
    Half = 1 bsl (W-1), Max = (1 bsl W)-1,
    [0,1,2,Half-2,Half-1,Half,Half+1,Max-1,Max].

apply_operation(B, Op, L) when is_binary(B), is_map(L) ->
    case byte_size(B) =< maps:get(max_input_bytes,L) of
        false -> {error, oversized_input};
        true ->
            try operation(B,Op,L) of
                {ok,B} -> {skip,no_change};
                Other -> Other
            catch error:function_clause -> {error,invalid_operation};
                  error:badarg -> {error,invalid_operation}
            end
    end;
apply_operation(_,_,_) -> {error,invalid_operation}.
apply_operations(B, [], _) -> {ok,B};
apply_operations(B, [Op|Ops], L) ->
    case apply_operation(B,Op,L) of
        {ok,Next} -> apply_operations(Next,Ops,L);
        {skip,Why} -> {error,{unrealized_operation,Why}};
        Error -> Error
    end.

%% Bit zero is the most significant bit of byte zero. No byte-boundary reset.
operation(B,{flip_bits,Off,W},_) when is_integer(Off),Off>=0,W=:=1; is_integer(Off),Off>=0,W=:=2; is_integer(Off),Off>=0,W=:=4 ->
    case Off+W =< bit_size(B) of
        true -> <<Head:Off/bitstring,V:W,Tail/bitstring>>=B,
                {ok,<<Head/bitstring,(V bxor ((1 bsl W)-1)):W,Tail/bitstring>>};
        false -> {skip,insufficient_length}
    end;
operation(B,{invert_bytes,Off,N},L) when N=:=1;N=:=2;N=:=4 ->
    case fits(B,Off,N) of
        true -> V=binary:part(B,Off,N), replace(B,Off,N,<< <<(X bxor 255)>> || <<X>> <= V >>,L);
        false -> {skip,insufficient_length}
    end;
operation(B,{add,Off,W,Endian,Delta},L)
  when (W=:=8 orelse W=:=16 orelse W=:=32),
       (Endian=:=little orelse Endian=:=big),is_integer(Delta) ->
    case abs(Delta) =< maps:get(max_delta,L) of
        false -> {error,delta_limit};
        true -> case fits(B,Off,W div 8) of
            false -> {skip,insufficient_length};
            true -> Old=binary:decode_unsigned(binary:part(B,Off,W div 8),Endian),
                %% Masking is explicit modulo 2^W, including negative sums.
                New=(Old+Delta) band ((1 bsl W)-1),
                integer_write(B,Off,W,Endian,New,L)
        end
    end;
operation(B,{set_integer,Off,W,Endian,V},L)
  when (W=:=8 orelse W=:=16 orelse W=:=32),
       (Endian=:=little orelse Endian=:=big),is_integer(V),V>=0,V<(1 bsl W) ->
    integer_write(B,Off,W,Endian,V,L);
operation(B,{overwrite,Off,Bytes},L) when is_binary(Bytes) -> literal(B,Off,byte_size(Bytes),Bytes,L);
operation(B,{insert,Off,Bytes},L) when is_binary(Bytes) -> literal(B,Off,0,Bytes,L);
operation(B,{dictionary_overwrite,Off,Token},L) when is_binary(Token) ->
    dictionary(B,Off,byte_size(Token),Token,L);
operation(B,{dictionary_insert,Off,Token},L) when is_binary(Token) -> dictionary(B,Off,0,Token,L);
operation(B,{delete,Off,N},L) when is_integer(N),N>0 -> replace(B,Off,N,<<>>,L);
operation(B,{duplicate,Off,N,At},L) when is_integer(N),N>0 ->
    case fits(B,Off,N) andalso fits(B,At,0) of
        false -> {skip,insufficient_length};
        true -> case N =< maps:get(max_block_bytes,L) andalso byte_size(B)+N =< maps:get(max_input_bytes,L) of
            false -> {skip,size_limit};
            true -> replace(B,At,0,binary:part(B,Off,N),L)
        end
    end;
operation(B,{splice,CutA,CutB,Donor,Id},L) when is_binary(Donor),is_binary(Id) ->
    case byte_size(Donor) =< maps:get(max_input_bytes,L) andalso hash(Donor)=:=Id of
        false -> {error,invalid_donor};
        true when Donor=:=B -> {skip,donor_unavailable};
        true -> case fits(B,CutA,0) andalso fits(Donor,CutB,0) of
            false -> {skip,insufficient_length};
            true -> Size=CutA+byte_size(Donor)-CutB,
                case Size =< maps:get(max_input_bytes,L) of
                    false -> {skip,size_limit};
                    true -> {ok,<<(binary:part(B,0,CutA))/binary,
                                   (binary:part(Donor,CutB,byte_size(Donor)-CutB))/binary>>}
                end
        end
    end;
operation(_,_,_) -> {error,invalid_operation}.
integer_write(B,Off,W,Endian,V,L) ->
    Bytes=case Endian of little -> <<V:W/little>>; big -> <<V:W/big>> end,
    replace(B,Off,W div 8,Bytes,L).
dictionary(_,_,_,<<>>,_) -> {skip,dictionary_unavailable};
dictionary(B,Off,N,Token,L) ->
    case byte_size(Token) =< maps:get(max_token_bytes,L) of
        true -> literal(B,Off,N,Token,L);
        false -> {skip,size_limit}
    end.
literal(_,_,_,<<>>,_) -> {skip,no_change};
literal(B,Off,N,Bytes,L) ->
    case byte_size(Bytes) =< maps:get(max_block_bytes,L) of
        true -> replace(B,Off,N,Bytes,L);
        false -> {skip,size_limit}
    end.
fits(B,Off,N) -> is_integer(Off) andalso Off>=0 andalso is_integer(N) andalso N>=0 andalso Off+N=<byte_size(B).
replace(B,Off,N,Bytes,L) ->
    case fits(B,Off,N) of
        false -> {skip,insufficient_length};
        true -> case byte_size(B)-N+byte_size(Bytes) =< maps:get(max_input_bytes,L) of
            false -> {skip,size_limit};
            true -> <<Head:Off/binary,_:N/binary,Tail/binary>>=B,{ok,<<Head/binary,Bytes/binary,Tail/binary>>}
        end
    end.
