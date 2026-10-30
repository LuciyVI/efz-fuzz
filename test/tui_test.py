"""Pure monitor behavior; no terminal or Erlang required."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('efz_tui', Path(__file__).resolve().parents[1] / 'scripts/tui.py')
tui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tui)


class MonitorTests(unittest.TestCase):
    def test_feature_stability_states_and_precision(self):
        self.assertEqual(tui.stability_lines({})[0], 'Stability: unavailable')
        self.assertEqual(tui.stability_lines({'feature_stability': {'status': 'disabled'}})[0],
                         'Stability: disabled')
        pending = {'feature_stability': {'status': 'insufficient_samples',
                   'current': {'valid_runs': 1, 'requested_runs': 20}}}
        self.assertIn('collecting 1/20', tui.stability_lines(pending)[0])
        pending['feature_stability']['collection_status'] = 'budget_exhausted'
        self.assertIn('budget exhausted 1/20', tui.stability_lines(pending)[0])
        empty = {'feature_stability': {'status': 'no_observed_features', 'percent': None}}
        self.assertIn('no features observed', tui.stability_lines(empty)[0])
        measured = {'feature_stability': {'status': 'measured', 'collection_status': 'collecting',
                    'percent': 95.0, 'stable_feature_pairs': 950,
                    'observed_feature_pairs': 1000, 'groups_measured': 12,
                    'current': {'valid_runs': 7, 'requested_runs': 20}}}
        head, detail = tui.stability_lines(measured, .4)
        self.assertIn('95.00%', head)
        self.assertIn('12 audited inputs', head)
        self.assertIn('updated 0.4s', head)
        self.assertIn('variable 50', detail)
        measured['feature_stability'].update(invalid_attempts=2,
                                             invalid_reasons={'coverage_failure': 2})
        self.assertIn('invalid 2 (coverage_failure 2)', tui.stability_lines(measured)[1])
        measured['feature_stability'].update(percent=99.9999, stable_feature_pairs=999999,
                                             observed_feature_pairs=1000000,
                                             collection_status='budget_exhausted')
        self.assertIn('<100% — budget exhausted', tui.stability_lines(measured)[0])
        measured['feature_stability']['collection_status'] = 'partial'
        self.assertIn('<100% — partial', tui.stability_lines(measured)[0])
        measured['feature_stability']['percent'] = float('nan')
        self.assertIn('unavailable', tui.stability_lines(measured)[0])

    def test_persistent_sequence_scope_and_phase(self):
        snap = {'feature_stability': {'scope': 'audited_sequence_steps',
            'status': 'measured', 'collection_status': 'collecting',
            'percent': 75.0, 'stable_feature_pairs': 9,
            'observed_feature_pairs': 12, 'groups_measured': 2},
            'target_execution': {'mode': 'persistent_vm', 'state_policy': 'accumulate'},
            'target_phase': 'audit', 'target_session': {'step': 2},
            'sequence_journal': {'step': 2, 'complete': True},
            'target_audit': {'repetition': 3, 'requested_repetitions': 4, 'calls': 6}}
        self.assertIn('2 audited step groups', tui.stability_lines(snap)[0])
        headline, detail = tui.target_lines(snap)
        self.assertIn('persistent/accumulate', headline)
        self.assertIn('audit', headline)
        self.assertIn('replay 3/4', headline)
        self.assertIn('Journal complete', detail)
        self.assertEqual(('', ''), tui.target_lines({}))

    def test_partial_or_malformed_snapshot_is_bounded(self):
        self.assertEqual(tui.stability_lines({'feature_stability': 'broken'})[0],
                         'Stability: unavailable')
        self.assertEqual(tui.input_lines({'preview_hex': 'not hex'}),
                         ['Input preview unavailable'])
        samples = tui.Samples()
        samples.update({'elapsed_ms': 100, 'stats': {'executions': 'bad'}})
        self.assertEqual(len(samples.rate), 0)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'snapshot.json'
            path.write_text('[]')
            with self.assertRaises(ValueError):
                tui.read_snapshot(Path(directory))
            path.write_text('{"schema_version":1,"feature_stability":{"status":"disabled"}}')
            self.assertEqual(tui.read_snapshot(Path(directory))['feature_stability']['status'], 'disabled')

    def test_rates_ignore_duplicate_samples_and_include_calibration(self):
        s = tui.Samples()
        s.update({'elapsed_ms': 1000, 'stats': {'executions': 10, 'calibrations': 2}})
        s.update({'elapsed_ms': 1500, 'stats': {'executions': 15, 'calibrations': 2}})
        s.update({'elapsed_ms': 1500, 'stats': {'executions': 15}})
        self.assertEqual(list(s.rate), [10])
        for i in range(1000):
            s.update({'elapsed_ms': 2000+i, 'stats': {'executions': i}})
        self.assertEqual(len(s.rate), 120)

    def test_input_and_terminal_control_characters(self):
        rows = tui.input_lines({'preview_hex': '0041ff1b'})
        self.assertIn('.A..', rows[0])
        self.assertNotIn('\x1b', tui.clean('\x1b[31m'))
        self.assertEqual(tui.input_lines({'preview_hex': ''}), ['<empty input>'])


if __name__ == '__main__':
    unittest.main()
