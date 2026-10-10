-module(efz_term_invalid_limits_target).
-export([options/0,semantic_contract/0,run/1]).
options() -> #{entrypoint=>{lists,reverse,1},arguments=>[
    #{kind=>list,item=>#{kind=>integer}}]}.
semantic_contract() -> (options())#{kind=>term_api,input_limits=>#{depth=>0}}.
run(Raw) -> efz_term_codec:execute(Raw,options()).
