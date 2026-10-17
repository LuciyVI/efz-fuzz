%% Dedicated ordinary target: other suites never instrument this module.
-module(efz_continuous_fixture).
-export([run/1,echo/1,options/0,semantic_contract/0]).
options()->#{entrypoint=>{?MODULE,echo,1},arguments=>[#{kind=>binary,max_length=>16}]}.
semantic_contract()->(options())#{kind=>term_api}.
run(B)->efz_term_codec:execute(B,options()).
echo(B)->B.
