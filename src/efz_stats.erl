-module(efz_stats).
-behaviour(gen_server).
-export([start_link/0,inc/1,add/2,get/0,failure/1]). -export([init/1,handle_call/3,handle_cast/2,handle_info/2,terminate/2,code_change/3]).
start_link()->gen_server:start_link({local,?MODULE},?MODULE,[],[]). inc(K)->gen_server:call(?MODULE,{inc,K}). get()->gen_server:call(?MODULE,get).
add(K,N) when is_integer(N),N>=0 -> gen_server:call(?MODULE,{add,K,N}).
failure(Why)->gen_server:call(?MODULE,{failure,Why}).
init([])->{ok,#{verification_executions=>0,verification_requested=>0,verification_skipped=>0,verification_completed=>0,
    verification_failed=>0,verification_valid=>0,verification_elapsed_us=>0,runtime_sampled_executions=>0,
    runtime_missed_executions=>0,runtime_sampling_us=>0,runtime_diagnostic_us=>0,runtime_max_buffer_bytes=>0,coverage_observed_executions=>0,coverage_empty_executions=>0,coverage_unstarted_executions=>0,coverage_broken_observations=>0,calibrations=>0,rejections=>0,infrastructure_failures=>0,executions=>0,discoveries=>0,crashes=>0,crash_occurrences=>0,unique_crashes=>0,timeouts=>0,started_at=>erlang:monotonic_time(millisecond)}}.
handle_cast({inc,K},S)->{noreply,S#{K=>maps:get(K,S,0)+1}}.
handle_call({failure,Why},_,S)->
    Primary=maps:get(primary_infrastructure_failure,S,Why),
    {reply,Primary,S#{infrastructure_failures=>maps:get(infrastructure_failures,S)+1,primary_infrastructure_failure=>Primary}};
handle_call({add,runtime_max_buffer_bytes,N},_,S)->{reply,ok,S#{runtime_max_buffer_bytes=>max(N,maps:get(runtime_max_buffer_bytes,S,0))}};
handle_call({add,K,N},_,S)->{reply,ok,S#{K=>maps:get(K,S,0)+N}};
handle_call({inc,K},_,S)->{reply,ok,S#{K=>maps:get(K,S,0)+1}}; handle_call(get,_,S)->{reply,S,S}; handle_call(_,_,S)->{reply,ok,S}. handle_info(_,S)->{noreply,S}. terminate(_,_) -> ok. code_change(_,S,_) -> {ok,S}.
