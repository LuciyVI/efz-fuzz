-module(efz_mutator_tests). -include_lib("eunit/include/eunit.hrl").
mutator_test()->B=efz_mutator_random:mutate(<<1,2,3>> ,#{seed=>{1,2,3}}),?assert(is_binary(B)),?assert(byte_size(B)>0). empty_test()->?assert(is_binary(efz_mutator_random:mutate(<<>>,#{seed=>{1,2,3}}))).
