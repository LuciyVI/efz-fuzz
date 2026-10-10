#!/usr/bin/env python3
"""Paired finite QS runs using an isolated baseline and one shared native artifact."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import statistics
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline', required=True, help='Baseline optional _build/gleam directory')
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    out = Path(args.out).resolve()
    assert not out.exists(), 'Refuse to overwrite measurements'
    cpus = sorted(os.sched_getaffinity(0))[:2]
    assert len(cpus) == 2
    out.mkdir(parents=True)
    seeds = out / 'seeds'
    seeds.mkdir()
    seed_inputs = [b'', b'a=', b'a=%00%FF', b'a=%20%26%3D%25&a=1', b'plain=1', b'a=1&x=%']
    for i, data in enumerate(seed_inputs):
        (seeds / f'{i}.qs').write_bytes(data)
    env = dict(os.environ, ERL_FLAGS='+S 2:2', ERL_CRASH_DUMP=str(out / 'erl_crash.dump'))
    source = out / 'source'
    source.mkdir()
    shutil.copy2(root / '_build/default/lib/cowlib/src/cow_qs.erl', source / 'cow_qs.erl')
    shutil.copy2(root / '_build/default/lib/cowlib/include/cow_inline.hrl', source / 'cow_inline.hrl')
    artifact = out / 'shared-artifact.term'
    expr = ('[Source,TargetDir,Artifact]=init:get_plain_arguments(),'
            '{ok,A}=efz_cov_native_public:compile(Source,TargetDir),'
            'ok=file:write_file(Artifact,io_lib:format("~tp.~n",[A])),halt(0).')
    prepare = ['erl', '+S', '2:2', '-noshell', '-pa', str(root / '_build/gleam/lib/efz/ebin'),
               '-eval', expr, '-extra', str(source / 'cow_qs.erl'),
               str(out / 'target'), str(artifact)]
    subprocess.run(prepare, cwd=root, env=env, check=True, timeout=30)
    modes = [('old', str(Path(args.baseline).resolve()), 'guided'),
             ('new', str(root / '_build/gleam'), 'plugin_guided'),
             ('off', str(root / '_build/gleam'), 'off')]
    jobs = [(name, engine, mode, rep) for rep in range(1, 4) for name, engine, mode in modes]
    random.Random(20261010).shuffle(jobs)
    def sha(path):
        return hashlib.sha256(Path(path).read_bytes()).hexdigest()
    manifest = {'cpu_affinity': cpus, 'ERL_FLAGS': '+S 2:2', 'repetitions': 3,
                'rng_seed': [17, 18, 19], 'mutation_execution_budget': 300,
                'warmup_mutations': 20, 'target_timeout_ms': 1000,
                'campaign_deadline_ms': 120000, 'driver_deadline_s': 135,
                'coverage_backend': 'otp_native_public', 'initial_seed_hashes': [sha(seeds / f'{i}.qs')
                    for i in range(6)], 'prepare_command': prepare, 'order_seed': 20261010,
                'jobs': jobs, 'shared_target_sha256': sha(out / 'target/cow_qs.beam'),
                'script_sha256': sha(root / 'scripts/gleam_bench.escript'),
                'engine_beam_sha256': {name: sha(Path(engine) / 'lib/efz/ebin/efz.beam')
                    for name, engine, mode in modes}, 'scope': 'finite measurement, no discovery superiority claim'}
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    results = []
    for name, engine, mode, rep in jobs:
        label = f'{name}-{rep}'
        run = out / label
        cmd = ['escript', 'scripts/gleam_bench.escript', engine, mode, '17', '300', '300',
               str(run), str(root), str(seeds), str(artifact)]
        start = time.monotonic()
        with (out / (label + '.log')).open('w') as log:
            process = subprocess.Popen(cmd, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT,
                                       preexec_fn=lambda: os.sched_setaffinity(0, cpus))
            try:
                code = process.wait(timeout=135)
                timed_out = False
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                code, timed_out = process.returncode, True
        row = {'label': label, 'revision': name, 'repeat': rep, 'command': cmd, 'exit_code': code,
               'driver_timeout': timed_out, 'driver_wall_s': time.monotonic() - start}
        summary = run / 'summary.json'
        if summary.exists():
            row['measurement'] = json.loads(summary.read_text())
        results.append(row)
        (out / 'runs.json').write_text(json.dumps(results, indent=2) + '\n')
    groups = {}
    for name, engine, mode in modes:
        ms = [r['measurement'] for r in results if r['revision'] == name and 'measurement' in r]
        groups[name] = {'samples': len(ms),
                       'completed_samples': sum(m['status'] == 'completed' and m['mutation_executions'] == 300 for m in ms),
                       'median_wall_us': statistics.median(m['wall_us'] for m in ms) if ms else None,
                       'median_primary_per_second': statistics.median(m['exec_per_second'] for m in ms) if ms else None,
                       'coverage_counts': [m['coverage_count'] for m in ms],
                       'semantic_only_novelty': [m['semantic_only'] for m in ms],
                       'provider_successes': [m['structured_stats'].get('successes', 0) for m in ms],
                       'provider_fallbacks': [m['structured_stats'].get('fallbacks',
                           m['structured_stats'].get('attempts', 0) - m['structured_stats'].get('successes', 0)
                           - m['structured_stats'].get('errors', 0)) for m in ms]}
    completed = len(results) == 9 and all(r['exit_code'] == 0 and not r['driver_timeout']
        and r.get('measurement', {}).get('status') == 'completed'
        and r['measurement']['mutation_executions'] == 300 for r in results)
    final = {'completed': completed, 'campaigns': groups,
             'limitations': 'Finite 300-execution samples; adapter-local semantic counts; includes corpus and startup costs'}
    (out / 'summary.json').write_text(json.dumps(final, indent=2) + '\n')
    print(json.dumps(final, indent=2))
    raise SystemExit(0 if completed else 1)


if __name__ == '__main__':
    main()
