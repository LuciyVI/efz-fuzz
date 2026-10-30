#!/usr/bin/env python3
"""Cold companion manifest; never modifies an immutable EFZ finding group."""
import argparse, hashlib, json, pathlib, subprocess

def main():
    p=argparse.ArgumentParser();p.add_argument('--replay-dir',required=True);p.add_argument('--out',required=True)
    p.add_argument('--artifact-prefix',required=True);p.add_argument('--native-artifacts',required=True)
    p.add_argument('--target',choices=['efz_qs_target','efz_qs_defect_target'],required=True)
    p.add_argument('--benchmark-manifest',required=True);a=p.parse_args()
    root=pathlib.Path(__file__).resolve().parents[1];dest=pathlib.Path(a.out);assert not dest.exists()
    data=json.loads((pathlib.Path(a.replay_dir)/'replay.json').read_text())
    frozen=json.loads(pathlib.Path(a.benchmark_manifest).read_text())
    original=pathlib.Path(a.artifact_prefix+'.input');hash_=hashlib.sha256(original.read_bytes()).hexdigest()
    assert hash_==data['input_sha256'] and data['replay']['status']=='reproduced'
    # Fix build and source identities from the measured series; no environment dump.
    command=['escript',str(root/'scripts/gleam_replay.escript'),a.artifact_prefix,a.native_artifacts,a.target,'64','NEW_OUTPUT_DIRECTORY']
    manifest={'artifact_schema_version':1,'raw_input':{'sha256':hash_,'path':str(original),'size':original.stat().st_size},
        'target':{'id':a.target,'entrypoint':a.target+':run/1','source_revision':frozen['head'],
            'source_sha256':frozen['source_sha256'].get('test/efz_qs_defect_target.erl' if a.target.endswith('defect_target') else 'examples/query_string/efz_qs_target.erl'),
            'artificial_fixture':a.target=='efz_qs_defect_target'},
        'efz_head':frozen['head'],'tracked_dirty_diff_sha256':frozen['tracked_diff_sha256'],
        'all_source_sha256':frozen['source_sha256'],'locks_and_build_options_sha256':frozen['configuration_sha256'],
        'toolchain':frozen['toolchain'],'dependency_revisions':{'cowboy':'79e3fb02b31d47af6e69e8f3ba18fba291a3072a','cowlib':'c768a804565ff5b8178ed968a5921e469d6bd7b2','ranch':'10b51304b26062e0dbfd5e74824324e9a911e269'},
        'execution':{'isolation':'existing isolated guardian','reset':'per execution','timeout_ms':1000,'coverage':'otp_native_public target-only','jit':True,'schedulers':'2:2'},
        'layer_configuration':data['layer'],'versions':data['expectation']['layer_versions'],'property':['query_model_agreement',1],
        'seed_or_recipe':data['recipe'],'primary_outcome':data['primary_outcome'],
        'failure_fingerprint':data['normalized_failure_fingerprint'],'original_execution_id':data['original_execution_id'],
        'diagnostics':[data['diagnostics'],str(pathlib.Path(a.replay_dir)/'replay.json')],
        'replay':{'command':command,'verified_status':'reproduced','result':data['replay']},
        'minimization':data['minimization'],'hex_encoded_binary_metadata':True}
    dest.parent.mkdir(parents=True,exist_ok=True);dest.write_text(json.dumps(manifest,indent=2)+'\n')
    print(dest)
if __name__=='__main__':main()
