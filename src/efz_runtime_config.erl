%% Shared campaign/executor/replay policy. No atom conversion from input.
-module(efz_runtime_config).
-export([defaults/0, prepare/1]).
defaults() ->
    #{enabled=>false,
      stability=>#{enabled=>true,seed_runs=>3,interesting_runs=>3,suspicious_runs=>3,
          failure_runs=>3,compare_return=>false,max_extra_executions=>1000},
      resources=>#{enabled=>true,sample_interval_ms=>20,max_samples=>64,
          max_sampled_processes=>128,ets_interval_ms=>100,max_ets_tables=>256,
          memory_bytes=>67108864,mailbox_messages=>1000,ets_memory_bytes=>16777216},
      hangs=>#{enabled=>true,max_stack_frames=>8,busy_reductions=>1000,max_sample_age_ms=>100},
      storage=>#{max_groups=>128,max_representatives=>3,max_metadata_bytes=>1048576,
          max_total_metadata_bytes=>16777216}}.
prepare(C) when is_map(C) ->
    try
        D=defaults(), unknown(C,D),
        R=maps:fold(fun(K,V,A)->case V of
            M when is_map(M)->U=maps:get(K,C,#{}),true=is_map(U),unknown(U,M),
                A#{K=>maps:merge(M,U)};
            _->A#{K=>maps:get(K,C,V)} end end,#{},D),
        true=is_boolean(maps:get(enabled,R)),
        S=maps:get(stability,R),bool(S,enabled),bool(S,compare_return),
        [range(S,K,1,16)||K<-[seed_runs,interesting_runs,suspicious_runs,failure_runs]],
        range(S,max_extra_executions,0,1000000),
        P=maps:get(resources,R),bool(P,enabled),range(P,sample_interval_ms,1,10000),
        range(P,max_samples,2,256),range(P,max_sampled_processes,1,256),
        range(P,ets_interval_ms,10,60000),range(P,max_ets_tables,1,4096),
        [range(P,K,1,1099511627776)||K<-[memory_bytes,mailbox_messages,ets_memory_bytes]],
        H=maps:get(hangs,R),bool(H,enabled),range(H,max_stack_frames,0,32),
        range(H,busy_reductions,1,1000000000),range(H,max_sample_age_ms,1,60000),
        %% Hangs alone still samples process counters, but cannot request stale data by design.
        true=(not maps:get(enabled,H) orelse maps:get(max_sample_age_ms,H)>=maps:get(sample_interval_ms,P)),
        T=maps:get(storage,R),range(T,max_groups,1,1024),range(T,max_representatives,1,16),
        range(T,max_metadata_bytes,4096,4194304),range(T,max_total_metadata_bytes,4096,67108864),
        true=maps:get(max_total_metadata_bytes,T)>=maps:get(max_metadata_bytes,T),
        %% Upper bound on resident sample slots (not a byte-accurate VM allocation limit).
        true=maps:get(max_samples,P)*maps:get(max_sampled_processes,P)=<32768,
        {ok,R}
    catch error:_->{error,invalid_runtime_oracles} end;
prepare(_)->{error,invalid_runtime_oracles}.
unknown(C,D)->true=(maps:keys(C)--maps:keys(D)=:=[]).
bool(M,K)->true=is_boolean(maps:get(K,M)).
range(M,K,L,H)->V=maps:get(K,M),true=is_integer(V) andalso V>=L andalso V=<H.
