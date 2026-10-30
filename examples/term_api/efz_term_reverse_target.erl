-module(efz_term_reverse_target).
-export([run/1, options/0, semantic_contract/0]).
options() -> #{entrypoint=>{lists,reverse,1},
    arguments=>[#{kind=>list,item=>#{kind=>integer}}]}.
semantic_contract() -> (options())#{kind=>term_api}.
run(Raw) -> efz_term_codec:execute(Raw,options()).
