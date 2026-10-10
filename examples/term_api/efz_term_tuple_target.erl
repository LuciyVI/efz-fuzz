-module(efz_term_tuple_target).
-export([run/1,options/0,semantic_contract/0]).
options() -> #{entrypoint=>{efz_term_tuple_library,combine,2},arguments=>[
    #{kind=>map,key=>#{kind=>atom,values=>[a,b]},value=>#{kind=>integer}},
    #{kind=>tuple,items=>[#{kind=>atom,values=>[a,b]},#{kind=>integer}]}]}.
semantic_contract() -> (options())#{kind=>term_api}.
run(Raw) -> efz_term_codec:execute(Raw,options()).
