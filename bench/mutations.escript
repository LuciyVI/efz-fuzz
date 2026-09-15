#!/usr/bin/env escript
%% Local Phase 3 benchmark. No coverage-hook profiling or optimization rounds.
-mode(compile).
main([Out])->
    true=code:add_patha("_build/default/lib/efz/ebin"),_=application:ensure_all_started(crypto),
    ok=logger:set_primary_config(level,warning),ok=filelib:ensure_dir(filename:join(Out,"x")),
    Specs=[{short,4,[bitflip,arithmetic,havoc]},
           {medium,1024,[bitflip,arithmetic,havoc]},
           {near_limit,4095,[bitflip,arithmetic,havoc]},
           {dictionary,1024,[dictionary_insert,dictionary_overwrite]},
           {splicing,1024,[splice]},{havoc,1024,[havoc]}],
    Mutation=[bench_case(S)||S<-Specs],
    T0=now_us(),{ok,A}=efz_instrument:compile("examples/staged/efz_staged_parser.erl",
        #{modules=>[efz_staged_parser],source_root=>".",outdir=>filename:join(Out,"targets")}),
    BuildUs=now_us()-T0,
    _=campaign(A,random,100,Out),_=campaign(A,staged,100,Out),
    Rounds=[begin Order=case I rem 2 of 0->[staged,random];_->[random,staged] end,
        [{Mode,campaign(A,Mode,500,Out)}||Mode<-Order] end||I<-lists:seq(1,5)],
    Campaigns=[#{mode=>Mode,samples=>[S||Round<-Rounds,{M,S}<-Round,M=:=Mode]}||Mode<-[random,staged]],
    Env=#{otp=>erlang:system_info(otp_release),erts=>erlang:system_info(version),
        architecture=>erlang:system_info(system_architecture),schedulers=>erlang:system_info(schedulers_online),
        erl_flags=>os:getenv("ERL_FLAGS"),rebar=>os:cmd("rebar3 version"),os=>os:type(),
        fixture=>A,fixture_compile_us=>BuildUs,profiled=>false,
        os_release=>read("/etc/os-release"),kernel=>os:cmd("uname -sr"),
        cpu_model=>hd([L||L<-binary:split(read("/proc/cpuinfo"),<<"\n">>,[global]),binary:match(L,<<"model name">>)=:={0,10}]),
        compiler_options=>[debug_info,warnings_as_errors],
        warmup=>one_validated_batch_and_campaign_pilot,samples=>5},
    Sources=[{F,digest(read(F))}||F<-lists:sort(filelib:wildcard("src/*.erl")++
        ["bench/mutations.escript","examples/staged/efz_staged_parser.erl"])],
    Evidence=#{environment=>Env,sources_sha256=>Sources,mutation=>Mutation,campaigns=>Campaigns},
    ok=file:write_file(filename:join(Out,"mutations.term"),term_to_binary(Evidence)),
    ok=file:write_file(filename:join(Out,"mutations.txt"),unicode:characters_to_binary(io_lib:format("~tp.~n",[Evidence]))),
    lists:foreach(fun(#{name:=Name,samples:=Ss})->show(Name,Ss,generated) end,Mutation),
    lists:foreach(fun(#{mode:=Mode,samples:=Ss})->show(Mode,Ss,executions),
        io:format("~p campaign stats: ~w~n",[Mode,[maps:get(stats,S)||S<-Ss]]) end,Campaigns),
    io:format("Environment ~tp~n",[Env]);
main(_)->error("usage: escript bench/mutations.escript OUTPUT_DIR").
bench_case({Name,Size,Stages})->
    B=binary:part(binary:copy(<<0,1,2,3>>,Size div 4+1),0,Size),
    <<First,Rest/binary>>=B,Donor = <<(First bxor 255),Rest/binary>>,
    Es=[#{id=>1,input=>B},#{id=>2,input=>Donor}],
    {ok,C}=efz_mutation_plan:prepare(#{seed=>{17,23,41},stages=>Stages,max_input_bytes=>4096,
        dictionary=>[<<"TOKEN">>,<<"BOOM!">>],max_idle_visits=>10000},[B,Donor]),
    %% Fixed bounded counts; dictionary stages may finish earlier, reported honestly.
    N=5000,Expected=batch(N,efz_mutation_plan:new(C),Es,0,0,0,true),
    Ss=[begin erlang:garbage_collect(),Before=memory(),{reductions,R0}=process_info(self(),reductions),
        {Us,Result}=timer:tc(fun()->batch(N,efz_mutation_plan:new(C),Es,0,0,0,false) end),
        Expected=Result,{reductions,R1}=process_info(self(),reductions),After=memory(),
        erlang:garbage_collect(),Clean=memory(),
        {Gen,Visits,Checksum}=Result,
        #{us=>Us,generated=>Gen,visits=>Visits,checksum=>Checksum,reductions=>R1-R0,
            before=>Before,after_batch=>After,after_gc=>Clean}
    end||_<-lists:seq(1,5)],
    #{name=>Name,bytes=>Size,input_sha256=>digest(B),donor_sha256=>digest(Donor),configuration=>C,samples=>Ss}.
batch(0,_,_,Gen,Visits,Checksum,_)->{Gen,Visits,Checksum};
batch(N,S,Es,Gen,Visits,Checksum,Validate)->
    case efz_mutation_plan:next(S,Es) of
        {candidate,B,P,Next}->
            case Validate of true->{ok,B}=efz_mutation:apply_operations(maps:get(primary,P),maps:get(operations,P),maps:get(config,S));false->ok end,
            batch(N-1,Next,Es,Gen+1,Visits+1,erlang:crc32(Checksum,B),Validate);
        {skip,_,Next}->batch(N,Next,Es,Gen,Visits+1,Checksum,Validate);
        {done,_,_}->{Gen,Visits,Checksum}
    end.
campaign(A,Mode,N,Out)->
    Base=#{target=>efz_staged_parser,artifacts=>[A],seeds=>[<<0>>],max_iterations=>N,
        random_seed=>{17,23,41},selection_seed=>{101,109,113},timeout=>100,
        crash_dir=>filename:join(Out,atom_to_list(Mode)++"-crashes")},
    C=case Mode of random->Base;staged->Base#{mutation_mode=>staged,max_input_bytes => 64, mutation => #{seed=>{17,23,41},
        stages=>[dictionary_insert,boundary,arithmetic,havoc,splice],dictionary=>[<<"TOKEN">>,<<"BOOM!">>],
        max_block_bytes=>16,max_token_bytes=>16,havoc_depth=>4}} end,
    Start=now_us(),{ok,_}=efz:start(C),R=efz:await(30000),ok=efz:stop(),
    #{status:=completed,stats:=Stats,timing:=Times}=R,N=maps:get(executions,Stats),0=maps:get(infrastructure_failures,Stats),
    #{us=>maps:get(mutation_us,Times),executions=>N,calibration_us=>maps:get(calibration_us,Times),
        total_api_us=>now_us()-Start,stats=>maps:remove(started_at,Stats),
        coverage=>maps:get(coverage,R),mutation_stats=>maps:get(mutation_stats,R,not_collected_in_legacy_mode)}.
show(Name,Ss,Key)->Times=[maps:get(us,S)||S<-Ss],Rates=lists:sort([maps:get(Key,S)*1000000/maps:get(us,S)||S<-Ss]),
    io:format("~p: count ~B median ~Bus range ~B..~B us, median ~.1f/s raw ~w~n",
        [Name,maps:get(Key,hd(Ss)),lists:nth(3,lists:sort(Times)),lists:min(Times),lists:max(Times),lists:nth(3,Rates),Times]).
memory()->#{process_bytes=>element(2,process_info(self(),memory)),vm_total=>erlang:memory(total)}.
now_us()->erlang:monotonic_time(microsecond).
digest(B)->binary:encode_hex(efz_mutation:hash(B),lowercase).
read(F)->{ok,B}=file:read_file(F),B.
