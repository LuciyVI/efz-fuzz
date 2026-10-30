-module(efz_monitor_wait_target).
-export([run/1]).
run(_)->
    Owner=persistent_term:get({?MODULE,owner}),Owner!{target_entered,self()},
    receive monitor_continue->ok end.
