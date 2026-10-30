%% Delegate before target lookup/load or application start.
-module(efz_external).
-export([main/1]).
main(Args) ->
    case {os:type(),os:find_executable("python3")} of
        {{unix,linux},Python} when is_list(Python) ->
            Script=filename:join(code:priv_dir(efz),"efz_external.py"),
            Port=open_port({spawn_executable,Python},[binary,{line,16384},exit_status,use_stdio,stderr_to_stdout,
                {args,["-u",Script,"--parent",os:getpid(),"--ebin",filename:dirname(code:which(?MODULE)),
                    "--otp",erlang:system_info(otp_release),"--erts",erlang:system_info(version)|Args]}]),
            wait(Port);
        _ -> io:put_chars(standard_error,"EFZ supervised mode requires Linux pidfd and Python 3.9+\n"),2
    end.
wait(P)->receive
    {P,{data,{eol,<<"EFZ_PARENT_READY">>}}}->true=port_command(P,<<"ACK\n">>),wait(P);
    {P,{data,{eol,B}}}->io:put_chars([B,"\n"]),wait(P);
    {P,{data,{noeol,B}}}->io:put_chars(B),wait(P);
    {P,{exit_status,N}}->N
end.
