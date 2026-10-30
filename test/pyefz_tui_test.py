"""Presentation contracts for the runtime provider snapshot schema."""
import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location(
    "efz_tui_provider", Path(__file__).resolve().parents[1] / "scripts/tui.py")
tui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tui)


class ProviderSnapshotTests(unittest.TestCase):
    def test_runtime_counts_and_latency_are_shown_separately(self):
        # The worker's provider_stats counters, not stats.executions, feed this
        # panel: requests can be skipped before a target is ever executed.
        lines = tui.provider_lines({
            "provider": {"mode": "hybrid", "weights": [["native", 70], ["erlamsa", 30]],
                         "options": {"profile": "formats", "strategy": "preserve"}},
            "stats": {"executions": 9999},
            "provider_stats": {
                "requests": 11, "changed": 7, "skips": 4, "fallbacks": 3,
                "errors": 0, "timeouts": 0, "cancelled": 1,
                "latency_us": [1000, 2000, 3000], "latency_samples_dropped": 2,
                "discoveries": {"native": 5, "erlamsa": 2},
                "retained": {"native": 4, "erlamsa": 1},
                "skip_reasons": {"format_miss": 3, "unchanged": 1}}})
        text = "\n".join(lines)
        for expected in ("hybrid", "formats", "preserve", "native=70 erlamsa=30",
                         "Requests 11 · changed 7", "Skips 4 · fallback 3",
                         "Latency sample 3 · dropped 2", "ms p50 2.00 · p95 2.00",
                         "native 5 / 4", "erlamsa 2 / 1", "format_miss: 3"):
            self.assertIn(expected, text)
        self.assertNotIn("9,999", text)

    def test_missing_or_invalid_observations_do_not_become_zero(self):
        self.assertEqual(tui.provider_lines({"stats": {"executions": 12}}), [])
        text = "\n".join(tui.provider_lines({
            "provider": {"mode": "erlamsa", "options": "invalid"},
            "provider_stats": {"requests": True, "changed": -1,
                               "latency_us": [True, -10, "20"],
                               "skip_reasons": {"bad": -1}}}))
        self.assertIn("Requests ? · changed ?", text)
        self.assertIn("Latency sample unavailable", text)
        self.assertNotIn("bad:", text)

    def test_reason_list_is_bounded_and_terminal_controls_are_sanitized(self):
        text = "\n".join(tui.provider_lines({
            "provider": {"mode": "erlamsa\x1b[31m"},
            "provider_stats": {"skip_reasons": {f"reason{i}": i for i in range(8)}}}))
        self.assertNotIn("\x1b", text)
        self.assertIn("reason7: 7", text)
        self.assertNotIn("reason3:", text)


if __name__ == "__main__":
    unittest.main()
