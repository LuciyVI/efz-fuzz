-module(efz_worker_sup). -behaviour(supervisor). -export([start_link/1,init/1]).
start_link(C)->supervisor:start_link({local,?MODULE},?MODULE,C). init(C)->{ok,{{one_for_one,5,10},[#{id=>efz_worker,start=>{efz_worker,start_link,[C]},restart=>temporary,shutdown=>5000,type=>worker}]}}.
