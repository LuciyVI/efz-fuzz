"""Pure monitor behavior; no terminal or Erlang required."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('efz_tui', Path(__file__).resolve().parents[1] / 'scripts/tui.py')
tui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tui)


class MonitorTests(unittest.TestCase):
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
