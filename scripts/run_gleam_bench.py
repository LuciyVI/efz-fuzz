#!/usr/bin/env python3
"""Finite serial same-engine series. A fresh VM/corpus per run, never per input."""
import argparse, hashlib, json, os, pathlib, platform, random, resource, signal, statistics, subprocess, time

MODES='baseline,off_default,off_on,seeds,structured,observation,guided,oracle,fraction1,fraction5,fraction10,fraction20'
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    p=argparse.ArgumentParser()
    p.add_argument('--out',required=True);p.add_argument('--baseline-build',required=True)
    p.add_argument('--off-build',required=True);p.add_argument('--on-build',required=True)
    p.add_argument('--seed-directory',required=True)
    p.add_argument('--executions',type=int,default=500);p.add_argument('--repetitions',type=int,default=1)
    p.add_argument('--seeds',default='17,23,41,59,71');p.add_argument('--modes',default=MODES)
    p.add_argument('--trace',type=int,default=0);p.add_argument('--order-seed',type=int,default=20261009)
    p.add_argument('--run-timeout',type=int,default=180);p.add_argument('--total-timeout',type=int,default=900)
    p.add_argument('--memory-gib',type=int,default=8);p.add_argument('--cpus')
    a=p.parse_args();root=pathlib.Path(__file__).resolve().parents[1];out=pathlib.Path(a.out).resolve()
    assert not out.exists(), 'refuse to overwrite series'
    assert 1<=a.executions<=100000 and 0<=a.trace<=10000 and 1<=a.repetitions<=20
    assert 1<=a.run_timeout<=600 and 1<=a.total_timeout<=7200 and 1<=a.memory_gib<=32
    modes=a.modes.split(',');assert set(modes)<=set((MODES+',discovery').split(','))
    seeds=list(map(int,a.seeds.split(',')));assert 1<=len(seeds)<=100 and all(0<s<2**31 for s in seeds)
    cpus=sorted(os.sched_getaffinity(0))[:2] if a.cpus is None else list(map(int,a.cpus.split(',')))
    assert cpus and set(cpus)<=os.sched_getaffinity(0)
    seed_dir=pathlib.Path(a.seed_directory).resolve();files=sorted(seed_dir.glob('*.qs'));assert 1<=len(files)<=64
    jobs=[(s,m,r) for r in range(a.repetitions) for s in seeds for m in modes]
    random.Random(a.order_seed).shuffle(jobs);out.mkdir(parents=True)
    manifest={'schema_version':1,'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
        'tracked_diff_sha256':hashlib.sha256(subprocess.check_output(['git','diff','--binary'],cwd=root)).hexdigest(),
        'source_sha256':{str(q.relative_to(root)):digest(q) for folder in ('src','examples','test','gleam/efz_semantic/src','scripts') for q in (root/folder).rglob('*') if q.is_file() and q.suffix in ('.erl','.gleam','.escript','.py','.sh')},
        'configuration_sha256':{f:digest(root/f) for f in ('rebar.config','rebar.lock','gleam/efz_semantic/gleam.toml','gleam/efz_semantic/manifest.toml')},
        'seed_sha256':{str(q):digest(q) for q in files},'seed_manifest_sha256':digest(pathlib.Path(str(seed_dir)+'.manifest.term')),
        'jobs':jobs,'order_seed':a.order_seed,'executions':a.executions,'trace':a.trace,'schedulers':'2:2','cpu_affinity':cpus,
        'warmup_executions':20,'memory_limit_gib':a.memory_gib,'run_timeout_s':a.run_timeout,'total_timeout_s':a.total_timeout,
        'discovery_fixture':{'artificial':True,'start_raw_hex':'6162633d31','dictionary_tokens':['627567'],'stages':['havoc'],'trigger_source_sha256':digest(root/'test/efz_qs_defect_target.erl'),'sampling':'first finding is an upper time bound at 100ms polls; no discovery is censored'},'target':'cow_qs:parse_qs/1','coverage':'otp_native_public target-only presence','reset':'existing guardian per execution','target_timeout_ms':1000,
        'baseline_build':a.baseline_build,'off_build':a.off_build,'on_build':a.on_build,
        'platform':platform.platform(),'ram_kib':next(x for x in pathlib.Path('/proc/meminfo').read_text().splitlines() if x.startswith('MemTotal:')),
        'cpu_models':sorted(set(x.partition(':')[2].strip() for x in pathlib.Path('/proc/cpuinfo').read_text().splitlines() if x.startswith('model name'))),
        'toolchain':{'otp':'27.0','erts':'15.0','gleam':'1.10.0','rebar':'3.25.0','jit':'enabled'},
        'measurement':'100ms existing EFZ snapshot sampling in all modes, fresh measured corpus after separate warmup, trace disabled for throughput',
        'profile':'conservative fixed-execution smoke; no superiority or full performance PASS'}
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    rows=[];deadline=time.monotonic()+a.total_timeout
    def limits():
        os.sched_setaffinity(0,cpus)
        resource.setrlimit(resource.RLIMIT_AS,(a.memory_gib*1024**3,)*2)
        resource.setrlimit(resource.RLIMIT_CPU,(a.run_timeout,a.run_timeout+1))
    for seed,mode,rep in jobs:
        dest=out/f'{mode}-{seed}-r{rep}';dest.mkdir()
        build=a.baseline_build if mode=='baseline' else a.off_build if mode=='off_default' else a.on_build
        engine_mode='off' if mode.startswith('off_') else mode
        cmd=['/usr/bin/time','-o',str(dest/'resources.txt'),'-f','%U %S %M','escript',str(root/'scripts/gleam_bench.escript'),build,engine_mode,str(seed),str(a.executions),str(a.trace),str(dest),str(root),str(seed_dir)]
        start=time.monotonic();row={'mode':mode,'seed':seed,'repetition':rep,'command':cmd,'artifact_dir':str(dest)}
        if start>=deadline:row.update(exit_code=None,status='NOT_RUN',reason='total_budget_exhausted')
        else:
            with (dest/'run.log').open('w') as f:
                try:
                    proc=subprocess.Popen(cmd,cwd=root,stdout=f,stderr=subprocess.STDOUT,preexec_fn=limits,start_new_session=True)
                    proc.wait(timeout=min(a.run_timeout,deadline-start))
                    row.update(exit_code=proc.returncode)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid,signal.SIGTERM)
                    try:proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:os.killpg(proc.pid,signal.SIGKILL);proc.wait()
                    row.update(exit_code=124,status='TIMEOUT')
            row['process_wall_s']=time.monotonic()-start
            resources=dest/'resources.txt'
            if resources.exists():
                try:
                    user,system,rss=resources.read_text().splitlines()[-1].split();row.update(cpu_user_s=float(user),cpu_system_s=float(system),peak_rss_kib=int(rss))
                except (ValueError,IndexError):row['resource_metrics']='unavailable'
            if (dest/'summary.json').exists():
                row.update(json.loads((dest/'summary.json').read_text()));row['mode']=mode
                if row['otp']!=[50,55] or row['erts']!=[49,53,46,48] or row['schedulers_online']!=2:
                    row.update(exit_code=2,reason='unexpected toolchain or scheduler count')
        rows.append(row);(out/'runs.json').write_text(json.dumps(rows,indent=2)+'\n')
        print(f'{mode} seed {seed} repeat {rep}: exit {row["exit_code"]}, {row.get("exec_per_second","unavailable")} exec/s',flush=True)
    summary={}
    for mode in modes:
        valid=[x for x in rows if x['mode']==mode and x['exit_code']==0];rates=[x['online_exec_per_second'] for x in valid]
        summary[mode]={'sample_size':len(valid),'requested_sample_size':len(seeds)*a.repetitions,
            'median_online_exec_s':statistics.median(rates) if rates else None,'range_online_exec_s':[min(rates),max(rates)] if rates else None,
            'median_total_exec_s':statistics.median([x['exec_per_second'] for x in valid]) if valid else None}
    (out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    if any(x['exit_code']!=0 for x in rows):raise SystemExit(1)
if __name__=='__main__':main()
