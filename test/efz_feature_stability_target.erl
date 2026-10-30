-module(efz_feature_stability_target).
-export([run/1]).

run(_) ->
    Owner=persistent_term:get({?MODULE,owner}),
    Owner!{target_entered,self()},
    receive
        {continue,a}->alpha();
        {continue,b}->beta()
    end.
alpha()->alpha_result.
beta()->beta_result.
