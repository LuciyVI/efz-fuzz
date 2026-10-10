-module(efz_term_maps_target).
-export([run/1, options/0, semantic_contract/0]).
options() -> #{entrypoint=>{maps,find,2},arguments=>[
    #{kind=>atom,values=>[present,missing]},
    #{kind=>map,key=>#{kind=>atom,values=>[present,missing]},
        value=>#{kind=>tuple,items=>[#{kind=>integer},#{kind=>binary}]}}]}.
semantic_contract() -> (options())#{kind=>term_api}.
run(Raw) -> efz_term_codec:execute(Raw,options()).
