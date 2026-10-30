#!/usr/bin/env python3
"""Verify the canonical P5 3-seed, 2-repeat, 500-mutation evidence series."""
import json, hashlib, pathlib, statistics, sys
if len(sys.argv)!=3:
    raise SystemExit('Usage: verify_p5_evidence.py SEMANTIC_RUN_DIR QS_RUN_DIR')
root=pathlib.Path(__file__).resolve().parents[1]
semantic=pathlib.Path(sys.argv[1]); qs=pathlib.Path(sys.argv[2])
checks={}
s=json.loads((semantic/'summary.json').read_text());q=json.loads((qs/'summary.json').read_text())
assert s['completed'] and q['completed']
sm=json.loads((semantic/'manifest.json').read_text());qm=json.loads((qs/'manifest.json').read_text())
for m in (sm,qm):
 for p,h in m['source_sha256'].items():
  assert hashlib.sha256((root/p).read_bytes()).hexdigest()==h,p
sr=json.loads((semantic/'runs.json').read_text());qr=json.loads((qs/'runs.json').read_text())
assert len(sr)==36 and len(qr)==48
assert all(r['exit_code']==0 and not r['driver_timeout'] for r in sr+qr)
assert all(r['measurement']['mutation_executions']==500 for r in sr+qr)
assert all(r['measurement']['extra_target_executions']==0 for r in sr)
idx={(r['revision'],r['repeat'],r['seed']):r['measurement'] for r in qr}
for seed in (17,29,43):
 for rep in (1,2):
  a,b,c= [idx[m,rep,seed] for m in ('baseline','off','seeds')]
  assert a['trace_sha256']==b['trace_sha256']==c['trace_sha256']
  assert a['coverage_count']==b['coverage_count']==c['coverage_count']
  assert not b['gleam_loaded'] and not b['semantic_state_created']
  assert idx['structured',rep,seed]['trace_sha256']==idx['observation',rep,seed]['trace_sha256']
  assert all(idx[m,rep,seed]['errors']==0 for m in ('baseline','old','off','new','seeds','structured','observation','oracle'))
actual=[]
for r in sr:
 m=r['measurement']
 assert m['stats']['infrastructure_failures']==0
 assert (semantic/r['label']/'durable-corpus').is_dir()
 if m['kind']=='stateful':
  x=json.loads((semantic/r['label']/'stateful-actual.json').read_text())
  counts=m['scenario_counters']
  assert x['primary_input_executions']==501
  assert x['accepted_scenarios']+x['rejected_packets']==501
  assert x['accepted_scenarios']==counts['reconstructed_valid_scenarios']
  assert x['completed_library_operations']==counts['reconstructed_library_operations']
  actual.append({'label':r['label'],**{k:v for k,v in x.items() if k!='rows'}})
for r in qr:
 assert (qs/r['label']/'durable-corpus').is_dir()
checks.update(campaigns=84,semantic_campaigns=36,qs_campaigns=48,
    actual_stateful_diagnostics=12,mutation_executions=84*500,
    source_hashes_match=True,disabled_raw_trace_equivalence_pairs=6,
    observation_neutrality_pairs=6,driver_failures=0,
    actual_stateful=actual,semantic_summary=s,qs_summary=q)
print(json.dumps(checks,indent=2))
