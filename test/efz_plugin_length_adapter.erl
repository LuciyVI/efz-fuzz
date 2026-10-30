-module(efz_plugin_length_adapter).
-behaviour(efz_semantic_adapter).
-export([descriptor/0,prepare/3,generate/2,mutate/4,observe/3]).
descriptor() -> #{id=><<"fixture.length_prefix">>,api_version=>1,model_version=>1,
    observer_version=>1,recipe_version=>1,operations_version=>1,
    capabilities=>[generation,mutation,observation],operations=>[100,101,102],
    model_modules=>[],properties=>[]}.
prepare(Target,Options,Limits) ->
    case Options=:=#{} andalso erlang:function_exported(Target,semantic_contract,0)
        andalso Target:semantic_contract()=:=#{kind=>length_prefix_fixture,outcome=>payload_size} of
        true->{ok,#{bytes=>maps:get(bytes,Limits)}};
        false->{error,incompatible_length_prefix_contract}
    end.
generate(Index,Context) ->
    Size=lists:nth(Index rem 4+1,[0,1,4,8]),
    encode(binary:copy(<<(Index rem 256)>>,Size),Context).
mutate(<<Size:16,Payload:Size/binary>>,Operation,#{choice:=Choice},Context) ->
    Next=case {Operation,Payload} of
        {100,_}-><<Payload/binary,Choice:8>>;
        {101,<<>>}->skip;
        {101,_}->Pos=Choice rem Size,<<A:Pos/binary,_,B/binary>>=Payload,<<A/binary,B/binary>>;
        {102,<<>>}->skip;
        {102,_}->Pos=Choice rem Size,<<A:Pos/binary,Byte,B/binary>>=Payload,
            <<A/binary,(Byte bxor (1 bsl (Choice rem 8))),B/binary>>
    end,
    case Next of
        skip->{skip,empty_payload};
        _->case encode(Next,Context) of
            {ok,Raw}->{ok,Raw,#{choice=>Choice,payload_bytes=>byte_size(Next)}};
            Skip->Skip
        end
    end;
mutate(_,_,_,_) -> {skip,unsupported_wire}.
encode(Payload,#{bytes:=Max}) ->
    Size=byte_size(Payload),case Size+2=<Max andalso Size=<65535 of
        true->{ok,<<Size:16,Payload/binary>>};false->{skip,limit} end.
observe(_, {ok,{payload,Size}},_) when is_integer(Size),Size>=0,Size=<65535 ->
    Bucket=case Size of 0->0;1->1;N when N=<4->2;N when N=<16->3;_->4 end,
    {ok,[1,10+Bucket]};
observe(_, {ok,{rejected,malformed_length_prefix}},_) -> {ok,[2]};
observe(_,_,_) -> {skip,unsupported_outcome}.
