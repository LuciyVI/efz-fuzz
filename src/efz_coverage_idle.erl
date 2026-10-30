%% Wall-clock stop condition for a campaign's mutation phase. Timestamps stay
%% local to the worker; only elapsed durations are exposed in reports.
-module(efz_coverage_idle).
-export([new/1,start/2,observe/3,expired/2,public/2]).

new(disabled) -> disabled;
new(Seconds) when is_integer(Seconds), Seconds > 0 ->
    #{limit_seconds=>Seconds,since_ms=>undefined,new_coverage_events=>0,
      last_new_coverage_iteration=>undefined}.

start(disabled,_) -> disabled;
start(#{since_ms:=undefined}=State,Now) -> State#{since_ms=>Now};
start(State,_) -> State.

observe(disabled,_,_) -> disabled;
observe(State,[],_) -> State;
observe(State,[_|_],{Now,Iteration}) ->
    case expired(State,Now) of
        true -> State;
        false -> State#{since_ms=>Now,
            new_coverage_events=>maps:get(new_coverage_events,State)+1,
            last_new_coverage_iteration=>Iteration}
    end.

expired(disabled,_) -> false;
expired(#{since_ms:=undefined},_) -> false;
expired(#{since_ms:=Since,limit_seconds:=Seconds},Now) ->
    Now-Since >= Seconds*1000.

public(disabled,_) -> #{schema_version=>1,enabled=>false};
public(#{since_ms:=undefined,limit_seconds:=Seconds}=State,_) ->
    (maps:without([since_ms],State))#{schema_version=>1,enabled=>true,status=>waiting_for_mutation,
        elapsed_ms=>0,remaining_ms=>Seconds*1000};
public(#{since_ms:=Since,limit_seconds:=Seconds}=State,Now) ->
    Elapsed=max(0,Now-Since),Limit=Seconds*1000,
    Status=case Elapsed>=Limit of true->expired;false->running end,
    (maps:without([since_ms],State))#{schema_version=>1,enabled=>true,status=>Status,
        elapsed_ms=>Elapsed,remaining_ms=>max(0,Limit-Elapsed)}.
