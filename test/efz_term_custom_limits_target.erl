%% An ordinary configured API with a declared codec envelope wider than default.
-module(efz_term_custom_limits_target).
-export([options/0,input_limits/0,semantic_contract/0,run/1]).
options() -> #{entrypoint=>{lists,reverse,1},arguments=>[
    #{kind=>list,min_length=>33,max_length=>64,item=>#{kind=>integer}}]}.
input_limits() -> #{bytes=>4096,depth=>8,nodes=>256,collection=>64,operations=>1}.
semantic_contract() -> (options())#{kind=>term_api,input_limits=>input_limits()}.
run(Raw) -> efz_term_codec:execute(Raw,(options())#{limits=>input_limits()}).
