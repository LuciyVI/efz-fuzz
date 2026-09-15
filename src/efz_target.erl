-module(efz_target).
-export([spawn/1, spawn_link/1, dirty/1]).
-callback run(binary()) -> term().

%% Controlled descendants are admitted by the lifecycle owner BEFORE their
%% code can run. A child inherits coverage, never the parent's other dictionary.
spawn(Fun) when is_function(Fun, 0) -> spawn_owned(Fun, false).
spawn_link(Fun) when is_function(Fun, 0) -> spawn_owned(Fun, true).
spawn_owned(Fun, Link) ->
    {Guardian, Capability} = owner(),
    Request = make_ref(), Monitor = monitor(process, Guardian),
    Guardian ! {spawn_owned, Capability, self(), Request, Fun},
    receive
        {Request, {ok, Pid}} ->
            demonitor(Monitor, [flush]),
            case Link of true -> link(Pid); false -> ok end,
            Pid ! {start_owned, Capability}, Pid;
        {Request, {error, Why}} ->
            demonitor(Monitor, [flush]), error({efz_infrastructure, Why});
        {'DOWN', Monitor, process, Guardian, Why} ->
            error({efz_infrastructure, {guardian_down, Why}})
    end.

%% Declare effects outside the shared-VM contract (e.g. writes to somebody
%% else's ETS). Such a VM must be discarded, even if processes can be cleaned.
dirty(Reason) ->
    {Guardian, Capability} = owner(),
    Guardian ! {runner_dirty, Capability, Reason}, ok.
owner() ->
    case get('$efz_lifecycle') of
        {Guardian, Capability} when is_pid(Guardian), is_reference(Capability) ->
            {Guardian, Capability};
        _ -> error({efz_infrastructure, no_execution_owner})
    end.
