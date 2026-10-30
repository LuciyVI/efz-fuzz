%% Portable term input schema 1. No ETF decoding, atom creation or runtime values.
-module(efz_term_codec).
-export([encode/3, decode/3, execute/2, validate_specs/2, limits/1, summary/2,
    atoms/1, resources/1]).

limits(L) -> maps:merge(#{bytes => 4096, depth => 8, nodes => 128,
    collection => 32, operations => 1}, L).

validate_specs(Specs, L0) ->
    L = limits(L0),
    try
        true = is_list(Specs),
        true = length(Specs) =< maps:get(collection,L),
        _ = lists:foldl(fun(S,N) -> spec(S,1,N,L) end,0,Specs),
        ok
    catch _:_ -> {error,invalid_argument_constraints} end.

spec(S,D,N,L) when is_map(S) ->
    true = D =< maps:get(depth,L),
    true = N < maps:get(nodes,L),
    K = maps:get(kind,S),
    case K of
        integer -> bounds(S,-1000000,1000000,integer), N+1;
        float -> bounds(S,-1000000.0,1000000.0,float), N+1;
        boolean -> N+1;
        binary -> lengths(S,L), N+1;
        charlist -> lengths(S,L), N+1;
        atom -> enum(S), N+1;
        resource -> enum(S), N+1;
        list -> lengths(S,L), spec(maps:get(item,S),D+1,N+1,L);
        tuple ->
            Is=maps:get(items,S), true=is_list(Is),
            true=length(Is)=<maps:get(collection,L),
            lists:foldl(fun(I,A)->spec(I,D+1,A,L) end,N+1,Is);
        map -> lengths(S,L),
            N1=spec(maps:get(key,S),D+1,N+1,L),
            spec(maps:get(value,S),D+1,N1,L);
        term ->
            Vs=maps:get(atoms,S,[]), true=is_list(Vs),
            true=length(Vs)=<256, true=lists:all(fun is_atom/1,Vs), N+1
    end.

enum(S) -> Vs=maps:get(values,S), true=is_list(Vs),
    true=length(Vs)>0, true=length(Vs)=<256,
    true=lists:all(fun is_atom/1,Vs), true=length(lists:usort(Vs))=:=length(Vs).

bounds(S,Min,Max,Kind) ->
    A=maps:get(min,S,Min), B=maps:get(max,S,Max),
    true=case Kind of integer->is_integer(A) andalso is_integer(B)
        andalso A>=-9223372036854775808 andalso B=<9223372036854775807;
        float->is_float(A) andalso is_float(B) andalso finite(A) andalso finite(B) end,
    true=A=<B.

lengths(S,L) ->
    A=maps:get(min_length,S,0), B=maps:get(max_length,S,maps:get(collection,L)),
    true=is_integer(A), true=is_integer(B), true=A>=0,
    true=A=<B, true=B=<maps:get(collection,L).

atoms(Specs) -> lists:usort(lists:flatmap(fun spec_atoms/1,Specs)).
spec_atoms(#{kind:=K,values:=Vs}) when K=:=atom; K=:=resource -> Vs;
spec_atoms(#{kind:=term}=S) -> maps:get(atoms,S,[]);
spec_atoms(#{kind:=list,item:=I}) -> spec_atoms(I);
spec_atoms(#{kind:=tuple,items:=Is}) -> lists:flatmap(fun spec_atoms/1,Is);
spec_atoms(#{kind:=map,key:=K,value:=V}) -> spec_atoms(K)++spec_atoms(V);
spec_atoms(_) -> [].

resources(Specs) -> lists:usort(lists:flatmap(fun spec_resources/1,Specs)).
spec_resources(#{kind:=resource,values:=Vs}) -> Vs;
spec_resources(#{kind:=list,item:=I}) -> spec_resources(I);
spec_resources(#{kind:=tuple,items:=Is}) -> lists:flatmap(fun spec_resources/1,Is);
spec_resources(#{kind:=map,key:=K,value:=V}) -> spec_resources(K)++spec_resources(V);
spec_resources(_) -> [].

encode(Args,Specs,L0) ->
    L=limits(L0),
    try
        true=is_list(Args), true=length(Args)=:=length(Specs),
        true=length(Args)=<maps:get(collection,L),
        _=validate_args(Args,Specs,L),
        A=atoms(Specs),
        Raw=iolist_to_binary([<<"EFZT",1,(length(Args)):16>>,
            [pack(T,A)||T<-Args]]),
        true=byte_size(Raw)=<maps:get(bytes,L),
        {ok,Raw}
    catch _:_ -> {skip,limit_or_unsupported} end.

decode(Raw,Specs,L0) when is_binary(Raw) ->
    L=limits(L0),
    try
        true=byte_size(Raw)=<maps:get(bytes,L),
        <<"EFZT",1,Count:16,Rest/binary>>=Raw,
        true=Count=:=length(Specs), true=Count=<maps:get(collection,L),
        {Args,<<>>,_}=unpack_many(Count,Rest,1,0,L,atoms(Specs),[]),
        _=validate_args(Args,Specs,L),
        {ok,Args}
    catch _:_ -> {skip,limit_or_unsupported} end;
decode(_,_,_) -> {skip,unsupported}.

%% Model-free harness execution. Resource values remain symbolic; a resource
%% harness resolves them during its own setup and cleanup lifecycle.
execute(Raw,#{entrypoint:={M,F,A},arguments:=Specs}=Options) ->
    case decode(Raw,Specs,maps:get(limits,Options,#{})) of
        {ok,Args} when length(Args)=:=A -> erlang:apply(M,F,Args);
        {skip,Why} -> {efz_term_input_rejected,Why}
    end.

validate_args(Args,Specs,L) ->
    lists:foldl(fun({T,S},N)->valid(T,S,1,N,L) end,0,lists:zip(Args,Specs)).

valid(T,S,D,N,L) ->
    true=D=<maps:get(depth,L), true=N<maps:get(nodes,L),
    K=maps:get(kind,S),
    case K of
        integer -> true=is_integer(T),
            true=T>=-9223372036854775808 andalso T=<9223372036854775807,
            range(T,S,-1000000,1000000), N+1;
        float -> true=is_float(T), true=finite(T), range(T,S,-1000000.0,1000000.0), N+1;
        boolean -> true=(T=:=true orelse T=:=false), N+1;
        binary -> true=is_binary(T), size_valid(byte_size(T),S,L), N+1;
        charlist ->
            true=is_list(T), size_valid(length(T),S,L),
            true=(T=:=[] orelse D<maps:get(depth,L)),
            true=lists:all(fun(C)->is_integer(C) andalso C>=0 andalso C=<16#10ffff
                andalso not (C>=16#d800 andalso C=<16#dfff) end,T),
            true=N+length(T)<maps:get(nodes,L), N+length(T)+1;
        atom -> true=is_atom(T), true=lists:member(T,maps:get(values,S)), N+1;
        resource ->
            {'$efz_resource',Name}=T, true=lists:member(Name,maps:get(values,S)), N+1;
        list ->
            true=is_list(T), size_valid(length(T),S,L),
            lists:foldl(fun(X,A)->valid(X,maps:get(item,S),D+1,A,L) end,N+1,T);
        tuple ->
            true=is_tuple(T), true=tuple_size(T)=<maps:get(collection,L),
            Ts=tuple_to_list(T), Is=maps:get(items,S),
            true=length(Ts)=:=length(Is),
            lists:foldl(fun({X,I},A)->valid(X,I,D+1,A,L) end,N+1,lists:zip(Ts,Is));
        map ->
            true=is_map(T), size_valid(map_size(T),S,L),
            lists:foldl(fun({Key,V},A)->
                A1=valid(Key,maps:get(key,S),D+1,A,L),
                valid(V,maps:get(value,S),D+1,A1,L)
            end,N+1,maps:to_list(T));
        term -> valid_any(T,S,D,N,L)
    end.

valid_any(T,S,D,N,L) when is_integer(T) -> valid(T,S#{kind=>integer},D,N,L);
valid_any(T,S,D,N,L) when is_float(T) -> valid(T,S#{kind=>float},D,N,L);
valid_any(T,S,D,N,L) when T=:=true; T=:=false -> valid(T,S#{kind=>boolean},D,N,L);
valid_any(T,S,D,N,L) when is_atom(T) -> valid(T,#{kind=>atom,values=>maps:get(atoms,S,[])},D,N,L);
valid_any(T,S,D,N,L) when is_binary(T) -> valid(T,S#{kind=>binary},D,N,L);
valid_any(T,S,D,N,L) when is_list(T) -> valid(T,S#{kind=>list,item=>S},D,N,L);
valid_any(T,S,D,N,L) when is_tuple(T) ->
    true=tuple_size(T)=<maps:get(collection,L),
    valid(T,#{kind=>tuple,items=>lists:duplicate(tuple_size(T),S)},D,N,L);
valid_any(T,S,D,N,L) when is_map(T) -> valid(T,S#{kind=>map,key=>S,value=>S},D,N,L).

range(T,S,A,B) -> true=T>=maps:get(min,S,A), true=T=<maps:get(max,S,B).
size_valid(N,S,L) -> true=N=<maps:get(collection,L),
    true=N>=maps:get(min_length,S,0),
    true=N=<maps:get(max_length,S,maps:get(collection,L)).
finite(F) -> F=:=F andalso abs(F)=<1.7976931348623157e308.

pack(false,_) -> <<0>>;
pack(true,_) -> <<1>>;
pack(T,_) when is_integer(T) -> <<2,T:64/signed>>;
pack(T,_) when is_float(T) -> <<3,T:64/float>>;
pack(T,_) when is_binary(T) -> [<<4,(byte_size(T)):32>>,T];
pack({'$efz_resource',Name},A) -> <<9,(atom_index(Name,A,0)):16>>;
pack(T,A) when is_atom(T) -> <<8,(atom_index(T,A,0)):16>>;
pack(T,A) when is_list(T) -> [<<5,(length(T)):16>>,[pack(X,A)||X<-T]];
pack(T,A) when is_tuple(T) -> [<<6,(tuple_size(T)):16>>,[pack(X,A)||X<-tuple_to_list(T)]];
pack(T,A) when is_map(T) ->
    [<<7,(map_size(T)):16>>,[[pack(K,A),pack(V,A)]||{K,V}<-lists:sort(maps:to_list(T))]].
atom_index(T,[T|_],N) -> N;
atom_index(T,[_|Rest],N) -> atom_index(T,Rest,N+1).

unpack(Raw,D,N,L,A) ->
    true=D=<maps:get(depth,L), true=N<maps:get(nodes,L),
    case Raw of
        <<0,Rest/binary>> -> {false,Rest,N+1};
        <<1,Rest/binary>> -> {true,Rest,N+1};
        <<2,T:64/signed,Rest/binary>> -> {T,Rest,N+1};
        <<3,T:64/float,Rest/binary>> -> true=finite(T), {T,Rest,N+1};
        <<4,Size:32,Rest0/binary>> ->
            true=Size=<maps:get(bytes,L), <<T:Size/binary,Rest/binary>>=Rest0, {T,Rest,N+1};
        <<8,I:16,Rest/binary>> -> {lists:nth(I+1,A),Rest,N+1};
        <<9,I:16,Rest/binary>> -> {{'$efz_resource',lists:nth(I+1,A)},Rest,N+1};
        <<K,Count:16,Rest0/binary>> when K=:=5; K=:=6; K=:=7 ->
            true=Count=<maps:get(collection,L),
            Size=case K of 7->2*Count; _->Count end,
            {Ts,Rest,N1}=unpack_many(Size,Rest0,D+1,N+1,L,A,[]),
            T=case K of 5->Ts; 6->list_to_tuple(Ts); 7->map_pairs(Ts,#{}) end,
            {T,Rest,N1}
    end.
unpack_many(0,Rest,_,N,_,_,Acc) -> {lists:reverse(Acc),Rest,N};
unpack_many(Count,Raw,D,N,L,A,Acc) ->
    {T,Rest,N1}=unpack(Raw,D,N,L,A),
    unpack_many(Count-1,Rest,D,N1,L,A,[T|Acc]).
map_pairs([],M) -> M;
map_pairs([K,V|Rest],M) -> false=maps:is_key(K,M), map_pairs(Rest,M#{K=>V}).

%% Result summaries tolerate runtime values: only their finite class is exposed.
summary(T,L0) -> summary_walk([{at,T,1}],limits(L0),0,0,[],false).
summary_walk([],_,N,Depth,Classes,Truncated) ->
    #{nodes=>N,depth=>Depth,classes=>lists:usort(Classes),truncated=>Truncated};
summary_walk(_,L,N,Depth,Classes,_) when N>=map_get(nodes,L) ->
    #{nodes=>N,depth=>Depth,classes=>lists:usort(Classes),truncated=>true};
summary_walk([{at,T,D}|Rest],L,N,Depth,Classes,Truncated) ->
    summary_node(T,D,Rest,L,N,Depth,Classes,Truncated).
summary_node(T,D,Rest,L,N,Depth,Classes,Truncated) ->
    {Class,AllChildren}=class_children(T,maps:get(collection,L)+1),
    Children=lists:sublist(AllChildren,maps:get(collection,L)),
    Cut=length(AllChildren)>maps:get(collection,L),
    Allow=D<maps:get(depth,L),
    Next=case Allow of true->[{at,X,D+1}||X<-Children]++Rest; false->Rest end,
    summary_walk(Next,L,N+1,max(Depth,D),[Class|Classes],
        Truncated orelse Cut orelse (not Allow andalso Children=/=[])).
class_children(T,_) when is_integer(T) -> {0,[]};
class_children(T,_) when is_float(T) -> {1,[]};
class_children(T,_) when T=:=true; T=:=false -> {2,[]};
class_children(T,_) when is_atom(T) -> {3,[]};
class_children(T,_) when is_binary(T) -> {4,[]};
class_children(T,Max) when is_list(T) -> {5,take_list(T,Max)};
class_children(T,Max) when is_tuple(T) ->
    {6,[element(I,T)||I<-lists:seq(1,min(tuple_size(T),Max))]};
class_children(T,Max) when is_map(T) -> {7,map_children(maps:iterator(T),Max,[])};
class_children(T,_) when is_pid(T) -> {8,[]};
class_children(T,_) when is_reference(T) -> {9,[]};
class_children(T,_) when is_port(T) -> {10,[]};
class_children(T,_) when is_function(T) -> {11,[]};
class_children(_,_) -> {12,[]}.
take_list(_,0) -> [];
take_list([],_) -> [];
take_list([H|T],N) -> [H|take_list(T,N-1)];
take_list(_,_) -> [].
map_children(_,0,Acc) -> lists:reverse(Acc);
map_children(It,N,Acc) -> case maps:next(It) of none->lists:reverse(Acc);
    {K,V,Next}->map_children(Next,N-1,[V,K|Acc]) end.
