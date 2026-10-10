%% The ordinary harness does not load Gleam. One decoder call per primary run.
-module(efz_xmlrpc_target).
-export([run/1, semantic_contract/0]).
semantic_contract() ->
    #{format => xmlrpc_method_call, version => 1,
      entrypoint => {xmlrpc_decode, payload, 1}, encoding => ascii}.
run(Input) when is_binary(Input) ->
    case decode(xmlrpc_decode, payload, binary_to_list(Input)) of
        {ok, Decoded} -> {accepted, Decoded};
        {error, Reason} -> {rejected, Reason}
    end.

decode(M,F,Input) -> erlang:apply(M,F,[Input]).
